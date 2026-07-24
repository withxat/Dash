import SwiftUI

@Observable
@MainActor
public final class BlossomColorPickerModel {
    public var selectedColor: Color {
        didSet {
            updateFromColor()
        }
    }

    /// Hue in degrees (0-360)
    public private(set) var hue: Double
    /// Saturation (0-1)
    public private(set) var saturation: Double
    /// Lightness/Brightness (0-100)
    public private(set) var lightness: Double

    public var isExpanded: Bool = false
    public var hoveredPetalIndex: Int?
    public var hoveredRing: PetalLayout.Ring?

    private var isUpdatingInternally = false

    public init(initialColor: Color = .blue) {
        selectedColor = initialColor
        // Extract HSB from color
        let (h, s, b) = extractHSB(from: initialColor)
        hue = h
        saturation = s
        lightness = b
    }

    private func updateFromColor() {
        guard !isUpdatingInternally else { return }
        let oldHue = hue
        let oldSat = saturation
        let oldLight = lightness
        let (h, s, b) = extractHSB(from: selectedColor)
        hue = h
        saturation = s
        lightness = b
        print("[Model] updateFromColor: hue \(oldHue) -> \(hue), sat \(oldSat) -> \(saturation), light \(oldLight) -> \(lightness)")
    }

    public func updateHue(_ newHue: Double) {
        let oldHue = hue
        isUpdatingInternally = true
        hue = newHue.truncatingRemainder(dividingBy: 360.0)
        if hue < 0 { hue += 360 }
        selectedColor = Color(hue: hue / 360.0, saturation: saturation, brightness: lightness / 100.0)
        isUpdatingInternally = false
        print("[Model] updateHue: \(oldHue) -> \(hue)")
    }

    public func updateSaturation(_ newSaturation: Double) {
        let oldSat = saturation
        isUpdatingInternally = true
        saturation = max(0, min(1, newSaturation))
        selectedColor = Color(hue: hue / 360.0, saturation: saturation, brightness: lightness / 100.0)
        isUpdatingInternally = false
        print("[Model] updateSaturation: \(oldSat) -> \(saturation)")
    }

    public func updateLightness(_ newLightness: Double) {
        let oldLight = lightness
        isUpdatingInternally = true
        lightness = max(0, min(100, newLightness))
        selectedColor = Color(hue: hue / 360.0, saturation: saturation, brightness: lightness / 100.0)
        isUpdatingInternally = false
        print("[Model] updateLightness: \(oldLight) -> \(lightness)")
    }

    public func selectPetal(index: Int, ring: PetalLayout.Ring, layout: PetalLayout) {
        print("[Model] selectPetal: index=\(index), ring=\(ring)")
        // Get color directly from layout (JSON colors)
        let color = layout.color(for: index, ring: ring)
        selectColor(color)
    }

    public func selectCenterColor(layout: PetalLayout) {
        print("[Model] selectCenterColor")
        selectColor(layout.centerColor)
    }

    private func selectColor(_ color: Color) {
        let (h, s, b) = extractHSB(from: color)
        print("[Model] selectColor: hue=\(h), sat=\(s), bright=\(b)")
        isUpdatingInternally = true
        selectedColor = color
        // Update HSB values from new color
        hue = h
        saturation = s
        lightness = b
        isUpdatingInternally = false
    }

    public func outerRingColor(layout: PetalLayout) -> Color {
        guard let index = hoveredPetalIndex, let ring = hoveredRing else {
            return selectedColor
        }
        // Get hovered color from layout (JSON colors)
        return layout.color(for: index, ring: ring)
    }

    public func expand() {
        print("[Model] expand() called, was: \(isExpanded)")
        isExpanded = true
        print("[Model] expand() done, now: \(isExpanded)")
    }

    public func collapse() {
        print("[Model] collapse() called, was: \(isExpanded)")
        isExpanded = false
        hoveredPetalIndex = nil
        hoveredRing = nil
        print("[Model] collapse() done, now: \(isExpanded)")
    }

    public func toggle() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }
}
