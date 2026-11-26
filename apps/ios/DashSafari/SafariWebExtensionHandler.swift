import Foundation

/// The principal class Safari requires of every web extension — and, here,
/// nothing more.
///
/// The whole extension is `Resources/content.js`: it reads the address of a
/// `dash.cloudflare.com` page and navigates to `dash://open?url=…`. It never
/// calls `browser.runtime.sendNativeMessage`, so this handler has no message to
/// answer; it exists because an extension bundle without a principal class does
/// not load. Keep it that way — the extension holds no token, shares no App
/// Group, and links no package precisely because nothing native runs in it.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
  func beginRequest(with context: NSExtensionContext) {
    context.completeRequest(returningItems: nil, completionHandler: nil)
  }
}
