import AVFoundation
import XCTest

@testable import Clingfy

/// Covers the decode that feeds the speech recogniser.
///
/// This exists because WhisperKit's own file-loading path has an open bug
/// (argmaxinc/argmax-oss-swift#500) that silently corrupts long compressed
/// audio — no error, success exit code, garbage transcript. Long compressed
/// `.m4a` is exactly what this app records, so the decode is ours and has to be
/// held to the format contract by test.
final class CaptionAudioDecoderTests: XCTestCase {

  private var tempDirectory: URL!

  override func setUpWithError() throws {
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("caption-decoder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
  }

  /// Writes an AAC .m4a at an arbitrary rate and channel count — deliberately
  /// mirroring what the recorder actually produces rather than a convenient
  /// 16 kHz mono WAV, because the whole point is the conversion.
  @discardableResult
  private func writeTone(
    named name: String,
    sampleRate: Double,
    channels: AVAudioChannelCount,
    seconds: Double,
    frequency: Double = 440
  ) throws -> URL {
    let url = tempDirectory.appendingPathComponent(name)
    let format = try XCTUnwrap(
      AVAudioFormat(
        standardFormatWithSampleRate: sampleRate, channels: channels))
    let writer = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: Int(channels),
      ])

    let frames = AVAudioFrameCount(sampleRate * seconds)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
      guard let data = buffer.floatChannelData?[channel] else { continue }
      for frame in 0..<Int(frames) {
        data[frame] = Float(
          sin(2.0 * Double.pi * frequency * Double(frame) / sampleRate) * 0.5)
      }
    }
    try writer.write(from: buffer)
    return url
  }

  // MARK: - Format contract

  /// Whisper is trained on 16 kHz mono. Anything else and the engine resamples,
  /// which is the code path this decoder exists to avoid.
  func testDecodesA44100MonoFileToExactly16kSamplesPerSecond() throws {
    let url = try writeTone(
      named: "mic.m4a", sampleRate: 44_100, channels: 1, seconds: 2.0)
    let samples = try CaptionAudioDecoder.decodeMono16k(url: url)
    // AAC encoders pad, so allow a tolerance rather than demanding exactness.
    XCTAssertEqual(Double(samples.count), 32_000, accuracy: 3_000)
  }

  /// The system tap is 48 kHz stereo while the built-in mic is 44.1 kHz mono —
  /// measured on real recordings from this machine. Both must come out identical.
  func testDecodesA48000StereoFileToTheSameShape() throws {
    let url = try writeTone(
      named: "system.m4a", sampleRate: 48_000, channels: 2, seconds: 2.0)
    let samples = try CaptionAudioDecoder.decodeMono16k(url: url)
    XCTAssertEqual(Double(samples.count), 32_000, accuracy: 3_000)
  }

  func testTwoDifferentSourceFormatsProduceComparableLengths() throws {
    let mic = try writeTone(
      named: "a.m4a", sampleRate: 44_100, channels: 1, seconds: 2.0)
    let system = try writeTone(
      named: "b.m4a", sampleRate: 48_000, channels: 2, seconds: 2.0)
    let micSamples = try CaptionAudioDecoder.decodeMono16k(url: mic)
    let systemSamples = try CaptionAudioDecoder.decodeMono16k(url: system)
    XCTAssertEqual(
      Double(micSamples.count), Double(systemSamples.count), accuracy: 3_000,
      "same duration, different source formats, same output shape")
  }

  func testDecodedSamplesAreInRange() throws {
    let url = try writeTone(
      named: "tone.m4a", sampleRate: 44_100, channels: 1, seconds: 1.0)
    let samples = try CaptionAudioDecoder.decodeMono16k(url: url)
    XCTAssertFalse(samples.isEmpty)
    for sample in samples {
      XCTAssertLessThanOrEqual(abs(sample), 1.001, "sample outside [-1, 1]")
      XCTAssertFalse(sample.isNaN, "NaN in decoded audio")
    }
  }

  /// A 440 Hz tone survives the resample as real signal, not silence. Length
  /// alone would pass on a buffer of zeros — which is precisely the shape the
  /// upstream corruption bug produces.
  func testDecodedAudioCarriesActualSignalNotSilence() throws {
    let url = try writeTone(
      named: "tone.m4a", sampleRate: 44_100, channels: 1, seconds: 1.0)
    let samples = try CaptionAudioDecoder.decodeMono16k(url: url)
    var sumOfSquares: Double = 0
    for sample in samples { sumOfSquares += Double(sample) * Double(sample) }
    let rms = (sumOfSquares / Double(max(samples.count, 1))).squareRoot()
    XCTAssertGreaterThan(rms, 0.05, "decoded to silence — the failure mode of #500")
  }

  // MARK: - Failure paths

  func testMissingFileThrowsRatherThanReturningEmpty() {
    let missing = tempDirectory.appendingPathComponent("nope.m4a")
    XCTAssertThrowsError(try CaptionAudioDecoder.decodeMono16k(url: missing)) { error in
      // An empty transcript and an unreadable file must not look the same.
      XCTAssertTrue(error is CaptionAudioDecoder.DecodeError || error is NSError)
    }
  }

  func testCancellationStopsTheDecodePromptly() throws {
    let url = try writeTone(
      named: "long.m4a", sampleRate: 44_100, channels: 1, seconds: 5.0)
    XCTAssertThrowsError(
      try CaptionAudioDecoder.decodeMono16k(url: url, isCancelled: { true })
    ) { error in
      XCTAssertEqual(error as? CaptionAudioDecoder.DecodeError, .cancelled)
    }
  }

  // MARK: - Normalisation

  /// The recogniser gets the RAW sidecar — the user's gain is baked in only at
  /// export — so a quiet recording would otherwise transcribe worse for no
  /// reason. Normalising in memory avoids keying transcription on any
  /// user-adjustable setting, which is what keeps it deterministic.
  func testQuietAudioIsBroughtUp() {
    var samples: [Float] = [0.05, -0.05, 0.025, -0.025]
    CaptionAudioDecoder.normalizePeak(&samples)
    let peak = samples.map { abs($0) }.max() ?? 0
    XCTAssertEqual(peak, 0.95, accuracy: 0.001)
  }

  func testRelativeShapeIsPreserved() {
    var samples: [Float] = [0.1, 0.05, -0.025]
    CaptionAudioDecoder.normalizePeak(&samples)
    XCTAssertEqual(samples[0] / samples[1], 2.0, accuracy: 0.001)
    XCTAssertEqual(samples[1] / samples[2], -2.0, accuracy: 0.001)
  }

  /// Scaling room tone up to full scale manufactures exactly the noise Whisper
  /// hallucinates over. The floor is not an optimisation.
  func testNearSilenceIsLeftAloneRatherThanAmplifiedIntoNoise() {
    var samples: [Float] = [0.0002, -0.0001, 0.00005]
    let before = samples
    CaptionAudioDecoder.normalizePeak(&samples)
    XCTAssertEqual(samples, before, "room tone must not be amplified")
  }

  func testAlreadyLoudAudioIsNotAttenuated() {
    var samples: [Float] = [0.99, -0.98]
    let before = samples
    CaptionAudioDecoder.normalizePeak(&samples)
    XCTAssertEqual(samples, before, "normalisation lifts, it does not compress")
  }

  func testEmptyInputIsHarmless() {
    var samples: [Float] = []
    CaptionAudioDecoder.normalizePeak(&samples)
    XCTAssertTrue(samples.isEmpty)
  }

  // MARK: - Against a real recording, when one is present

  /// Skips on a machine without recordings so CI is unaffected. When a real
  /// project IS present this is the only test exercising a genuine multi-minute
  /// compressed capture, which is the input profile #500 corrupts.
  func testDecodesARealRecordingWhenOneIsAvailable() throws {
    let recordings = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/com.clingfy.clingfy.dev/Recordings")
    let projects =
      (try? FileManager.default.contentsOfDirectory(
        at: recordings, includingPropertiesForKeys: nil)) ?? []

    var source: URL?
    for project in projects where project.pathExtension == "clingfyproj" {
      for name in ["capture/mic.m4a", "capture/system.m4a"] {
        let candidate = project.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate.path) {
          source = candidate
          break
        }
      }
      if source != nil { break }
    }

    let url = try XCTSkipIfNil(source, "no real recording with an audio sidecar")
    let samples = try CaptionAudioDecoder.decodeMono16k(url: url)
    XCTAssertGreaterThan(samples.count, 16_000, "under a second of audio decoded")

    let seconds = Double(samples.count) / CaptionAudioDecoder.targetSampleRate
    let assetSeconds = CMTimeGetSeconds(AVAsset(url: url).duration)
    XCTAssertEqual(
      seconds, assetSeconds, accuracy: 0.5,
      "decoded duration drifted from the container's — the shape #500 takes")
  }

  private func XCTSkipIfNil<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw XCTSkip(message) }
    return value
  }
}
