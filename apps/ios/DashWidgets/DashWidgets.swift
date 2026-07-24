import ActivityKit
import SwiftUI
import WidgetKit

@main
struct DashWidgetsBundle: WidgetBundle {
  var body: some Widget {
    WatchtowerWidget()
    PagesBuildLiveActivity()
  }
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
  let stage = state.stage.capitalized
  let status = state.status.capitalized
  return "\(stage) · \(status)"
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

  static func status(_ raw: String) -> Color {
    switch raw {
    case "critical": critical
    case "warning": warning
    default: ok
    }
  }

  /// Pages deployment stages — keep in sync with `pagesStatusColor` in PagesViews.
  static func pagesStatus(_ raw: String) -> Color {
    switch raw.lowercased() {
    case "success": ok
    case "failure", "canceled", "cancelled": critical
    case "active", "idle": warning
    default: ok
    }
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
        issueCount: 1, criticalCount: 0, warningCount: 1,
        signals: [.init(title: "Certificate expiring", detail: "example.com", status: "warning")],
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
        .widgetURL(URL(string: "dash://watchtower"))
    }
    .configurationDisplayName("Watchtower")
    .description("Account health at a glance — issues, cert and domain expiry.")
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
        Text(headline(snapshot))
          .font(.headline)
          .minimumScaleFactor(0.8)
        Spacer(minLength: 0)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(snapshot.severityHeadline)
      if let account = snapshot.accountName {
        Text(account)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if family == .systemMedium {
        Divider()
        if snapshot.signals.isEmpty {
          Text("Everything looks healthy.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(Array(snapshot.signals.prefix(4).enumerated()), id: \.offset) { _, signal in
            HStack(spacing: 6) {
              Circle().fill(WidgetColor.status(signal.status)).frame(width: 6, height: 6)
              Text(signal.title).font(.caption).lineLimit(1)
              Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(signal.status), \(signal.title)")
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
      Text("Open Dash to sync your account health.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
  }

  private func headline(_ snapshot: WatchtowerWidgetSnapshot) -> String {
    snapshot.severityHeadline
  }

  private func statusColor(_ snapshot: WatchtowerWidgetSnapshot) -> Color {
    if snapshot.criticalCount > 0 { return WidgetColor.critical }
    if snapshot.warningCount > 0 { return WidgetColor.warning }
    return WidgetColor.ok
  }
}
