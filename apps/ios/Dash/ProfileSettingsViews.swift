import CloudflareAPI
import CoreTransferable
import GradientAvatars
import PhotosUI
import SwiftDitherKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Account decisions

/// Switch account and Sign out are each asked in two places — the Profile
/// tray, where they are stack steps (copy in the body, controls in the fixed
/// footer), and Settings, where tapping the row opens its one-step confirmation
/// tray directly. The decision itself is defined once here: same copy, same
/// controls, same rule about who gets a Cancel. Only the way *out* differs, so
/// every host passes its own `cancel`, and only the Profile footer passes the
/// morph identity its Sign out pill travels on.
enum AccountDecisionCopy {
  /// Two consequences, two paragraphs — kept as separate catalog keys and
  /// joined here, because the Files sentence is only true of this app's mounts
  /// and must stay translatable on its own.
  static var signOutConsequences: String {
    [
      DashL10n.string("You'll need to reconnect your Cloudflare account to use Dash again."),
      DashL10n.string(
        "Any R2 locations mounted in Files and their downloaded copies will be removed from this iPhone."
      ),
    ].joined(separator: "\n\n")
  }

  static func switchMessage(for account: CloudflareAccount) -> String {
    DashL10n.string(
      "Switch to \(account.name)? Cached data and open screens for the current account will reset."
    )
  }
}

/// The centred supporting copy a confirmation step shows above its controls.
/// Only the Profile tray needs it: there the text belongs to one step and
/// changes as the flow moves, which is content. Settings hands the same string
/// to `dashTrayDescription` instead, because a one-step tray's copy is that
/// tray's standing explanation of itself. Same words, two honest positions.
struct AccountDecisionMessage: View {
  let text: String

  var body: some View {
    Text(text)
      .dashTextStyle(.supporting)
      .foregroundStyle(DashTheme.subtle)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 4)
      .padding(.top, 4)
  }
}

/// Commit control for the account switch. It states no Cancel on purpose: the
/// switch is reversible, so the tray's ✕ is the whole way out — popping the
/// step in the Profile tray, dismissing the one-step tray in Settings, which
/// is the same "not this" either way.
struct AccountSwitchConfirmationActions: View {
  let confirm: () -> Void
  @Environment(\.dashTrayDismissAfter) private var dismissAfter

  var body: some View {
    DashActionButton(title: "Switch account") {
      dismissAfter(confirm)
    }
  }
}

/// Sign out is destructive, so it always pairs its danger pill with a Cancel:
/// the header circle wears the same ✕ at every depth, and a step one tap from
/// an irreversible action must state that backing out is still possible.
/// `cancel` is that step's own way back — a pop in the Profile tray, a
/// dismissal in Settings.
struct SignOutConfirmationActions: View {
  let cancel: () -> Void
  /// Each host names its own confirm pill; the shared component cannot, and a
  /// container identifier would not answer a `buttons[…]` query.
  var confirmIdentifier: String? = nil
  /// The surface the idle control on the previous step grows from — the
  /// Profile footer's full-width pill, Settings' red row.
  var morphID: String? = nil
  var labelMorphID: String? = nil
  var morphNamespace: Namespace.ID? = nil
  @Environment(AppModel.self) private var model

  var body: some View {
    DashTrayActionPair {
      DashTrayCancelButton(action: cancel)
        .disabled(model.signOutActionPhase.isActive)
    } primary: {
      confirmButton
    }
  }

  @ViewBuilder private var confirmButton: some View {
    let button = DashActionButton(
      title: "Sign out",
      role: .destructive,
      phase: model.signOutActionPhase,
      morphID: morphID,
      labelMorphID: labelMorphID,
      morphNamespace: morphNamespace,
      onSuccessPresentationCompleted: model.completeSignOutActionPresentation
    ) {
      Task {
        await model.signOut(presentsCompletion: true)
      }
    }
    if let confirmIdentifier {
      button.accessibilityIdentifier(confirmIdentifier)
    } else {
      button
    }
  }
}

/// Avatar long-press account switcher with in-tray switch and sign-out
/// confirmations. Tapping the avatar still pushes Settings.
struct ProfileTrayContent: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  @Binding var path: [ProfileTrayPhase]

  var body: some View {
    DashTrayFlow(root: .accounts, path: $path, role: \.trayRole) { phase in
      switch phase {
      case .accounts:
        accountList
      case .switchAccount(let account):
        accountSwitchMessage(account)
      case .signOut:
        signOutMessage
      }
    }
    .frame(maxWidth: .infinity)
    .dashTrayTitle((path.last ?? .accounts).title)
  }

  private var accountList: some View {
    VStack(spacing: DashTheme.Spacing.itemGap) {
      ForEach(model.accounts) { account in
        let isActive = account.id == model.activeAccountID
        Button {
          if isActive {
            dismiss()
            return
          }
          path.append(.switchAccount(account))
        } label: {
          ProfileTrayAccountRow(account: account, isActive: isActive)
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityIdentifier("profile-account-\(account.id)")
        .accessibilityLabel(Text(verbatim: account.name))
        .accessibilityValue(isActive ? DashL10n.string("Active account") : "")
        .accessibilityHint(isActive ? "" : DashL10n.string("Switch account"))
        .accessibilityAddTraits(isActive ? .isSelected : [])
      }
    }
  }

  private func accountSwitchMessage(_ account: CloudflareAccount) -> some View {
    AccountDecisionMessage(text: AccountDecisionCopy.switchMessage(for: account))
  }

  private var signOutMessage: some View {
    AccountDecisionMessage(text: AccountDecisionCopy.signOutConsequences)
  }
}

/// Fixed footer for `ProfileTrayContent`. Its height never participates in the
/// body's fitted-height animation, so the shared Sign out hero has one stable
/// global destination while account rows and confirmation copy morph above it.
struct ProfileTrayFooter: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var path: [ProfileTrayPhase]
  let onSwitchAccount: (CloudflareAccount) -> Void
  @Namespace private var actionMorph

  /// Shared by the idle Sign out pill and the confirming pill so the enamel
  /// face travels between steps — same `matchedGeometryEffect` path
  /// `DashConfirmableActions` uses for danger rows. The account-switch step
  /// carries no footer Cancel — the header's ✕ owns the way out of it; the
  /// destructive sign-out step is the deliberate exception (see below).
  private static let signOutMorphID = "profile-tray-sign-out"

  var body: some View {
    DashTrayFlow(root: .accounts, path: $path, role: \.trayRole) { phase in
      switch phase {
      case .accounts:
        signOutSource
      case .switchAccount(let account):
        accountSwitchActions(account)
      case .signOut:
        signOutConfirmationActions
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var signOutMorphID: String? {
    reduceMotion ? nil : Self.signOutMorphID
  }

  /// Companion id for the title run: both endpoints say "Sign out", so the
  /// pinned label rides the surface morph instead of cross-fading in place.
  private var signOutLabelMorphID: String? {
    reduceMotion ? nil : "\(Self.signOutMorphID).label"
  }

  private var signOutMorphNamespace: Namespace.ID? {
    reduceMotion ? nil : actionMorph
  }

  private var signOutSource: some View {
    DashActionButton(
      title: "Sign out",
      role: .destructive,
      morphID: signOutMorphID,
      labelMorphID: signOutLabelMorphID,
      morphNamespace: signOutMorphNamespace
    ) {
      path.append(.signOut)
    }
    .accessibilityIdentifier("profile-account-sign-out")
  }

  private func accountSwitchActions(_ account: CloudflareAccount) -> some View {
    AccountSwitchConfirmationActions { onSwitchAccount(account) }
  }

  /// The one stack step that keeps a footer Cancel, because it is the one that
  /// is destructive — the shared control states why. Here its way back is a
  /// one-step pop, and both morph endpoints stay inside this fixed footer so
  /// the enamel face travels between them.
  private var signOutConfirmationActions: some View {
    SignOutConfirmationActions(
      cancel: popStep,
      morphID: signOutMorphID,
      labelMorphID: signOutLabelMorphID,
      morphNamespace: signOutMorphNamespace
    )
  }

  /// Exactly the pop the header control performs — Cancel is a second door
  /// onto the previous step, never a dismissal of the whole tray.
  private func popStep() {
    guard !path.isEmpty else { return }
    path.removeLast()
  }
}

private struct ProfileTrayAccountRow: View {
  let account: CloudflareAccount
  let isActive: Bool
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    HStack(spacing: 14) {
      GradientAvatar(
        seed: account.id,
        size: 48,
        pattern: .dither,
        contentScale: 1.5
      )
      .overlay {
        Circle().stroke(DashTheme.separator, lineWidth: 0.5)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(account.name)
          .dashTextStyle(.bodySemibold)
          .foregroundStyle(DashTheme.text)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)

        if isActive {
          Text(DashL10n.string("Active account"))
            .dashTextStyle(.footnote)
            .foregroundStyle(DashTheme.rowSubtitle)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      DashSelectionMark(isSelected: isActive)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
    .background(DashTheme.Sheet.shortcutItem, in: DashTheme.buttonShape)
    .contentShape(DashTheme.buttonShape)
  }
}

enum ProfileTrayPhase: Hashable, Sendable {
  case accounts
  case switchAccount(CloudflareAccount)
  case signOut

  static let initial: Self = .accounts

  var title: String {
    switch self {
    case .accounts, .switchAccount: DashL10n.string("Switch account")
    case .signOut: DashL10n.string("Sign out")
    }
  }

  var trayRole: DashTrayStepRole {
    switch self {
    case .accounts: .root
    case .switchAccount: .detail
    case .signOut: .destructive
    }
  }
}

private enum SettingsListMetrics {
  /// Grows with the enlarged row text (was the 24-in-36 slot shared with
  /// `DashListRow` / Resources). Plate stays transparent; only the outline
  /// glyph paints.
  static let iconSize: CGFloat = 27
  static let iconColumn: CGFloat = 40
  static let featuredLeading: CGFloat = 56
  static let rowSpacing: CGFloat = 12
}

/// Settings row on the shared list chrome: bare outline `SolarAsset.*` glyph
/// at `iconMuted` (no catalog tone plate). Keeps Settings-only trailing
/// affordances (value, menu dots, switch) instead of reusing `DashListRow`
/// wholesale.
struct SettingsPlainRow<Accessory: View>: View {
  let title: String
  var subtitle: String?
  let icon: String
  var iconColor = DashTheme.iconMuted
  var textColor = DashTheme.text
  var trailing: String?
  var trailingIcon: String?
  /// Applied to `trailingIcon` — `SolarAsset.trayDots` renders the horizontal
  /// dots that mark a row opening a picker tray.
  var trailingIconRotation: Angle = .zero
  var showsChevron = false
  /// Leaves the app (Safari / Mail) — arrow-right-up, not the in-app chevron.
  var showsExternalLink = false
  private let hasAccessory: Bool
  @ViewBuilder let accessory: () -> Accessory
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .body) private var iconScale: CGFloat = 1

  private var usesStackedLayout: Bool { dynamicTypeSize.isAccessibilitySize }
  private var iconPointSize: CGFloat {
    SettingsListMetrics.iconSize * min(max(iconScale, 1), 1.3)
  }
  private var iconFrame: CGFloat {
    SettingsListMetrics.iconColumn * min(max(iconScale, 1), 1.3)
  }

  init(
    title: String,
    subtitle: String? = nil,
    icon: String,
    iconColor: Color = DashTheme.iconMuted,
    textColor: Color = DashTheme.text,
    trailing: String? = nil,
    trailingIcon: String? = nil,
    trailingIconRotation: Angle = .zero,
    showsChevron: Bool = false,
    showsExternalLink: Bool = false,
    hasAccessory: Bool = true,
    @ViewBuilder accessory: @escaping () -> Accessory
  ) {
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.iconColor = iconColor
    self.textColor = textColor
    self.trailing = trailing
    self.trailingIcon = trailingIcon
    self.trailingIconRotation = trailingIconRotation
    self.showsChevron = showsChevron
    self.showsExternalLink = showsExternalLink
    self.hasAccessory = hasAccessory
    self.accessory = accessory
  }

  var body: some View {
    HStack(alignment: usesStackedLayout ? .top : .center, spacing: SettingsListMetrics.rowSpacing) {
      SolarIcon(asset: icon, size: iconPointSize, color: iconColor)
        .frame(width: iconFrame, height: iconFrame)

      if usesStackedLayout {
        VStack(alignment: .leading, spacing: 8) {
          label
          if hasTrailingContent {
            trailingContent
          }
        }
      } else {
        label
        Spacer(minLength: 12)
        trailingContent
      }
    }
    .padding(.vertical, DashTheme.Spacing.listRow)
    .frame(maxWidth: .infinity, minHeight: DashTheme.Layout.minimumHitTarget, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private var hasTrailingContent: Bool {
    hasAccessory || trailing != nil || trailingIcon != nil || showsChevron
      || showsExternalLink
  }

  private var label: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(textColor)
        .lineLimit(usesStackedLayout ? nil : 2)
      if let subtitle {
        Text(subtitle)
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.rowSubtitle)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var trailingContent: some View {
    HStack(spacing: 8) {
      accessory()
      if let trailing {
        Text(trailing)
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.text)
          .multilineTextAlignment(.trailing)
          .lineLimit(usesStackedLayout ? nil : 1)
      }
      if let trailingIcon {
        SolarIcon(
          asset: trailingIcon, size: 20, color: DashTheme.placeholder,
          rotation: trailingIconRotation)
      } else if showsExternalLink {
        SolarIcon(
          asset: SolarAsset.arrowRightUp,
          size: DashTheme.Chevron.row,
          color: DashTheme.placeholder
        )
      } else if showsChevron {
        SolarIcon(
          asset: SolarAsset.chevronRight,
          size: DashTheme.Chevron.row,
          color: DashTheme.placeholder
        )
      }
    }
    .frame(
      maxWidth: usesStackedLayout ? .infinity : nil,
      alignment: usesStackedLayout ? .trailing : .leading
    )
  }
}

extension SettingsPlainRow where Accessory == EmptyView {
  init(
    title: String,
    subtitle: String? = nil,
    icon: String,
    iconColor: Color = DashTheme.iconMuted,
    textColor: Color = DashTheme.text,
    trailing: String? = nil,
    trailingIcon: String? = nil,
    trailingIconRotation: Angle = .zero,
    showsChevron: Bool = false,
    showsExternalLink: Bool = false
  ) {
    self.init(
      title: title,
      subtitle: subtitle,
      icon: icon,
      iconColor: iconColor,
      textColor: textColor,
      trailing: trailing,
      trailingIcon: trailingIcon,
      trailingIconRotation: trailingIconRotation,
      showsChevron: showsChevron,
      showsExternalLink: showsExternalLink,
      hasAccessory: false,
      accessory: { EmptyView() }
    )
  }
}

struct SettingsPlainToggleRow: View {
  let title: String
  var subtitle: String?
  let icon: String
  @Binding var isOn: Bool
  var isEnabled = true
  var isLoading = false

  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      SettingsPlainRow(title: title, subtitle: subtitle, icon: icon) {
        DashSwitch(isOn: isOn)
          .opacity(isLoading ? 0.72 : 1)
      }
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .disabled(!isEnabled || isLoading)
    .opacity(isEnabled ? 1 : 0.55)
    .accessibilityElement(children: .combine)
    .accessibilityValue(DashL10n.string(isOn ? "On" : "Off"))
    .accessibilityAddTraits(.isToggle)
  }
}

/// Same title + bare-row column as `DashListGroup` — Settings used to invent
/// an uppercase caption and hairline-separated list that read as a different app.
struct SettingsPlainSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      DashListGroupHeader(title: DashL10n.ui(title))
        .padding(.horizontal, 4)

      VStack(alignment: .leading, spacing: 0) {
        content()
      }
      .padding(.horizontal, DashTheme.Spacing.rowInset)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct SettingsFeaturedRow<Leading: View>: View {
  let title: String
  let subtitle: String?
  @ViewBuilder let leading: () -> Leading

  var body: some View {
    HStack(spacing: SettingsListMetrics.rowSpacing) {
      leading()
        .frame(
          width: SettingsListMetrics.featuredLeading,
          height: SettingsListMetrics.featuredLeading
        )
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .dashTextStyle(.sectionTitle)
          .foregroundStyle(DashTheme.strong)
          .fixedSize(horizontal: false, vertical: true)
        if let subtitle {
          Text(subtitle)
            .dashTextStyle(.supporting)
            .foregroundStyle(DashTheme.rowSubtitle)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      SolarIcon(
        asset: SolarAsset.chevronRight,
        size: DashTheme.Chevron.row,
        color: DashTheme.placeholder
      )
    }
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}

private enum DashHelpLink {
  static var feedback: URL {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
    let build = info?["CFBundleVersion"] as? String ?? "Unknown"
    let system = ProcessInfo.processInfo.operatingSystemVersion
    let systemVersion = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
    let body = """
      \(DashL10n.string("Describe what happened:"))


      \(DashL10n.string("App context"))
      Dash \(version) (\(build))
      iOS \(systemVersion)

      \(DashL10n.string("Please do not include account names, IDs, domains, or other sensitive data."))
      """

    var components = URLComponents()
    components.scheme = "mailto"
    components.path = "i@xat.sh"
    components.queryItems = [
      URLQueryItem(name: "subject", value: DashL10n.string("Dash feedback")),
      URLQueryItem(name: "body", value: body),
    ]
    return components.url ?? URL(string: "mailto:i@xat.sh")!
  }
}

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @AppStorage(DashAppLanguage.storageKey) private var languageRaw = DashAppLanguage.system.rawValue
  @AppStorage(DashInteractionPreferences.hapticsKey) private var hapticsEnabled = true
  @AppStorage(DashWorkspaceGlowPreset.storageKey) private var workspaceGlowRaw =
    DashWorkspaceGlowPreset.defaultPreset.rawValue
  @AppStorage(DashChartStylePreference.storageKey) private var chartStyleRaw =
    DashChartStylePreference.defaultStyle.rawValue
  @AppStorage(ICloudPreferencesSync.enabledKey) private var iCloudSyncEnabled = true
  @AppStorage(DashExperimentalFeatures.tunnelsKey) private var tunnelsExperimentalEnabled =
    false
  @State private var showsLanguagePicker = false
  @State private var showsWorkspaceGlowPicker = false
  @State private var showsChartStylePicker = false
  @State private var showsSignOutConfirmation = false

  private var selectedLanguage: DashAppLanguage {
    DashAppLanguage.resolved(stored: languageRaw)
  }

  private var selectedChartStyle: DashChartStylePreference {
    DashChartStylePreference.resolved(stored: chartStyleRaw)
  }

  private var selectedWorkspaceGlow: DashWorkspaceGlowPreset {
    DashWorkspaceGlowPreset.resolved(stored: workspaceGlowRaw)
  }

  private var profileSubtitle: String? {
    if let email = model.user?.email, email != model.profileTitle {
      return email
    }
    return DashL10n.string("Profile")
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        VStack(spacing: 0) {
          DashListGroupLink(value: .profile) {
            SettingsFeaturedRow(
              title: model.profileTitle,
              subtitle: profileSubtitle
            ) {
              UserAvatar(email: model.user?.email ?? "", size: 56)
            }
          }
          .accessibilityIdentifier("settings-profile-row")
          .accessibilityHint(DashL10n.string("Profile"))

          if model.accounts.count > 1 {
            DashListGroupLink(value: .settingsAccounts) {
              SettingsFeaturedRow(
                title: DashL10n.string("Switch account"),
                subtitle: model.activeAccount?.name
              ) {
                SolarIcon(
                  asset: SolarAsset.users,
                  size: 28,
                  color: DashTheme.brand
                )
                .frame(width: 56, height: 56)
                .background(Circle().fill(DashTheme.brand.opacity(0.1)))
              }
            }
            .accessibilityIdentifier("settings-switch-account")
          }
        }
        .padding(.horizontal, DashTheme.Spacing.rowInset)

        SettingsPlainSection(title: "General") {
          Button {
            // `DashSurfaceButtonStyle` has no press haptic — only shrink styles do.
            DashDelight.lightImpact()
            showsLanguagePicker = true
          } label: {
            SettingsPlainRow(
              title: DashL10n.string("Language"),
              icon: SolarAsset.earth,
              trailing: selectedLanguage.displayName,
              trailingIcon: SolarAsset.trayDots,
              trailingIconRotation: .degrees(90)
            )
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityHint(DashL10n.string("Choose English, Simplified Chinese, or System"))

          // Appearance held this one row on its own; a single-row section is a
          // header the page pays for twice.
          Button {
            DashDelight.lightImpact()
            showsWorkspaceGlowPicker = true
          } label: {
            SettingsPlainRow(
              title: DashL10n.string("Glow"),
              icon: SolarAsset.sun,
              trailing: selectedWorkspaceGlow.displayName,
              trailingIcon: SolarAsset.trayDots,
              trailingIconRotation: .degrees(90)
            )
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityIdentifier("workspace-glow-color")

          Button {
            DashDelight.lightImpact()
            showsChartStylePicker = true
          } label: {
            SettingsPlainRow(
              title: DashL10n.string("Chart style"),
              icon: SolarAsset.chatSquare2,
              trailing: selectedChartStyle.displayName,
              trailingIcon: SolarAsset.trayDots,
              trailingIconRotation: .degrees(90)
            )
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityIdentifier("chart-style")

          SettingsPlainToggleRow(
            title: DashL10n.string("Haptic feedback"),
            icon: SolarAsset.smartphoneVibration,
            isOn: $hapticsEnabled
          )
          .onChange(of: hapticsEnabled) { _, enabled in
            if enabled { DashDelight.lightImpact() }
          }
        }

        SettingsPlainSection(title: "iCloud") {
          SettingsPlainToggleRow(
            title: DashL10n.string("Sync settings"),
            icon: SolarAsset.cloud,
            isOn: $iCloudSyncEnabled
          )
          .accessibilityIdentifier("icloud-settings-sync")
        }

        SettingsPlainSection(title: "Experimental") {
          SettingsPlainToggleRow(
            title: DashL10n.string("Tunnels"),
            icon: SolarAsset.routing,
            isOn: $tunnelsExperimentalEnabled
          )
          .accessibilityIdentifier("settings-experimental-tunnels")
        }

        // Help and About were separate sections at the foot of the page; the
        // titles carry these rows on their own, so the subtitles and the extra
        // headers are gone. Legal links stay on sign-in, not here.
        SettingsPlainSection(title: "Help & about") {
          externalRow(
            title: DashL10n.string("Send feedback"),
            icon: SolarAsset.inbox,
            destination: DashHelpLink.feedback,
            accessibilityHint: DashL10n.string("Opens your email app")
          )

          DashListGroupLink(value: .about) {
            SettingsPlainRow(
              title: DashL10n.string("About Dash"),
              icon: SolarAsset.infoCircle,
              showsChevron: true
            )
          }

          DashListGroupLink(value: .openSource) {
            SettingsPlainRow(
              title: DashL10n.string("Open source"),
              icon: SolarAsset.code,
              showsChevron: true
            )
          }
        }

        SettingsPlainSection(title: "Account") {
          Button {
            DashDelight.lightImpact()
            showsSignOutConfirmation = true
          } label: {
            SettingsPlainRow(
              title: DashL10n.string("Sign out"),
              icon: SolarAsset.danger,
              iconColor: DashTheme.danger,
              textColor: DashTheme.danger
            )
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityIdentifier("settings-sign-out")
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, DashTheme.Spacing.section)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .background(DashTheme.canvas.ignoresSafeArea())
    .detailHeader(icon: .solar(SolarAsset.Content.settings), title: "Settings")
    .dashTray(
      isPresented: $showsLanguagePicker,
      title: DashL10n.string("Language")
    ) {
      LanguagePickerTray(languageRaw: $languageRaw)
    }
    .dashTray(
      isPresented: $showsWorkspaceGlowPicker,
      title: DashL10n.string("Glow"),
      tone: selectedWorkspaceGlow.trayTone
    ) {
      WorkspaceGlowPickerTray(workspaceGlowRaw: $workspaceGlowRaw)
    }
    .dashTray(
      isPresented: $showsChartStylePicker,
      title: DashL10n.string("Chart style")
    ) {
      ChartStylePickerTray(chartStyleRaw: $chartStyleRaw)
    }
    .dashTray(
      isPresented: $showsSignOutConfirmation,
      title: DashL10n.string("Sign out")
    ) {
      SignOutConfirmationContent()
    }
    .onChange(of: iCloudSyncEnabled) { _, enabled in
      ICloudPreferencesSync.shared.setEnabled(enabled)
    }
    .onChange(of: workspaceGlowRaw) { _, _ in
      ICloudPreferencesSync.shared.publish(.workspaceGlow)
    }
    .onAppear {
      // The remounted Settings page is the real completion signal for a
      // language reload. Keep the cover until this destination exists instead
      // of guessing how long root reconstruction and routing should take.
      guard model.isReloadingLanguage else { return }
      withAnimation(DashTheme.Motion.iconSwap) {
        model.isReloadingLanguage = false
      }
    }
  }

  private func externalRow(
    title: String,
    icon: String,
    destination: URL,
    accessibilityHint: String
  ) -> some View {
    Button {
      openURL(destination)
    } label: {
      SettingsPlainRow(
        title: title,
        icon: icon,
        showsExternalLink: true
      )
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityHint(accessibilityHint)
  }
}

struct SettingsAccountsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.dashNavigationEntryID) private var navigationEntryID
  @State private var pendingAccount: CloudflareAccount?

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(model.accounts) { account in
          Button {
            guard account.id != model.activeAccountID else {
              guard let navigationEntryID else { return }
              navigator?.dismiss(entryID: navigationEntryID)
              return
            }
            DashDelight.lightImpact()
            pendingAccount = account
          } label: {
            SettingsPlainRow(
              title: account.name,
              subtitle: account.id == model.activeAccountID
                ? DashL10n.string("Active account") : nil,
              icon: SolarAsset.users
            ) {
              DashSelectionMark(isSelected: account.id == model.activeAccountID)
            }
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityAddTraits(account.id == model.activeAccountID ? .isSelected : [])
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.horizontal, DashTheme.Spacing.rowInset)
      .padding(.top, DashTheme.Spacing.section)
      .padding(.bottom, DashTheme.Spacing.scrollBottomInset)
    }
    .background(DashTheme.canvas.ignoresSafeArea())
    .detailHeader(icon: .solar(SolarAsset.Content.user), title: "Switch account")
    .dashTray(
      item: $pendingAccount,
      title: { _ in DashL10n.string("Switch account") },
      content: { account in
        AccountSwitchConfirmationContent(account: account) {
          model.selectAccount(account)
        }
      }
    )
  }
}

/// Settings asks the same two decisions as the Profile tray, but one step at a
/// time: the shared copy becomes the tray's description — a one-step tray has a
/// standing explanation of itself rather than a step's content — and the shared
/// controls sit in the body, cancelling by dismissing because there is no
/// previous step to pop to.
private struct AccountSwitchConfirmationContent: View {
  let account: CloudflareAccount
  let confirm: () -> Void

  var body: some View {
    AccountSwitchConfirmationActions(confirm: confirm)
      .dashTrayDescription(AccountDecisionCopy.switchMessage(for: account))
  }
}

/// Settings' sign-out row already names the action, so its tray begins on the
/// destructive confirmation instead of repeating Sign out as a menu choice.
enum SignOutTrayStep: Hashable, Sendable {
  case confirm

  static let initial = Self.confirm

  var trayRole: DashTrayStepRole { .destructive }
}

/// Settings' direct sign-out confirmation. It owns the confirm pill's phase
/// because `AppRootView` holds the signed-in stage while that phase is
/// `.succeeded` and swaps to sign-in only when the pill's success check reports
/// back through `completeSignOutActionPresentation`.
private struct SignOutConfirmationContent: View {
  @Environment(\.dashTrayDismiss) private var dismiss

  var body: some View {
    DashTrayFlow(route: SignOutTrayStep.initial, role: SignOutTrayStep.initial.trayRole) { _ in
      confirmation
    }
    .frame(maxWidth: .infinity)
  }

  private var confirmation: some View {
    VStack(spacing: 16) {
      AccountDecisionMessage(text: AccountDecisionCopy.signOutConsequences)

      SignOutConfirmationActions(
        cancel: dismiss,
        confirmIdentifier: "settings-sign-out-confirm"
      )
    }
  }
}

private enum WorkspaceGlowTrayStep: Hashable, Sendable {
  case picker
  case inspiration(DashWorkspaceGlowPreset)

  var trayRole: DashTrayStepRole {
    switch self {
    case .picker: .root
    case .inspiration: .detail
    }
  }

  var title: String {
    switch self {
    case .picker: DashL10n.string("Glow")
    case .inspiration(let preset): preset.displayName
    }
  }
}

private struct WorkspaceGlowPanelMorphModifier: ViewModifier {
  let id: String?
  let namespace: Namespace.ID
  let isSource: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if let id {
      content.matchedGeometryEffect(
        id: id,
        in: namespace,
        properties: .frame,
        anchor: .center,
        isSource: isSource
      )
    } else {
      content
    }
  }
}

private enum WorkspaceGlowPanelMorphElement: String {
  case panel
  case label
}

private struct WorkspaceGlowPanelSurface: View {
  let preset: DashWorkspaceGlowPreset

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        DashTheme.canvas

        if preset != .none {
          DashWorkspaceGlowField(
            color: DashTheme.workspaceWash(for: preset),
            depth: max(geometry.size.height, 1)
          )
          .frame(maxHeight: .infinity, alignment: .top)
        } else {
          SolarIcon(asset: SolarAsset.sun, size: 36, color: DashTheme.iconMuted)
            .overlay {
              Rectangle()
                .fill(DashTheme.iconMuted)
                .frame(width: 1.5, height: 46)
                .rotationEffect(.degrees(45))
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 48)
            .accessibilityHidden(true)
        }
      }
    }
    .clipShape(shape)
    .overlay {
      shape.strokeBorder(DashTheme.separator, lineWidth: 1)
    }
  }
}

private struct WorkspaceGlowPanelOutline: View {
  let color: Color

  var body: some View {
    RoundedRectangle(
      cornerRadius: DashTheme.Radius.card + WorkspaceGlowPickerMetrics.outlineOutset,
      style: .continuous
    )
    .strokeBorder(
      color,
      lineWidth: WorkspaceGlowPickerMetrics.outlineLineWidth
    )
    .padding(-WorkspaceGlowPickerMetrics.outlineOutset)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// The wash surface and its emphasized ring are one physical object. Keeping
/// the outline inside the panel's matched seat prevents two nominally equal
/// springs from producing visibly different intermediate frames.
private struct WorkspaceGlowPanelHero: View {
  let preset: DashWorkspaceGlowPreset
  let outlineColor: Color
  let showsOutline: Bool

  var body: some View {
    WorkspaceGlowPanelSurface(preset: preset)
      .overlay {
        WorkspaceGlowPanelOutline(color: outlineColor)
          .opacity(showsOutline ? 1 : 0)
      }
  }
}

private struct WorkspaceGlowPickerTray: View {
  @Binding var workspaceGlowRaw: String
  @Environment(\.dashTrayDismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var centeredPresetID: String?
  @State private var centeredPresetPositionIsReady = false
  @State private var path: [WorkspaceGlowTrayStep] = []
  @State private var morphingPreset: DashWorkspaceGlowPreset?
  @State private var morphingOutlinedPreset: DashWorkspaceGlowPreset?
  @State private var morphUsesCenteredAnchor = false
  @State private var deferredExternalPresetID: String?
  @State private var inspirationReturnGeneration = 0
  @Namespace private var inspirationPanelMorph
  @Namespace private var centeredInspirationPanelMorph

  private var selectedPreset: DashWorkspaceGlowPreset {
    DashWorkspaceGlowPreset.resolved(stored: workspaceGlowRaw)
  }

  private var activeStep: WorkspaceGlowTrayStep {
    path.last ?? .picker
  }

  private var activeTone: FeatureVisualTone? {
    switch activeStep {
    case .picker: selectedPreset.trayTone
    case .inspiration(let preset): preset.trayTone
    }
  }

  private var centeredMorphAnchorPreset: DashWorkspaceGlowPreset? {
    if morphUsesCenteredAnchor, let morphingPreset {
      return morphingPreset
    }
    guard
      let centeredPresetID,
      let preset = DashWorkspaceGlowPreset.allCases.first(where: { $0.id == centeredPresetID }),
      preset.inspiration != nil
    else { return nil }
    return preset
  }

  private var activeInspirationMorphNamespace: Namespace.ID {
    morphUsesCenteredAnchor ? centeredInspirationPanelMorph : inspirationPanelMorph
  }

  /// Normal motion keeps both route canvases mounted. Supporting content fades
  /// between them, while the visible detail hero follows the stable compact
  /// anchor without putting route alpha over the matched surface.
  private var pickerContentIsVisible: Bool {
    reduceMotion || path.isEmpty
  }

  /// `DashTrayFlow.heroMorph` retains the root route even when Reduce Motion
  /// cross-fades that whole route. Key filter lifetime to the active route, not
  /// to supporting-content visibility, so hidden side backdrops never linger.
  private var pickerEdgeStrength: CGFloat {
    path.isEmpty ? 1 : 0
  }

  private var inspirationContentIsVisible: Bool {
    reduceMotion || !path.isEmpty
  }

  private var supportingTransitionAnimation: Animation? {
    guard !reduceMotion else { return nil }
    return path.isEmpty ? DashTheme.Motion.morphExit : DashTheme.Motion.morph
  }

  /// The outgoing picker remains alive while `DashTrayFlow` transitions to a
  /// detail. Its transformed ScrollView must not feed a newly resolved target
  /// back into selection; only the seeded, live root picker owns position
  /// writes.
  private var centeredPresetPosition: Binding<String?> {
    Binding(
      get: { centeredPresetID },
      set: { proposedID in
        guard
          path.isEmpty,
          morphingPreset == nil,
          centeredPresetPositionIsReady
        else { return }
        centeredPresetID = proposedID
      }
    )
  }

  private var flowPath: Binding<[WorkspaceGlowTrayStep]> {
    Binding(
      get: { path },
      set: { proposedPath in
        let isReturningToPicker = !path.isEmpty && proposedPath.isEmpty
        guard isReturningToPicker else {
          path = proposedPath
          return
        }

        inspirationReturnGeneration += 1
        let returnGeneration = inspirationReturnGeneration

        guard !reduceMotion else {
          path = proposedPath
          completeInspirationReturn()
          return
        }

        withAnimation(
          DashTheme.Motion.morphExit,
          completionCriteria: .removed
        ) {
          path = proposedPath
        } completion: {
          guard
            path.isEmpty,
            inspirationReturnGeneration == returnGeneration
          else { return }
          completeInspirationReturn()
        }
      }
    )
  }

  var body: some View {
    DashTrayFlow(
      root: .picker,
      path: flowPath,
      role: \.trayRole,
      transitionStyle: .heroMorph
    ) { step in
      switch step {
      case .picker:
        picker
      case .inspiration(let preset):
        inspiration(for: preset)
      }
    }
    .animation(supportingTransitionAnimation, value: path)
    .dashTrayTitle(activeStep.title)
    .dashTrayContentTone(activeTone)
    .environment(\.dashTrayTone, activeTone)
    .onChange(of: workspaceGlowRaw) { _, stored in
      guard centeredPresetPositionIsReady else { return }
      let externallySelected = DashWorkspaceGlowPreset.resolved(stored: stored)
      // Local taps move the scroll owner before they persist the preset, so an
      // equal ID is a no-op. A real external write (including iCloud KVS) is
      // the only path that recentres the picker from the persisted value.
      guard centeredPresetID != externallySelected.id else {
        deferredExternalPresetID = nil
        return
      }
      guard path.isEmpty, morphingPreset == nil else {
        deferredExternalPresetID = externallySelected.id
        return
      }
      deferredExternalPresetID = nil
      clearInspirationMorph()
      withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
        centeredPresetID = externallySelected.id
      }
    }
  }

  private func clearInspirationMorph() {
    guard morphingPreset != nil else { return }
    inspirationReturnGeneration += 1
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      morphingPreset = nil
      morphingOutlinedPreset = nil
      morphUsesCenteredAnchor = false
    }
  }

  private func completeInspirationReturn() {
    let deferredPresetID = deferredExternalPresetID
    deferredExternalPresetID = nil
    clearInspirationMorph()

    guard
      let deferredPresetID,
      centeredPresetID != deferredPresetID
    else { return }
    withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
      centeredPresetID = deferredPresetID
    }
  }

  private var picker: some View {
    // Selection still writes immediately so the workspace wash previews live
    // behind the tray; Done is just the explicit close, same band as Language.
    // Re-publish tray tone here so the submit pill tracks the live draft even
    // if the cover's presenting tone is sticky for the presentation.
    DashTrayScrollBoundary {
      GeometryReader { proxy in
        ZStack {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: WorkspaceGlowPickerMetrics.cardSpacing) {
              ForEach(DashWorkspaceGlowPreset.allCases) { preset in
                glowCard(for: preset)
                  .id(preset.id)
              }
            }
            .scrollTargetLayout()
            .padding(.vertical, WorkspaceGlowPickerMetrics.cardVerticalInset)
          }
          .contentMargins(
            .horizontal,
            WorkspaceGlowPickerMetrics.horizontalInset(viewportWidth: proxy.size.width),
            for: .scrollContent
          )
          .scrollPosition(id: centeredPresetPosition, anchor: .center)
          .scrollTargetBehavior(WorkspaceGlowCenteredScrollTargetBehavior())
          .simultaneousGesture(
            DragGesture(minimumDistance: 1)
              .onChanged { _ in clearInspirationMorph() }
          )
          .onAppear {
            guard !centeredPresetPositionIsReady else { return }
            // A non-nil target installed before this horizontal scroll mounts is
            // not consumed on iOS 26: the state says Ember while the physical
            // offset stays on None. Create the target edge only after the scroll
            // exists, and reject its default-position write until this seed lands.
            centeredPresetID = selectedPreset.id
            centeredPresetPositionIsReady = true
          }
          // Unramped, unlike the dynamic vertical fades: `contentMargins` centres
          // the end cards, so at either extreme the treatment lands on empty tray
          // surface and paints that surface over itself — invisible without any
          // offset to track. Mid-scroll it defocuses, then dissolves, a passing card.
          .overlay(alignment: .leading) {
            DashScrollEdgeEffect(
              edge: .leading,
              surface: DashTheme.Sheet.background,
              thickness: WorkspaceGlowPickerMetrics.edgeFadeWidth,
              style: .fadeAndBlur,
              strength: pickerEdgeStrength
            )
          }
          .overlay(alignment: .trailing) {
            DashScrollEdgeEffect(
              edge: .trailing,
              surface: DashTheme.Sheet.background,
              thickness: WorkspaceGlowPickerMetrics.edgeFadeWidth,
              style: .fadeAndBlur,
              strength: pickerEdgeStrength
            )
          }

          if let centeredPreset = centeredMorphAnchorPreset {
            centeredMorphAnchor(for: centeredPreset)
          }
        }
      }
      .frame(height: WorkspaceGlowPickerMetrics.viewportHeight)
      // SwiftUI owns the centered target while this tray is mounted. Keep the
      // bridge one-way: feeding the resulting preset back into scrollPosition
      // closes an AttributeGraph loop during the same layout transaction.
      .onChange(of: centeredPresetID) { _, presetID in
        guard
          let presetID,
          let preset = DashWorkspaceGlowPreset.allCases.first(where: { $0.id == presetID })
        else { return }
        select(preset)
      }
    } action: {
      DashActionButton(title: DashL10n.string("Done")) {
        dismiss()
      }
      .padding(.top, 16)
      .opacity(pickerContentIsVisible ? 1 : 0)
      .accessibilityIdentifier("settings-workspace-glow-done")
    }
    // The retained detail hero owns the whole return flight. Re-enabling the
    // carousel before its rendered endpoint would let a drag tear down the
    // matched identity mid-spring and recreate the snap this handoff prevents.
    .allowsHitTesting(morphingPreset == nil)
  }

  private func glowCard(for preset: DashWorkspaceGlowPreset) -> some View {
    let isSelected = selectedPreset == preset
    let isCentered = centeredPresetID == preset.id
    let shape = RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
    let selectionColor =
      preset == .none ? DashTheme.text : DashTheme.workspaceWash(for: preset)

    let compactVisualIsVisible = reduceMotion || morphingPreset != preset

    return ZStack(alignment: .topLeading) {
      Button {
        clearInspirationMorph()
        if centeredPresetID != preset.id {
          withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
            centeredPresetID = preset.id
          }
        }
        select(preset)
      } label: {
        ZStack(alignment: .topTrailing) {
          WorkspaceGlowPanelHero(
            preset: preset,
            outlineColor: selectionColor,
            showsOutline: isSelected
          )
          .frame(
            width: WorkspaceGlowPickerMetrics.cardWidth,
            height: WorkspaceGlowPickerMetrics.cardHeight
          )
          .opacity(pickerContentIsVisible && compactVisualIsVisible ? 1 : 0)
          .animation(
            morphingPreset == preset ? nil : supportingTransitionAnimation,
            value: pickerContentIsVisible
          )

          Text(preset.displayName)
            .dashTextStyle(.bodySemibold)
            .foregroundStyle(DashTheme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .opacity(pickerContentIsVisible && compactVisualIsVisible ? 1 : 0)
            .animation(
              morphingPreset == preset ? nil : supportingTransitionAnimation,
              value: pickerContentIsVisible
            )
            // Match the glyph itself. Positioning lives outside the identity so
            // the title travels from the compact bottom seat to the detail's
            // leading seat instead of scaling a card-sized text container.
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
            .frame(
              width: WorkspaceGlowPickerMetrics.cardWidth,
              height: WorkspaceGlowPickerMetrics.cardHeight,
              alignment: .bottom
            )

          compactSideMorphAnchors(for: preset)

          DashSelectionMark(
            isSelected: isSelected,
            size: 20,
            selectedColor: selectionColor
          )
          .padding(10)
          .opacity(pickerContentIsVisible ? 1 : 0)
        }
        .contentShape(shape)
      }
      .buttonStyle(DashSurfaceButtonStyle())
      .accessibilityLabel(preset.displayName)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityIdentifier("workspace-glow-preset-\(preset.rawValue)")

      if preset.inspiration != nil {
        Button {
          inspirationReturnGeneration += 1
          morphingPreset = preset
          // The expanded ring describes the active selection, not merely the
          // inspiration source. A side card therefore morphs without borrowing
          // the centred card's outline semantics.
          morphingOutlinedPreset = isCentered ? preset : nil
          morphUsesCenteredAnchor = !reduceMotion && isCentered
          path.append(.inspiration(preset))
        } label: {
          SolarIcon(asset: SolarAsset.starsBold, size: 18, color: DashTheme.strong)
            .dashCompactHitTarget()
        }
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel(
          String(
            format: DashL10n.string("Inspiration for %@"),
            preset.displayName
          )
        )
        .accessibilityIdentifier("workspace-glow-inspiration-\(preset.rawValue)")
        .padding(4)
        .opacity(pickerContentIsVisible ? 1 : 0)
      }
    }
  }

  /// The centered source is a permanent transparent anchor outside the
  /// ScrollView coordinate space. It is registered before Stars can be tapped,
  /// so the morph never has to migrate an identity from a scrolling occurrence.
  private func centeredMorphAnchor(for preset: DashWorkspaceGlowPreset) -> some View {
    return ZStack(alignment: .topTrailing) {
      Color.clear
        .frame(
          width: WorkspaceGlowPickerMetrics.cardWidth,
          height: WorkspaceGlowPickerMetrics.cardHeight
        )
        .modifier(
          WorkspaceGlowPanelMorphModifier(
            id: centeredInspirationMorphID(for: preset, element: .panel),
            namespace: centeredInspirationPanelMorph,
            isSource: path.isEmpty
          )
        )

      Text(preset.displayName)
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(DashTheme.text)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .opacity(0)
        .modifier(
          WorkspaceGlowPanelMorphModifier(
            id: centeredInspirationMorphID(for: preset, element: .label),
            namespace: centeredInspirationPanelMorph,
            isSource: path.isEmpty
          )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 16)
        .frame(
          width: WorkspaceGlowPickerMetrics.cardWidth,
          height: WorkspaceGlowPickerMetrics.cardHeight,
          alignment: .bottom
        )
    }
    .frame(
      width: WorkspaceGlowPickerMetrics.cardWidth,
      height: WorkspaceGlowPickerMetrics.cardHeight
    )
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func compactSideMorphAnchors(for preset: DashWorkspaceGlowPreset) -> some View {
    Color.clear
      .frame(
        width: WorkspaceGlowPickerMetrics.cardWidth,
        height: WorkspaceGlowPickerMetrics.cardHeight
      )
      .modifier(
        WorkspaceGlowPanelMorphModifier(
          id: sideInspirationMorphID(for: preset, element: .panel),
          namespace: inspirationPanelMorph,
          isSource: path.isEmpty
        )
      )

    Text(preset.displayName)
      .dashTextStyle(.bodySemibold)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .opacity(0)
      .modifier(
        WorkspaceGlowPanelMorphModifier(
          id: sideInspirationMorphID(for: preset, element: .label),
          namespace: inspirationPanelMorph,
          isSource: path.isEmpty
        )
      )
      .padding(.horizontal, 10)
      .padding(.bottom, 16)
      .frame(
        width: WorkspaceGlowPickerMetrics.cardWidth,
        height: WorkspaceGlowPickerMetrics.cardHeight,
        alignment: .bottom
      )
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private func inspiration(for preset: DashWorkspaceGlowPreset) -> some View {
    if let inspiration = preset.inspiration {
      let color = DashTheme.workspaceWash(for: preset)
      let heroHeight = inspirationHeroHeight(for: preset)
      VStack(alignment: .leading, spacing: DashTheme.Spacing.section) {
        ZStack(alignment: .bottomLeading) {
          if reduceMotion {
            WorkspaceGlowPanelHero(
              preset: preset,
              outlineColor: color,
              showsOutline: morphingOutlinedPreset == preset
            )
            .frame(height: WorkspaceGlowPickerMetrics.inspirationHeight)

            Text(preset.displayName)
              .dashTextStyle(.bodySemibold)
              .foregroundStyle(DashTheme.text)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
              .padding(18)
          } else if morphingPreset == preset {
            // The detail route owns the visible hero for the entire flight.
            // On push it inherits the already-rendered compact anchor frame;
            // on pop the retained route follows that anchor all the way home
            // before `flowPath` hands rendering back to the real card.
            WorkspaceGlowPanelHero(
              preset: preset,
              outlineColor: color,
              showsOutline: morphingOutlinedPreset == preset
            )
            .frame(height: heroHeight)
            .modifier(
              WorkspaceGlowPanelMorphModifier(
                id: detailInspirationMorphID(for: preset, element: .panel),
                namespace: activeInspirationMorphNamespace,
                isSource: !path.isEmpty
              )
            )

            Text(preset.displayName)
              .dashTextStyle(.bodySemibold)
              .foregroundStyle(DashTheme.text)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
              .modifier(
                WorkspaceGlowPanelMorphModifier(
                  id: detailInspirationMorphID(for: preset, element: .label),
                  namespace: activeInspirationMorphNamespace,
                  isSource: !path.isEmpty
                )
              )
              .padding(18)
          }
        }
        .frame(height: heroHeight)
        .accessibilityIdentifier("workspace-glow-inspiration-panel-\(preset.rawValue)")

        VStack(alignment: .leading, spacing: DashTheme.Spacing.itemGap) {
          HStack(spacing: 8) {
            SolarIcon(asset: SolarAsset.starsBold, size: 17, color: DashTheme.strong)
            Text(DashL10n.string("Inspired by"))
              .dashTextStyle(.captionSemibold)
              .foregroundStyle(DashTheme.subtle)
          }

          VStack(alignment: .leading, spacing: DashTheme.Spacing.listRow) {
            Text(inspiration.source)
              .dashTextStyle(.bodySemibold)
              .foregroundStyle(DashTheme.text)

            Text(inspiration.description)
              .dashTextStyle(.supporting)
              .foregroundStyle(DashTheme.subtle)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .opacity(inspirationContentIsVisible ? 1 : 0)
        .transition(.opacity)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
  }

  /// The retained detail owns the visible return all the way through the
  /// rendered spring. Give it the compact card's real height before the final
  /// ownership handoff so clearing the morph cannot reveal a taller view.
  private func inspirationHeroHeight(for preset: DashWorkspaceGlowPreset) -> CGFloat {
    guard !reduceMotion, path.isEmpty, morphingPreset == preset else {
      return WorkspaceGlowPickerMetrics.inspirationHeight
    }
    return WorkspaceGlowPickerMetrics.cardHeight
  }

  private func inspirationMorphID(
    for preset: DashWorkspaceGlowPreset,
    element: WorkspaceGlowPanelMorphElement
  ) -> String? {
    guard !reduceMotion, preset.inspiration != nil else { return nil }
    // Pre-register every compact source while the picker is active, but once a
    // detail owns the source role keep only its matching seat in the namespace.
    // Unrelated non-source nodes add no visual value and can create needless
    // AttributeGraph relationships during the tray's fitted-height animation.
    guard path.isEmpty || morphingPreset == preset else { return nil }
    return "workspace-glow-inspiration-\(preset.rawValue)-\(element.rawValue)"
  }

  private func centeredInspirationMorphID(
    for preset: DashWorkspaceGlowPreset,
    element: WorkspaceGlowPanelMorphElement
  ) -> String? {
    guard path.isEmpty || (morphUsesCenteredAnchor && morphingPreset == preset) else {
      return nil
    }
    return inspirationMorphID(for: preset, element: element)
  }

  private func sideInspirationMorphID(
    for preset: DashWorkspaceGlowPreset,
    element: WorkspaceGlowPanelMorphElement
  ) -> String? {
    guard path.isEmpty || (!morphUsesCenteredAnchor && morphingPreset == preset) else {
      return nil
    }
    return inspirationMorphID(for: preset, element: element)
  }

  private func detailInspirationMorphID(
    for preset: DashWorkspaceGlowPreset,
    element: WorkspaceGlowPanelMorphElement
  ) -> String? {
    guard morphingPreset == preset else { return nil }
    return inspirationMorphID(for: preset, element: element)
  }

  private func select(_ preset: DashWorkspaceGlowPreset) {
    guard workspaceGlowRaw != preset.rawValue else { return }
    // The same write animates the live workspace wash behind the tray and the
    // card's static selection cues; swiping can interrupt it at any point.
    withAnimation(reduceMotion ? nil : DashTheme.Motion.morph) {
      workspaceGlowRaw = preset.rawValue
    }
    DashDelight.selectionChanged()
  }
}

enum WorkspaceGlowPickerMetrics {
  static let cardWidth: CGFloat = 126
  static let cardHeight: CGFloat = 184
  static let inspirationHeight: CGFloat = 160
  static let cardSpacing = DashTheme.Spacing.itemGap
  static let outlineGap: CGFloat = 1
  static let outlineLineWidth: CGFloat = 2
  static let outlineOutset = outlineGap + outlineLineWidth
  /// Air above and below the cards, inside the scrolling region so the outer
  /// selection ring has room to keep its gap and continuous corner arcs.
  static let cardVerticalInset: CGFloat = 8
  static let viewportHeight = cardHeight + cardVerticalInset * 2
  static let edgeFadeWidth = DashScrollEdgeFadeMetrics.thickness

  /// Enough inset to centre one card, but never less than the fade that would
  /// otherwise cover an end card the scroll can no longer move.
  static func horizontalInset(viewportWidth: CGFloat) -> CGFloat {
    max(edgeFadeWidth, (viewportWidth - cardWidth) / 2)
  }
}

/// View-aligned momentum first chooses the nearest card, then the anchor moves
/// that target to the viewport's centre. This keeps native, interruptible
/// deceleration on iOS 17+ while making a swipe itself a picker interaction.
private struct WorkspaceGlowCenteredScrollTargetBehavior: ScrollTargetBehavior {
  private let viewAligned = ViewAlignedScrollTargetBehavior(limitBehavior: .always)

  func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
    viewAligned.updateTarget(&target, context: context)
    target.anchor = .center
  }
}

/// Two collapsed chart cards side by side, one pinned to each renderer.
///
/// The rows this replaced named the two styles and left the user to go find a
/// chart before the words meant anything. A style is a look, so the option is
/// the look: `DashCollapsedChartCard` is the app's one half-row chart pose, and
/// both panels plot the same sample series so the only difference on screen is
/// the difference being chosen.
private struct ChartStylePickerTray: View {
  @Binding var chartStyleRaw: String
  @Environment(\.dashTrayDismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  /// Draft only — `chartStyleRaw` commits on Done, same band as Language and
  /// Glow. Glow writes through immediately because its effect is the workspace
  /// *behind* the tray; here the effect is already on the card, so there is
  /// nothing an early write would show that the panels do not.
  @State private var draftRaw: String

  init(chartStyleRaw: Binding<String>) {
    _chartStyleRaw = chartStyleRaw
    _draftRaw = State(initialValue: chartStyleRaw.wrappedValue)
  }

  /// Fixed preview data, run through the same floor-lift both real collapsed
  /// cards use. A generated series would redraw on every body pass and the two
  /// panels would stop being comparable.
  private static let sample = CollapsedDitherTrendSeries(values: [
    18, 26, 21, 34, 46, 39, 55, 62, 48, 67, 79, 70, 86, 94, 88, 76,
  ])
  private static let sampleSeriesID = "preview"

  private var draftStyle: DashChartStylePreference {
    DashChartStylePreference.resolved(stored: draftRaw)
  }

  /// Not `isAccessibilitySize`: a half-tray panel is ~155pt wide, and the
  /// card's one-line title runs under the selection mark well before the
  /// accessibility sizes — "Swift Charts" reaches the corner at xxLarge.
  private var stacksPanels: Bool {
    dynamicTypeSize >= .xxLarge
  }

  var body: some View {
    DashTrayScrollBoundary {
      Group {
        if stacksPanels {
          VStack(spacing: DashTheme.Spacing.itemGap) { panels }
        } else {
          HStack(alignment: .top, spacing: DashTheme.Spacing.itemGap) { panels }
        }
      }
      .dashTrayDescription(
        DashL10n.string(
          "Dither is Dash’s dotted look. Swift Charts uses the system chart style."
        )
      )
    } action: {
      DashActionButton(title: DashL10n.string("Done")) {
        commit()
      }
      .padding(.top, 16)
      .accessibilityIdentifier("settings-chart-style-done")
    }
  }

  @ViewBuilder private var panels: some View {
    ForEach(DashChartStylePreference.allCases) { preference in
      panel(preference)
    }
  }

  private func panel(_ preference: DashChartStylePreference) -> some View {
    let isSelected = draftStyle == preference
    return Button {
      select(preference)
    } label: {
      DashCollapsedChartCard(
        title: preference.titleKey,
        data: sampleData,
        series: sampleSeries,
        valueCeiling: Self.sample.valueCeiling,
        accessibilitySummary: DashL10n.string("Sample chart in this style.")
      )
      .dashChartStyle(preference)
      // On the card's own inset grid, so the mark's trailing edge lines up with
      // the title's leading one and their centres sit on the same line.
      .overlay(alignment: .topTrailing) {
        DashSelectionMark(isSelected: isSelected, size: 18)
          .padding(DashTheme.Spacing.card)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("chart-style-\(preference.rawValue)")
  }

  private func select(_ preference: DashChartStylePreference) {
    guard draftRaw != preference.rawValue else { return }
    draftRaw = preference.rawValue
    DashDelight.selectionChanged()
  }

  private func commit() {
    guard draftRaw != chartStyleRaw else {
      dismiss()
      return
    }
    chartStyleRaw = draftRaw
    DashChartStylePreference.mirrorToWidgets(draftRaw)
    dismiss()
  }

  private var sampleData: [DitherDatum] {
    Self.sample.values.enumerated().map { index, value in
      DitherDatum(
        id: "\(index)",
        label: "\(index)",
        values: [Self.sampleSeriesID: value])
    }
  }

  /// One gradient band — the variant that carries Dither's dot ramp, so the
  /// dithered panel states its case and the system panel answers with a smooth
  /// fill under a stroked line.
  private var sampleSeries: [DitherSeries] {
    [
      DitherSeries(
        id: Self.sampleSeriesID,
        label: DashL10n.string("Chart style"),
        color: DashTheme.DitherChart.brand(
          colorScheme: colorScheme,
          contrast: colorSchemeContrast),
        variant: .gradient)
    ]
  }
}

private struct LanguagePickerTray: View {
  @Binding var languageRaw: String
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  @Environment(\.dashTrayDismissAfter) private var dismissAfter
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Draft only — `languageRaw` commits on Done. Applying immediately remounts
  /// the app tree (`.id(languageRaw)`), which is why Done owns the write.
  @State private var draftRaw: String

  init(languageRaw: Binding<String>) {
    _languageRaw = languageRaw
    _draftRaw = State(initialValue: languageRaw.wrappedValue)
  }

  var body: some View {
    DashTrayScrollBoundary {
      Group {
        if dynamicTypeSize.isAccessibilitySize {
          VStack(spacing: DashTheme.Spacing.itemGap) {
            ForEach(DashAppLanguage.allCases) { language in
              languageOption(language, axis: .horizontal)
            }
          }
        } else {
          HStack(spacing: DashTheme.Spacing.compact) {
            ForEach(DashAppLanguage.allCases) { language in
              languageOption(language, axis: .vertical)
            }
          }
        }
      }
      .dashTrayDescription(
        DashL10n.string(
          "System follows the iPhone language, including Settings → Dash → Language.")
      )
    } action: {
      DashActionButton(title: DashL10n.string("Done")) {
        commit()
      }
      .padding(.top, 16)
      .accessibilityIdentifier("settings-language-done")
    }
  }

  @ViewBuilder
  private func languageOption(
    _ language: DashAppLanguage,
    axis: Axis
  ) -> some View {
    let isSelected = draftRaw == language.rawValue
    Button {
      guard draftRaw != language.rawValue else { return }
      draftRaw = language.rawValue
      DashDelight.selectionChanged()
    } label: {
      Group {
        if axis == .vertical {
          VStack(spacing: 12) {
            languageGlyph(for: language)
            Text(language.displayName)
              .dashTextStyle(.bodyMedium)
              .foregroundStyle(DashTheme.text)
              .multilineTextAlignment(.center)
              .lineLimit(2)
              .minimumScaleFactor(0.85)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 28)
          .frame(maxWidth: .infinity)
        } else {
          HStack(spacing: 14) {
            languageGlyph(for: language)
            Text(language.displayName)
              .dashTextStyle(.bodySemibold)
              .foregroundStyle(DashTheme.text)
              .lineLimit(1)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .frame(minHeight: DashTheme.Layout.minimumHitTarget)
        }
      }
      .overlay(alignment: .topTrailing) {
        // Language cards already read as a three-way choice — an empty circle
        // on the unselected two is furniture. Only the filled check lands.
        if isSelected {
          SolarIcon(
            asset: SolarAsset.checkCircleFill,
            size: axis == .vertical ? 26 : 28,
            color: DashTheme.brand
          )
          .padding(8)
          .transition(
            reduceMotion
              ? .opacity
              : .opacity.combined(
                with: .scale(scale: DashTheme.Motion.glyphSwapScale)))
        }
      }
      .animation(
        reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.glyphSwap,
        value: isSelected
      )
      .background(DashTheme.Sheet.shortcutItem)
      .clipShape(DashTheme.buttonShape)
      .contentShape(Rectangle())
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("settings-language-\(language.rawValue)")
  }

  @ViewBuilder
  private func languageGlyph(for language: DashAppLanguage) -> some View {
    Group {
      switch language {
      case .system:
        SolarIcon(asset: SolarAsset.smartphone, size: 36, color: DashTheme.iconMuted)
      case .english:
        Text(verbatim: "A")
          .font(.system(size: 34, weight: .bold))
          .foregroundStyle(DashTheme.iconMuted)
      case .simplifiedChinese:
        Text(verbatim: "文")
          .font(.system(size: 32, weight: .bold))
          .foregroundStyle(DashTheme.iconMuted)
      }
    }
    .frame(width: 36, height: 36)
    .accessibilityHidden(true)
  }

  private func commit() {
    guard draftRaw != languageRaw else {
      dismiss()
      return
    }
    let nextRaw = draftRaw
    // Cover first (behind the tray), then remount only after the tray's actual
    // dismissal completion — never a duration coupled to its current spring.
    model.isReloadingLanguage = true
    dismissAfter {
      DashAppLanguage.resolved(stored: nextRaw).applyToProcess()
      languageRaw = nextRaw
      // `.id(languageRaw)` remounts `AppRootView` in this update. Defer the
      // restore until the new `MainTabView` can consume it; `SettingsView`
      // clears the cover from its own onAppear, the real landing milestone.
      Task { @MainActor in
        model.pendingRoute = .settings
      }
    }
  }
}

private enum AboutDestination {
  static let github = URL(string: "https://github.com/withxat")!
  static let x = URL(string: "https://x.com/withxat")!
}

enum DashBuildMetadata {
  static let commitResourceName = "DashGitCommit"

  static func shortCommit(from rawValue: String?) -> String? {
    guard let rawValue else { return nil }
    let candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard candidate.count >= 7, candidate.allSatisfy(\.isHexDigit) else { return nil }
    return String(candidate.prefix(7)).lowercased()
  }

  static func shortCommit(in bundle: Bundle) -> String? {
    guard
      let url = bundle.url(forResource: commitResourceName, withExtension: "txt"),
      let rawValue = try? String(contentsOf: url, encoding: .utf8)
    else { return nil }
    return shortCommit(from: rawValue)
  }
}

/// About screen (Settings → About): one calm brand lockup followed by the app,
/// build, Cloudflare status, and developer facts people come here to find.
struct AboutView: View {
  private var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
  }

  private var build: String {
    DashBuildMetadata.shortCommit(in: .main) ?? "—"
  }

  private var copyrightYear: Int {
    Calendar.current.component(.year, from: .now)
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        AboutBrandHero()

        DashInfoGroup(title: "App details") {
          DashInfoRow("Version", value: version)
            .accessibilityIdentifier("about-version")
          DashInfoRow("Build", value: build, mono: true)
            .accessibilityIdentifier("about-build")
          DashInfoRow("Platform", value: "iPhone")
          DashInfoRow("Requires", value: DashL10n.string("iOS 17 or later"))
          DashInfoRow("License", value: "MIT")
        }

        CloudflareStatusSection()

        SettingsPlainSection(title: "Developer") {
          Link(destination: AboutDestination.github) {
            SettingsPlainRow(
              title: "GitHub",
              icon: SolarAsset.github,
              trailing: "@withxat",
              showsExternalLink: true
            )
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityIdentifier("about-github")

          Link(destination: AboutDestination.x) {
            SettingsPlainRow(
              title: "X",
              icon: SolarAsset.socialX,
              trailing: "@withxat",
              showsExternalLink: true
            )
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityIdentifier("about-x")
        }

        Text(
          verbatim:
            "\(DashL10n.string("Unofficial Cloudflare client")) · © \(copyrightYear) Xat"
        )
        .dashTextStyle(.caption)
        .foregroundStyle(DashTheme.placeholder)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.vertical, DashTheme.Spacing.section)
    }
    .background(DashTheme.canvas)
    .detailHeader(icon: .solar(SolarAsset.Content.infoCircle), title: "About")
  }

}

private struct AboutBrandHero: View {
  var body: some View {
    VStack(spacing: 16) {
      Image(DashTheme.Asset.appIcon)
        .resizable()
        .scaledToFit()
        .frame(width: 96, height: 96)
        .dashShadow(
          .raised,
          in: RoundedRectangle(
            cornerRadius: 96 * DashTheme.Radius.appIconCornerFactor,
            style: .continuous)
        )
        .accessibilityHidden(true)
        .frame(height: 136)

      Text("Dash")
        .dashTextStyle(.emptyTitle)
        .foregroundStyle(DashTheme.strong)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
  }
}

/// One credited open-source project: a name, a short purpose, its author, the
/// SPDX-style license, and a repository link. Names, authors, and license IDs
/// are proper nouns and render raw; only the `purpose` is localized.
private struct OpenSourceCredit: Identifiable {
  let name: String
  /// Localizable one-liner describing what Dash uses the project for.
  let purpose: String
  let author: String
  let license: String
  let url: URL

  var id: String { name }

  /// Libraries and vendored source that ship in the app binary.
  static let libraries: [OpenSourceCredit] = [
    OpenSourceCredit(
      name: "CodeEditor", purpose: "Code and JSON editing", author: "ZeeZide",
      license: "MIT", url: URL(string: "https://github.com/ZeeZide/CodeEditor")!),
    OpenSourceCredit(
      name: "Highlightr", purpose: "Syntax highlighting", author: "Juan Pablo Illanes",
      license: "MIT", url: URL(string: "https://github.com/raspu/Highlightr")!),
    OpenSourceCredit(
      name: "Paper Shaders", purpose: "Sign-in mesh gradient", author: "Paper",
      license: "Apache-2.0", url: URL(string: "https://github.com/paper-design/shaders")!),
    OpenSourceCredit(
      name: "VariableBlur", purpose: "Progressive header blur", author: "Nikita Starshinov",
      license: "MIT", url: URL(string: "https://github.com/nikstar/VariableBlur")!),
  ]

  /// Icon artwork Dash renders. Solar ships under CC BY 4.0, which requires
  /// this attribution — not merely a courtesy.
  static let icons: [OpenSourceCredit] = [
    OpenSourceCredit(
      name: "Solar Icons", purpose: "Interface icons", author: "480 Design",
      license: "CC BY 4.0", url: URL(string: "https://github.com/480-Design/Solar-Icon-Set")!),
    OpenSourceCredit(
      name: "Hugeicons", purpose: "File-type icons", author: "Hugeicons",
      license: "MIT", url: URL(string: "https://github.com/hugeicons/hugeicons")!),
    OpenSourceCredit(
      name: "MingCute", purpose: "Social and map icons", author: "MingCute Design",
      license: "Apache-2.0",
      url: URL(string: "https://github.com/mingcute-design/mingcute-icons")!),
  ]
}

/// A small neutral capsule carrying a license identifier (MIT, CC BY 4.0…).
private struct OpenSourceLicenseBadge: View {
  let license: String

  var body: some View {
    DashMetaBadge(license)
      .fixedSize()
  }
}

/// One tappable credit row: name + "purpose · author", a license badge, and an
/// external-link mark. Tapping opens the repository in the browser.
private struct OpenSourceCreditRow: View {
  let credit: OpenSourceCredit
  @Environment(\.openURL) private var openURL

  var body: some View {
    Button {
      openURL(credit.url)
    } label: {
      DashListRow(
        title: credit.name,
        subtitle: "\(DashL10n.ui(credit.purpose)) · \(credit.author)",
        showsChevron: false
      ) {
        HStack(spacing: 8) {
          OpenSourceLicenseBadge(license: credit.license)
          SolarIcon(
            asset: SolarAsset.arrowRightUp,
            size: DashTheme.Chevron.row,
            color: DashTheme.placeholder
          )
        }
      }
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityHint(DashL10n.string("Opens the project repository in your browser"))
    .dashListCardInset()
  }
}

/// Open-source acknowledgements (Settings → Open source): the third-party
/// libraries and icon sets Dash ships, each linking to its repository.
struct OpenSourceView: View {
  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        Text(
          DashL10n.string(
            "Dash is built with these open-source projects. Thank you to their authors and maintainers."
          )
        )
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)

        DashListGroup(title: "Libraries") {
          dashListCard {
            ForEach(OpenSourceCredit.libraries) { credit in
              OpenSourceCreditRow(credit: credit)
            }
          }
        }

        DashListGroup(title: "Icons") {
          dashListCard {
            ForEach(OpenSourceCredit.icons) { credit in
              OpenSourceCreditRow(credit: credit)
            }
          }
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.vertical, DashTheme.Spacing.section)
    }
    .background(DashTheme.canvas)
    .detailHeader(icon: .solar(SolarAsset.Content.code), title: "Open source")
  }
}

enum ProfileAccountRenameAccess {
  static let requiredScopes: Set<String> = ["account-settings.write"]

  static func isGranted(_ grantedScopes: Set<String>?) -> Bool {
    guard let grantedScopes else { return false }
    return requiredScopes.isSubset(of: grantedScopes)
  }
}

/// The standalone Profile page, pushed from the Settings hub's identity row:
/// identity, user id and registration date, and the active account's details.
/// Account switching and sign-out stay one level up in Settings.
struct ProfileView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dashNavigationEntryID) private var navigationEntryID
  @Environment(\.dashWorkspacePresentationState) private var workspacePresentationState
  @State private var avatarPickerItem: PhotosPickerItem?
  @State private var avatarPickerPresented = false
  @State private var avatarPickerReporterID = UUID()
  @State private var avatarActionPhase: DashActionPhase = .idle
  @State private var showsRename = false
  @State private var renameText = ""
  @State private var renameActionPhase: DashActionPhase = .idle
  @State private var renameError: String?

  private var canRenameAccount: Bool {
    ProfileAccountRenameAccess.isGranted(model.grantedScopes)
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        VStack(spacing: 12) {
          profileAvatar
          VStack(spacing: 4) {
            Text(model.profileTitle)
              .dashTextStyle(.sheetTitle)
              .foregroundStyle(DashTheme.strong)
            if let email = model.user?.email, email != model.profileTitle {
              Text(email)
                .dashTextStyle(.supporting)
                .foregroundStyle(DashTheme.subtle)
            }
            if !model.isDemoSession {
              Text(DashL10n.string("Custom photos are stored only in Dash on this iPhone."))
                .dashTextStyle(.footnote)
                .foregroundStyle(DashTheme.placeholder)
                .padding(.top, 2)
            }
          }
          if !model.isDemoSession,
            model.avatars.hasCustomImage(for: model.user?.id)
          {
            Button {
              Task { await restoreDefaultAvatar() }
            } label: {
              Text(DashL10n.string("Use default avatar"))
                .dashTextStyle(.footnoteSemibold)
                .foregroundStyle(DashTheme.brand)
                .frame(minHeight: DashTheme.Layout.minimumHitTarget)
                .padding(.horizontal, 8)
            }
            .buttonStyle(DashPressButtonStyle())
            .disabled(avatarActionPhase.isActive)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)

        DashCard {
          VStack(alignment: .leading, spacing: 0) {
            profileField(
              label: DashL10n.string("User ID"), value: model.user?.id ?? "—", mono: true)
            DashListGroupDivider()
            profileField(
              label: DashL10n.string("Registered"),
              value: formattedDate(model.user?.createdOn) ?? "—")
          }
        }

        if let account = model.activeAccount {
          VStack(alignment: .leading, spacing: 8) {
            if !canRenameAccount {
              DashAuthorizationDisclosure()
            }
            HStack(spacing: 12) {
              Text(DashL10n.string("Active account"))
                .dashTextStyle(.footnoteSemibold)
                .foregroundStyle(DashTheme.subtle)
              Spacer(minLength: 0)
              Button {
                guard canRenameAccount else {
                  model.requestAccess(to: ProfileAccountRenameAccess.requiredScopes)
                  return
                }
                renameError = nil
                renameText = account.name
                showsRename = true
              } label: {
                SolarIcon(asset: SolarAsset.pen, size: 18, color: DashTheme.brand)
                  .dashCompactHitTarget()
              }
              .buttonStyle(DashPressButtonStyle())
              .disabled(model.isAuthenticating)
              .accessibilityLabel(
                canRenameAccount
                  ? DashL10n.string("Rename account")
                  : DashL10n.string("Grant access to rename account")
              )
            }
            DashCard {
              VStack(alignment: .leading, spacing: 0) {
                profileField(label: DashL10n.string("Name"), value: account.name)
                DashListGroupDivider()
                profileField(label: DashL10n.string("Account ID"), value: account.id, mono: true)
                if let created = formattedDate(account.createdOn) {
                  DashListGroupDivider()
                  profileField(label: DashL10n.string("Created"), value: created)
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        // Registrations used to sit here, and then briefly in Resources. A
        // registration is now one card on the zone that owns the name, so this
        // group carries the audit log alone.
        DashListGroup(title: "Account") {
          dashListCard {
            DashListGroupLink(value: .auditLogs) {
              DashListRow(
                title: DashL10n.string("Audit log"),
                subtitle: DashL10n.string("Recent account activity"),
                icon: SolarAsset.Content.shieldCheck
              )
            }
            .accessibilityIdentifier("profile-audit-log-row")
            .dashListCardInset()
          }
        }

      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.vertical, DashTheme.Spacing.section)
    }
    .background(DashTheme.canvas)
    .detailHeader(icon: .solar(SolarAsset.Content.user), title: "Profile")
    .task(id: avatarPickerItem) {
      guard let avatarPickerItem else { return }
      await importAvatar(from: avatarPickerItem)
    }
    .dashTray(isPresented: $showsRename, title: DashL10n.string("Rename account")) {
      DashFormSheet(
        actionPhase: renameActionPhase,
        onSuccessPresentationCompleted: completeRenamePresentation,
        canSave: !renameText.trimmingCharacters(in: .whitespaces).isEmpty,
        onSave: { Task { await renameAccount() } }
      ) {
        VStack(spacing: 14) {
          if let renameError {
            DashNotice(kind: .error, message: renameError)
          }
          DashFormField(label: DashL10n.string("Name"), text: $renameText)
        }
      }
    }
  }

  @MainActor @ViewBuilder
  private var profileAvatar: some View {
    let email = model.user?.email ?? ""
    let userID = model.user?.id
    let hasCustomImage = model.avatars.hasCustomImage(for: userID)
    let avatarPhase = avatarActionPhase
    let usesReducedMotion = reduceMotion

    if model.isDemoSession {
      UserAvatar(email: email, size: 80)
    } else {
      Button {
        setAvatarPickerPresented(true)
      } label: {
        UserAvatar(email: email, size: 80)
          .overlay(alignment: .bottomTrailing) {
            ZStack {
              Circle().fill(DashTheme.canvas)
              Circle().fill(DashTheme.strong).padding(3)
              SolarIcon(
                asset: hasCustomImage ? SolarAsset.pen : SolarAsset.gallery,
                size: 14,
                color: DashTheme.inverse
              )
              .opacity(avatarPhase == .idle ? 1 : 0)
              .blur(radius: usesReducedMotion || avatarPhase == .idle ? 0 : 2)
              .scaleEffect(
                usesReducedMotion || avatarPhase == .idle
                  ? 1 : DashTheme.Motion.iconSwapScale
              )
              .animation(usesReducedMotion ? nil : DashTheme.Motion.iconSwap, value: avatarPhase)

              DashActionStatusIcon(
                phase: avatarPhase,
                loadingColor: DashTheme.inverse,
                size: 14,
                lineWidth: 2,
                onSuccessPresentationCompleted: completeAvatarPresentation
              )
            }
            .frame(width: 30, height: 30)
            .offset(x: 2, y: 2)
            .accessibilityHidden(true)
          }
      }
      .photosPicker(
        isPresented: $avatarPickerPresented,
        selection: $avatarPickerItem,
        matching: .images,
        preferredItemEncoding: .compatible
      )
      .onChange(of: avatarPickerPresented, initial: true) { _, presented in
        workspacePresentationState?.setCoverPresented(
          presented,
          reporterID: avatarPickerReporterID,
          entryID: navigationEntryID)
      }
      .buttonStyle(DashPressButtonStyle())
      .disabled(avatarPhase.isActive || userID == nil)
      .accessibilityLabel(DashL10n.string("Change profile photo"))
      .accessibilityValue(avatarPhase.accessibilityValue)
    }
  }

  @MainActor
  private func setAvatarPickerPresented(_ presented: Bool) {
    workspacePresentationState?.setCoverPresented(
      presented,
      reporterID: avatarPickerReporterID,
      entryID: navigationEntryID)
    avatarPickerPresented = presented
  }

  @MainActor
  private func importAvatar(from item: PhotosPickerItem) async {
    guard let userID = model.user?.id, !model.isDemoSession else {
      avatarPickerItem = nil
      return
    }
    avatarActionPhase = .loading
    defer { avatarPickerItem = nil }
    do {
      guard let imported = try await item.loadTransferable(type: AvatarPhotoImport.self) else {
        throw CustomAvatarError.invalidImage
      }
      try Task.checkCancellation()
      try await model.avatars.setCustomImage(imported.image, for: userID)
      try Task.checkCancellation()
      model.toasts.success(DashL10n.string("Saved successfully"))
      avatarActionPhase = .succeeded
    } catch is CancellationError {
      avatarActionPhase = .idle
      return
    } catch {
      avatarActionPhase = .idle
      model.toasts.error(
        DashL10n.string("Dash couldn’t use this photo. Try another image"))
    }
  }

  @MainActor
  private func restoreDefaultAvatar() async {
    guard let userID = model.user?.id, !model.isDemoSession else { return }
    avatarActionPhase = .loading
    do {
      try await model.avatars.removeCustomImage(
        for: userID, email: model.user?.email ?? "")
      try Task.checkCancellation()
      model.toasts.success(DashL10n.string("Saved successfully"))
      avatarActionPhase = .succeeded
    } catch is CancellationError {
      avatarActionPhase = .idle
      return
    } catch {
      avatarActionPhase = .idle
      model.toasts.error(
        DashL10n.string("Dash couldn’t update your profile photo. Try again"))
    }
  }

  private func completeAvatarPresentation() {
    guard avatarActionPhase == .succeeded else { return }
    avatarActionPhase = .idle
  }

  private func renameAccount() async {
    guard canRenameAccount else {
      model.requestAccess(to: ProfileAccountRenameAccess.requiredScopes)
      return
    }
    renameActionPhase = .loading
    renameError = nil
    do {
      try await model.renameActiveAccount(
        to: renameText.trimmingCharacters(in: .whitespaces))
      renameActionPhase = .succeeded
    } catch {
      renameActionPhase = .idle
      renameError = error.dashActionableMessage
    }
  }

  private func completeRenamePresentation() {
    guard renameActionPhase == .succeeded else { return }
    showsRename = false
    renameActionPhase = .idle
  }

  private func profileField(label: String, value: String, mono: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .dashTextStyle(.footnoteSemibold)
        .foregroundStyle(DashTheme.subtle)
      Text(value)
        .dashTextStyle(mono ? .codeBody : .supporting)
        .foregroundStyle(DashTheme.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Cloudflare timestamps arrive as ISO 8601, with or without fractional
  /// seconds; render them as a plain date.
  private func formattedDate(_ iso: String?) -> String? {
    guard let iso else { return nil }
    guard DashDateFormatting.date(fromISO8601: iso) != nil else { return iso }
    return DashDateFormatting.dateOnly(fromISO8601: iso)
  }
}

private struct AvatarPhotoImport: Transferable {
  let image: CustomAvatarFileStore.PreparedImage

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { received in
      let image = try CustomAvatarFileStore.prepareImage(from: received.file)
      return AvatarPhotoImport(image: image)
    }
  }
}
