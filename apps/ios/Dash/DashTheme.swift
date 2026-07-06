import SwiftUI

enum DashTheme {
  static let brand = Color(red: 0.0, green: 0.45, blue: 0.84)
  static let accent = Color(red: 0.96, green: 0.47, blue: 0.08)
  static let canvas = Color(uiColor: .systemGroupedBackground)
  static let base = Color(uiColor: .secondarySystemGroupedBackground)
  static let elevated = Color(uiColor: .tertiarySystemGroupedBackground)
  static let line = Color(uiColor: .separator)
  static let subtle = Color(uiColor: .secondaryLabel)
}

extension Font {
  static func chill(_ size: CGFloat, heavy: Bool = false) -> Font {
    .custom(
      heavy ? "ChillRoundGothic-Heavy" : "ChillRoundGothic-Bold", size: size, relativeTo: .body)
  }
}

struct DashCard<Content: View>: View {
  @ViewBuilder let content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .padding(.horizontal, 16)
      .background(DashTheme.base, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

struct StatusBadge: View {
  let text: String
  var body: some View {
    Text(text.capitalized).font(.caption2.weight(.semibold)).foregroundStyle(DashTheme.brand)
      .padding(.horizontal, 8).padding(.vertical, 4).background(
        DashTheme.brand.opacity(0.12), in: Capsule())
  }
}

struct LoadingStateView: View {
  var body: some View {
    ProgressView().tint(DashTheme.brand).frame(maxWidth: .infinity, minHeight: 180)
  }
}

struct ErrorStateView: View {
  let message: String
  let retry: () -> Void
  var body: some View {
    ContentUnavailableView {
      Label("Couldn’t load", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("Try again", action: retry).buttonStyle(.borderedProminent)
    }
  }
}
