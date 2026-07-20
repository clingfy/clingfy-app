import XCTest

@testable import Clingfy

/// Unit tests for the vendored RNNoise wrapper.
///
/// These pin the three properties that silently break the export when they are
/// wrong — framing, scale, and latency — plus the actual noise suppression. A
/// scale or latency regression does not crash anything: it ships a mic track
/// that is near-silent or 20 ms out of sync.
final class RNNoiseEngineTests: XCTestCase {
  private let sampleRate: Float = 48_000

  // MARK: - Helpers

  /// Deterministic pseudo-random noise in the ±1.0 float range.
  private func noise(count: Int, amplitude: Float = 0.1, seed: UInt32 = 12345) -> [Float] {
    var state = seed
    var out = [Float](repeating: 0, count: count)
    for i in 0..<count {
      state = state &* 1_103_515_245 &+ 12345
      let unit = Float((state >> 16) & 0x7fff) / 16384.0 - 1.0
      out[i] = unit * amplitude
    }
    return out
  }

  /// Speech-like harmonic stack: a 140 Hz fundamental with 12 harmonics under a
  /// slow amplitude envelope. RNNoise is trained on speech, so this is what it
  /// should preserve.
  ///
  /// Normalized so the result PEAKS at `amplitude` — a raw harmonic sum peaks
  /// well above the term it is scaled by, which would otherwise hand the engine
  /// an already-out-of-scale signal and make full-scale assertions meaningless.
  private func voice(count: Int, amplitude: Float = 0.25) -> [Float] {
    var out = [Float](repeating: 0, count: count)
    for i in 0..<count {
      let t = Float(i) / sampleRate
      var sum: Float = 0
      for harmonic in 1...12 {
        sum += sinf(2 * .pi * 140 * Float(harmonic) * t) / Float(harmonic)
      }
      let envelope = 0.5 + 0.5 * sinf(2 * .pi * 3 * t)
      out[i] = sum * envelope
    }
    let rawPeak = peak(out)
    guard rawPeak > 0 else { return out }
    let scale = amplitude / rawPeak
    for i in 0..<count { out[i] *= scale }
    return out
  }

  private func rms(_ samples: ArraySlice<Float>) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
    return (sum / Float(samples.count)).squareRoot()
  }

  private func peak(_ samples: [Float]) -> Float {
    samples.reduce(Float(0)) { max($0, abs($1)) }
  }

  // MARK: - Contract

  func testLibraryFrameSizeMatchesThePinnedConstant() {
    XCTAssertEqual(
      RNNoiseEngine.libraryFrameSize(), RNNoiseEngine.frameSize,
      "The vendored library changed its frame size; the framing loop assumes 480.")
  }

  func testLatencyIsTwoFrames() {
    XCTAssertEqual(RNNoiseEngine.latencySamples, 2 * RNNoiseEngine.frameSize)
  }

  // MARK: - Length and framing

  func testOutputLengthMatchesInputForAnExactFrameMultiple() {
    let input = voice(count: RNNoiseEngine.frameSize * 40)
    let output = RNNoiseEngine.denoise(input, wetMix: 1.0)
    XCTAssertEqual(output.count, input.count)
  }

  func testOutputLengthMatchesInputForARaggedTail() {
    // 40 frames + 137 samples: the tail is shorter than one frame.
    let input = voice(count: RNNoiseEngine.frameSize * 40 + 137)
    let output = RNNoiseEngine.denoise(input, wetMix: 1.0)
    XCTAssertEqual(output.count, input.count)
  }

  func testShorterThanOneFrameStillReturnsTheSameLength() {
    let input = voice(count: 100)
    let output = RNNoiseEngine.denoise(input, wetMix: 1.0)
    XCTAssertEqual(output.count, 100)
  }

  func testEmptyInputIsReturnedUnchanged() {
    XCTAssertTrue(RNNoiseEngine.denoise([], wetMix: 1.0).isEmpty)
  }

  // MARK: - Suppression

  func testNoiseOnlyInputIsStronglyAttenuated() {
    let input = noise(count: Int(sampleRate) * 3, amplitude: 0.1)
    let output = RNNoiseEngine.denoise(input, wetMix: 1.0)
    // Skip the first second: the model needs to converge.
    let skip = Int(sampleRate)
    let before = rms(input[skip...])
    let after = rms(output[skip...])
    XCTAssertLessThan(
      after, before * 0.5,
      "Steady broadband noise should be attenuated by at least 6 dB")
  }

  func testVoiceSurvivesFarBetterThanNoise() {
    let count = Int(sampleRate) * 3
    let skip = Int(sampleRate)
    let backdrop = noise(count: count, amplitude: 0.1)
    var mixed = voice(count: count)
    for i in 0..<count { mixed[i] += backdrop[i] }

    let denoisedNoise = RNNoiseEngine.denoise(backdrop, wetMix: 1.0)
    let denoisedMixed = RNNoiseEngine.denoise(mixed, wetMix: 1.0)

    let residualNoise = rms(denoisedNoise[skip...])
    let survivingVoice = rms(denoisedMixed[skip...])
    XCTAssertGreaterThan(
      survivingVoice, residualNoise * 4,
      "Speech must survive suppression far better than pure noise does")
    XCTAssertGreaterThan(
      survivingVoice, rms(mixed[skip...]) * 0.4,
      "Speech must not be gutted by the suppressor")
  }

  // MARK: - Scale

  /// The library works in the ±32768 short range. If the wrapper ever stops
  /// scaling into it, every recording is treated as near-silence and the output
  /// collapses — which is easy to mistake for very aggressive denoising.
  func testLoudVoiceKeepsItsAmplitudeOrderOfMagnitude() {
    let input = voice(count: Int(sampleRate) * 2, amplitude: 0.25)
    let output = RNNoiseEngine.denoise(input, wetMix: 1.0)
    let skip = Int(sampleRate)
    let inputPeak = peak(Array(input[skip...]))
    let outputPeak = peak(Array(output[skip...]))
    XCTAssertGreaterThan(
      outputPeak, inputPeak * 0.2,
      "Output collapsed — the ±32768 scaling into RNNoise is probably missing")
    XCTAssertLessThan(
      outputPeak, inputPeak * 3.0,
      "Output exploded — the scaling back out of RNNoise is probably wrong")
  }

  /// Suppression reshapes the spectrum, which can push the output peak above the
  /// input's (~1.06–1.08x on normal speech, up to ~1.17x on a hot take). A mic
  /// already near full scale would come back out of range, and the export's
  /// `bakeGain` skips its clamp at unity gain — so the engine has to clamp.
  func testHotInputIsClampedToFullScale() {
    let input = voice(count: Int(sampleRate) * 2, amplitude: 0.99)
    let output = RNNoiseEngine.denoise(input, wetMix: 1.0)
    XCTAssertLessThanOrEqual(peak(output), 1.0)
    XCTAssertGreaterThan(peak(output), 0.5, "The voice must still be there after clamping")
  }

  func testLightMixOfAHotInputIsAlsoClamped() {
    let input = voice(count: Int(sampleRate), amplitude: 0.99)
    XCTAssertLessThanOrEqual(peak(RNNoiseEngine.denoise(input, wetMix: 0.5)), 1.0)
  }

  // MARK: - Alignment

  /// The denoised mic is mixed against the untouched system track, so a bulk
  /// delay here shows up as lip-sync drift in every export. A burst placed at a
  /// known offset must come back at that same offset.
  func testOutputIsSampleAlignedWithInput() {
    let count = Int(sampleRate) * 2
    let burstStart = count / 2
    let burstLength = Int(sampleRate) / 10
    var input = [Float](repeating: 0, count: count)
    let burst = voice(count: burstLength, amplitude: 0.5)
    for i in 0..<burstLength { input[burstStart + i] = burst[i] }

    let output = RNNoiseEngine.denoise(input, wetMix: 1.0)

    // Energy must land in the burst window, not one/two frames later.
    let inWindow = rms(output[burstStart..<(burstStart + burstLength)])
    let afterWindow = rms(
      output[(burstStart + burstLength + RNNoiseEngine.latencySamples)..<count])
    XCTAssertGreaterThan(
      inWindow, afterWindow * 10,
      "Burst energy landed outside its window — latency compensation is wrong")

    // And nothing meaningful may precede the burst.
    let beforeWindow = rms(output[0..<(burstStart - RNNoiseEngine.latencySamples)])
    XCTAssertLessThan(beforeWindow, inWindow * 0.1)
  }

  // MARK: - Wet mix

  func testZeroWetMixIsAPassThrough() {
    let input = voice(count: RNNoiseEngine.frameSize * 10)
    let output = RNNoiseEngine.denoise(input, wetMix: 0)
    XCTAssertEqual(output, input)
  }

  func testLightLeavesMoreNoiseThanBalanced() {
    let input = noise(count: Int(sampleRate) * 3, amplitude: 0.1)
    let skip = Int(sampleRate)
    let light = rms(RNNoiseEngine.denoise(input, wetMix: 0.5)[skip...])
    let balanced = rms(RNNoiseEngine.denoise(input, wetMix: 1.0)[skip...])
    XCTAssertGreaterThan(
      light, balanced,
      "A lighter wet mix must leave more of the original noise in place")
    XCTAssertLessThan(light, rms(input[skip...]), "Light must still reduce noise")
  }

  func testWetMixIsClamped() {
    let input = voice(count: RNNoiseEngine.frameSize * 8)
    let above = RNNoiseEngine.denoise(input, wetMix: 4.0)
    let full = RNNoiseEngine.denoise(input, wetMix: 1.0)
    XCTAssertEqual(above, full)
    XCTAssertEqual(RNNoiseEngine.denoise(input, wetMix: -1.0), input)
  }
}
