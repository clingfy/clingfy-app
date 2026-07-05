import AVFoundation
import Accelerate

/// Removes speaker→mic bleed of the SYSTEM audio from the microphone track using
/// the clean `system.m4a` as a reference — a known-reference echo canceller.
///
/// Why this exists: when the user plays system audio through SPEAKERS while the
/// mic is live, the mic picks up the speaker output ~55 ms later (audio I/O
/// round-trip). `system.m4a` is a clean digital tap; `mic.m4a` = the user's voice
/// PLUS a delayed copy of the system audio. The separated-audio export mixes
/// `mic.m4a + system.m4a`, so the system audio is heard twice → an audible echo
/// (proven: mic↔system correlation −0.29 at −55 ms; export mix self-echo at the
/// same lag). We estimate the bleed by adaptively predicting the mic from the
/// delay-aligned system reference and subtract it, leaving the voice intact —
/// the voice is uncorrelated with the system, so the filter mathematically
/// cannot remove it.
///
/// The whole thing is a NO-OP (returns the original mic URL, `applied == false`)
/// when there is no measurable bleed: headphones, no system audio, or a silent
/// mic all yield a near-zero mic↔system correlation that falls under the gate.
///
/// Algorithm (validated offline against the real bleed recording, −26 dB):
///   1. Decode mic + system to mono Float32 48 kHz.
///   2. Estimate the signed bleed delay + normalized peak correlation (coarse,
///      on a decimated signal). Gate: bail out below `gateCorrelation`.
///   3. Build the delay-aligned reference (zero-filled shift + small pre-roll so
///      the causal NLMS filter can also model a little pre-echo).
///   4. Standard NLMS: predict mic from the reference, subtract → cleaned mic.
///   5. Write the cleaned mic to a lossless CAF the export consumes in place of
///      the raw mic.
enum MicEchoCanceller {
  static let sampleRate: Double = 48_000
  /// Adaptive filter length in taps. 512 @ 48 kHz ≈ 10.7 ms — long enough for the
  /// residual fine delay + early reflections after bulk alignment, short enough
  /// to stay stable (longer over-fits and diverges on this signal class).
  static let filterTaps = 512
  /// NLMS step size (0 < µ < 2). 0.3 gave the best stable reduction offline.
  static let stepSize: Float = 0.3
  static let regularization: Float = 1e-6
  /// Below this |mic↔system| correlation there is no meaningful bleed to cancel
  /// (headphones / no system audio / silent mic) → the canceller is a no-op.
  static let gateCorrelation: Float = 0.10
  /// Widest bleed delay we search for (the I/O round-trip is ~55 ms; this is
  /// generous headroom).
  static let maxDelaySeconds: Double = 0.30
  /// Pre-roll so the causal filter covers a few ms of anti-causal reverb / any
  /// sub-sample bulk-alignment error.
  static let prerollSeconds: Double = 0.008
  /// Decimation factor for the coarse delay search (48 kHz → 6 kHz). The NLMS
  /// filter absorbs the residual sub-decimation delay.
  static let delaySearchDecimation = 8
  /// Below this many samples there is not enough signal to estimate anything.
  static let minSamples = 4_800  // 0.1 s

  struct Result {
    /// The mic to feed into the export. Either the freshly written cleaned file
    /// (`applied == true`) or the original `micURL` unchanged (`applied == false`).
    let cleanedMicURL: URL
    let applied: Bool
    let bleedCorrelation: Float
    let delayMs: Double
    let reductionDb: Float
  }

  enum CancelError: Error {
    case noAudioTrack(URL)
    case decodeFailed(URL)
    case writeFailed(URL)
  }

  /// Decode `micURL` + `systemURL`, estimate and subtract the system bleed from
  /// the mic, and write the cleaned mic into `outputDirectory`. Returns the
  /// original mic (`applied == false`) when no bleed is detected or the inputs
  /// are too short. Never throws for "no bleed" — only for genuine decode/write
  /// failures, so the caller can degrade to the raw mic.
  static func cancel(micURL: URL, systemURL: URL, outputDirectory: URL) throws -> Result {
    let mic = try decodePCMMono48k(url: micURL)
    let system = try decodePCMMono48k(url: systemURL)
    let n = min(mic.count, system.count)
    guard n >= minSamples else {
      return Result(
        cleanedMicURL: micURL, applied: false, bleedCorrelation: 0, delayMs: 0, reductionDb: 0)
    }
    let micN = Array(mic[0..<n])
    let systemN = Array(system[0..<n])

    // 1. Signed bleed delay + normalized peak correlation.
    let (delaySamples, corr) = estimateDelay(mic: micN, system: systemN)
    let delayMs = Double(delaySamples) / sampleRate * 1000.0
    guard abs(corr) >= gateCorrelation else {
      // No measurable bleed → leave the mic exactly as recorded.
      return Result(
        cleanedMicURL: micURL, applied: false, bleedCorrelation: corr, delayMs: delayMs,
        reductionDb: 0)
    }

    // 2. Delay-aligned reference (zero-filled shift so no wrap-around artifacts).
    let preroll = Int((prerollSeconds * sampleRate).rounded())
    let offset = preroll - delaySamples
    var reference = [Float](repeating: 0, count: n)
    for i in 0..<n {
      let j = i + offset
      if j >= 0 && j < n { reference[i] = systemN[j] }
    }

    // 3. NLMS → cleaned mic (the error signal = mic minus the predicted bleed).
    let cleaned = nlms(desired: micN, reference: reference)

    // 4. Metrics (coarse, for logging / diagnostics).
    let residual = correlationAtDelay(cleaned, systemN, delaySamples: delaySamples)
    let reductionDb = 20.0 * log10(abs(residual) / max(abs(corr), 1e-6) + 1e-9)

    // 5. Write the cleaned mic.
    let url = try writeMonoPCM(cleaned, directory: outputDirectory)
    return Result(
      cleanedMicURL: url, applied: true, bleedCorrelation: corr, delayMs: delayMs,
      reductionDb: reductionDb)
  }

  // MARK: - NLMS

  /// Standard normalized LMS: for each sample `y = wᵀ·window`, `e = d − y`,
  /// `w += µ·e·window / (‖window‖² + ε)`. Returns the error signal `e` (the
  /// cleaned mic). `w` is stored oldest→newest to match the contiguous reference
  /// window, so both the dot product and the update run over the same slice with
  /// no per-sample copy. Exposed (not private) so tests can drive it directly.
  static func nlms(desired: [Float], reference: [Float]) -> [Float] {
    let n = desired.count
    let taps = filterTaps
    guard n > 0, reference.count >= n else { return desired }

    // Left-pad the reference with `taps - 1` zeros so the causal window
    // `refPad[i ..< i+taps]` is always valid and zero-filled before sample 0.
    var refPad = [Float](repeating: 0, count: n + taps - 1)
    for i in 0..<n { refPad[i + taps - 1] = reference[i] }

    var weights = [Float](repeating: 0, count: taps)
    var out = [Float](repeating: 0, count: n)
    var energy: Float = 0

    refPad.withUnsafeBufferPointer { rp in
      weights.withUnsafeMutableBufferPointer { wp in
        let refBase = rp.baseAddress!
        let wBase = wp.baseAddress!
        for i in 0..<n {
          let window = refBase + i  // refPad[i ..< i + taps], oldest → newest
          // Sliding energy: add the newest sample, drop the one that left.
          let newest = rp[i + taps - 1]
          let leaving: Float = i == 0 ? 0 : rp[i - 1]
          energy += newest * newest - leaving * leaving

          var y: Float = 0
          vDSP_dotpr(wBase, 1, window, 1, &y, vDSP_Length(taps))
          let e = desired[i] - y
          out[i] = e

          var scale = stepSize * e / (max(energy, 0) + regularization)
          // weights += scale * window
          vDSP_vsma(window, 1, &scale, wBase, 1, wBase, 1, vDSP_Length(taps))
        }
      }
    }
    return out
  }

  // MARK: - Delay estimation

  /// Coarse signed bleed delay (in 48 kHz samples) and the normalized peak
  /// correlation, searched on a decimated signal. A positive lag `D` means the
  /// mic matches `system[n − D]`; the observed bleed sits at a NEGATIVE lag
  /// (system.m4a is written with more pipeline latency than the mic path).
  static func estimateDelay(mic: [Float], system: [Float]) -> (samples: Int, correlation: Float) {
    let m = delaySearchDecimation
    let a = decimateZeroMean(mic, factor: m)
    let b = decimateZeroMean(system, factor: m)
    let len = min(a.count, b.count)
    guard len > 1 else { return (0, 0) }

    var sumSqA: Float = 0
    var sumSqB: Float = 0
    vDSP_svesq(a, 1, &sumSqA, vDSP_Length(len))
    vDSP_svesq(b, 1, &sumSqB, vDSP_Length(len))
    let denom = max(sqrt(sumSqA) * sqrt(sumSqB), 1e-9)

    let maxLag = min(Int(maxDelaySeconds * sampleRate / Double(m)), len - 1)
    var best: Float = 0
    var bestLag = 0
    a.withUnsafeBufferPointer { ap in
      b.withUnsafeBufferPointer { bp in
        let aBase = ap.baseAddress!
        let bBase = bp.baseAddress!
        for lag in -maxLag...maxLag {
          var dot: Float = 0
          if lag >= 0 {
            vDSP_dotpr(aBase + lag, 1, bBase, 1, &dot, vDSP_Length(len - lag))
          } else {
            vDSP_dotpr(aBase, 1, bBase - lag, 1, &dot, vDSP_Length(len + lag))
          }
          let c = dot / denom
          if abs(c) > abs(best) {
            best = c
            bestLag = lag
          }
        }
      }
    }
    return (bestLag * m, best)
  }

  /// Normalized correlation of `a` vs `b` at a single (full-rate) lag, measured on
  /// the decimated signals — used only for the reduction metric.
  private static func correlationAtDelay(_ a: [Float], _ b: [Float], delaySamples: Int) -> Float {
    let m = delaySearchDecimation
    let ad = decimateZeroMean(a, factor: m)
    let bd = decimateZeroMean(b, factor: m)
    let len = min(ad.count, bd.count)
    guard len > 1 else { return 0 }
    var sqA: Float = 0
    var sqB: Float = 0
    vDSP_svesq(ad, 1, &sqA, vDSP_Length(len))
    vDSP_svesq(bd, 1, &sqB, vDSP_Length(len))
    let denom = max(sqrt(sqA) * sqrt(sqB), 1e-9)
    let lag = Int((Double(delaySamples) / Double(m)).rounded())
    guard abs(lag) < len else { return 0 }
    var dot: Float = 0
    ad.withUnsafeBufferPointer { ap in
      bd.withUnsafeBufferPointer { bp in
        if lag >= 0 {
          vDSP_dotpr(ap.baseAddress! + lag, 1, bp.baseAddress!, 1, &dot, vDSP_Length(len - lag))
        } else {
          vDSP_dotpr(ap.baseAddress!, 1, bp.baseAddress! - lag, 1, &dot, vDSP_Length(len + lag))
        }
      }
    }
    return dot / denom
  }

  /// Block-average decimation followed by mean removal.
  static func decimateZeroMean(_ x: [Float], factor m: Int) -> [Float] {
    guard m > 1 else {
      var out = x
      var mean: Float = 0
      vDSP_meanv(out, 1, &mean, vDSP_Length(out.count))
      var negMean = -mean
      vDSP_vsadd(out, 1, &negMean, &out, 1, vDSP_Length(out.count))
      return out
    }
    let outCount = x.count / m
    guard outCount > 0 else { return [] }
    var out = [Float](repeating: 0, count: outCount)
    let inv = 1.0 / Float(m)
    x.withUnsafeBufferPointer { xp in
      let base = xp.baseAddress!
      for i in 0..<outCount {
        var s: Float = 0
        vDSP_sve(base + i * m, 1, &s, vDSP_Length(m))
        out[i] = s * inv
      }
    }
    var mean: Float = 0
    vDSP_meanv(out, 1, &mean, vDSP_Length(outCount))
    var negMean = -mean
    vDSP_vsadd(out, 1, &negMean, &out, 1, vDSP_Length(outCount))
    return out
  }

  // MARK: - Decode / encode

  /// Decode an audio file to mono Float32 at `sampleRate` (AVFoundation resamples
  /// and down-mixes per the output settings).
  static func decodePCMMono48k(url: URL) throws -> [Float] {
    let asset = AVAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first else {
      throw CancelError.noAudioTrack(url)
    }
    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      throw CancelError.decodeFailed(url)
    }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw CancelError.decodeFailed(url) }
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? CancelError.decodeFailed(url) }

    var samples = [Float]()
    while let sampleBuffer = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        CMSampleBufferInvalidate(sampleBuffer)
        continue
      }
      let length = CMBlockBufferGetDataLength(block)
      let count = length / MemoryLayout<Float>.size
      if count > 0 {
        var chunk = [Float](repeating: 0, count: count)
        chunk.withUnsafeMutableBytes { raw in
          _ = CMBlockBufferCopyDataBytes(
            block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        samples.append(contentsOf: chunk)
      }
      CMSampleBufferInvalidate(sampleBuffer)
    }
    if reader.status == .failed { throw reader.error ?? CancelError.decodeFailed(url) }
    return samples
  }

  /// Write mono Float32 PCM to a lossless CAF in `directory`. Lossless keeps the
  /// only encode the final export's AAC pass, avoiding a double lossy generation.
  static func writeMonoPCM(_ samples: [Float], directory: URL) throws -> URL {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    else {
      throw CancelError.writeFailed(directory)
    }
    let url = directory.appendingPathComponent("mic-echo-cancelled-\(UUID().uuidString).caf")
    let file: AVAudioFile
    do {
      file = try AVAudioFile(forWriting: url, settings: format.settings)
    } catch {
      throw CancelError.writeFailed(url)
    }
    let frames = AVAudioFrameCount(samples.count)
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
      throw CancelError.writeFailed(url)
    }
    buffer.frameLength = frames
    samples.withUnsafeBufferPointer { src in
      buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
    }
    do {
      try file.write(from: buffer)
    } catch {
      throw CancelError.writeFailed(url)
    }
    return url
  }
}
