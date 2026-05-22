import XCTest

@testable import Clingfy

/// Phase 1 guard for the preset-background feature: the `CanvasBackground`
/// model + its `from(args:)` / `resolve(...)` resolver, and the new preset
/// fields on the `processVideo` / `exportVideo` request DTOs. Pins the
/// back-compat kind inference (old Flutter payloads carry no
/// `backgroundKind`) and the preset-parameter parsing + clamping.
final class CanvasBackgroundTests: XCTestCase {

  // MARK: - CanvasBackgroundPreset.from(args:)

  func testPresetFromArgsReturnsNilWhenNoPresetId() {
    XCTAssertNil(CanvasBackgroundPreset.from(args: nil))
    XCTAssertNil(CanvasBackgroundPreset.from(args: ["backgroundColor": 0xFF00FF00]))
    XCTAssertNil(CanvasBackgroundPreset.from(args: ["backgroundPresetId": ""]))
  }

  func testPresetFromArgsParsesAllFields() {
    let preset = CanvasBackgroundPreset.from(args: [
      "backgroundPresetId": "abstractWaves",
      "backgroundPresetPalette": "bluePurple",
      "backgroundPresetIntensity": 0.8,
      "backgroundPresetBlur": 0.25,
      "backgroundPresetSeed": 42,
    ])
    XCTAssertEqual(preset?.id, "abstractWaves")
    XCTAssertEqual(preset?.palette, "bluePurple")
    XCTAssertEqual(preset?.intensity, 0.8)
    XCTAssertEqual(preset?.blur, 0.25)
    XCTAssertEqual(preset?.seed, 42)
  }

  func testPresetFromArgsAppliesDefaultsAndClamps() {
    let preset = CanvasBackgroundPreset.from(args: [
      "backgroundPresetId": "abstractWaves",
      "backgroundPresetIntensity": 5.0,  // out of range → clamps to 1.0
      "backgroundPresetBlur": -2.0,  // out of range → clamps to 0.0
    ])
    XCTAssertEqual(preset?.palette, "default")
    XCTAssertEqual(preset?.intensity, 1.0)
    XCTAssertEqual(preset?.blur, 0.0)
    XCTAssertEqual(preset?.seed, 0)
  }

  // MARK: - CanvasBackground.from(args:) — back-compat kind inference

  func testInfersColorWhenNothingSet() {
    let bg = CanvasBackground.from(args: nil)
    XCTAssertEqual(bg.kind, .color)
    XCTAssertNil(bg.colorArgb)
    XCTAssertNil(bg.imagePath)
    XCTAssertNil(bg.preset)
  }

  func testInfersColorFromColorArg() {
    let bg = CanvasBackground.from(args: ["backgroundColor": 0xFF8957E5])
    XCTAssertEqual(bg.kind, .color)
    XCTAssertEqual(bg.colorArgb, 0xFF8957E5)
  }

  func testInfersImageFromImagePathArg() {
    let bg = CanvasBackground.from(args: ["backgroundImagePath": "/tmp/bg.png"])
    XCTAssertEqual(bg.kind, .image)
    XCTAssertEqual(bg.imagePath, "/tmp/bg.png")
  }

  func testInfersPresetFromPresetArgs() {
    let bg = CanvasBackground.from(args: ["backgroundPresetId": "abstractWaves"])
    XCTAssertEqual(bg.kind, .preset)
    XCTAssertEqual(bg.preset?.id, "abstractWaves")
  }

  func testEmptyImagePathIsTreatedAsNoImage() {
    let bg = CanvasBackground.from(args: ["backgroundImagePath": ""])
    XCTAssertEqual(bg.kind, .color)
    XCTAssertNil(bg.imagePath)
  }

  // MARK: - Explicit backgroundKind discriminator

  func testExplicitKindIsHonoredWhenDataPresent() {
    // Color + a stale presetId — explicit kind disambiguates to color.
    let bg = CanvasBackground.from(args: [
      "backgroundKind": "color",
      "backgroundColor": 0xFF112233,
      "backgroundPresetId": "abstractWaves",
    ])
    XCTAssertEqual(bg.kind, .color)
    XCTAssertEqual(bg.colorArgb, 0xFF112233)
  }

  func testExplicitKindFallsBackToInferenceWhenDataMissing() {
    // Says preset but carries no presetId → fall back to inference (image).
    let bg = CanvasBackground.from(args: [
      "backgroundKind": "preset",
      "backgroundImagePath": "/tmp/bg.png",
    ])
    XCTAssertEqual(bg.kind, .image)
  }

  // MARK: - Request DTO parsing

  func testPreviewSceneRequestParsesPreset() {
    let req = PreviewSceneRequest.fromFlutter([
      "projectPath": "/tmp/p.clingfyproj",
      "backgroundKind": "preset",
      "backgroundPresetId": "abstractWaves",
      "backgroundPresetPalette": "bluePurple",
      "backgroundPresetSeed": 7,
    ])
    XCTAssertEqual(req?.backgroundKind, "preset")
    XCTAssertEqual(req?.backgroundPreset?.id, "abstractWaves")
    XCTAssertEqual(req?.canvasBackground.kind, .preset)
    XCTAssertEqual(req?.canvasBackground.preset?.seed, 7)
  }

  func testExportVideoRequestParsesPreset() {
    let req = ExportVideoRequest.fromFlutter([
      "projectPath": "/tmp/p.clingfyproj",
      "backgroundKind": "preset",
      "backgroundPresetId": "abstractWaves",
    ])
    XCTAssertEqual(req?.backgroundPreset?.id, "abstractWaves")
    XCTAssertEqual(req?.canvasBackground.kind, .preset)
  }

  func testRequestDTOsStayBackCompatWithoutPresetArgs() {
    // Old payload: color only, no backgroundKind / preset keys.
    let preview = PreviewSceneRequest.fromFlutter([
      "projectPath": "/tmp/p.clingfyproj",
      "backgroundColor": 0xFF8957E5,
    ])
    XCTAssertNil(preview?.backgroundKind)
    XCTAssertNil(preview?.backgroundPreset)
    XCTAssertEqual(preview?.canvasBackground.kind, .color)
    XCTAssertEqual(preview?.canvasBackground.colorArgb, 0xFF8957E5)

    let export = ExportVideoRequest.fromFlutter([
      "projectPath": "/tmp/p.clingfyproj",
      "backgroundImagePath": "/tmp/bg.png",
    ])
    XCTAssertNil(export?.backgroundPreset)
    XCTAssertEqual(export?.canvasBackground.kind, .image)
  }
}
