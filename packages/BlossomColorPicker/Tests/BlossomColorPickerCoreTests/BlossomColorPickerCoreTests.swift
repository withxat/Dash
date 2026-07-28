import CoreGraphics
import SwiftUI
import Testing

@testable import BlossomColorPickerCore

@MainActor
@Test func modelNormalizesHueAndClampsEditableComponents() {
  let model = BlossomColorPickerModel(initialColor: .red)

  model.updateHue(-30)
  #expect(model.hue == 330)
  model.updateHue(390)
  #expect(model.hue == 30)

  model.updateSaturation(-1)
  #expect(model.saturation == 0)
  model.updateSaturation(2)
  #expect(model.saturation == 1)

  model.updateLightness(-10)
  #expect(model.lightness == 0)
  model.updateLightness(120)
  #expect(model.lightness == 100)
}

@MainActor
@Test func collapsingClearsTransientHoverState() {
  let model = BlossomColorPickerModel()
  model.expand()
  model.hoveredPetalIndex = 3
  model.hoveredRing = .outer

  model.collapse()

  #expect(!model.isExpanded)
  #expect(model.hoveredPetalIndex == nil)
  #expect(model.hoveredRing == nil)
}

@Test func petalLayoutMapsCardinalPositionsToExpectedRings() throws {
  let layout = PetalLayout(
    innerPetalCount: 6,
    outerPetalCount: 12,
    innerRadius: 40,
    outerRadius: 80
  )
  let center = CGPoint(x: 100, y: 100)

  let outer = try #require(
    layout.petalIndex(at: CGPoint(x: 100, y: 20), center: center, petalSize: 30))
  #expect(outer.index == 0)
  #expect(outer.ring == .outer)

  let inner = try #require(
    layout.petalIndex(at: CGPoint(x: 100, y: 60), center: center, petalSize: 30))
  #expect(inner.index == 0)
  #expect(inner.ring == .inner)

  #expect(layout.petalIndex(at: center, center: center, petalSize: 30) == nil)
}
