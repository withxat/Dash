import SwiftUI

struct ArcSliderView: View {
    @Bindable var model: BlossomColorPickerModel
    let radius: CGFloat

    @Environment(\.blossomStyle) private var style

    @State private var isDragging = false

    private var startAngle: Double {
        BlossomConstants.arcStartAngle
    }

    private var endAngle: Double {
        BlossomConstants.arcEndAngle
    }

    private var arcSpan: Double {
        endAngle - startAngle
    }

    var body: some View {
        let thumbAngle = startAngle + (1.0 - model.lightness / 100.0) * arcSpan

        ZStack {
            // Arc track with gradient
            ArcShape(startAngle: .degrees(startAngle), endAngle: .degrees(endAngle))
                .stroke(
                    AngularGradient(
                        colors: gradientColors,
                        center: .center,
                        startAngle: .degrees(startAngle),
                        endAngle: .degrees(endAngle),
                    ),
                    style: StrokeStyle(lineWidth: style.sliderWidth, lineCap: .round),
                )
                .frame(width: radius * 2, height: radius * 2)

            // Thumb
            Circle()
                .fill(currentThumbColor)
                .frame(
                    width: style.sliderWidth + BlossomConstants.arcThumbSizeOffset,
                    height: style.sliderWidth + BlossomConstants.arcThumbSizeOffset,
                )
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.5), lineWidth: BlossomConstants.borderWidth),
                )
                .scaleEffect(isDragging ? BlossomConstants.arcThumbDragScale : 1.0)
                .offset(
                    x: cos(thumbAngle * .pi / 180) * radius,
                    y: sin(thumbAngle * .pi / 180) * radius,
                )
                .animation(.blossom, value: isDragging)
                .animation(isDragging ? nil : .blossom, value: model.lightness)
        }
        .animation(isDragging ? nil : .blossom, value: model.hue)
        .animation(isDragging ? nil : .blossom, value: model.saturation)
        .scaleEffect(model.isExpanded ? 1.0 : 0.0)
        .opacity(model.isExpanded ? 1.0 : 0.0)
        .animation(.blossom(delay: BlossomConstants.arcSliderAnimationDelay), value: model.isExpanded)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    updateLightness(from: value.location, center: CGPoint(x: radius, y: radius))
                }
                .onEnded { _ in
                    isDragging = false
                },
        )
    }

    private var currentThumbColor: Color {
        // Blend from selected color to white based on brightness
        let t = model.lightness / 100.0
        let adjustedSaturation = model.saturation * (1.0 - t * 0.8) // Reduce saturation towards white
        return Color(hue: model.hue / 360.0, saturation: adjustedSaturation, brightness: 0.2 + t * 0.8)
    }

    private var gradientColors: [Color] {
        // Gradient from dark color to white
        (0 ..< BlossomConstants.arcGradientSteps).map { i in
            let t = Double(i) / Double(BlossomConstants.arcGradientSteps - 1)
            let brightness = 1.0 - t // 1.0 at start (white end), 0.0 at end (dark end)
            let saturation = model.saturation * t // 0 at white end, full at color end
            return Color(hue: model.hue / 360.0, saturation: saturation, brightness: max(0.1, brightness * 0.8 + 0.2))
        }
    }

    private func updateLightness(from location: CGPoint, center: CGPoint) {
        let dx = location.x - center.x
        let dy = location.y - center.y
        var angle = atan2(dy, dx) * 180 / .pi

        // Clamp angle to arc range
        angle = max(startAngle, min(endAngle, angle))

        // Convert angle to lightness (0-100)
        let normalizedAngle = (angle - startAngle) / arcSpan
        let lightness = (1.0 - normalizedAngle) * 100.0
        model.updateLightness(lightness)
    }
}

struct ArcShape: Shape {
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false,
        )
        return path
    }
}

#Preview {
    @Previewable @State var model = BlossomColorPickerModel(initialColor: .green)

    ArcSliderView(model: model, radius: BlossomConstants.arcSliderRadius)
        .frame(width: 250, height: 250)
        .onAppear {
            model.expand()
        }
        .padding(40)
}
