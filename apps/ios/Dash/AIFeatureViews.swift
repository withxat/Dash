import CloudflareAPI
import SwiftUI

// MARK: - Workers AI

/// Browsable Workers AI model catalog with a run tray for text models.
struct WorkersAIView: View {
  @Environment(AppModel.self) private var model
  @State private var models: [GenericResource] = []
  @State private var loading = true
  @State private var error: String?
  @State private var search = ""
  @State private var selected: GenericResource?

  private var filtered: [GenericResource] {
    guard !search.isEmpty else { return models }
    return models.filter {
      $0.name.localizedCaseInsensitiveContains(search)
        || ($0.detail?.localizedCaseInsensitiveContains(search) ?? false)
    }
  }

  var body: some View {
    DashFeatureList(
      search: $search,
      prompt: "Search models",
      isLoading: loading,
      error: error,
      hasContent: !models.isEmpty,
      retry: { Task { await load(force: true) } }
    ) {
      if filtered.isEmpty {
        DashEmptyState(
          icon: SolarAsset.search,
          title: search.isEmpty ? "No models" : "Nothing found",
          message: search.isEmpty
            ? "Cloudflare returned no Workers AI models."
            : "No model matches \(search)."
        )
      } else {
        DashListCard {
          DashListCardRows(items: filtered) { item in
            Button {
              selected = item
            } label: {
              DashListRow(
                title: item.name.replacingOccurrences(of: "@cf/", with: ""),
                subtitle: taskName(of: item),
                icon: SolarAsset.bolt
              )
            }
            .buttonStyle(DashPressButtonStyle())
          }
        }
      }
    }
    .dashTray(
      item: $selected,
      title: { $0.name.replacingOccurrences(of: "@cf/", with: "") }
    ) { item in
      AIModelDetailTray(model: item, taskName: taskName(of: item))
    }
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func taskName(of resource: GenericResource) -> String? {
    if case .object(let task)? = resource.raw["task"],
      case .string(let name)? = task["name"]
    {
      return name
    }
    return nil
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let path = "/accounts/\(accountID)/ai/models/search"
    let key = FeatureCacheKey.generic(path: path)
    if !force, let cached: [GenericResource] = model.featureCache.get(key) {
      models = cached
      loading = false
      return
    }
    if models.isEmpty { loading = true }
    error = nil
    do {
      var all: [GenericResource] = []
      var page = 1
      // The catalog is a few hundred entries; stop as soon as a page comes
      // back short instead of trusting result_info to exist.
      while page <= 10 {
        let result = try await model.client.listResources(
          path: path, query: ["per_page": "100", "page": String(page)])
        all.append(contentsOf: result.items)
        if result.items.count < 100 { break }
        page += 1
      }
      models = all
      model.featureCache.set(key, all)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}

private struct AIModelDetailTray: View {
  @Environment(AppModel.self) private var appModel
  let model: GenericResource
  let taskName: String?
  @State private var prompt = ""
  @State private var response: String?
  @State private var running = false
  @State private var runError: String?

  private var supportsPromptRun: Bool {
    taskName == "Text Generation"
      && appModel.hasScopes(FeatureID.workersAI.capability.write)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let taskName {
        StatusBadge(text: taskName)
      }
      if let description = model.detail, !description.isEmpty {
        Text(description)
          .dashTextStyle(.supportingMedium)
          .foregroundStyle(DashTheme.subtle)
      }
      if supportsPromptRun {
        DashFormField(label: "Prompt", text: $prompt)
        if let runError {
          DashNotice(kind: .error, message: runError)
        }
        if let response {
          DashCodeBlock(title: "Response", text: response)
        }
        DashTrayPillButton(
          title: running ? "Running…" : "Run model",
          isLoading: running
        ) {
          guard !prompt.isEmpty else { return }
          Task { await run() }
        }
      }
    }
  }

  private func run() async {
    guard let accountID = appModel.activeAccountID else { return }
    running = true
    runError = nil
    do {
      let result = try await appModel.client.mutate(
        path: "/accounts/\(accountID)/ai/run/\(model.name)",
        method: "POST",
        body: ["prompt": .string(prompt)]
      )
      if case .object(let object) = result, case .string(let text)? = object["response"] {
        response = text
      } else {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let rendered = String(decoding: try encoder.encode(result), as: UTF8.self)
        response =
          rendered.count > 100_000
          ? String(rendered.prefix(100_000)) + "\n\n…response truncated for display"
          : rendered
      }
    } catch {
      runError = error.dashActionableMessage
    }
    running = false
  }
}

// MARK: - Browser Rendering

/// Render a URL through Browser Rendering: screenshot, PDF, or markdown.
struct BrowserRenderingView: View {
  private enum Mode: String, CaseIterable, Hashable {
    case screenshot = "Screenshot"
    case pdf = "PDF"
    case markdown = "Markdown"
  }

  @Environment(AppModel.self) private var model
  @State private var url = ""
  @State private var mode = Mode.screenshot
  @State private var running = false
  @State private var error: String?
  @State private var screenshot: UIImage?
  @State private var pdfURL: URL?
  @State private var markdown: String?

  private var allowsRun: Bool {
    model.hasScopes(FeatureID.browserRendering.capability.write)
  }

  var body: some View {
    DashFeatureScreen(
      chrome: {
        DashTextTabs(
          items: Mode.allCases.map { ($0.rawValue, $0) },
          selection: $mode
        )
      },
      content: {
        browserRenderingContent
      })
  }

  private var browserRenderingContent: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: DashTheme.Spacing.section) {
        DashFormField(label: "URL", text: $url, keyboard: .URL)
        DashPillButton(
          title: "Render",
          isLoading: running,
          isEnabled: allowsRun && !url.isEmpty
        ) {
          Task { await run() }
        }
        if !allowsRun {
          DashNotice(
            kind: .warning,
            message: "Rendering needs the browser-rendering.write scope."
          )
        }
        if let error {
          DashNotice(kind: .error, message: error)
        }
        switch mode {
        case .screenshot:
          if let screenshot {
            Image(uiImage: screenshot)
              .resizable()
              .scaledToFit()
              .clipShape(
                RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
              )
              .overlay {
                RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
                  .stroke(DashTheme.line, lineWidth: 0.5)
              }
          }
        case .pdf:
          if let pdfURL {
            ShareLink(item: pdfURL) {
              DashListCard {
                DashListRow(
                  title: "Share PDF",
                  subtitle: pdfURL.lastPathComponent,
                  icon: SolarAsset.file
                )
              }
            }
          }
        case .markdown:
          if let markdown {
            DashCodeBlock(title: "Markdown", text: markdown)
          }
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.bottom, DashTheme.Spacing.section)
    }
  }

  private var normalizedURL: String {
    url.hasPrefix("http://") || url.hasPrefix("https://") ? url : "https://\(url)"
  }

  private func run() async {
    guard let accountID = model.activeAccountID else { return }
    running = true
    error = nil
    do {
      let body = try JSONEncoder().encode(
        JSONValue.object(["url": .string(normalizedURL)]))
      switch mode {
      case .screenshot:
        let data = try await model.client.executeRaw(
          path: "/accounts/\(accountID)/browser-rendering/screenshot",
          method: "POST", data: body, contentType: "application/json")
        if let image = UIImage(data: data) {
          screenshot = image
        } else {
          error = renderFailureMessage(from: data)
        }
      case .pdf:
        let data = try await model.client.executeRaw(
          path: "/accounts/\(accountID)/browser-rendering/pdf",
          method: "POST", data: body, contentType: "application/json")
        if data.starts(with: Data("%PDF".utf8)) {
          let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-\(UUID().uuidString.prefix(8)).pdf")
          try data.write(to: destination)
          pdfURL = destination
        } else {
          error = renderFailureMessage(from: data)
        }
      case .markdown:
        let value = try await model.client.execute(
          path: "/accounts/\(accountID)/browser-rendering/markdown",
          method: "POST",
          body: .object(["url": .string(normalizedURL)]))
        if case .object(let object) = value, case .string(let text)? = object["result"] {
          markdown = text
        } else {
          error = "Cloudflare returned no markdown for this URL."
        }
      }
    } catch {
      self.error = error.dashActionableMessage
    }
    running = false
  }

  /// Binary endpoints return a JSON error envelope on failure.
  private func renderFailureMessage(from data: Data) -> String {
    if let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object(let object) = value,
      case .array(let errors)? = object["errors"],
      case .object(let first)? = errors.first,
      case .string(let message)? = first["message"]
    {
      return message
    }
    return "Cloudflare returned an unexpected response."
  }
}
