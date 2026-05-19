import AVFoundation
import XCTest

@testable import Clingfy

/// Pins AudioLevelEstimator behavior after it was extracted out of
/// ScreenRecorderFacade.swift (Commit 1 of the strangler refactor).
final class AudioLevelEstimatorTests: XCTestCase {

  // MARK: dbfs(for:)

  func testDbfsForUnityIsZero() {
    XCTAssertEqual(AudioLevelEstimator.dbfs(for: 1.0), 0.0, accuracy: 0.0001)
  }

  func testDbfsForHalfIsApproxMinusSixDb() {
    XCTAssertEqual(AudioLevelEstimator.dbfs(for: 0.5), -6.0206, accuracy: 0.001)
  }

  func testDbfsClampsSilenceToFloor() {
    // max(linear, 1e-9) -> 20*log10(1e-9) = -180 dB
    XCTAssertEqual(AudioLevelEstimator.dbfs(for: 0.0), -180.0, accuracy: 0.0001)
    XCTAssertEqual(AudioLevelEstimator.dbfs(for: -5.0), -180.0, accuracy: 0.0001)
  }

  // MARK: estimatePeak — float32

  func testEstimatePeakFloat32ReturnsAbsolutePeak() throws {
    let samples: [Float] = [0.1, -0.75, 0.5, 0.25, -0.3]
    let buffer = try makeFloat32SampleBuffer(samples)

    let result = try XCTUnwrap(AudioLevelEstimator.estimatePeak(sampleBuffer: buffer))

    XCTAssertEqual(result.linear, 0.75, accuracy: 0.0001)
    XCTAssertEqual(result.dbfs, AudioLevelEstimator.dbfs(for: 0.75), accuracy: 0.0001)
  }

  func testEstimatePeakFloat32ClampsAboveUnity() throws {
    let samples: [Float] = [0.2, -1.8, 0.4]
    let buffer = try makeFloat32SampleBuffer(samples)

    let result = try XCTUnwrap(AudioLevelEstimator.estimatePeak(sampleBuffer: buffer))

    XCTAssertEqual(result.linear, 1.0, accuracy: 0.0001)
    XCTAssertEqual(result.dbfs, 0.0, accuracy: 0.0001)
  }

  // MARK: estimatePeak — int16

  func testEstimatePeakInt16NormalizesAgainstInt16Max() throws {
    let half = Int16(Int16.max / 2)
    let samples: [Int16] = [123, -half, 200]
    let buffer = try makeInt16SampleBuffer(samples)

    let result = try XCTUnwrap(AudioLevelEstimator.estimatePeak(sampleBuffer: buffer))

    XCTAssertEqual(
      result.linear, Double(half) / Double(Int16.max), accuracy: 0.0005)
  }

  func testEstimatePeakInt16MinMapsToUnity() throws {
    let samples: [Int16] = [10, Int16.min, -20]
    let buffer = try makeInt16SampleBuffer(samples)

    let result = try XCTUnwrap(AudioLevelEstimator.estimatePeak(sampleBuffer: buffer))

    XCTAssertEqual(result.linear, 1.0, accuracy: 0.0001)
  }

  // MARK: helpers

  private func makeFloat32SampleBuffer(_ samples: [Float]) throws -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0)
    return try makeSampleBuffer(
      asbd: &asbd, bytes: samples.withUnsafeBufferPointer { Data(buffer: $0) },
      frameCount: samples.count)
  }

  private func makeInt16SampleBuffer(_ samples: [Int16]) throws -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2,
      mFramesPerPacket: 1,
      mBytesPerFrame: 2,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 16,
      mReserved: 0)
    return try makeSampleBuffer(
      asbd: &asbd, bytes: samples.withUnsafeBufferPointer { Data(buffer: $0) },
      frameCount: samples.count)
  }

  private func makeSampleBuffer(
    asbd: inout AudioStreamBasicDescription, bytes: Data, frameCount: Int
  ) throws -> CMSampleBuffer {
    var formatDesc: CMAudioFormatDescription?
    var status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
      magicCookieSize: 0, magicCookie: nil, extensions: nil,
      formatDescriptionOut: &formatDesc)
    XCTAssertEqual(status, noErr, "format description create failed")
    let format = try XCTUnwrap(formatDesc)

    var blockBuffer: CMBlockBuffer?
    let length = bytes.count
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: length, alignment: MemoryLayout<UInt8>.alignment)
    bytes.copyBytes(
      to: raw.bindMemory(to: UInt8.self, capacity: length), count: length)
    status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: raw, blockLength: length,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: length, flags: 0, blockBufferOut: &blockBuffer)
    XCTAssertEqual(status, noErr, "block buffer create failed")
    let block = try XCTUnwrap(blockBuffer)

    var sampleBuffer: CMSampleBuffer?
    status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
      sampleCount: frameCount, presentationTimeStamp: .zero,
      packetDescriptions: nil, sampleBufferOut: &sampleBuffer)
    XCTAssertEqual(status, noErr, "sample buffer create failed")
    return try XCTUnwrap(sampleBuffer)
  }
}
