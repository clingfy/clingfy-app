import Foundation

/// Typed boundary DTO for the `startRecording` method-channel arguments.
///
/// `fromFlutter` reproduces *exactly* the inline parsing currently in
/// `ScreenRecorderFacade.startRecording` (same keys, same defaults, same
/// nil-handling). Introduced additively in Commit 2 of the strangler refactor;
/// the facade is wired to consume it in a later slice (it is not yet rewired,
/// so behavior is unchanged). Engine-domain DTO — Windows parses the same
/// `[String: Any]` surface (see windows-port-inventory §7).
struct StartRecordingRequest: Equatable {
  let sessionId: String?
  let disableMicrophone: Bool
  let disableCameraOverlay: Bool
  let disableCursorHighlight: Bool
  let allowLowStorageBypass: Bool

  static func fromFlutter(_ args: [String: Any]?) -> StartRecordingRequest {
    StartRecordingRequest(
      sessionId: args?["sessionId"] as? String,
      disableMicrophone: args?["disableMicrophone"] as? Bool ?? false,
      disableCameraOverlay: args?["disableCameraOverlay"] as? Bool ?? false,
      disableCursorHighlight: args?["disableCursorHighlight"] as? Bool ?? false,
      allowLowStorageBypass: args?["allowLowStorageBypass"] as? Bool ?? false
    )
  }
}
