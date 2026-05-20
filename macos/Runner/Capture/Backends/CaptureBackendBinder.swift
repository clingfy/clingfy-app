import FlutterMacOS
import Foundation

/// Slice 6 / PR 22: handler surface that `CaptureBackendBinder` wires the
/// backend's 6 callback slots into. Today the only implementer is
/// `ScreenRecorderFacade`; a future `RecordingSessionCoordinator`
/// (Slice 7+) can take ownership without changing the binding mechanism.
///
/// `@MainActor` because every callback the backend fires arrives on the main
/// queue (both `CaptureBackendAVFoundation` and
/// `CaptureBackendScreenCaptureKit` post their callbacks via
/// `runOnMainIfNeeded` internally; the facade has always treated them as
/// main-actor).
@MainActor
protocol CaptureBackendEventHandling: AnyObject {
  func backendDidReportMicrophoneLevel(_ sample: MicrophoneLevelSample)
  func backendDidWarn(message: String)
  func backendDidStart(url: URL)
  func backendDidPause()
  func backendDidResume()
  func backendDidFinish(url: URL?, error: Error?)
}

/// Slice 6 / PR 22: stateless binder that attaches a handler's methods to
/// the 6 callback slots on a `CaptureBackend`. Extracts the callback-
/// attachment block (lines 2513-2764) of the old
/// `ScreenRecorderFacade.setCaptureBackend(_:)`.
///
/// The binder owns no state and does NOT touch `self.capture`,
/// `resetOverlayUpdateDeduper()`, or any other side effect that previously
/// ran inside `setCaptureBackend`. Those stay on the facade. The binder
/// just routes events.
///
/// The handler is captured `weak` inside each closure so the binder does
/// not keep the facade alive. Calling `bind(_:to:)` on a backend whose
/// callbacks were previously set overwrites them — matches the original
/// behavior when the facade rebinds after a backend swap (e.g. the
/// ScreenCaptureKit → AVFoundation fallback path).
///
/// Engine-domain; see `windows-port-inventory.md` §7.
@MainActor
struct CaptureBackendBinder {
  func bind(_ backend: CaptureBackend, to handler: CaptureBackendEventHandling) {
    backend.onMicrophoneLevel = { [weak handler] sample in
      handler?.backendDidReportMicrophoneLevel(sample)
    }
    backend.onWarning = { [weak handler] message in
      handler?.backendDidWarn(message: message)
    }
    backend.onStarted = { [weak handler] url in
      handler?.backendDidStart(url: url)
    }
    backend.onPaused = { [weak handler] in
      handler?.backendDidPause()
    }
    backend.onResumed = { [weak handler] in
      handler?.backendDidResume()
    }
    backend.onFinished = { [weak handler] url, error in
      handler?.backendDidFinish(url: url, error: error)
    }
  }
}
