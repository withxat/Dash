#if canImport(UIKit)
    import BlossomColorPickerCore
    import SwiftUI
    import UIKit

    /// Manages the UIView lifecycle for the expanded color picker on iOS.
    /// Shows an overlay view attached to the UIWindow with high zPosition.
    @MainActor
    final class PickerViewPresenter {
        private var overlayView: UIView?
        private var hostingController: UIHostingController<AnyView>?
        private var model: BlossomColorPickerModel?
        private var backgroundObserver: NSObjectProtocol?

        func show(
            at screenPoint: CGPoint,
            model: BlossomColorPickerModel,
            layout: PetalLayout,
            style: BlossomStyle = .default,
        ) {
            print("[Presenter] show() called, screenPoint: \(screenPoint)")
            print("[Presenter] model.isExpanded before: \(model.isExpanded)")

            // Dismiss any existing view first
            dismissImmediately()

            self.model = model

            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first(where: { $0.isKeyWindow })
            else {
                print("[Presenter] No key window found")
                return
            }

            let totalSize = ExpandedBlossomView.totalSize(layout: layout, style: style)
            print("[Presenter] totalSize: \(totalSize)")

            // Create overlay view (full screen, transparent, captures taps outside)
            let overlay = PickerOverlayView(frame: window.bounds)
            overlay.backgroundColor = .clear
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.onTapOutside = { [weak self] in
                print("[Presenter] Tap outside - collapsing")
                self?.model?.collapse()
            }

            // Create hosting controller for SwiftUI content
            let contentView = ExpandedBlossomView(model: model, layout: layout)
                .blossomStyle(style)
            let hostingController = UIHostingController(rootView: AnyView(contentView))
            hostingController.view.backgroundColor = .clear

            // Position centered on the screen point
            let pickerFrame = CGRect(
                x: screenPoint.x - totalSize / 2,
                y: screenPoint.y - totalSize / 2,
                width: totalSize,
                height: totalSize,
            )
            hostingController.view.frame = pickerFrame
            print("[Presenter] picker frame: \(pickerFrame)")

            // Add to overlay
            overlay.addSubview(hostingController.view)
            overlay.pickerFrame = pickerFrame

            // Add overlay to window with high zPosition
            overlay.layer.zPosition = CGFloat.greatestFiniteMagnitude
            window.addSubview(overlay)

            overlayView = overlay
            self.hostingController = hostingController

            // Set up app background observer (close when app goes to background)
            setupBackgroundObserver()

            // Expand after view is mounted
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

            // Remove observer
            removeObservers()

            // Wait for collapse animation to complete before removing view
            print("[Presenter] waiting for animation...")
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                print("[Presenter] removing overlay after delay")
                overlayView?.removeFromSuperview()
                overlayView = nil
                hostingController = nil
                model = nil
            }
        }

        private func dismissImmediately() {
            print("[Presenter] dismissImmediately() called")
            removeObservers()
            overlayView?.removeFromSuperview()
            overlayView = nil
            hostingController = nil
            model = nil
        }

        private func removeObservers() {
            if let observer = backgroundObserver {
                NotificationCenter.default.removeObserver(observer)
                backgroundObserver = nil
            }
        }

        private func setupBackgroundObserver() {
            // Delay observer setup to avoid triggering immediately
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))

                // Check if overlay still exists (might have been dismissed already)
                guard self.overlayView != nil else { return }

                self.backgroundObserver = NotificationCenter.default.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil,
                    queue: .main,
                ) { [weak self] _ in
                    print("[Presenter] App entered background - closing picker")
                    Task { @MainActor in
                        self?.model?.collapse()
                    }
                }
            }
        }
    }

    /// Overlay view that captures taps outside the picker
    private class PickerOverlayView: UIView {
        var pickerFrame: CGRect = .zero
        var onTapOutside: (() -> Void)?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // If tap is inside picker, pass through to picker
            if pickerFrame.contains(point) {
                return super.hitTest(point, with: event)
            }
            // Tap outside - trigger dismiss and don't consume the tap
            onTapOutside?()
            return nil
        }
    }
#endif
