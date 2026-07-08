import AVFoundation
import Accelerate

/// Removes speaker→mic bleed of the SYSTEM audio from the microphone track using
/// the clean `system.m4a` as a reference — a known-reference echo canceller.
///
/// Why this exists: when the user plays system audio through SPEAKERS while the
/// mic is live, the mic picks up the speaker output ~55–110 ms later (audio I/O
/// round-trip). `system.m4a` is a clean digital tap; `mic.m4a` = the user's voice
/// PLUS a delayed copy of the system audio. The separated-audio export mixes
/// `mic.m4a + system.m4a`, so the system audio is heard twice → an audible echo.
///
/// Where the echo actually lives (measured on real recordings): the bleed is
/// almost entirely confined to the **pauses between speech**. While the user is
/// talking the loud voice masks the bleed (mic↔system correlation ≈ 0), but in
/// the gaps the mic is essentially a delayed copy of the system (correlation up
/// to 0.5–0.8). Mixing that into the export and — worse — raising the mic gain
/// makes the delayed system copy rival the direct system → a "weak echo" heard
/// only in the gaps, louder at higher gain.
///
/// The v1 canceller gated on a SINGLE global mic↔system correlation over the
/// whole file; loud speech averaged it below the gate, so it never fired on real
/// recordings. This version detects the bleed **per window** so speech can't
/// mask it, cancels it adaptively, and blends by voice activity so the voice is
/// never touched.
///
/// The whole thing is a NO-OP (returns the original mic URL, `applied == false`)
/// when no window shows meaningful bleed: headphones, no system audio, or a
/// silent mic all yield a near-zero windowed correlation that falls under the
/// gate.
///
/// Algorithm:
///   1. Decode mic + system to mono Float32 48 kHz.
///   2. Estimate the signed bleed delay + peak correlation on a **sliding
///      window** (system-present windows only), taking the strongest window so
///      speech can't average the bleed away. Gate: bail out below
///      `gateCorrelation`.
///   3. Build the delay-aligned reference (zero-filled shift + small pre-roll).
///   4. NLMS with double-talk detection: predict mic from the reference and
///      subtract, but FREEZE adaptation while near-end voice dominates so the
///      filter can never learn (and thus cancel) the voice.
///   5. Voice-activity blend: emit the RAW mic where near-end voice is present
///      (byte-for-byte, zero voice damage) and the cleaned mic in the pauses
///      (bleed removed), crossfaded to avoid clicks.
///   6. Write the result to a lossless CAF the export/preview consumes in place
///      of the raw mic.
enum MicEchoCanceller {
  static let sampleRate: Double = 48_000
  /// Adaptive filter length in taps. 512 @ 48 kHz ≈ 10.7 ms — long enough for the
  /// residual fine delay + early reflections after bulk alignment, short enough
  /// to stay stable (longer over-fits and diverges on this signal class).
  static let filterTaps = 512
  /// NLMS step size (0 < µ < 2). 0.3 keeps misadjustment low (an independent
  /// reference stays a near-no-op); higher µ barely improves the real bleed cut
  /// (~1 dB) because the double-talk freeze + voice-activity blend do the work.
  static let stepSize: Float = 0.3
  static let regularization: Float = 1e-6
  /// Below this |mic↔system| WINDOWED-peak correlation there is no meaningful
  /// bleed to cancel (headphones / no system audio / silent mic) → no-op. This is
  /// the strongest 0.5 s window, so loud speech in other windows can't dilute it.
  static let gateCorrelation: Float = 0.15
  /// Widest bleed delay we search for (the I/O round-trip is ~55–110 ms; this is
  /// generous headroom).
  static let maxDelaySeconds: Double = 0.30
  /// Narrowest plausible bleed delay. Anything closer to zero than this is not an
  /// acoustic round-trip and is rejected — it guards against a degenerate lock at
  /// ~0 lag (mic vs. a near-simultaneous system tap).
  static let minDelaySeconds: Double = 0.010
  /// Two windows are the "same" bleed if their peak lags agree within this.
  static let clusterToleranceSeconds: Double = 0.006
  /// Real bleed peaks at the SAME delay across many system-present windows;
  /// a coincidental correlation (music, cross-talk on headphones) is a one-window
  /// fluke at a random lag. Require at least this many windows to agree on a lag
  /// before engaging, so colored bleed-free audio can't trip the canceller.
  static let minConsensusWindows = 3
  /// Pre-roll so the causal filter covers a few ms of anti-causal reverb / any
  /// sub-sample bulk-alignment error.
  static let prerollSeconds: Double = 0.008
  /// Decimation factor for the coarse delay search (48 kHz → 6 kHz). The NLMS
  /// filter absorbs the residual sub-decimation delay.
  static let delaySearchDecimation = 8
  /// Below this many samples there is not enough signal to estimate anything.
  static let minSamples = 4_800  // 0.1 s
  /// Sliding-window length for detection + delay estimation.
  static let detectionWindowSeconds: Double = 0.5
  /// Envelope smoothing window for the double-talk / voice-activity detectors.
  static let envelopeWindowSeconds: Double = 0.02
  /// Freeze NLMS adaptation when the mic envelope exceeds this multiple of the
  /// reference envelope — i.e. near-end voice clearly dominates any possible echo.
  static let doubleTalkRatio: Float = 3.0
  /// Reference envelope above which the system is considered audibly present.
  static let referencePresentFloor: Float = 0.003
  /// The system is treated as "present" for this long after its envelope drops
  /// under the floor, bridging intra-speech gaps in the system audio so the
  /// blend doesn't flap raw/cleaned inside one sentence.
  static let systemHoldSeconds: Double = 0.5
  /// …and this long BEFORE it rises (envelope rise time + alignment slack).
  static let systemBackfillSeconds: Double = 0.06
  /// Blend crossfade time constants: FAST into the cleaned path (bleed must not
  /// leak at system onsets), slow back to raw (no chatter at system tails).
  static let blendFastSeconds: Double = 0.004
  static let blendSlowSeconds: Double = 0.12
  /// Extra attenuation of the cleaned mic while the system is present and the
  /// mic is unambiguously at bleed level — makes the residual survive even a
  /// +24 dB mic gain. Conservative on purpose: it only engages when the mic
  /// envelope is far below the reference (no plausible near-end voice), engages
  /// slowly, and releases FAST so voice onsets are never swallowed.
  static let pauseDuckDb: Float = -12.0
  static let pauseDuckMicToRefRatio: Float = 0.25

  struct Result {
    /// The mic to feed into the export/preview. Either the freshly written
    /// cleaned file (`applied == true`) or the original `micURL` unchanged
    /// (`applied == false`).
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

    // 1. Signed bleed delay + peak correlation, on the STRONGEST window so loud
    //    speech elsewhere can't average the bleed below the gate.
    let (delaySamples, corr) = estimateDelay(mic: micN, system: systemN)
    let delayMs = Double(delaySamples) / sampleRate * 1000.0
    guard abs(corr) >= gateCorrelation else {
      // No measurable bleed → leave the mic exactly as recorded.
      return Result(
        cleanedMicURL: micURL, applied: false, bleedCorrelation: corr, delayMs: delayMs,
        reductionDb: 0)
    }

    // 2. Delay-aligned reference (zero-filled shift so no wrap-around artifacts).
    let reference = alignedReference(system: systemN, delaySamples: delaySamples, count: n)

    // 3. Envelopes for double-talk / voice-activity decisions.
    let micEnv = movingRMS(micN)
    let refEnv = movingRMS(reference)

    // 4. NLMS with double-talk freeze → the raw cancelled mic.
    let cleaned = nlmsDoubleTalk(desired: micN, reference: reference, micEnv: micEnv, refEnv: refEnv)

    // 5. Blend by SYSTEM presence: cleaned whenever the system is audible (the
    //    frozen-weight subtraction cannot touch the voice, so this also removes
    //    the bleed hiding under double-talk), raw when the system is silent
    //    (byte-for-byte voice, zero risk). Bleed-level pauses get an extra duck
    //    so the residual stays inaudible even under a +24 dB mic gain.
    let blended = systemPresenceBlend(
      raw: micN, cleaned: cleaned, micEnv: micEnv, refEnv: refEnv)

    // 6. Metrics (coarse, for logging / diagnostics). Measure the residual bleed
    //    the SAME way before and after (mic↔system vs. blended↔system at the same
    //    lag) so the ratio is a faithful reduction, not a comparison of two
    //    different statistics.
    let residualBefore = correlationAtDelay(micN, systemN, delaySamples: delaySamples)
    let residualAfter = correlationAtDelay(blended, systemN, delaySamples: delaySamples)
    let reductionDb = 20.0 * log10(abs(residualAfter) / max(abs(residualBefore), 1e-6) + 1e-9)

    // 7. Write the cleaned mic.
    let url = try writeMonoPCM(blended, directory: outputDirectory)
    return Result(
      cleanedMicURL: url, applied: true, bleedCorrelation: corr, delayMs: delayMs,
      reductionDb: reductionDb)
  }

  /// Build the delay-aligned system reference: `reference[i] = system[i + preroll
  /// − delay]` (zero-filled outside the valid range).
  static func alignedReference(system: [Float], delaySamples: Int, count n: Int) -> [Float] {
    let preroll = Int((prerollSeconds * sampleRate).rounded())
    let offset = preroll - delaySamples
    var reference = [Float](repeating: 0, count: n)
    let m = min(n, system.count)
    for i in 0..<n {
      let j = i + offset
      if j >= 0 && j < m { reference[i] = system[j] }
    }
    return reference
  }

  // MARK: - NLMS

  /// Standard normalized LMS: for each sample `y = wᵀ·window`, `e = d − y`,
  /// `w += µ·e·window / (‖window‖² + ε)`. Returns the error signal `e` (the
  /// cleaned mic). `w` is stored oldest→newest to match the contiguous reference
  /// window, so both the dot product and the update run over the same slice with
  /// no per-sample copy. Exposed (not private) so tests can drive it directly.
  static func nlms(desired: [Float], reference: [Float]) -> [Float] {
    nlmsDoubleTalk(desired: desired, reference: reference, micEnv: nil, refEnv: nil)
  }

  /// NLMS with optional double-talk detection. When `micEnv`/`refEnv` are
  /// provided, the weight update is FROZEN for samples where near-end voice
  /// clearly dominates (`micEnv > doubleTalkRatio · refEnv`), so the filter can
  /// only ever learn the system bleed, never the voice. The filter output is
  /// still produced everywhere; only adaptation pauses. Passing `nil` envelopes
  /// reduces to plain NLMS.
  static func nlmsDoubleTalk(
    desired: [Float], reference: [Float], micEnv: [Float]?, refEnv: [Float]?
  ) -> [Float] {
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

          // Double-talk freeze: skip the update while near-end voice dominates.
          if let micEnv, let refEnv, micEnv[i] > doubleTalkRatio * refEnv[i] + 1e-4 {
            continue
          }

          var scale = stepSize * e / (max(energy, 0) + regularization)
          // weights += scale * window
          vDSP_vsma(window, 1, &scale, wBase, 1, wBase, 1, vDSP_Length(taps))
        }
      }
    }
    return out
  }

  // MARK: - System-presence blend

  /// Emit the CLEANED mic whenever the system audio is present and the RAW mic
  /// when it is silent, crossfaded.
  ///
  /// Why presence and not voice activity: bleed exists exactly when the system
  /// is audible, including UNDER the user's voice (double-talk). The v2 blend
  /// passed the raw mic through during speech, so the bleed hiding under it
  /// survived 100% and became an audible echo once the user raised the mic gain
  /// (gain targets the mic → the bleed rides along; measured on a real
  /// recording: raw −2.8 dB below masker at +24 dB gain, v2 −20 dB, this blend
  /// −31.5 dB — inaudible). The cleaned path is voice-safe by construction:
  /// with double-talk-frozen weights the NLMS output is `mic − w·reference`,
  /// a fixed linear function of the REFERENCE only, so anything uncorrelated
  /// with the system (the voice) passes through untouched.
  ///
  /// Presence = reference envelope above `referencePresentFloor`, dilated
  /// backward by `systemBackfillSeconds` (envelope rise time) and held for
  /// `systemHoldSeconds` (bridges intra-speech gaps so the blend doesn't flap
  /// raw/cleaned inside one system sentence — each flap leaks a bleed edge).
  ///
  /// Duck: while the system is present and the mic envelope is far below the
  /// reference (`< pauseDuckMicToRefRatio·refEnv` — unambiguous bleed/noise,
  /// no plausible near-end voice), attenuate the cleaned path by `pauseDuckDb`
  /// for extra gain headroom. Engages slowly, releases fast, so a voice onset
  /// is never swallowed.
  static func systemPresenceBlend(
    raw: [Float], cleaned: [Float], micEnv: [Float], refEnv: [Float]
  ) -> [Float] {
    let n = raw.count
    guard cleaned.count == n, micEnv.count == n, refEnv.count == n else { return cleaned }

    // System-presence mask: active envelope, dilated back, held forward.
    var present = [Bool](repeating: false, count: n)
    let hold = Int(systemHoldSeconds * sampleRate)
    let backfill = Int(systemBackfillSeconds * sampleRate)
    var lastActive = -hold - 1
    for i in 0..<n {
      if refEnv[i] > referencePresentFloor { lastActive = i }
      present[i] = (i - lastActive) <= hold
    }
    var nextActive = n + backfill + 1
    for i in stride(from: n - 1, through: 0, by: -1) {
      if refEnv[i] > referencePresentFloor { nextActive = i }
      if (nextActive - i) <= backfill { present[i] = true }
    }

    let fast = Float(1.0 - exp(-1.0 / (blendFastSeconds * sampleRate)))
    let slow = Float(1.0 - exp(-1.0 / (blendSlowSeconds * sampleRate)))
    let duckFloor = pow(10.0, pauseDuckDb / 20.0)

    var out = [Float](repeating: 0, count: n)
    var gain: Float = 1.0  // 1 → raw mic, 0 → cleaned mic
    var duck: Float = 1.0  // 1 → no duck, duckFloor → full duck (cleaned path)
    for i in 0..<n {
      let target: Float = present[i] ? 0.0 : 1.0
      // FAST into cleaned (bleed must not leak at system onsets), slow to raw.
      let coeff = target < gain ? fast : slow
      gain += coeff * (target - gain)

      let bleedOnly = present[i] && micEnv[i] < pauseDuckMicToRefRatio * refEnv[i]
      let duckTarget: Float = bleedOnly ? duckFloor : 1.0
      // Engage slowly, release FAST (voice onsets must never be swallowed).
      let duckCoeff = duckTarget < duck ? slow : fast
      duck += duckCoeff * (duckTarget - duck)

      out[i] = gain * raw[i] + (1 - gain) * (cleaned[i] * duck)
    }
    return out
  }

  // MARK: - Offline gain bake

  /// Bake a static gain into a mic file: decode → multiply → clamp ±1.0 → write
  /// CAF. Used by the EXPORT instead of an MTAudioProcessingTap because
  /// `AVAssetReaderAudioMixOutput` applies a per-track tap to the MIXED stream —
  /// a +24 dB mic tap there multiplies the system audio too and the clamp then
  /// squares the whole mix off at 0 dBFS (severe audible distortion whenever the
  /// mic was active with system audio). Baking the gain into the mic file keeps
  /// it mic-only by construction; the clamp matches the tap's historic
  /// `clampFloatOutput` bound so a boosted mic still can't enter the mixdown
  /// above full scale.
  static func bakeGain(micURL: URL, gainDb: Double, outputDirectory: URL) throws -> URL {
    let gainLinear = Float(pow(10.0, max(0.0, min(24.0, gainDb)) / 20.0))
    guard gainLinear > 1.0001 else { return micURL }
    var samples = try decodePCMMono48k(url: micURL)
    guard !samples.isEmpty else { return micURL }
    samples = applyGain(samples, gainLinear: gainLinear)
    return try writeMonoPCM(samples, directory: outputDirectory)
  }

  /// `clamp(x · gain, ±1)` — exposed for tests.
  static func applyGain(_ samples: [Float], gainLinear: Float) -> [Float] {
    var out = samples
    var gain = gainLinear
    vDSP_vsmul(out, 1, &gain, &out, 1, vDSP_Length(out.count))
    var lo: Float = -1.0
    var hi: Float = 1.0
    vDSP_vclip(out, 1, &lo, &hi, &out, 1, vDSP_Length(out.count))
    return out
  }

  // MARK: - Envelope

  /// Moving-RMS envelope over `envelopeWindowSeconds`, computed in O(n) with a
  /// sliding sum of squares.
  static func movingRMS(_ x: [Float]) -> [Float] {
    let n = x.count
    guard n > 0 else { return [] }
    let w = max(1, Int((envelopeWindowSeconds * sampleRate).rounded()))
    var sq = [Float](repeating: 0, count: n)
    vDSP_vsq(x, 1, &sq, 1, vDSP_Length(n))
    var out = [Float](repeating: 0, count: n)
    var running: Float = 0
    for i in 0..<n {
      running += sq[i]
      if i >= w { running -= sq[i - w] }
      let count = Float(min(i + 1, w))
      // `running` can drift a hair below zero from float cancellation → clamp
      // before the sqrt so the envelope never becomes NaN.
      out[i] = (max(running, 0) / count).squareRoot()
    }
    return out
  }

  // MARK: - Delay estimation

  /// Bleed delay (in 48 kHz samples) and its correlation, found by CONSENSUS
  /// across sliding windows. In each window we take the strongest normalized
  /// cross-correlation over the plausible-delay band; real bleed is the same
  /// source delayed, so its peak lands at the SAME lag in every system-present
  /// window, while a coincidental correlation (music, headphone cross-talk) is a
  /// lone window at a random lag. We keep only windows whose peak clears the gate,
  /// cluster them by lag, and return the largest cluster's lag+correlation — but
  /// only if at least `minConsensusWindows` windows agree. Otherwise (0, 0), which
  /// makes cancel() treat it as no bleed. A positive lag `D` means the mic matches
  /// `system[n − D]`; the observed bleed sits at a NEGATIVE lag (system.m4a is
  /// written with more pipeline latency than the mic path).
  static func estimateDelay(mic: [Float], system: [Float]) -> (samples: Int, correlation: Float) {
    let m = delaySearchDecimation
    let a = decimateZeroMean(mic, factor: m)
    let b = decimateZeroMean(system, factor: m)
    let len = min(a.count, b.count)
    guard len > 1 else { return (0, 0) }

    // Cap the search span to half the data so the window guard can still pass on
    // short clips (`2·maxLag + 2 ≤ len`), then floor out implausibly small lags.
    let maxLag = min(Int(maxDelaySeconds * sampleRate / Double(m)), (len - 1) / 2)
    let minLag = Int(minDelaySeconds * sampleRate / Double(m))
    guard maxLag > minLag else { return (0, 0) }
    let win = max(2 * maxLag + 2, Int(detectionWindowSeconds * sampleRate / Double(m)))
    let hop = max(1, win / 2)

    // Per-window peak lags (decimated) that clear the gate.
    var peakLags: [Int] = []
    var peakCorrs: [Float] = []

    a.withUnsafeBufferPointer { ap in
      b.withUnsafeBufferPointer { bp in
        let aBase = ap.baseAddress!
        let bBase = bp.baseAddress!
        var start = 0
        while start < len {
          let end = min(start + win, len)
          if end - start > maxLag + 1 {
            var windowBest: Float = 0
            var windowLag = 0
            // Normalized cross-correlation restricted to this window:
            //   corr(lag) = Σ_i a[i]·b[i−lag],  i ∈ [start, end), i−lag ∈ [0, len)
            for lag in -maxLag...maxLag {
              if abs(lag) < minLag { continue }
              let iLo = max(start, lag)  // need i ≥ lag so i−lag ≥ 0
              let iHi = min(end, len + lag)  // need i−lag < len
              let count = iHi - iLo
              if count <= 1 { continue }
              let aPtr = aBase + iLo
              let bPtr = bBase + (iLo - lag)
              var dot: Float = 0
              var sqA: Float = 0
              var sqB: Float = 0
              vDSP_dotpr(aPtr, 1, bPtr, 1, &dot, vDSP_Length(count))
              vDSP_svesq(aPtr, 1, &sqA, vDSP_Length(count))
              vDSP_svesq(bPtr, 1, &sqB, vDSP_Length(count))
              // Require the reference window to be audibly present (skip silence).
              let refRms = (sqB / Float(count)).squareRoot()
              if refRms < referencePresentFloor { continue }
              let denom = max((sqA * sqB).squareRoot(), 1e-9)
              let c = dot / denom
              if abs(c) > abs(windowBest) {
                windowBest = c
                windowLag = lag
              }
            }
            if abs(windowBest) >= gateCorrelation {
              peakLags.append(windowLag)
              peakCorrs.append(windowBest)
            }
          }
          if end >= len { break }
          start += hop
        }
      }
    }

    guard peakLags.count >= minConsensusWindows else { return (0, 0) }

    // Largest cluster of agreeing lags (a coincidence is a lone outlier).
    let tolerance = Int(clusterToleranceSeconds * sampleRate / Double(m))
    var bestClusterLags: [Int] = []
    var bestClusterCorr: Float = 0
    for i in peakLags.indices {
      var members: [Int] = []
      var strongest: Float = 0
      for j in peakLags.indices where abs(peakLags[j] - peakLags[i]) <= tolerance {
        members.append(peakLags[j])
        if abs(peakCorrs[j]) > abs(strongest) { strongest = peakCorrs[j] }
      }
      if members.count > bestClusterLags.count {
        bestClusterLags = members
        bestClusterCorr = strongest
      }
    }
    guard bestClusterLags.count >= minConsensusWindows else { return (0, 0) }

    let median = bestClusterLags.sorted()[bestClusterLags.count / 2]
    return (median * m, bestClusterCorr)
  }

  /// Normalized correlation of `a` vs `b` at a single (full-rate) lag, measured on
  /// the decimated signals — used only for the reduction metric.
  private static func correlationAtDelay(_ a: [Float], _ b: [Float], delaySamples: Int) -> Float {
    let m = delaySearchDecimation
    let ad = decimateZeroMean(a, factor: m)
    let bd = decimateZeroMean(b, factor: m)
    let len = min(ad.count, bd.count)
    guard len > 1 else { return 0 }
    let lag = Int((Double(delaySamples) / Double(m)).rounded())
    guard abs(lag) < len else { return 0 }
    // Norms must cover the SAME overlap slice as the dot product, otherwise the
    // correlation is under-normalized by the excluded |lag| samples.
    let count = len - abs(lag)
    var dot: Float = 0
    var sqA: Float = 0
    var sqB: Float = 0
    ad.withUnsafeBufferPointer { ap in
      bd.withUnsafeBufferPointer { bp in
        let aPtr = lag >= 0 ? ap.baseAddress! + lag : ap.baseAddress!
        let bPtr = lag >= 0 ? bp.baseAddress! : bp.baseAddress! - lag
        vDSP_dotpr(aPtr, 1, bPtr, 1, &dot, vDSP_Length(count))
        vDSP_svesq(aPtr, 1, &sqA, vDSP_Length(count))
        vDSP_svesq(bPtr, 1, &sqB, vDSP_Length(count))
      }
    }
    return dot / max((sqA * sqB).squareRoot(), 1e-9)
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
