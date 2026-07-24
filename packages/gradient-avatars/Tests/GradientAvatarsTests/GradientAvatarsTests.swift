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
    AvatarRenderer.image(seed: "jane@example.com", size: 64, pattern: .mesh)
  )
  let second = try #require(
    AvatarRenderer.image(seed: "jane@example.com", size: 64, pattern: .mesh)
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

@Test func pngExportProducesACompletePNG() throws {
  let data = try #require(
    AvatarRenderer.pngData(seed: "outpace", size: 48, pattern: .dither)
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
