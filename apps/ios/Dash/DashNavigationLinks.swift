import CloudflareAPI
import GradientAvatars
import SwiftUI
import UIKit

// MARK: - Link helpers

/// Supplies a navigation action that pushes a destination onto the enclosing
/// tab's native `NavigationStack`. Use this for controls that need their own
/// button style; `DestinationLink` is the standard row-shaped convenience.
struct DashNavigationSource<Content: View>: View {
  let destination: Destination
  var presentation: DashNavigationPresentation?
  var hero: DashNavigationHero? = nil
  var onNavigate: (() -> Void)?
  /// Optional lifecycle boundary (for example a Tray's `dismissAfter`).
  var schedule: ((@escaping () -> Void) -> Void)?
  /// Kept for call-site compatibility; native `NavigationStack` requires no
  /// embedded anchor probe.
  var embedsAnchor: Bool = false
  @ViewBuilder var content: (@escaping () -> Void) -> Content

  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.dashNavigationEntryID) private var sourceEntryID

  var body: some View {
    content(navigate)
  }

  private func navigate() {
    let origin = hero.map {
      DashNavigationOrigin(
        semanticID: destination.dashNavigationSemanticID,
        anchorInstanceID: UUID(),
        sourceFrame: nil,
        hero: $0)
    }
    let expectedNavigator = navigator
    let expectedSourceEntryID = sourceEntryID
    onNavigate?()
    let expectedRevision = expectedNavigator?.revision
    let expectedAccountID = expectedNavigator?.accountID
    let commit: () -> Void = {
      guard let expectedNavigator, let expectedRevision,
        expectedNavigator.revision == expectedRevision,
        expectedNavigator.accountID == expectedAccountID,
        expectedSourceEntryID == nil
          || expectedNavigator.topEntry?.id == expectedSourceEntryID
      else {
        return
      }
      _ = expectedNavigator.push(
        destination,
        presentation: presentation,
        origin: origin)
    }
    if let schedule {
      schedule(commit)
    } else {
      commit()
    }
  }
}

/// Opens a `Destination` on the enclosing tab's custom page stack.
struct DestinationLink<Label: View>: View {
  let destination: Destination
  var hero: DashNavigationHero? = nil
  var onNavigate: (() -> Void)?
  @ViewBuilder var label: () -> Label

  var body: some View {
    DashNavigationSource(
      destination: destination,
      hero: hero,
      onNavigate: onNavigate
    ) { navigate in
      Button(action: navigate) {
        label()
      }
      // A navigation row is a surface, not a button — it must not shrink on press.
      .buttonStyle(DashSurfaceButtonStyle())
    }
  }
}

/// Opens a destination on the enclosing tab's navigation stack.
struct DashListGroupLink<Label: View>: View {
  let value: Destination
  var hero: DashNavigationHero? = nil
  var onNavigate: (() -> Void)?
  @ViewBuilder let label: () -> Label

  var body: some View {
    DestinationLink(destination: value, hero: hero, onNavigate: onNavigate, label: label)
  }
}
