import CloudflareAPI
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

struct ProfileTrayContent: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dashTrayDismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Dismisses the tray and pushes the Profile page onto the active tab.
  let openProfile: () -> Void
  let openSettings: () -> Void
  /// DEBUG-only: dismisses the tray and pushes the Debug playground.
  var openDebug: (() -> Void)? = nil
  @State private var phase: ProfileTrayPhase = .menu
  @State private var isSigningOut = false

  init(
    openProfile: @escaping () -> Void,
    openSettings: @escaping () -> Void,
    openDebug: (() -> Void)? = nil
  ) {
    self.openProfile = openProfile
    self.openSettings = openSettings
    self.openDebug = openDebug
  }

  var body: some View {
    ZStack {
      switch phase {
      case .menu:
        menu
          .transition(reduceMotion ? .opacity : .dashMorph)
      case .accounts:
        accountList
          .transition(reduceMotion ? .opacity : .dashMorph)
      case .switchAccount(let account):
        accountSwitchConfirmation(account)
          .transition(reduceMotion ? .opacity : .dashMorph)
      case .signOut:
        signOutConfirmation
          .transition(reduceMotion ? .opacity : .dashMorph)
      }
    }
    .dashTrayTitle(phase.title)
  }

  private var menu: some View {
    VStack(spacing: 20) {
      HStack(spacing: 16) {
        UserAvatar(email: model.user?.email ?? "", size: 56)
        VStack(alignment: .leading, spacing: 4) {
          Text(model.profileTitle)
            .dashTextStyle(.bodySemibold)
          if let email = model.user?.email, email != model.profileTitle {
            Text(email)
              .dashTextStyle(.supporting)
              .foregroundStyle(DashTheme.subtle)
          }
          if let account = model.activeAccount, account.name != model.profileTitle {
            Text(account.name)
              .dashTextStyle(.footnote)
              .foregroundStyle(DashTheme.placeholder)
          }
        }
        Spacer(minLength: 0)
      }

      VStack(spacing: 10) {
        menuRow(
          title: DashL10n.string("Profile"), icon: SolarAsset.user, action: openProfile)
        menuRow(
          title: DashL10n.string("Settings"), icon: SolarAsset.settings, action: openSettings)
        #if DEBUG
          if let openDebug {
            menuRow(title: "Debug", icon: SolarAsset.code, action: openDebug)
          }
        #endif
        if model.accounts.count > 1 {
          menuRow(title: DashL10n.string("Switch account"), icon: SolarAsset.users) {
            withAnimation(DashTheme.Motion.morph) { phase = .accounts }
          }
        }

        menuRow(
          title: DashL10n.string("Sign out"), icon: SolarAsset.danger, tint: DashTheme.danger
        ) {
          withAnimation(DashTheme.Motion.morph) { phase = .signOut }
        }
      }
    }
  }

  private var accountList: some View {
    VStack(spacing: 16) {
      VStack(spacing: 10) {
        ForEach(model.accounts) { account in
          Button {
            if account.id == model.activeAccountID {
              dismiss()
              return
            }
            withAnimation(DashTheme.Motion.morph) { phase = .switchAccount(account) }
          } label: {
            HStack(spacing: 12) {
              Text(account.name)
                .dashTextStyle(.bodyMedium)
                .foregroundStyle(DashTheme.text)
                .lineLimit(1)
              Spacer(minLength: 0)
              SolarIcon(
                asset: account.id == model.activeAccountID
                  ? SolarAsset.checkCircleFill : SolarAsset.circle,
                size: 22,
                color: account.id == model.activeAccountID
                  ? DashTheme.brand : DashTheme.placeholder)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DashTheme.Sheet.shortcutItem, in: DashTheme.buttonShape)
          }
          .buttonStyle(DashSurfaceButtonStyle())
          .accessibilityAddTraits(account.id == model.activeAccountID ? .isSelected : [])
        }
      }

      Button {
        withAnimation(DashTheme.Motion.morph) { phase = .menu }
      } label: {
        Text(DashL10n.string("Back"))
          .dashTextStyle(.buttonMedium)
          .foregroundStyle(DashTheme.subtle)
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .buttonStyle(DashPressButtonStyle())
    }
  }

  private func accountSwitchConfirmation(_ account: CloudflareAccount) -> some View {
    VStack(spacing: 16) {
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

      VStack(spacing: 4) {
        Button {
          withAnimation(DashTheme.Motion.morph) { phase = .accounts }
        } label: {
          Text(DashL10n.string("Cancel"))
            .dashTextStyle(.buttonMedium)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DashPressButtonStyle())

        DashActionButton(title: DashL10n.string("Switch account")) {
          model.selectAccount(account)
          dismiss()
        }
      }
    }
  }

  private var signOutConfirmation: some View {
    VStack(spacing: 16) {
      Text(DashL10n.string("You'll need to reconnect your Cloudflare account to use Dash again."))
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)

      VStack(spacing: 4) {
        Button {
          withAnimation(DashTheme.Motion.morph) { phase = .menu }
        } label: {
          Text(DashL10n.string("Cancel"))
            .dashTextStyle(.buttonMedium)
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DashPressButtonStyle())
        .disabled(isSigningOut)

        DashActionButton(
          title: DashL10n.string("Sign out"),
          role: .destructive,
          isLoading: isSigningOut
        ) {
          Task {
            isSigningOut = true
            await model.signOut()
            isSigningOut = false
            dismiss()
          }
        }
      }
    }
  }

  private func menuRow(
    title: String, icon: String, tint: Color = DashTheme.iconMuted,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        SolarIcon(asset: icon, size: 22, color: tint)
        Text(title)
          .dashTextStyle(.bodyMedium)
          .foregroundStyle(tint == DashTheme.danger ? DashTheme.danger : DashTheme.text)
          .lineLimit(1)
        Spacer(minLength: 0)
        SolarIcon(
          asset: SolarAsset.chevronRight, size: DashTheme.Chevron.row, color: DashTheme.placeholder)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DashTheme.Sheet.shortcutItem, in: DashTheme.buttonShape)
    }
    .buttonStyle(DashSurfaceButtonStyle())
  }
}

enum ProfileTrayPhase: Equatable, Sendable {
  case menu
  case accounts
  case switchAccount(CloudflareAccount)
  case signOut

  var title: String {
    switch self {
    case .menu: DashL10n.string("Profile")
    case .accounts, .switchAccount: DashL10n.string("Switch account")
    case .signOut: DashL10n.string("Sign out")
    }
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
  @AppStorage(DashInteractionPreferences.holdToConfirmKey) private var holdToConfirmEnabled =
    true
  @AppStorage(DashWorkspaceWashPreset.storageKey) private var workspaceWashRaw =
    DashWorkspaceWashPreset.defaultPreset.rawValue
  @AppStorage(ICloudPreferencesSync.enabledKey) private var iCloudSyncEnabled = true
  @State private var watchtowerNotificationsDenied = false
  @State private var showsLanguagePicker = false
  @State private var showsWorkspaceWashPicker = false
  @State private var showsICloudSyncDetails = false

  private var selectedLanguage: DashAppLanguage {
    DashAppLanguage.resolved(stored: languageRaw)
  }

  private var selectedWorkspaceWash: DashWorkspaceWashPreset {
    DashWorkspaceWashPreset.resolved(stored: workspaceWashRaw)
  }

  private var hasShortcutsAndShareWriteAccess: Bool {
    guard let grantedScopes = model.grantedScopes else { return false }
    return DashAuthorizationScopes.shortcutsAndShareWrites.isSubset(of: grantedScopes)
  }

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        DashListGroup(title: "General") {
          dashListCard {
            Button {
              showsLanguagePicker = true
            } label: {
              DashListRow(
                title: DashL10n.string("Language"),
                subtitle: DashL10n.string("App display language"),
                icon: SolarAsset.Content.globus,
                trailing: selectedLanguage.displayName
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            .accessibilityHint(DashL10n.string("Choose English, Simplified Chinese, or System"))
            .dashListCardInset()
          }

          DashToggleRow(
            title: DashL10n.string("Haptic feedback"),
            subtitle: DashL10n.string("Vibrate on button presses, selections, and confirmations."),
            isOn: $hapticsEnabled
          )
          .onChange(of: hapticsEnabled) { _, enabled in
            if enabled { DashDelight.lightImpact() }
          }

          DashToggleRow(
            title: DashL10n.string("Hold to confirm"),
            subtitle: DashL10n.string(
              "Require a long press to confirm deletes and other irreversible actions."
            ),
            isOn: $holdToConfirmEnabled
          )
        }

        DashListGroup(title: "Appearance") {
          dashListCard {
            Button {
              showsWorkspaceWashPicker = true
            } label: {
              DashListRow(
                title: DashL10n.string("Top glow"),
                subtitle: DashL10n.string("For Home, Resources, and Watchtower."),
                icon: SolarAsset.Content.slider,
                iconColor: DashTheme.workspaceWash(for: selectedWorkspaceWash),
                trailing: selectedWorkspaceWash.displayName
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            .accessibilityIdentifier("workspace-wash-color")
            .dashListCardInset()
          }
        }

        DashListGroup(title: "iCloud") {
          DashToggleRow(
            title: DashL10n.string("Sync settings"),
            subtitle: DashL10n.string(
              iCloudSyncEnabled
                ? "Keep selected Dash preferences in sync across iPhones using your iCloud account."
                : "Settings on this iPhone stay local."
            ),
            isOn: $iCloudSyncEnabled
          )
          .accessibilityIdentifier("icloud-settings-sync")

          dashListCard {
            Button {
              showsICloudSyncDetails = true
            } label: {
              DashListRow(
                title: DashL10n.string("What syncs"),
                subtitle: DashL10n.string(
                  "Quick actions, Shortcuts, Watchtower charts, and Top glow."
                ),
                icon: SolarAsset.Content.cloud
              )
            }
            .buttonStyle(DashSurfaceButtonStyle())
            .accessibilityIdentifier("icloud-settings-details")
            .dashListCardInset()
          }
        }

        DashListGroup(title: "Watchtower") {
          DashToggleRow(
            title: DashL10n.string("Notifications"),
            subtitle: DashL10n.string(
              "Cloudflare delivers an alert here when one of your notification policies fires."
            ),
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
              ))
          }
        }

        PushAlertsSettingsCard()

        DashListGroup(title: "Shortcuts") {
          dashListCard {
            DashListRow(
              title: DashL10n.string("Siri & Shortcuts"),
              subtitle: DashL10n.string(
                "Purge Cache, Under Attack, Development Mode, Upload to R2, and Open Watchtower."
              ),
              icon: SolarAsset.Content.bolt
            )
            .dashListCardInset()
            .accessibilityHint(
              DashL10n.string("Available in the Shortcuts app when Dash is signed in"))
          }

          dashListCard {
            if hasShortcutsAndShareWriteAccess {
              DashListRow(
                title: DashL10n.string("Shortcuts & Share write access"),
                subtitle: DashL10n.string(
                  "Purge Cache, domain security modes, and R2 uploads are authorized."
                ),
                icon: SolarAsset.Content.shieldCheck,
                trailing: DashL10n.string("Granted")
              )
              .dashListCardInset()
            } else {
              Button {
                model.requestAccess(to: DashAuthorizationScopes.shortcutsAndShareWrites)
              } label: {
                DashListRow(
                  title: DashL10n.string("Shortcuts & Share write access"),
                  subtitle: DashL10n.string(
                    "Dash requests all permissions used by its current features in one authorization."
                  ),
                  icon: SolarAsset.Content.shieldCheck,
                  trailing: model.isAuthenticating
                    ? DashL10n.string("Opening…") : DashL10n.string("Grant")
                )
              }
              .buttonStyle(DashSurfaceButtonStyle())
              .disabled(model.isAuthenticating)
              .accessibilityHint(
                DashL10n.string("Opens Cloudflare to review the requested permissions")
              )
              .dashListCardInset()
            }
          }
        }

        DashListGroup(title: "Help & legal") {
          dashListCard {
            externalRow(
              title: DashL10n.string("Send feedback"),
              subtitle: DashL10n.string("Email i@xat.sh"),
              icon: SolarAsset.inbox,
              destination: DashHelpLink.feedback,
              accessibilityHint: DashL10n.string("Opens your email app")
            )

            DashListGroupDivider()

            externalRow(
              title: DashL10n.string("Privacy Policy"),
              subtitle: DashL10n.string("How Dash handles account and device data"),
              icon: SolarAsset.Content.shieldCheck,
              destination: DashHelpLink.privacy,
              accessibilityHint: DashL10n.string("Opens the policy on dash.xat.sh")
            )

            DashListGroupDivider()

            externalRow(
              title: DashL10n.string("Terms of Use"),
              subtitle: DashL10n.string("Independent client and operation responsibilities"),
              icon: SolarAsset.Content.file,
              destination: DashHelpLink.terms,
              accessibilityHint: DashL10n.string("Opens the terms on dash.xat.sh")
            )
          }
        }

        DashListGroup(title: "About") {
          dashListCard {
            DashListGroupLink(value: .about) {
              DashListRow(
                title: DashL10n.string("About Dash"),
                subtitle: DashL10n.string("Version and app details"),
                icon: SolarAsset.Content.cloud
              )
            }
            .dashListCardInset()
          }

          dashListCard {
            DashListGroupLink(value: .openSource) {
              DashListRow(
                title: DashL10n.string("Open source"),
                subtitle: DashL10n.string("Libraries and icons that power Dash"),
                icon: SolarAsset.Content.code
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
      isPresented: $showsICloudSyncDetails,
      title: DashL10n.string("What syncs")
    ) {
      ICloudSyncDetailsTray(isEnabled: iCloudSyncEnabled)
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
    subtitle: String,
    icon: String,
    destination: URL,
    accessibilityHint: String
  ) -> some View {
    Button {
      openURL(destination)
    } label: {
      DashListRow(
        title: title,
        subtitle: subtitle,
        icon: icon
      )
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityHint(accessibilityHint)
    .dashListCardInset()
  }
}

private struct ICloudSyncDetailsTray: View {
  let isEnabled: Bool

  private var items: [String] {
    [
      DashL10n.string("Quick actions"),
      DashL10n.string("Shortcuts"),
      DashL10n.string("Watchtower charts"),
      DashL10n.string("Top glow"),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(items, id: \.self) { item in
        HStack(spacing: 12) {
          SolarIcon(
            asset: isEnabled ? SolarAsset.checkCircleFill : SolarAsset.circle,
            size: 22,
            color: isEnabled ? DashTheme.brand : DashTheme.placeholder
          )
          .accessibilityHidden(true)
          Text(item)
            .dashTextStyle(.bodyMedium)
            .foregroundStyle(DashTheme.text)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: DashTheme.Layout.minimumHitTarget)
        .background(DashTheme.Sheet.shortcutItem, in: DashTheme.buttonShape)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isEnabled ? .isSelected : [])
      }

      Text(
        DashL10n.string(
          isEnabled
            ? "Only these preferences are synced. Accounts, credentials, alerts, and cached Cloudflare data stay on this iPhone."
            : "Sync is off. These preferences stay on this iPhone, and the existing iCloud copy is not deleted."
        )
      )
      .dashTextStyle(.supporting)
      .foregroundStyle(DashTheme.subtle)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 4)
    }
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

      Text(
        DashL10n.string(
          "System follows the iPhone language, including Settings → Dash → Language.")
      )
      .dashTextStyle(.footnote)
      .foregroundStyle(DashTheme.subtle)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }
}

/// About screen (Settings → About): the app icon over the app name, tagline,
/// and version.
struct AboutView: View {
  private var versionText: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "—"
    let build = info?["CFBundleVersion"] as? String ?? "—"
    return "\(version) (\(build))"
  }

  var body: some View {
    ScrollView {
      VStack(spacing: DashTheme.Spacing.section) {
        VStack(spacing: 16) {
          Image("LoginAppIcon")
            .resizable()
            .scaledToFit()
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 96 * 0.2237, style: .continuous))
            // The warm halo that used to lift the icon's spot off the canvas.
            .background {
              RadialGradient(
                colors: [DashTheme.wash.opacity(0.55), DashTheme.wash.opacity(0)],
                center: .center,
                startRadius: 8,
                endRadius: 300
              )
              .frame(width: 600, height: 600)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
            }
            .accessibilityHidden(true)

          VStack(spacing: 4) {
            Text("Dash")
              .dashTextStyle(.sheetTitle)
              .foregroundStyle(DashTheme.strong)
            Text("A native Cloudflare client for iPhone")
              .dashTextStyle(.supporting)
              .foregroundStyle(DashTheme.subtle)
              .multilineTextAlignment(.center)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)

        DashCard {
          VStack(alignment: .leading, spacing: 4) {
            Text("Version")
              .dashTextStyle(.footnoteSemibold)
              .foregroundStyle(DashTheme.subtle)
            Text(versionText)
              .dashTextStyle(.supporting)
              .foregroundStyle(DashTheme.text)
              .textSelection(.enabled)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 12)
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.vertical, DashTheme.Spacing.section)
    }
    .background(DashTheme.canvas)
    .detailHeader(icon: .solar(SolarAsset.Content.cloud), title: "About")
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

  /// Swift packages that ship in the app binary (direct and transitive).
  static let libraries: [OpenSourceCredit] = [
    OpenSourceCredit(
      name: "CodeEditor", purpose: "Code and JSON editing", author: "ZeeZide",
      license: "MIT", url: URL(string: "https://github.com/ZeeZide/CodeEditor")!),
    OpenSourceCredit(
      name: "Highlightr", purpose: "Syntax highlighting", author: "Juan Pablo Illanes",
      license: "MIT", url: URL(string: "https://github.com/raspu/Highlightr")!),
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

/// One tappable credit row: name + "purpose · author", a license badge, and a
/// chevron. Tapping opens the repository in the browser.
private struct OpenSourceCreditRow: View {
  let credit: OpenSourceCredit
  @Environment(\.openURL) private var openURL

  var body: some View {
    Button {
      openURL(credit.url)
    } label: {
      DashListRow(
        title: credit.name,
        subtitle: "\(DashL10n.ui(credit.purpose)) · \(credit.author)"
      ) {
        OpenSourceLicenseBadge(license: credit.license)
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

/// The standalone Profile page, pushed from the avatar tray's Profile row:
/// identity, user id and registration date, and the active account's details.
/// Switching accounts and signing out stay on the tray menu.
struct ProfileView: View {
  @Environment(AppModel.self) private var model
  @State private var avatarPickerItem: PhotosPickerItem?
  @State private var isUpdatingAvatar = false
  @State private var showsRename = false
  @State private var renameText = ""
  @State private var renaming = false
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
            .disabled(isUpdatingAvatar)
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
        isSaving: renaming,
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

  @ViewBuilder
  private var profileAvatar: some View {
    let email = model.user?.email ?? ""
    let userID = model.user?.id
    let hasCustomImage = model.avatars.hasCustomImage(for: userID)
    let isUpdating = isUpdatingAvatar

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
              if isUpdating {
                DashLoadingRing(color: DashTheme.inverse, size: 13, lineWidth: 2)
              } else {
                SolarIcon(
                  asset: hasCustomImage ? SolarAsset.pen : SolarAsset.gallery,
                  size: 14,
                  color: DashTheme.inverse)
              }
            }
            .frame(width: 30, height: 30)
            .offset(x: 2, y: 2)
            .accessibilityHidden(true)
          }
      }
      .buttonStyle(DashPressButtonStyle())
      .disabled(isUpdating || userID == nil)
      .accessibilityLabel(DashL10n.string("Change profile photo"))
      .accessibilityValue(isUpdating ? DashL10n.string("Updating") : "")
    }
  }

  @MainActor
  private func importAvatar(from item: PhotosPickerItem) async {
    guard let userID = model.user?.id, !model.isDemoSession else {
      avatarPickerItem = nil
      return
    }
    isUpdatingAvatar = true
    defer {
      avatarPickerItem = nil
      isUpdatingAvatar = false
    }
    do {
      guard let imported = try await item.loadTransferable(type: AvatarPhotoImport.self) else {
        throw CustomAvatarError.invalidImage
      }
      try Task.checkCancellation()
      try await model.avatars.setCustomImage(imported.image, for: userID)
      try Task.checkCancellation()
      model.toasts.success(DashL10n.string("Saved successfully."))
    } catch is CancellationError {
      return
    } catch {
      model.toasts.error(
        DashL10n.string("Dash couldn’t use this photo. Try another image."))
    }
  }

  @MainActor
  private func restoreDefaultAvatar() async {
    guard let userID = model.user?.id, !model.isDemoSession else { return }
    isUpdatingAvatar = true
    defer { isUpdatingAvatar = false }
    do {
      try await model.avatars.removeCustomImage(
        for: userID, email: model.user?.email ?? "")
      try Task.checkCancellation()
      model.toasts.success(DashL10n.string("Saved successfully."))
    } catch is CancellationError {
      return
    } catch {
      model.toasts.error(
        DashL10n.string("Dash couldn’t update your profile photo. Try again."))
    }
  }

  private func renameAccount() async {
    guard canRenameAccount else {
      model.requestAccess(to: ProfileAccountRenameAccess.requiredScopes)
      return
    }
    renaming = true
    renameError = nil
    do {
      try await model.renameActiveAccount(
        to: renameText.trimmingCharacters(in: .whitespaces))
      showsRename = false
    } catch {
      renameError = error.dashActionableMessage
    }
    renaming = false
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
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    guard let date = fractional.date(from: iso) ?? plain.date(from: iso) else { return iso }
    return date.formatted(date: .abbreviated, time: .omitted)
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
