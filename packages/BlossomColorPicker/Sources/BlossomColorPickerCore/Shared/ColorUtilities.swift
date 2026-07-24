import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// Extract HSB components from a SwiftUI Color
/// - Returns: Tuple with hue (0-360), saturation (0-1), brightness (0-100)
public func extractHSB(from color: Color) -> (hue: Double, saturation: Double, brightness: Double) {
    #if canImport(UIKit)
        let uiColor = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h * 360.0, s, b * 100.0)
    #elseif canImport(AppKit)
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return (nsColor.hueComponent * 360.0, nsColor.saturationComponent, nsColor.brightnessComponent * 100.0)
    #endif
}

/// Create a border color with adjusted saturation and brightness
public func adjustedBorderColor(from color: Color, saturationMultiplier: Double, brightnessMultiplier: Double) -> Color {
    #if canImport(UIKit)
        let uiColor = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let newS = min(1.0, s * saturationMultiplier)
        let newB = min(1.0, b * brightnessMultiplier)
        return Color(UIColor(hue: h, saturation: newS, brightness: newB, alpha: a))
    #elseif canImport(AppKit)
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let newS = min(1.0, nsColor.saturationComponent * saturationMultiplier)
        let newB = min(1.0, nsColor.brightnessComponent * brightnessMultiplier)
        return Color(NSColor(hue: nsColor.hueComponent, saturation: newS, brightness: newB, alpha: nsColor.alphaComponent))
    #endif
}

/// Compare two colors by HSB with tolerance
public func colorsMatch(_ color1: Color, _ color2: Color, tolerance: Double = 0.01) -> Bool {
    let (h1, s1, b1) = extractHSB(from: color1)
    let (h2, s2, b2) = extractHSB(from: color2)

    // Normalize to 0-1 for comparison
    let hue1 = h1 / 360.0, hue2 = h2 / 360.0
    let bright1 = b1 / 100.0, bright2 = b2 / 100.0

    let hueMatch = abs(hue1 - hue2) < tolerance || abs(hue1 - hue2) > (1.0 - tolerance)
    let satMatch = abs(s1 - s2) < tolerance
    let brightMatch = abs(bright1 - bright2) < tolerance

    print("[ColorsMatch] color1: h=\(hue1), s=\(s1), b=\(bright1)")
    print("[ColorsMatch] color2: h=\(hue2), s=\(s2), b=\(bright2)")
    print("[ColorsMatch] match: hue=\(hueMatch), sat=\(satMatch), bright=\(brightMatch)")

    return hueMatch && satMatch && brightMatch
}
