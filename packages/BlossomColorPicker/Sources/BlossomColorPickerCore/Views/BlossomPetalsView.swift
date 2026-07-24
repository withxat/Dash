import SwiftUI

struct BlossomPetalsView: View {
    @Bindable var model: BlossomColorPickerModel
    let layout: PetalLayout
    let center: CGPoint

    @Environment(\.blossomStyle) private var style

    /// Mask size large enough to accommodate hover scale
    private var maskSize: CGFloat {
        style.petalSize * BlossomConstants.petalHoverScale * 1.2
    }

    /// Calculate offset from center for a petal position
    private func petalOffset(for index: Int, ring: PetalLayout.Ring) -> CGSize {
        let position = layout.position(for: index, ring: ring, in: center)
        return CGSize(
            width: position.x - center.x,
            height: position.y - center.y,
        )
    }

    var body: some View {
        ZStack {
            // Outer ring petals (12) - rendered first (behind), animates after inner
            ForEach(0 ..< layout.outerPetalCount, id: \.self) { index in
                let offset = petalOffset(for: index, ring: .outer)
                let color = layout.color(for: index, ring: .outer)
                let expandDelay = Double(index + layout.innerPetalCount) * BlossomConstants.petalAnimationDelay
                let collapseDelay = Double(index) * BlossomConstants.petalAnimationDelay

                if index == 0 {
                    // First petal: only show RIGHT half (left half will be rendered on top later)
                    PetalView(
                        color: color,
                        size: style.petalSize,
                        isHovered: model.hoveredPetalIndex == index && model.hoveredRing == .outer,
                        isExpanded: model.isExpanded,
                        expandDelay: expandDelay,
                        collapseDelay: collapseDelay,
                    )
                    .mask(
                        HStack(spacing: 0) {
                            Color.clear.frame(width: maskSize / 2)
                            Color.black.frame(width: maskSize / 2)
                        }
                        .frame(width: maskSize, height: maskSize),
                    )
                    .offset(model.isExpanded ? offset : .zero)
                    .animation(.blossom(delay: model.isExpanded ? expandDelay : collapseDelay), value: model.isExpanded)
                    .position(center)
                } else {
                    PetalView(
                        color: color,
                        size: style.petalSize,
                        isHovered: model.hoveredPetalIndex == index && model.hoveredRing == .outer,
                        isExpanded: model.isExpanded,
                        expandDelay: expandDelay,
                        collapseDelay: collapseDelay,
                    )
                    .offset(model.isExpanded ? offset : .zero)
                    .animation(.blossom(delay: model.isExpanded ? expandDelay : collapseDelay), value: model.isExpanded)
                    .position(center)
                }
            }

            // Outer ring: LEFT half of first petal (rendered on top for looped z-index)
            outerLoopPetal

            // Inner ring petals (6) - rendered on top, animates first (inside to outside)
            ForEach(0 ..< layout.innerPetalCount, id: \.self) { index in
                let offset = petalOffset(for: index, ring: .inner)
                let color = layout.color(for: index, ring: .inner)
                let expandDelay = Double(index) * BlossomConstants.petalAnimationDelay
                let collapseDelay = Double(index + layout.outerPetalCount) * BlossomConstants.petalAnimationDelay

                if index == 0 {
                    // First petal: only show RIGHT half
                    PetalView(
                        color: color,
                        size: style.petalSize,
                        isHovered: model.hoveredPetalIndex == index && model.hoveredRing == .inner,
                        isExpanded: model.isExpanded,
                        expandDelay: expandDelay,
                        collapseDelay: collapseDelay,
                    )
                    .mask(
                        HStack(spacing: 0) {
                            Color.clear.frame(width: maskSize / 2)
                            Color.black.frame(width: maskSize / 2)
                        }
                        .frame(width: maskSize, height: maskSize),
                    )
                    .offset(model.isExpanded ? offset : .zero)
                    .animation(.blossom(delay: model.isExpanded ? expandDelay : collapseDelay), value: model.isExpanded)
                    .position(center)
                } else {
                    PetalView(
                        color: color,
                        size: style.petalSize,
                        isHovered: model.hoveredPetalIndex == index && model.hoveredRing == .inner,
                        isExpanded: model.isExpanded,
                        expandDelay: expandDelay,
                        collapseDelay: collapseDelay,
                    )
                    .offset(model.isExpanded ? offset : .zero)
                    .animation(.blossom(delay: model.isExpanded ? expandDelay : collapseDelay), value: model.isExpanded)
                    .position(center)
                }
            }

            // Inner ring: LEFT half of first petal (rendered on top for looped z-index)
            innerLoopPetal
        }
    }

    /// LEFT half of outer ring's first petal for looped z-index effect
    @ViewBuilder
    private var outerLoopPetal: some View {
        let offset = petalOffset(for: 0, ring: .outer)
        let color = layout.color(for: 0, ring: .outer)
        let expandDelay = Double(layout.innerPetalCount) * BlossomConstants.petalAnimationDelay
        let collapseDelay = 0.0

        PetalView(
            color: color,
            size: style.petalSize,
            isHovered: model.hoveredPetalIndex == 0 && model.hoveredRing == .outer,
            isExpanded: model.isExpanded,
            expandDelay: expandDelay,
            collapseDelay: collapseDelay,
        )
        .mask(
            HStack(spacing: 0) {
                Color.black.frame(width: maskSize / 2)
                Color.clear.frame(width: maskSize / 2)
            }
            .frame(width: maskSize, height: maskSize),
        )
        .offset(model.isExpanded ? offset : .zero)
        .animation(.blossom(delay: model.isExpanded ? expandDelay : collapseDelay), value: model.isExpanded)
        .position(center)
    }

    /// LEFT half of inner ring's first petal for looped z-index effect
    @ViewBuilder
    private var innerLoopPetal: some View {
        let offset = petalOffset(for: 0, ring: .inner)
        let color = layout.color(for: 0, ring: .inner)
        let expandDelay = 0.0
        let collapseDelay = Double(layout.outerPetalCount) * BlossomConstants.petalAnimationDelay

        PetalView(
            color: color,
            size: style.petalSize,
            isHovered: model.hoveredPetalIndex == 0 && model.hoveredRing == .inner,
            isExpanded: model.isExpanded,
            expandDelay: expandDelay,
            collapseDelay: collapseDelay,
        )
        .mask(
            HStack(spacing: 0) {
                Color.black.frame(width: maskSize / 2)
                Color.clear.frame(width: maskSize / 2)
            }
            .frame(width: maskSize, height: maskSize),
        )
        .offset(model.isExpanded ? offset : .zero)
        .animation(.blossom(delay: model.isExpanded ? expandDelay : collapseDelay), value: model.isExpanded)
        .position(center)
    }
}

#Preview {
    @Previewable @State var model = BlossomColorPickerModel()

    BlossomPetalsView(
        model: model,
        layout: PetalLayout(),
        center: CGPoint(x: 150, y: 150),
    )
    .frame(width: 300, height: 300)
    .onAppear {
        model.expand()
    }
}
