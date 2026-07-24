import SwiftUI

/// Central location for all configurable constants in the Blossom Color Picker.
/// Edit these values to adjust the appearance and layout of the picker.
public enum BlossomConstants {
    // MARK: - Petal Layout

    /// Number of petals in the inner ring
    public static let innerPetalCount: Int = 6

    /// Number of petals in the outer ring
    public static let outerPetalCount: Int = 12

    /// Distance from center to inner ring petals
    public static let innerRadius: CGFloat = 20

    /// Distance from center to outer ring petals
    public static let outerRadius: CGFloat = 36

    // MARK: - Sizes

    /// Size of each petal circle
    public static let petalSize: CGFloat = 30

    /// Size of the inner ring petals (if different from outer)
    public static let innerPetalSize: CGFloat = 30

    /// Size of the center circle
    public static let centerCircleSize: CGFloat = 30

    // MARK: - Outer Ring

    /// Width of the outer ring border stroke
    public static let outerRingBorderWidth: CGFloat = 6

    /// Gap between outer ring border and the color picker circles (petals)
    public static let outerRingInset: CGFloat = 12

    // MARK: - Borders

    /// Border width for petals and center circle
    public static let borderWidth: CGFloat = 1

    /// Saturation multiplier for petal borders (1.5 = 50% more saturated)
    public static let borderSaturationMultiplier: CGFloat = 1.25

    /// Brightness multiplier for petal borders (0.85 = 15% darker)
    public static let borderBrightnessMultiplier: CGFloat = 0.9

    /// Border color opacity for the white center circle
    public static let centerBorderOpacity: CGFloat = 0.1

    // MARK: - Arc Slider

    /// Width of the arc slider track
    public static let sliderWidth: CGFloat = 12

    /// Height of the brightness/saturation sliders (unused for arc)
    public static let sliderHeight: CGFloat = 140

    /// Spacing between blossom and sliders
    public static let sliderSpacing: CGFloat = 20

    /// Arc slider start angle in degrees (0° = 3 o'clock, -30° ≈ 2 o'clock)
    public static let arcStartAngle: Double = -30

    /// Arc slider end angle in degrees (30° ≈ 4 o'clock)
    public static let arcEndAngle: Double = 30

    /// Arc slider radius from center
    public static let arcSliderRadius: CGFloat = 80

    /// Arc slider thumb size addition to track width
    public static let arcThumbSizeOffset: CGFloat = 8

    /// Arc slider thumb scale when dragging
    public static let arcThumbDragScale: CGFloat = 1.1

    /// Arc slider animation delay on expand
    public static let arcSliderAnimationDelay: Double = 0.1

    /// Number of gradient steps in the arc slider
    public static let arcGradientSteps: Int = 11

    // MARK: - Animation

    /// Delay between each petal's animation (staggered bloom effect)
    public static let petalAnimationDelay: Double = 0.015

    /// Animation delay for center circle
    public static let centerAnimationDelay: Double = 0.1

    // MARK: - Hover Effects

    /// Scale factor when petal is hovered
    public static let petalHoverScale: CGFloat = 1.1

    // MARK: - Collapsed Swatch

    /// Size of the collapsed color swatch
    public static let collapsedSwatchSize: CGFloat = 32

    /// Border opacity for the collapsed swatch
    public static let collapsedSwatchBorderOpacity: CGFloat = 0.3

    // MARK: - Layout Spacing

    /// Padding between ring and slider
    public static let sliderPadding: CGFloat = 12

    /// Extra padding for total view size
    public static let viewPadding: CGFloat = 20
}
