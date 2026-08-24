import CoreGraphics
import Foundation
import Testing

@testable import GradientAvatars

@Test func stringHashMatchesUpstreamAnchors() {
  #expect(AvatarGenerator.seed(from: "jane@example.com") == 2_231_369_329)
  #expect(AvatarGenerator.seed(from: "") == 1_947_474_976)
  #expect(AvatarGenerator.seed(from: "a") == 1_817_065_451)
  #expect(AvatarGenerator.seed(from: "👩🏽‍💻") == 3_516_176_855)
}

@Test func goldenPalettesMatchUpstreamVersion021() {
  assertPalette(
    "jane@example.com",
    seed: 2_231_369_329,
    harmony: .triadic,
    colors: ["#8659F2", "#FB692C", "#58FD88"]
  )
  assertPalette(
    "acme",
    seed: 2_281_398_667,
    harmony: .complementary,
    colors: ["#40F8A4", "#EA1979", "#0FF2D6", "#EC4258"]
  )
  assertPalette(
    42,
    seed: 42,
    harmony: .tetradic,
    colors: ["#F38763", "#52F51C", "#29BFF2", "#D160F7"]
  )
  assertPalette(
    0,
    seed: 0,
    harmony: .triadic,
    colors: ["#E23434", "#46E946", "#4A4AF4"]
  )
  assertPalette(
    "outpace",
    seed: 1_754_654_890,
    harmony: .tetradic,
    colors: ["#FEEB21", "#09F96D", "#2C3DF9", "#E72C99"]
  )
  assertPalette(
    "0",
    seed: 1_684_187_033,
    harmony: .complementary,
    colors: ["#252DF4", "#EFE962", "#7B4EE9", "#A9E121"]
  )
}

@Test func paletteCountSharesAStablePrefix() {
  let natural = AvatarGenerator.palette(for: "prefix")
  let pair = AvatarGenerator.palette(for: "prefix", count: 2)
  let quartet = AvatarGenerator.palette(for: "prefix", count: 4)

  #expect(pair.colors == Array(natural.colors.prefix(2)))
  #expect(quartet.colors.prefix(natural.colors.count) == natural.colors[...])
  #expect(pair.harmony == natural.harmony)
  #expect(quartet.harmony == natural.harmony)
}

@Test func paletteGenerationIsDeterministicAndWellFormed() {
  let first = AvatarGenerator.palette(for: "determinism")
  let second = AvatarGenerator.palette(for: "determinism")
  #expect(first == second)
  #expect(first.seed == AvatarGenerator.seed(from: "determinism"))

  var distinctPalettes = Set<[AvatarColor]>()
  for index in 0..<200 {
    let palette = AvatarGenerator.palette(for: "seed-\(index * 7_919)")
    #expect((3...4).contains(palette.colors.count))
    #expect(AvatarHarmony.allCases.contains(palette.harmony))
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

private func assertPalette(
  _ input: String,
  seed: UInt32,
  harmony: AvatarHarmony,
  colors: [String]
) {
  let palette = AvatarGenerator.palette(for: input)
  #expect(palette.seed == seed)
  #expect(palette.harmony == harmony)
  #expect(palette.colors.map(\.hex) == colors)
}

private func assertPalette(
  _ input: UInt32,
  seed: UInt32,
  harmony: AvatarHarmony,
  colors: [String]
) {
  let palette = AvatarGenerator.palette(for: input)
  #expect(palette.seed == seed)
  #expect(palette.harmony == harmony)
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
