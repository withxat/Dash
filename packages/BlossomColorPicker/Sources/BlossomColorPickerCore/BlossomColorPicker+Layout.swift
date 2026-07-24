import SwiftUI

public struct PetalLayout: Sendable {
    public enum Ring: Sendable {
        case inner // ring_1: 6 petals
        case outer // ring_2: 12 petals
    }

    public let innerPetalCount: Int
    public let outerPetalCount: Int
    public let innerRadius: CGFloat
    public let outerRadius: CGFloat
    public let colors: BlossomColors

    public init(
        innerPetalCount: Int = BlossomConstants.innerPetalCount,
        outerPetalCount: Int = BlossomConstants.outerPetalCount,
        innerRadius: CGFloat = BlossomConstants.innerRadius,
        outerRadius: CGFloat = BlossomConstants.outerRadius,
        colors: BlossomColors = .default,
    ) {
        self.innerPetalCount = innerPetalCount
        self.outerPetalCount = outerPetalCount
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.colors = colors
    }

    public var totalPetalCount: Int {
        innerPetalCount + outerPetalCount
    }

    func petalCount(for ring: Ring) -> Int {
        switch ring {
        case .inner: innerPetalCount
        case .outer: outerPetalCount
        }
    }

    func radius(for ring: Ring) -> CGFloat {
        switch ring {
        case .inner: innerRadius
        case .outer: outerRadius
        }
    }

    /// Angle for petal position (starting from 12 o'clock, going clockwise)
    func angle(for index: Int, ring: Ring) -> Angle {
        let count = petalCount(for: ring)
        let baseAngle = 360.0 / Double(count)
        // Start from -90° (12 o'clock) and go clockwise
        return .degrees(Double(index) * baseAngle - 90)
    }

    func position(for index: Int, ring: Ring, in center: CGPoint) -> CGPoint {
        let angle = angle(for: index, ring: ring)
        let radius = radius(for: ring)
        return CGPoint(
            x: center.x + cos(angle.radians) * radius,
            y: center.y + sin(angle.radians) * radius,
        )
    }

    /// Get color for petal from loaded JSON colors
    func color(for index: Int, ring: Ring) -> Color {
        switch ring {
        case .inner:
            let safeIndex = index % colors.ring_1.count
            return colors.ring_1[safeIndex].color
        case .outer:
            let safeIndex = index % colors.ring_2.count
            return colors.ring_2[safeIndex].color
        }
    }

    var centerColor: Color {
        colors.centerColor
    }

    func petalIndex(at point: CGPoint, center: CGPoint, petalSize: CGFloat) -> (index: Int, ring: Ring)? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)

        // Calculate angle from 12 o'clock going clockwise
        var angle = atan2(dy, dx) * 180 / .pi + 90
        if angle < 0 { angle += 360 }

        // Threshold between inner and outer rings (midpoint between ring centers)
        let ringThreshold = (outerRadius + innerRadius) / 2

        // Check outer ring: from threshold to outer edge
        if distance > ringThreshold, distance < outerRadius + petalSize / 2 {
            let index = Int(round(angle / (360.0 / Double(outerPetalCount)))) % outerPetalCount
            return (index, .outer)
        }

        // Check inner ring: from inner edge to threshold
        // Inner edge starts at innerRadius - petalSize/2, but we also need to exclude center circle
        let innerStart = max(innerRadius - petalSize / 2, BlossomConstants.centerCircleSize / 2)
        if distance > innerStart, distance <= ringThreshold {
            let index = Int(round(angle / (360.0 / Double(innerPetalCount)))) % innerPetalCount
            return (index, .inner)
        }

        return nil
    }
}
