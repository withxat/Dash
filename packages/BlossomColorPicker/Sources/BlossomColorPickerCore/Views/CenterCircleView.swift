import SwiftUI

struct CenterCircleView: View {
    let centerColor: Color
    let isExpanded: Bool
    let expandDelay: Double
    let collapseDelay: Double

    @Environment(\.blossomStyle) private var style

    var body: some View {
        Circle()
            .fill(centerColor)
            .overlay(
                Circle()
                    .stroke(Color.gray.opacity(BlossomConstants.centerBorderOpacity), lineWidth: BlossomConstants.borderWidth),
            )
            .frame(width: style.centerCircleSize, height: style.centerCircleSize)
            .scaleEffect(isExpanded ? 1.0 : 0.0)
            .opacity(isExpanded ? 1.0 : 0.0)
            .animation(.blossom(delay: isExpanded ? expandDelay : collapseDelay), value: isExpanded)
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3)
        CenterCircleView(
            centerColor: .white,
            isExpanded: true,
            expandDelay: 0,
            collapseDelay: 0.3,
        )
    }
    .frame(width: 200, height: 200)
}
