import CloudflareAPI
import SwiftUI

private func permissionHint(for error: Error) -> String {
  guard let apiError = error as? CloudflareAPIError, apiError.isPermissionDenied else {
    return error.dashActionableMessage
  }
  return
    (apiError.errorDescription ?? "Permission denied")
    + "\n\nEnable the required OAuth scope on your Cloudflare app and sign in again."
}

/// Cloudflare answers 403 for both a missing OAuth scope and a product that was
/// never activated on the account. When every read scope is already granted,
/// the product itself is the missing piece.
@MainActor
private func isMissingEntitlement(_ error: Error, feature: FeatureID, model: AppModel) -> Bool {
  guard let apiError = error as? CloudflareAPIError, apiError.isPermissionDenied,
    let granted = model.grantedScopes
  else { return false }
  return feature.capability.read.isSubset(of: granted)
}

private struct ProductNotActivatedView: View {
  @Environment(\.openURL) private var openURL
  let feature: FeatureID
  let icon: String
  let accountID: String?
  let dashboardPath: String

  var body: some View {
    DashEmptyState(
      icon: icon,
      title: "\(feature.title) isn’t activated",
      message:
        "This Cloudflare account hasn’t activated \(feature.title) yet. Choose a plan in the Cloudflare dashboard, then pull to refresh.",
      actionTitle: "Open Cloudflare Dashboard",
      action: {
        guard let accountID,
          let url = URL(string: "https://dash.cloudflare.com/\(accountID)/\(dashboardPath)")
        else { return }
        openURL(url)
      }
    )
  }
}

struct ImagesView: View {
  @Environment(AppModel.self) private var model
  @State private var images: [CloudflareImage] = []
  @State private var selected: CloudflareImage?
  @State private var error: String?
  @State private var loading = true
  @State private var notActivated = false
  @State private var deleting = false
  @State private var deleteError: String?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load() } }
    ) {
      if notActivated {
        ProductNotActivatedView(
          feature: .images,
          icon: SolarAsset.gallery,
          accountID: model.activeAccountID,
          dashboardPath: "images"
        )
      } else if images.isEmpty {
        DashEmptyState(
          icon: SolarAsset.gallery,
          title: "No images",
          message: "Cloudflare Images returned no assets for this account."
        )
      } else {
        DashListCard {
          DashListCardRows(items: images) { image in
            Button {
              deleteError = nil
              selected = image
            } label: {
              DashListRow(
                title: image.name,
                subtitle: image.uploaded,
                icon: SolarAsset.gallery,
                trailing: image.requireSignedURLs == true ? "Signed" : nil,
                showsChevron: false
              )
            }
            .buttonStyle(DashPressButtonStyle())
          }
        }
      }
    }
    .dashTray(
      item: $selected,
      title: { $0.name },
      content: { image in
        DashDetailTray(
          fields: image.detailFields,
          deleteMessage: "Permanently delete \(image.name) from Cloudflare Images.",
          isDeleting: deleting,
          deleteError: deleteError,
          onDelete: { Task { await delete(image) } }
        )
      }
    )
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func delete(_ image: CloudflareImage) async {
    guard let accountID = model.activeAccountID else { return }
    deleting = true
    deleteError = nil
    do {
      _ = try await model.client.mutate(
        path: "/accounts/\(accountID)/images/v1/\(image.id)", method: "DELETE")
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      selected = nil
      model.featureCache.remove(FeatureCacheKey.images(accountID))
      await load(force: true)
    } catch {
      deleteError = error.dashActionableMessage
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    deleting = false
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
    notActivated = false
    do {
      images = try await model.client.listImages(accountID: accountID)
      model.featureCache.set(key, images)
    } catch {
      if isMissingEntitlement(error, feature: .images, model: model) {
        notActivated = true
      } else {
        self.error = permissionHint(for: error)
      }
    }
    loading = false
  }
}

struct StreamView: View {
  @Environment(AppModel.self) private var model
  @State private var videos: [StreamVideo] = []
  @State private var selected: StreamVideo?
  @State private var error: String?
  @State private var loading = true
  @State private var notActivated = false
  @State private var deleting = false
  @State private var deleteError: String?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      retry: { Task { await load() } }
    ) {
      if notActivated {
        ProductNotActivatedView(
          feature: .stream,
          icon: SolarAsset.video,
          accountID: model.activeAccountID,
          dashboardPath: "stream/plans"
        )
      } else if videos.isEmpty {
        DashEmptyState(
          icon: SolarAsset.video,
          title: "No videos",
          message: "Stream returned no videos for this account."
        )
      } else {
        DashListCard {
          DashListCardRows(items: videos) { video in
            Button {
              deleteError = nil
              selected = video
            } label: {
              DashListRow(
                title: video.name,
                subtitle: video.created,
                icon: SolarAsset.video,
                showsChevron: false
              )
            }
            .buttonStyle(DashPressButtonStyle())
          }
        }
      }
    }
    .dashTray(
      item: $selected,
      title: { $0.name },
      content: { video in
        DashDetailTray(
          fields: video.detailFields,
          deleteMessage: "Permanently delete \(video.name) from Stream.",
          isDeleting: deleting,
          deleteError: deleteError,
          onDelete: { Task { await delete(video) } }
        )
      }
    )
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func delete(_ video: StreamVideo) async {
    guard let accountID = model.activeAccountID else { return }
    deleting = true
    deleteError = nil
    do {
      _ = try await model.client.mutate(
        path: "/accounts/\(accountID)/stream/\(video.uid)", method: "DELETE")
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      selected = nil
      model.featureCache.remove(FeatureCacheKey.stream(accountID))
      await load(force: true)
    } catch {
      deleteError = error.dashActionableMessage
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    deleting = false
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
    notActivated = false
    do {
      videos = try await model.client.listStreamVideos(accountID: accountID)
      model.featureCache.set(key, videos)
    } catch {
      if isMissingEntitlement(error, feature: .stream, model: model) {
        notActivated = true
      } else {
        self.error = permissionHint(for: error)
      }
    }
    loading = false
  }
}

struct AnalyticsView: View {
  @Environment(AppModel.self) private var model
  @State private var sites: [RumSite] = []
  @State private var selected: RumSite?
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
            Button {
              selected = site
            } label: {
              DashListRow(
                title: site.name,
                subtitle: site.siteTag,
                icon: SolarAsset.chart,
                showsChevron: false
              )
            }
            .buttonStyle(DashPressButtonStyle())
          }
        }
      }
    }
    .dashTray(
      item: $selected,
      title: { $0.name },
      content: { DashDetailTray(fields: $0.detailFields) }
    )
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

/// One selected account row, across the tab's four resource types, so a single
/// detail tray can render whichever the user tapped.
private enum AccountDetailItem: Identifiable, Equatable {
  case member(AccountMember)
  case policy(NotificationPolicy)
  case history(NotificationHistoryEntry)
  case audit(AuditLogEntry)

  var id: String {
    switch self {
    case .member(let value): "member-\(value.id)"
    case .policy(let value): "policy-\(value.id)"
    case .history(let value): "history-\(value.id)"
    case .audit(let value): "audit-\(value.id)"
    }
  }

  var trayTitle: String {
    switch self {
    case .member(let value): value.displayName
    case .policy(let value): value.title
    case .history(let value): value.title
    case .audit(let value): value.title
    }
  }

  var fields: [DashDetailField] {
    switch self {
    case .member(let value): value.detailFields
    case .policy(let value): value.detailFields
    case .history(let value): value.detailFields
    case .audit(let value): value.detailFields
    }
  }
}

struct AccountView: View {
  private enum Tab: Hashable { case members, alerts, audit }

  @Environment(AppModel.self) private var model
  @State private var members: [AccountMember] = []
  @State private var policies: [NotificationPolicy] = []
  @State private var history: [NotificationHistoryEntry] = []
  @State private var auditLogs: [AuditLogEntry] = []
  @State private var detail: AccountDetailItem?
  @State private var error: String?
  @State private var loading = true
  @State private var selectedTab: Tab = .members
  @State private var togglingPolicy = false
  @State private var toggleError: String?
  @State private var deletingPolicy = false
  @State private var deletePolicyError: String?

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
              Button {
                detail = .member(member)
              } label: {
                DashListRow(
                  title: member.displayName,
                  subtitle: member.user?.email ?? member.roleSummary,
                  icon: SolarAsset.users,
                  showsChevron: false
                )
              }
              .buttonStyle(DashPressButtonStyle())
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
              Button {
                toggleError = nil
                deletePolicyError = nil
                detail = .policy(policy)
              } label: {
                DashListRow(
                  title: policy.title,
                  subtitle: policy.enabled == false ? "Disabled" : nil,
                  icon: SolarAsset.bolt,
                  showsChevron: false
                )
              }
              .buttonStyle(DashPressButtonStyle())
            }
            if !policies.isEmpty && !history.isEmpty {
              DashListGroupDivider()
            }
            DashListCardRows(items: history) { entry in
              Button {
                detail = .history(entry)
              } label: {
                DashListRow(
                  title: entry.title,
                  subtitle: entry.subtitle,
                  icon: SolarAsset.clock,
                  showsChevron: false
                )
              }
              .buttonStyle(DashPressButtonStyle())
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
              Button {
                detail = .audit(entry)
              } label: {
                DashListRow(
                  title: entry.title,
                  subtitle: entry.subtitle,
                  icon: SolarAsset.shieldCheck,
                  showsChevron: false
                )
              }
              .buttonStyle(DashPressButtonStyle())
            }
          }
        }
      }
    }
    .dashTray(
      item: $detail,
      title: { $0.trayTitle },
      content: { item in
        if case .policy(let policy) = item {
          DashDetailTray(
            fields: policy.detailFields,
            deleteMessage: "Permanently delete the policy \(policy.title).",
            isDeleting: deletingPolicy,
            deleteError: deletePolicyError,
            onDelete: { Task { await deletePolicy(policy) } }
          ) {
            VStack(spacing: 10) {
              DashTrayPillButton(
                title: policy.enabled == false ? "Enable policy" : "Disable policy",
                isLoading: togglingPolicy
              ) {
                Task { await toggle(policy) }
              }
              if let toggleError {
                DashNotice(kind: .error, message: toggleError)
              }
            }
          }
        } else {
          DashDetailTray(fields: item.fields)
        }
      }
    )
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func deletePolicy(_ policy: NotificationPolicy) async {
    guard let accountID = model.activeAccountID else { return }
    deletingPolicy = true
    deletePolicyError = nil
    do {
      _ = try await model.client.mutate(
        path: "/accounts/\(accountID)/alerting/v3/policies/\(policy.id)", method: "DELETE")
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      detail = nil
      model.featureCache.remove(FeatureCacheKey.accountSnapshot(accountID))
      await load(force: true)
    } catch {
      deletePolicyError = error.dashActionableMessage
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    deletingPolicy = false
  }

  private func toggle(_ policy: NotificationPolicy) async {
    guard let accountID = model.activeAccountID else { return }
    togglingPolicy = true
    toggleError = nil
    do {
      _ = try await model.client.mutate(
        path: "/accounts/\(accountID)/alerting/v3/policies/\(policy.id)", method: "PUT",
        body: ["enabled": .bool(!(policy.enabled ?? true))])
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      detail = nil
      model.featureCache.remove(FeatureCacheKey.accountSnapshot(accountID))
      await load(force: true)
    } catch { toggleError = error.dashActionableMessage }
    togglingPolicy = false
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
