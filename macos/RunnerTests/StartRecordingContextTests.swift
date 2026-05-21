import CoreGraphics
import XCTest

@testable import Clingfy

/// Slice 9 / PR 33b guard: `StartRecordingContext.from(...)` is the typed
/// snapshot the facade builds at the top of `startRecording`. These tests
/// pin the factory mapping — args parsing (with the same defaults the old
/// inline parse used), preference reads, and verbatim pass-through of the
/// facade-private `effective*` values + the request + selection fields.
@MainActor
final class StartRecordingContextTests: XCTestCase {

  private let request = StartRecordingRequest(
    sessionId: "session-1",
    disableMicrophone: true,
    disableCameraOverlay: false,
    disableCursorHighlight: true,
    allowLowStorageBypass: true)

  // MARK: - args parsing

  func testFromParsesFrameRateAndSystemAudioFromArgs() {
    let context = makeContext(args: ["frameRate": 24, "systemAudioEnabled": true])
    XCTAssertEqual(context.frameRate, 24)
    XCTAssertTrue(context.systemAudioEnabled)
  }

  func testFromDefaultsFrameRate60AndSystemAudioFalseWhenArgsNil() {
    let context = makeContext(args: nil)
    XCTAssertEqual(context.frameRate, 60)
    XCTAssertFalse(context.systemAudioEnabled)
  }

  func testFromDefaultsFrameRate60AndSystemAudioFalseWhenKeysMissing() {
    let context = makeContext(args: ["unrelated": 1])
    XCTAssertEqual(context.frameRate, 60)
    XCTAssertFalse(context.systemAudioEnabled)
  }

  // MARK: - pass-through

  func testFromPassesThroughRequestAndSelection() {
    let context = makeContext(
      args: nil, selectedDisplayID: 7, selectedAppWindowID: 99)
    XCTAssertEqual(context.request, request)
    XCTAssertEqual(context.selectedDisplayID, 7)
    XCTAssertEqual(context.selectedAppWindowID, 99)
  }

  func testFromPassesThroughEffectiveValuesVerbatim() {
    let context = makeContext(
      args: nil,
      effectiveOverlayEnabledForRecording: true,
      effectiveCursorEnabledForRecording: false,
      effectiveCameraCaptureModeForRecording: .separateCameraAsset,
      shouldRecordSeparateCameraAsset: true)
    XCTAssertTrue(context.effectiveOverlayEnabledForRecording)
    XCTAssertFalse(context.effectiveCursorEnabledForRecording)
    XCTAssertEqual(context.effectiveCameraCaptureModeForRecording, .separateCameraAsset)
    XCTAssertTrue(context.shouldRecordSeparateCameraAsset)
  }

  // MARK: - preference reads

  func testFromMapsPreferenceValues() {
    let prefs = PreferencesStore()
    let originalDisplayMode = prefs.displayMode
    let originalQuality = prefs.recordingQuality
    let originalCursorLinked = prefs.cursorLinked
    let originalExclude = prefs.excludeRecorderApp
    let originalOverlayMirror = prefs.overlayMirror
    let originalOverlayLinked = prefs.overlayLinked
    let originalVideoDeviceId = prefs.videoDeviceId
    let originalAudioDeviceId = prefs.audioDeviceId
    defer {
      prefs.displayMode = originalDisplayMode
      prefs.recordingQuality = originalQuality
      prefs.cursorLinked = originalCursorLinked
      prefs.excludeRecorderApp = originalExclude
      prefs.overlayMirror = originalOverlayMirror
      prefs.overlayLinked = originalOverlayLinked
      prefs.videoDeviceId = originalVideoDeviceId
      prefs.audioDeviceId = originalAudioDeviceId
    }

    prefs.displayMode = .singleAppWindow
    prefs.recordingQuality = .fhd
    prefs.cursorLinked = true
    prefs.excludeRecorderApp = true
    prefs.overlayMirror = true
    prefs.overlayLinked = false
    prefs.videoDeviceId = "video-7"
    prefs.audioDeviceId = "audio-3"

    let context = StartRecordingContext.from(
      request: request,
      args: nil,
      prefs: prefs,
      selectedDisplayID: nil,
      selectedAppWindowID: nil,
      effectiveOverlayEnabledForRecording: false,
      effectiveCursorEnabledForRecording: false,
      effectiveCameraCaptureModeForRecording: .separateCameraAsset,
      shouldRecordSeparateCameraAsset: false)

    XCTAssertEqual(context.displayMode, .singleAppWindow)
    XCTAssertEqual(context.recordingQuality, .fhd)
    XCTAssertTrue(context.cursorLinked)
    XCTAssertTrue(context.excludeRecorderApp)
    XCTAssertTrue(context.overlayMirror)
    XCTAssertFalse(context.overlayLinked)
    XCTAssertEqual(context.videoDeviceId, "video-7")
    XCTAssertEqual(context.audioDeviceId, "audio-3")
  }

  // MARK: - Helpers

  private func makeContext(
    args: [String: Any]?,
    selectedDisplayID: CGDirectDisplayID? = nil,
    selectedAppWindowID: CGWindowID? = nil,
    effectiveOverlayEnabledForRecording: Bool = false,
    effectiveCursorEnabledForRecording: Bool = false,
    effectiveCameraCaptureModeForRecording: CameraCaptureMode = .separateCameraAsset,
    shouldRecordSeparateCameraAsset: Bool = false
  ) -> StartRecordingContext {
    StartRecordingContext.from(
      request: request,
      args: args,
      prefs: PreferencesStore(),
      selectedDisplayID: selectedDisplayID,
      selectedAppWindowID: selectedAppWindowID,
      effectiveOverlayEnabledForRecording: effectiveOverlayEnabledForRecording,
      effectiveCursorEnabledForRecording: effectiveCursorEnabledForRecording,
      effectiveCameraCaptureModeForRecording: effectiveCameraCaptureModeForRecording,
      shouldRecordSeparateCameraAsset: shouldRecordSeparateCameraAsset)
  }
}
