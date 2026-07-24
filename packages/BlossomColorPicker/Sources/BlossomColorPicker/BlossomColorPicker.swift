import BlossomColorPickerCore
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
#endif

// Type alias for platform-specific presenter
#if canImport(UIKit)
    typealias PickerPresenter = PickerViewPresenter
#elseif canImport(AppKit)
    typealias PickerPresenter = PickerWindowPresenter
#endif

public struct BlossomColorPicker: View {
    @Binding private var selection: Color
    @State private var model: BlossomColorPickerModel
    @State private var presenter = PickerPresenter()
    @State private var isCooldown = false

    private let layout: PetalLayout
    private let onColorChange: ((Color) -> Void)?
    private let onDismiss: ((Color) -> Void)?

    public init(
        selection: Binding<Color>,
        layout: PetalLayout = PetalLayout(),
        onColorChange: ((Color) -> Void)? = nil,
        onDismiss: ((Color) -> Void)? = nil,
    ) {
        _selection = selection
        _model = State(wrappedValue: BlossomColorPickerModel(initialColor: selection.wrappedValue))
        self.layout = layout
        self.onColorChange = onColorChange
        self.onDismiss = onDismiss
    }

    public init(
        initialColor: Color = .blue,
        layout: PetalLayout = PetalLayout(),
        onColorChange: ((Color) -> Void)? = nil,
        onDismiss: ((Color) -> Void)? = nil,
    ) {
        _selection = .constant(initialColor)
        _model = State(wrappedValue: BlossomColorPickerModel(initialColor: initialColor))
        self.layout = layout
        self.onColorChange = onColorChange
        self.onDismiss = onDismiss
    }

    public var body: some View {
        // Collapsed swatch only - respects frame modifier
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)

            Circle()
                .fill(model.selectedColor)
                .overlay(
                    Circle()
                        .stroke(
                            .white.opacity(BlossomConstants.collapsedSwatchBorderOpacity),
                            lineWidth: BlossomConstants.borderWidth,
                        ),
                )
                .frame(width: size, height: size)
                .contentShape(Circle())
                .onTapGesture {
                    // Prevent rapid re-opening
                    guard !isCooldown else {
                        print("[BlossomColorPicker] tap ignored - cooldown active")
                        return
                    }

                    print("[BlossomColorPicker] tap gesture, model.isExpanded: \(model.isExpanded)")

                    // Start cooldown
                    isCooldown = true
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        isCooldown = false
                    }

                    // Get screen position of swatch center
                    let frame = geometry.frame(in: .global)
                    let screenPoint = convertToScreenCoordinates(frame: frame)
                    print("[BlossomColorPicker] calling presenter.show()")
                    presenter.show(at: screenPoint, model: model, layout: layout)
                }
                .accessibilityLabel("Color picker")
                .accessibilityHint("Tap to expand color picker")
                .accessibilityAddTraits(.isButton)
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: model.selectedColor) { _, newValue in
            selection = newValue
            onColorChange?(newValue)
        }
        .onChange(of: model.isExpanded) { wasExpanded, isExpanded in
            print("[BlossomColorPicker] onChange isExpanded: \(wasExpanded) -> \(isExpanded)")
            if wasExpanded, !isExpanded {
                print("[BlossomColorPicker] calling presenter.dismiss()")
                presenter.dismiss()
                onDismiss?(model.selectedColor)
            }
        }
    }

    /// Convert SwiftUI global coordinates to screen coordinates
    private func convertToScreenCoordinates(frame: CGRect) -> CGPoint {
        #if canImport(UIKit)
            // UIKit: SwiftUI .global coordinates are in screen coordinates (top-left origin)
            return CGPoint(x: frame.midX, y: frame.midY)
        #else
            // AppKit: SwiftUI .global coordinates are relative to the window
            // We need to convert to NSScreen coordinates (bottom-up)
            guard let window = NSApp.keyWindow else {
                return CGPoint(x: frame.midX, y: frame.midY)
            }

            let windowFrame = window.frame

            // SwiftUI Y is top-down within the window
            // NSScreen Y is bottom-up from screen origin
            // Window's frame.origin is already in screen coordinates (bottom-left of window)
            let centerX = windowFrame.origin.x + frame.midX
            let centerY = windowFrame.origin.y + windowFrame.height - frame.midY

            return CGPoint(x: centerX, y: centerY)
        #endif
    }
}

#Preview("Binding-based") {
    @Previewable @State var color = Color.blue

    VStack(spacing: 40) {
        BlossomColorPicker(selection: $color)
            .frame(width: 32, height: 32)

        Rectangle()
            .fill(color)
            .frame(width: 100, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    .padding(60)
}

#Preview("Callback-based") {
    BlossomColorPicker(
        initialColor: .orange,
        onColorChange: { color in
            print("Color changed: \(color)")
        },
        onDismiss: { finalColor in
            print("Dismissed with: \(finalColor)")
        },
    )
    .frame(width: 32, height: 32)
    .padding(60)
}
