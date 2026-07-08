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
      .background(DashTheme.canvas)
  }

}

// MARK: - Tray content helpers

struct DashFormSheet<Content: View>: View {
  var saveTitle = "Save"
  var isSaving = false
  var canSave = true
  /// Optional high-risk actions (e.g. Delete) rendered below Save, each morphing
  /// into a confirmation step via `DashConfirmableActions`.
  var dangerActions: [DashDangerAction] = []
  let onSave: () -> Void
  @ViewBuilder let content: Content

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        VStack(spacing: 16) {
          content
          DashPillButton(title: saveTitle, isLoading: isSaving, action: onSave)
            .disabled(!canSave || isSaving)
            .opacity(canSave ? 1 : 0.45)
        }
        .padding(.horizontal, DashTheme.Sheet.content)

        if !dangerActions.isEmpty {
          DashConfirmableActions(actions: dangerActions)
            .padding(.top, 4)
        }
      }
      .padding(.bottom, dangerActions.isEmpty ? DashTheme.Sheet.bodyBottom : 0)
    }
    .scrollBounceBehavior(.basedOnSize)
    .dashKeyboardDismissal()
    .safeAreaPadding(.bottom)
  }
}

private struct DashKeyboardDismissalModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .scrollDismissesKeyboard(.immediately)
      .contentShape(Rectangle())
      .onTapGesture(perform: dismissKeyboard)
  }

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }
}

extension View {
  func dashKeyboardDismissal() -> some View {
    modifier(DashKeyboardDismissalModifier())
  }
}

struct DashFormField: View {
  let label: String
  @Binding var text: String
  var keyboard: UIKeyboardType = .default
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DashTheme.subtle)
      TextField(label, text: $text)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(DashTheme.text)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(keyboard)
        .focused($isFocused)
        .submitLabel(.done)
        .onSubmit { isFocused = false }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(DashTheme.recessed)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
    }
  }
}

/// Multiline code variant of DashFormField for tray forms.
struct DashFormCodeField: View {
  let label: String
  @Binding var text: String
  var minHeight: CGFloat = 220

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(label)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DashTheme.subtle)
      TextEditor(text: $text)
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(DashTheme.text)
        .scrollContentBackground(.hidden)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .frame(minHeight: minHeight)
        .padding(12)
        .background(DashTheme.recessed)
        .clipShape(RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
    }
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
      .background(DashTheme.strong, in: DashTheme.pillShape)
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
      .background(DashTheme.recessed, in: DashTheme.pillShape)
      .overlay {
        DashTheme.pillShape.stroke(DashTheme.line, lineWidth: 0.5)
      }
  }
}

// MARK: - Danger confirmation morph

/// A single high-risk action presented inside a tray. Tapping its row morphs —
/// via matchedGeometryEffect — into an inline confirmation step before `perform`
/// runs. This is the canonical tray danger pattern; reuse it everywhere a
/// destructive action needs a second tap (purge, delete, sign out).
struct DashDangerAction: Identifiable {
  /// Stable across re-renders — it drives the matchedGeometryEffect morph, so it
  /// must NOT be a fresh UUID per render. Defaults to `title`.
  let id: String
  let title: String
  let icon: String
  let message: String
  let perform: () async -> Void

  init(
    id: String? = nil,
    title: String,
    icon: String = SolarAsset.trash,
    message: String,
    perform: @escaping () async -> Void
  ) {
    self.id = id ?? title
    self.title = title
    self.icon = icon
    self.message = message
    self.perform = perform
  }
}

/// Tray content that lists destructive actions as menu rows and morphs a tapped
/// one — via matchedGeometryEffect — into a confirm step (message, a plain
/// Cancel, and a red Confirm that the row grows into). Self-insets for standalone
/// trays; pass `horizontalInset: 0` when embedding under content that already
/// insets (e.g. `DashDetailTray`).
struct DashConfirmableActions: View {
  let actions: [DashDangerAction]
  var horizontalInset: CGFloat = DashTheme.Sheet.content
  @Namespace private var morph
  @State private var pending: DashDangerAction?
  @State private var working = false
  @Environment(\.dashTrayDismiss) private var dismiss

  var body: some View {
    ZStack {
      if let pending {
        confirmation(pending)
          .transition(.opacity)
      } else {
        menu
          .transition(.opacity)
      }
    }
    .padding(.horizontal, horizontalInset)
    .padding(.bottom, 8)
  }

  private var menu: some View {
    VStack(spacing: 10) {
      ForEach(actions) { action in
        Button {
          withAnimation(DashTheme.Motion.morph) { pending = action }
        } label: {
          dangerRow(action)
        }
        .buttonStyle(DashPressButtonStyle())
      }
    }
  }

  // List-item styled after Edit shortcuts rows, with an outline icon.
  private func dangerRow(_ action: DashDangerAction) -> some View {
    HStack(spacing: 12) {
      SolarIcon(asset: action.icon, size: 22, color: DashTheme.danger)
      Text(action.title)
        .font(.body)
        .foregroundStyle(DashTheme.danger)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: DashTheme.Radius.button, style: .continuous)
        .fill(DashTheme.dangerTint)
        .matchedGeometryEffect(id: action.id, in: morph)
    }
  }

  private func confirmation(_ action: DashDangerAction) -> some View {
    VStack(spacing: 16) {
      Text(action.message)
        .font(.system(size: 15))
        .foregroundStyle(DashTheme.subtle)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
        .padding(.top, 4)

      VStack(spacing: 4) {
        Button {
          withAnimation(DashTheme.Motion.morph) { pending = nil }
        } label: {
          Text("Cancel")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DashPressButtonStyle())
        .disabled(working)

        Button {
          Task {
            working = true
            await action.perform()
            dismiss()
          }
        } label: {
          HStack(spacing: 8) {
            if working { ProgressView().tint(DashTheme.inverse) }
            Text("Confirm")
              .font(.system(size: 16, weight: .semibold))
          }
          .foregroundStyle(DashTheme.inverse)
          .frame(maxWidth: .infinity, minHeight: 52)
          .background {
            DashTheme.pillShape
              .fill(DashTheme.danger)
              .matchedGeometryEffect(id: action.id, in: morph)
          }
        }
        .buttonStyle(DashPressButtonStyle())
        .disabled(working)
      }
    }
  }
}

// MARK: - Header more menu

/// Trailing toolbar button that opens a `dashMoreMenu` tray of danger actions.
struct DashMoreButton: View {
  @Binding var isPresented: Bool
  var accessibilityLabel = "More actions"

  var body: some View {
    Button {
      isPresented = true
    } label: {
      DashToolbarActionIcon(asset: SolarAsset.menuDots)
    }
    .buttonStyle(DashPressButtonStyle())
    .accessibilityLabel(accessibilityLabel)
  }
}

extension View {
  /// Attaches a tray of high-risk actions, each morphing to a confirmation step.
  func dashMoreMenu(
    isPresented: Binding<Bool>,
    title: String = "Actions",
    actions: [DashDangerAction]
  ) -> some View {
    dashTray(isPresented: isPresented, title: title) {
      DashConfirmableActions(actions: actions)
    }
  }
}
