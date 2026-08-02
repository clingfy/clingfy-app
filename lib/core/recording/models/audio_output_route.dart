/// The system's current default audio-output device, classified by whether it
/// can acoustically feed the microphone.
///
/// Mirrors `AudioOutputRoute` in `macos/Runner/Capture/Audio/AudioOutputRoute.swift`
/// — the `name` values are the wire format, so keep the two in sync.
///
/// This exists because speaker playback is the precondition for the
/// speaker -> mic bleed that makes a recording come back with a doubled,
/// delayed soundtrack. Recording system audio is safe on headphones and risky
/// on speakers, so the recorder warns before a take rather than leaving the
/// user to discover it in the export.
enum AudioOutputRoute {
  /// Built-in or external speakers — system audio is audible in the room, so it
  /// will bleed into any open microphone.
  speakers,

  /// Headphones or headset — no acoustic path from output back to the mic.
  headphones,

  /// Virtual/aggregate/loopback devices, or a platform that does not report the
  /// route. Never warns: these route digitally, and a false warning trains the
  /// user to ignore the real one.
  unknown;

  static AudioOutputRoute fromName(String? name) {
    switch (name) {
      case 'speakers':
        return AudioOutputRoute.speakers;
      case 'headphones':
        return AudioOutputRoute.headphones;
      default:
        return AudioOutputRoute.unknown;
    }
  }

  /// True when playing system audio can reach the microphone through the air.
  bool get bleedsIntoMicrophone => this == AudioOutputRoute.speakers;
}
