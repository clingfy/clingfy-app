import 'package:flutter/foundation.dart';

/// Why captions cannot run, as reported by native.
///
/// These are wire values, not messages: native sends a stable identifier and
/// Flutter localises it. A native-side string would ship one hardcoded English
/// sentence to an app that also ships Arabic and Romanian.
enum CaptionsUnavailableReason {
  /// Below the transcription engine's minimum macOS.
  unsupportedOs('unsupportedOS'),

  /// Intel Mac. The engine needs the Neural Engine, so subtitles are not
  /// available at all here.
  ///
  /// This comment used to say the opposite — that Intel fell back to a slow
  /// CPU path and the honest message was "this will take a while". It never
  /// did: the resolver returns `.unavailable`, and an Intel Mac gets no
  /// Generate button. That misreading reached users twice, as UI copy and as
  /// release notes, before the name was fixed.
  requiresAppleSilicon('requiresAppleSilicon'),

  /// The recording has no decodable audio at all. Nothing to transcribe.
  noAudio('noAudio'),

  /// Windows. The engine is not ported.
  platformNotSupported('platformNotSupported'),

  /// The probe itself failed — native raised rather than answering. Distinct
  /// from every other reason here because it may be transient and is the only
  /// one worth retrying: the reachable trigger today is `SCENE_INPUT_MISSING`,
  /// raised when the bundle cannot be read, which a moved or still-copying
  /// project produces and a second attempt can clear.
  ///
  /// Never sent by native — set on this side when the call throws.
  probeFailed('probeFailed'),

  /// Native sent something this build does not know. Treated as unavailable
  /// rather than crashing, so an older Flutter against a newer native binary
  /// degrades instead of throwing.
  unknown('unknown');

  const CaptionsUnavailableReason(this.wireValue);

  final String wireValue;

  static CaptionsUnavailableReason fromWire(String? value) {
    for (final reason in CaptionsUnavailableReason.values) {
      if (reason.wireValue == value) return reason;
    }
    return CaptionsUnavailableReason.unknown;
  }
}

/// What native says about captioning this machine and this recording.
///
/// Queried before the captions UI offers anything, mirroring how the audio
/// panel gates on `getRecordingSceneInfo` rather than guessing from device
/// lists. Native is the only side that knows the hardware, the OS, and what is
/// actually decodable on disk.
@immutable
class CaptionsCapabilityInfo {
  const CaptionsCapabilityInfo({
    required this.available,
    this.reason,
    this.hasMicAudio = false,
    this.languages = const [],
    this.hasSystemAudio = false,
    this.usesEmbeddedAudioOnly = false,
  });

  final bool available;
  final CaptionsUnavailableReason? reason;

  /// Whether this recording has a decodable `capture/mic.m4a`.
  final bool hasMicAudio;

  /// Every language the engine can decode, `(code, name)` sorted by name.
  ///
  /// Comes from the engine rather than a list held here, so it cannot drift
  /// from what the engine actually supports. Empty when the feature is
  /// unavailable, or on a build whose native half predates this.
  final List<CaptionLanguage> languages;

  /// Whether this recording has a decodable `capture/system.m4a`.
  final bool hasSystemAudio;

  /// True when neither sidecar exists but `screen.mov` carries usable audio.
  ///
  /// Captions still work, but the UI should say what it cannot do: on a
  /// recording made before macOS 15 the embedded audio is the **microphone
  /// only**, because that capture backend never recorded system audio. A
  /// meeting captured then has one side of the conversation on disk and no
  /// transcription recovers the other.
  final bool usesEmbeddedAudioOnly;

  /// Fallback for a native side that does not implement the probe at all.
  ///
  /// Should not happen — every platform returns a reason rather than leaving
  /// the method unhandled — but an unhandled method throws
  /// `MissingPluginException`, and captions being unavailable is a better
  /// outcome than an unhandled exception reaching the user.
  static const CaptionsCapabilityInfo unsupported = CaptionsCapabilityInfo(
    available: false,
    reason: CaptionsUnavailableReason.platformNotSupported,
  );

  /// The probe raised instead of answering.
  ///
  /// Separate from [unsupported] because "not supported on this platform" is a
  /// lie when the truth is that one call failed — and because this is the one
  /// unavailable state the user can do something about.
  static const CaptionsCapabilityInfo probeFailed = CaptionsCapabilityInfo(
    available: false,
    reason: CaptionsUnavailableReason.probeFailed,
  );

  factory CaptionsCapabilityInfo.fromMap(Map<dynamic, dynamic> map) {
    return CaptionsCapabilityInfo(
      available: map['available'] as bool? ?? false,
      reason: map['available'] as bool? ?? false
          ? null
          : CaptionsUnavailableReason.fromWire(map['reason'] as String?),
      hasMicAudio: map['hasMicAudio'] as bool? ?? false,
      languages: [
        for (final raw in (map['languages'] as List<dynamic>? ?? const []))
          if (raw is Map &&
              raw['code'] is String &&
              (raw['code'] as String).isNotEmpty)
            CaptionLanguage(
              code: raw['code'] as String,
              name: raw['name'] as String? ?? raw['code'] as String,
            ),
      ],
      hasSystemAudio: map['hasSystemAudio'] as bool? ?? false,
      usesEmbeddedAudioOnly: map['usesEmbeddedAudioOnly'] as bool? ?? false,
    );
  }

  /// Both sources on when both exist: meetings, demos and tutorials are the
  /// common case and both sides matter there.
  bool get defaultUsesMic => hasMicAudio || usesEmbeddedAudioOnly;
  bool get defaultUsesSystem => hasSystemAudio;

  /// A picker with one entry is noise.
  bool get shouldOfferSourcePicker => hasMicAudio && hasSystemAudio;

  @override
  bool operator ==(Object other) =>
      other is CaptionsCapabilityInfo &&
      other.available == available &&
      other.reason == reason &&
      other.hasMicAudio == hasMicAudio &&
      other.hasSystemAudio == hasSystemAudio &&
      other.usesEmbeddedAudioOnly == usesEmbeddedAudioOnly;

  @override
  int get hashCode => Object.hash(
    available,
    reason,
    hasMicAudio,
    hasSystemAudio,
    usesEmbeddedAudioOnly,
  );

  @override
  String toString() =>
      'CaptionsCapabilityInfo(available: $available, reason: $reason, '
      'mic: $hasMicAudio, system: $hasSystemAudio, '
      'embeddedOnly: $usesEmbeddedAudioOnly)';
}

/// One language the engine can decode.
class CaptionLanguage {
  const CaptionLanguage({required this.code, required this.name});

  /// Whisper code, e.g. `en`, `ar`, `ro`.
  final String code;

  /// The engine's own lowercase English name, e.g. `english`. Display casing
  /// is the UI's business.
  final String name;
}
