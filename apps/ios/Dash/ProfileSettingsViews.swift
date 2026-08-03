import AppIntents
import CloudflareAPI
import CoreTransferable
import GradientAvatars
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// Avatar long-press account switcher with in-tray switch and sign-out
/// confirmations. Tapping the avatar still pushes Settings.
struct ProfileTrayContent: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var phase: ProfileTrayPhase

  var body: some View {
    ZStack {
      switch phase {
      case .accounts:
        accountList
          .transition(reduceMotion ? .opacity : .dashMorph)
      case .switchAccount(let account):
        accountSwitchMessage(account)
          .transition(reduceMotion ? .opacity : .dashMorph)
      case .signOut:
        signOutMessage
          .transition(reduceMotion ? .opacity : .dashMorph)
      }
    }
    .frame(maxWidth: .infinity)
    .dashTrayTitle(phase.title)
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
          withAnimation(DashTheme.Motion.morph) { phase = .switchAccount(account) }
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
    Text(
      DashL10n.string(
        "Switch to \(account.name)? Cached data and open screens for the current account will reset."
      )
    )
    .dashTextStyle(.supporting)
    .foregroundStyle(DashTheme.subtle)
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity)
    .padding(.top, 4)
  }

  private var signOutConsequences: String {
    [
      DashL10n.string("You'll need to reconnect your Cloudflare account to use Dash again."),
      DashL10n.string(
        "Any R2 locations mounted in Files and their downloaded copies will be removed from this iPhone."
      ),
    ].joined(separator: "\n\n")
  }

  private var signOutMessage: some View {
    Text(signOutConsequences)
      .dashTextStyle(.supporting)
      .foregroundStyle(DashTheme.subtle)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity)
      .padding(.top, 4)
  }
}

/// Fixed footer for `ProfileTrayContent`. Its height never participates in the
/// body's fitted-height animation, so the shared Sign out hero has one stable
/// global destination while account rows and confirmation copy morph above it.
struct ProfileTrayFooter: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var phase: ProfileTrayPhase
  @Namespace private var actionMorph

  /// Shared by the full-width Sign out pill and the half-width confirm pill so
  /// the enamel face shrinks into the Cancel + Sign out row — same
  /// `matchedGeometryEffect` path `DashConfirmableActions` uses for danger rows.
  private static let signOutMorphID = "profile-tray-sign-out"

  var body: some View {
    ZStack {
      switch phase {
      case .accounts:
        signOutSource
          .transition(reduceMotion ? .opacity : .dashMorph)
      case .switchAccount(let account):
        accountSwitchActions(account)
          .transition(reduceMotion ? .opacity : .dashMorph)
      case .signOut:
        signOutConfirmationActions
          .transition(reduceMotion ? .opacity : .dashMorph)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var signOutMorphID: String? {
    reduceMotion ? nil : Self.signOutMorphID
  }

  private var signOutMorphNamespace: Namespace.ID? {
    reduceMotion ? nil : actionMorph
  }

  private var signOutSource: some View {
    DashActionButton(
      title: "Sign out",
      role: .destructive,
      morphID: signOutMorphID,
      morphNamespace: signOutMorphNamespace
    ) {
      withAnimation(DashTheme.Motion.morph) { phase = .signOut }
    }
    .accessibilityIdentifier("profile-account-sign-out")
  }

  private func accountSwitchActions(_ account: CloudflareAccount) -> some View {
    DashTrayActionPair {
      DashTrayCancelButton {
        withAnimation(DashTheme.Motion.morph) { phase = .accounts }
      }
    } primary: {
      DashActionButton(title: "Switch account") {
        model.selectAccount(account)
        dismiss()
      }
    }
  }

  private var signOutConfirmationActions: some View {
    DashTrayActionPair {
      DashTrayCancelButton {
        withAnimation(DashTheme.Motion.morphExit) { phase = .accounts }
      }
      .disabled(model.signOutActionPhase.isActive)
    } primary: {
      DashActionButton(
        title: "Sign out",
        role: .destructive,
        phase: model.signOutActionPhase,
        morphID: signOutMorphID,
        morphNamespace: signOutMorphNamespace,
        onSuccessPresentationCompleted: model.completeSignOutActionPresentation
      ) {
        Task {
          await model.signOut(presentsCompletion: true)
        }
      }
    }
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
        Circle().stroke(DashTheme.line, lineWidth: 0.5)
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

      SolarIcon(
        asset: isActive ? SolarAsset.checkCircleFill : SolarAsset.circle,
        size: 22,
        color: isActive ? DashTheme.brand : DashTheme.placeholder
      )
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
    .background(DashTheme.Sheet.shortcutItem, in: DashTheme.buttonShape)
    .contentShape(DashTheme.buttonShape)
  }
}

enum ProfileTrayPhase: Equatable, Sendable {
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
}

private enum SettingsListMetrics {
  /// Same 24-in-36 slot as `DashListRow` / Resources — plate stays
  /// transparent; only the outline glyph paints.
  static let iconSize: CGFloat = 24
  static let iconColumn: CGFloat = 36
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
    .padding(.vertical, 12)
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
          .foregroundStyle(DashTheme.subtle)
          .multilineTextAlignment(.trailing)
          .lineLimit(usesStackedLayout ? nil : 1)
      }
      if let trailingIcon {
        SolarIcon(asset: trailingIcon, size: 20, color: DashTheme.placeholder)
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
  static let privacy = URL(string: "https://dash.xat.sh/privacy")!
  static let terms = URL(string: "https://dash.xat.sh/terms")!

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
  @AppStorage(WatchtowerNotifier.optInDefaultsKey) private var watchtowerNotifications = false
  @AppStorage(DashAppLanguage.storageKey) private var languageRaw = DashAppLanguage.system.rawValue
  @AppStorage(DashInteractionPreferences.hapticsKey) private var hapticsEnabled = true
  @AppStorage(DashWorkspaceWashPreset.storageKey) private var workspaceWashRaw =
    DashWorkspaceWashPreset.defaultPreset.rawValue
  @AppStorage(DashChartStylePreference.storageKey) private var chartStyleRaw =
    DashChartStylePreference.defaultStyle.rawValue
  @AppStorage(ICloudPreferencesSync.enabledKey) private var iCloudSyncEnabled = true
  @AppStorage(DashExperimentalFeatures.tunnelsKey) private var tunnelsExperimentalEnabled =
    false
  @State private var watchtowerNotificationsDenied = false
  @State private var showsLanguagePicker = false
  @State private var showsWorkspaceWashPicker = false
  @State private var showsChartStylePicker = false
  @State private var showsSignOutConfirmation = false

  private var selectedLanguage: DashAppLanguage {
    DashAppLanguage.resolved(stored: languageRaw)
  }

  private var selectedChartStyle: DashChartStylePreference {
    DashChartStylePreference.resolved(stored: chartStyleRaw)
  }

  private var selectedWorkspaceWash: DashWorkspaceWashPreset {
    DashWorkspaceWashPreset.resolved(stored: workspaceWashRaw)
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
            showsLanguagePicker = true
          } label: {
            SettingsPlainRow(
              title: DashL10n.string("Language"),
              icon: SolarAsset.globus,
              trailing: selectedLanguage.displayName,
              trailingIcon: SolarAsset.menuDots
            )
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityHint(DashL10n.string("Choose English, Simplified Chinese, or System"))

          // Appearance held this one row on its own; a single-row section is a
          // header the page pays for twice.
          Button {
            showsWorkspaceWashPicker = true
          } label: {
            SettingsPlainRow(
              title: DashL10n.string("Top glow"),
              icon: SolarAsset.sunset,
              trailing: selectedWorkspaceWash.displayName,
              trailingIcon: SolarAsset.menuDots
            )
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityIdentifier("workspace-wash-color")

          Button {
            showsChartStylePicker = true
          } label: {
            SettingsPlainRow(
              title: DashL10n.string("Chart style"),
              icon: SolarAsset.chart,
              trailing: selectedChartStyle.displayName,
              trailingIcon: SolarAsset.menuDots
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

        SettingsPlainSection(title: "Watchtower") {
          SettingsPlainToggleRow(
            title: DashL10n.string("Notifications"),
            icon: SolarAsset.inbox,
            isOn: $watchtowerNotifications
          )
          .onChange(of: watchtowerNotifications) { _, enabled in
            guard enabled else {
              watchtowerNotificationsDenied = false
              return
            }
            Task {
              let granted = await WatchtowerNotifier.requestAuthorization()
              if !granted {
                watchtowerNotifications = false
                watchtowerNotificationsDenied = true
                model.toasts.warning(
                  DashL10n.string(
                    "Notifications are turned off in iOS Settings. Enable them for Dash to get alerts."
                  ))
              }
            }
          }
          if watchtowerNotificationsDenied {
            DashNotice(
              kind: .warning,
              message: DashL10n.string(
                "Notifications are turned off in iOS Settings. Enable them for Dash to get alerts."
              )
            )
            .padding(.bottom, 8)
          }

          PushAlertsSettingsRows()
        }

        SettingsPlainSection(title: "Integrations") {
          // `ShortcutsLink` is the only supported way into Dash’s App Shortcuts
          // page. `shortcuts://` only restores Shortcuts’ last screen; there is
          // no public URI for an app’s own actions folder. Keep the link on top
          // with a full-row hit shape — burying it under the chrome leaves only
          // the system pill’s tiny target, which reads as a dead Settings row.
          SettingsPlainRow(
            title: DashL10n.string("Siri & Shortcuts"),
            icon: SolarAsset.bolt,
            showsChevron: true
          )
          .accessibilityHidden(true)
          .overlay {
            ShortcutsLink()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .contentShape(Rectangle())
              .opacity(0.02)
              .accessibilityLabel(DashL10n.string("Siri & Shortcuts"))
              .accessibilityHint(DashL10n.string("Opens the Shortcuts app"))
              .accessibilityIdentifier("settings-siri-shortcuts")
          }

          DashListGroupLink(value: .filesMount) {
            SettingsPlainRow(
              title: DashL10n.string("Files"),
              icon: SolarAsset.folder,
              showsChevron: true
            )
          }
        }

        SettingsPlainSection(title: "Experimental") {
          SettingsPlainToggleRow(
            title: DashL10n.string("Tunnels"),
            icon: SolarAsset.routing,
            isOn: $tunnelsExperimentalEnabled
          )
          .accessibilityIdentifier("settings-experimental-tunnels")
        }

        // Help, legal, and About were three-row and two-row sections stacked at
        // the foot of the page; the titles carry these rows on their own, so
        // the subtitles and the extra header are gone.
        SettingsPlainSection(title: "Help & about") {
          // Two `Group`s: one merged section now holds more rows than a single
          // `ViewBuilder` accepts, and `Group` nests them without changing the
          // enclosing stack's layout.
          Group {
            externalRow(
              title: DashL10n.string("Send feedback"),
              icon: SolarAsset.inbox,
              destination: DashHelpLink.feedback,
              accessibilityHint: DashL10n.string("Opens your email app")
            )

            externalRow(
              title: DashL10n.string("Privacy Policy"),
              icon: SolarAsset.shieldCheck,
              destination: DashHelpLink.privacy,
              accessibilityHint: DashL10n.string("Opens the policy on dash.xat.sh")
            )

            externalRow(
              title: DashL10n.string("Terms of Use"),
              icon: SolarAsset.file,
              destination: DashHelpLink.terms,
              accessibilityHint: DashL10n.string("Opens the terms on dash.xat.sh")
            )
          }

          Group {
            DashListGroupLink(value: .about) {
              SettingsPlainRow(
                title: DashL10n.string("About Dash"),
                icon: SolarAsset.userCircle,
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

            #if DEBUG
              DashListGroupLink(value: .debug) {
                SettingsPlainRow(
                  title: "Debug",
                  icon: SolarAsset.codeCircle,
                  showsChevron: true
                )
              }
            #endif
          }
        }

        SettingsPlainSection(title: "Account") {
          Button {
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
      isPresented: $showsWorkspaceWashPicker,
      title: DashL10n.string("Top glow")
    ) {
      WorkspaceWashPickerTray(workspaceWashRaw: $workspaceWashRaw)
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
    .onChange(of: workspaceWashRaw) { _, _ in
      ICloudPreferencesSync.shared.publish(.workspaceWash)
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
  @Environment(\.dismiss) private var dismiss
  @State private var pendingAccount: CloudflareAccount?

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(model.accounts) { account in
          Button {
            guard account.id != model.activeAccountID else {
              dismiss()
              return
            }
            pendingAccount = account
          } label: {
            SettingsPlainRow(
              title: account.name,
              subtitle: account.id == model.activeAccountID
                ? DashL10n.string("Active account") : nil,
              icon: SolarAsset.users
            ) {
              SolarIcon(
                asset: account.id == model.activeAccountID
                  ? SolarAsset.checkCircleFill : SolarAsset.circle,
                size: 22,
                color: account.id == model.activeAccountID
                  ? DashTheme.brand : DashTheme.placeholder
              )
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
          pendingAccount = nil
        }
      }
    )
  }
}

private struct AccountSwitchConfirmationContent: View {
  @Environment(AppModel.self) private var model
  let account: CloudflareAccount
  let cancel: () -> Void

  var body: some View {
    DashTrayActionPair {
      DashTrayCancelButton(action: cancel)
    } primary: {
      DashActionButton(title: "Switch account") {
        model.selectAccount(account)
      }
    }
    .dashTrayDescription(
      DashL10n.string(
        "Switch to \(account.name)? Cached data and open screens for the current account will reset."
      )
    )
  }
}

private struct SignOutConfirmationContent: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss

  /// Two consequences, two paragraphs — kept as separate catalog keys and
  /// joined here, because the Files sentence is only true of this app's mounts
  /// and must stay translatable on its own.
  private var consequences: String {
    [
      DashL10n.string("You'll need to reconnect your Cloudflare account to use Dash again."),
      DashL10n.string(
        "Any R2 locations mounted in Files and their downloaded copies will be removed from this iPhone."
      ),
    ].joined(separator: "\n\n")
  }

  var body: some View {
    DashTrayActionPair {
      DashTrayCancelButton(action: dismiss)
        .disabled(model.signOutActionPhase.isActive)
    } primary: {
      DashActionButton(
        title: "Sign out",
        role: .destructive,
        phase: model.signOutActionPhase,
        onSuccessPresentationCompleted: model.completeSignOutActionPresentation
      ) {
        Task {
          await model.signOut(presentsCompletion: true)
        }
      }
    }
    .dashTrayDescription(consequences)
  }
}

private struct WorkspaceWashPickerTray: View {
  @Binding var workspaceWashRaw: String
  @Environment(\.dashTrayDismiss) private var dismiss

  var body: some View {
    VStack(spacing: 12) {
      ForEach(DashWorkspaceWashPreset.allCases) { preset in
        let isSelected =
          DashWorkspaceWashPreset.resolved(stored: workspaceWashRaw) == preset
        Button {
          if workspaceWashRaw != preset.rawValue {
            workspaceWashRaw = preset.rawValue
            DashDelight.selectionChanged()
          }
          dismiss()
        } label: {
          HStack(spacing: 12) {
            Circle()
              .fill(DashTheme.workspaceWash(for: preset))
              .frame(width: 22, height: 22)
              .overlay(Circle().stroke(DashTheme.line, lineWidth: 1))
              .overlay {
                if preset == .none {
                  Rectangle()
                    .fill(DashTheme.iconMuted)
                    .frame(width: 1, height: 18)
                    .rotationEffect(.degrees(45))
                }
              }
              .accessibilityHidden(true)
            Text(preset.displayName)
              .dashTextStyle(.bodyMedium)
              .foregroundStyle(DashTheme.text)
              .lineLimit(1)
            Spacer(minLength: 0)
            SolarIcon(
              asset: isSelected ? SolarAsset.checkCircleFill : SolarAsset.circle,
              size: 22,
              color: isSelected ? DashTheme.brand : DashTheme.placeholder
            )
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .frame(minHeight: DashTheme.Layout.minimumHitTarget)
          .background(DashTheme.Sheet.shortcutItem)
          .clipShape(DashTheme.buttonShape)
          .contentShape(Rectangle())
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("workspace-wash-preset-\(preset.rawValue)")
      }
    }
  }
}

private struct ChartStylePickerTray: View {
  @Binding var chartStyleRaw: String
  @Environment(\.dashTrayDismiss) private var dismiss

  var body: some View {
    VStack(spacing: 12) {
      ForEach(DashChartStylePreference.allCases) { preference in
        let isSelected =
          DashChartStylePreference.resolved(stored: chartStyleRaw) == preference
        Button {
          guard chartStyleRaw != preference.rawValue else {
            dismiss()
            return
          }
          chartStyleRaw = preference.rawValue
          DashChartStylePreference.mirrorToWidgets(preference.rawValue)
          DashDelight.selectionChanged()
          dismiss()
        } label: {
          HStack(spacing: 12) {
            Text(preference.displayName)
              .dashTextStyle(.bodyMedium)
              .foregroundStyle(DashTheme.text)
              .lineLimit(1)
            Spacer(minLength: 0)
            SolarIcon(
              asset: isSelected ? SolarAsset.checkCircleFill : SolarAsset.circle,
              size: 22,
              color: isSelected ? DashTheme.brand : DashTheme.placeholder
            )
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .frame(minHeight: DashTheme.Layout.minimumHitTarget)
          .background(DashTheme.Sheet.shortcutItem)
          .clipShape(DashTheme.buttonShape)
          .contentShape(Rectangle())
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("chart-style-\(preference.rawValue)")
      }
    }
    .dashTrayDescription(
      DashL10n.string(
        "Dither is Dash’s dotted look. Swift Charts uses the system chart style."
      )
    )
  }
}

private struct LanguagePickerTray: View {
  @Binding var languageRaw: String
  @Environment(\.dashTrayDismiss) private var dismiss

  var body: some View {
    VStack(spacing: 12) {
      ForEach(DashAppLanguage.allCases) { language in
        let isSelected = languageRaw == language.rawValue
        Button {
          guard languageRaw != language.rawValue else {
            dismiss()
            return
          }
          language.applyToProcess()
          languageRaw = language.rawValue
          DashDelight.selectionChanged()
          dismiss()
        } label: {
          HStack(spacing: 12) {
            Text(language.displayName)
              .dashTextStyle(.bodyMedium)
              .foregroundStyle(DashTheme.text)
              .lineLimit(1)
            Spacer(minLength: 0)
            SolarIcon(
              asset: isSelected ? SolarAsset.checkCircleFill : SolarAsset.circle,
              size: 22,
              color: isSelected ? DashTheme.brand : DashTheme.placeholder
            )
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .frame(minHeight: DashTheme.Layout.minimumHitTarget)
          .background(DashTheme.Sheet.shortcutItem)
          .clipShape(DashTheme.buttonShape)
          .contentShape(Rectangle())
        }
        .buttonStyle(DashSurfaceButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
    .dashTrayDescription(
      DashL10n.string(
        "System follows the iPhone language, including Settings → Dash → Language.")
    )
  }
}

private enum AboutDestination {
  static let github = URL(string: "https://github.com/withxat")!
  static let x = URL(string: "https://x.com/withxat")!
}

/// About screen (Settings → About): one calm brand lockup followed by the
/// product, build, privacy, and developer facts people actually come here to
/// find.
struct AboutView: View {
  private var version: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
  }

  private var build: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
  }

  private var copyrightYear: Int {
    Calendar.current.component(.year, from: .now)
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        AboutBrandHero()

        DashCard {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
              SolarIcon(asset: SolarAsset.cloudflare, size: 22, color: DashTheme.accent)
              Text("Cloudflare, on the phone you already carry.")
                .dashTextStyle(.sectionTitle)
                .foregroundStyle(DashTheme.strong)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(
              "Purge cache, inspect traffic, roll back deployments, and browse R2. Domains, Workers, Pages, and KV stay native and portrait."
            )
            .dashTextStyle(.supporting)
            .foregroundStyle(DashTheme.subtle)
            .fixedSize(horizontal: false, vertical: true)
          }
        }

        DashInfoGroup(title: "App details") {
          DashInfoRow("Version", value: version)
            .accessibilityIdentifier("about-version")
          DashInfoRow("Build", value: build, mono: true)
            .accessibilityIdentifier("about-build")
          DashInfoRow("Platform", value: "iPhone")
          DashInfoRow("Requires", value: DashL10n.string("iOS 17 or later"))
          DashInfoRow("License", value: "MIT")
        }

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

        DashInfoGroup(title: "Privacy & security") {
          DashInfoRow("Analytics & tracking", value: DashL10n.string("None"))
          DashInfoRow("OAuth tokens", value: DashL10n.string("This iPhone’s Keychain"))
          DashInfoRow("Core account data", value: DashL10n.string("Direct to Cloudflare"))
          DashInfoRow("Resource cache", value: DashL10n.string("Current session"))
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
    .detailHeader(icon: .solar(SolarAsset.Content.cloud), title: "About")
  }

}

private struct AboutBrandHero: View {
  var body: some View {
    VStack(spacing: 16) {
      Image("LoginAppIcon")
        .resizable()
        .scaledToFit()
        .frame(width: 96, height: 96)
        .dashShadow(
          .raised,
          in: RoundedRectangle(cornerRadius: 96 * 0.2237, style: .continuous)
        )
        .accessibilityHidden(true)
        .frame(height: 136)

      VStack(spacing: 4) {
        Text("Dash")
          .dashTextStyle(.emptyTitle)
          .foregroundStyle(DashTheme.strong)
        Text("A native Cloudflare client for iPhone")
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.subtle)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
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
      name: "MingCute", purpose: "Social icons", author: "MingCute Design",
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
  @State private var avatarPickerItem: PhotosPickerItem?
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

        // Registrations used to sit here; it browses as its own catalog
        // feature in Resources now, so this group carries the audit log alone.
        DashListGroup(title: "Account") {
          dashListCard {
            DashListGroupLink(value: .auditLogs) {
              DashListRow(
                title: DashL10n.string("Audit log"),
                subtitle: DashL10n.string("Recent account activity"),
                icon: SolarAsset.Content.shieldCheck
              )
            }
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
      PhotosPicker(
        selection: $avatarPickerItem,
        matching: .images,
        preferredItemEncoding: .compatible
      ) {
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
              .scaleEffect(usesReducedMotion || avatarPhase == .idle ? 1 : 0.25)
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
      .buttonStyle(DashPressButtonStyle())
      .disabled(avatarPhase.isActive || userID == nil)
      .accessibilityLabel(DashL10n.string("Change profile photo"))
      .accessibilityValue(avatarPhase.accessibilityValue)
    }
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
      model.toasts.success(DashL10n.string("Saved successfully."))
      avatarActionPhase = .succeeded
    } catch is CancellationError {
      avatarActionPhase = .idle
      return
    } catch {
      avatarActionPhase = .idle
      model.toasts.error(
        DashL10n.string("Dash couldn’t use this photo. Try another image."))
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
      model.toasts.success(DashL10n.string("Saved successfully."))
      avatarActionPhase = .succeeded
    } catch is CancellationError {
      avatarActionPhase = .idle
      return
    } catch {
      avatarActionPhase = .idle
      model.toasts.error(
        DashL10n.string("Dash couldn’t update your profile photo. Try again."))
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
    guard ExpiryReminders.date(fromISO8601: iso) != nil else { return iso }
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
