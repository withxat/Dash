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
            print("[Presenter] show() called, screenPoint: \(screenPoint)")
            print("[Presenter] model.isExpanded before: \(model.isExpanded)")

            // Dismiss any existing window first
            dismissImmediately()

            self.model = model

            // Calculate window size from expanded view
            let totalSize = ExpandedBlossomView.totalSize(layout: layout, style: style)
            print("[Presenter] totalSize: \(totalSize)")

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
            print("[Presenter] window origin: \(origin)")

            // Host SwiftUI view
            let hostingView = NSHostingView(rootView: contentView)
            window.contentView = hostingView

            // Show window (don't try to make key for borderless)
            window.orderFront(nil)
            print("[Presenter] window ordered front")

            self.window = window

            // Set up click-outside-to-dismiss
            setupClickOutsideMonitor(totalSize: totalSize)

            // Set up app deactivate observer (close when switching to another app)
            setupAppDeactivateObserver()

            // Expand the model after the view is mounted (next run loop)
            print("[Presenter] scheduling expand()")
            Task { @MainActor in
                print("[Presenter] calling model.expand()")
                model.expand()
                print("[Presenter] model.isExpanded after expand: \(model.isExpanded)")
            }
        }

        func dismiss() {
            print("[Presenter] dismiss() called")
            print("[Presenter] model.isExpanded: \(model?.isExpanded ?? false)")

            // Remove observers
            removeObservers()

            // Wait for collapse animation to complete before closing window
            print("[Presenter] waiting for animation...")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                print("[Presenter] closing window after delay")
                window?.close()
                window = nil
                model = nil
            }
        }

        private func dismissImmediately() {
            print("[Presenter] dismissImmediately() called")
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
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
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
                    print("[Presenter] App resigned active - closing picker")
                    Task { @MainActor in
                        self?.model?.collapse()
                    }
                }
            }
        }
    }
#endif
