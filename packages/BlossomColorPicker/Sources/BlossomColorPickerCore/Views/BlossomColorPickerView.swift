import SwiftUI

struct BlossomColorPickerView: View {
    @Bindable var model: BlossomColorPickerModel
    let layout: PetalLayout

    @Environment(\.blossomStyle) private var style

    var body: some View {
        ZStack {
            // Collapsed swatch - only hittable when not expanded
            CollapsedSwatchView(
                color: model.selectedColor,
                isExpanded: model.isExpanded,
                onTap: { model.expand() },
            )
            .allowsHitTesting(!model.isExpanded)

            // Expanded blossom - only hittable when expanded
            ExpandedBlossomView(
                model: model,
                layout: layout,
            )
            .allowsHitTesting(model.isExpanded)
        }
        .animation(.blossom, value: model.isExpanded)
    }
}

#Preview("Collapsed") {
    @Previewable @State var model = BlossomColorPickerModel(initialColor: .blue)

    BlossomColorPickerView(
        model: model,
        layout: PetalLayout(),
    )
    .padding(40)
}

#Preview("Expanded") {
    @Previewable @State var model = BlossomColorPickerModel(initialColor: .orange)

    BlossomColorPickerView(
        model: model,
        layout: PetalLayout(),
    )
    .onAppear {
        model.expand()
    }
    .padding(40)
}
