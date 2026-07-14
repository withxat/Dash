import CloudflareAPI
import PhotosUI
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
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @State private var images: [CloudflareImage] = []
  @State private var selected: CloudflareImage?
  @State private var error: String?
  @State private var loading = true
  @State private var notActivated = false
  @State private var deleting = false
  @State private var deleteError: String?
  @State private var pickedItem: PhotosPickerItem?
  @State private var uploading = false
  @State private var uploadError: String?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !images.isEmpty,
      retry: { Task { await load() } }
    ) {
      if uploading {
        DashNotice(kind: .success, message: "Uploading image…")
      }
      if let uploadError {
        DashNotice(kind: .error, message: uploadError)
      }
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
    .toolbar {
      if featureAllowsWrites, !notActivated {
        ToolbarItem(placement: .topBarTrailing) {
          PhotosPicker(selection: $pickedItem, matching: .images) {
            SolarIcon(asset: SolarAsset.upload, size: 20, color: DashTheme.strong)
              .frame(width: 34, height: 34)
              .background(DashTheme.base, in: Circle())
              .overlay { Circle().stroke(DashTheme.line, lineWidth: 0.5) }
          }
          .accessibilityLabel("Upload image")
          .disabled(uploading)
        }
        .dashSeparateToolbarBackground()
      }
    }
    .onChange(of: pickedItem) { _, item in
      if let item { Task { await upload(item) } }
    }
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func upload(_ item: PhotosPickerItem) async {
    guard let accountID = model.activeAccountID else { return }
    uploading = true
    uploadError = nil
    do {
      guard let data = try await item.loadTransferable(type: Data.self) else {
        throw CloudflareAPIError.invalidResponse
      }
      let filename = "upload-\(UUID().uuidString.prefix(8)).jpg"
      _ = try await model.client.uploadImage(
        accountID: accountID, filename: filename, data: data)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      model.featureCache.remove(FeatureCacheKey.images(accountID))
      await load(force: true)
    } catch {
      uploadError = error.dashActionableMessage
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    pickedItem = nil
    uploading = false
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
  /// Documented ceiling for the Stream basic (multipart) upload path.
  static let basicUploadLimit = 200 * 1024 * 1024

  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @State private var videos: [StreamVideo] = []
  @State private var selected: StreamVideo?
  @State private var error: String?
  @State private var loading = true
  @State private var notActivated = false
  @State private var deleting = false
  @State private var deleteError: String?
  @State private var adds = false
  @State private var pickedItem: PhotosPickerItem?
  @State private var uploading = false
  @State private var uploadError: String?
  @State private var copyURL = ""
  @State private var copyName = ""

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !videos.isEmpty,
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
    .toolbar {
      if featureAllowsWrites, !notActivated {
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(asset: SolarAsset.upload, accessibilityLabel: "Add video") {
            uploadError = nil
            adds = true
          }
        }
        .dashSeparateToolbarBackground()
      }
    }
    .dashTray(isPresented: $adds, title: "Add video") {
      VStack(alignment: .leading, spacing: 16) {
        if uploading {
          DashNotice(kind: .success, message: "Uploading video…")
        }
        if let uploadError {
          DashNotice(kind: .error, message: uploadError)
        }
        // Built outside the picker's label closure, which isn't
        // main-actor-isolated and so can't construct the card itself.
        let pickerLabel = DashListCard {
          DashListRow(
            title: "Upload from library",
            subtitle: "Basic upload, files up to 200 MB",
            icon: SolarAsset.upload
          )
        }
        PhotosPicker(selection: $pickedItem, matching: .videos) { pickerLabel }
          .disabled(uploading)
        DashFormField(label: "…or import from URL", text: $copyURL, keyboard: .URL)
        DashFormField(label: "Name (optional)", text: $copyName)
        DashTrayPillButton(
          title: uploading ? "Working…" : "Import from URL",
          isLoading: uploading
        ) {
          guard !copyURL.isEmpty else { return }
          Task { await importFromURL() }
        }
      }
    }
    .onChange(of: pickedItem) { _, item in
      if let item { Task { await upload(item) } }
    }
    .refreshable { await load(force: true) }
    .task { await load() }
  }

  private func upload(_ item: PhotosPickerItem) async {
    guard let accountID = model.activeAccountID else { return }
    uploading = true
    uploadError = nil
    do {
      guard let data = try await item.loadTransferable(type: Data.self) else {
        throw CloudflareAPIError.invalidResponse
      }
      guard data.count <= Self.basicUploadLimit else {
        uploadError =
          "This video is over 200 MB; the basic upload path caps there. Use dash.cloudflare.com or tus for larger files."
        uploading = false
        pickedItem = nil
        return
      }
      let filename = "upload-\(UUID().uuidString.prefix(8)).mp4"
      _ = try await model.client.uploadStreamVideo(
        accountID: accountID, filename: filename, data: data)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      adds = false
      model.featureCache.remove(FeatureCacheKey.stream(accountID))
      await load(force: true)
    } catch {
      uploadError = error.dashActionableMessage
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    pickedItem = nil
    uploading = false
  }

  private func importFromURL() async {
    guard let accountID = model.activeAccountID else { return }
    uploading = true
    uploadError = nil
    do {
      _ = try await model.client.streamCopy(
        accountID: accountID, url: copyURL, name: copyName)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      copyURL = ""
      copyName = ""
      adds = false
      model.featureCache.remove(FeatureCacheKey.stream(accountID))
      await load(force: true)
    } catch {
      uploadError = error.dashActionableMessage
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    uploading = false
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
      hasContent: !sites.isEmpty,
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

/// Invite form: email plus one role picked from the account's role list.
private struct MemberInviteForm: View {
  @Environment(AppModel.self) private var model
  let onInvited: () -> Void

  @State private var email = ""
  @State private var roles: [AccountRole] = []
  @State private var roleName = ""
  @State private var loadingRoles = true
  @State private var saving = false
  @State private var saveError: String?

  var body: some View {
    DashFormSheet(
      saveTitle: "Invite",
      isSaving: saving,
      canSave: !email.isEmpty && selectedRole != nil,
      onSave: { Task { await invite() } },
      content: {
        VStack(alignment: .leading, spacing: 16) {
          if let saveError {
            DashNotice(kind: .error, message: saveError)
          }
          DashFormField(label: "Email address", text: $email, keyboard: .emailAddress)
          if loadingRoles {
            DashLoadingRing(color: DashTheme.brand).frame(maxWidth: .infinity)
          } else if roles.isEmpty {
            DashNotice(
              kind: .warning,
              message: "No roles could be loaded; inviting needs at least one role.")
          } else {
            DashFormMenuField(
              label: "Role", selection: $roleName, options: roles.map(\.name))
          }
        }
      }
    )
    .task { await loadRoles() }
  }

  private var selectedRole: AccountRole? {
    roles.first { $0.name == roleName }
  }

  private func loadRoles() async {
    guard let accountID = model.activeAccountID else { return }
    do {
      roles = try await model.client.listAccountRoles(accountID: accountID)
      if roleName.isEmpty {
        roleName =
          roles.first { $0.name.lowercased().contains("read") }?.name
          ?? roles.first?.name ?? ""
      }
    } catch {
      saveError = error.dashActionableMessage
    }
    loadingRoles = false
  }

  private func invite() async {
    guard let accountID = model.activeAccountID, let role = selectedRole else { return }
    saving = true
    saveError = nil
    do {
      _ = try await model.client.inviteAccountMember(
        accountID: accountID, email: email, roleIDs: [role.id])
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      onInvited()
    } catch {
      saveError = error.dashActionableMessage
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    saving = false
  }
}

/// Create an alert policy bound to a specific webhook by id (names are not
/// unique, so the menu renders labels while selection stores the id).
private struct AlertPolicyCreateForm: View {
  @Environment(AppModel.self) private var model
  let webhookID: String
  let onCreated: () -> Void

  @State private var name = ""
  @State private var alerts: [AvailableAlert] = []
  @State private var selectedType = ""
  @State private var loading = true
  @State private var saving = false
  @State private var saveError: String?

  var body: some View {
    DashFormSheet(
      saveTitle: "Create",
      isSaving: saving,
      canSave: !name.isEmpty && !selectedType.isEmpty,
      onSave: { Task { await create() } },
      content: {
        VStack(alignment: .leading, spacing: 16) {
          if let saveError {
            DashNotice(kind: .error, message: saveError)
          }
          DashFormField(label: "Policy name", text: $name)
          if loading {
            DashLoadingRing(color: DashTheme.brand).frame(maxWidth: .infinity)
          } else if alerts.isEmpty {
            DashNotice(
              kind: .warning,
              message: "No alert types were returned for this account.")
          } else {
            alertTypeMenu
          }
          Text(
            "Delivers through your Dash webhook. Alert text is forwarded via dash.xat.sh to this iPhone."
          )
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.subtle)
        }
      }
    )
    .task { await loadAlerts() }
  }

  private var alertTypeMenu: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Alert type")
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      Menu {
        Picker("Alert type", selection: $selectedType) {
          ForEach(alerts) { alert in
            Text(alert.title).tag(alert.type ?? "")
          }
        }
      } label: {
        HStack(spacing: 8) {
          Text(selectedLabel)
            .dashTextStyle(.bodyMedium)
            .foregroundStyle(DashTheme.text)
          Spacer(minLength: 0)
          SolarIcon(asset: SolarAsset.chevronRight, size: 14, color: DashTheme.placeholder)
            .rotationEffect(.degrees(90))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashTheme.recessed)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
      }
    }
  }

  private var selectedLabel: String {
    alerts.first { $0.type == selectedType }?.title ?? "Choose an alert type"
  }

  private func loadAlerts() async {
    guard let accountID = model.activeAccountID else { return }
    do {
      alerts = try await model.client.listAvailableAlerts(accountID: accountID)
      if selectedType.isEmpty {
        selectedType = alerts.first?.type ?? ""
      }
    } catch {
      saveError = error.dashActionableMessage
    }
    loading = false
  }

  private func create() async {
    guard let accountID = model.activeAccountID, !selectedType.isEmpty else { return }
    saving = true
    saveError = nil
    do {
      _ = try await model.client.createNotificationPolicy(
        accountID: accountID,
        input: NotificationPolicyInput(
          name: name,
          alertType: selectedType,
          enabled: true,
          mechanisms: NotificationMechanisms(webhooks: [
            NotificationMechanismTarget(id: webhookID)
          ])
        ))
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      onCreated()
    } catch {
      saveError = error.dashActionableMessage
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    saving = false
  }
}

struct AccountView: View {
  private enum Tab: Hashable { case members, alerts, audit }

  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
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
  @State private var invites = false
  @State private var creatingPolicy = false
  @State private var removingMember = false
  @State private var removeMemberError: String?
  @State private var pushEnabled = false
  @State private var pushBusy = false
  @State private var pushError: String?

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: !(members.isEmpty && policies.isEmpty && history.isEmpty && auditLogs.isEmpty)
        || pushEnabled,
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
        pushCard
        if policies.isEmpty && history.isEmpty {
          DashEmptyState(
            icon: SolarAsset.bolt,
            title: "No alerts",
            message: pushEnabled
              ? "Create a policy to choose which Cloudflare alerts reach this iPhone."
              : "Notification policies and recent alerts will appear here."
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
        } else if case .member(let member) = item, featureAllowsWrites {
          DashDetailTray(
            fields: item.fields,
            deleteMessage:
              "Remove \(member.displayName) from this account. Their access ends immediately.",
            isDeleting: removingMember,
            deleteError: removeMemberError,
            onDelete: { Task { await removeMember(member) } }
          )
        } else {
          DashDetailTray(fields: item.fields)
        }
      }
    )
    .toolbar {
      if featureAllowsWrites, selectedTab == .members {
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(asset: SolarAsset.plus, accessibilityLabel: "Invite member") {
            invites = true
          }
        }
        .dashSeparateToolbarBackground()
      } else if featureAllowsWrites, selectedTab == .alerts, pushEnabled,
        model.activeAccountID.flatMap({
          PushRegistrationService.storedWebhookID(accountID: $0)
        }) != nil
      {
        ToolbarItem(placement: .topBarTrailing) {
          DashToolbarIconButton(asset: SolarAsset.plus, accessibilityLabel: "Create alert policy") {
            creatingPolicy = true
          }
        }
        .dashSeparateToolbarBackground()
      }
    }
    .dashTray(isPresented: $invites, title: "Invite member") {
      MemberInviteForm {
        invites = false
        if let accountID = model.activeAccountID {
          model.featureCache.remove(FeatureCacheKey.accountSnapshot(accountID))
        }
        Task { await load(force: true) }
      }
    }
    .dashTray(isPresented: $creatingPolicy, title: "Create alert policy") {
      if let accountID = model.activeAccountID,
        let webhookID = PushRegistrationService.storedWebhookID(accountID: accountID)
      {
        AlertPolicyCreateForm(webhookID: webhookID) {
          creatingPolicy = false
          model.featureCache.remove(FeatureCacheKey.accountSnapshot(accountID))
          Task { await load(force: true) }
        }
      }
    }
    .refreshable { await load(force: true) }
    .task(id: model.activeAccountID) {
      syncPushToggle()
      await load()
      await reconcilePushIfNeeded()
    }
  }

  @ViewBuilder
  private var pushCard: some View {
    DashListCard {
      VStack(alignment: .leading, spacing: 10) {
        DashToggleRow(
          title: "Push Cloudflare alerts to this iPhone",
          isOn: Binding(
            get: { pushEnabled },
            set: { newValue in
              Task { await setPushEnabled(newValue) }
            }
          )
        )
        .disabled(pushBusy || model.configuration.pushBaseURL == nil)
        Text(
          "Turns on a webhook and alert policies in this Cloudflare account. Alert payloads are forwarded through dash.xat.sh to Apple Push Notification service."
        )
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        if let pushError {
          DashNotice(kind: .error, message: pushError)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
      }
    }
  }

  private func syncPushToggle() {
    guard let accountID = model.activeAccountID else {
      pushEnabled = false
      return
    }
    pushEnabled = PushRegistrationService.isEnabled(accountID: accountID)
  }

  private func setPushEnabled(_ enabled: Bool) async {
    guard let accountID = model.activeAccountID else { return }
    pushBusy = true
    pushError = nil
    do {
      if enabled {
        let granted = await WatchtowerNotifier.requestAuthorization()
        guard granted else {
          pushError = "Notifications are turned off in Settings."
          pushEnabled = false
          pushBusy = false
          return
        }
        guard let token = await PushRegistrationService.waitForDeviceToken(in: model) else {
          throw PushRegistrationError.missingDeviceToken
        }
        try await PushRegistrationService.enable(
          accountID: accountID, client: model.client,
          configuration: model.configuration, deviceToken: token)
        pushEnabled = true
      } else {
        try await PushRegistrationService.disable(accountID: accountID, client: model.client)
        pushEnabled = false
      }
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    } catch {
      pushError = error.dashActionableMessage
      syncPushToggle()
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    pushBusy = false
  }

  private func reconcilePushIfNeeded() async {
    guard let accountID = model.activeAccountID,
      PushRegistrationService.isEnabled(accountID: accountID),
      let token = model.pendingDeviceToken
    else { return }
    try? await PushRegistrationService.reconcile(
      accountID: accountID, client: model.client,
      configuration: model.configuration, deviceToken: token)
  }

  private func removeMember(_ member: AccountMember) async {
    guard let accountID = model.activeAccountID else { return }
    removingMember = true
    removeMemberError = nil
    do {
      _ = try await model.client.mutate(
        path: "/accounts/\(accountID)/members/\(member.id)", method: "DELETE")
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      detail = nil
      model.featureCache.remove(FeatureCacheKey.accountSnapshot(accountID))
      await load(force: true)
    } catch {
      removeMemberError = error.dashActionableMessage
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    removingMember = false
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
      _ = try await model.client.updateNotificationPolicy(
        accountID: accountID,
        policyID: policy.id,
        input: policy.input(enabled: !(policy.enabled ?? true)))
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
