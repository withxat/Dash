import SwiftUI

public struct ExpandedBlossomView: View {
    @Bindable var model: BlossomColorPickerModel
    let layout: PetalLayout

    @Environment(\.blossomStyle) private var style

    public init(model: BlossomColorPickerModel, layout: PetalLayout) {
        self.model = model
        self.layout = layout
    }

    public var body: some View {
        let ringRadius = layout.outerRadius + style.petalSize / 2 + BlossomConstants.outerRingInset
        let sliderRadius = ringRadius + style.sliderWidth / 2 + BlossomConstants.sliderPadding
        let totalSize = sliderRadius * 2 + style.sliderWidth + BlossomConstants.viewPadding

        ZStack {
            // Outer ring (always shows selected color, not hovered color)
            OuterRingView(
                color: model.selectedColor,
                radius: ringRadius,
                isExpanded: model.isExpanded,
            )

            // Blossom petals
            BlossomPetalsView(
                model: model,
                layout: layout,
                center: CGPoint(x: totalSize / 2, y: totalSize / 2),
            )
            .frame(width: totalSize, height: totalSize)

            // Center circle (fixed color from JSON, tap to select or close if already selected)
            // Appears first on expand, disappears last on collapse
            CenterCircleView(
                centerColor: layout.centerColor,
                isExpanded: model.isExpanded,
                expandDelay: 0,
                collapseDelay: Double(layout.totalPetalCount) * BlossomConstants.petalAnimationDelay,
            )

            // Arc slider on the right
            ArcSliderView(model: model, radius: sliderRadius)
        }
        .frame(width: totalSize, height: totalSize)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let center = CGPoint(x: totalSize / 2, y: totalSize / 2)
                    if let (index, ring) = layout.petalIndex(at: value.location, center: center, petalSize: style.petalSize) {
                        if model.hoveredPetalIndex != index || model.hoveredRing != ring {
                            model.hoveredPetalIndex = index
                            model.hoveredRing = ring
                        }
                    } else {
                        model.hoveredPetalIndex = nil
                        model.hoveredRing = nil
                    }
                }
                .onEnded { value in
                    let center = CGPoint(x: totalSize / 2, y: totalSize / 2)

                    // Check if tap is on center circle
                    let dx = value.location.x - center.x
                    let dy = value.location.y - center.y
                    let distance = sqrt(dx * dx + dy * dy)

                    print("[Gesture] onEnded: location=\(value.location), center=\(center), distance=\(distance)")

                    if distance <= style.centerCircleSize / 2 {
                        // Tap on center circle - check if it matches current selection
                        print("[Gesture] tap on center circle")
                        let tappedColor = layout.centerColor
                        if colorsMatch(tappedColor, model.selectedColor) {
                            print("[Gesture] center color matches selected - collapsing")
                            model.collapse()
                        } else {
                            print("[Gesture] selecting center color")
                            model.selectCenterColor(layout: layout)
                        }
                    } else if let (index, ring) = layout.petalIndex(at: value.location, center: center, petalSize: style.petalSize) {
                        // Tap on petal - check if it matches current selection
                        print("[Gesture] tap on petal: index=\(index), ring=\(ring)")
                        let tappedColor = layout.color(for: index, ring: ring)
                        if colorsMatch(tappedColor, model.selectedColor) {
                            print("[Gesture] petal color matches selected - collapsing")
                            model.collapse()
                        } else {
                            print("[Gesture] selecting petal color")
                            model.selectPetal(index: index, ring: ring, layout: layout)
                        }
                    } else {
                        print("[Gesture] tap outside petals and center")
                    }

                    model.hoveredPetalIndex = nil
                    model.hoveredRing = nil
                },
        )
        .onContinuousHover { phase in
            let center = CGPoint(x: totalSize / 2, y: totalSize / 2)
            switch phase {
            case let .active(location):
                if let (index, ring) = layout.petalIndex(at: location, center: center, petalSize: style.petalSize) {
                    model.hoveredPetalIndex = index
                    model.hoveredRing = ring
                } else {
                    model.hoveredPetalIndex = nil
                    model.hoveredRing = nil
                }
            case .ended:
                model.hoveredPetalIndex = nil
                model.hoveredRing = nil
            }
        }
    }

    /// Calculate the total size needed for the expanded view
    public static func totalSize(layout: PetalLayout, style: BlossomStyle = .default) -> CGFloat {
        let ringRadius = layout.outerRadius + style.petalSize / 2 + BlossomConstants.outerRingInset
        let sliderRadius = ringRadius + style.sliderWidth / 2 + BlossomConstants.sliderPadding
        return sliderRadius * 2 + style.sliderWidth + BlossomConstants.viewPadding
    }
}

#Preview {
    @Previewable @State var model = BlossomColorPickerModel(initialColor: .green)

    ExpandedBlossomView(
        model: model,
        layout: PetalLayout(),
    )
    .onAppear {
        model.expand()
    }
    .padding(40)
}
