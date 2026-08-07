import Foundation
import SwiftUI
import WidgetKit

struct QuickActionsEntry: TimelineEntry {
  let date: Date
  let actions: [HomeActionID]
  let accountID: String?
}

struct QuickActionsProvider: TimelineProvider {
  func placeholder(in context: Context) -> QuickActionsEntry {
    QuickActionsEntry(date: Date(), actions: HomeActions.defaults, accountID: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (QuickActionsEntry) -> Void) {
    completion(loadEntry())
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<QuickActionsEntry>) -> Void
  ) {
    let entry = loadEntry()
    completion(Timeline(entries: [entry], policy: .after(Date(timeIntervalSinceNow: 60 * 60))))
  }

  private func loadEntry() -> QuickActionsEntry {
    QuickActionsEntry(
      date: Date(),
      actions: HomeActions.mirroredActions(),
      accountID: DashWidgetBridges.mirroredActiveAccountID)
  }
}

struct QuickActionsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: QuickActionsWidgetKind.id, provider: QuickActionsProvider()) {
      entry in
      QuickActionsWidgetView(entry: entry)
        .containerBackground(.background, for: .widget)
    }
    .configurationDisplayName("Quick Actions")
    .description("The three Home quick actions, ready from the Home Screen.")
    .supportedFamilies([.systemMedium])
    .contentMarginsDisabled()
  }
}

private struct QuickActionsWidgetView: View {
  let entry: QuickActionsEntry

  var body: some View {
    Group {
      if entry.actions.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "slider.horizontal.3")
            .font(.title2.weight(.semibold))
          Text(
            "Choose Home actions in Dash.",
            comment: "Empty Quick Actions widget prompt."
          )
          .font(.caption.weight(.semibold))
          .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HStack(alignment: .top, spacing: 8) {
          ForEach(entry.actions) { action in
            Link(destination: link(for: action)) {
              VStack(spacing: 10) {
                Image(systemName: action.widgetSystemImage)
                  .font(.system(size: 22, weight: .semibold))
                  .foregroundStyle(.primary)
                  .frame(width: 44, height: 44)
                  .background(
                    .quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(action.widgetTitle)
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.primary)
                  .multilineTextAlignment(.center)
                  .lineLimit(2)
                  .minimumScaleFactor(0.8)
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .accessibilityLabel(action.widgetTitle)
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private func link(for action: HomeActionID) -> URL {
    HomeActions.deepLink(action: action, accountID: entry.accountID)
      ?? URL(string: "dash://action/\(action.rawValue)")!
  }
}

extension HomeActionID {
  fileprivate var widgetTitle: String {
    switch self {
    case .addDomain: String(localized: "Add domain")
    case .uploadR2: String(localized: "Upload R2")
    case .addDNSRecord: String(localized: "Add DNS")
    case .createKVKey: String(localized: "Create key")
    case .createR2Bucket: String(localized: "New bucket")
    case .addPagesDomain: String(localized: "Pages domain")
    case .addWorkerDomain: String(localized: "Worker domain")
    case .enableDevelopmentMode: String(localized: "Dev mode")
    case .enableUnderAttackMode: String(localized: "Under Attack")
    }
  }

  /// SF Symbols — Solar assets are not in the widget target's catalog.
  fileprivate var widgetSystemImage: String {
    switch self {
    case .addDomain: "plus.circle.fill"
    case .uploadR2: "square.and.arrow.up.fill"
    case .addDNSRecord: "globe"
    case .createKVKey: "key.fill"
    case .createR2Bucket: "shippingbox.fill"
    case .addPagesDomain: "chevron.left.forwardslash.chevron.right"
    case .addWorkerDomain: "curlybraces"
    case .enableDevelopmentMode: "slider.horizontal.3"
    case .enableUnderAttackMode: "shield.fill"
    }
  }
}
