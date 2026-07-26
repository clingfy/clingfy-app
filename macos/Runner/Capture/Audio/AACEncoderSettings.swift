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
/// The exact ceiling is not purely a function of (rate, channels, bitrate):
/// the same 16 kHz stereo 192 kbps tuple encodes happily into a `.m4a` from
/// float PCM, which is why unit tests over the settings dictionary alone kept
/// passing while export was broken. Staying well under the limit is the only
/// portable answer.
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
