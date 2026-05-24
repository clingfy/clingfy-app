import XCTest

@testable import Clingfy

/// Golden tests pinning the exact `fromFlutter` parsing/defaults of the
/// boundary DTOs introduced in Commit 2. These lock current behavior so a
/// future slice that rewires the facade to consume the DTOs cannot silently
/// drift any key, default, or the zoom-effect derivation contract.

final class StartRecordingRequestParsingTests: XCTestCase {
  func testDefaultsWhenArgsNil() {
    let r = StartRecordingRequest.fromFlutter(nil)
    XCTAssertNil(r.sessionId)
    XCTAssertFalse(r.disableMicrophone)
    XCTAssertFalse(r.disableCameraOverlay)
    XCTAssertFalse(r.disableCursorHighlight)
    XCTAssertFalse(r.allowLowStorageBypass)
  }

  func testDefaultsWhenArgsEmpty() {
    XCTAssertEqual(StartRecordingRequest.fromFlutter([:]), StartRecordingRequest.fromFlutter(nil))
  }

  func testFullyPopulated() {
    let r = StartRecordingRequest.fromFlutter([
      "sessionId": "sess-1",
      "disableMicrophone": true,
      "disableCameraOverlay": true,
      "disableCursorHighlight": true,
      "allowLowStorageBypass": true,
    ])
    XCTAssertEqual(r.sessionId, "sess-1")
    XCTAssertTrue(r.disableMicrophone)
    XCTAssertTrue(r.disableCameraOverlay)
    XCTAssertTrue(r.disableCursorHighlight)
    XCTAssertTrue(r.allowLowStorageBypass)
  }

  func testWrongTypesFallBackToDefaults() {
    let r = StartRecordingRequest.fromFlutter([
      "sessionId": 42,
      "disableMicrophone": "yes",
    ])
    XCTAssertNil(r.sessionId)
    XCTAssertFalse(r.disableMicrophone)
  }
}

final class ExportVideoRequestParsingTests: XCTestCase {
  func testNilWhenProjectPathMissing() {
    XCTAssertNil(ExportVideoRequest.fromFlutter(nil))
    XCTAssertNil(ExportVideoRequest.fromFlutter([:]))
    XCTAssertNil(ExportVideoRequest.fromFlutter(["layoutPreset": "16:9"]))
  }

  func testDefaultsWithOnlyProjectPath() {
    let r = ExportVideoRequest.fromFlutter(["projectPath": "/p"])!
    XCTAssertEqual(r.projectPath, "/p")
    XCTAssertEqual(r.layout, "auto")
    XCTAssertEqual(r.resolution, "auto")
    XCTAssertEqual(r.fit, "fit")
    XCTAssertEqual(r.padding, 0.0)
    XCTAssertEqual(r.cornerRadius, 0.0)
    XCTAssertNil(r.backgroundColor)
    XCTAssertNil(r.backgroundImagePath)
    XCTAssertEqual(r.cursorSize, 1.0)
    XCTAssertEqual(r.rawZoomFactor, 1.5)
    XCTAssertTrue(r.zoomEffectEnabled)  // raw 1.5 > 1.0
    XCTAssertEqual(r.zoomFactor, 1.5)
    XCTAssertTrue(r.showCursor)
    XCTAssertNil(r.filename)
    XCTAssertNil(r.directoryOverride)
    XCTAssertEqual(r.format, "mov")
    XCTAssertEqual(r.codec, "hevc")
    XCTAssertEqual(r.bitrate, "auto")
    XCTAssertEqual(r.audioGainDb, 0.0)
    XCTAssertEqual(r.audioVolumePercent, 100.0)
    XCTAssertFalse(r.autoNormalizeOnExport)
    XCTAssertEqual(r.targetLoudnessDbfs, -16.0)
    XCTAssertNil(r.cameraPath)
  }

  func testFullyPopulated() {
    let r = ExportVideoRequest.fromFlutter([
      "projectPath": "/proj", "layoutPreset": "16:9", "resolutionPreset": "1080p",
      "fitMode": "crop", "padding": 12.0, "cornerRadius": 8.0, "backgroundColor": 0x11_22_33,
      "backgroundImagePath": "/bg.png", "cursorSize": 2.0, "zoomFactor": 3.0,
      "zoomEffectEnabled": true, "showCursor": false, "filename": "out", "directoryOverride": "/d",
      "format": "mp4", "codec": "h264", "bitrate": "high", "audioGainDb": -3.0,
      "audioVolumePercent": 80.0, "autoNormalizeOnExport": true, "targetLoudnessDbfs": -14.0,
      "cameraPath": "/cam.mov",
    ])!
    XCTAssertEqual(r.layout, "16:9")
    XCTAssertEqual(r.resolution, "1080p")
    XCTAssertEqual(r.fit, "crop")
    XCTAssertEqual(r.padding, 12.0)
    XCTAssertEqual(r.cornerRadius, 8.0)
    XCTAssertEqual(r.backgroundColor, 0x11_22_33)
    XCTAssertEqual(r.backgroundImagePath, "/bg.png")
    XCTAssertEqual(r.cursorSize, 2.0)
    XCTAssertEqual(r.zoomFactor, 3.0)
    XCTAssertFalse(r.showCursor)
    XCTAssertEqual(r.filename, "out")
    XCTAssertEqual(r.directoryOverride, "/d")
    XCTAssertEqual(r.format, "mp4")
    XCTAssertEqual(r.codec, "h264")
    XCTAssertEqual(r.bitrate, "high")
    XCTAssertEqual(r.audioGainDb, -3.0)
    XCTAssertEqual(r.audioVolumePercent, 80.0)
    XCTAssertTrue(r.autoNormalizeOnExport)
    XCTAssertEqual(r.targetLoudnessDbfs, -14.0)
    XCTAssertEqual(r.cameraPath, "/cam.mov")
  }

  // The zoom-effect derivation contract is load-bearing — pin every branch.
  func testZoomContractExplicitlyDisabledOverridesHighRawFactor() {
    let r = ExportVideoRequest.fromFlutter([
      "projectPath": "/p", "zoomFactor": 2.5, "zoomEffectEnabled": false,
    ])!
    XCTAssertEqual(r.rawZoomFactor, 2.5)
    XCTAssertFalse(r.zoomEffectEnabled)
    XCTAssertEqual(r.zoomFactor, 1.0)
  }

  func testZoomContractExplicitlyEnabledWithUnityRaw() {
    let r = ExportVideoRequest.fromFlutter([
      "projectPath": "/p", "zoomFactor": 1.0, "zoomEffectEnabled": true,
    ])!
    XCTAssertTrue(r.zoomEffectEnabled)
    XCTAssertEqual(r.zoomFactor, 1.0)
  }

  func testZoomContractLegacyFallbackBelowUnityIsDisabled() {
    let r = ExportVideoRequest.fromFlutter(["projectPath": "/p", "zoomFactor": 1.0])!
    XCTAssertFalse(r.zoomEffectEnabled)  // 1.0 is not > 1.0
    XCTAssertEqual(r.zoomFactor, 1.0)
  }
}

final class PreviewSceneRequestParsingTests: XCTestCase {
  func testNilWhenProjectPathMissing() {
    XCTAssertNil(PreviewSceneRequest.fromFlutter(nil))
    XCTAssertNil(PreviewSceneRequest.fromFlutter([:]))
  }

  func testDefaultsWithOnlyProjectPath() {
    let r = PreviewSceneRequest.fromFlutter(["projectPath": "/p"])!
    XCTAssertEqual(r.layout, "auto")
    XCTAssertEqual(r.resolution, "auto")
    XCTAssertEqual(r.fit, "fit")
    XCTAssertEqual(r.padding, 0.0)
    XCTAssertEqual(r.cornerRadius, 0.0)
    XCTAssertNil(r.backgroundColor)
    XCTAssertEqual(r.cursorSize, 1.0)
    XCTAssertEqual(r.rawZoomFactor, 1.5)
    XCTAssertEqual(r.zoomFactor, 1.5)
    XCTAssertTrue(r.showCursor)
    XCTAssertEqual(r.cameraPreviewChangeKind, .none)
    XCTAssertEqual(r.format, "mov")
    XCTAssertEqual(r.codec, "hevc")
    XCTAssertEqual(r.bitrate, "auto")
    XCTAssertEqual(r.audioGainDb, 0.0)
    XCTAssertEqual(r.audioVolumePercent, 100.0)
    XCTAssertNil(r.sessionId)
    XCTAssertNil(r.cameraPath)
  }

  func testInvalidCameraPreviewChangeKindFallsBackToNone() {
    let r = PreviewSceneRequest.fromFlutter([
      "projectPath": "/p", "cameraPreviewChangeKind": "not-a-real-kind",
    ])!
    XCTAssertEqual(r.cameraPreviewChangeKind, .none)
  }

  func testSessionAndCameraPathAndZoomDisabled() {
    let r = PreviewSceneRequest.fromFlutter([
      "projectPath": "/p", "sessionId": "s9", "cameraPath": "/c.mov",
      "zoomFactor": 4.0, "zoomEffectEnabled": false,
    ])!
    XCTAssertEqual(r.sessionId, "s9")
    XCTAssertEqual(r.cameraPath, "/c.mov")
    XCTAssertEqual(r.rawZoomFactor, 4.0)
    XCTAssertEqual(r.zoomFactor, 1.0)
  }
}
