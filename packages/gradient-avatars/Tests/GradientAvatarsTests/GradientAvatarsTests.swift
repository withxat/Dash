import CoreGraphics
import Foundation
import Testing

@testable import GradientAvatars

@Test func stringHashMatchesUpstreamAnchors() {
  #expect(AvatarGenerator.seed(from: "example.com") == 2_291_378_260)
  #expect(AvatarGenerator.seed(from: "docs.example.com") == 1_136_324_104)
  #expect(AvatarGenerator.seed(from: "acme") == 1_174_237_616)
  #expect(AvatarGenerator.seed(from: "jane@example.com") == 65_580_788)
  #expect(AvatarGenerator.seed(from: "0") == 890_022_064)
  #expect(AvatarGenerator.seed(from: "") == 2_166_136_261)
}

@Test func seedIgnoresCaseAndSurroundingSpace() {
  #expect(
    AvatarGenerator.seed(from: "  Example.COM \n") == AvatarGenerator.seed(from: "example.com")
  )
}

@Test func goldenPalettesMatchHashvatar() {
  assertPalette("example.com", seed: 2_291_378_260, colors: ["#fd6970", "#470003"])
  assertPalette("docs.example.com", seed: 1_136_324_104, colors: ["#c27900", "#442100"])
  assertPalette("acme", seed: 1_174_237_616, colors: ["#00c2a9", "#00211a"])
  assertPalette("jane@example.com", seed: 65_580_788, colors: ["#cb2f56", "#3f000b"])
  assertPalette("cloudflare.com", seed: 2_445_620_719, colors: ["#00c4f1", "#004766"])
  assertPalette("0", seed: 890_022_064, colors: ["#d75e00", "#410500"])
  assertPalette("", seed: 2_166_136_261, colors: ["#00aeff", "#001749"])

  assertPalette(
    "example.com",
    seed: 2_291_378_260,
    colors: ["#fd6970", "#470003", "#741d25", "#430000"]
  )
}

@Test func paletteKeepsOneHueAndDarkensEverySecondary() {
  for index in 0..<64 {
    let palette = AvatarGenerator.palette(for: "hue-\(index)", count: 4)
    let hues = Set(palette.oklch.map { ($0.hue * 1_000).rounded() })
    #expect(hues.count == 1)

    let primary = palette.oklch[0]
    #expect(palette.oklch.dropFirst().allSatisfy { $0.lightness < primary.lightness })
    #expect(palette.oklch.allSatisfy { $0.chroma <= 0.37 })
  }
}

@Test func tonesOverrideTheHashDerivedHue() {
  let tone = AvatarOklch(lightness: 0.65, chroma: 0.25, hue: 320)
  let palette = AvatarGenerator.palette(for: "toned", count: 2, tones: [tone])
  #expect(palette.oklch.allSatisfy { abs($0.hue - tone.hue) <= 30 })
  #expect(palette != AvatarGenerator.palette(for: "toned", count: 2))
}

@Test func paletteGenerationIsDeterministicAndWellFormed() {
  let first = AvatarGenerator.palette(for: "determinism")
  let second = AvatarGenerator.palette(for: "determinism")
  #expect(first == second)
  #expect(first.seed == AvatarGenerator.seed(from: "determinism"))

  var distinctPalettes = Set<[AvatarColor]>()
  for index in 0..<200 {
    let palette = AvatarGenerator.palette(for: "seed-\(index * 7_919)")
    #expect(palette.colors.count == 2)
    #expect(palette.colors.allSatisfy { $0.hex.count == 7 })
    distinctPalettes.insert(palette.colors)
  }
  #expect(distinctPalettes.count > 190)
}

@Test func renderersProduceStableImagesAtRequestedSize() throws {
  let first = try #require(
    AvatarRenderer.image(seed: "jane@example.com", size: 64, pattern: .gradient)
  )
  let second = try #require(
    AvatarRenderer.image(seed: "jane@example.com", size: 64, pattern: .gradient)
  )
  let dither = try #require(
    AvatarRenderer.image(seed: "jane@example.com", size: 64, pattern: .dither)
  )

  #expect(first.width == 64)
  #expect(first.height == 64)
  #expect(imageBytes(first) == imageBytes(second))
  #expect(imageBytes(first) != imageBytes(dither))
  #expect(AvatarRenderer.image(seed: "invalid", size: 0) == nil)
}

@Test func ditherPaintsNothingButItsTwoPaletteColors() throws {
  let seed = "example.com"
  let image = try #require(AvatarRenderer.image(seed: seed, size: 96, pattern: .dither))
  let palette = AvatarGenerator.palette(for: seed, count: 2)

  #expect(distinctColors(in: image) == Set(palette.colors))
}

@Test func ditherPhaseMovesThePattern() throws {
  let still = try #require(
    AvatarRenderer.image(seed: "motion", size: 64, pattern: .dither, phase: 0)
  )
  let repeated = try #require(
    AvatarRenderer.image(seed: "motion", size: 64, pattern: .dither, phase: 0)
  )
  let moved = try #require(
    AvatarRenderer.image(seed: "motion", size: 64, pattern: .dither, phase: 2.5)
  )

  #expect(imageBytes(still) == imageBytes(repeated))
  #expect(imageBytes(still) != imageBytes(moved))
}

@Test func motionPhaseAdvancesInWholeFrames() {
  let start = Date(timeIntervalSinceReferenceDate: 1_000)
  let sameFrame = start.addingTimeInterval(AvatarMotion.frameInterval / 4)
  let nextFrame = start.addingTimeInterval(AvatarMotion.frameInterval)

  #expect(AvatarMotion.phase(at: start) == AvatarMotion.phase(at: sameFrame))
  #expect(AvatarMotion.phase(at: nextFrame) > AvatarMotion.phase(at: start))
}

@Test func pngExportProducesACompletePNG() throws {
  let data = try #require(
    AvatarRenderer.pngData(seed: "dash.xat.sh", size: 48, pattern: .dither)
  )
  #expect(data.count > 100)
  #expect(Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
}

private func assertPalette(_ input: String, seed: UInt32, colors: [String]) {
  let palette = AvatarGenerator.palette(for: input, count: colors.count)
  #expect(palette.seed == seed)
  #expect(palette.colors.map(\.hex) == colors)
}

private func imageBytes(_ image: CGImage) -> Data? {
  guard let data = image.dataProvider?.data else { return nil }
  return data as Data
}

private func distinctColors(in image: CGImage) -> Set<AvatarColor> {
  guard let data = image.dataProvider?.data as Data? else { return [] }
  var colors = Set<AvatarColor>()
  for y in 0..<image.height {
    let row = y * image.bytesPerRow
    for x in 0..<image.width {
      let offset = row + x * 4
      colors.insert(
        AvatarColor(
          red: data[offset],
          green: data[offset + 1],
          blue: data[offset + 2]
        )
      )
    }
  }
  return colors
}
