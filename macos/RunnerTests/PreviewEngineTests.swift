import CoreGraphics
import FlutterMacOS
import XCTest

@testable import Clingfy

/// Slice 8 / PR 28 guard: input-validation early returns for
/// `PreviewEngine.processVideo(...)` + the `setAudioGainDb` →
/// `setAudioMix` delegation. The happy path of `processVideo` dispatches
/// to the global `updateActiveInlinePreviewScene` /
/// `routePreviewSceneRequest` helpers in `InlinePreviewViewFactory.swift`
/// — those are exercised by `PreviewProfileTests` /
/// `InlinePreviewViewLayoutTests`. Here we pin what the engine itself
/// owns end-to-end without the inline view present.
@MainActor
final class PreviewEngineTests: XCTestCase {

  private func makeAnyInput(projectPath: String = "/tmp/nope")
    -> PreviewEngine.ProcessVideoInput
  {
    PreviewEngine.ProcessVideoInput(
      projectPath: projectPath,
      layout: "auto",
      resolution: "auto",
      fit: "fit",
      padding: 0,
      cornerRadius: 0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      zoomFactor: 1.0,
      showCursor: true,
      audioGainDb: 0,
      audioVolumePercent: 100,
      zoomSegments: nil,
      cameraPreviewChangeKind: .none,
      sessionId: nil,
      cameraPath: nil,
      cameraParams: nil)
  }

  private func makeDeps(
    resolvePreviewMediaSources: @escaping (String, String?) -> PreviewMediaSources? = { _, _ in nil }
  ) -> PreviewEngine.ProcessVideoDependencies {
    .init(
      resolvePreviewMediaSources: resolvePreviewMediaSources,
      resolveTargetSize: { src, _, _ in src },
      defaultZoomFollowStrength: 0.15)
  }

  // MARK: - processVideo input validation

  func testProcessVideoReturnsPROCESSINPUTMISSINGWhenMediaSourcesNil() {
    let engine = PreviewEngine()
    var resolverProbed: (String, String?)?
    let exp = expectation(description: "result")
    var receivedError: FlutterError?

    engine.processVideo(
      input: makeAnyInput(projectPath: "/tmp/missing"),
      dependencies: makeDeps { path, explicitCameraPath in
        resolverProbed = (path, explicitCameraPath)
        return nil
      }
    ) { res in
      receivedError = res as? FlutterError
      exp.fulfill()
    }

    wait(for: [exp], timeout: 1)
    XCTAssertEqual(resolverProbed?.0, "/tmp/missing")
    XCTAssertNil(resolverProbed?.1, "no cameraPath was supplied — resolver must see nil")
    XCTAssertEqual(receivedError?.code, "PROCESS_INPUT_MISSING")
    XCTAssertEqual(receivedError?.details as? String, "/tmp/missing")
    XCTAssertEqual(
      receivedError?.message,
      "Recording project not found. It may have been moved or deleted.")
  }

  func testProcessVideoForwardsExplicitCameraPathToResolver() {
    let engine = PreviewEngine()
    var resolverProbed: (String, String?)?

    var input = makeAnyInput(projectPath: "/tmp/whatever")
    input = PreviewEngine.ProcessVideoInput(
      projectPath: input.projectPath,
      layout: input.layout,
      resolution: input.resolution,
      fit: input.fit,
      padding: input.padding,
      cornerRadius: input.cornerRadius,
      backgroundColor: input.backgroundColor,
      backgroundImagePath: input.backgroundImagePath,
      cursorSize: input.cursorSize,
      zoomFactor: input.zoomFactor,
      showCursor: input.showCursor,
      audioGainDb: input.audioGainDb,
      audioVolumePercent: input.audioVolumePercent,
      zoomSegments: input.zoomSegments,
      cameraPreviewChangeKind: input.cameraPreviewChangeKind,
      sessionId: input.sessionId,
      cameraPath: "/tmp/explicit-camera.mov",
      cameraParams: input.cameraParams)

    engine.processVideo(
      input: input,
      dependencies: makeDeps { path, explicitCameraPath in
        resolverProbed = (path, explicitCameraPath)
        return nil
      }
    ) { _ in }

    XCTAssertEqual(resolverProbed?.1, "/tmp/explicit-camera.mov")
  }

  // MARK: - setAudioGainDb is a setAudioMix wrapper at volumePercent = 100

  func testSetAudioGainDbDelegatesToSetAudioMixAt100Percent() {
    // Without the inline preview view present, both methods should
    // simply call updateActiveInlinePreviewAudioMixOverride and return
    // nil. We can't easily observe the override side-effect from here,
    // but we CAN observe that:
    //   - the call doesn't throw
    //   - the result fires with nil
    //   - identical behavior to setAudioMix with volumePercent = 100
    //
    // The actual volume = 100 wiring is also verified by reading the
    // engine source — the wrapper passes audioVolumePercent: 100.0
    // verbatim. Black-box symmetry test below.
    let engine = PreviewEngine()
    let gainExp = expectation(description: "gain")
    let mixExp = expectation(description: "mix")
    var gainResult: Any?
    var mixResult: Any?

    engine.setAudioGainDb(audioGainDb: 5.5) { res in
      gainResult = res
      gainExp.fulfill()
    }
    engine.setAudioMix(sessionId: nil, audioGainDb: 5.5, audioVolumePercent: 100.0) { res in
      mixResult = res
      mixExp.fulfill()
    }

    wait(for: [gainExp, mixExp], timeout: 1)
    // Both paths return nil when no inline view is active.
    XCTAssertNil(gainResult)
    XCTAssertNil(mixResult)
  }

  // MARK: - setAudioMix clamps inputs

  func testSetAudioMixDoesNotCrashOnExtremeInputs() {
    // Clamping is internal; we can't directly observe the clamped values
    // here without a live inline view. Pinning that the engine doesn't
    // crash on out-of-range values (which feed `max(0, min(24, ...))` +
    // `max(0, min(100, ...))`) is the floor.
    let engine = PreviewEngine()
    let exp = expectation(description: "result")
    engine.setAudioMix(
      sessionId: nil,
      audioGainDb: -100,  // clamps to 0
      audioVolumePercent: 999  // clamps to 100
    ) { _ in
      exp.fulfill()
    }
    wait(for: [exp], timeout: 1)
  }

  // MARK: - setCameraPlacement returns nil without inline view

  func testSetCameraPlacementReturnsNilWhenNoInlineView() {
    // No inline view active in tests; the early-return branch yields nil.
    let engine = PreviewEngine()
    let exp = expectation(description: "result")
    var received: Any? = "non-nil-sentinel"

    engine.setCameraPlacement(
      sessionId: nil,
      cameraPreviewChangeKind: .none,
      cameraParams: nil
    ) { res in
      received = res
      exp.fulfill()
    }

    wait(for: [exp], timeout: 1)
    XCTAssertNil(received)
  }
}
