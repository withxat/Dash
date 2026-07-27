import SwiftUI

/// Shared confirmation for clearing current issues and unread notifications
/// from the inbox (local ignore only).
struct WatchtowerIgnoreAllTray: View {
  let count: Int
  let onConfirm: () -> Void
  @Environment(\.dashTrayDismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(confirmationMessage)
        .dashTextStyle(.supporting)
        .foregroundStyle(DashTheme.subtle)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      DashActionButton(
        title: DashL10n.string("Ignore all"),
        role: .destructive,
        holdToConfirm: true,
        action: {
          onConfirm()
          dismiss()
        }
      )
    }
  }

  private var confirmationMessage: String {
    count == 1
      ? DashL10n.string(
        "Ignore 1 current or unread alert? It moves to Ignored on this iPhone. Cloudflare isn’t changed."
      )
      : DashL10n.string(
        "Ignore \(count) current or unread alerts? They move to Ignored on this iPhone. Cloudflare isn’t changed."
      )
  }
}
