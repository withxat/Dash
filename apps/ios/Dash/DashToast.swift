import SwiftUI
import UIKit

/// Transient top-of-screen feedback for completed or failed actions.
/// Persistent capability / form state stays in `DashNotice`.
struct DashToast: Identifiable, Equatable, Sendable {
  enum ID: Hashable, Sendable {
    case transient(UUID)
    case deferredDeletionBatch
  }

  enum Kind: Equatable, Sendable {
    case success
    case error
    case warning

    var defaultTitle: String {
      switch self {
      case .success: DashL10n.string("Success")
      case .error: DashL10n.string("Error")
      case .warning: DashL10n.string("Warning")
      }
    }

    var duration: TimeInterval {
      switch self {
      case .success: 2.4
      case .warning: 3.2
      case .error: 3.8
      }
    }
  }

  enum Action: Equatable, Sendable {
    case undoDeferredDeletionBatch
    case retryDeferredDeletion(UUID)
    case retryDeferredDeletions([UUID])
  }

  enum DismissBehavior: Equatable, Sendable {
    case automatic
    case programmaticOnly
  }

  let id: ID
  let kind: Kind
  var title: String?
  let message: String
  var duration: TimeInterval
  var action: Action?
  var actionTitle: String?
  var actionAccessibilityLabel: String?
  var accessibilityAnnouncement: String?
  var dismissBehavior: DismissBehavior

  init(
    id: ID = .transient(UUID()),
    kind: Kind,
    title: String? = nil,
    message: String,
    duration: TimeInterval? = nil,
    action: Action? = nil,
    actionTitle: String? = nil,
    actionAccessibilityLabel: String? = nil,
    accessibilityAnnouncement: String? = nil,
    dismissBehavior: DismissBehavior = .automatic
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.message = message
    self.duration = duration ?? kind.duration
    self.action = action
    self.actionTitle = actionTitle
    self.actionAccessibilityLabel = actionAccessibilityLabel
    self.accessibilityAnnouncement = accessibilityAnnouncement
    self.dismissBehavior = dismissBehavior
  }

  var resolvedTitle: String { title ?? kind.defaultTitle }
}

/// App-level toast queue owned by `AppModel`. Destructive-operation feedback
/// can temporarily protect the visible slot without dropping unrelated
/// feedback that arrives while Undo is available.
@MainActor
@Observable
final class DashToastCenter {
  /// Opaque ownership for the one coordinator allowed to mutate the
  /// programmatic-only deferred-deletion slot. A stable toast ID identifies
  /// presentation; it is not authorization to dismiss that presentation.
  struct DeferredDeletionOwner: Equatable, Sendable {
    fileprivate let token: UUID
  }

  private struct QueuedToast {
    var toast: DashToast
    var haptic: Bool
    var announce: Bool
    var deferredDeletionOwner: DeferredDeletionOwner?
    var deferredDeletionOperationIDs: Set<UUID>
    var onDismiss: (@MainActor @Sendable () -> Void)?
  }

  private(set) var current: DashToast?
  private var dismissTask: Task<Void, Never>?
  private var currentOnDismiss: (@MainActor @Sendable () -> Void)?
  private var currentDeferredDeletionOperationIDs: Set<UUID> = []
  private var queued: [QueuedToast] = []
  private var deferredDeletionOwnerToken: UUID?

  func claimDeferredDeletionOwner() -> DeferredDeletionOwner {
    precondition(
      deferredDeletionOwnerToken == nil,
      "Only one coordinator may own the deferred-deletion toast.")
    let owner = DeferredDeletionOwner(token: UUID())
    deferredDeletionOwnerToken = owner.token
    return owner
  }

  func success(_ message: String, title: String? = nil, haptic: Bool = true) {
    show(DashToast(kind: .success, title: title, message: message), haptic: haptic)
  }

  func error(_ message: String, title: String? = nil, haptic: Bool = true) {
    show(DashToast(kind: .error, title: title, message: message), haptic: haptic)
  }

  func warning(_ message: String, title: String? = nil, haptic: Bool = true) {
    show(DashToast(kind: .warning, title: title, message: message), haptic: haptic)
  }

  func show(
    _ toast: DashToast,
    haptic: Bool = true,
    announce: Bool = true,
    deferredDeletionOwner owner: DeferredDeletionOwner? = nil,
    deferredDeletionOperationIDs: Set<UUID> = [],
    onDismiss: (@MainActor @Sendable () -> Void)? = nil
  ) {
    guard isAuthorized(toPresent: toast, owner: owner) else { return }
    if current?.id == .deferredDeletionBatch,
      current?.dismissBehavior == .programmaticOnly,
      toast.id != .deferredDeletionBatch
    {
      let queuedToast = QueuedToast(
        toast: toast,
        haptic: haptic,
        announce: announce,
        deferredDeletionOwner: owner,
        deferredDeletionOperationIDs: deferredDeletionOperationIDs,
        onDismiss: onDismiss)
      if let index = queued.firstIndex(where: { $0.toast.id == toast.id }) {
        queued[index].onDismiss?()
        queued[index] = queuedToast
      } else {
        queued.append(queuedToast)
      }
      return
    }
    dismissTask?.cancel()
    let replacedOnDismiss = currentOnDismiss
    current = toast
    currentOnDismiss = onDismiss
    currentDeferredDeletionOperationIDs = deferredDeletionOperationIDs
    replacedOnDismiss?()
    if haptic { playHaptic(for: toast.kind) }
    if announce {
      UIAccessibility.post(
        notification: .announcement,
        argument: toast.accessibilityAnnouncement
          ?? "\(DashL10n.ui(toast.resolvedTitle)). \(toast.message)")
    }
    if toast.dismissBehavior == .automatic {
      scheduleDismiss(for: toast)
    }
  }

  func update(
    _ toast: DashToast,
    haptic: Bool = false,
    announce: Bool = true,
    deferredDeletionOwner owner: DeferredDeletionOwner? = nil,
    deferredDeletionOperationIDs: Set<UUID> = [],
    onDismiss: (@MainActor @Sendable () -> Void)? = nil
  ) {
    guard isAuthorized(toPresent: toast, owner: owner) else { return }
    guard current != toast else { return }
    guard current?.id == toast.id else {
      show(
        toast,
        haptic: haptic,
        announce: announce,
        deferredDeletionOwner: owner,
        deferredDeletionOperationIDs: deferredDeletionOperationIDs,
        onDismiss: onDismiss)
      return
    }
    show(
      toast,
      haptic: haptic,
      announce: announce,
      deferredDeletionOwner: owner,
      deferredDeletionOperationIDs: deferredDeletionOperationIDs,
      onDismiss: onDismiss)
  }

  func dismiss() {
    guard current?.dismissBehavior != .programmaticOnly else { return }
    dismissCurrent()
  }

  private func dismissCurrent() {
    dismissTask?.cancel()
    dismissTask = nil
    let onDismiss = currentOnDismiss
    currentOnDismiss = nil
    currentDeferredDeletionOperationIDs.removeAll()
    current = nil
    onDismiss?()
    if current == nil, !queued.isEmpty {
      let next = queued.removeFirst()
      show(
        next.toast,
        haptic: next.haptic,
        announce: next.announce,
        deferredDeletionOwner: next.deferredDeletionOwner,
        deferredDeletionOperationIDs: next.deferredDeletionOperationIDs,
        onDismiss: next.onDismiss)
    }
  }

  /// Drops the toast only if it is still the one that scheduled dismissal.
  func dismiss(id: DashToast.ID) {
    guard current?.id == id, current?.dismissBehavior != .programmaticOnly else { return }
    dismissCurrent()
  }

  func releaseDeferredDeletionToast(owner: DeferredDeletionOwner) {
    guard
      owner.token == deferredDeletionOwnerToken,
      current?.id == .deferredDeletionBatch
    else { return }
    dismissCurrent()
  }

  /// Removes feedback owned by the deletion coordinator during credential
  /// teardown without dropping unrelated app feedback. Dismiss callbacks are
  /// intentionally discarded because the coordinator is clearing the
  /// associated operation state itself.
  func purgeDeferredDeletionToasts(owner: DeferredDeletionOwner) {
    guard owner.token == deferredDeletionOwnerToken else { return }
    queued.removeAll {
      $0.toast.id == .deferredDeletionBatch
        && $0.deferredDeletionOwner == owner
    }
    guard current?.id == .deferredDeletionBatch else { return }
    dismissTask?.cancel()
    dismissTask = nil
    currentOnDismiss = nil
    currentDeferredDeletionOperationIDs.removeAll()
    current = nil
    if !queued.isEmpty {
      let next = queued.removeFirst()
      show(
        next.toast,
        haptic: next.haptic,
        announce: next.announce,
        deferredDeletionOwner: next.deferredDeletionOwner,
        deferredDeletionOperationIDs: next.deferredDeletionOperationIDs,
        onDismiss: next.onDismiss)
    }
  }

  /// Drops result feedback associated with superseded or invalidated
  /// operations and returns every operation represented by those aggregate
  /// descriptors so still-valid batches can be reported again. When the
  /// current result is removed, promotion is deferred until the coordinator
  /// has rendered its replacement state; otherwise a newly promoted result
  /// could be overwritten by that render.
  func discardDeferredDeletionResultFeedback(
    associatedWith operationIDs: Set<UUID>,
    owner: DeferredDeletionOwner
  ) -> Set<UUID> {
    guard owner.token == deferredDeletionOwnerToken else { return [] }
    var discardedOperationIDs: Set<UUID> = []
    queued.removeAll { item in
      guard item.deferredDeletionOwner == owner else { return false }
      guard !operationIDs.isDisjoint(with: item.deferredDeletionOperationIDs) else {
        return false
      }
      discardedOperationIDs.formUnion(item.deferredDeletionOperationIDs)
      return true
    }
    if current?.id == .deferredDeletionBatch,
      !operationIDs.isDisjoint(with: currentDeferredDeletionOperationIDs)
    {
      discardedOperationIDs.formUnion(currentDeferredDeletionOperationIDs)
      dismissTask?.cancel()
      dismissTask = nil
      currentOnDismiss = nil
      currentDeferredDeletionOperationIDs.removeAll()
      current = nil
    }
    return discardedOperationIDs
  }

  func promoteNextQueuedToastIfIdle() {
    guard current == nil, !queued.isEmpty else { return }
    let next = queued.removeFirst()
    show(
      next.toast,
      haptic: next.haptic,
      announce: next.announce,
      deferredDeletionOwner: next.deferredDeletionOwner,
      deferredDeletionOperationIDs: next.deferredDeletionOperationIDs,
      onDismiss: next.onDismiss)
  }

  /// Adds a finite coordinator result behind whatever the user is currently
  /// reading. Unlike an in-place state update, this preserves both an earlier
  /// reconciliation notice and a later success/failure result.
  func enqueueDeferredDeletionToast(
    _ toast: DashToast,
    owner: DeferredDeletionOwner,
    haptic: Bool = true,
    announce: Bool = true,
    operationIDs: Set<UUID> = [],
    onDismiss: (@MainActor @Sendable () -> Void)? = nil
  ) {
    guard isAuthorized(toPresent: toast, owner: owner) else { return }
    guard current != nil else {
      show(
        toast,
        haptic: haptic,
        announce: announce,
        deferredDeletionOwner: owner,
        deferredDeletionOperationIDs: operationIDs,
        onDismiss: onDismiss)
      return
    }
    queued.append(
      QueuedToast(
        toast: toast,
        haptic: haptic,
        announce: announce,
        deferredDeletionOwner: owner,
        deferredDeletionOperationIDs: operationIDs,
        onDismiss: onDismiss))
  }

  /// Session/language teardown must not drain queued feedback one item at a
  /// time. Optionally retain the already re-localized coordinator toast.
  func clearAll(preserving id: DashToast.ID? = nil) {
    let removedQueued = queued.filter { $0.toast.id != id }
    queued.removeAll { $0.toast.id != id }
    for item in removedQueued {
      item.onDismiss?()
    }
    guard current?.id != id else { return }
    dismissTask?.cancel()
    dismissTask = nil
    let onDismiss = currentOnDismiss
    currentOnDismiss = nil
    currentDeferredDeletionOperationIDs.removeAll()
    current = nil
    onDismiss?()
    if current == nil, !queued.isEmpty {
      let next = queued.removeFirst()
      show(
        next.toast,
        haptic: next.haptic,
        announce: next.announce,
        deferredDeletionOwner: next.deferredDeletionOwner,
        deferredDeletionOperationIDs: next.deferredDeletionOperationIDs,
        onDismiss: next.onDismiss)
    }
  }

  private func scheduleDismiss(for toast: DashToast) {
    let id = toast.id
    let nanoseconds = UInt64(toast.duration * 1_000_000_000)
    dismissTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled else { return }
      self?.dismiss(id: id)
    }
  }

  private func isAuthorized(
    toPresent toast: DashToast,
    owner: DeferredDeletionOwner?
  ) -> Bool {
    guard toast.id == .deferredDeletionBatch else { return true }
    return owner?.token == deferredDeletionOwnerToken
  }

  private func playHaptic(for kind: DashToast.Kind) {
    switch kind {
    case .success: DashDelight.celebrateSuccess()
    case .error: DashDelight.failError()
    case .warning: DashDelight.warnImpact()
    }
  }
}

/// Floating top tray card — same sheet surface + floating margins as bottom trays.
struct DashToastHost: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dragOffset: CGFloat = 0

  private var toast: DashToast? { model.toasts.current }

  var body: some View {
    Group {
      if let toast {
        DashToastCard(toast: toast)
          .padding(.horizontal, DashTheme.Sheet.floatingMargin)
          // Main canvas ignores the top safe area; keep the card below the
          // status bar / Dynamic Island the same way floating trays inset.
          .safeAreaPadding(.top)
          .padding(.top, DashTheme.Sheet.floatingMargin)
          .offset(y: min(0, dragOffset))
          .opacity(dragOpacity)
          .gesture(toast.dismissBehavior == .automatic ? dismissDrag : nil)
          .transition(toastTransition)
          .onTapGesture {
            if toast.dismissBehavior == .automatic, toast.action == nil {
              dismissAnimated()
            }
          }
      }
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .animation(
      reduceMotion ? DashTheme.Motion.reduced : DashToastMotion.present,
      value: toast?.id
    )
    .onChange(of: toast?.id) { _, _ in dragOffset = 0 }
  }

  private var dragOpacity: Double {
    guard dragOffset < 0 else { return 1 }
    return Double(max(0.35, 1 + dragOffset / 80))
  }

  private var toastTransition: AnyTransition {
    if reduceMotion {
      return .opacity
    }
    return .asymmetric(
      insertion: .move(edge: .top).combined(with: .opacity),
      removal: .move(edge: .top).combined(with: .opacity)
    )
  }

  private var dismissDrag: some Gesture {
    DragGesture(minimumDistance: 8)
      .onChanged { value in
        // Only pull upward — downward would fight the present spring.
        dragOffset = min(0, value.translation.height)
      }
      .onEnded { value in
        let shouldDismiss =
          value.translation.height < -36 || value.predictedEndTranslation.height < -80
        if shouldDismiss {
          dismissAnimated()
        } else if reduceMotion {
          dragOffset = 0
        } else {
          withAnimation(DashToastMotion.release) { dragOffset = 0 }
        }
      }
  }

  private func dismissAnimated() {
    if reduceMotion {
      dragOffset = 0
      model.toasts.dismiss()
    } else {
      withAnimation(DashToastMotion.dismiss) {
        dragOffset = 0
        model.toasts.dismiss()
      }
    }
  }
}

/// The toast host shares the tray's floating-surface springs — one present /
/// release / dismiss set for both, defined in `DashTheme.Motion`.
private enum DashToastMotion {
  static let present = DashTheme.Motion.present
  static let release = DashTheme.Motion.release
  static let dismiss = DashTheme.Motion.dismiss
}

private struct DashToastCard: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let toast: DashToast

  private var colors: (foreground: Color, tint: Color, icon: String) {
    switch toast.kind {
    case .success:
      (DashTheme.success, DashTheme.successTint, SolarAsset.Content.checkCircle)
    case .error:
      (DashTheme.danger, DashTheme.dangerTint, SolarAsset.Content.danger)
    case .warning:
      (DashTheme.warning, DashTheme.warningTint, SolarAsset.Content.danger)
    }
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: DashDisplayChrome.floatingRadius, style: .continuous)
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 12) {
          toastCopy
          actionButton
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      } else {
        HStack(alignment: .top, spacing: 12) {
          toastCopy
          actionButton
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DashTheme.Sheet.background, in: shape)
    .dashShadow(.raised, in: shape)
  }

  private var toastCopy: some View {
    HStack(alignment: .top, spacing: 12) {
      SolarIcon(asset: colors.icon, size: 22, color: colors.foreground)
        .frame(width: 36, height: 36)
        .background(colors.tint, in: Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(DashL10n.ui(toast.resolvedTitle))
          .dashTextStyle(.bodySemibold)
          .foregroundStyle(DashTheme.strong)
          .fixedSize(horizontal: false, vertical: true)
        Text(DashL10n.ui(toast.message))
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(DashL10n.ui(toast.resolvedTitle)): \(toast.message)")
  }

  @ViewBuilder
  private var actionButton: some View {
    if let action = toast.action, let actionTitle = toast.actionTitle {
      Button {
        model.performToastAction(action)
      } label: {
        Text(DashL10n.ui(actionTitle))
          .dashTextStyle(.bodySemibold)
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(DashPressButtonStyle())
      .foregroundStyle(colors.foreground)
      .accessibilityLabel(
        DashL10n.ui(toast.actionAccessibilityLabel ?? actionTitle)
      )
      .accessibilityIdentifier("dash-toast-action")
    }
  }
}

extension View {
  /// Mounts the shared toast host above this surface. Call once on the main
  /// canvas and again inside tray covers so toasts clear the dimmed sheet.
  func dashToastHost() -> some View {
    overlay(alignment: .top) { DashToastHost() }
  }
}
