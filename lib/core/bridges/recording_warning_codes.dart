/// Machine-readable codes carried by Windows `recordingWarning` events
/// (Phase 10.2).
///
/// Keep this list in sync with the emitter documentation in
/// `windows/runner/Bridge/workflow_event_publisher.h`. macOS warnings never
/// carry a code (macOS localizes natively before emitting); a warning with
/// no/unknown code renders its `message` verbatim — the legacy behavior.
class RecordingWarningCode {
  RecordingWarningCode._();

  static const String micOpenFailed = 'MIC_OPEN_FAILED';
  static const String micDisconnected = 'MIC_DISCONNECTED';
  static const String systemAudioOpenFailed = 'SYSTEM_AUDIO_OPEN_FAILED';
  static const String systemAudioStopped = 'SYSTEM_AUDIO_STOPPED';
  static const String cameraUnavailable = 'CAMERA_UNAVAILABLE';
  static const String cameraOpenFailed = 'CAMERA_OPEN_FAILED';
  static const String cameraDisconnected = 'CAMERA_DISCONNECTED';
  static const String cameraPreviewHidden = 'CAMERA_PREVIEW_HIDDEN';
  static const String encoderVideoError = 'ENCODER_VIDEO_ERROR';
  static const String encoderAudioError = 'ENCODER_AUDIO_ERROR';
  static const String windowClosedPartialSaved = 'WINDOW_CLOSED_PARTIAL_SAVED';
  static const String displayDisconnectedPartialSaved =
      'DISPLAY_DISCONNECTED_PARTIAL_SAVED';
}
