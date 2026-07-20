import Foundation

/// User-facing voice-cleanup strength. The engine behind each level is chosen
/// here and never surfaced in the UI, so a stronger engine can replace RNNoise
/// later without a wire-format or UI change.
///
/// Keep the raw values in sync with the Dart `CleanupMode` in
/// `lib/core/timeline/model/edit_track.dart`.
enum VoiceCleanupMode: String {
  case light
  case balanced
  case highQuality

  /// Unknown values decode to `.balanced`, matching Dart's `CleanupMode.fromWire`.
  static func fromWire(_ raw: String?) -> VoiceCleanupMode {
    guard let raw, let mode = VoiceCleanupMode(rawValue: raw) else { return .balanced }
    return mode
  }

  /// How much of the suppressed signal to keep, against the original.
  ///
  /// `.highQuality` is reserved for a future full-band engine (DeepFilterNet per
  /// `docs/editing-platform-plan.md` Phase 4); until that engine is vendored it
  /// runs RNNoise at full strength, which is the best available. The UI does not
  /// offer the level yet — this mapping exists so a project saved by a future
  /// build still opens and exports sensibly here.
  var wetMix: Float {
    switch self {
    case .light: return 0.5
    case .balanced, .highQuality: return 1.0
    }
  }
}

/// A voice-cleanup request as it arrives from Flutter.
struct VoiceCleanupRequest: Equatable {
  let enabled: Bool
  let mode: VoiceCleanupMode

  static let disabled = VoiceCleanupRequest(enabled: false, mode: .balanced)

  /// Parses the additive `voiceCleanup` key of `processVideo` / `exportVideo`.
  /// A missing or malformed value means disabled, so payloads from older
  /// Flutter builds keep exporting exactly as before.
  static func fromFlutter(_ raw: Any?) -> VoiceCleanupRequest {
    guard let map = raw as? [String: Any], let enabled = map["enabled"] as? Bool, enabled else {
      return .disabled
    }
    return VoiceCleanupRequest(enabled: true, mode: .fromWire(map["mode"] as? String))
  }
}

/// Mic noise reduction: the engine-agnostic, file-to-file stage that removes
/// background noise (fans, room tone, street, keyboard) from the microphone
/// track.
///
/// Placement in the mic chain — see `LetterboxExporter`'s separated-audio
/// preamble — is `raw mic → echo cancel → THIS → normalize/gain → mix with
/// system`. Two ordering rules matter:
///
/// - It runs AFTER `MicEchoCanceller` because that stage needs the mic's
///   original speaker bleed intact to correlate against the system reference.
/// - It runs BEFORE the loudness peak scan and the gain bake, because removing
///   noise lowers the mic's peak; normalizing against the pre-cleanup peak would
///   under-boost the voice and re-amplify whatever noise survived.
///
/// It only ever touches the MIC. System audio (music, game, app audio) is never
/// denoised — running a speech model over it would wreck it — which is why the
/// stage is skipped entirely for legacy recordings that have no separate mic
/// sidecar to work on.
enum AudioEnhancementPipeline {
  /// Version of the pipeline itself (chaining, scaling, mode→engine routing),
  /// separate from the engine's own version. Both are part of the cache key.
  static let pipelineVersion = 1

  struct Result {
    let enhancedMicURL: URL
    /// False when the request was disabled or there was nothing to process; the
    /// URL is then the untouched input.
    let applied: Bool
    /// How much quieter the track got, in dB. POSITIVE means noise was removed
    /// (the usual outcome); a negative value would mean the stage made the track
    /// louder, which for a noise suppressor means something is wrong. Diagnostic
    /// only — nothing branches on it.
    let noiseReductionDb: Float
  }

  enum EnhanceError: Error {
    /// The suppressor could not be created at all. Distinct from "nothing to
    /// clean" so the caller degrades to the raw mic WITHOUT caching a result.
    case engineUnavailable
    case decodeFailed(URL)
    case writeFailed(URL)
    case emptyInput(URL)
  }

  /// File-name prefix for staged output. Distinct from the canceller's
  /// `mic-echo-cancelled-` prefix so the two stages' temp files are swept and
  /// adopted independently.
  static let stagedFileNamePrefix = "mic-enhanced-"

  /// Denoise `micURL` into a new lossless CAF in `outputDirectory`.
  ///
  /// Lossless output keeps the export's AAC pass the only lossy generation.
  /// Throws only on genuine decode/write failure so callers can degrade to the
  /// un-enhanced mic — losing the noise reduction is always safer than failing
  /// an export or a preview open.
  static func enhance(micURL: URL, mode: VoiceCleanupMode, outputDirectory: URL) throws -> Result {
    let samples: [Float]
    do {
      samples = try MicEchoCanceller.decodePCMMono48k(url: micURL)
    } catch {
      throw EnhanceError.decodeFailed(micURL)
    }
    guard !samples.isEmpty else { throw EnhanceError.emptyInput(micURL) }

    let inputRms = rms(samples)
    guard let cleaned = RNNoiseEngine.denoise(samples, wetMix: mode.wetMix) else {
      throw EnhanceError.engineUnavailable
    }
    let outputRms = rms(cleaned)

    let url: URL
    do {
      url = try MicEchoCanceller.writeMonoPCM(
        cleaned, directory: outputDirectory, namePrefix: stagedFileNamePrefix)
    } catch {
      throw EnhanceError.writeFailed(outputDirectory)
    }

    let reductionDb =
      (inputRms > 0 && outputRms > 0) ? 20 * log10f(inputRms / outputRms) : 0
    NativeLogger.i(
      "Audio", "Voice cleanup applied",
      context: [
        "mode": mode.rawValue,
        "engineVersion": "\(RNNoiseEngine.engineVersion)",
        "reductionDb": String(format: "%.1f", reductionDb),
      ])
    return Result(enhancedMicURL: url, applied: true, noiseReductionDb: reductionDb)
  }

  private static func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Double = 0
    for sample in samples { sum += Double(sample) * Double(sample) }
    return Float((sum / Double(samples.count)).squareRoot())
  }
}
