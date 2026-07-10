import CloudflareAPI
import SwiftUI

struct APIExplorerView: View {
  private enum Mode: String, CaseIterable, Identifiable {
    case products = "Products"
    case endpoints = "Endpoints"
    var id: Self { self }
  }

  @State private var search = ""
  @State private var selected: CloudflareEndpointDefinition?
  @State private var mode: Mode = .products

  private var filteredEndpoints: [CloudflareEndpointDefinition] {
    guard !search.isEmpty else { return CloudflareEndpointCatalog.all }
    let needle = search.localizedLowercase
    return CloudflareEndpointCatalog.all.filter { endpoint in
      endpoint.summary.localizedLowercase.contains(needle)
        || endpoint.path.localizedLowercase.contains(needle)
        || endpoint.id.localizedLowercase.contains(needle)
        || endpoint.tags.contains { $0.localizedLowercase.contains(needle) }
    }
  }

  private var endpointSections: [(String, [CloudflareEndpointDefinition])] {
    Dictionary(grouping: filteredEndpoints, by: \.primaryTag)
      .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
  }

  private var filteredProducts: [OAuthProductDefinition] {
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

  private var productSections: [(String, [OAuthProductDefinition])] {
    Dictionary(grouping: filteredProducts, by: \.categoryTitle)
      .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("Catalog mode", selection: $mode) {
        ForEach(Mode.allCases) { mode in
          Text(mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)

      if mode == .products {
        List {
          Section {
            LabeledContent("Products", value: "\(OAuthScopeCatalog.products.count)")
            LabeledContent("OAuth permissions", value: "\(OAuthScopeCatalog.all.count)")
          }
          ForEach(productSections, id: \.0) { category, products in
            Section(category) {
              ForEach(products) { product in
                NavigationLink {
                  CapabilityProductView(product: product)
                } label: {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(product.name)
                      .font(.subheadline.weight(.medium))
                    Text(
                      "\(product.scopes.count) permission\(product.scopes.count == 1 ? "" : "s")"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        }
        .scrollContentBackground(.hidden)
      } else {
        List {
          Section {
            LabeledContent("Operations", value: "\(CloudflareEndpointCatalog.all.count)")
            LabeledContent("Schema snapshot", value: CloudflareEndpointCatalog.generatedAt)
          } footer: {
            Text(
              "Every operation comes from Cloudflare's OpenAPI schema. Mutating requests always require confirmation."
            )
          }

          ForEach(endpointSections, id: \.0) { tag, endpoints in
            Section(tag) {
              ForEach(endpoints) { endpoint in
                APIEndpointRow(endpoint: endpoint) { selected = endpoint }
              }
            }
          }
        }
        .scrollContentBackground(.hidden)
      }
    }
    .background(DashTheme.canvas)
    .navigationTitle("API Explorer")
    .searchable(text: $search, prompt: "Products, permissions, operations")
    .sheet(item: $selected) { endpoint in
      NavigationStack {
        APIRequestView(endpoint: endpoint)
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
          .font(.caption2.monospaced().weight(.bold))
          .foregroundStyle(endpoint.isMutation ? DashTheme.warning : DashTheme.brand)
          .frame(width: 48, alignment: .leading)
        VStack(alignment: .leading, spacing: 3) {
          Text(endpoint.summary)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(DashTheme.text)
            .multilineTextAlignment(.leading)
          Text(endpoint.path)
            .font(.caption2.monospaced())
            .foregroundStyle(DashTheme.subtle)
            .lineLimit(2)
        }
      }
    }
    .buttonStyle(.plain)
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
    List {
      if !allowsWrites, !feature.capability.write.isEmpty {
        Section {
          Button("Grant write access") {
            model.requestAccess(to: feature.capability.all)
          }
        } footer: {
          Text("This module is currently read-only.")
        }
      }

      Section {
        ForEach(endpoints) { endpoint in
          APIEndpointRow(endpoint: endpoint) { selected = endpoint }
        }
      } header: {
        Text("\(endpoints.count) public operations")
      } footer: {
        Text("Generated from Cloudflare OpenAPI \(CloudflareEndpointCatalog.generatedAt).")
      }
    }
    .scrollContentBackground(.hidden)
    .background(DashTheme.canvas)
    .navigationTitle(feature.title)
    .searchable(text: $search, prompt: "Search \(feature.title)")
    .sheet(item: $selected) { endpoint in
      NavigationStack {
        APIRequestView(endpoint: endpoint)
      }
    }
  }
}

private struct CapabilityProductView: View {
  @Environment(AppModel.self) private var model
  let product: OAuthProductDefinition
  @State private var selected: CloudflareEndpointDefinition?

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
    List {
      Section("Permissions") {
        ForEach(product.scopes) { scope in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(scope.name)
              Text(scope.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            }
            Spacer()
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
        }
        if !missingScopes.isEmpty {
          Button(
            "Grant \(missingScopes.count) missing permission\(missingScopes.count == 1 ? "" : "s")"
          ) {
            model.requestAccess(to: missingScopes)
          }
        }
        if !unsupportedScopes.isEmpty {
          Text("Cloudflare does not expose these metadata permissions to this OAuth client.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section("Public API operations") {
        if endpoints.isEmpty {
          Text("No matching public operation is present in the current OpenAPI snapshot.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(endpoints) { endpoint in
            APIEndpointRow(endpoint: endpoint) { selected = endpoint }
          }
        }
      }
    }
    .navigationTitle(product.name)
    .sheet(item: $selected) { endpoint in
      NavigationStack {
        APIRequestView(endpoint: endpoint)
      }
    }
  }
}

private struct APIRequestView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(AppModel.self) private var model
  let endpoint: CloudflareEndpointDefinition

  @State private var pathValues: [String: String]
  @State private var queryText = ""
  @State private var bodyText: String
  @State private var responseText: String?
  @State private var error: Error?
  @State private var isRunning = false
  @State private var confirmsMutation = false

  init(endpoint: CloudflareEndpointDefinition) {
    self.endpoint = endpoint
    _pathValues = State(
      initialValue: Dictionary(uniqueKeysWithValues: endpoint.pathParameters.map { ($0, "") })
    )
    _bodyText = State(initialValue: endpoint.hasRequestBody ? "{\n  \n}" : "")
  }

  var body: some View {
    Form {
      Section {
        LabeledContent("Method", value: endpoint.method)
        Text(endpoint.path)
          .font(.caption.monospaced())
          .textSelection(.enabled)
      } header: {
        Text(endpoint.summary)
      }

      if !endpoint.pathParameters.isEmpty {
        Section("Path parameters") {
          ForEach(endpoint.pathParameters, id: \.self) { parameter in
            TextField(parameter, text: pathBinding(parameter))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          }
        }
      }

      Section("Query") {
        TextField("page=1&per_page=50", text: $queryText)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .font(.body.monospaced())
      }

      if endpoint.hasRequestBody {
        Section("JSON body") {
          TextEditor(text: $bodyText)
            .font(.body.monospaced())
            .frame(minHeight: 180)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
      }

      Section {
        Button(endpoint.isMutation ? "Review and run" : "Run request") {
          if endpoint.isMutation {
            confirmsMutation = true
          } else {
            Task { await run() }
          }
        }
        .disabled(isRunning)

        if isRunning {
          HStack {
            ProgressView()
            Text("Cloudflare is processing the request…")
              .foregroundStyle(.secondary)
          }
        }
      } footer: {
        if endpoint.isMutation {
          Text("This operation can change Cloudflare account state.")
        }
      }

      if let error {
        Section("Error") {
          Text(error.localizedDescription)
            .foregroundStyle(DashTheme.danger)
            .textSelection(.enabled)
          if (error as? CloudflareAPIError)?.isForbidden == true {
            if model.hasScopes(Set(CloudflareScopes.published)) {
              Text("All published scopes are granted. This account may not include the product.")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              Button("Request all OAuth-enabled permissions") {
                model.requestAccess(to: Set(CloudflareScopes.published))
              }
            }
          }
        }
      }

      if let responseText {
        Section("Response") {
          ScrollView(.horizontal) {
            Text(responseText)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }
      }
    }
    .navigationTitle(endpoint.id)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Done") { dismiss() }
      }
    }
    .confirmationDialog(
      "Run \(endpoint.method) request?",
      isPresented: $confirmsMutation,
      titleVisibility: .visible
    ) {
      Button("Run \(endpoint.method)", role: endpoint.method == "DELETE" ? .destructive : nil) {
        Task { await run() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(endpoint.path)
    }
    .task { prefillKnownIdentifiers() }
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
      responseText =
        rendered.count > 100_000
        ? String(rendered.prefix(100_000)) + "\n\n…response truncated for display"
        : rendered
    } catch {
      self.error = error
    }
    isRunning = false
  }
}

private struct APIRequestInputError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
