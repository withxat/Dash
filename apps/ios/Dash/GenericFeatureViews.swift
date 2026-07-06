import CloudflareAPI
import SwiftUI

struct GenericFeatureView: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID
  var body: some View {
    GenericResourcesView(title: feature.title, path: path)
  }

  private var path: String {
    let account = model.activeAccountID ?? ""
    return switch feature {
    case .queues: "/accounts/\(account)/queues"
    case .vectorize: "/accounts/\(account)/vectorize/v2/indexes"
    case .secrets: "/accounts/\(account)/secrets_store/stores"
    case .turnstile: "/accounts/\(account)/challenges/widgets"
    case .accessApps: "/accounts/\(account)/access/apps"
    case .emailAddresses: "/accounts/\(account)/email/routing/addresses"
    case .registrar: "/accounts/\(account)/registrar/domains"
    case .tunnels: "/accounts/\(account)/cfd_tunnel"
    case .loadBalancerPools: "/accounts/\(account)/load_balancers/pools"
    case .images: "/accounts/\(account)/images/v1"
    case .stream: "/accounts/\(account)/stream"
    case .analytics: "/accounts/\(account)/rum/site_info/list"
    case .account: "/accounts/\(account)/members"
    default: "/accounts/\(account)"
    }
  }
}

struct GenericResourcesView: View {
  @Environment(AppModel.self) private var model
  let title: String
  let path: String
  @State private var resources: [GenericResource] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    List {
      if loading {
        LoadingStateView().listRowBackground(Color.clear)
      } else if let error {
        ErrorStateView(message: error) { Task { await load() } }.listRowBackground(Color.clear)
      } else if resources.isEmpty {
        ContentUnavailableView(
          "Nothing here yet", systemImage: "tray",
          description: Text("Cloudflare returned no resources for this account.")
        ).listRowBackground(Color.clear)
      } else {
        ForEach(resources) { resource in
          HStack {
            Image(systemName: "cloud").foregroundStyle(DashTheme.brand)
            VStack(alignment: .leading) {
              Text(resource.name)
              if let detail = resource.detail {
                Text(detail).font(.caption).foregroundStyle(DashTheme.subtle)
              }
            }
            Spacer()
          }
        }
      }
    }
    .dashGroupedList()
    .navigationTitle(title).refreshable { await load() }.task { await load() }
  }

  private func load() async {
    loading = true
    error = nil
    do {
      let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
      var query: [String: String?] = [:]
      if parts.count == 2, let queryItems = URLComponents(string: "?\(parts[1])")?.queryItems {
        for item in queryItems { query[item.name] = item.value }
      }
      resources = try await model.client.listResources(path: parts[0], query: query).items
    } catch { self.error = error.localizedDescription }
    loading = false
  }
}
