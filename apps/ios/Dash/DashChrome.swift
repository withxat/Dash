import SwiftUI

// MARK: - Sheet presentation

enum DashSheetSizing: Equatable {
  /// Height hugs content (Profile, forms).
  case content
  /// Full-height sheet (Edit shortcuts).
  case large
}

struct TrayPresentedPreferenceKey: PreferenceKey {
  static let defaultValue = false
  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}

private struct DashTrayDismissKey: EnvironmentKey {
  nonisolated(unsafe) static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
  var dashTrayDismiss: () -> Void {
    get { self[DashTrayDismissKey.self] }
    set { self[DashTrayDismissKey.self] = newValue }
  }
}

extension View {
  func dashTray<Content: View>(
    isPresented: Binding<Bool>,
    title: String,
    sizing: DashSheetSizing = .content,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(
      DashTrayModifier(
        isPresented: isPresented, title: title, sizing: sizing, trayContent: content))
  }

  /// In-tree bottom tray for hero transitions that must share a navigation namespace.
  func dashOverlayTray<Content: View>(
    isPresented: Binding<Bool>,
    title: String,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(DashOverlayTrayModifier(isPresented: isPresented, title: title, trayContent: content))
  }

  func dashTray<Item: Identifiable & Equatable, Content: View>(
    item: Binding<Item?>,
    title: @escaping (Item) -> String,
    sizing: DashSheetSizing = .content,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    modifier(
      DashTrayItemModifier(item: item, title: title, sizing: sizing, trayContent: content)
    )
  }
}

private struct DashSheetFittedHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct DashSheetStyleModifier: ViewModifier {
  let sizing: DashSheetSizing
  @State private var contentHeight: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .onPreferenceChange(DashSheetFittedHeightKey.self) { height in
        guard sizing == .content, height > 0 else { return }
        contentHeight = height
      }
      .presentationDetents(detents)
      .presentationDragIndicator(.hidden)
      .presentationBackground(DashTheme.canvas)
  }

  private var detents: Set<PresentationDetent> {
    switch sizing {
    case .content:
      [.height(max(contentHeight, 220))]
    case .large:
      [.large]
    }
  }
}

private struct DashSheetContainer<Content: View>: View {
  let title: String
  let sizing: DashSheetSizing
  @ViewBuilder var content: () -> Content
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      sheetHeader
      sheetBody
    }
    .modifier(DashSheetContentMeasurement(enabled: sizing == .content))
    .background(DashTheme.canvas)
    .safeAreaPadding(.bottom, DashTheme.Sheet.outerBottom)
    .environment(\.dashTrayDismiss, { dismiss() })
    .dashSheetStyle(sizing: sizing)
  }

  private var sheetHeader: some View {
    VStack(spacing: 0) {
      if sizing == .large {
        DashSheetGrabBar()
      }

      HStack(alignment: .center, spacing: 12) {
        Text(title)
          .font(.dashTitle(20))
          .foregroundStyle(DashTheme.strong)
        Spacer(minLength: 12)
        Button {
          dismiss()
        } label: {
          SolarIcon(asset: SolarAsset.close, size: 22, color: DashTheme.Sheet.closeIcon)
            .frame(width: 32, height: 32)
            .background(DashTheme.recessed, in: Circle())
        }
        .padding(2)
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel("Close")
      }
      .padding(.horizontal, DashTheme.Sheet.content)
      .padding(.top, sizing == .large ? 12 : DashTheme.Sheet.headerTop)
      .padding(.bottom, DashTheme.Sheet.headerBottom)

      Rectangle()
        .fill(DashTheme.Sheet.headerBorder)
        .frame(height: 1)
        .padding(.horizontal, DashTheme.Sheet.content)
    }
  }

  @ViewBuilder
  private var sheetBody: some View {
    switch sizing {
    case .content:
      content()
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.vertical, DashTheme.Sheet.bodyVertical)
    case .large:
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, DashTheme.Sheet.bodyVertical)
    }
  }
}

private struct DashSheetGrabBar: View {
  var body: some View {
    Capsule()
      .fill(DashTheme.fill)
      .frame(width: DashTheme.Sheet.grabBarWidth, height: DashTheme.Sheet.grabBarHeight)
      .frame(maxWidth: .infinity)
      .padding(.top, DashTheme.Sheet.grabBarTop)
      .padding(.bottom, DashTheme.Sheet.grabBarBottom)
      .accessibilityHidden(true)
  }
}

private struct DashSheetContentMeasurement: ViewModifier {
  let enabled: Bool

  func body(content: Content) -> some View {
    content
      .fixedSize(horizontal: false, vertical: enabled)
      .background {
        if enabled {
          GeometryReader { proxy in
            Color.clear.preference(key: DashSheetFittedHeightKey.self, value: proxy.size.height)
          }
        }
      }
  }
}

extension View {
  fileprivate func dashSheetStyle(sizing: DashSheetSizing) -> some View {
    modifier(DashSheetStyleModifier(sizing: sizing))
  }
}

private struct DashTrayModifier<TrayContent: View>: ViewModifier {
  @Binding var isPresented: Bool
  let title: String
  var sizing: DashSheetSizing = .content
  @ViewBuilder var trayContent: () -> TrayContent

  func body(content: Content) -> some View {
    content
      .preference(key: TrayPresentedPreferenceKey.self, value: isPresented)
      .sheet(isPresented: $isPresented) {
        DashSheetContainer(title: title, sizing: sizing, content: trayContent)
      }
  }
}

private struct DashOverlayTrayModifier<TrayContent: View>: ViewModifier {
  @Binding var isPresented: Bool
  let title: String
  @ViewBuilder var trayContent: () -> TrayContent
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    ZStack(alignment: .bottom) {
      content
      if isPresented {
        Color.black.opacity(DashTheme.Sheet.scrimOpacity)
          .ignoresSafeArea()
          .onTapGesture { isPresented = false }
          .transition(.opacity)

        DashOverlayTrayContainer(
          title: title,
          onClose: { isPresented = false },
          content: trayContent
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .preference(key: TrayPresentedPreferenceKey.self, value: isPresented)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: isPresented)
  }
}

private struct DashOverlayTrayContainer<Content: View>: View {
  let title: String
  let onClose: () -> Void
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      DashSheetGrabBar()
      HStack(alignment: .center, spacing: 12) {
        Text(title)
          .font(.dashTitle(20))
          .foregroundStyle(DashTheme.strong)
        Spacer(minLength: 12)
        Button(action: onClose) {
          SolarIcon(asset: SolarAsset.close, size: 22, color: DashTheme.Sheet.closeIcon)
            .frame(width: 32, height: 32)
            .background(DashTheme.recessed, in: Circle())
        }
        .padding(2)
        .buttonStyle(DashPressButtonStyle())
        .accessibilityLabel("Close")
      }
      .padding(.horizontal, DashTheme.Sheet.content)
      .padding(.top, 12)
      .padding(.bottom, DashTheme.Sheet.headerBottom)

      Rectangle()
        .fill(DashTheme.Sheet.headerBorder)
        .frame(height: 1)
        .padding(.horizontal, DashTheme.Sheet.content)

      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, DashTheme.Sheet.bodyVertical)
    }
    .frame(maxWidth: .infinity)
    .frame(maxHeight: UIScreen.main.bounds.height * 0.88)
    .background(DashTheme.canvas)
    .clipShape(
      RoundedRectangle(cornerRadius: DashTheme.Radius.sheet, style: .continuous)
    )
    .safeAreaPadding(.bottom, DashTheme.Sheet.outerBottom)
    .environment(\.dashTrayDismiss, onClose)
  }
}

private struct DashTrayItemModifier<Item: Identifiable & Equatable, TrayContent: View>: ViewModifier
{
  @Binding var item: Item?
  let title: (Item) -> String
  var sizing: DashSheetSizing = .content
  @ViewBuilder var trayContent: (Item) -> TrayContent

  private var isPresented: Bool { item != nil }

  func body(content: Content) -> some View {
    content
      .preference(key: TrayPresentedPreferenceKey.self, value: isPresented)
      .sheet(item: $item) { value in
        DashSheetContainer(
          title: title(value), sizing: sizing, content: { trayContent(value) }
        )
      }
  }
}

// MARK: - Root chrome

private struct ShowsProfileKey: EnvironmentKey {
  static let defaultValue: Binding<Bool> = .constant(false)
}

private struct ShowsEditShortcutsKey: EnvironmentKey {
  static let defaultValue: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
  var showsProfile: Binding<Bool> {
    get { self[ShowsProfileKey.self] }
    set { self[ShowsProfileKey.self] = newValue }
  }

  var showsEditShortcuts: Binding<Bool> {
    get { self[ShowsEditShortcutsKey.self] }
    set { self[ShowsEditShortcutsKey.self] = newValue }
  }
}

struct DashRootHeader: View {
  let title: String

  @Environment(AppModel.self) private var model
  @Environment(\.showsProfile) private var showsProfile

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      Text(title)
        .font(.dashTitle(34))
        .foregroundStyle(DashTheme.strong)
        .tracking(-0.5)
      Spacer(minLength: 0)
      Button {
        showsProfile.wrappedValue = true
      } label: {
        HeaderProfileAvatar(email: model.user?.email ?? "")
      }
      .buttonStyle(DashPressButtonStyle())
      .accessibilityLabel("Open profile")
    }
    .frame(minHeight: 52)
  }
}

// MARK: - Tray content helpers

struct DashFormSheet<Content: View>: View {
  var saveTitle = "Save"
  var isSaving = false
  var canSave = true
  let onSave: () -> Void
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        content
        DashPillButton(title: saveTitle, isLoading: isSaving, action: onSave)
          .disabled(!canSave || isSaving)
          .opacity(canSave ? 1 : 0.45)
      }
      .padding(.horizontal, DashTheme.Sheet.content)
      .padding(.bottom, DashTheme.Sheet.bodyBottom)
    }
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaPadding(.bottom)
  }
}

struct DashFormField: View {
  let label: String
  @Binding var text: String
  var axis: Axis = .horizontal
  var keyboard: UIKeyboardType = .default

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DashTheme.subtle)
      TextField(label, text: $text, axis: axis)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(DashTheme.text)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(keyboard)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(DashTheme.recessed)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
    }
  }
}

struct DashActionRow: View {
  let title: String
  var icon: String?
  var trailing: String?
  var role: ButtonRole?
  let action: () -> Void

  var body: some View {
    Button(role: role, action: action) {
      HStack(spacing: 12) {
        if let icon {
          SolarIcon(
            asset: icon,
            size: 22,
            color: role == .destructive ? DashTheme.danger : DashTheme.strong
          )
        }
        Text(title)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(role == .destructive ? DashTheme.danger : DashTheme.strong)
        Spacer(minLength: 0)
        if let trailing {
          Text(trailing)
            .font(.system(size: 15))
            .foregroundStyle(DashTheme.subtle)
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(role == .destructive ? DashTheme.dangerTint : DashTheme.recessed)
      .clipShape(DashTheme.buttonShape)
    }
    .buttonStyle(DashPressButtonStyle())
  }
}

struct DashPillButton: View {
  let title: String
  var isLoading = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if isLoading { ProgressView().tint(DashTheme.inverse) }
        Text(title)
          .font(.system(size: 16, weight: .semibold))
      }
      .foregroundStyle(DashTheme.inverse)
      .frame(maxWidth: .infinity, minHeight: 52)
      .background(DashTheme.strong, in: DashTheme.buttonShape)
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(isLoading)
  }
}

struct DashSecondaryPillButton: View {
  let title: String
  var action: (() -> Void)?

  var body: some View {
    Group {
      if let action {
        Button(action: action) { label }
          .buttonStyle(DashPressButtonStyle())
      } else {
        label
      }
    }
  }

  private var label: some View {
    Text(title)
      .font(.system(size: 16, weight: .bold))
      .foregroundStyle(DashTheme.strong)
      .frame(maxWidth: .infinity, minHeight: 52)
      .background(DashTheme.recessed, in: DashTheme.buttonShape)
      .overlay {
        DashTheme.buttonShape.stroke(DashTheme.line, lineWidth: 0.5)
      }
  }
}
