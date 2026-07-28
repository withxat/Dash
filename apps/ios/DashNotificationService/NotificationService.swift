import UserNotifications

/// Rewrites a Cloudflare alert on device, before iOS shows it.
///
/// Two things can only happen here:
///
/// * **Language.** The relay forwards Cloudflare's `text`, which is English and
///   always will be — the relay has no catalog and no idea what language this
///   iPhone is set to. This is the only place that knows both.
/// The 30-second budget applies: on expiry iOS delivers whatever was last
/// handed to `contentHandler`, so `serviceExtensionTimeWillExpire` must always
/// have a usable copy ready.
final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttempt: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    bestAttempt = content

    let userInfo = content.userInfo
    guard
      NotificationAccountAuthorizationStore.contains(
        userInfo[AlertLocalization.PayloadKey.accountID] as? String)
    else {
      // A best-effort webhook deletion can fail while the phone is offline.
      // Once the app has signed out, never expose that old account's resource
      // name, route, thread, or actions on the Lock Screen.
      content.title = DashAlertStrings.string("Dash")
      content.subtitle = ""
      content.body = DashAlertStrings.string("Open Dash to sync your Cloudflare alerts.")
      content.categoryIdentifier = ""
      content.threadIdentifier = "dash"
      content.targetContentIdentifier = nil
      content.interruptionLevel = .passive
      content.sound = nil
      content.userInfo = [:]
      contentHandler(content)
      return
    }

    // The relay's visible `aps.alert` is deliberately generic. Restore the
    // original Cloudflare copy only after the account boundary above succeeds;
    // if iOS ever skips this extension, the Lock Screen remains fail-closed.
    if let originalTitle =
      userInfo[AlertLocalization.PayloadKey.originalTitle] as? String
    {
      content.title = originalTitle
    }
    if let originalBody =
      userInfo[AlertLocalization.PayloadKey.originalBody] as? String
    {
      content.body = originalBody
    }

    if let rewrite = AlertLocalization.rewrite(
      alertType: userInfo[AlertLocalization.PayloadKey.alertType] as? String,
      subject: userInfo[AlertLocalization.PayloadKey.subject] as? String,
      originalBody: content.body)
    {
      content.title = rewrite.title
      content.body = rewrite.body
    }

    contentHandler(content)
  }

  override func serviceExtensionTimeWillExpire() {
    guard let contentHandler, let bestAttempt else { return }
    contentHandler(bestAttempt)
  }
}
