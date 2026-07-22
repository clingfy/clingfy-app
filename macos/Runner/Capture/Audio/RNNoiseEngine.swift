import Accelerate
import Foundation

/// Swift wrapper over the vendored RNNoise recurrent-network noise suppressor
/// (`Capture/Audio/RNNoise/`, upstream v0.2, BSD-3-Clause).
///
/// RNNoise is trained for exactly the format the mic sidecar decodes to — 48 kHz
/// mono — and consumes 480-sample (10 ms) frames, so no resampling is needed
/// anywhere in this path. It suppresses broadband background noise (fans, room
/// tone, keyboard, street) while leaving speech intact; it is NOT an echo
/// canceller (speaker→mic bleed is `MicEchoCanceller`'s job, and runs first).
///
/// Two details of the C library leak into this wrapper and both are load-bearing:
///
/// 1. **Scale.** `rnnoise_process_frame` works in the ±32768 short range, not the
///    ±1.0 float range AVFoundation decodes to. Feeding it ±1.0 samples makes it
///    treat the whole recording as near-silence and emit almost nothing — which
///    sounds like extremely aggressive denoising rather than a bug.
/// 2. **Latency.** The output lags the input by exactly two frames: 480 samples
///    for the overlap-add analysis buffer plus 480 for the `delayed_X`
///    pitch-filter lookahead. Uncompensated, the denoised mic would sit 20 ms
///    late against the system track in the export mix. `denoise` compensates so
///    its result is sample-aligned with its input.
enum RNNoiseEngine {
  /// Version of this engine + the vendored library + the mode→strength mapping.
  /// Part of the cleanup cache key: bump it whenever `denoise`'s output could
  /// change for the same input, or cached denoised mics keep playing stale audio.
  /// (Same discipline as `MicEchoCanceller.algorithmVersion`.)
  static let engineVersion = 1

  /// `rnnoise_get_frame_size()`. Pinned here because the framing loop below is
  /// written around it; `RNNoiseEngineTests` asserts the library agrees.
  static let frameSize = 480
  static let sampleRate: Double = 48_000

  /// Analysis overlap-add (480) + `delayed_X` pitch-filter lookahead (480).
  static let latencySamples = 2 * frameSize

  /// RNNoise's operating range.
  private static let shortScale: Float = 32768.0

  /// Denoise mono 48 kHz samples in the ±1.0 float range.
  ///
  /// Returns an array of the same length, sample-aligned with `samples`, or nil
  /// when the engine could not run at all — which the caller must treat as a
  /// failure rather than caching it as a clean pass.
  /// `wetMix` blends the suppressed signal against the original: 1.0 is full
  /// RNNoise, 0.5 leaves the noise ~6 dB down with fewer artifacts, 0.0 is a
  /// pass-through. Values outside 0...1 are clamped.
  static func denoise(_ samples: [Float], wetMix: Float) -> [Float]? {
    let n = samples.count
    guard n > 0 else { return samples }
    let wet = max(0.0, min(1.0, wetMix))
    guard wet > 0.0001 else { return samples }

    guard let state = rnnoise_create(nil) else {
      // Allocation failure. Returning the input would look like a successful
      // no-op cleanup and get cached as one, so the caller is told instead.
      NativeLogger.w("Audio", "RNNoise state allocation failed; no cleanup applied")
      return nil
    }
    defer { rnnoise_destroy(state) }

    var output = [Float](repeating: 0, count: n)
    var input = [Float](repeating: 0, count: frameSize)
    var denoised = [Float](repeating: 0, count: frameSize)

    // Conceptually: pad the input with `latencySamples` zeros, run every frame,
    // then drop the first `latencySamples` output samples. Because the latency
    // is a whole number of frames, that is the same as discarding the first two
    // frames of output and writing frame `f`'s output at `f * frameSize -
    // latencySamples` — no padded copy of the recording is ever materialized.
    let frameCount = (n + latencySamples + frameSize - 1) / frameSize

    for frame in 0..<frameCount {
      let readOffset = frame * frameSize
      for i in 0..<frameSize {
        let index = readOffset + i
        input[i] = index < n ? samples[index] * shortScale : 0
      }

      input.withUnsafeMutableBufferPointer { src in
        denoised.withUnsafeMutableBufferPointer { dst in
          _ = rnnoise_process_frame(state, dst.baseAddress, src.baseAddress)
        }
      }

      guard frame >= latencySamples / frameSize else { continue }
      let writeOffset = readOffset - latencySamples
      let count = min(frameSize, n - writeOffset)
      guard count > 0 else { break }
      for i in 0..<count {
        output[writeOffset + i] = denoised[i] / shortScale
      }
    }

    if wet < 0.9999 {
      // out = wet · denoised + (1 - wet) · original
      var wetGain = wet
      var dryGain = 1 - wet
      vDSP_vsmul(output, 1, &wetGain, &output, 1, vDSP_Length(n))
      var dry = [Float](repeating: 0, count: n)
      vDSP_vsmul(samples, 1, &dryGain, &dry, 1, vDSP_Length(n))
      vDSP_vadd(output, 1, dry, 1, &output, 1, vDSP_Length(n))
    }

    // Suppression is not purely attenuating: reshaping the spectrum shifts phase
    // relationships, so the output peak can sit slightly ABOVE the input's —
    // measured at ~1.06–1.08x on normal speech and up to ~1.17x on a hot take.
    // A mic already peaking near full scale can therefore come back out of
    // range, and nothing downstream would catch it: the export's `bakeGain`
    // skips its own clamp at unity gain, so those samples would reach the mixdown
    // and clip. Clamp here, matching `MicEchoCanceller.applyGain`'s bound.
    var low: Float = -1.0
    var high: Float = 1.0
    vDSP_vclip(output, 1, &low, &high, &output, 1, vDSP_Length(n))
    return output
  }

  /// `rnnoise_get_frame_size()` as the library reports it — used by tests to
  /// catch a vendored-library upgrade that changes the framing contract.
  static func libraryFrameSize() -> Int {
    Int(rnnoise_get_frame_size())
  }
}
