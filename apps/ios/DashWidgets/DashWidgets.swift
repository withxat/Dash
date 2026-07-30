import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DashWidgetsBundle: WidgetBundle {
  var body: some Widget {
    WatchtowerWidget()
    AccountMetricsWidget()
    DomainMetricsWidget()
    QuickActionsWidget()
    PagesBuildLiveActivity()
    WorkerBuildLiveActivity()
  }
}

struct WorkerBuildLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: WorkerBuildAttributes.self) { context in
      WorkerBuildLockScreenView(context: context)
        .widgetURL(workerBuildDeepLink(context))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 6) {
            Circle()
              .fill(WidgetColor.workerBuild(context.state))
              .frame(width: 8, height: 8)
            Text(context.attributes.scriptName)
              .font(.caption.weight(.semibold))
              .lineLimit(1)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.shortCommit ?? "")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(workerBuildStatusLine(context.state))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      } compactLeading: {
        Image(systemName: WorkerBuildGlyph.symbol)
          .foregroundStyle(WidgetColor.workerBuild(context.state))
      } compactTrailing: {
        Text(context.state.branch ?? context.state.shortCommit ?? "")
          .font(.caption2.monospaced().weight(.semibold))
          .foregroundStyle(WidgetColor.workerBuild(context.state))
          .lineLimit(1)
      } minimal: {
        Image(systemName: WorkerBuildGlyph.symbol)
          .foregroundStyle(WidgetColor.workerBuild(context.state))
      }
      .widgetURL(workerBuildDeepLink(context))
    }
  }
}

private enum WorkerBuildGlyph {
  static let symbol = "hammer.fill"
}

private struct WorkerBuildLockScreenView: View {
  let context: ActivityViewContext<WorkerBuildAttributes>

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: WorkerBuildGlyph.symbol)
        .font(.title3.weight(.semibold))
        .foregroundStyle(WidgetColor.workerBuild(context.state))
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Circle()
            .fill(WidgetColor.workerBuild(context.state))
            .frame(width: 8, height: 8)
          Text(context.attributes.scriptName)
            .font(.headline)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        Text(workerBuildStatusLine(context.state))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let commit = context.state.shortCommit {
          Text(commit)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    .padding()
  }
}

/// The app already localized `phase`; this only joins it to the branch. Nothing
/// here re-derives copy from a raw Cloudflare status — the widget bundle would
/// resolve it against a catalog it cannot map.
private func workerBuildStatusLine(_ state: WorkerBuildAttributes.ContentState) -> String {
  guard let branch = state.branch, !branch.isEmpty else { return state.phase }
  return "\(state.phase) · \(branch)"
}

private func workerBuildDeepLink(_ context: ActivityViewContext<WorkerBuildAttributes>) -> URL? {
  guard let accountID = context.attributes.accountID, !accountID.isEmpty else { return nil }
  var components = URLComponents()
  components.scheme = "dash"
  components.host = "worker"
  components.path = "/\(context.attributes.scriptName)"
  components.queryItems = [URLQueryItem(name: "account", value: accountID)]
  return components.url
}

struct PagesBuildLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: PagesBuildAttributes.self) { context in
      PagesBuildLockScreenView(context: context)
        .widgetURL(pagesBuildDeepLink(context))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 6) {
            Circle()
              .fill(WidgetColor.pagesStatus(context.state.status))
              .frame(width: 8, height: 8)
            Text(context.attributes.projectName)
              .font(.caption.weight(.semibold))
              .lineLimit(1)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.shortID)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(pagesBuildStatusLine(context.state))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      } compactLeading: {
        Image(systemName: PagesBuildGlyph.symbol)
          .foregroundStyle(WidgetColor.pagesStatus(context.state.status))
      } compactTrailing: {
        Text(context.state.shortID.prefix(4))
          .font(.caption2.monospaced().weight(.semibold))
          .foregroundStyle(WidgetColor.pagesStatus(context.state.status))
      } minimal: {
        Image(systemName: PagesBuildGlyph.symbol)
          .foregroundStyle(WidgetColor.pagesStatus(context.state.status))
      }
      .widgetURL(pagesBuildDeepLink(context))
    }
  }
}

private enum PagesBuildGlyph {
  /// Solar `SolarCodeCircleFill` isn't in the widget target; this SF Symbol
  /// reads closer to a Pages deployment than the catalog's generic `doc.text`.
  static let symbol = "arrow.triangle.branch"
}

private struct PagesBuildLockScreenView: View {
  let context: ActivityViewContext<PagesBuildAttributes>

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: PagesBuildGlyph.symbol)
        .font(.title3.weight(.semibold))
        .foregroundStyle(WidgetColor.pagesStatus(context.state.status))
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Circle()
            .fill(WidgetColor.pagesStatus(context.state.status))
            .frame(width: 8, height: 8)
          Text(context.attributes.projectName)
            .font(.headline)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        Text(pagesBuildStatusLine(context.state))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(context.state.shortID)
          .font(.caption2.monospaced())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    .padding()
  }
}

private func pagesBuildStatusLine(_ state: PagesBuildAttributes.ContentState) -> String {
  // Cloudflare's stage ids are snake_case ("clone_repo"), and `.capitalized`
  // alone shipped them that way — "Clone_Repo · Active".
  let stage = state.stage.replacingOccurrences(of: "_", with: " ").capitalized
  let status = state.status.capitalized
  return "\(String(localized: .init(stage))) · \(String(localized: .init(status)))"
}

private func pagesBuildDeepLink(_ context: ActivityViewContext<PagesBuildAttributes>) -> URL? {
  // Older activities have no account binding. Leaving them untappable is
  // safer than resolving a same-named project under the current account.
  guard let accountID = context.attributes.accountID, !accountID.isEmpty else { return nil }
  var components = URLComponents()
  components.scheme = "dash"
  components.host = "pages"
  components.path =
    "/\(context.attributes.projectName)/deployments/\(context.attributes.deploymentID)"
  components.queryItems = [URLQueryItem(name: "account", value: accountID)]
  return components.url
}

/// Status colors mirror DashTheme's ok/warning/critical tokens; DashTheme
/// itself isn't compiled into the widget, so the three values are duplicated
/// here. Keep in sync with DashTheme.success/.warning/.danger.
private enum WidgetColor {
  static let ok = Color(light: 0x10B981, dark: 0x34D399)
  static let warning = Color(light: 0xEAB308, dark: 0xFACC15)
  static let critical = Color(light: 0xEF4444, dark: 0xF87171)

  /// Pages deployment stages — keep in sync with `pagesStatusColor` in PagesViews.
  static func pagesStatus(_ raw: String) -> Color {
    switch raw.lowercased() {
    case "success": ok
    case "failure", "canceled", "cancelled": critical
    case "active", "idle": warning
    default: ok
    }
  }

  /// Colour comes from the phase token the app computed, plus the outcome once
  /// there is one. A finished build with no outcome is not painted green —
  /// Cloudflare simply did not say how it ended.
  static func workerBuild(_ state: WorkerBuildAttributes.ContentState) -> Color {
    if state.phaseToken == "finished" {
      switch state.outcome?.lowercased() {
      case "success": return ok
      case .some: return critical
      case nil: return warning
      }
    }
    return warning
  }
}

extension Color {
  fileprivate init(light: UInt32, dark: UInt32) {
    self.init(
      uiColor: UIColor { traits in
        let hex = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(
          red: CGFloat((hex >> 16) & 0xFF) / 255,
          green: CGFloat((hex >> 8) & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255,
          alpha: 1)
      })
  }
}

struct WatchtowerEntry: TimelineEntry {
  let date: Date
  let snapshot: WatchtowerWidgetSnapshot?
}

struct WatchtowerProvider: TimelineProvider {
  func placeholder(in context: Context) -> WatchtowerEntry {
    WatchtowerEntry(
      date: Date(),
      snapshot: WatchtowerWidgetSnapshot(
        unreadCount: 1,
        alerts: [.init(id: "cf:preview", title: "Certificate expiring", detail: "example.com")],
        accountName: "Your account", fetchedAt: Date()))
  }

  func getSnapshot(in context: Context, completion: @escaping (WatchtowerEntry) -> Void) {
    completion(WatchtowerEntry(date: Date(), snapshot: loadSnapshot()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<WatchtowerEntry>) -> Void) {
    let entry = WatchtowerEntry(date: Date(), snapshot: loadSnapshot())
    completion(Timeline(entries: [entry], policy: .after(Date(timeIntervalSinceNow: 30 * 60))))
  }

  private func loadSnapshot() -> WatchtowerWidgetSnapshot? {
    guard let url = WatchtowerWidgetSnapshot.containerFileURL else { return nil }
    return try? WatchtowerWidgetSnapshot.load(from: url)
  }
}

struct WatchtowerWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "WatchtowerWidget", provider: WatchtowerProvider()) { entry in
      WatchtowerWidgetView(entry: entry)
        .containerBackground(.background, for: .widget)
        .widgetURL(entry.snapshot?.deepLinkURL)
    }
    .configurationDisplayName("Watchtower")
    .description(
      Text(
        "Unread Cloudflare alerts for your account.",
        comment: "Description of the Watchtower widget.")
    )
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

struct WatchtowerWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: WatchtowerEntry

  var body: some View {
    if let snapshot = entry.snapshot {
      switch snapshot.staleness(now: entry.date) {
      case .stale:
        staleView(snapshot)
      default:
        content(snapshot)
      }
    } else {
      emptyView
    }
  }

  private func content(_ snapshot: WatchtowerWidgetSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Circle().fill(statusColor(snapshot)).frame(width: 10, height: 10)
        Text(snapshot.headline)
          .font(.headline)
          .minimumScaleFactor(0.8)
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(Text(snapshot.headline))
      if let account = snapshot.accountName {
        Text(account)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if family == .systemMedium {
        Divider()
        if snapshot.alerts.isEmpty {
          Text(
            snapshot.alertsUnavailable
              ? String(
                localized: "Open Dash to reconnect notification access.",
                comment: "Watchtower widget message when notification access has expired.")
              : String(
                localized: "Cloudflare hasn't sent anything new.",
                comment: "Watchtower widget message when its alert history is empty.")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          ForEach(Array(snapshot.alerts.prefix(4).enumerated()), id: \.offset) { _, alert in
            HStack(spacing: 6) {
              Circle().fill(WidgetColor.warning).frame(width: 6, height: 6)
              Text(alert.title).font(.caption).lineLimit(1)
              Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(alert.title)
          }
        }
      }
      Spacer(minLength: 0)
      if snapshot.staleness(now: entry.date) == .aging {
        Text(WatchtowerFreshness.checkedText(fetchedAt: snapshot.fetchedAt, now: entry.date))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
  }

  private func staleView(_ snapshot: WatchtowerWidgetSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Watchtower").font(.headline)
      Text("Stale — open Dash to refresh.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
  }

  private var emptyView: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Watchtower").font(.headline)
      Text("Open Dash to sync your Cloudflare alerts.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
  }

  private func statusColor(_ snapshot: WatchtowerWidgetSnapshot) -> Color {
    if snapshot.alertsUnavailable { return WidgetColor.warning }
    return snapshot.unreadCount > 0 ? WidgetColor.warning : WidgetColor.ok
  }
}
