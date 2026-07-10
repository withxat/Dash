import CloudflareAPI
import SwiftUI

/// One curated row on a hub screen, resolved to a concrete destination.
struct HubRowItem: Identifiable {
  let title: String
  let subtitle: String
  let icon: String
  let destination: Destination
  var id: String { title }
}

/// Which zone-scoped destination a feature's zone picker pushes.
func zoneDestination(for feature: FeatureID, zoneID: String, zoneName: String) -> Destination {
  switch feature {
  case .dnsManagement:
    return .dns(zoneID)
  default:
    return .zoneFeatureHub(feature: feature, zoneID: zoneID, zoneName: zoneName)
  }
}

/// Curated hub for products whose surface is a handful of sibling resource
/// lists (Calls, Zero Trust connectors, Workers observability, DNS
/// management). Each row pushes a generic resource list or another
/// destination; writes come from the capability registry.
struct FeatureHubView: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID

  private var rows: [HubRowItem] {
    let account = model.activeAccountID ?? ""
    func list(_ title: String, _ subtitle: String, _ icon: String, _ path: String) -> HubRowItem {
      HubRowItem(
        title: title, subtitle: subtitle, icon: icon,
        destination: .zoneTool(
          zoneID: "", title: title,
          path: path.replacingOccurrences(of: "{account}", with: account)))
    }
    switch feature {
    case .calls:
      return [
        list(
          "Apps", "SFU applications and tokens", SolarAsset.video,
          "/accounts/{account}/calls/apps"),
        list(
          "TURN keys", "Credentials for TURN service", SolarAsset.key,
          "/accounts/{account}/calls/turn_keys"),
        list(
          "MoQ relays", "Media over QUIC relays", SolarAsset.routing,
          "/accounts/{account}/moq/relays"),
      ]
    case .zeroTrustConnectors:
      return [
        list(
          "Tunnels", "Cloudflare Tunnel (cloudflared)", SolarAsset.routing,
          "/accounts/{account}/cfd_tunnel"),
        list(
          "WARP connectors", "Site-to-site WARP tunnels", SolarAsset.shield,
          "/accounts/{account}/warp_connector"),
        list(
          "Network routes", "Private network CIDR routes", SolarAsset.branching,
          "/accounts/{account}/teamnet/routes"),
        list(
          "Virtual networks", "Segmented private networks", SolarAsset.globus,
          "/accounts/{account}/teamnet/virtual_networks"),
      ]
    case .workersObservability:
      return [
        list(
          "Saved queries", "Stored telemetry queries", SolarAsset.search,
          "/accounts/{account}/workers/observability/queries"),
        list(
          "Destinations", "Telemetry export destinations", SolarAsset.upload,
          "/accounts/{account}/workers/observability/destinations"),
      ]
    case .dnsManagement:
      return [
        HubRowItem(
          title: "Zone DNS records", subtitle: "Browse and edit records per zone",
          icon: SolarAsset.globe, destination: .zonePicker(.dnsManagement)),
        list(
          "DNS views", "Internal DNS views", SolarAsset.pinList,
          "/accounts/{account}/dns_settings/views"),
      ]
    default:
      return []
    }
  }

  var body: some View {
    HubRowsScreen(rows: rows)
      .navigationTitle(feature.title)
      .navigationBarTitleDisplayMode(.inline)
  }
}

/// Hub of zone-scoped resource lists, reached through the zone picker.
struct ZoneFeatureHubView: View {
  let feature: FeatureID
  let zoneID: String
  let zoneName: String

  private var rows: [HubRowItem] {
    func list(_ title: String, _ subtitle: String, _ icon: String, _ path: String) -> HubRowItem {
      HubRowItem(
        title: title, subtitle: subtitle, icon: icon,
        destination: .zoneTool(zoneID: zoneID, title: title, path: path))
    }
    switch feature {
    case .sslCertificates:
      return [
        list(
          "Certificate packs", "Edge certificates for this zone", SolarAsset.shieldCheck,
          "/zones/{zone}/ssl/certificate_packs?status=all"),
        list(
          "Custom hostnames", "SSL for SaaS hostnames", SolarAsset.globus,
          "/zones/{zone}/custom_hostnames"),
        list(
          "Custom certificates", "Uploaded certificates", SolarAsset.key,
          "/zones/{zone}/custom_certificates"),
      ]
    case .apiSecurity:
      return [
        list(
          "Operations", "API Shield endpoint inventory", SolarAsset.code,
          "/zones/{zone}/api_gateway/operations"),
        list(
          "Discovered operations", "Endpoints found by API Discovery", SolarAsset.search,
          "/zones/{zone}/api_gateway/discovery/operations"),
        list(
          "Page Shield scripts", "Scripts observed on your pages", SolarAsset.file,
          "/zones/{zone}/page_shield/scripts"),
        list(
          "Page Shield policies", "Content security policies", SolarAsset.shield,
          "/zones/{zone}/page_shield/policies"),
      ]
    default:
      return []
    }
  }

  var body: some View {
    HubRowsScreen(rows: rows)
      .navigationTitle(zoneName)
      .navigationBarTitleDisplayMode(.inline)
  }
}

private struct HubRowsScreen: View {
  let rows: [HubRowItem]

  var body: some View {
    DashFeatureScreen {
      ScrollView {
        LazyVStack(spacing: DashTheme.Spacing.section) {
          DashListCard {
            DashListCardRows(items: rows) { row in
              DashListGroupLink(value: row.destination) {
                DashListRow(title: row.title, subtitle: row.subtitle, icon: row.icon)
              }
            }
          }
        }
        .padding(.horizontal, DashTheme.Spacing.screen)
        .padding(.bottom, DashTheme.Spacing.section)
      }
    }
  }
}

/// Zone list that routes into a feature's zone-scoped surface.
struct FeatureZonePickerView: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID
  @State private var zones: [CloudflareZone] = []
  @State private var loading = true
  @State private var error: String?
  @State private var search = ""

  private var filtered: [CloudflareZone] {
    guard !search.isEmpty else { return zones }
    return zones.filter { $0.name.localizedCaseInsensitiveContains(search) }
  }

  var body: some View {
    DashFeatureList(
      search: $search,
      prompt: "Search zones",
      isLoading: loading,
      error: error,
      retry: { Task { await load() } }
    ) {
      if filtered.isEmpty {
        DashEmptyState(
          icon: SolarAsset.search,
          title: search.isEmpty ? "No zones" : "Nothing found",
          message: search.isEmpty
            ? "Cloudflare returned no zones for this account."
            : "No zone matches \(search)."
        )
      } else {
        DashListCard {
          DashListCardRows(items: filtered) { zone in
            DashListGroupLink(
              value: zoneDestination(for: feature, zoneID: zone.id, zoneName: zone.name)
            ) {
              DashListRow(
                title: zone.name,
                subtitle: zone.status ?? "unknown",
                icon: SolarAsset.globe
              )
            }
          }
        }
      }
    }
    .navigationTitle("Choose a zone")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.zones(accountID)
    if !force, let cached: [CloudflareZone] = model.featureCache.get(key) {
      zones = cached
      loading = false
      error = nil
      return
    }
    if zones.isEmpty { loading = true }
    error = nil
    do {
      zones = try await model.client.listZones(accountID: accountID).items
      model.featureCache.set(key, zones)
    } catch {
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}
