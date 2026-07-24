import SwiftUI

struct PetalView: View {
    let color: Color
    let size: CGFloat
    let isHovered: Bool
    let isExpanded: Bool
    let expandDelay: Double
    let collapseDelay: Double

    var body: some View {
        Circle()
            .fill(color)
            .overlay(
                Circle()
                    .stroke(borderColor, lineWidth: BlossomConstants.borderWidth),
            )
            .frame(width: size, height: size)
            .scaleEffect(isHovered ? BlossomConstants.petalHoverScale : 1.0)
            .scaleEffect(isExpanded ? 1.0 : 0.0)
            .opacity(isExpanded ? 1.0 : 0.0)
            .animation(.blossom(delay: isExpanded ? expandDelay : collapseDelay), value: isExpanded)
            .animation(.blossom, value: isHovered)
    }

    /// Border color with higher saturation
    private var borderColor: Color {
        adjustedBorderColor(
            from: color,
            saturationMultiplier: BlossomConstants.borderSaturationMultiplier,
            brightnessMultiplier: BlossomConstants.borderBrightnessMultiplier,
        )
    }
}

#Preview {
    HStack(spacing: 20) {
        PetalView(
            color: Color(red: 241 / 255, green: 211 / 255, blue: 101 / 255),
            size: 40,
            isHovered: false,
            isExpanded: true,
            expandDelay: 0,
            collapseDelay: 0,
        )
        PetalView(
            color: Color(red: 218 / 255, green: 231 / 255, blue: 248 / 255),
            size: 40,
            isHovered: true,
            isExpanded: true,
            expandDelay: 0,
            collapseDelay: 0,
        )
    }
    .padding(40)
}
