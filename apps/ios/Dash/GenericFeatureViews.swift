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
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load() } }
    ) {
      if resources.isEmpty {
        DashEmptyState(
          icon: SolarAsset.inbox,
          title: "Nothing here yet",
          message: "Cloudflare returned no resources for this account."
        )
      } else {
        DashListCard {
          DashListCardRows(items: resources) { resource in
            DashListRow(
              title: resource.name,
              subtitle: resource.detail,
              icon: SolarAsset.cloud,
              showsChevron: false
            )
          }
        }
      }
    }
    .refreshable { await load(force: true) }.task { await load() }
  }

  private func load(force: Bool = false) async {
    let key = FeatureCacheKey.generic(path: path)
    if !force, let cached: [GenericResource] = model.featureCache.get(key) {
      resources = cached
      loading = false
      error = nil
      return
    }
    if resources.isEmpty { loading = true }
    error = nil
    do {
      let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
      var query: [String: String?] = [:]
      if parts.count == 2, let queryItems = URLComponents(string: "?\(parts[1])")?.queryItems {
        for item in queryItems { query[item.name] = item.value }
      }
      resources = try await model.client.listResources(path: parts[0], query: query).items
      model.featureCache.set(key, resources)
    } catch {
      if let apiError = error as? CloudflareAPIError, apiError.isPermissionDenied {
        self.error =
          (apiError.errorDescription ?? "Permission denied")
          + "\n\nEnable the required OAuth scope on your Cloudflare app and sign in again."
      } else {
        self.error = error.localizedDescription
      }
    }
    loading = false
  }
}
