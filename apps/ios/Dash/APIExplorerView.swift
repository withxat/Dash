import CloudflareAPI
import SwiftUI

enum APIExplorerMode: String, CaseIterable, Hashable {
  case products = "Products"
  case endpoints = "Endpoints"
}

enum APIExplorerFiltering {
  static func endpoints(matching search: String) -> [CloudflareEndpointDefinition] {
    guard !search.isEmpty else { return CloudflareEndpointCatalog.all }
    let needle = search.localizedLowercase
    return CloudflareEndpointCatalog.all.filter { endpoint in
      endpoint.summary.localizedLowercase.contains(needle)
        || endpoint.path.localizedLowercase.contains(needle)
        || endpoint.id.localizedLowercase.contains(needle)
        || endpoint.tags.contains { $0.localizedLowercase.contains(needle) }
    }
  }

  static func endpointSections(matching search: String) -> [(
    String, [CloudflareEndpointDefinition]
  )] {
    Dictionary(grouping: endpoints(matching: search), by: \.primaryTag)
      .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
  }

  static func products(matching search: String) -> [OAuthProductDefinition] {
    guard !search.isEmpty else { return OAuthScopeCatalog.products }
    let needle = search.localizedLowercase
    return OAuthScopeCatalog.products.filter { product in
      product.name.localizedLowercase.contains(needle)
        || product.id.localizedLowercase.contains(needle)
        || product.scopes.contains {
          $0.name.localizedLowercase.contains(needle) || $0.id.localizedLowercase.contains(needle)
        }
    }
  }

  static func productSections(matching search: String) -> [(String, [OAuthProductDefinition])] {
    Dictionary(grouping: products(matching: search), by: \.categoryTitle)
      .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
  }
}

enum APIRequestDraft {
  static func shouldConfirm(isMutation: Bool) -> Bool { isMutation }

  static func truncatedResponse(_ rendered: String, limit: Int = 100_000) -> String {
    rendered.count > limit
      ? String(rendered.prefix(limit)) + "\n\n…response truncated for display"
      : rendered
  }
}

struct APIExplorerView: View {
  @State private var search = ""
  @State private var selected: CloudflareEndpointDefinition?
  @State private var selectedProduct: OAuthProductDefinition?
  @State private var mode: APIExplorerMode = .products

  var body: some View {
    DashFeatureScreen(
      search: $search,
      prompt: "Products, permissions, operations",
      chrome: {
        DashTextTabs(
          items: APIExplorerMode.allCases.map { ($0.rawValue, $0) },
          selection: $mode
        )
      },
      content: {
        ScrollView {
          LazyVStack(spacing: DashTheme.Spacing.section) {
            if mode == .products {
              productsContent
            } else {
              endpointsContent
            }
          }
          .padding(.horizontal, DashTheme.Spacing.screen)
          .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
        }
      }
    )
    .navigationTitle("API Explorer")
    .dashTray(
      item: $selected, title: { $0.summary },
      content: { endpoint in
        APIRequestTray(endpoint: endpoint)
      }
    )
    .dashTray(
      item: $selectedProduct, title: { $0.name },
      content: { product in
        CapabilityProductTray(product: product) { selected = $0 }
      })
  }

  @ViewBuilder
  private var productsContent: some View {
    DashListGroup(title: "Catalog") {
      DashValueRow(title: "Products", value: "\(OAuthScopeCatalog.products.count)")
      DashListGroupDivider()
      DashValueRow(title: "OAuth permissions", value: "\(OAuthScopeCatalog.all.count)")
    }

    let sections = APIExplorerFiltering.productSections(matching: search)
    if sections.isEmpty {
      DashEmptyState(
        icon: SolarAsset.search,
        title: "Nothing found",
        message: "Try another product or permission name."
      )
    } else {
      ForEach(sections, id: \.0) { category, products in
        DashListGroup(title: category) {
          ForEach(Array(products.enumerated()), id: \.element.id) { index, product in
            Button {
              selectedProduct = product
            } label: {
              DashListRow(
                title: product.name,
                subtitle:
                  "\(product.scopes.count) permission\(product.scopes.count == 1 ? "" : "s")"
              )
            }
            .buttonStyle(DashPressButtonStyle())
            if index < products.count - 1 { DashListGroupDivider() }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var endpointsContent: some View {
    DashListGroup(title: "OpenAPI") {
      DashValueRow(title: "Operations", value: "\(CloudflareEndpointCatalog.all.count)")
      DashListGroupDivider()
      DashValueRow(title: "Schema snapshot", value: CloudflareEndpointCatalog.generatedAt)
    }

    Text(
      "Every operation comes from Cloudflare's OpenAPI schema. Mutating requests always require confirmation."
    )
    .dashTextStyle(.footnote)
    .foregroundStyle(DashTheme.placeholder)
    .frame(maxWidth: .infinity, alignment: .leading)

    let sections = APIExplorerFiltering.endpointSections(matching: search)
    if sections.isEmpty {
      DashEmptyState(
        icon: SolarAsset.search,
        title: "Nothing found",
        message: "Try another operation, path, or tag."
      )
    } else {
      ForEach(sections, id: \.0) { tag, endpoints in
        DashListGroup(title: tag) {
          ForEach(Array(endpoints.enumerated()), id: \.element.id) { index, endpoint in
            APIEndpointRow(endpoint: endpoint) { selected = endpoint }
            if index < endpoints.count - 1 { DashListGroupDivider() }
          }
        }
      }
    }
  }
}

private struct APIEndpointRow: View {
  let endpoint: CloudflareEndpointDefinition
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 12) {
        Text(endpoint.method)
          .dashTextStyle(.micro)
          .fontWeight(.bold)
          .foregroundStyle(endpoint.isMutation ? DashTheme.warning : DashTheme.brand)
          .frame(width: 48, alignment: .leading)
        VStack(alignment: .leading, spacing: 3) {
          Text(endpoint.summary)
            .dashTextStyle(.supportingMedium)
            .foregroundStyle(DashTheme.text)
            .multilineTextAlignment(.leading)
          Text(endpoint.path)
            .dashTextStyle(.code)
            .foregroundStyle(DashTheme.subtle)
            .lineLimit(2)
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(DashPressButtonStyle())
  }
}

struct EndpointProductView: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID
  let matching: [String]
  @State private var selected: CloudflareEndpointDefinition?
  @State private var search = ""

  private var allowsWrites: Bool { model.hasScopes(feature.capability.write) }

  private var endpoints: [CloudflareEndpointDefinition] {
    let terms = matching.map { $0.lowercased() }
    return CloudflareEndpointCatalog.all.filter { endpoint in
      if !allowsWrites, endpoint.isMutation { return false }
      let haystack = ([endpoint.id, endpoint.path] + endpoint.tags).joined(separator: " ")
        .lowercased()
      guard terms.contains(where: haystack.contains) else { return false }
      guard !search.isEmpty else { return true }
      let needle = search.localizedLowercase
      return haystack.contains(needle) || endpoint.summary.localizedLowercase.contains(needle)
    }
  }

  var body: some View {
    DashFeatureScreen(
      search: $search, prompt: "Search \(feature.title)",
      content: {
        ScrollView {
          LazyVStack(spacing: DashTheme.Spacing.section) {
            if !allowsWrites, !feature.capability.write.isEmpty {
              DashNotice(kind: .warning, message: "This module is currently read-only.")
              DashSecondaryPillButton(title: "Grant write access") {
                model.requestAccess(to: feature.capability.all)
              }
            }

            DashListGroup(title: "\(endpoints.count) public operations") {
              if endpoints.isEmpty {
                Text("No matching operations in the current OpenAPI snapshot.")
                  .dashTextStyle(.supporting)
                  .foregroundStyle(DashTheme.subtle)
                  .padding(.vertical, 10)
              } else {
                ForEach(Array(endpoints.enumerated()), id: \.element.id) { index, endpoint in
                  APIEndpointRow(endpoint: endpoint) { selected = endpoint }
                  if index < endpoints.count - 1 { DashListGroupDivider() }
                }
              }
            }

            Text(
              "Generated from Cloudflare OpenAPI \(CloudflareEndpointCatalog.generatedAt)."
            )
            .dashTextStyle(.micro)
            .foregroundStyle(DashTheme.placeholder)
          }
          .padding(.horizontal, DashTheme.Spacing.screen)
          .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
        }
      }
    )
    .navigationTitle(feature.title)
    .dashTray(
      item: $selected, title: { $0.summary },
      content: { endpoint in
        APIRequestTray(endpoint: endpoint)
      })
  }
}

private struct CapabilityProductTray: View {
  @Environment(AppModel.self) private var model
  let product: OAuthProductDefinition
  let openEndpoint: (CloudflareEndpointDefinition) -> Void

  private var unsupportedScopes: Set<String> {
    product.scopeIDs.intersection(CloudflareScopes.unsupportedByOAuthClient)
  }

  private var missingScopes: Set<String> {
    guard let granted = model.grantedScopes else { return [] }
    return product.scopeIDs
      .intersection(CloudflareScopes.requestable)
      .subtracting(granted)
  }

  private var endpoints: [CloudflareEndpointDefinition] {
    let tokens =
      product.id
      .split(whereSeparator: { "-_.".contains($0) })
      .map { $0.lowercased() }
      .filter { $0.count > 2 && !["read", "write", "account", "zone"].contains($0) }
    guard !tokens.isEmpty else { return [] }
    return CloudflareEndpointCatalog.all.filter { endpoint in
      let haystack =
        ([endpoint.id, endpoint.path] + endpoint.tags)
        .joined(separator: " ")
        .lowercased()
      return tokens.contains { haystack.contains($0) }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      DashListGroup(title: "Permissions") {
        ForEach(Array(product.scopes.enumerated()), id: \.element.id) { index, scope in
          HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
              Text(scope.name)
                .dashTextStyle(.bodyMedium)
              Text(scope.id)
                .dashTextStyle(.code)
                .foregroundStyle(DashTheme.subtle)
            }
            Spacer(minLength: 0)
            Image(
              systemName:
                unsupportedScopes.contains(scope.id)
                ? "nosign"
                : missingScopes.contains(scope.id) ? "lock" : "checkmark.circle.fill"
            )
            .foregroundStyle(
              unsupportedScopes.contains(scope.id)
                ? DashTheme.danger
                : missingScopes.contains(scope.id) ? DashTheme.warning : DashTheme.success)
          }
          .padding(.vertical, 8)
          if index < product.scopes.count - 1 { DashListGroupDivider() }
        }
      }

      if !missingScopes.isEmpty {
        DashSecondaryPillButton(
          title:
            "Grant \(missingScopes.count) missing permission\(missingScopes.count == 1 ? "" : "s")"
        ) {
          model.requestAccess(to: missingScopes)
        }
      }
      if !unsupportedScopes.isEmpty {
        Text("Cloudflare does not expose these metadata permissions to this OAuth client.")
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
      }

      DashListGroup(title: "Public API operations") {
        if endpoints.isEmpty {
          Text("No matching public operation is present in the current OpenAPI snapshot.")
            .dashTextStyle(.supporting)
            .foregroundStyle(DashTheme.subtle)
            .padding(.vertical, 10)
        } else {
          ForEach(Array(endpoints.enumerated()), id: \.element.id) { index, endpoint in
            APIEndpointRow(endpoint: endpoint) { openEndpoint(endpoint) }
            if index < endpoints.count - 1 { DashListGroupDivider() }
          }
        }
      }
    }
    .padding(.horizontal, DashTheme.Sheet.content)
  }
}

private struct APIRequestTray: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  let endpoint: CloudflareEndpointDefinition

  @State private var pathValues: [String: String]
  @State private var queryText = ""
  @State private var bodyText: String
  @State private var responseText: String?
  @State private var error: Error?
  @State private var isRunning = false
  @State private var phase: Phase = .compose

  private enum Phase: Equatable {
    case compose
    case confirm
  }

  init(endpoint: CloudflareEndpointDefinition) {
    self.endpoint = endpoint
    _pathValues = State(
      initialValue: Dictionary(uniqueKeysWithValues: endpoint.pathParameters.map { ($0, "") })
    )
    _bodyText = State(initialValue: endpoint.hasRequestBody ? "{\n  \n}" : "")
  }

  var body: some View {
    DashConfirmMorph(
      confirming: Binding(
        get: { phase == .confirm },
        set: { active in phase = active ? .confirm : .compose }
      ),
      message:
        "Run \(endpoint.method) \(endpoint.path)? This operation can change Cloudflare account state.",
      isBusy: isRunning,
      actionTitle: endpoint.isMutation ? "Review and run" : "Run request",
      confirmingActionTitle: "Run \(endpoint.method)",
      confirmingActionRole: endpoint.method == "DELETE" ? .destructive : nil,
      actionEnabled: !isRunning,
      errorMessage: error.map { DashFailurePresentation.from(error: $0).message },
      action: {
        if APIRequestDraft.shouldConfirm(isMutation: endpoint.isMutation), phase == .compose {
          UIImpactFeedbackGenerator(style: .medium).impactOccurred()
          withAnimation(DashTheme.Motion.morph) { phase = .confirm }
        } else {
          Task { await run() }
        }
      },
      appliesContentPadding: true,
      content: {
        VStack(alignment: .leading, spacing: 14) {
          Text(endpoint.summary)
            .dashTextStyle(.supporting)
            .foregroundStyle(DashTheme.subtle)

          labeled("Method", endpoint.method)
          Text(endpoint.path)
            .dashTextStyle(.code)
            .textSelection(.enabled)
            .foregroundStyle(DashTheme.text)

          if !endpoint.pathParameters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text("Path parameters")
                .dashTextStyle(.footnoteSemibold)
                .foregroundStyle(DashTheme.subtle)
              ForEach(endpoint.pathParameters, id: \.self) { parameter in
                TextField(parameter, text: pathBinding(parameter))
                  .textInputAutocapitalization(.never)
                  .autocorrectionDisabled()
                  .padding(12)
                  .background(DashTheme.recessed, in: DashTheme.buttonShape)
              }
            }
          }

          VStack(alignment: .leading, spacing: 8) {
            Text("Query")
              .dashTextStyle(.footnoteSemibold)
              .foregroundStyle(DashTheme.subtle)
            TextField("page=1&per_page=50", text: $queryText)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .dashTextStyle(.code)
              .padding(12)
              .background(DashTheme.recessed, in: DashTheme.buttonShape)
          }

          if endpoint.hasRequestBody {
            VStack(alignment: .leading, spacing: 8) {
              Text("JSON body")
                .dashTextStyle(.footnoteSemibold)
                .foregroundStyle(DashTheme.subtle)
              TextEditor(text: $bodyText)
                .dashTextStyle(.code)
                .frame(minHeight: 140)
                .padding(8)
                .background(DashTheme.recessed, in: DashTheme.buttonShape)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
          }

          if let responseText {
            VStack(alignment: .leading, spacing: 8) {
              Text("Response")
                .dashTextStyle(.footnoteSemibold)
                .foregroundStyle(DashTheme.subtle)
              ScrollView(.horizontal) {
                Text(responseText)
                  .dashTextStyle(.code)
                  .textSelection(.enabled)
              }
            }
          }
        }
      }
    )
    .dashTrayTitle(phase == .confirm ? "Confirm" : endpoint.method)
    .dashKeyboardDismissal()
    .task { prefillKnownIdentifiers() }
  }

  private func labeled(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).dashTextStyle(.footnote).foregroundStyle(DashTheme.subtle)
      Spacer()
      Text(value).dashTextStyle(.supportingMedium)
    }
  }

  private func pathBinding(_ key: String) -> Binding<String> {
    Binding(
      get: { pathValues[key] ?? "" },
      set: { pathValues[key] = $0 }
    )
  }

  private func prefillKnownIdentifiers() {
    guard let accountID = model.activeAccountID else { return }
    for key in endpoint.pathParameters where key.localizedCaseInsensitiveContains("account") {
      if pathValues[key]?.isEmpty == true {
        pathValues[key] = accountID
      }
    }
  }

  private func resolvedPath() throws -> String {
    var path = endpoint.path
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    for parameter in endpoint.pathParameters {
      guard let value = pathValues[parameter], !value.isEmpty else {
        throw APIRequestInputError("Enter \(parameter).")
      }
      let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
      path = path.replacingOccurrences(of: "{\(parameter)}", with: encoded)
    }
    return path
  }

  private func parsedQuery() -> [String: String?] {
    guard !queryText.isEmpty,
      let items = URLComponents(string: "?\(queryText)")?.queryItems
    else { return [:] }
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
  }

  private func parsedBody() throws -> JSONValue? {
    guard endpoint.hasRequestBody, !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    do {
      return try JSONDecoder().decode(JSONValue.self, from: Data(bodyText.utf8))
    } catch {
      throw APIRequestInputError("The request body is not valid JSON.")
    }
  }

  @MainActor
  private func run() async {
    isRunning = true
    error = nil
    responseText = nil
    do {
      let value = try await model.client.execute(
        path: resolvedPath(),
        method: endpoint.method,
        query: parsedQuery(),
        body: parsedBody()
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let rendered = String(decoding: try encoder.encode(value), as: UTF8.self)
      responseText = APIRequestDraft.truncatedResponse(rendered)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      withAnimation(DashTheme.Motion.morph) { phase = .compose }
    } catch {
      self.error = error
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    isRunning = false
  }
}

private struct APIRequestInputError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
