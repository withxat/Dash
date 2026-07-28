#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
  import BlossomColorPickerCore
  import SwiftUI

  /// Manages the NSWindow lifecycle for the expanded color picker.
  /// Shows a borderless, floating window at the swatch's screen position.
  @MainActor
  final class PickerWindowPresenter {
    private var window: NSWindow?
    private var localEventMonitor: Any?
    private var appDeactivateObserver: NSObjectProtocol?
    private var model: BlossomColorPickerModel?

    func show(
      at screenPoint: CGPoint,
      model: BlossomColorPickerModel,
      layout: PetalLayout,
      style: BlossomStyle = .default,
    ) {
      // Dismiss any existing window first
      dismissImmediately()

      self.model = model

      // Calculate window size from expanded view
      let totalSize = ExpandedBlossomView.totalSize(layout: layout, style: style)

      // Create content view
      let contentView = ExpandedBlossomView(model: model, layout: layout)
        .blossomStyle(style)

      // Create borderless window
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: totalSize, height: totalSize),
        styleMask: .borderless,
        backing: .buffered,
        defer: false,
      )
      window.backgroundColor = .clear
      window.isOpaque = false
      window.level = .floating
      window.hasShadow = false
      window.isReleasedWhenClosed = false

      // Position window centered on swatch
      let origin = NSPoint(
        x: screenPoint.x - totalSize / 2,
        y: screenPoint.y - totalSize / 2,
      )
      window.setFrameOrigin(origin)

      // Host SwiftUI view
      let hostingView = NSHostingView(rootView: contentView)
      window.contentView = hostingView

      // Show window (don't try to make key for borderless)
      window.orderFront(nil)

      self.window = window

      // Set up click-outside-to-dismiss
      setupClickOutsideMonitor(totalSize: totalSize)

      // Set up app deactivate observer (close when switching to another app)
      setupAppDeactivateObserver()

      // Expand the model after the view is mounted (next run loop)
      Task { @MainActor in
        model.expand()
      }
    }

    func dismiss() {
      // Remove observers
      removeObservers()

      // Wait for collapse animation to complete before closing window
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(350))
        window?.close()
        window = nil
        model = nil
      }
    }

    private func dismissImmediately() {
      removeObservers()
      window?.close()
      window = nil
      model = nil
    }

    private func removeObservers() {
      if let monitor = localEventMonitor {
        NSEvent.removeMonitor(monitor)
        localEventMonitor = nil
      }
      if let observer = appDeactivateObserver {
        NotificationCenter.default.removeObserver(observer)
        appDeactivateObserver = nil
      }
    }

    private func setupClickOutsideMonitor(totalSize _: CGFloat) {
      localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
        .leftMouseDown, .rightMouseDown,
      ]) { [weak self] event in
        guard let self, let window else { return event }

        // Get click location in screen coordinates
        let clickLocation = NSEvent.mouseLocation

        // Get window frame
        let windowFrame = window.frame

        // Check if click is outside the window
        if !windowFrame.contains(clickLocation) {
          // Collapse the model (which will trigger dismiss via onChange)
          model?.collapse()
        }

        return event
      }
    }

    private func setupAppDeactivateObserver() {
      // Delay observer setup to avoid triggering immediately on window show
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(100))

        // Check if window still exists (might have been dismissed already)
        guard self.window != nil else { return }

        self.appDeactivateObserver = NotificationCenter.default.addObserver(
          forName: NSApplication.didResignActiveNotification,
          object: nil,
          queue: .main,
        ) { [weak self] _ in
          Task { @MainActor in
            self?.model?.collapse()
          }
        }
      }
    }
  }
#endif
