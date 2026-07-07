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
    .modifier(DashSheetOuterBottomPadding(enabled: sizing == .content))
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
        DashCloseButton { dismiss() }
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
        .padding(.top, DashTheme.Sheet.bodyVertical)
    }
  }
}

private struct DashSheetOuterBottomPadding: ViewModifier {
  let enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      content.safeAreaPadding(.bottom, DashTheme.Sheet.outerBottom)
    } else {
      content
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

struct CatalogToolbar: ToolbarContent {
  @Environment(AppModel.self) private var model
  @Environment(\.showsProfile) private var showsProfile

  var body: some ToolbarContent {
    leadingAvatarItem
  }

  @ToolbarContentBuilder
  private var leadingAvatarItem: some ToolbarContent {
    if #available(iOS 26.0, *) {
      ToolbarItem(placement: .topBarLeading) { profileButton }
        .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .topBarLeading) { profileButton }
    }
  }

  private var profileButton: some View {
    Button {
      showsProfile.wrappedValue = true
    } label: {
      HeaderProfileAvatar(email: model.user?.email ?? "")
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Open profile")
  }
}

extension View {
  func dashCatalogScreen(_ title: String) -> some View {
    navigationTitle(title)
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        CatalogToolbar()
      }
      .toolbarBackground(DashTheme.canvas, for: .navigationBar)
      .background(DashTheme.canvas)
  }

  func dashCatalogSearch(
    text: Binding<String>,
    prompt: String
  ) -> some View {
    modifier(
      DashCatalogSearchModifier(text: text, prompt: prompt))
  }
}

// Hand-rolled header search. The system `.searchable` +
// `.searchToolbarBehavior(.minimize)` + top-bar `DefaultToolbarItem` combo
// re-presents the field after dismissal and hangs the first expansion on
// iOS 26 hardware, so catalog screens draw their own button and field.
private struct DashCatalogSearchModifier: ViewModifier {
  @Binding var text: String
  let prompt: String
  @State private var isExpanded = false
  @FocusState private var isFocused: Bool

  func body(content: Content) -> some View {
    content
      .safeAreaInset(edge: .top, spacing: 0) {
        if isExpanded {
          searchBar
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .toolbar {
        if !isExpanded {
          searchToolbarItem
        }
      }
  }

  private var searchBar: some View {
    HStack(spacing: 12) {
      DashInlineSearch(prompt: prompt, text: $text, reportsFocus: $isFocused)
      DashCloseButton(accessibilityLabel: "Close search") { collapse() }
    }
    .padding(.horizontal, DashTheme.Spacing.screen)
    .padding(.bottom, 10)
    .background(DashTheme.canvas)
    .onAppear { isFocused = true }
  }

  @ToolbarContentBuilder
  private var searchToolbarItem: some ToolbarContent {
    if #available(iOS 26.0, *) {
      ToolbarItem(placement: .topBarTrailing) { searchButton }
        .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .topBarTrailing) { searchButton }
    }
  }

  private var searchButton: some View {
    Button {
      withAnimation(.easeOut(duration: 0.22)) { isExpanded = true }
    } label: {
      ZStack {
        Circle().fill(DashTheme.elevated)
        SolarIcon(asset: SolarAsset.search, size: 20, color: DashTheme.strong)
      }
      .frame(width: AvatarHeaderMetrics.barSize, height: AvatarHeaderMetrics.barSize)
      .overlay { Circle().stroke(DashTheme.line, lineWidth: 0.5) }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Search")
  }

  private func collapse() {
    isFocused = false
    withAnimation(.easeOut(duration: 0.22)) {
      isExpanded = false
      text = ""
    }
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

/// Circular close control shared by tray headers and the catalog search bar.
struct DashCloseButton: View {
  var accessibilityLabel = "Close"
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      SolarIcon(asset: SolarAsset.close, size: 22, color: DashTheme.Sheet.closeIcon)
        .frame(width: 32, height: 32)
        .background(DashTheme.recessed, in: Circle())
    }
    .padding(2)
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(accessibilityLabel)
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
