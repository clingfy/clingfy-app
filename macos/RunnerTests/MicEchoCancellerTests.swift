import AVFoundation
import XCTest

@testable import Clingfy

/// Tests for the speaker→mic bleed canceller. The bleed is a delayed, scaled copy
/// of the (clean) system reference added to an uncorrelated "voice"; a correct
/// canceller drives the residual mic↔system correlation toward zero while leaving
/// the voice intact (voice is uncorrelated with the reference, so it cannot be
/// removed).
final class MicEchoCancellerTests: XCTestCase {

  // Deterministic white-ish noise in [-1, 1] (seeded LCG) so tests are stable.
  private func noise(_ count: Int, seed: UInt64) -> [Float] {
    var state = seed &+ 0x9E37_79B9_7F4A_7C15
    var out = [Float](repeating: 0, count: count)
    for i in 0..<count {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let bits = UInt32(truncatingIfNeeded: state >> 32)
      out[i] = (Float(bits) / Float(UInt32.max)) * 2 - 1
    }
    return out
  }

  private func zeroMeanUnit(_ x: ArraySlice<Float>) -> [Float] {
    var a = Array(x)
    guard !a.isEmpty else { return a }
    let mean = a.reduce(0, +) / Float(a.count)
    for i in a.indices { a[i] -= mean }
    let norm = sqrt(a.reduce(0) { $0 + $1 * $1 })
    if norm > 0 {
      for i in a.indices { a[i] /= norm }
    }
    return a
  }

  private func correlation(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Float {
    let ua = zeroMeanUnit(a)
    let ub = zeroMeanUnit(b)
    let n = min(ua.count, ub.count)
    var s: Float = 0
    for i in 0..<n { s += ua[i] * ub[i] }
    return s
  }

  /// Correlation of `a` vs `b` at `lag` (a[n] ~ b[n-lag]).
  private func correlationAtLag(_ a: [Float], _ b: [Float], lag: Int) -> Float {
    if lag >= 0 {
      guard a.count > lag, b.count > lag else { return 0 }
      return correlation(a[lag...], b[..<(b.count - lag)])
    }
    let l = -lag
    guard a.count > l, b.count > l else { return 0 }
    return correlation(a[..<(a.count - l)], b[l...])
  }

  private func writeCAF(_ samples: [Float], name: String) throws -> URL {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: MicEchoCanceller.sampleRate, channels: 1,
      interleaved: false)!
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer {
      buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
    }
    try file.write(from: buffer)
    return url
  }

  // MARK: - NLMS

  func testNlmsRemovesCorrelatedBleedPreservingVoice() {
    let n = 48_000
    let voice = noise(n, seed: 1)
    let reference = noise(n, seed: 2)
    let delay = 12
    let gain: Float = 0.6

    var desired = voice
    for i in delay..<n { desired[i] = voice[i] + gain * reference[i - delay] }

    let cleaned = MicEchoCanceller.nlms(desired: desired, reference: reference)
    XCTAssertEqual(cleaned.count, n)

    // Measure after convergence (second half).
    let half = n / 2
    let before = abs(
      correlationAtLag(Array(desired[half..<n]), Array(reference[half..<n]), lag: delay))
    let after = abs(
      correlationAtLag(Array(cleaned[half..<n]), Array(reference[half..<n]), lag: delay))

    XCTAssertGreaterThan(before, 0.3, "the synthetic bleed should be strongly present")
    XCTAssertLessThan(after, 0.12, "the bleed should be largely cancelled")
    XCTAssertLessThan(after, before * 0.4, "cancellation should be a big reduction")

    // Voice preserved: cleaned ≈ voice in the converged region.
    let voiceKeep = correlation(cleaned[half..<n], voice[half..<n])
    XCTAssertGreaterThan(voiceKeep, 0.85, "the uncorrelated voice must survive cancellation")
  }

  func testNlmsIsStableAndNoOpWithoutCorrelatedReference() {
    let n = 24_000
    let voice = noise(n, seed: 5)
    let reference = noise(n, seed: 6)  // independent → nothing to cancel
    let cleaned = MicEchoCanceller.nlms(desired: voice, reference: reference)
    // Output must stay finite and close to the input (no divergence, no voice loss).
    XCTAssertTrue(cleaned.allSatisfy { $0.isFinite })
    let keep = correlation(cleaned[(n / 2)..<n], voice[(n / 2)..<n])
    XCTAssertGreaterThan(keep, 0.9)
  }

  // MARK: - Delay estimation

  func testEstimateDelayFindsBleedLagAndCorrelation() {
    let n = 48_000
    let voice = noise(n, seed: 3)
    let system = noise(n, seed: 4)
    let delay = 2_640  // ~55 ms at 48 kHz
    let gain: Float = 0.6

    var mic = voice
    for i in delay..<n { mic[i] = voice[i] + gain * system[i - delay] }

    let (samples, corr) = MicEchoCanceller.estimateDelay(mic: mic, system: system)
    // Coarse (decimation-limited) but must land near the true lag with a
    // correlation well above the gate.
    XCTAssertEqual(
      samples, delay, accuracy: MicEchoCanceller.delaySearchDecimation * 2,
      "detected bleed lag should match the synthetic delay")
    XCTAssertGreaterThan(abs(corr), MicEchoCanceller.gateCorrelation)
  }

  // MARK: - End-to-end cancel()

  func testCancelReducesBleedEndToEnd() throws {
    let n = 48_000
    let voice = noise(n, seed: 7)
    let system = noise(n, seed: 8)
    let delay = 2_640
    let gain: Float = 0.6

    var mic = voice
    for i in delay..<n { mic[i] = voice[i] + gain * system[i - delay] }

    let micURL = try writeCAF(mic, name: "mic.caf")
    let systemURL = try writeCAF(system, name: "system.caf")
    let outDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let result = try MicEchoCanceller.cancel(
      micURL: micURL, systemURL: systemURL, outputDirectory: outDir)

    XCTAssertTrue(result.applied, "a real bleed should be cancelled")
    XCTAssertNotEqual(result.cleanedMicURL, micURL, "a fresh cleaned file should be written")
    XCTAssertLessThan(result.reductionDb, -6, "at least ~6 dB bleed reduction")

    let cleaned = try MicEchoCanceller.decodePCMMono48k(url: result.cleanedMicURL)
    let m = min(cleaned.count, system.count)
    let half = m / 2
    let before = abs(correlationAtLag(Array(mic[half..<m]), Array(system[half..<m]), lag: delay))
    let after = abs(
      correlationAtLag(Array(cleaned[half..<m]), Array(system[half..<m]), lag: delay))
    XCTAssertLessThan(after, before * 0.4, "residual bleed should be much smaller than input")
  }

  func testCancelBypassesWhenNoBleed() throws {
    let n = 48_000
    let voice = noise(n, seed: 9)
    let system = noise(n, seed: 10)  // independent → no bleed

    let micURL = try writeCAF(voice, name: "mic.caf")
    let systemURL = try writeCAF(system, name: "system.caf")
    let outDir = FileManager.default.temporaryDirectory

    let result = try MicEchoCanceller.cancel(
      micURL: micURL, systemURL: systemURL, outputDirectory: outDir)

    XCTAssertFalse(result.applied, "no bleed ⇒ canceller must be a no-op")
    XCTAssertEqual(result.cleanedMicURL, micURL, "bypass returns the original mic unchanged")
    XCTAssertLessThan(abs(result.bleedCorrelation), MicEchoCanceller.gateCorrelation)
  }

  /// Colored (tonal) independent audio: the OLD single-strongest-window gate
  /// could exceed 0.15 on colored signals with no bleed at all (e.g. headphones +
  /// music), engaging the canceller and smearing a system ghost into a clean mic.
  /// Consensus requires many windows to agree on ONE lag, which independent
  /// sources never do, so it must stay a no-op.
  func testCancelBypassesColoredIndependentAudio() throws {
    let n = 96_000  // 2 s → enough windows for a real consensus decision
    func colored(_ seed: UInt64) -> [Float] {
      let raw = noise(n, seed: seed)
      var y = [Float](repeating: 0, count: n)
      let a: Float = 0.95  // one-pole low-pass → colored / music-like
      var acc: Float = 0
      for i in 0..<n {
        acc = a * acc + (1 - a) * raw[i]
        y[i] = acc
      }
      return y
    }
    let micURL = try writeCAF(colored(21), name: "mic.caf")
    let systemURL = try writeCAF(colored(22), name: "system.caf")

    let result = try MicEchoCanceller.cancel(
      micURL: micURL, systemURL: systemURL, outputDirectory: FileManager.default.temporaryDirectory)

    XCTAssertFalse(
      result.applied, "independent colored audio has no consistent bleed lag → must be a no-op")
    XCTAssertEqual(result.cleanedMicURL, micURL, "bypass returns the original mic unchanged")
  }

  // MARK: - Windowed detection (the core v2 fix)

  /// The real bug: bleed lives only in the speech PAUSES, so a single global
  /// correlation is averaged below the gate by the loud speech and the canceller
  /// never fires. The windowed estimator must still find it.
  func testEstimateDelayFindsBleedMaskedBySpeech() {
    let n = 96_000  // 2 s
    let system = noise(n, seed: 11).map { $0 * 0.5 }
    let voice = noise(n, seed: 12)
    let delay = 4_800  // 100 ms
    let half = n / 2

    var mic = [Float](repeating: 0, count: n)
    // First half: LOUD speech, no bleed (masks any correlation globally).
    for i in 0..<half { mic[i] = 2.0 * voice[i] }
    // Second half: a quiet PAUSE that is pure speaker bleed of the system.
    for i in half..<n { mic[i] = 0.3 * system[i - delay] }

    // Global correlation is tiny (loud speech dominates the mic energy)…
    let globalCorr = abs(correlationAtLag(mic, system, lag: delay))
    XCTAssertLessThan(
      globalCorr, MicEchoCanceller.gateCorrelation,
      "a global correlation should be masked below the gate by the speech")

    // …but the windowed estimator finds the bleed in the pause window.
    let (samples, corr) = MicEchoCanceller.estimateDelay(mic: mic, system: system)
    XCTAssertEqual(
      samples, delay, accuracy: MicEchoCanceller.delaySearchDecimation * 2,
      "windowed detection should recover the pause-time bleed lag")
    XCTAssertGreaterThan(
      abs(corr), MicEchoCanceller.gateCorrelation,
      "the strongest window must clear the gate so the canceller engages")
  }

  // MARK: - Double-talk freeze

  /// When near-end voice dominates, adaptation must FREEZE so the filter never
  /// learns (and thus cancels) the voice — while still cancelling when allowed.
  func testDoubleTalkFreezeSuspendsAdaptation() {
    let n = 24_000
    let system = noise(n, seed: 13)
    let delay = 12
    var desired = [Float](repeating: 0, count: n)
    for i in delay..<n { desired[i] = 0.5 * system[i - delay] }  // pure bleed

    // Force a permanent freeze (mic envelope always far above the reference):
    // weights never leave zero, so the filter passes the input through.
    let frozenEnv = [Float](repeating: 100, count: n)
    let refEnv = MicEchoCanceller.movingRMS(system)
    let frozen = MicEchoCanceller.nlmsDoubleTalk(
      desired: desired, reference: system, micEnv: frozenEnv, refEnv: refEnv)
    for i in stride(from: 0, to: n, by: 1_000) {
      XCTAssertEqual(frozen[i], desired[i], accuracy: 1e-6, "frozen adaptation must pass-through")
    }

    // With adaptation allowed (nil envelopes) the same signal IS cancelled.
    let adapted = MicEchoCanceller.nlmsDoubleTalk(
      desired: desired, reference: system, micEnv: nil, refEnv: nil)
    let half = n / 2
    let before = abs(correlationAtLag(Array(desired[half..<n]), Array(system[half..<n]), lag: delay))
    let after = abs(correlationAtLag(Array(adapted[half..<n]), Array(system[half..<n]), lag: delay))
    XCTAssertLessThan(after, before * 0.7, "unfrozen adaptation should cancel the bleed")
  }

  // MARK: - End-to-end: preserve voice, cancel pause bleed

  /// The whole point: a recording with a loud-speech segment (with bleed under
  /// it) followed by a bleed-only pause must come out with the speech intact and
  /// the pause bleed gone.
  func testCancelPreservesLoudVoiceAndCancelsPauseBleed() throws {
    let n = 96_000
    let system = noise(n, seed: 14).map { $0 * 0.5 }
    let voice = noise(n, seed: 15)
    let delay = 4_800
    let half = n / 2

    var mic = [Float](repeating: 0, count: n)
    // Double-talk: loud voice + bleed under it.
    for i in 0..<half { mic[i] = 2.0 * voice[i] + (i >= delay ? 0.3 * system[i - delay] : 0) }
    // Pause: bleed only.
    for i in half..<n { mic[i] = 0.3 * system[i - delay] }

    let micURL = try writeCAF(mic, name: "mic.caf")
    let systemURL = try writeCAF(system, name: "system.caf")
    let outDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let result = try MicEchoCanceller.cancel(
      micURL: micURL, systemURL: systemURL, outputDirectory: outDir)
    XCTAssertTrue(result.applied, "the pause bleed should trigger cancellation")

    let cleaned = try MicEchoCanceller.decodePCMMono48k(url: result.cleanedMicURL)
    let m = min(cleaned.count, n)
    let hi = min(half, m)

    // Speech region: the loud voice survives essentially untouched (blend passes
    // the raw mic where near-end voice is present).
    let voiceKeep = correlation(cleaned[0..<hi], mic[0..<hi])
    XCTAssertGreaterThan(voiceKeep, 0.95, "loud speech must be preserved")

    // Pause region: the bleed is strongly reduced.
    let before = abs(
      correlationAtLag(Array(mic[half..<m]), Array(system[half..<m]), lag: delay))
    let after = abs(
      correlationAtLag(Array(cleaned[half..<m]), Array(system[half..<m]), lag: delay))
    XCTAssertGreaterThan(before, 0.3, "the synthetic pause bleed should be strongly present")
    XCTAssertLessThan(after, before * 0.4, "the pause bleed should be largely cancelled")
  }
}
