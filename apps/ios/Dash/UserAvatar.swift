import CryptoKit
import SwiftUI
import UIKit

enum Gravatar {
  static func normalize(_ email: String) -> String {
    email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  static func url(for email: String, size: Int) -> URL? {
    let normalized = normalize(email)
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

/// Session-scoped in-memory avatar cache shared by every `UserAvatar`.
/// `AsyncImage` loads per instance and never retries a failure, so on a poor
/// connection one tab's toolbar could win while the others stayed on the
/// initials fallback forever. The store single-flights one canonical-size
/// request per email and republishes the result to every observer at once.
@MainActor
@Observable
final class AvatarStore {
  /// Pixels requested from Gravatar — covers the largest rendering
  /// (80 pt at 3×) so every smaller avatar shares one bitmap.
  private static let canonicalPixelSize = 240

  private enum Entry {
    /// Gravatar answered 404: the user has no avatar. Definitive — the
    /// initials fallback is the right rendering, not a failure to heal.
    case missing
    case loaded(UIImage)
  }

  private var entries: [String: Entry] = [:]
  private var inFlight = Set<String>()
  /// Every email ever asked for, so foregrounding can retry transient misses
  /// on behalf of long-lived views whose `.task` already ran.
  private var requested = Set<String>()
  private let session: URLSession

  init(session: URLSession? = nil) {
    self.session =
      session
      ?? {
        // Waiting for connectivity lets the one request complete late on a
        // flaky connection instead of failing fast and stranding the avatar.
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
      }()
    NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.retryMissing() }
    }
  }

  func image(for email: String) -> UIImage? {
    guard case .loaded(let image)? = entries[Gravatar.normalize(email)] else { return nil }
    return image
  }

  /// Kicks off a fetch unless one already resolved or is running. Safe to
  /// call from every avatar's `.task`; the first caller wins, the rest
  /// observe. A transient failure leaves the entry absent so a later call
  /// (or returning to the foreground) retries.
  func ensureLoaded(_ email: String) {
    let key = Gravatar.normalize(email)
    guard !key.isEmpty, entries[key] == nil, !inFlight.contains(key),
      let url = Gravatar.url(for: key, size: Self.canonicalPixelSize)
    else { return }
    requested.insert(key)
    inFlight.insert(key)
    Task {
      defer { inFlight.remove(key) }
      guard let (data, response) = try? await session.data(from: url),
        let status = (response as? HTTPURLResponse)?.statusCode
      else { return }
      if status == 404 {
        entries[key] = .missing
      } else if status == 200, let image = UIImage(data: data) {
        entries[key] = .loaded(image)
      }
    }
  }

  func clear() {
    entries = [:]
    requested = []
  }

  private func retryMissing() {
    for email in requested where entries[email] == nil {
      ensureLoaded(email)
    }
  }
}

enum AvatarHeaderMetrics {
  /// Matches UIKit minimal back-button slot width on iOS.
  static let barSize: CGFloat = 44
  static let titleSize: CGFloat = 34
}

struct UserAvatar: View {
  @Environment(AppModel.self) private var model
  let email: String
  var size: CGFloat = 32

  var body: some View {
    avatarContent
      .frame(width: size, height: size)
      .clipShape(Circle())
      .overlay { Circle().stroke(DashTheme.line, lineWidth: 0.5) }
      .contentShape(Circle())
      .task(id: email) { model.avatars.ensureLoaded(email) }
  }

  @ViewBuilder
  private var avatarContent: some View {
    if let image = model.avatars.image(for: email) {
      Image(uiImage: image).resizable().scaledToFill()
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
