import CloudflareAPI
import SwiftUI

private func permissionHint(for error: Error) -> String {
  guard let apiError = error as? CloudflareAPIError, apiError.isPermissionDenied else {
    return error.localizedDescription
  }
  return
    (apiError.errorDescription ?? "Permission denied")
    + "\n\nEnable the required OAuth scope on your Cloudflare app and sign in again."
}

struct ImagesView: View {
  @Environment(AppModel.self) private var model
  @State private var images: [CloudflareImage] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load() } }
    ) {
      if images.isEmpty {
        DashEmptyState(
          icon: SolarAsset.gallery,
          title: "No images",
          message: "Cloudflare Images returned no assets for this account."
        )
      } else {
        DashListCard {
          DashListCardRows(items: images) { image in
            DashListRow(
              title: image.name,
              subtitle: image.uploaded,
              icon: SolarAsset.gallery,
              trailing: image.requireSignedURLs == true ? "Signed" : nil,
              showsChevron: false
            )
          }
        }
      }
    }
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.images(accountID)
    if !force, let cached: [CloudflareImage] = model.featureCache.get(key) {
      images = cached
      loading = false
      error = nil
      return
    }
    if images.isEmpty { loading = true }
    error = nil
    do {
      images = try await model.client.listImages(accountID: accountID)
      model.featureCache.set(key, images)
    } catch {
      self.error = permissionHint(for: error)
    }
    loading = false
  }
}

struct StreamView: View {
  @Environment(AppModel.self) private var model
  @State private var videos: [StreamVideo] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load() } }
    ) {
      if videos.isEmpty {
        DashEmptyState(
          icon: SolarAsset.video,
          title: "No videos",
          message: "Stream returned no videos for this account."
        )
      } else {
        DashListCard {
          DashListCardRows(items: videos) { video in
            DashListRow(
              title: video.name,
              subtitle: video.created,
              icon: SolarAsset.video,
              showsChevron: false
            )
          }
        }
      }
    }
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.stream(accountID)
    if !force, let cached: [StreamVideo] = model.featureCache.get(key) {
      videos = cached
      loading = false
      error = nil
      return
    }
    if videos.isEmpty { loading = true }
    error = nil
    do {
      videos = try await model.client.listStreamVideos(accountID: accountID)
      model.featureCache.set(key, videos)
    } catch {
      self.error = permissionHint(for: error)
    }
    loading = false
  }
}

struct AnalyticsView: View {
  @Environment(AppModel.self) private var model
  @State private var sites: [RumSite] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load() } }
    ) {
      if sites.isEmpty {
        DashEmptyState(
          icon: SolarAsset.chart,
          title: "No analytics sites",
          message: "No RUM sites are configured on this account."
        )
      } else {
        DashListGroup(title: "RUM sites") {
          DashListCardRows(items: sites) { site in
            DashListRow(
              title: site.name,
              subtitle: site.siteTag,
              icon: SolarAsset.chart,
              showsChevron: false
            )
          }
        }
      }
    }
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.rumSites(accountID)
    if !force, let cached: [RumSite] = model.featureCache.get(key) {
      sites = cached
      loading = false
      error = nil
      return
    }
    if sites.isEmpty { loading = true }
    error = nil
    do {
      sites = try await model.client.listRumSites(accountID: accountID)
      model.featureCache.set(key, sites)
    } catch {
      self.error = permissionHint(for: error)
    }
    loading = false
  }
}

struct AccountView: View {
  private enum Tab: Hashable { case members, alerts, audit }

  @Environment(AppModel.self) private var model
  @State private var members: [AccountMember] = []
  @State private var policies: [NotificationPolicy] = []
  @State private var history: [NotificationHistoryEntry] = []
  @State private var auditLogs: [AuditLogEntry] = []
  @State private var error: String?
  @State private var loading = true
  @State private var selectedTab: Tab = .members

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load() } },
      header: {
        DashTextTabs(
          items: [("Members", Tab.members), ("Alerts", Tab.alerts), ("Audit", Tab.audit)],
          selection: $selectedTab
        )
      }
    ) {
      switch selectedTab {
      case .members:
        if members.isEmpty {
          DashEmptyState(
            icon: SolarAsset.users,
            title: "No members",
            message: "No account members were returned."
          )
        } else {
          DashListCard {
            DashListCardRows(items: members) { member in
              DashListRow(
                title: member.displayName,
                subtitle: member.user?.email ?? member.roleSummary,
                icon: SolarAsset.users,
                showsChevron: false
              )
            }
          }
        }
      case .alerts:
        if policies.isEmpty && history.isEmpty {
          DashEmptyState(
            icon: SolarAsset.bolt,
            title: "No alerts",
            message: "Notification policies and recent alerts will appear here."
          )
        } else {
          DashListCard {
            DashListCardRows(items: policies) { policy in
              DashListRow(title: policy.title, icon: SolarAsset.bolt, showsChevron: false)
            }
            if !policies.isEmpty && !history.isEmpty {
              DashListGroupDivider()
            }
            DashListCardRows(items: history) { entry in
              DashListRow(
                title: entry.title,
                subtitle: entry.subtitle,
                icon: SolarAsset.clock,
                showsChevron: false
              )
            }
          }
        }
      case .audit:
        if auditLogs.isEmpty {
          DashEmptyState(
            icon: SolarAsset.shieldCheck,
            title: "No audit events",
            message: "Recent account activity will appear here."
          )
        } else {
          DashListCard {
            DashListCardRows(items: auditLogs) { entry in
              DashListRow(
                title: entry.title,
                subtitle: entry.subtitle,
                icon: SolarAsset.shieldCheck,
                showsChevron: false
              )
            }
          }
        }
      }
    }
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func load(force: Bool = false) async {
    guard let accountID = model.activeAccountID else { return }
    let key = FeatureCacheKey.accountSnapshot(accountID)
    if !force, let cached: AccountFeatureSnapshot = model.featureCache.get(key) {
      members = cached.members
      policies = cached.policies
      history = cached.history
      auditLogs = cached.auditLogs
      loading = false
      error = nil
      return
    }
    if members.isEmpty && policies.isEmpty && history.isEmpty && auditLogs.isEmpty {
      loading = true
    }
    error = nil
    var failures: [String] = []

    do { members = try await model.client.listAccountMembers(accountID: accountID).items } catch {
      failures.append(permissionHint(for: error))
    }
    do { policies = try await model.client.listNotificationPolicies(accountID: accountID) } catch {
      failures.append(permissionHint(for: error))
    }
    do { history = try await model.client.listNotificationHistory(accountID: accountID) } catch {
      failures.append(permissionHint(for: error))
    }
    do { auditLogs = try await model.client.listAuditLogs(accountID: accountID) } catch {
      failures.append(permissionHint(for: error))
    }

    if members.isEmpty && policies.isEmpty && history.isEmpty && auditLogs.isEmpty {
      error = failures.first
    } else {
      model.featureCache.set(
        key,
        AccountFeatureSnapshot(
          members: members, policies: policies, history: history, auditLogs: auditLogs))
    }
    loading = false
  }
}
