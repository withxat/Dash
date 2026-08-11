import CloudflareAPI
import GradientAvatars
import SwiftUI
import UIKit

// MARK: - Destination routing

struct DestinationRoutedContent: View {
  @Environment(AppModel.self) private var model
  let destination: Destination

  private var allowsWrites: Bool {
    let scopes = writeScopes(for: destination)
    return scopes.isEmpty || model.hasScopes(scopes)
  }

  var body: some View {
    Group {
      switch destination {
      case .profile: ProfileView()
      case .settings: SettingsView()
      case .settingsAccounts: SettingsAccountsView()
      case .about: AboutView()
      case .openSource: OpenSourceView()
      case .feature(let feature):
        FeatureRouterContent(feature: feature)
      case .zone(let id): ZoneDetailView(zoneID: id)
      case .dns(let id): DNSRecordsView(zoneID: id)
      case .cache(let id): ZoneCacheView(zoneID: id)
      case .zoneAnalytics(let id): ZoneAnalyticsView(zoneID: id)
      case .zoneWebAnalytics(let id): WebAnalyticsView(zoneID: id)
      case .zoneWAF(let id): WAFEventsView(zoneID: id)
      case .zoneSettings(let id): ZoneSettingsView(zoneID: id)
      case .zoneEmailRouting(let id): EmailRoutingView(zoneID: id)
      case .auditLogs: AuditLogView()
      case .watchtowerInbox: WatchtowerInboxView()
      case .cloudflareStatus: CloudflareStatusView()
      case .emailAddresses: EmailDestinationAddressesView()
      case .registrarDomain(let domain): RegistrarDomainDetailView(domain: domain)
      case .chartDetail(let detail): DashChartDetailView(detail: detail)
      case .worker(let name): WorkerDetailView(name: name)
      case .tunnel(let id): TunnelDetailView(tunnelID: id)
      case .pagesProject(let name): PagesProjectDetailView(projectName: name)
      case .pagesDeployment(let project, let deploymentID):
        PagesDeploymentDetailView(projectName: project, deploymentID: deploymentID)
      case .pagesDomains(let name): PagesDomainsView(projectName: name)
      case .r2Bucket(let name, let prefix): R2BucketView(bucket: name, folderPrefix: prefix)
      case .r2BucketSettings(let name): R2BucketSettingsView(bucket: name)
      case .kvNamespace(let id): KVNamespaceView(namespaceID: id)
      case .kvKey(let namespaceID, let key):
        KVKeyDetailView(namespaceID: namespaceID, key: key)
      }
    }
    .environment(\.featureAllowsWrites, allowsWrites)
    .environment(\.featureRequiredScopes, readScopes(for: destination))
    .environment(\.featureIdentity, featureID(for: destination))
  }
}
