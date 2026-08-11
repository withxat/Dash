import CloudflareAPI
import GradientAvatars
import SwiftUI
import UIKit

// MARK: - Link helpers

/// Supplies a navigation action whose concrete source occurrence is registered
/// with the custom page compositor. Use this for controls that need their own
/// button style; `DestinationLink` is the standard row-shaped convenience.
struct DashNavigationSource<Content: View>: View {
  let destination: Destination
  var presentation: DashNavigationPresentation?
  var hero: DashNavigationHero? = nil
  var onNavigate: (() -> Void)?
  /// Optional lifecycle boundary (for example a Tray's `dismissAfter`). The
  /// source geometry is captured on the tap, before the presenting surface
  /// unmounts; only the route mutation waits for the boundary to finish.
  var schedule: ((@escaping () -> Void) -> Void)?
  /// When true, the source anchor is published through the environment so an
  /// inner view (the header avatar circle) can register it. The outer wrapper
  /// stays unanchored — otherwise the morph would capture glass chrome.
  var embedsAnchor: Bool = false
  @ViewBuilder var content: (@escaping () -> Void) -> Content

  @Environment(\.destinationNavigator) private var navigator
  @Environment(\.dashNavigationAnchorRegistry) private var anchorRegistry
  @Environment(\.dashNavigationEntryID) private var sourceEntryID
  @State private var anchorInstanceID = UUID()

  var body: some View {
    if embedsAnchor {
      content(navigate)
        .environment(\.dashNavigationEmbeddedAnchorID, anchorInstanceID)
    } else {
      content(navigate)
        .dashNavigationAnchor(
          instanceID: anchorInstanceID,
          semanticID: destination.dashNavigationSemanticID)
    }
  }

  private func navigate() {
    let origin = anchorRegistry?.captureOrigin(
      semanticID: destination.dashNavigationSemanticID,
      anchorInstanceID: anchorInstanceID,
      hero: hero)
    let expectedNavigator = navigator
    let expectedSourceEntryID = sourceEntryID
    onNavigate?()
    // `onNavigate` may legitimately synchronize this navigator's account
    // scope. The delayed-intent baseline starts after that preparation, while
    // the source visual was still captured synchronously at the tap.
    let expectedRevision = expectedNavigator?.revision
    let expectedAccountID = expectedNavigator?.accountID
    let commit: () -> Void = {
      guard let expectedNavigator, let expectedRevision,
        expectedNavigator.revision == expectedRevision,
        expectedNavigator.accountID == expectedAccountID,
        expectedSourceEntryID == nil
          || expectedNavigator.topEntry?.id == expectedSourceEntryID
      else {
        anchorRegistry?.discardCapturedVisual(for: origin)
        return
      }
      let entryID = expectedNavigator.push(
        destination,
        presentation: presentation,
        origin: origin)
      if entryID == nil {
        anchorRegistry?.discardCapturedVisual(for: origin)
      }
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
