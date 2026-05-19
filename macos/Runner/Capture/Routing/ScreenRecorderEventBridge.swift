import FlutterMacOS
import Foundation

/// Owns the facade → Flutter event-callback wiring that was previously inlined
/// in MainFlutterWindow.awakeFromNib (Slice 2 / PR 6 of the strangler
/// refactor). This is a verbatim move of the *pure forwarding* callbacks:
/// device-change / mic-level (via AudioDevicesEventHandler), indicator taps and
/// cameraOverlayMoved (via the method channel), and the recording-lifecycle
/// workflow events (via the injected emit closure).
///
/// The two MainFlutterWindow-UI-coupled callbacks — `onRecordingStateChanged`
/// (menu bar + native UI visibility) and `onAreaSelectionCleared`
/// (pre-recording bar state) — intentionally remain wired in MainFlutterWindow
/// per the plan ("MenuBar/PreRecordingBar wiring stays").
///
/// Closure bodies and payload maps are byte-identical to the originals;
/// `[weak self]` (the bridge, whose lifetime equals MainFlutterWindow's)
/// preserves the previous `[weak self]` (the window) no-op-after-dealloc
/// semantics. Engine-domain forwarding shape (see windows-port-inventory §7).
///
/// `@MainActor` because the facade's callback properties are main-actor
/// isolated and binding happens from `awakeFromNib` (main), exactly as the
/// inline wiring did.
@MainActor
final class ScreenRecorderEventBridge {
  private weak var facade: ScreenRecorderFacade?
  private let eventHandler: AudioDevicesEventHandler
  private let channel: FlutterMethodChannel?
  private let emitWorkflowEvent: ([String: Any]) -> Void

  init(
    facade: ScreenRecorderFacade,
    eventHandler: AudioDevicesEventHandler,
    channel: FlutterMethodChannel?,
    emitWorkflowEvent: @escaping ([String: Any]) -> Void
  ) {
    self.facade = facade
    self.eventHandler = eventHandler
    self.channel = channel
    self.emitWorkflowEvent = emitWorkflowEvent
  }

  func bind() {
    guard let facade else { return }

    // Fire audio/video device changes
    facade.onDevicesChanged = { [weak self] in
      self?.eventHandler.fireAudioSourcesChanged()
    }
    facade.onVideoDevicesChanged = { [weak self] in
      self?.eventHandler.fireVideoSourcesChanged()
    }
    facade.onMicrophoneLevel = { [weak self] sample in
      self?.eventHandler.fireMicrophoneLevel(
        linear: sample.linear,
        dbfs: sample.dbfs,
        isLow: sample.isLow
      )
    }
    facade.onIndicatorPauseTapped = { [weak self] in
      self?.channel?.invokeMethod(NativeToFlutterMethod.indicatorPauseTapped, arguments: nil)
    }
    facade.onIndicatorStopTapped = { [weak self] in
      self?.channel?.invokeMethod(NativeToFlutterMethod.indicatorStopTapped, arguments: nil)
    }
    facade.onIndicatorResumeTapped = { [weak self] in
      self?.channel?.invokeMethod(NativeToFlutterMethod.indicatorResumeTapped, arguments: nil)
    }

    // Mirror external recording lifecycle changes back to Flutter.
    facade.onRecordingStarted = { [weak self] sessionId in
      NativeLogger.d("Recording", "Recording started callback from facade")
      self?.emitWorkflowEvent([
        "type": "recordingStarted",
        "sessionId": sessionId,
      ])
    }
    facade.onRecordingPaused = { [weak self] sessionId in
      self?.emitWorkflowEvent([
        "type": "recordingPaused",
        "sessionId": sessionId,
      ])
    }
    facade.onRecordingResumed = { [weak self] sessionId in
      self?.emitWorkflowEvent([
        "type": "recordingResumed",
        "sessionId": sessionId,
      ])
    }
    facade.onRecordingFinalized = { [weak self] sessionId, projectPath in
      NativeLogger.d(
        "Recording", "Recording finalized callback from facade. Project: \(projectPath)")
      self?.emitWorkflowEvent([
        "type": "recordingFinalized",
        "sessionId": sessionId,
        "projectPath": projectPath,
      ])
    }
    facade.onRecordingFailed = { [weak self] payload in
      self?.emitWorkflowEvent(payload)
    }
    facade.onRecordingWarning = { [weak self] payload in
      self?.emitWorkflowEvent(payload)
    }
    facade.onCameraOverlayMoved = { [weak self] payload in
      self?.channel?.invokeMethod(NativeToFlutterMethod.cameraOverlayMoved, arguments: payload)
    }
  }
}
