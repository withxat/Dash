import CloudflareAPI
import SwiftUI

/// Curated hub for products whose surface is a handful of sibling resource
/// lists (Calls, Zero Trust connectors, Workers observability). Each row
/// pushes a generic resource list; writes come from the capability registry.
struct FeatureHubView: View {
  @Environment(AppModel.self) private var model
  let feature: FeatureID

  private struct HubRow: Identifiable {
    let title: String
    let subtitle: String
    let icon: String
    /// Account-scoped REST path with `{account}` placeholder.
    let path: String
    var id: String { path }
  }

  private var rows: [HubRow] {
    switch feature {
    case .calls:
      return [
        HubRow(
          title: "Apps", subtitle: "SFU applications and tokens",
          icon: SolarAsset.video, path: "/accounts/{account}/calls/apps"),
        HubRow(
          title: "TURN keys", subtitle: "Credentials for TURN service",
          icon: SolarAsset.key, path: "/accounts/{account}/calls/turn_keys"),
        HubRow(
          title: "MoQ relays", subtitle: "Media over QUIC relays",
          icon: SolarAsset.routing, path: "/accounts/{account}/moq/relays"),
      ]
    case .zeroTrustConnectors:
      return [
        HubRow(
          title: "Tunnels", subtitle: "Cloudflare Tunnel (cloudflared)",
          icon: SolarAsset.routing, path: "/accounts/{account}/cfd_tunnel"),
        HubRow(
          title: "WARP connectors", subtitle: "Site-to-site WARP tunnels",
          icon: SolarAsset.shield, path: "/accounts/{account}/warp_connector"),
        HubRow(
          title: "Network routes", subtitle: "Private network CIDR routes",
          icon: SolarAsset.branching, path: "/accounts/{account}/teamnet/routes"),
        HubRow(
          title: "Virtual networks", subtitle: "Segmented private networks",
          icon: SolarAsset.globus, path: "/accounts/{account}/teamnet/virtual_networks"),
      ]
    case .workersObservability:
      return [
        HubRow(
          title: "Saved queries", subtitle: "Stored telemetry queries",
          icon: SolarAsset.search, path: "/accounts/{account}/workers/observability/queries"),
        HubRow(
          title: "Destinations", subtitle: "Telemetry export destinations",
          icon: SolarAsset.upload,
          path: "/accounts/{account}/workers/observability/destinations"),
      ]
    default:
      return []
    }
  }

  var body: some View {
    DashFeatureScreen {
      ScrollView {
        LazyVStack(spacing: DashTheme.Spacing.section) {
          DashListCard {
            DashListCardRows(items: rows) { row in
              DashListGroupLink(
                value: .zoneTool(zoneID: "", title: row.title, path: resolved(row.path))
              ) {
                DashListRow(title: row.title, subtitle: row.subtitle, icon: row.icon)
              }
            }
          }
        }
        .padding(.horizontal, DashTheme.Spacing.screen)
        .padding(.bottom, DashTheme.Spacing.section)
      }
    }
    .navigationTitle(feature.title)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func resolved(_ path: String) -> String {
    path.replacingOccurrences(of: "{account}", with: model.activeAccountID ?? "")
  }
}
