import AVFoundation
import Foundation

/// AAC-LC output rules shared by every encoder in the app.
///
/// AAC-LC rejects bitrates that its sample rate cannot carry, and the rejection
/// is both late and opaque: `AVAssetWriter.canAdd(_:)` returns true,
/// `startWriting()` returns true, and the encoder only fails when the FIRST
/// sample buffer is appended — surfacing as `-11861 "Cannot Encode Media"`
/// wrapping OSStatus `-12651`. Nothing about that error names the bitrate, so
/// the rule has to be enforced up front.
///
/// Measured on macOS 15, driving the real export pipeline (a 16 kHz mic plus a
/// 48 kHz system sidecar, mixed by `AVAssetReaderAudioMixOutput` into a `.mov`
/// writer) with the output rate pinned to 16 kHz:
///   192 kbps → rejected, 128 kbps → rejected, 96 kbps → accepted.
///
/// The rejection is not confined to the export path: the same 16 kHz stereo
/// 192 kbps tuple also fails when writing a plain `.m4a` from float PCM, which
/// is what made the test fixture helper unable to produce a low-rate file at
/// all until it was moved onto this rule.
///
/// The capture writer and the export writer each shipped this bug
/// independently — same illegal combination, months apart, different files.
/// That is why the rule lives in one place instead of being restated at each
/// encoder.
enum AACEncoderSettings {

  /// The fixed rate set AAC-LC supports.
  static let supportedSampleRates: Set<Double> = [
    8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000,
  ]

  /// Used when no source track reports a usable rate.
  static let defaultSampleRate: Double = 48_000

  static let maxBitRatePerChannel = 96_000
  static let minBitRatePerChannel = 16_000

  /// Per-channel bitrate for `sampleRate`, held to roughly 2 bits per sample.
  ///
  /// The `* 2` keeps low-rate sources (Bluetooth HFP mics report 8 or 16 kHz)
  /// inside what the encoder accepts, while the cap keeps normal 44.1/48 kHz
  /// content at the full 96 kbps per channel it has always used. The floor
  /// stops an absurdly small value being requested for an 8 kHz source.
  static func bitRate(sampleRate: Double, channels: Int) -> Int {
    let perChannel = min(maxBitRatePerChannel, max(minBitRatePerChannel, Int(sampleRate * 2)))
    return perChannel * max(1, channels)
  }

  /// The highest per-channel bitrate AAC-LC will actually carry at
  /// `sampleRate`, measured rather than looked up.
  ///
  /// `AACBitRateProbeTests` drives the real `AVAssetWriter` at 48 kHz stereo
  /// and finds everything up to 320 kbps accepted and 384 kbps refused — so
  /// 160 kbps per channel. The header's 16 kHz measurements put the boundary
  /// there between 48 and 64 kbps per channel. Both land on roughly ten thirds
  /// of the sample rate, which is the rule used here.
  ///
  /// Note how much slack this leaves over [bitRate]'s `* 2`: that function is
  /// deliberately conservative because it also feeds CAPTURE, where a wrong
  /// guess costs a recording. This one exists for export, where the source is
  /// already on disk and a refused tuple costs a retry.
  static func maxLegalBitRatePerChannel(sampleRate: Double) -> Int {
    Int(sampleRate * 10.0 / 3.0)
  }

  /// Per-channel target for an export quality tier. Stereo doubles it, so
  /// these are the 192 / 256 / 320 kbps the UI offers.
  ///
  /// Unknown values fall back to `standard`, which keeps an older or malformed
  /// payload exporting exactly what it exports today.
  static func exportTargetPerChannel(quality wire: String) -> Int {
    switch wire.lowercased() {
    case "high": return 128_000
    case "best": return 160_000
    default: return maxBitRatePerChannel
    }
  }

  /// The AAC bitrate for an EXPORT at `quality`.
  ///
  /// Separate from [bitRate] rather than a parameter on it, and that is the
  /// whole point: [bitRate] has two production callers, one of which is the
  /// capture writer (`SourceAudioRecorder`). Adding a tier parameter there
  /// would put a user-facing export control one defaulted argument away from
  /// changing how every recording is captured. The `standard` case delegates,
  /// so the default export is byte-identical to what shipped before this
  /// existed.
  ///
  /// The tier is a CEILING. A 16 kHz Bluetooth headset mic still gets what
  /// 16 kHz can carry whichever tier is selected, because asking for more is
  /// the `-11861` failure this file exists to prevent.
  static func exportBitRate(sampleRate: Double, channels: Int, quality: String) -> Int {
    let target = exportTargetPerChannel(quality: quality)
    // `standard` is the conservative rule verbatim, so the default export is
    // byte-identical to what shipped before the tiers existed.
    if target <= maxBitRatePerChannel {
      return bitRate(sampleRate: sampleRate, channels: channels)
    }
    // Raise the ceiling ONLY at the rate whose ceiling was actually measured.
    //
    // `AACBitRateProbeTests` measured 48 kHz: up to 320 kbps accepted, 384
    // refused. Below that, the only data points are the header's 16 kHz
    // measurements — 96 kbps total accepted, 128 kbps refused — which leaves a
    // band in between that nothing has tested. Interpolating into it would put
    // a guess on the path whose failure mode is an export that dies on the
    // first sample buffer with `-11861`, so a sub-48 kHz source keeps the
    // conservative rate whichever tier is chosen. A 16 kHz headset recording
    // simply cannot carry 320 kbps, and saying so costs nothing.
    guard sampleRate >= defaultSampleRate else {
      return bitRate(sampleRate: sampleRate, channels: channels)
    }
    let legal = maxLegalBitRatePerChannel(sampleRate: sampleRate)
    let perChannel = min(target, max(minBitRatePerChannel, legal))
    return perChannel * max(1, channels)
  }

  /// Output sample rate for a mix of `tracks`: the **highest** supported rate
  /// among them, never simply the first.
  ///
  /// Taking the first track's rate lets whichever source happens to be ordered
  /// first dictate the whole mix. A Bluetooth headset mic (16 kHz) mixed with
  /// system audio (48 kHz) would export the system audio resampled down to
  /// 16 kHz — audible damage to content that was never low-rate — on top of
  /// requesting a bitrate that rate cannot carry.
  static func outputSampleRate(for tracks: [AVAssetTrack]) -> Double {
    let rates: [Double] = tracks.compactMap { track in
      guard
        let formatDescription = track.formatDescriptions.first,
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
          formatDescription as! CMFormatDescription)?.pointee,
        supportedSampleRates.contains(asbd.mSampleRate)
      else {
        return nil
      }
      return asbd.mSampleRate
    }
    return rates.max() ?? defaultSampleRate
  }
}
