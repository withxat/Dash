import UIKit

/// Sink that receives APNs device tokens from `PushDelegate`.
@MainActor
protocol PushTokenInbox: AnyObject {
  func receiveDeviceToken(_ token: Data)
}

/// UIApplicationDelegate that forwards device tokens into an explicit sink.
/// Prefer this over resolving App Intents' `AppDependencyManager` from the
/// delegate — that dependency surface is for intents, not system callbacks.
final class PushDelegate: NSObject, UIApplicationDelegate {
  weak var inbox: (any PushTokenInbox)?

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Task { @MainActor in
      inbox?.receiveDeviceToken(deviceToken)
    }
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    // Silent — push degrades; Watchtower local notifications still work.
  }
}

enum PushRegistration {
  /// Hex device token for the relay's `/push/register` body.
  static func hexToken(from data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  #if DEBUG
    static let apnsEnvironment = "sandbox"
  #else
    static let apnsEnvironment = "production"
  #endif
}
