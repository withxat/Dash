import SwiftUI

public struct BlossomColors: Codable, Sendable {
    public let center: [RGBColor]
    public let ring_1: [RGBColor] // Inner ring - 6 colors
    public let ring_2: [RGBColor] // Outer ring - 12 colors

    public struct RGBColor: Codable, Sendable {
        public let r: Int
        public let g: Int
        public let b: Int

        public var color: Color {
            Color(
                red: Double(r) / 255.0,
                green: Double(g) / 255.0,
                blue: Double(b) / 255.0,
            )
        }
    }

    public var centerColor: Color {
        center.first?.color ?? .white
    }

    public static let `default`: BlossomColors = {
        guard let url = Bundle.module.url(forResource: "sample_colors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let colors = try? JSONDecoder().decode(BlossomColors.self, from: data)
        else {
            // Fallback colors
            return BlossomColors(
                center: [RGBColor(r: 253, g: 253, b: 253)],
                ring_1: [
                    RGBColor(r: 250, g: 244, b: 209),
                    RGBColor(r: 246, g: 226, b: 218),
                    RGBColor(r: 240, g: 213, b: 217),
                    RGBColor(r: 227, g: 215, b: 235),
                    RGBColor(r: 218, g: 231, b: 248),
                    RGBColor(r: 218, g: 236, b: 219),
                ],
                ring_2: [
                    RGBColor(r: 241, g: 211, b: 101),
                    RGBColor(r: 235, g: 191, b: 102),
                    RGBColor(r: 228, g: 168, b: 100),
                    RGBColor(r: 220, g: 109, b: 77),
                    RGBColor(r: 211, g: 85, b: 81),
                    RGBColor(r: 204, g: 84, b: 156),
                    RGBColor(r: 163, g: 101, b: 211),
                    RGBColor(r: 137, g: 108, b: 206),
                    RGBColor(r: 118, g: 153, b: 232),
                    RGBColor(r: 145, g: 199, b: 207),
                    RGBColor(r: 175, g: 217, b: 161),
                    RGBColor(r: 194, g: 224, b: 155),
                ],
            )
        }
        return colors
    }()
}
