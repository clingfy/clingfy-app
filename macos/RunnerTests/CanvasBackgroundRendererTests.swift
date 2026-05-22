import CoreGraphics
import XCTest

@testable import Clingfy

/// Phase 2 guard for the preset-background feature: the procedural
/// `AbstractWavesBackgroundRenderer` + the `CanvasBackgroundRenderer`
/// dispatcher/cache + the `BackgroundPresetCatalog`. Pins that rendering
/// succeeds at preview and export sizes and — critically — that it is
/// deterministic by `seed`, so the live preview and the export produce
/// matching results.
final class CanvasBackgroundRendererTests: XCTestCase {

  private func preset(
    seed: Int = 1, palette: String = "bluePurple", intensity: Double = 0.7,
    blur: Double = 0.35
  ) -> CanvasBackgroundPreset {
    CanvasBackgroundPreset(
      id: "abstractWaves", palette: palette, intensity: intensity, blur: blur, seed: seed)
  }

  private func pixelData(_ image: CGImage) -> Data? {
    image.dataProvider?.data as Data?
  }

  // MARK: - Catalog

  func testCatalogPaletteLookupAndFallback() {
    XCTAssertEqual(BackgroundPresetCatalog.palette("sunset").id, "sunset")
    // Unknown palette falls back to the default.
    XCTAssertEqual(
      BackgroundPresetCatalog.palette("does-not-exist").id,
      BackgroundPresetCatalog.defaultPaletteId)
    XCTAssertFalse(BackgroundPresetCatalog.palette("bluePurple").colorsArgb.isEmpty)
  }

  // MARK: - Rendering succeeds

  func testRendersNonEmptyImageAtPreviewSize() {
    let image = CanvasBackgroundRenderer.shared.image(
      for: preset(), pixelSize: CGSize(width: 800, height: 450))
    XCTAssertNotNil(image)
    XCTAssertEqual(image?.width, 800)
    XCTAssertEqual(image?.height, 450)
  }

  func testRendersAt4K() {
    let image = CanvasBackgroundRenderer.shared.image(
      for: preset(seed: 99), pixelSize: CGSize(width: 3840, height: 2160))
    XCTAssertNotNil(image)
    XCTAssertEqual(image?.width, 3840)
    XCTAssertEqual(image?.height, 2160)
  }

  func testZeroSizeReturnsNil() {
    XCTAssertNil(
      CanvasBackgroundRenderer.shared.image(for: preset(), pixelSize: .zero))
  }

  // MARK: - Determinism

  func testSameSeedProducesIdenticalOutput() {
    let size = CGSize(width: 320, height: 200)
    let renderer = AbstractWavesBackgroundRenderer()
    guard
      let a = renderer.render(preset: preset(seed: 42), pixelSize: size),
      let b = renderer.render(preset: preset(seed: 42), pixelSize: size)
    else {
      return XCTFail("renderer returned nil")
    }
    XCTAssertEqual(pixelData(a), pixelData(b), "same seed must render byte-identical pixels")
  }

  func testDifferentSeedProducesDifferentOutput() {
    let size = CGSize(width: 320, height: 200)
    let renderer = AbstractWavesBackgroundRenderer()
    guard
      let a = renderer.render(preset: preset(seed: 1), pixelSize: size),
      let b = renderer.render(preset: preset(seed: 2), pixelSize: size)
    else {
      return XCTFail("renderer returned nil")
    }
    XCTAssertNotEqual(pixelData(a), pixelData(b), "different seeds should differ")
  }

  func testDifferentPaletteProducesDifferentOutput() {
    let size = CGSize(width: 320, height: 200)
    let renderer = AbstractWavesBackgroundRenderer()
    guard
      let a = renderer.render(
        preset: preset(seed: 7, palette: "bluePurple"), pixelSize: size),
      let b = renderer.render(preset: preset(seed: 7, palette: "sunset"), pixelSize: size)
    else {
      return XCTFail("renderer returned nil")
    }
    XCTAssertNotEqual(pixelData(a), pixelData(b))
  }

  // MARK: - Seeded generator

  func testSeededGeneratorIsDeterministic() {
    var a = SeededGenerator(seed: 123)
    var b = SeededGenerator(seed: 123)
    for _ in 0..<32 {
      XCTAssertEqual(a.next(), b.next())
    }
  }
}
