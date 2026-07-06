import SwiftUI

@main
struct DashApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      AppRootView()
        .environment(model)
        .tint(DashTheme.brand)
        .task { await model.bootstrap() }
    }
  }
}
