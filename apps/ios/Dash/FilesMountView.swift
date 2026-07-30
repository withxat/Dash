import CloudflareAPI
import Foundation
import SwiftUI

/// Settings subpage for exposing each authenticated Cloudflare account as a
/// separate Files location.
struct FilesMountView: View {
  @Environment(AppModel.self) private var model
  @State private var mountedAccountIDs: Set<String> = []
  @State private var accountsPhase: DashSectionPhase = .loading
  @State private var inFlightAccountID: String?
  @State private var pendingUnmountAccount: CloudflareAccount?
  @State private var loadRevision = 0

  private let objectWriteScope: Set<String> = ["workers-r2-bucket-item.write"]

  private var loadIdentity: String {
    let accountIDs = model.accounts.map(\.id).sorted().joined(separator: ",")
    return "\(model.isDemoSession):\(accountIDs)"
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        if model.isDemoSession {
          FeatureWriteAccessNotice(
            message: "Show R2 buckets in the Files app",
            scopes: FeatureID.r2.capability.all
          )
        } else {
          filesInformation
          accountsGroup
            .dashSectionBoundary()

          if !model.hasScopes(objectWriteScope) {
            FeatureWriteAccessNotice(
              message: "Buckets appear read-only in Files until you authorize write access.",
              scopes: objectWriteScope
            )
            .dashItemBoundary()
          }
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.vertical, DashTheme.Spacing.section)
    }
    .background(DashTheme.canvas)
    .detailHeader(icon: .solar(SolarAsset.Content.folder), title: "Files")
    .task(id: loadIdentity) {
      guard !model.isDemoSession else {
        loadRevision &+= 1
        mountedAccountIDs = []
        accountsPhase = .content
        inFlightAccountID = nil
        return
      }
      await loadDomains()
    }
    .dashTray(
      item: $pendingUnmountAccount,
      title: { _ in "Files" },
      content: { account in
        DashConfirmableActions(actions: [unmountAction(for: account)])
      }
    )
  }

  private var filesInformation: some View {
    DashInfoGroup(title: "Files") {
      DashInfoRow("Maximum download", value: "1 GB")
      DashInfoRow("Maximum upload", value: "300 MB")
      DashInfoRow(
        "Rename & move",
        value: DashL10n.string("Not available in Files")
      )
      DashInfoRow(
        "Previews",
        value: DashL10n.string("Downloads the whole file")
      )
      DashInfoRow(
        "External changes",
        value: DashL10n.string(
          "Re-enter the folder to see objects added or deleted from Wrangler, the dashboard, or another device."
        )
      )
    }
  }

  private var accountsGroup: some View {
    DashListGroup(title: "Accounts") {
      switch accountsPhase {
      case .loading:
        loadingAccountRows
      case .content:
        ForEach(model.accounts) { account in
          accountButton(account)
        }
      case .failed(let message):
        VStack(spacing: DashTheme.Spacing.compact) {
          DashNotice(kind: .error, message: message)
          DashSecondaryPillButton(title: "Try again") {
            Task { await loadDomains() }
          }
        }
        .padding(.vertical, DashTheme.Spacing.compact)
      }
    }
  }

  @ViewBuilder
  private var loadingAccountRows: some View {
    if model.accounts.isEmpty {
      HStack(spacing: 12) {
        Circle()
          .dashSkeletonFill(DashSkeletonStyle.strong)
          .frame(width: 36, height: 36)
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .dashSkeletonFill(DashSkeletonStyle.strong)
          .frame(width: 132, height: 14)
        Spacer(minLength: 0)
        Capsule(style: .continuous)
          .dashSkeletonFill(DashSkeletonStyle.mid)
          .frame(width: 51, height: 31)
      }
      .frame(minHeight: DashTheme.Layout.minimumHitTarget)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(DashL10n.string("Loading"))
    } else {
      ForEach(model.accounts) { account in
        accountRow(account, isMounted: false, isLoading: true)
          .redacted(reason: .placeholder)
          .dashSkeletonShimmer()
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
  }

  private func accountButton(_ account: CloudflareAccount) -> some View {
    let isMounted = mountedAccountIDs.contains(account.id)
    let isLoading = inFlightAccountID == account.id

    return Button {
      if isMounted {
        pendingUnmountAccount = account
      } else {
        mount(account)
      }
    } label: {
      accountRow(account, isMounted: isMounted, isLoading: isLoading)
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .disabled(inFlightAccountID != nil)
    .opacity(inFlightAccountID == nil || isLoading ? 1 : 0.55)
    .accessibilityElement(children: .combine)
    .accessibilityValue(DashL10n.string(isMounted ? "On" : "Off"))
    .accessibilityAddTraits(.isToggle)
  }

  private func accountRow(
    _ account: CloudflareAccount,
    isMounted: Bool,
    isLoading: Bool
  ) -> some View {
    DashListRow(
      title: account.name,
      icon: SolarAsset.Content.cloud,
      showsChevron: false
    ) {
      DashSwitch(isOn: isMounted)
        .opacity(isLoading ? 0.72 : 1)
    }
  }

  private func mount(_ account: CloudflareAccount) {
    guard model.canModifyFileProviderDomains, inFlightAccountID == nil else { return }
    let previousAccountIDs = mountedAccountIDs
    inFlightAccountID = account.id
    mountedAccountIDs.insert(account.id)

    Task { @MainActor in
      defer { inFlightAccountID = nil }
      guard
        model.canModifyFileProviderDomains,
        model.accounts.contains(where: { $0.id == account.id })
      else {
        mountedAccountIDs = previousAccountIDs
        return
      }

      do {
        let accountIDs = try await FileProviderDomains.addDomain(for: account)
        guard
          model.canModifyFileProviderDomains,
          model.accounts.contains(where: { $0.id == account.id })
        else {
          if let accountIDs = try? await FileProviderDomains.removeDomain(accountID: account.id) {
            mountedAccountIDs = accountIDs
          } else {
            mountedAccountIDs.remove(account.id)
          }
          return
        }
        mountedAccountIDs = accountIDs
      } catch {
        mountedAccountIDs = previousAccountIDs
        model.toasts.error(DashL10n.string("Couldn't update the Files mount."))
      }
    }
  }

  private func unmountAction(for account: CloudflareAccount) -> DashDangerAction {
    DashDangerAction(
      id: "files-unmount-\(account.id)",
      title: DashL10n.string("Remove \(account.name)"),
      message:
        "The Files location and its downloaded files will be removed from this iPhone.",
      confirmTitle: "Remove"
    ) {
      try await unmount(account)
    }
  }

  @MainActor
  private func unmount(_ account: CloudflareAccount) async throws {
    guard model.canModifyFileProviderDomains, inFlightAccountID == nil else {
      throw FilesMountUpdateError()
    }

    let previousAccountIDs = mountedAccountIDs
    inFlightAccountID = account.id
    mountedAccountIDs.remove(account.id)
    defer { inFlightAccountID = nil }

    do {
      mountedAccountIDs = try await FileProviderDomains.removeDomain(accountID: account.id)
    } catch {
      mountedAccountIDs = previousAccountIDs
      throw FilesMountUpdateError()
    }
  }

  @MainActor
  private func loadDomains() async {
    loadRevision &+= 1
    let revision = loadRevision
    accountsPhase = .loading

    do {
      let accountIDs = try await FileProviderDomains.mountedAccountIDs()
      guard revision == loadRevision, !Task.isCancelled else { return }
      mountedAccountIDs = accountIDs
      accountsPhase = .content
    } catch {
      guard revision == loadRevision, !Task.isCancelled else { return }
      accountsPhase = .failed(
        DashL10n.string("Couldn't update the Files mount.")
      )
    }
  }
}

private struct FilesMountUpdateError: LocalizedError {
  var errorDescription: String? {
    DashL10n.string("Couldn't update the Files mount.")
  }
}
