import CloudflareAPI
import SwiftUI

/// Write scope the Add form needs. A grant without it leaves the screen fully
/// working read-side, with `FeatureWriteAccessNotice` where Add would be.
let emailAddressWriteScopes: Set<String> = ["email-routing-address.write"]

/// The account's Email Routing destination addresses.
///
/// Verification is the whole point of this screen. Cloudflare's `verified` is a
/// nullable timestamp, and mail forwarded to an address that never had its
/// confirmation link clicked is **dropped silently** — so the state is a
/// `StatusBadge` on every row plus a warning above the list, never a detail
/// buried in a tray.
struct EmailDestinationAddressesView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.featureAllowsWrites) private var featureAllowsWrites
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var addresses: [EmailDestinationAddress] = []
  @State private var loading = true
  @State private var loaded = false
  @State private var error: String?
  @State private var selected: EmailDestinationAddress?
  @State private var addsAddress = false
  @State private var loadedContext: AccountRequestContext?

  private var unverified: [EmailDestinationAddress] {
    addresses.filter { !$0.isVerified }
  }

  var body: some View {
    DashFeatureList(
      isLoading: loading,
      error: error,
      hasContent: loaded,
      retry: { Task { await load(force: true) } }
    ) { mode in
      if !mode.isPlaceholder {
        if !featureAllowsWrites {
          FeatureWriteAccessNotice(
            message: "Read-only — grant Email Routing write access to change routes.",
            scopes: emailAddressWriteScopes)
        }
        if !unverified.isEmpty {
          DashNotice(
            kind: .warning,
            message:
              "Mail forwarded to an unverified address is dropped. Open the confirmation email Cloudflare sent to it."
          )
          .dashSectionBoundary(!featureAllowsWrites)
        }
      }
      addressesSection(mode: mode)
      if !mode.isPlaceholder {
        removalNote
      }
    }
    .detailHeader(
      icon: .solar(SolarAsset.Content.user),
      title: "Destination addresses",
      tint: FeatureVisualIdentity.heroColor(for: .emailRouting)
    )
    .refreshable { await load(force: true) }
    .task(id: model.accountRequestContext) { await load() }
    .dashTray(
      item: $selected,
      title: { $0.email },
      content: { address in
        DashDetailTray(fields: Self.detailFields(for: address))
      }
    )
    .dashTray(isPresented: $addsAddress, title: "Add a destination address") {
      EmailAddressAddForm {
        await load(force: true)
      }
    }
  }

  // MARK: List

  /// Unbounded, so the header goes straight into `DashFeatureList`'s lazy stack
  /// and the rows follow as its sibling — not a `DashListGroup`, whose eager
  /// `VStack` would mount every address at once.
  @ViewBuilder
  private func addressesSection(mode: DashBodyMode) -> some View {
    DashListGroupHeader(
      title: DashL10n.ui("Addresses"),
      actionTitle: !mode.isPlaceholder && featureAllowsWrites ? DashL10n.ui("Add") : nil,
      actionIcon: !mode.isPlaceholder && featureAllowsWrites ? SolarAsset.plus : nil,
      action: !mode.isPlaceholder && featureAllowsWrites ? { addsAddress = true } : nil
    )
    .padding(.horizontal, 4)
    .dashSectionBoundary()
    .padding(.bottom, 8)

    if !mode.isPlaceholder, addresses.isEmpty {
      DashEmptyState(
        icon: SolarAsset.Content.user,
        title: "No destination addresses",
        message:
          "Add the inbox you want mail forwarded to. Cloudflare emails it a confirmation link.",
        actionTitle: featureAllowsWrites ? "Add a destination address" : nil,
        action: featureAllowsWrites ? { addsAddress = true } : nil)
    } else {
      dashModeListRows(mode: mode, items: addresses, reduceMotion: reduceMotion) { address in
        Button {
          selected = address
        } label: {
          DashListRow(
            title: address.email,
            subtitle: Self.addedSubtitle(address),
            icon: SolarAsset.Content.user,
            iconColor: address.isVerified
              ? FeatureVisualIdentity.catalogColor(for: .emailRouting) : DashTheme.iconMuted,
            showsChevron: false
          ) {
            StatusBadge(address.isVerified ? .verified : .unverified)
          }
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityLabel(
          "\(address.email), \(StatusBadge.accessibilityText(for: address.isVerified ? .verified : .unverified))"
        )
      }
    }
  }

  /// Deliberate omission, stated rather than hidden — the same shape zone
  /// settings uses for domain removal.
  private var removalNote: some View {
    DashCard {
      Text(
        DashL10n.string(
          "Removing a destination address isn't available in Dash. Use the Cloudflare dashboard."
        )
      )
      .dashTextStyle(.footnote)
      .foregroundStyle(DashTheme.subtle)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .dashSectionBoundary()
  }

  // MARK: Fields

  static func detailFields(for address: EmailDestinationAddress) -> [DashDetailField] {
    var fields = [DashDetailField(label: "Address", value: address.email, mono: true)]
    if let created = address.created, DashDateFormatting.date(fromISO8601: created) != nil {
      fields.append(
        DashDetailField(
          label: "Added",
          value: DashDateFormatting.dateAndTime(fromISO8601: created)))
    }
    fields.append(
      DashDetailField(
        label: "Verified",
        value: address.verified.flatMap { iso -> String? in
          guard DashDateFormatting.date(fromISO8601: iso) != nil else { return nil }
          return DashDateFormatting.dateAndTime(fromISO8601: iso)
        } ?? DashL10n.string("Unverified")))
    return fields
  }

  static func addedSubtitle(_ address: EmailDestinationAddress) -> String? {
    guard let created = address.created,
      DashDateFormatting.date(fromISO8601: created) != nil
    else {
      return nil
    }
    return DashL10n.string(
      "Added \(DashDateFormatting.dateOnly(fromISO8601: created))")
  }

  // MARK: Loading

  private func load(force: Bool = false) async {
    guard let context = model.accountRequestContext else {
      loadedContext = nil
      addresses = []
      loaded = false
      loading = false
      error = nil
      selected = nil
      addsAddress = false
      return
    }
    if loadedContext != context {
      loadedContext = context
      addresses = []
      loaded = false
      loading = true
      error = nil
      selected = nil
      addsAddress = false
    }
    let key = FeatureCacheKey.emailAddresses(context.accountID)
    if !force, let cached: [EmailDestinationAddress] = model.featureCache.get(key) {
      addresses = cached
      loaded = true
      loading = false
      error = nil
      return
    }
    do {
      let fetched = try await model.client.listEmailDestinationAddresses(
        accountID: context.accountID)
      guard model.isCurrentAccount(context), !Task.isCancelled else { return }
      addresses = fetched
      loaded = true
      error = nil
      model.featureCache.set(key, fetched)
    } catch {
      guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
        return
      }
      self.error = error.dashActionableMessage
    }
    loading = false
  }
}

/// Adds one destination address. Cloudflare mails it a confirmation link; the
/// address stays unverified — and drops every message routed to it — until that
/// link is clicked, which is what the success copy says out loud.
struct EmailAddressAddForm: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  var onAdded: () async -> Void

  @State private var email = ""
  @State private var actionPhase: DashActionPhase = .idle
  @State private var errorMessage: String?

  private var normalized: String {
    email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// Deliberately shallow: Cloudflare is the authority on what it will accept,
  /// and a stricter client-side pattern only blocks addresses that work.
  private var canSave: Bool {
    let parts = normalized.split(separator: "@")
    return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && parts[1].contains(".")
      && !actionPhase.isActive
  }

  var body: some View {
    DashFormSheet(
      saveTitle: "Send verification email",
      actionPhase: actionPhase,
      onSuccessPresentationCompleted: completeSavePresentation,
      canSave: canSave,
      onSave: { Task { await save() } },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          DashFormField(
            label: "Address", text: $email, keyboard: .emailAddress,
            contentType: .emailAddress)
          if let errorMessage {
            DashNotice(kind: .error, message: errorMessage)
          }
        }
      }
    )
    .dashTrayDescription(
      DashL10n.string(
        "Cloudflare emails a confirmation link to this address. Mail routed to it is dropped until the link is opened."
      )
    )
  }

  private func save() async {
    guard canSave, let context = model.accountRequestContext else { return }
    let address = normalized
    actionPhase = .loading
    errorMessage = nil
    do {
      _ = try await model.client.createEmailDestinationAddress(
        accountID: context.accountID, email: address)
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        actionPhase = .idle
        return
      }
      model.featureCache.remove(FeatureCacheKey.emailAddresses(context.accountID))
      model.toasts.success(DashL10n.string("Cloudflare sent a verification email to \(address)."))
      await onAdded()
      guard model.isCurrentAccount(context), !Task.isCancelled else {
        actionPhase = .idle
        return
      }
      actionPhase = .succeeded
    } catch {
      actionPhase = .idle
      guard model.isCurrentAccount(context), !Task.isCancelled, !error.dashIsCancellation else {
        return
      }
      errorMessage = error.dashActionableMessage
    }
  }

  private func completeSavePresentation() {
    guard actionPhase == .succeeded else {
      actionPhase = .idle
      return
    }
    actionPhase = .idle
    dismiss()
  }
}
