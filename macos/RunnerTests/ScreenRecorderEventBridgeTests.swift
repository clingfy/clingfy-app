import FlutterMacOS
import XCTest

@testable import Clingfy

/// PR 6 guard: ScreenRecorderEventBridge.bind() must install the
/// recording-lifecycle callbacks so they forward byte-identical payloads to the
/// injected workflow-event emitter — exactly what MainFlutterWindow did inline.
/// Side-effect-free: no real recording; we invoke the installed closures
/// directly and capture the emitted payloads.
@MainActor
final class ScreenRecorderEventBridgeTests: XCTestCase {

  func testLifecycleCallbacksForwardIdenticalWorkflowPayloads() {
    let facade = ScreenRecorderFacade()
    var emitted: [[String: Any]] = []
    let bridge = ScreenRecorderEventBridge(
      facade: facade,
      eventHandler: AudioDevicesEventHandler(),
      channel: nil,
      emitWorkflowEvent: { emitted.append($0) }
    )

    bridge.bind()

    facade.onRecordingStarted?("s1")
    facade.onRecordingPaused?("s2")
    facade.onRecordingResumed?("s3")
    facade.onRecordingFinalized?("s4", "/proj/path")
    facade.onRecordingFailed?(["type": "recordingFailed", "code": "boom"])
    facade.onRecordingWarning?(["type": "recordingWarning", "message": "careful"])

    XCTAssertEqual(emitted.count, 6)
    XCTAssertEqual(emitted[0]["type"] as? String, "recordingStarted")
    XCTAssertEqual(emitted[0]["sessionId"] as? String, "s1")
    XCTAssertEqual(emitted[1]["type"] as? String, "recordingPaused")
    XCTAssertEqual(emitted[1]["sessionId"] as? String, "s2")
    XCTAssertEqual(emitted[2]["type"] as? String, "recordingResumed")
    XCTAssertEqual(emitted[2]["sessionId"] as? String, "s3")
    XCTAssertEqual(emitted[3]["type"] as? String, "recordingFinalized")
    XCTAssertEqual(emitted[3]["sessionId"] as? String, "s4")
    XCTAssertEqual(emitted[3]["projectPath"] as? String, "/proj/path")
    XCTAssertEqual(emitted[4]["type"] as? String, "recordingFailed")
    XCTAssertEqual(emitted[4]["code"] as? String, "boom")
    XCTAssertEqual(emitted[5]["type"] as? String, "recordingWarning")
    XCTAssertEqual(emitted[5]["message"] as? String, "careful")
  }

  func testBindInstallsForwardingCallbacks() {
    let facade = ScreenRecorderFacade()
    let bridge = ScreenRecorderEventBridge(
      facade: facade,
      eventHandler: AudioDevicesEventHandler(),
      channel: nil,
      emitWorkflowEvent: { _ in }
    )

    XCTAssertNil(facade.onRecordingStarted)
    XCTAssertNil(facade.onDevicesChanged)

    bridge.bind()

    XCTAssertNotNil(facade.onRecordingStarted)
    XCTAssertNotNil(facade.onRecordingFinalized)
    XCTAssertNotNil(facade.onDevicesChanged)
    XCTAssertNotNil(facade.onVideoDevicesChanged)
    XCTAssertNotNil(facade.onMicrophoneLevel)
    XCTAssertNotNil(facade.onIndicatorPauseTapped)
    XCTAssertNotNil(facade.onIndicatorStopTapped)
    XCTAssertNotNil(facade.onIndicatorResumeTapped)
    XCTAssertNotNil(facade.onCameraOverlayMoved)
  }
}
