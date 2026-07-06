import CloudflareAPI
import SwiftUI

struct WatchtowerView: View {
  @Environment(AppModel.self) private var model
  @State private var resources: [GenericResource] = []
  @State private var error: String?
  @State private var loading = true

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 16) {
        if loading {
          LoadingStateView()
        } else if let error {
          ErrorStateView(message: error) { Task { await load() } }
        } else if resources.isEmpty {
          ContentUnavailableView(
            "All quiet", systemImage: "checkmark.shield",
            description: Text("No recent Cloudflare alerts."))
        } else {
          ForEach(resources) { resource in
            DashCard {
              HStack {
                Image(systemName: "bell.badge").foregroundStyle(DashTheme.accent)
                VStack(alignment: .leading) {
                  Text(resource.name)
                  Text(resource.detail ?? "Notification").font(.caption).foregroundStyle(
                    DashTheme.subtle)
                }
                Spacer()
              }.padding(.vertical, 12)
            }
          }
        }
      }.padding(16).padding(.bottom, 80)
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
