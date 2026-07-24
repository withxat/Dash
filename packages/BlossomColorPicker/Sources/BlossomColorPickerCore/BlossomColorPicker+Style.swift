import SwiftUI

public struct BlossomStyle: Sendable {
    public var petalSize: CGFloat
    public var innerPetalSize: CGFloat
    public var outerRingBorderWidth: CGFloat
    public var centerCircleSize: CGFloat
    public var sliderWidth: CGFloat
    public var sliderHeight: CGFloat
    public var spacing: CGFloat

    public init(
        petalSize: CGFloat = BlossomConstants.petalSize,
        innerPetalSize: CGFloat = BlossomConstants.innerPetalSize,
        outerRingBorderWidth: CGFloat = BlossomConstants.outerRingBorderWidth,
        centerCircleSize: CGFloat = BlossomConstants.centerCircleSize,
        sliderWidth: CGFloat = BlossomConstants.sliderWidth,
        sliderHeight: CGFloat = BlossomConstants.sliderHeight,
        spacing: CGFloat = BlossomConstants.sliderSpacing,
    ) {
        self.petalSize = petalSize
        self.innerPetalSize = innerPetalSize
        self.outerRingBorderWidth = outerRingBorderWidth
        self.centerCircleSize = centerCircleSize
        self.sliderWidth = sliderWidth
        self.sliderHeight = sliderHeight
        self.spacing = spacing
    }

    public static let `default` = BlossomStyle()
}

extension EnvironmentValues {
    @Entry var blossomStyle: BlossomStyle = .default
}

public extension View {
    func blossomStyle(_ style: BlossomStyle) -> some View {
        environment(\.blossomStyle, style)
    }
}
