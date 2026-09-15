import Foundation

/// Whether this machine and this recording can produce captions, and if not,
/// exactly why.
///
/// Answered by native rather than inferred by the UI, for the same reason the
/// audio panel gates on `getRecordingSceneInfo` rather than on device lists:
/// native is the only side that knows what the hardware is, what the OS is, and
/// what is actually decodable on disk. A UI guessing at that gets it subtly
/// wrong and shows a button that fails.
///
/// Every unavailable case carries a machine-readable `reason` so the UI can show
/// one specific sentence. A generic "captions unavailable" turns each of these
/// into a support conversation, and several of them are things the user can fix
/// in seconds if told which one it is.
struct CaptionsCapability: Equatable {

  /// Why captions cannot run. Ordered by how the resolver checks them: platform
  /// facts first, because a Mac that cannot run the engine at all should say so
  /// rather than complaining about the recording.
  enum Reason: String {
    /// Below the engine's minimum macOS. Not reachable while the app's
    /// deployment target is at or above it, but kept so raising or lowering
    /// that floor cannot silently produce an unexplained failure.
    case unsupportedOS = "unsupportedOS"
    /// Intel. WhisperKit builds on x86_64 but there is no Neural Engine, so
    /// compute falls back to CPU+GPU. Distinct from a hard block on purpose —
    /// the honest message is "this will be slow", not "you cannot".
    case intelSlowPath = "intelSlowPath"
    /// The recording contains no decodable audio at all: no sidecars, and
    /// nothing usable embedded in screen.mov. There is nothing to transcribe.
    case noAudio = "noAudio"
    /// Windows. The engine is not ported. Reported as a reason rather than as a
    /// missing method, so the Windows UI shows an explanation instead of
    /// throwing MissingPluginException.
    case platformNotSupported = "platformNotSupported"
  }

  let isAvailable: Bool
  let reason: Reason?

  /// Which sources this specific recording has. Drives the source picker, and
  /// tells the UI when to hide it because there is only one choice.
  let hasMicAudio: Bool
  let hasSystemAudio: Bool

  /// True when neither sidecar exists but `screen.mov` carries usable audio.
  ///
  /// Captions still work; the UI should say what it can and cannot do, because
  /// on a pre-macOS-15 recording the embedded audio is the MICROPHONE ONLY —
  /// that capture backend never recorded system audio — so a meeting captured
  /// then has only one side of the conversation on disk, and no amount of
  /// transcription recovers the other.
  let usesEmbeddedAudioOnly: Bool

  static func unavailable(_ reason: Reason) -> CaptionsCapability {
    CaptionsCapability(
      isAvailable: false, reason: reason,
      hasMicAudio: false, hasSystemAudio: false, usesEmbeddedAudioOnly: false)
  }

  /// Decides capability from platform facts and what the project actually has.
  ///
  /// Pure so the whole decision table is testable without a machine, an OS
  /// version, or a recording.
  static func resolve(
    isAppleSilicon: Bool,
    meetsMinimumOS: Bool,
    hasDecodableMic: Bool,
    hasDecodableSystem: Bool,
    hasDecodableEmbedded: Bool
  ) -> CaptionsCapability {
    guard meetsMinimumOS else { return .unavailable(.unsupportedOS) }
    guard isAppleSilicon else { return .unavailable(.intelSlowPath) }

    let hasAnything = hasDecodableMic || hasDecodableSystem || hasDecodableEmbedded
    guard hasAnything else { return .unavailable(.noAudio) }

    return CaptionsCapability(
      isAvailable: true,
      reason: nil,
      hasMicAudio: hasDecodableMic,
      hasSystemAudio: hasDecodableSystem,
      // Only when there is nothing better. A recording with sidecars never
      // falls back, even if screen.mov also carries a premixed track.
      usesEmbeddedAudioOnly: !hasDecodableMic && !hasDecodableSystem && hasDecodableEmbedded
    )
  }

  /// The bridge payload.
  ///
  /// Keys are mirrored by the Dart side and by the Windows router; renaming one
  /// silently disables captions rather than failing loudly, so they are pinned
  /// by test on both sides.
  func toFlutter() -> [String: Any] {
    var payload: [String: Any] = [
      "available": isAvailable,
      "hasMicAudio": hasMicAudio,
      "hasSystemAudio": hasSystemAudio,
      "usesEmbeddedAudioOnly": usesEmbeddedAudioOnly,
    ]
    if let reason {
      payload["reason"] = reason.rawValue
    }
    return payload
  }

  /// The default source selection for this recording.
  ///
  /// Both when both exist — the owner's call, because meetings, demos and
  /// tutorials are the common case and both sides matter there. Otherwise
  /// whichever single source is present.
  var defaultUsesMic: Bool { hasMicAudio || usesEmbeddedAudioOnly }
  var defaultUsesSystem: Bool { hasSystemAudio }

  /// Whether the picker is worth showing at all. With one source there is no
  /// choice to make, and a dropdown with one entry is noise.
  var shouldOfferSourcePicker: Bool { hasMicAudio && hasSystemAudio }
}
