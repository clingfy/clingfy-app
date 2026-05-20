import FlutterMacOS
import Foundation
import XCTest

@testable import Clingfy

/// Slice 6 / PR 22 guard: `CaptureBackendBinder.bind(_:to:)` wires every one
/// of the 6 backend callback slots into the matching protocol method,
/// preserves the in-firing order set by the backend, and holds the handler
/// weakly so the binder can never leak the facade.
@MainActor
final class CaptureBackendBinderTests: XCTestCase {

  // MARK: - Test doubles

  /// A `CaptureBackend` that exists only to hold the 6 callback slots so the
  /// binder has something to write into. The remaining surface members are
  /// satisfied with no-op stubs and inert defaults so the type conforms.
  private final class FakeBackend: CaptureBackend {
    var isRecording: Bool = false
    var isPaused: Bool = false
    var currentOutputURL: URL? = nil
    var canPauseResume: Bool = false
    var supportsLiveOverlayExclusionDuringSeparateCameraCapture: Bool = false

    func start(config: CaptureStartConfig) {}
    func stop() {}
    func pause() {}
    func resume() {}
    func updateOverlay(windowID: CGWindowID?) {}

    // Callback slots — the only members the binder writes to.
    var onStarted: ((URL) -> Void)?
    var onFinished: ((URL?, Error?) -> Void)?
    var onPaused: (() -> Void)?
    var onResumed: (() -> Void)?
    var onWarning: ((String) -> Void)?
    var onMicrophoneLevel: ((MicrophoneLevelSample) -> Void)?
  }

  /// Records every event the binder routes to it (in firing order) so tests
  /// can assert sequencing + payload pass-through. `MicrophoneLevelSample`
  /// is not `Equatable`, so the event stores the sample's `linear` value
  /// instead — sufficient to prove the payload was forwarded unchanged.
  private final class RecordingHandler: CaptureBackendEventHandling {
    enum Event: Equatable {
      case micLevel(linear: Double, dbfs: Double)
      case warn(message: String)
      case start(url: URL)
      case paused
      case resumed
      case finished(url: URL?, errorMessage: String?)
    }
    private(set) var events: [Event] = []
    func backendDidReportMicrophoneLevel(_ sample: MicrophoneLevelSample) {
      events.append(.micLevel(linear: sample.linear, dbfs: sample.dbfs))
    }
    func backendDidWarn(message: String) { events.append(.warn(message: message)) }
    func backendDidStart(url: URL) { events.append(.start(url: url)) }
    func backendDidPause() { events.append(.paused) }
    func backendDidResume() { events.append(.resumed) }
    func backendDidFinish(url: URL?, error: Error?) {
      let msg: String?
      if let f = error as? FlutterError {
        msg = f.message ?? f.code
      } else if let e = error {
        msg = e.localizedDescription
      } else {
        msg = nil
      }
      events.append(.finished(url: url, errorMessage: msg))
    }
  }

  // MARK: - Tests

  func testAllSixCallbackSlotsAreAttachedAfterBind() {
    let backend = FakeBackend()
    let handler = RecordingHandler()
    CaptureBackendBinder().bind(backend, to: handler)

    XCTAssertNotNil(backend.onMicrophoneLevel)
    XCTAssertNotNil(backend.onWarning)
    XCTAssertNotNil(backend.onStarted)
    XCTAssertNotNil(backend.onPaused)
    XCTAssertNotNil(backend.onResumed)
    XCTAssertNotNil(backend.onFinished)
  }

  func testBackendFiringSequenceFlowsThroughInOrderWithPayloads() {
    let backend = FakeBackend()
    let handler = RecordingHandler()
    CaptureBackendBinder().bind(backend, to: handler)

    let sample = MicrophoneLevelSample(linear: 0.5, dbfs: -12)
    let startURL = URL(fileURLWithPath: "/tmp/start.mov")
    let finishURL = URL(fileURLWithPath: "/tmp/finish.mov")

    // Backend posts events in a representative order.
    backend.onStarted?(startURL)
    backend.onMicrophoneLevel?(sample)
    backend.onWarning?("close to disk full")
    backend.onPaused?()
    backend.onResumed?()
    backend.onFinished?(finishURL, nil)

    XCTAssertEqual(
      handler.events,
      [
        .start(url: startURL),
        .micLevel(linear: 0.5, dbfs: -12),
        .warn(message: "close to disk full"),
        .paused,
        .resumed,
        .finished(url: finishURL, errorMessage: nil),
      ])
  }

  func testFinishedPropagatesErrorThroughTheBoundary() {
    let backend = FakeBackend()
    let handler = RecordingHandler()
    CaptureBackendBinder().bind(backend, to: handler)

    let err = FlutterError(code: "RECORDING_ERROR", message: "boom", details: nil)
    backend.onFinished?(nil, err)

    XCTAssertEqual(handler.events, [.finished(url: nil, errorMessage: "boom")])
  }

  func testRebindReplacesPreviousCallbacks() {
    // Matches the original setCaptureBackend behavior on the SCK → AVF
    // fallback path: rebinding a backend overwrites any callbacks the
    // previous bind set.
    let backend = FakeBackend()
    let firstHandler = RecordingHandler()
    let secondHandler = RecordingHandler()
    let binder = CaptureBackendBinder()

    binder.bind(backend, to: firstHandler)
    binder.bind(backend, to: secondHandler)

    backend.onPaused?()

    XCTAssertEqual(firstHandler.events, [], "first handler should no longer receive events")
    XCTAssertEqual(secondHandler.events, [.paused])
  }

  func testHandlerIsHeldWeaklyByBoundCallbacks() {
    let backend = FakeBackend()
    weak var weakHandler: RecordingHandler?
    do {
      let handler = RecordingHandler()
      weakHandler = handler
      CaptureBackendBinder().bind(backend, to: handler)
      XCTAssertNotNil(weakHandler, "handler should be alive while in scope")
    }
    // Handler went out of scope. If the binder's closures retained it, the
    // weak reference would still be non-nil. The whole point of `[weak
    // handler]` inside `bind(_:to:)` is to prevent the binder from keeping
    // the facade alive.
    XCTAssertNil(weakHandler, "binder must not retain handler")

    // The bound closures still exist on the backend; calling them after the
    // handler is gone must be a safe no-op (weak handler dereferences to nil).
    backend.onPaused?()
    backend.onMicrophoneLevel?(MicrophoneLevelSample(linear: 0, dbfs: -120))
    backend.onFinished?(nil, nil)
  }
}
