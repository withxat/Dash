import Combine
import SwiftUI
import UIKit

// MARK: - Sheet presentation

/// Whether a subtree currently presents the app's single compact tray, bubbled
/// to `MainTabView` so root chrome can hide the dock and header avatar.
struct DashTrayPresentation: Equatable {
  var presented = false
}

/// Cross-host bridge for page-owned trays. Preferences cannot cross from a
/// cached `UIHostingController` into `MainTabView`, so each tray also reports
/// its stable modifier instance here while the custom page stack is active.
@MainActor
@Observable
final class DashWorkspacePresentationState {
  private struct Reporter: Equatable {
    let entryID: UUID?
    var presented: Bool
  }

  private var trayPresentations: [UUID: Reporter] = [:]
  private var coverPresentations: [UUID: Reporter] = [:]

  var trayPresented: Bool {
    trayPresentations.values.contains { $0.presented }
  }

  var coverPresented: Bool {
    coverPresentations.values.contains { $0.presented }
  }

  /// Guarded, because `@Observable` notifies on every write — equal or not —
  /// and `MainTabView`'s body reads `trayPresented` to decide the dock, the
  /// header displacement, and route consumption. Each `dashTray` reports from
  /// both `onAppear` and an `initial: true` `onChange`, so a screen carrying
  /// several of them (Settings has four) re-invalidated the view that lays it
  /// out once per report, on the frame it mounted.
  func setTrayPresented(_ presented: Bool, reporterID: UUID, entryID: UUID?) {
    let reporter = Reporter(entryID: entryID, presented: presented)
    guard trayPresentations[reporterID] != reporter else { return }
    trayPresentations[reporterID] = reporter
  }

  func setCoverPresented(_ presented: Bool, reporterID: UUID, entryID: UUID?) {
    let reporter = Reporter(entryID: entryID, presented: presented)
    guard coverPresentations[reporterID] != reporter else { return }
    coverPresentations[reporterID] = reporter
  }

  /// Same guard: pruning an entry that reported nothing must not rewrite the
  /// dictionaries, or every replaced entry invalidates `MainTabView` for free.
  func removePresentationReporters(forEntryID entryID: UUID) {
    let trays = trayPresentations.filter { $0.value.entryID != entryID }
    if trays.count != trayPresentations.count { trayPresentations = trays }
    let covers = coverPresentations.filter { $0.value.entryID != entryID }
    if covers.count != coverPresentations.count { coverPresentations = covers }
  }
}

private struct DashWorkspacePresentationStateKey: EnvironmentKey {
  static let defaultValue: DashWorkspacePresentationState? = nil
}

extension EnvironmentValues {
  var dashWorkspacePresentationState: DashWorkspacePresentationState? {
    get { self[DashWorkspacePresentationStateKey.self] }
    set { self[DashWorkspacePresentationStateKey.self] = newValue }
  }
}

struct TrayPresentedPreferenceKey: PreferenceKey {
  static let defaultValue = DashTrayPresentation()
  static func reduce(value: inout DashTrayPresentation, nextValue: () -> DashTrayPresentation) {
    let next = nextValue()
    value.presented = value.presented || next.presented
  }
}

/// Layout constants for the floating dock capsule (`DashFloatingTabBar`).
enum DashDockMetrics {
  /// Width of one tab cell; the bar is `cell × tab count` wide.
  static let cell: CGFloat = 80
  static let height: CGFloat = 64
  /// How far `MainTabView` sinks the bar into the home-indicator inset.
  static let bottomSink: CGFloat = 10
}

private struct DashTrayDismissKey: EnvironmentKey {
  nonisolated(unsafe) static let defaultValue: () -> Void = {}
}

private struct DashTrayDismissAfterKey: EnvironmentKey {
  nonisolated(unsafe) static let defaultValue: (@escaping () -> Void) -> Void = {
    completion in completion()
  }
}

struct DashTrayDismissDisabledPreferenceKey: PreferenceKey {
  static let defaultValue = false

  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}

private struct DashTrayToneKey: EnvironmentKey {
  static let defaultValue: FeatureVisualTone? = nil
}

private struct DashTrayBodyMaxHeightKey: EnvironmentKey {
  static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
  var dashTrayDismiss: () -> Void {
    get { self[DashTrayDismissKey.self] }
    set { self[DashTrayDismissKey.self] = newValue }
  }

  /// Closes through the tray's complete keyboard/exit choreography, then runs
  /// work that would otherwise tear down or navigate away from its presenter.
  var dashTrayDismissAfter: (@escaping () -> Void) -> Void {
    get { self[DashTrayDismissAfterKey.self] }
    set { self[DashTrayDismissAfterKey.self] = newValue }
  }

  /// Contextual tone of the presenting flow — Family's "the tray dresses for
  /// the room it walks into". `nil` (the default) is the neutral tray. Set via
  /// `dashTray(tone:)`; feature-launched trays pass
  /// `FeatureVisualIdentity.tone(for:)`, Profile/Settings trays stay neutral.
  /// Applied sparingly: the footer submit pill, a non-destructive header
  /// action circle, and a whisper of wash at the card top. The tray background
  /// token itself never changes.
  var dashTrayTone: FeatureVisualTone? {
    get { self[DashTrayToneKey.self] }
    set { self[DashTrayToneKey.self] = newValue }
  }

  /// How tall the tray's content may grow before the card runs out of room —
  /// published by `DashSheetCard`, spent by `DashTrayScrollBoundary`, which
  /// hands what is left after its action band to the scrolling body. `nil`
  /// outside a tray (and on the first frame, before the header is measured):
  /// no budget, so the boundary lays out at natural height and never scrolls.
  var dashTrayBodyMaxHeight: CGFloat? {
    get { self[DashTrayBodyMaxHeightKey.self] }
    set { self[DashTrayBodyMaxHeightKey.self] = newValue }
  }
}
