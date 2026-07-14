import SwiftUI
import WidgetKit

@main
struct DashWidgetsBundle: WidgetBundle {
  var body: some Widget { WatchtowerWidget() }
}

/// Status colors mirror DashTheme's ok/warning/critical tokens; DashTheme
/// itself isn't compiled into the widget, so the three values are duplicated
/// here. Keep in sync with DashTheme.success/.warning/.danger.
private enum WidgetColor {
  static let ok = Color(light: 0x10B981, dark: 0x34D399)
  static let warning = Color(light: 0xEAB308, dark: 0xFACC15)
  static let critical = Color(light: 0xEF4444, dark: 0xDC2626)

  static func status(_ raw: String) -> Color {
    switch raw {
    case "critical": critical
    case "warning": warning
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
          }
        }
      }
      Spacer(minLength: 0)
      if snapshot.staleness(now: entry.date) == .aging {
        Text("Updated \(snapshot.fetchedAt, style: .relative) ago")
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
    guard snapshot.issueCount > 0 else { return "All clear" }
    return "\(snapshot.issueCount) \(snapshot.issueCount == 1 ? "issue" : "issues")"
  }

  private func statusColor(_ snapshot: WatchtowerWidgetSnapshot) -> Color {
    if snapshot.criticalCount > 0 { return WidgetColor.critical }
    if snapshot.warningCount > 0 { return WidgetColor.warning }
    return WidgetColor.ok
  }
}
