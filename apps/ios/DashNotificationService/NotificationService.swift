import UserNotifications

/// Rewrites a Cloudflare alert on device, before iOS shows it.
///
/// Two things can only happen here:
///
/// * **Language.** The relay forwards Cloudflare's `text`, which is English and
///   always will be — the relay has no catalog and no idea what language this
///   iPhone is set to. This is the only place that knows both.
/// * **Badge.** The relay is stateless by design (no KV, no DO, no D1), so it
///   cannot count anything. The unread count already lives in the App Group
///   container that feeds the widget, so the badge is read from there rather
///   than invented.
///
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
    if let rewrite = AlertLocalization.rewrite(
      alertType: userInfo[AlertLocalization.PayloadKey.alertType] as? String,
      subject: userInfo[AlertLocalization.PayloadKey.subject] as? String,
      originalBody: content.body)
    {
      content.title = rewrite.title
      content.body = rewrite.body
    }

    if let badge = WatchtowerBadgeReader.unreadCount() {
      content.badge = NSNumber(value: badge)
    }

    contentHandler(content)
  }

  override func serviceExtensionTimeWillExpire() {
    guard let contentHandler, let bestAttempt else { return }
    contentHandler(bestAttempt)
  }
}
