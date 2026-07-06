import CloudflareAPI
import SwiftUI

struct WatchtowerView: View {
  @Environment(AppModel.self) private var model
  @State private var resources: [GenericResource] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    ScrollView {
      LazyVStack(spacing: DashTheme.Spacing.section) {
        if loading {
          LoadingStateView()
        } else if let error {
          ErrorStateView(message: error) { Task { await load() } }
        } else if resources.isEmpty {
          ContentUnavailableView(
            "All quiet", systemImage: "checkmark.shield",
            description: Text("No recent Cloudflare alerts."))
        } else {
          DashListGroup(title: "Recent alerts") {
            ForEach(Array(resources.enumerated()), id: \.element.id) { index, resource in
              HStack {
                Image(systemName: "bell.badge.fill")
                  .symbolRenderingMode(.hierarchical)
                  .foregroundStyle(DashTheme.accent)
                  .frame(width: 44, height: 44)
                  .background(DashTheme.accent.opacity(0.15))
                  .clipShape(
                    RoundedRectangle(cornerRadius: DashTheme.Radius.medium, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                  Text(resource.name).font(.system(size: 14)).foregroundStyle(DashTheme.text)
                  Text(resource.detail ?? "Notification")
                    .font(.system(size: 12))
                    .foregroundStyle(DashTheme.subtle)
                    .lineLimit(1)
                }
                Spacer()
              }
              .padding(.vertical, 10)
              if index < resources.count - 1 { Divider().overlay(DashTheme.hairline) }
            }
          }
        }
      }
      .padding(.horizontal, DashTheme.Spacing.screen)
      .padding(.top, DashTheme.Spacing.screen)
      .padding(.bottom, 80)
    }
    .background(DashTheme.canvas).navigationTitle("Watchtower").navigationBarTitleDisplayMode(
      .large
    )
    .toolbar { AccountToolbar() }.refreshable { await load() }.task { await load() }
    .destinationRouting()
  }

  private func load() async {
    guard let accountID = model.activeAccountID else { return }
    loading = true
    error = nil
    do {
      resources = try await model.client.listResources(
        path: "/accounts/\(accountID)/alerting/v3/history", query: ["per_page": "20"]
      ).items
    } catch { self.error = error.localizedDescription }
    loading = false
  }
}
