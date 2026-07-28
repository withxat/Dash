import Foundation

/// Localizes Cloudflare alerts on device.
///
/// Compiled into both the app and the Notification Service Extension, so the
/// same mapping decides what a notification says whether it is rewritten before
/// display or read back inside the app.
///
/// The relay cannot do this. It forwards Cloudflare's `text`, which is always
/// English, and it has no idea what language this iPhone is set to. So the
/// payload carries the machine-readable `dashAlertType` and the extension turns
/// that into copy — the same discipline `StatusBadge` follows, where appearance
/// comes from a token and never from parsing the words.
enum AlertLocalization {
  /// APNs payload keys the relay sets alongside `aps`.
  enum PayloadKey {
    static let alertType = "dashAlertType"
    static let accountID = "dashAccountID"
    static let originalBody = "dashOriginalBody"
    static let originalTitle = "dashOriginalTitle"
    static let route = "dashRoute"
    static let subject = "dashSubject"
  }

  /// Alert types Dash can describe in the user's own language.
  ///
  /// Anything not listed passes through untouched — an English notification is
  /// a far better outcome than a confidently mistranslated one, and Cloudflare
  /// adds alert types faster than this list can track them.
  enum Known: String, CaseIterable, Sendable {
    case dashTest = "dash_test"
    case dosAttackL7 = "dos_attack_l7"
    case httpAlertEdgeError = "http_alert_edge_error"
    case httpAlertOriginError = "http_alert_origin_error"
    case loadBalancingHealthAlert = "load_balancing_health_alert"
    case pagesEventAlert = "pages_event_alert"
    case realOriginMonitoring = "real_origin_monitoring"
    case secondaryDNSAllPrimariesFailing = "secondary_dns_all_primaries_failing"
    case tunnelHealthEvent = "tunnel_health_event"
    case universalSSLEventType = "universal_ssl_event_type"
    case weeklyAccountOverview = "weekly_account_overview"

    var title: String {
      switch self {
      case .dashTest: DashAlertStrings.string("Dash test alert")
      case .dosAttackL7: DashAlertStrings.string("L7 DDoS")
      case .httpAlertEdgeError: DashAlertStrings.string("Edge errors")
      case .httpAlertOriginError: DashAlertStrings.string("Origin errors")
      case .loadBalancingHealthAlert: DashAlertStrings.string("Load balancer health")
      case .pagesEventAlert: DashAlertStrings.string("Pages builds")
      case .realOriginMonitoring: DashAlertStrings.string("Origin monitoring")
      case .secondaryDNSAllPrimariesFailing: DashAlertStrings.string("Secondary DNS")
      case .tunnelHealthEvent: DashAlertStrings.string("Tunnel health")
      case .universalSSLEventType: DashAlertStrings.string("Universal SSL")
      case .weeklyAccountOverview: DashAlertStrings.string("Weekly overview")
      }
    }

    /// A localized one-liner for the alert, given the resource it names.
    ///
    /// Deliberately a *summary*, not a translation: Cloudflare's body carries
    /// counts and time windows that no client-side mapping can restate
    /// faithfully. When there is no subject to name, the original English body
    /// is kept rather than replaced with something vaguer.
    func body(subject: String) -> String {
      switch self {
      case .dashTest:
        DashAlertStrings.string("Push is working.")
      case .dosAttackL7:
        DashAlertStrings.string("Cloudflare is mitigating an attack on \(subject).")
      case .httpAlertEdgeError:
        DashAlertStrings.string("Cloudflare is returning errors for \(subject).")
      case .httpAlertOriginError, .realOriginMonitoring:
        DashAlertStrings.string("The origin for \(subject) is returning errors.")
      case .loadBalancingHealthAlert:
        DashAlertStrings.string("A load balancer pool for \(subject) changed health.")
      case .pagesEventAlert:
        DashAlertStrings.string("A build for \(subject) finished.")
      case .secondaryDNSAllPrimariesFailing:
        DashAlertStrings.string("Every primary nameserver for \(subject) is failing.")
      case .tunnelHealthEvent:
        DashAlertStrings.string("A tunnel for \(subject) changed health.")
      case .universalSSLEventType:
        DashAlertStrings.string("A certificate event for \(subject).")
      case .weeklyAccountOverview:
        DashAlertStrings.string("Your weekly Cloudflare summary is ready.")
      }
    }

    /// True when the body reads correctly with no resource named.
    var isSubjectOptional: Bool {
      self == .dashTest || self == .weeklyAccountOverview
    }
  }

  struct Rewrite: Equatable, Sendable {
    let title: String
    let body: String
  }

  /// Pure: what a notification should say, or nil to leave it exactly as
  /// Cloudflare wrote it.
  static func rewrite(
    alertType: String?,
    subject: String?,
    originalBody: String
  ) -> Rewrite? {
    guard let alertType, let known = Known(rawValue: alertType) else { return nil }
    let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines)

    if let subject, !subject.isEmpty {
      return Rewrite(title: known.title, body: known.body(subject: subject))
    }
    guard known.isSubjectOptional else {
      // Known type, unknown resource: the localized title is still an
      // improvement, and Cloudflare's body still says which thing it is about.
      return Rewrite(title: known.title, body: originalBody)
    }
    return Rewrite(title: known.title, body: known.body(subject: ""))
  }
}

/// Accounts whose notification contents may be shown on this device.
///
/// The app mirrors the current OAuth identity into the App Group. The
/// Notification Service checks it before exposing a resource name, so a
/// webhook that could not be deleted during sign-out cannot leak an old
/// account's content onto the Lock Screen.
enum NotificationAccountAuthorizationStore {
  static let appGroupID = "group.sh.xat.dash.app"
  static let key = "dash.notification_authorized_accounts"

  static func replace(
    with accountIDs: Set<String>,
    in defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)
  ) {
    let normalized =
      accountIDs
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .sorted()
    if normalized.isEmpty {
      defaults?.removeObject(forKey: key)
    } else {
      defaults?.set(normalized, forKey: key)
    }
  }

  static func contains(
    _ accountID: String?,
    in defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)
  ) -> Bool {
    guard let accountID else { return false }
    let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return false }
    return Set(defaults?.stringArray(forKey: key) ?? []).contains(normalized)
  }

  static func clear(
    in defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)
  ) {
    defaults?.removeObject(forKey: key)
  }
}

/// Catalog lookup that works in an app extension.
///
/// `DashL10n` reads the in-app language override from `UserDefaults.standard`,
/// which in an extension is the *extension's* own suite — the user's choice
/// would never arrive. This reads the App Group mirror the app maintains, and
/// falls back to the system language.
enum DashAlertStrings {
  static let appGroupID = "group.sh.xat.dash.app"
  static let languageMirrorKey = "dash.app_language"

  /// Test-only pin. `DashL10n.localeOverrideForTesting` cannot serve here — this
  /// type is also compiled into the extension, which has no access to it.
  nonisolated(unsafe) static var localeOverrideForTesting: Locale?

  static var locale: Locale {
    if let localeOverrideForTesting {
      return localeOverrideForTesting
    }
    guard
      let defaults = UserDefaults(suiteName: appGroupID),
      let raw = defaults.string(forKey: languageMirrorKey),
      raw != "system",
      !raw.isEmpty
    else {
      return .autoupdatingCurrent
    }
    return Locale(identifier: raw)
  }

  static func string(_ value: String.LocalizationValue) -> String {
    var resource = LocalizedStringResource(value)
    resource.locale = locale
    return String(localized: resource)
  }

  /// Called by the app whenever Settings → Language changes, and once at
  /// launch. Without this the extension only ever sees the system language, and
  /// a user who set Dash to 简体中文 on an English phone would get English
  /// notifications from an otherwise Chinese app.
  static func mirrorLanguage(_ raw: String) {
    UserDefaults(suiteName: appGroupID)?.set(raw, forKey: languageMirrorKey)
  }
}
