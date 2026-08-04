import CloudflareAPI
import Observation
import SwiftUI

// MARK: - Session state

/// Session snapshot of Cloudflare's status page. Deliberately NOT `Codable`:
/// `FeatureDataCache` mirrors Codable values to disk, and a relaunch repainting
/// yesterday's outage as if it were current is worse than a skeleton.
struct CloudflareStatusSnapshot: Hashable {
  let summary: CloudflareStatusSummary
  let fetchedAt: Date
}

@MainActor
@Observable
final class CloudflareStatusState {
  private(set) var snapshot: CloudflareStatusSnapshot?
  private(set) var isLoading = false
  private(set) var failureMessage: String?

  /// Status freshness: 5 minutes, not the cache default 15 — the page is the
  /// thing users check *during* an incident.
  private static let ttl: TimeInterval = 5 * 60

  /// Watchtower panel phase. Last-known content survives a failed warm
  /// refresh; only a cold miss veils the section.
  var sectionPhase: DashSectionPhase {
    if snapshot != nil { return .content }
    if let failureMessage { return .failed(failureMessage) }
    return .loading
  }

  func load(model: AppModel, force: Bool = false) async {
    let key = FeatureCacheKey.cloudflareStatus
    if !force, let cached: CloudflareStatusSnapshot = model.featureCache.get(key) {
      snapshot = cached
      failureMessage = nil
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      let summary = try await model.featureCache.coalescedLoad(key) {
        try await CloudflareStatusClient.summary()
      }
      guard !Task.isCancelled else { return }
      let fresh = CloudflareStatusSnapshot(summary: summary, fetchedAt: .now)
      model.featureCache.set(key, fresh, ttl: Self.ttl)
      snapshot = fresh
      failureMessage = nil
    } catch {
      guard !Task.isCancelled, !error.dashIsCancellation else { return }
      failureMessage = error.dashActionableMessage
    }
  }
}

/// The page indicator as a row title. The paired `StatusBadge` carries the
/// tone — this wording must never be colored on its own.
private func overallStatusTitle(_ indicator: CloudflareStatusSummary.Indicator) -> String {
  switch indicator {
  case .none: DashL10n.string("All systems operational")
  case .minor: DashL10n.string("Minor service outage")
  case .major: DashL10n.string("Major service outage")
  case .critical: DashL10n.string("Critical service outage")
  case .unknown: DashL10n.string("Status unknown")
  }
}

// MARK: - Watchtower panel

/// Fixed tail block of the Watchtower tab. Not a metric card on purpose: it
/// renders Cloudflare's own published verdict (cloudflarestatus.com), so it
/// lives outside the reorderable chart layout and the editor never sees it —
/// and it computes nothing, which is what keeps it on the right side of the
/// no-Diagnostics rule.
struct CloudflareStatusSection: View {
  let state: CloudflareStatusState
  let retry: () -> Void

  var body: some View {
    DashInfoGroup(
      title: "Cloudflare status",
      phase: state.sectionPhase,
      placeholderRows: 1,
      retry: retry
    ) {
      if let summary = state.snapshot?.summary {
        DashListGroupLink(value: .cloudflareStatus) {
          DashListRow(
            title: overallStatusTitle(summary.indicator),
            showsIconPlate: false
          ) {
            StatusBadge(StatusToken(statusIndicator: summary.indicator))
          }
        }
        .accessibilityIdentifier("watchtower-cloudflare-status")

        // `summary.json` carries unresolved incidents only, so this list is
        // short-lived by construction; the detail screen shows the rest.
        ForEach(summary.incidents.prefix(3)) { incident in
          DashListGroupLink(value: .cloudflareStatus) {
            DashListRow(
              title: incident.name,
              showsChevron: false,
              showsIconPlate: false
            ) {
              StatusBadge(StatusToken(statusIncident: incident.status))
            }
          }
        }
      }
    }
  }
}

// MARK: - Detail screen

struct CloudflareStatusView: View {
  private static let statusPageURL = URL(string: "https://www.cloudflarestatus.com")!

  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var state = CloudflareStatusState()

  var body: some View {
    DashFeatureList(
      isLoading: state.isLoading,
      error: state.failureMessage,
      hasContent: state.snapshot != nil,
      retry: { Task { await state.load(model: model, force: true) } },
      header: {},
      content: { mode in
        if mode.isPlaceholder {
          placeholderSections
        } else if let snapshot = state.snapshot {
          liveSections(snapshot)
        }
      }
    )
    .detailHeader(icon: .solar(SolarAsset.heartPulse), title: "Cloudflare status")
    .task { await state.load(model: model) }
    .refreshable { await state.load(model: model, force: true) }
  }

  @ViewBuilder
  private func liveSections(_ snapshot: CloudflareStatusSnapshot) -> some View {
    let summary = snapshot.summary

    DashInfoGroup(title: "Status") {
      DashInfoRow("Overall") {
        StatusBadge(StatusToken(statusIndicator: summary.indicator))
      }
      if let freshness = WatchtowerAnalyticsChartModel.updatedBadge(
        fetchedAt: snapshot.fetchedAt)
      {
        DashInfoRow("Updated", value: freshness)
      }
    }
    .dashBodySlot(reduceMotion: reduceMotion)

    // Unresolved incidents only — bounded by construction, so the group's
    // eager stack is safe.
    if !summary.incidents.isEmpty {
      DashInfoGroup(title: "Active incidents") {
        ForEach(summary.incidents) { incident in
          CloudflareIncidentRow(incident: incident)
        }
      }
      .dashSectionBoundary()
    }

    // 125 rows of green is furniture: show what's wrong, or one quiet line
    // saying nothing is. An empty component list means the page's services
    // group moved (see `CloudflareStatusClient`) — drop the section rather
    // than invent one from colo noise; indicator and incidents remain.
    if !summary.serviceComponents.isEmpty {
      let degraded = summary.serviceComponents.filter { $0.status != .operational }
      DashInfoGroup(title: "Services") {
        if degraded.isEmpty {
          DashInfoRow("All services operational") { EmptyView() }
        } else {
          ForEach(degraded) { component in
            DashListRow(
              title: component.name,
              showsChevron: false,
              showsIconPlate: false
            ) {
              StatusBadge(StatusToken(statusComponent: component.status))
            }
          }
        }
      }
      .dashSectionBoundary()
    }

    // In-progress windows only; the row already says what is happening, so a
    // per-row badge would be furniture. Names are colo-scoped Cloudflare copy.
    if !summary.activeMaintenances.isEmpty {
      DashInfoGroup(title: "Maintenance in progress") {
        ForEach(summary.activeMaintenances) { maintenance in
          DashListRow(
            title: maintenance.name,
            showsChevron: false,
            showsIconPlate: false
          )
        }
      }
      .dashSectionBoundary()
    }

    // The escape hatch that keeps this screen honest if the page ever
    // restructures: Cloudflare's own page, in the browser.
    Button {
      openURL(Self.statusPageURL)
    } label: {
      DashListRow(
        title: DashL10n.string("Full status page"),
        icon: SolarAsset.globe,
        showsChevron: false,
        showsIconPlate: false
      ) {
        SolarIcon(
          asset: SolarAsset.arrowRightUp,
          size: DashTheme.Chevron.row,
          color: DashTheme.placeholder)
      }
      .dashListCardInset()
    }
    .buttonStyle(DashSurfaceButtonStyle())
    .accessibilityHint(DashL10n.string("Opens cloudflarestatus.com"))
    .dashSectionBoundary()
  }

  @ViewBuilder
  private var placeholderSections: some View {
    DashInfoGroup(title: "Status", phase: .loading, placeholderRows: 2) {
      EmptyView()
    }
    .dashBodySlot(reduceMotion: reduceMotion)
    DashInfoGroup(title: "Services", phase: .loading, placeholderRows: 3) {
      EmptyView()
    }
    .dashSectionBoundary()
    .dashBodySlot(reduceMotion: reduceMotion)
  }
}

/// One unresolved incident: name and lifecycle badge over the latest update's
/// body. Everything except the badge is Cloudflare's own English prose and
/// stays verbatim — free text can be neither localized nor branched on.
private struct CloudflareIncidentRow: View {
  let incident: CloudflareStatusIncident

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 12) {
        Text(incident.name)
          .dashTextStyle(.bodySemibold)
          .foregroundStyle(DashTheme.text)
          .frame(maxWidth: .infinity, alignment: .leading)
        StatusBadge(StatusToken(statusIncident: incident.status))
      }
      if let update = incident.latestUpdate, !update.isEmpty {
        Text(update)
          .dashTextStyle(.footnote)
          .foregroundStyle(DashTheme.subtle)
          .lineLimit(4)
      }
      if let updatedAt = incident.updatedAt {
        Text(updatedAt.formatted(.relative(presentation: .named)))
          .dashTextStyle(.caption)
          .foregroundStyle(DashTheme.subtle)
      }
    }
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}
