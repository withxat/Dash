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
    self.dismissBehavior = dismissBehavior
  }

  var resolvedTitle: String { title ?? kind.defaultTitle }
}

/// Single-slot toast queue owned by `AppModel`. A new toast replaces the
/// current one; auto-dismiss is cancelled when replaced or dismissed early.
@MainActor
@Observable
final class DashToastCenter {
  private(set) var current: DashToast?
  private var dismissTask: Task<Void, Never>?
  private var queued: DashToast?

  func success(_ message: String, title: String? = nil, haptic: Bool = true) {
    show(DashToast(kind: .success, title: title, message: message), haptic: haptic)
  }

  func error(_ message: String, title: String? = nil, haptic: Bool = true) {
    show(DashToast(kind: .error, title: title, message: message), haptic: haptic)
  }

  func warning(_ message: String, title: String? = nil, haptic: Bool = true) {
    show(DashToast(kind: .warning, title: title, message: message), haptic: haptic)
  }

  func show(_ toast: DashToast, haptic: Bool = true) {
    if current?.id == .deferredDeletionBatch,
      current?.dismissBehavior == .programmaticOnly,
      toast.id != .deferredDeletionBatch
    {
      queued = toast
      return
    }
    dismissTask?.cancel()
    current = toast
    if haptic { playHaptic(for: toast.kind) }
    UIAccessibility.post(
      notification: .announcement,
      argument: "\(toast.resolvedTitle). \(toast.message)")
    if toast.dismissBehavior == .automatic {
      scheduleDismiss(for: toast)
    }
  }

  func update(_ toast: DashToast, haptic: Bool = false) {
    guard current?.id == toast.id else {
      show(toast, haptic: haptic)
      return
    }
    show(toast, haptic: haptic)
  }

  func dismiss() {
    dismissTask?.cancel()
    dismissTask = nil
    current = nil
    if let queued {
      self.queued = nil
      show(queued)
    }
  }

  /// Drops the toast only if it is still the one that scheduled dismissal.
  func dismiss(id: DashToast.ID) {
    guard current?.id == id else { return }
    dismiss()
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
    HStack(alignment: .top, spacing: 12) {
      SolarIcon(asset: colors.icon, size: 22, color: colors.foreground)
        .frame(width: 36, height: 36)
        .background(colors.tint, in: Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(DashL10n.ui(toast.resolvedTitle))
          .dashTextStyle(.bodySemibold)
          .foregroundStyle(DashTheme.strong)
          .lineLimit(1)
        Text(DashL10n.ui(toast.message))
          .dashTextStyle(.supporting)
          .foregroundStyle(DashTheme.subtle)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let action = toast.action, let actionTitle = toast.actionTitle {
        Button(DashL10n.ui(actionTitle)) {
          model.performToastAction(action)
        }
        .buttonStyle(DashPressButtonStyle())
        .dashTextStyle(.bodySemibold)
        .foregroundStyle(colors.foreground)
        .accessibilityLabel(
          DashL10n.ui(toast.actionAccessibilityLabel ?? actionTitle))
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(DashTheme.Sheet.background, in: shape)
    .dashShadow(.raised, in: shape)
    .accessibilityElement(children: toast.action == nil ? .combine : .contain)
    .accessibilityLabel("\(toast.resolvedTitle): \(toast.message)")
  }
}

extension View {
  /// Mounts the shared toast host above this surface. Call once on the main
  /// canvas and again inside tray covers so toasts clear the dimmed sheet.
  func dashToastHost() -> some View {
    overlay(alignment: .top) { DashToastHost() }
  }
}
