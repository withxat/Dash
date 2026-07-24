import SwiftUI

/// Controls when a chart creates its raster frame.
public enum DitherRenderingMode: Hashable, Sendable {
  /// Render behind an actor and reuse frames from the bounded shared cache.
  /// This is the default for interactive interfaces.
  case asynchronous

  /// Render during view evaluation for offscreen snapshot tools that do not run
  /// SwiftUI tasks. Avoid this mode in scrolling or interactive interfaces.
  case immediate
}

private struct DitherRenderingModeKey: EnvironmentKey {
  static let defaultValue = DitherRenderingMode.asynchronous
}

extension EnvironmentValues {
  var ditherRenderingMode: DitherRenderingMode {
    get { self[DitherRenderingModeKey.self] }
    set { self[DitherRenderingModeKey.self] = newValue }
  }
}

extension View {
  /// Selects raster scheduling for every SwiftDitherKit chart in this subtree.
  ///
  /// Use ``DitherRenderingMode/immediate`` with `ImageRenderer` and other
  /// offscreen snapshot tools. Interactive interfaces should retain the default
  /// ``DitherRenderingMode/asynchronous`` mode.
  public func ditherRenderingMode(_ mode: DitherRenderingMode) -> some View {
    environment(\.ditherRenderingMode, mode)
  }
}
