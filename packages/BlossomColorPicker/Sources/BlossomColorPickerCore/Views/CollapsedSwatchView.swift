import SwiftUI

struct CollapsedSwatchView: View {
    let color: Color
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: BlossomConstants.collapsedSwatchSize, height: BlossomConstants.collapsedSwatchSize)
            .overlay(
                Circle()
                    .stroke(.white.opacity(BlossomConstants.collapsedSwatchBorderOpacity), lineWidth: BlossomConstants.borderWidth),
            )
            .scaleEffect(isExpanded ? 0.0 : 1.0)
            .opacity(isExpanded ? 0.0 : 1.0)
            .animation(.blossom, value: isExpanded)
            .contentShape(Circle())
            .onTapGesture(perform: onTap)
            .accessibilityLabel("Color picker")
            .accessibilityHint("Tap to expand color picker")
            .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    VStack(spacing: 20) {
        CollapsedSwatchView(
            color: .blue,
            isExpanded: false,
            onTap: {},
        )

        CollapsedSwatchView(
            color: .orange,
            isExpanded: false,
            onTap: {},
        )
    }
    .padding(40)
}
