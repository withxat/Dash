import SwiftUI

/// Shared confirmation for clearing unread Cloudflare deliveries from the
/// inbox (local ignore only).
struct WatchtowerIgnoreAllTray: View {
  let count: Int
  let onConfirm: () -> Void
  @Environment(\.dashTrayDismiss) private var dismiss

  var body: some View {
    DashActionButton(
      title: DashL10n.string("Ignore all"),
      role: .destructive,
      action: {
        onConfirm()
        dismiss()
      }
    )
    .dashTrayDescription(confirmationMessage)
  }

  private var confirmationMessage: String {
    count == 1
      ? DashL10n.string(
        "Ignore 1 unread alert? It moves to Ignored on this iPhone. Cloudflare isn’t changed."
      )
      : DashL10n.string(
        "Ignore \(count) unread alerts? They move to Ignored on this iPhone. Cloudflare isn’t changed."
      )
  }
}
