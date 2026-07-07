import CryptoKit
import SwiftUI

enum Gravatar {
  static func url(for email: String, size: Int) -> URL? {
    let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    let digest = Insecure.MD5.hash(data: Data(normalized.utf8))
    let hash = digest.map { String(format: "%02x", $0) }.joined()
    return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=\(size)&d=404")
  }

  static func initial(for email: String) -> String {
    let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return "?" }
    return String(first).uppercased()
  }
}

enum AvatarHeaderMetrics {
  /// Matches UIKit minimal back-button slot width on iOS.
  static let barSize: CGFloat = 44
  static let titleSize: CGFloat = 34
}

struct UserAvatar: View {
  let email: String
  var size: CGFloat = 32

  var body: some View {
    avatarContent
      .frame(width: size, height: size)
      .clipShape(Circle())
      .overlay { Circle().stroke(DashTheme.line, lineWidth: 0.5) }
      .contentShape(Circle())
  }

  @ViewBuilder
  private var avatarContent: some View {
    if let url = Gravatar.url(for: email, size: Int(size * 2)) {
      AsyncImage(url: url) { phase in
        switch phase {
        case .success(let image):
          image.resizable().scaledToFill()
        default:
          initialsFallback
        }
      }
    } else {
      initialsFallback
    }
  }

  private var initialsFallback: some View {
    Circle()
      .fill(DashTheme.accent)
      .overlay {
        Text(Gravatar.initial(for: email))
          .font(.system(size: size * 0.4, weight: .bold))
          .foregroundStyle(DashTheme.inverse)
      }
  }
}

/// Tab-root profile control — same 44pt circle as the native back-button slot.
struct HeaderProfileAvatar: View {
  let email: String

  var body: some View {
    UserAvatar(email: email, size: AvatarHeaderMetrics.barSize)
  }
}
