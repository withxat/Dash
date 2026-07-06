import SwiftUI

enum DashTheme {
  enum Radius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let card: CGFloat = 20
  }

  enum Spacing {
    static let screen: CGFloat = 16
    static let section: CGFloat = 20
    static let card: CGFloat = 16
  }

  static let canvas = adaptive(light: 0xFFFFFF, dark: 0x1A1A1A)
  static let elevated = adaptive(light: 0xFAFAFA, dark: 0x1F1F1F)
  static let recessed = adaptive(light: 0xF5F5F5, dark: 0x262626)
  static let base = adaptive(light: 0xFFFFFF, dark: 0x2B2B2B)
  static let tint = adaptive(light: 0xF7F7F7, dark: 0x404040)
  static let control = adaptive(light: 0xFFFFFF, dark: 0x212126)
  static let fill = adaptive(light: 0xE5E5E5, dark: 0x404040)

  static let text = adaptive(light: 0x212126, dark: 0xF5F5F5)
  static let strong = adaptive(light: 0x171717, dark: 0xFAFAFA)
  static let subtle = adaptive(light: 0x717171, dark: 0xA3A3A3)
  static let placeholder = adaptive(light: 0xA3A3A3, dark: 0x717171)
  static let inverse = adaptive(light: 0xFFFFFF, dark: 0x171717)

  static let accent = Color(hex: 0xF6821F)
  static let brand = adaptive(light: 0x1460E6, dark: 0x1256D6)
  static let line = adaptive(light: 0xE5E5E5, dark: 0x525252)
  static let hairline = adaptive(light: 0xEEEEEE, dark: 0x404040)
  static let danger = adaptive(light: 0xEF4444, dark: 0xDC2626)
  static let dangerTint = adaptive(light: 0xFEE2E2, dark: 0x450A0A)
  static let success = adaptive(light: 0x10B981, dark: 0x34D399)
  static let successTint = adaptive(light: 0xD1FAE5, dark: 0x064E3B)
  static let warning = adaptive(light: 0xEAB308, dark: 0xFACC15)
  static let warningTint = adaptive(light: 0xFEF9C3, dark: 0x713F12)
  static let info = adaptive(light: 0x3B82F6, dark: 0x60A5FA)
  static let infoTint = adaptive(light: 0xDBEAFE, dark: 0x1E3A8A)

  private static func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(
      uiColor: UIColor { traits in
        UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
      })
  }
}

extension UIColor {
  fileprivate convenience init(hex: UInt32) {
    self.init(
      red: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1)
  }
}

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(uiColor: UIColor(hex: hex))
  }
}

extension Font {
  static func chill(_ size: CGFloat, heavy: Bool = false) -> Font {
    .custom(
      heavy ? "ChillRoundGothic_Heavy" : "ChillRoundGothic_Bold", size: size,
      relativeTo: .title)
  }
}

struct DashCard<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .padding(DashTheme.Spacing.card)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DashTheme.base)
      .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
          .stroke(DashTheme.line, lineWidth: 0.5)
      }
      .dashCardShadow()
  }
}

struct DashListGroup<Content: View>: View {
  let title: String
  var actionTitle: String?
  var action: (() -> Void)?
  private let content: Content

  init(
    title: String, actionTitle: String? = nil, action: (() -> Void)? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.actionTitle = actionTitle
    self.action = action
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(title)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(DashTheme.subtle)
        Spacer(minLength: 0)
        if let actionTitle, let action {
          Button(actionTitle, action: action)
            .font(.system(size: 13, weight: .medium))
            .buttonStyle(DashOpacityButtonStyle())
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      VStack(alignment: .leading, spacing: 0) { content }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashTheme.base)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
            .stroke(DashTheme.line, lineWidth: 0.5)
        }
        .padding(.horizontal, -0.5)
        .padding(.bottom, -0.5)
    }
    .background(DashTheme.elevated)
    .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
        .stroke(DashTheme.line, lineWidth: 0.5)
    }
  }
}

struct CatalogFeatureIcon: View {
  let feature: FeatureID
  var compact = false

  private var tone: Color {
    switch feature {
    case .zones, .registrar, .tunnels, .loadBalancerPools: DashTheme.success
    case .workers, .turnstile, .accessApps, .emailAddresses, .account: DashTheme.brand
    case .analytics, .images, .stream, .secrets: DashTheme.warning
    default: DashTheme.accent
    }
  }

  var body: some View {
    Image(systemName: feature.symbol)
      .font(.system(size: compact ? 16 : 22, weight: .semibold))
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(tone)
      .frame(width: compact ? 28 : 44, height: compact ? 28 : 44)
      .background(tone.opacity(0.15))
      .clipShape(
        RoundedRectangle(
          cornerRadius: compact ? DashTheme.Radius.small : DashTheme.Radius.medium,
          style: .continuous))
  }
}

struct StatusBadge: View {
  let text: String

  private var colors: (foreground: Color, background: Color) {
    let value = text.lowercased()
    if ["active", "ok", "healthy", "success"].contains(value) {
      return (DashTheme.success, DashTheme.successTint)
    }
    if ["warning", "pending", "degraded"].contains(value) {
      return (DashTheme.warning, DashTheme.warningTint)
    }
    if ["error", "failed", "critical", "inactive"].contains(value) {
      return (DashTheme.danger, DashTheme.dangerTint)
    }
    return (DashTheme.brand, DashTheme.infoTint)
  }

  var body: some View {
    Text(text.capitalized)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(colors.foreground)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(colors.background, in: Capsule())
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

struct DashOpacityButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
  }
}

extension View {
  func dashCardShadow() -> some View {
    shadow(color: .black.opacity(0.04), radius: 1, y: 1)
      .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
  }

  func dashScreen() -> some View {
    scrollContentBackground(.hidden)
      .background(DashTheme.canvas)
      .foregroundStyle(DashTheme.text)
  }

  func dashGroupedList() -> some View {
    listStyle(.insetGrouped)
      .listSectionSpacing(.custom(DashTheme.Spacing.section))
      .scrollContentBackground(.hidden)
      .background(DashTheme.canvas)
      .foregroundStyle(DashTheme.text)
  }
}
