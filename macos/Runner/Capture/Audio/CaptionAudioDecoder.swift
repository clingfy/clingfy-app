import AVFoundation
import Foundation

/// Decodes a recording's audio to the exact shape a speech recogniser wants:
/// **16 kHz, mono, Float32, non-interleaved, in [-1, 1]**.
///
/// ## Why this exists rather than handing the file to the engine
///
/// WhisperKit will happily take a file path and resample internally — and has an
/// open bug (argmaxinc/argmax-oss-swift#500) where that path **silently corrupts
/// long compressed audio**: an 87-minute compressed file produces a garbage
/// transcript with no error and a success exit code. A five-minute slice of the
/// same file is fine, and the same audio pre-converted to 16 kHz mono is fine.
/// Long compressed `.m4a` is exactly what this app records, so the file path is
/// not an option.
///
/// The suspected causes are trusting a container's *estimated* length for VBR
/// audio, and rebuilding an `AVAudioConverter` per chunk so filter state is lost
/// across boundaries — corruption that accumulates and is invisible on short
/// files. This decoder avoids both by construction: one `AVAssetReader` pass
/// with the target format declared in its output settings, so AVFoundation
/// resamples and downmixes as it reads, with no chunk boundaries to lose state
/// across. It is the same mechanism `MicEchoCanceller.decodePCMMono48k` has used
/// in production since echo cancellation shipped.
///
/// ## Why 16 kHz specifically
///
/// Whisper's models are trained on 16 kHz mono. Feeding anything else means the
/// engine resamples anyway, which is the code path being avoided.
///
/// ## Why not reuse the 48 kHz decoder
///
/// Resampling 48 kHz down to 16 kHz afterwards would be a second conversion, and
/// the 48 kHz path exists to feed RNNoise, which requires that rate. Different
/// consumers, different targets, one shared mechanism.
enum CaptionAudioDecoder {

  /// The rate Whisper models expect.
  static let targetSampleRate: Double = 16_000

  enum DecodeError: Error, Equatable {
    case noAudioTrack(URL)
    case unreadable(URL)
    case cancelled
  }

  /// Decodes `url` to 16 kHz mono Float32.
  ///
  /// - Parameter isCancelled: polled between sample buffers so a long decode can
  ///   be abandoned promptly. A 60-minute recording is ~57 MB of Float32 at this
  ///   rate and takes real time to produce; a user who cancelled should not wait
  ///   for it.
  ///
  /// Returns the whole file in memory, which is the shape the engine wants.
  /// Budget roughly **64 KB per second of audio** — about 115 MB for 30 minutes,
  /// per source. That is why the transcription job decodes one source at a time
  /// and releases it before starting the next, rather than holding mic and
  /// system audio simultaneously.
  static func decodeMono16k(
    url: URL,
    isCancelled: () -> Bool = { false }
  ) throws -> [Float] {
    let asset = AVAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first else {
      throw DecodeError.noAudioTrack(url)
    }

    // Hold the asset for the life of the read. An AVAssetTrack does NOT retain
    // its parent asset, and letting it deallocate mid-read fails with -11800 /
    // -12780 — a trap this codebase has already hit once and recorded.
    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      throw DecodeError.unreadable(url)
    }

    // The target format is declared here, so AVFoundation resamples and
    // downmixes inside its own single pass. Whatever the recorder produced —
    // 44.1 kHz mono from a built-in mic, 48 kHz stereo from the system tap —
    // comes out identically shaped.
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
      AVSampleRateKey: targetSampleRate,
      AVNumberOfChannelsKey: 1,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw DecodeError.unreadable(url) }
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? DecodeError.unreadable(url)
    }

    var samples: [Float] = []
    // Pre-size from the track's duration to avoid repeated reallocation on a
    // long recording. An estimate is fine; the array grows if it was low.
    let estimatedSeconds = CMTimeGetSeconds(track.timeRange.duration)
    if estimatedSeconds.isFinite, estimatedSeconds > 0 {
      samples.reserveCapacity(Int(estimatedSeconds * targetSampleRate))
    }

    while let sampleBuffer = output.copyNextSampleBuffer() {
      if isCancelled() {
        CMSampleBufferInvalidate(sampleBuffer)
        reader.cancelReading()
        throw DecodeError.cancelled
      }
      guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        CMSampleBufferInvalidate(sampleBuffer)
        continue
      }
      let length = CMBlockBufferGetDataLength(block)
      let count = length / MemoryLayout<Float>.size
      if count > 0 {
        var chunk = [Float](repeating: 0, count: count)
        chunk.withUnsafeMutableBytes { raw in
          guard let base = raw.baseAddress else { return }
          _ = CMBlockBufferCopyDataBytes(
            block, atOffset: 0, dataLength: length, destination: base)
        }
        samples.append(contentsOf: chunk)
      }
      CMSampleBufferInvalidate(sampleBuffer)
    }

    if reader.status == .failed {
      throw reader.error ?? DecodeError.unreadable(url)
    }
    return samples
  }

  /// Peak-normalises in place toward `targetPeak`, leaving near-silence alone.
  ///
  /// The microphone reaching the recogniser is the RAW sidecar — the user's gain
  /// setting is baked in only at export, so a quiet recording arrives quiet and
  /// transcribes worse for no reason. Normalising in memory fixes that without
  /// keying transcription on any user-adjustable setting, which is what keeps
  /// the result deterministic for a given recording.
  ///
  /// A silence floor matters: scaling a track that contains only room tone up to
  /// full scale manufactures exactly the kind of noise Whisper hallucinates over.
  static func normalizePeak(
    _ samples: inout [Float],
    targetPeak: Float = 0.95,
    silenceFloor: Float = 0.001
  ) {
    var peak: Float = 0
    for sample in samples {
      let magnitude = abs(sample)
      if magnitude > peak { peak = magnitude }
    }
    guard peak > silenceFloor, peak < targetPeak else { return }
    let gain = targetPeak / peak
    for index in samples.indices {
      samples[index] *= gain
    }
  }
}
