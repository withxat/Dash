import Foundation

struct AppConfiguration: Sendable {
  let clientID: String
  let redirectURI: String
  let callbackScheme = "dash"

  var isConfigured: Bool {
    !clientID.isEmpty && !redirectURI.isEmpty && !clientID.contains("$(")
      && !redirectURI.contains("$(")
  }

  /// Origin of the OAuth redirect worker, used as the push registration base.
  /// Nil when redirect URI is missing, unexpanded, or not https — push then
  /// degrades silently, same as an unavailable Keychain access group.
  var pushBaseURL: URL? {
    guard !redirectURI.isEmpty, !redirectURI.contains("$("),
      let url = URL(string: redirectURI),
      let scheme = url.scheme?.lowercased(), scheme == "https",
      let host = url.host, !host.isEmpty
    else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.port = url.port
    return components.url
  }

  static let current = AppConfiguration(
    clientID: Bundle.main.object(forInfoDictionaryKey: "DASHClientID") as? String ?? "",
    redirectURI: Bundle.main.object(forInfoDictionaryKey: "DASHRedirectURI") as? String ?? ""
  )
}

/// Cloudflare API / OAuth transport for the app and share extension.
/// `URLSession.shared` keeps a 60s request timeout; on a dead path that means
/// a full minute of spinner before the user sees an error. This session fails
/// after 25s of silence. Resource timeout stays at the system default so large
/// R2 uploads can still finish on a slow but progressing link.
enum DashAPISession {
  static let shared: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 25
    return URLSession(configuration: configuration)
  }()
}

/// Locale-aware lookups into `Localizable.xcstrings`.
///
/// `String(localized:)` ignores SwiftUI's `\.locale` and sticks to Bundle's
/// process-preferred language (often fixed until relaunch). Prefer these
/// helpers so Settings → Language can remount the UI without quitting.
///
/// - `string(_:)` — call sites with literals / interpolations
///   (`DashL10n.string("Settings")`). Uses `String.LocalizationValue` so
///   interpolations match `String(localized:)` and Xcode keeps extracting keys.
/// - `ui(_:)` — runtime English source strings already in the catalog (chrome
///   APIs that accept plain `String`). Unknown keys pass through unchanged.
enum DashL10n {
  /// Test-only locale pin so unit tests do not mutate `UserDefaults` (Swift
  /// Testing runs cases in parallel by default).
  nonisolated(unsafe) static var localeOverrideForTesting: Locale?

  /// Locale used for catalog lookup (in-app preference, or launch-arg / system).
  static var activeLocale: Locale {
    if let localeOverrideForTesting {
      return localeOverrideForTesting
    }
    if DashAppLanguage.isOverriddenByLaunchArguments {
      return .autoupdatingCurrent
    }
    let raw =
      UserDefaults.standard.string(forKey: DashAppLanguage.storageKey)
      ?? DashAppLanguage.system.rawValue
    return DashAppLanguage.resolved(stored: raw).locale
  }

  static func string(_ value: String.LocalizationValue) -> String {
    var resource = LocalizedStringResource(value)
    resource.locale = activeLocale
    return String(localized: resource)
  }

  /// `ui(_:)` with the catalog's answer attached.
  ///
  /// A miss returns the key unchanged, and for `ui(_:)`'s main job that is the
  /// *correct* outcome — it is deliberately called on data (zone names, object
  /// keys, RDAP tokens) that has no translation. That is also why a missing key
  /// never announced itself: English simply reached the screen. `matchedCatalog`
  /// makes the miss observable, so a caller that knows it passed a catalog key
  /// can fail on it instead.
  ///
  /// The flag compares against the source string, so a key whose translation is
  /// intentionally identical to English reads as a miss. None of Dash's are;
  /// allowlist at the call site if one ever is.
  static func lookup(_ value: String) -> (value: String, matchedCatalog: Bool) {
    guard !value.isEmpty else { return (value, false) }
    let localized = string(String.LocalizationValue(value))
    return (localized, localized != value)
  }

  static func ui(_ string: String) -> String {
    let result = lookup(string)
    #if DEBUG
      if strictLookup, !result.matchedCatalog, !string.isEmpty,
        activeLocale.language.languageCode?.identifier != "en"
      {
        assertionFailure(
          "DashL10n: no \(activeLocale.identifier) catalog entry for \(string.debugDescription)")
      }
    #endif
    return result.value
  }

  static func ui(_ string: String?) -> String? {
    string.map(ui)
  }

  #if DEBUG
    /// Opt-in strictness for a scope that only passes catalog keys — a test
    /// enumerating `StatusToken`, a preview pinned to zh-Hans. Off by default
    /// because the silent pass-through is intended behaviour for data; on, a key
    /// that was never spliced trips here instead of shipping English.
    ///
    /// Never asserts under `en`, where every lookup returns its own source
    /// string and so cannot be told apart from a miss.
    nonisolated(unsafe) static var strictLookup = false
  #endif
}

/// Interaction toggles (Settings → General). Defaults are on; absent keys read
/// as enabled so a fresh install keeps haptics and hold-to-confirm.
enum DashInteractionPreferences {
  static let hapticsKey = "dash.haptics_enabled"
  static let holdToConfirmKey = "dash.hold_to_confirm_enabled"

  static var hapticsEnabled: Bool {
    UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true
  }

  static var holdToConfirmEnabled: Bool {
    UserDefaults.standard.object(forKey: holdToConfirmKey) as? Bool ?? true
  }
}

/// In-app language preference (Settings → Language). Persisted separately from
/// iOS per-app language so Dash can offer a first-class picker; `system` clears
/// the process override and follows the phone (or Settings → Dash → Language).
enum DashAppLanguage: String, CaseIterable, Identifiable, Sendable {
  case system
  case english = "en"
  case simplifiedChinese = "zh-Hans"

  static let storageKey = "dash.app_language"

  var id: String { rawValue }

  /// BCP-47 tag written to `AppleLanguages`, or `nil` when following the system.
  var localeIdentifier: String? {
    switch self {
    case .system: nil
    case .english: "en"
    case .simplifiedChinese: "zh-Hans"
    }
  }

  /// SwiftUI / formatting locale for the root environment.
  var locale: Locale {
    if let localeIdentifier {
      return Locale(identifier: localeIdentifier)
    }
    return .autoupdatingCurrent
  }

  /// Menu labels: language names stay in their own script; System localizes.
  var displayName: String {
    switch self {
    case .system: DashL10n.string("System")
    case .english: "English"
    case .simplifiedChinese: "简体中文"
    }
  }

  static func resolved(stored raw: String) -> DashAppLanguage {
    DashAppLanguage(rawValue: raw) ?? .system
  }

  /// Launch args like `-AppleLanguages (en)` must win for UI tests.
  static var isOverriddenByLaunchArguments: Bool {
    ProcessInfo.processInfo.arguments.contains("-AppleLanguages")
  }

  /// Persists the preference into `AppleLanguages` for cold launch / extensions.
  /// Hot UI updates go through `DashL10n` + root `.environment(\.locale)` /
  /// `.id` remount — Bundle preferred-language alone does not flip at runtime.
  func applyToProcess() {
    guard !Self.isOverriddenByLaunchArguments else { return }
    if let localeIdentifier {
      UserDefaults.standard.set([localeIdentifier], forKey: "AppleLanguages")
    } else {
      UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    }
  }
}
