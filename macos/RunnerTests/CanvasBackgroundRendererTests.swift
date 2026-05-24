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

  // MARK: - Phase 5 presets (graphicMesh, radialGlow)

  func testCatalogListsAllPhase5Presets() {
    XCTAssertEqual(
      Set(BackgroundPresetCatalog.presetIds),
      ["abstractWaves", "graphicMesh", "radialGlow"])
  }

  func testGraphicMeshRendersAndIsDeterministic() {
    let size = CGSize(width: 360, height: 240)
    let p = CanvasBackgroundPreset(
      id: "graphicMesh", palette: "aurora", intensity: 0.7, blur: 0.3, seed: 5)
    let renderer = GraphicMeshBackgroundRenderer()
    guard
      let a = renderer.render(preset: p, pixelSize: size),
      let b = renderer.render(preset: p, pixelSize: size)
    else {
      return XCTFail("graphicMesh renderer returned nil")
    }
    XCTAssertEqual(a.width, 360)
    XCTAssertEqual(pixelData(a), pixelData(b))
  }

  func testRadialGlowRendersAndIsDeterministic() {
    let size = CGSize(width: 360, height: 240)
    let p = CanvasBackgroundPreset(
      id: "radialGlow", palette: "sunset", intensity: 0.6, blur: 0.2, seed: 8)
    let renderer = RadialGlowBackgroundRenderer()
    guard
      let a = renderer.render(preset: p, pixelSize: size),
      let b = renderer.render(preset: p, pixelSize: size)
    else {
      return XCTFail("radialGlow renderer returned nil")
    }
    XCTAssertEqual(a.height, 240)
    XCTAssertEqual(pixelData(a), pixelData(b))
  }

  func testDispatcherRoutesEachPresetId() {
    let size = CGSize(width: 200, height: 120)
    for id in BackgroundPresetCatalog.presetIds {
      let p = CanvasBackgroundPreset(
        id: id, palette: "bluePurple", intensity: 0.7, blur: 0.35, seed: 3)
      XCTAssertNotNil(
        CanvasBackgroundRenderer.shared.image(for: p, pixelSize: size),
        "dispatcher returned nil for preset \(id)")
    }
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
