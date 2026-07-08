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

/// A compact circular action rendered left of a `.content` tray's close button
/// (e.g. delete). Tray content publishes it with `dashTrayHeaderAction`.
struct DashSheetHeaderAction: Equatable {
  let id: String
  let icon: String
  var accessibilityLabel: String
  let perform: () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

private struct DashSheetHeaderActionKey: PreferenceKey {
  static var defaultValue: DashSheetHeaderAction? { nil }
  static func reduce(value: inout DashSheetHeaderAction?, nextValue: () -> DashSheetHeaderAction?) {
    value = nextValue() ?? value
  }
}

extension View {
  /// Publishes a circular header action (left of close) for the enclosing tray.
  func dashTrayHeaderAction(_ action: DashSheetHeaderAction?) -> some View {
    preference(key: DashSheetHeaderActionKey.self, value: action)
  }
}

/// Shared header (title + close, optional grab bar and trailing action) for both
/// tray styles.
private struct DashSheetHeader: View {
  let title: String
  var showsGrabBar = false
  var trailingAction: DashSheetHeaderAction? = nil
  let dismiss: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      if showsGrabBar { DashSheetGrabBar() }

      HStack(alignment: .center, spacing: 8) {
        Text(title)
          .font(.dashTitle(20))
          .foregroundStyle(DashTheme.strong)
        Spacer(minLength: 12)
        if let trailingAction {
          Button(action: trailingAction.perform) {
            SolarIcon(asset: trailingAction.icon, size: 22, color: DashTheme.danger)
              .frame(width: 32, height: 32)
              .background(DashTheme.dangerTint, in: Circle())
          }
          .padding(2)
          .buttonStyle(DashPressButtonStyle())
          .accessibilityLabel(trailingAction.accessibilityLabel)
        }
        DashCloseButton { dismiss() }
      }
      .padding(.horizontal, DashTheme.Sheet.content)
      .padding(.top, showsGrabBar ? 12 : DashTheme.Sheet.headerTop)
      .padding(.bottom, DashTheme.Sheet.headerBottom)

      Rectangle()
        .fill(DashTheme.Sheet.headerBorder)
        .frame(height: 1)
        .padding(.horizontal, DashTheme.Sheet.content)
    }
  }
}

/// `.content` trays: a full-screen transparent cover with our own dim and a
/// bottom-pinned card. The card springs its own height (DashSheetCard) so morphs
/// resize smoothly in both directions — there's no native detent to clip or snap.
/// The dim fades and the card slides/drags independently of the cover, which is
/// presented without its own transition (see DashTrayModifier).
private struct DashCustomSheet<Content: View>: View {
  let title: String
  /// Removes the cover once the exit animation has finished.
  let onDismiss: () -> Void
  @ViewBuilder var content: () -> Content
  @State private var shown = false
  @State private var drag: CGFloat = 0
  @State private var cardHeight: CGFloat = 0
  @State private var headerAction: DashSheetHeaderAction?

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black.opacity(shown ? DashTheme.Sheet.scrimOpacity : 0)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { close() }

      // Always laid out (only offset off-screen while hidden) so the whole card —
      // header action included — slides as one piece instead of the button
      // popping in a frame late.
      DashSheetCard {
        VStack(alignment: .leading, spacing: 0) {
          DashSheetHeader(title: title, trailingAction: headerAction, dismiss: close)
            // Drag-to-dismiss lives on the header only, so a scrollable body
            // (forms, detail) keeps its own vertical scroll.
            .contentShape(Rectangle())
            .gesture(dragGesture)
          content()
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, DashTheme.Sheet.bodyVertical)
        }
      }
      .offset(y: shown ? drag : hiddenOffset)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .environment(\.dashTrayDismiss, close)
    .onPreferenceChange(DashSheetFittedHeightKey.self) { cardHeight = $0 }
    .onPreferenceChange(DashSheetHeaderActionKey.self) { headerAction = $0 }
    .presentationBackground(.clear)
    .onAppear { withAnimation(DashTheme.Motion.sheet) { shown = true } }
  }

  /// Push the card fully below the screen while hidden, using its measured height
  /// so the visible slide distance equals the card — not a magic overshoot.
  private var hiddenOffset: CGFloat { (cardHeight > 0 ? cardHeight : 900) + 160 }

  private func close() {
    withAnimation(DashTheme.Motion.sheet) {
      shown = false
      drag = 0
    } completion: {
      onDismiss()
    }
  }

  private var dragGesture: some Gesture {
    // Global space: measuring in the header's own (moving) coordinates feeds the
    // offset back into the translation and makes the drag flicker.
    DragGesture(coordinateSpace: .global)
      .onChanged { value in drag = max(0, value.translation.height) }
      .onEnded { value in
        if value.translation.height > 120 {
          close()
        } else {
          withAnimation(DashTheme.Motion.sheet) { drag = 0 }
        }
      }
  }
}

/// `.large` trays keep the native sheet — a tall, scrollable list (Edit shortcuts)
/// doesn't need the morphing card.
private struct DashLargeSheet<Content: View>: View {
  let title: String
  @ViewBuilder var content: () -> Content
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      DashSheetHeader(title: title, showsGrabBar: true, dismiss: { dismiss() })
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, DashTheme.Sheet.bodyVertical)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(DashTheme.canvas)
    .environment(\.dashTrayDismiss, { dismiss() })
    .presentationDetents([.large])
    .presentationDragIndicator(.hidden)
    .presentationBackground(DashTheme.canvas)
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

/// The visible card of a `.content` tray, hosted in the bottom of a full-screen
/// transparent cover. It measures its natural height and springs a `display`
/// height toward it, clipping the content mid-flight — so a morph grows and
/// shrinks smoothly with no detent to clip or snap. Paints its own canvas fill,
/// top corners, and safe-area extension. First measurement is instant so the
/// tray opens crisply.
private struct DashSheetCard<Content: View>: View {
  @ViewBuilder let content: Content
  @State private var display: CGFloat = 0

  var body: some View {
    content
      // Hug the content vertically so ScrollView-based trays (forms, detail)
      // report a real natural height instead of greedily filling the cover.
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .top)
      .padding(.bottom, DashTheme.Sheet.bodyVertical)
      .background {
        GeometryReader { proxy in
          Color.clear.preference(key: DashSheetFittedHeightKey.self, value: proxy.size.height)
        }
      }
      .frame(height: display > 0 ? display : nil, alignment: .top)
      .clipped()
      .background {
        UnevenRoundedRectangle(
          topLeadingRadius: DashTheme.Radius.sheet,
          topTrailingRadius: DashTheme.Radius.sheet,
          style: .continuous
        )
        .fill(DashTheme.canvas)
        .ignoresSafeArea(.container, edges: .bottom)
      }
      .frame(maxWidth: .infinity)
      .onPreferenceChange(DashSheetFittedHeightKey.self) { natural in
        guard natural > 0 else { return }
        if display == 0 {
          display = natural
        } else {
          withAnimation(DashTheme.Motion.morph) { display = natural }
        }
      }
  }
}

// The full-screen cover is toggled without animation (`covered`, driven off the
// caller's binding through a disabled-animation transaction) so its own present
// transition never fires — DashCustomSheet owns the fade/slide and the exit
// finishes before the caller's binding clears.
private func dashPresentWithoutAnimation(_ apply: () -> Void) {
  var transaction = Transaction()
  transaction.disablesAnimations = true
  withTransaction(transaction, apply)
}

private struct DashTrayModifier<TrayContent: View>: ViewModifier {
  @Binding var isPresented: Bool
  let title: String
  var sizing: DashSheetSizing = .content
  @ViewBuilder var trayContent: () -> TrayContent
  @State private var covered = false

  @ViewBuilder
  func body(content: Content) -> some View {
    if sizing == .content {
      content
        .preference(key: TrayPresentedPreferenceKey.self, value: isPresented)
        .onChange(of: isPresented, initial: true) { _, present in
          dashPresentWithoutAnimation { covered = present }
        }
        .fullScreenCover(isPresented: $covered) {
          DashCustomSheet(
            title: title, onDismiss: { isPresented = false }, content: trayContent)
        }
    } else {
      content
        .preference(key: TrayPresentedPreferenceKey.self, value: isPresented)
        .sheet(isPresented: $isPresented) {
          DashLargeSheet(title: title, content: trayContent)
        }
    }
  }
}

private struct DashTrayItemModifier<Item: Identifiable & Equatable, TrayContent: View>: ViewModifier
{
  @Binding var item: Item?
  let title: (Item) -> String
  var sizing: DashSheetSizing = .content
  @ViewBuilder var trayContent: (Item) -> TrayContent
  @State private var coveredItem: Item?

  private var isPresented: Bool { item != nil }

  @ViewBuilder
  func body(content: Content) -> some View {
    if sizing == .content {
      content
        .preference(key: TrayPresentedPreferenceKey.self, value: isPresented)
        .onChange(of: item, initial: true) { _, newItem in
          dashPresentWithoutAnimation { coveredItem = newItem }
        }
        .fullScreenCover(item: $coveredItem) { value in
          DashCustomSheet(
            title: title(value), onDismiss: { item = nil }, content: { trayContent(value) })
        }
    } else {
      content
        .preference(key: TrayPresentedPreferenceKey.self, value: isPresented)
        .sheet(item: $item) { value in
          DashLargeSheet(title: title(value), content: { trayContent(value) })
        }
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

/// A form tray with exactly one action button. When a delete is supplied, a
/// circular header button morphs the form — in place — into a confirmation whose
/// single button is the destructive one; the Save button becomes Confirm rather
/// than a second button appearing. This is the canonical editor tray.
struct DashFormSheet<Content: View>: View {
  var saveTitle = "Save"
  var isSaving = false
  var canSave = true
  var deleteMessage: String? = nil
  var isDeleting = false
  var onDelete: (() -> Void)? = nil
  let onSave: () -> Void
  @ViewBuilder let content: Content
  @State private var confirmingDelete = false

  private var hasDelete: Bool { deleteMessage != nil && onDelete != nil }

  var body: some View {
    DashConfirmMorph(
      confirming: $confirmingDelete,
      message: deleteMessage,
      isBusy: confirmingDelete ? isDeleting : isSaving,
      actionTitle: confirmingDelete ? "Confirm" : saveTitle,
      actionRole: confirmingDelete ? .destructive : nil,
      actionEnabled: confirmingDelete || canSave,
      action: { confirmingDelete ? onDelete?() : onSave() },
      headerDelete: hasDelete,
      content: { content }
    )
    .dashKeyboardDismissal()
  }
}

/// The shared body/confirm morph: a body that swaps to a centered message, a
/// Cancel that fades in while confirming, and one persistent `DashActionButton`
/// that morphs in place (e.g. Save → Confirm). A header trash button flips
/// `confirming`. Reused by editor and detail trays so the whole app shares one
/// "a tray has one action button, or none" interaction.
private struct DashConfirmMorph<Content: View>: View {
  @Binding var confirming: Bool
  let message: String?
  let isBusy: Bool
  let actionTitle: String
  let actionRole: ButtonRole?
  let actionEnabled: Bool
  let action: () -> Void
  var headerDelete = false
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 16) {
      ZStack {
        if confirming, let message {
          Text(message)
            .font(.system(size: 15))
            .foregroundStyle(DashTheme.subtle)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .transition(.dashMorph)
        } else {
          content()
            .transition(.dashMorph)
        }
      }

      if confirming {
        Button {
          withAnimation(DashTheme.Motion.morph) { confirming = false }
        } label: {
          Text("Cancel")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(DashTheme.subtle)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DashPressButtonStyle())
        .transition(.dashMorph)
      }

      DashActionButton(
        title: actionTitle, role: actionRole, isLoading: isBusy, action: action
      )
      .disabled(!actionEnabled)
      .opacity(actionEnabled ? 1 : 0.45)
    }
    .padding(.horizontal, DashTheme.Sheet.content)
    .padding(.bottom, DashTheme.Sheet.bodyBottom)
    .dashTrayHeaderAction(
      headerDelete && !confirming
        ? DashSheetHeaderAction(
          id: "delete", icon: SolarAsset.trash, accessibilityLabel: "Delete"
        ) {
          withAnimation(DashTheme.Motion.morph) { confirming = true }
        }
        : nil
    )
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

private struct DashBlurModifier: ViewModifier {
  let radius: CGFloat
  func body(content: Content) -> some View {
    content.blur(radius: radius)
  }
}

extension AnyTransition {
  /// Softer cross-fade for morphing tray content: fades *and* blurs, so the
  /// before/after content dissolves rather than hard-swapping under the
  /// matchedGeometryEffect hero.
  static var dashMorph: AnyTransition {
    .opacity.combined(
      with: .modifier(
        active: DashBlurModifier(radius: 3),
        identity: DashBlurModifier(radius: 0)))
  }
}

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
          .transition(.dashMorph)
      } else {
        menu
          .transition(.dashMorph)
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

/// The single primary action button a `.content` tray should have — one, or
/// none. It morphs in place between a neutral state (e.g. Save) and a
/// destructive one (e.g. Confirm) by animating its own fill and label rather than
/// swapping two buttons, so it never shifts position.
struct DashActionButton: View {
  let title: String
  var role: ButtonRole? = nil
  var isLoading = false
  let action: () -> Void

  private var fill: Color { role == .destructive ? DashTheme.danger : DashTheme.strong }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if isLoading { ProgressView().tint(DashTheme.inverse) }
        Text(title)
          .font(.system(size: 16, weight: .semibold))
          .contentTransition(.opacity)
      }
      .foregroundStyle(DashTheme.inverse)
      .frame(maxWidth: .infinity, minHeight: 52)
      .background(fill, in: DashTheme.pillShape)
    }
    .buttonStyle(DashPressButtonStyle())
    .disabled(isLoading)
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
