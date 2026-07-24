import SwiftUI

struct OuterRingView: View {
    let color: Color
    let radius: CGFloat
    let isExpanded: Bool

    @Environment(\.blossomStyle) private var style

    var body: some View {
        Circle()
            .fill(color.opacity(0.15))
            .overlay(
                Circle()
                    .stroke(color, lineWidth: style.outerRingBorderWidth),
            )
            .frame(width: radius * 2, height: radius * 2)
            .scaleEffect(isExpanded ? 1.0 : 0.0)
            .opacity(isExpanded ? 1.0 : 0.0)
            .animation(.blossom, value: isExpanded)
            .animation(.blossom, value: color)
    }
}

#Preview {
    OuterRingView(
        color: .green,
        radius: 100,
        isExpanded: true,
    )
    .padding(40)
}
