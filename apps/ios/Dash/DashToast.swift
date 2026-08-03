import SwiftUI
import UIKit

/// Transient top-of-screen feedback for completed or failed actions.
/// Persistent capability / form state stays in `DashNotice`.
struct DashToast: Identifiable, Equatable, Sendable {
  enum ID: Hashable, Sendable {
    case transient(UUID)
    case deferredDeletionBatch
    /// One optimistic / await-then-toast mutation owned by
    /// `DashOptimisticOperationCenter`.
    case optimistic(UUID)
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

    /// Short dwell so a queued run of automatic toasts advances quickly.
    /// Persistent (`programmaticOnly`) toasts ignore this and hold the slot.
    var duration: TimeInterval {
      switch self {
      case .success: 1.6
      case .warning: 2.2
      case .error: 2.6
      }
    }
  }

  enum Action: Equatable, Sendable {
    case undoDeferredDeletionBatch
    case retryDeferredDeletion(UUID)
    case retryDeferredDeletions([UUID])
    case undoOptimistic(UUID)
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
  /// When set, the card leading mark is `DashActionStatusIcon` (ring → check)
  /// instead of the kind glyph.
  var actionPhase: DashActionPhase?
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
    actionPhase: DashActionPhase? = nil,
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
    self.actionPhase = actionPhase
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

  /// When a new automatic toast arrives behind another automatic one, cut the
  /// visible dwell short so the queue replaces soon instead of stacking waits.
  private static let automaticReplaceDelay: TimeInterval = 0.4

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

    // Same identity refreshes in place (Undo copy, batch count, …).
    if current?.id == toast.id {
      present(
        toast,
        haptic: haptic,
        announce: announce,
        deferredDeletionOperationIDs: deferredDeletionOperationIDs,
        onDismiss: onDismiss)
      return
    }

    // A fresh destructive grace period must expose Undo immediately. It may
    // preempt finite automatic feedback, while another protected operation
    // still holds the slot until its owner releases it.
    if toast.id == .deferredDeletionBatch,
      toast.action == .undoDeferredDeletionBatch,
      toast.dismissBehavior == .programmaticOnly,
      current?.dismissBehavior == .automatic
    {
      discardQueuedPendingDeletionToast()
      present(
        toast,
        haptic: haptic,
        announce: announce,
        deferredDeletionOperationIDs: deferredDeletionOperationIDs,
        onDismiss: onDismiss)
      return
    }

    // Slot busy: queue. Automatic toasts accelerate so the next one lands soon;
    // programmatic-only (Undo) holds until the coordinator releases it.
    if current != nil {
      enqueue(
        toast,
        haptic: haptic,
        announce: announce,
        deferredDeletionOwner: owner,
        deferredDeletionOperationIDs: deferredDeletionOperationIDs,
        onDismiss: onDismiss)
      if current?.dismissBehavior == .automatic {
        scheduleAcceleratedDismiss()
      }
      return
    }

    present(
      toast,
      haptic: haptic,
      announce: announce,
      deferredDeletionOperationIDs: deferredDeletionOperationIDs,
      onDismiss: onDismiss)
  }

  private func enqueue(
    _ toast: DashToast,
    haptic: Bool,
    announce: Bool,
    deferredDeletionOwner owner: DeferredDeletionOwner?,
    deferredDeletionOperationIDs: Set<UUID>,
    onDismiss: (@MainActor @Sendable () -> Void)?
  ) {
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
  }

  /// A pending deletion can first queue behind another protected operation,
  /// then become eligible to preempt after that operation turns automatic.
  /// Drop the stale queued copy before presenting the latest deadline/count.
  private func discardQueuedPendingDeletionToast() {
    queued.removeAll { item in
      guard
        item.toast.id == .deferredDeletionBatch,
        item.toast.action == .undoDeferredDeletionBatch,
        item.toast.dismissBehavior == .programmaticOnly
      else { return false }
      item.onDismiss?()
      return true
    }
  }

  private func present(
    _ toast: DashToast,
    haptic: Bool,
    announce: Bool,
    deferredDeletionOperationIDs: Set<UUID>,
    onDismiss: (@MainActor @Sendable () -> Void)?
  ) {
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
    dismissCurrent(force: false)
  }

  private func dismissCurrent(force: Bool) {
    if !force, current?.dismissBehavior == .programmaticOnly { return }
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
    dismissCurrent(force: false)
  }

  func releaseDeferredDeletionToast(owner: DeferredDeletionOwner) {
    guard
      owner.token == deferredDeletionOwnerToken,
      current?.id == .deferredDeletionBatch
    else { return }
    dismissCurrent(force: true)
  }

  /// Drops an optimistic toast even while it is `programmaticOnly`.
  func dismissOptimistic(id: UUID) {
    let toastID = DashToast.ID.optimistic(id)
    queued.removeAll {
      guard $0.toast.id == toastID else { return false }
      $0.onDismiss?()
      return true
    }
    guard current?.id == toastID else { return }
    dismissCurrent(force: true)
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

  /// Cuts an automatic toast's remaining dwell so a queued successor can take
  /// the slot without waiting out the full success/error duration.
  private func scheduleAcceleratedDismiss() {
    guard let current, current.dismissBehavior == .automatic else { return }
    let id = current.id
    dismissTask?.cancel()
    let nanoseconds = UInt64(Self.automaticReplaceDelay * 1_000_000_000)
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

/// Floating toast host — top edge matches the floated profile avatar numerically
/// (`AvatarHeaderMetrics.chromeInset` below the status-bar safe area).
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
          // Main canvas ignores the top safe area; land on the same band as
          // the floated avatar (safe area + chrome inset), not tray margins.
          .safeAreaPadding(.top)
          .padding(.top, AvatarHeaderMetrics.chromeInset)
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
    // Drop in from above with spring overshoot — paired with
    // `DashToastMotion.present`'s under-damped spring.
    return .asymmetric(
      insertion: .offset(y: -28).combined(with: .opacity),
      removal: .offset(y: -16).combined(with: .opacity)
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

/// Toast-only motion: present is springier than trays so the card can settle
/// with a short bounce. Release / dismiss stay on the shared floating set.
private enum DashToastMotion {
  static let present = Animation.spring(
    response: 0.42, dampingFraction: 0.68, blendDuration: 0.1)
  static let release = DashTheme.Motion.release
  static let dismiss = DashTheme.Motion.dismiss
}

private struct DashToastCard: View {
  @Environment(AppModel.self) private var model
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let toast: DashToast

  private var accent: Color {
    switch toast.kind {
    case .success: DashTheme.success
    case .error: DashTheme.danger
    case .warning: DashTheme.warning
    }
  }

  private var kindIcon: String {
    switch toast.kind {
    case .success: SolarAsset.Content.checkCircle
    case .error: SolarAsset.Content.danger
    case .warning: SolarAsset.Content.danger
    }
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: DashTheme.Radius.card, style: .continuous)
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 10) {
          toastCopy
          actionButton
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      } else {
        HStack(alignment: .center, spacing: 10) {
          toastCopy
          actionButton
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DashTheme.homeDomainsSurface, in: shape)
    // Soft lift only — no ring. `dashShadow` is a 1pt border and would fight
    // the Domains-plate look.
    .shadow(
      color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08),
      radius: 10,
      x: 0,
      y: 3
    )
  }

  private var toastCopy: some View {
    HStack(alignment: .center, spacing: 10) {
      leadingMark

      Text(DashL10n.ui(toast.message))
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(DashTheme.strong)
        .contentTransition(reduceMotion ? .opacity : .interpolate)
        .animation(
          reduceMotion ? DashTheme.Motion.reduced : DashTheme.Motion.iconSwap,
          value: toast.message
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  @ViewBuilder
  private var leadingMark: some View {
    if let phase = toast.actionPhase {
      DashActionStatusIcon(
        phase: phase,
        loadingColor: DashTheme.brand,
        successColor: DashTheme.success,
        size: 20,
        lineWidth: 2.5
      )
    } else {
      SolarIcon(asset: kindIcon, size: 20, color: accent)
        .accessibilityHidden(true)
    }
  }

  private var accessibilityLabel: String {
    if toast.actionPhase != nil {
      return toast.message
    }
    return "\(DashL10n.ui(toast.resolvedTitle)): \(toast.message)"
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
      .foregroundStyle(accent)
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
