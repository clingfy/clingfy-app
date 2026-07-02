import AVFoundation
import XCTest

@testable import Clingfy

/// Phase 1.5 audio source-separation: per-source segment writer, segment
/// merger, and the bundle/manifest plumbing for capture/mic.m4a +
/// capture/system.m4a.
@available(macOS 15.0, *)
final class AudioSourceRecordingTests: XCTestCase {
  private var tempDirectory: URL!

  override func setUpWithError() throws {
    tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AudioSourceRecordingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDirectory {
      try? FileManager.default.removeItem(at: tempDirectory)
    }
  }

  // MARK: - Naming

  func testAudioSourceKindFileNames() {
    XCTAssertEqual(AudioSourceKind.microphone.finalFileName, "mic.m4a")
    XCTAssertEqual(AudioSourceKind.systemAudio.finalFileName, "system.m4a")
    XCTAssertEqual(AudioSourceKind.microphone.segmentFileName(index: 1), "mic.segment-001.m4a")
    XCTAssertEqual(AudioSourceKind.systemAudio.segmentFileName(index: 12), "system.segment-012.m4a")
  }

  // MARK: - Segment writer

  func testWriterEncodesBuffersToPlayableAACFile() async throws {
    let url = tempDirectory.appendingPathComponent("mic.segment-001.m4a")
    let writer = AudioSourceSegmentWriter(kind: .microphone, index: 1, url: url)

    for buffer in try makePCMSampleBuffers(totalSeconds: 0.5) {
      writer.append(buffer)
    }

    let finishedURL = await writer.finish()
    XCTAssertEqual(finishedURL, url)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

    let asset = AVURLAsset(url: url)
    let tracks = asset.tracks(withMediaType: .audio)
    XCTAssertEqual(tracks.count, 1)

    let duration = asset.duration.seconds
    XCTAssertEqual(duration, 0.5, accuracy: 0.15)

    let formatDescriptions = tracks[0].formatDescriptions as! [CMFormatDescription]
    XCTAssertEqual(
      CMFormatDescriptionGetMediaSubType(formatDescriptions[0]),
      kAudioFormatMPEG4AAC
    )
  }

  func testWriterWithNoBuffersProducesNoFile() async {
    let url = tempDirectory.appendingPathComponent("system.segment-001.m4a")
    let writer = AudioSourceSegmentWriter(kind: .systemAudio, index: 1, url: url)

    let finishedURL = await writer.finish()
    XCTAssertNil(finishedURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testWriterEncodesPlanarBuffersLikeLiveSCKDelivery() async throws {
    // ScreenCaptureKit delivers non-interleaved (planar) Float32; the writer
    // must accept that layout, not just the packed test default.
    let url = tempDirectory.appendingPathComponent("system.segment-003.m4a")
    let writer = AudioSourceSegmentWriter(kind: .systemAudio, index: 3, url: url)

    for buffer in try makePCMSampleBuffers(totalSeconds: 0.4, interleaved: false) {
      writer.append(buffer)
    }

    let finishedURL = await writer.finish()
    XCTAssertEqual(finishedURL, url)

    let asset = AVURLAsset(url: url)
    XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1)
    XCTAssertEqual(asset.duration.seconds, 0.4, accuracy: 0.15)
  }

  func testWriterCancelDeletesPartialFile() async throws {
    let url = tempDirectory.appendingPathComponent("mic.segment-002.m4a")
    let writer = AudioSourceSegmentWriter(kind: .microphone, index: 2, url: url)

    for buffer in try makePCMSampleBuffers(totalSeconds: 0.2) {
      writer.append(buffer)
    }
    writer.cancel()

    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

    let finishedURL = await writer.finish()
    XCTAssertNil(finishedURL)
  }

  // MARK: - Coordinator

  func testRecorderOnlyWritesEnabledSourcesAndActiveSegments() async throws {
    let recorder = SourceAudioRecorder()
    let streamToken = NSObject()
    let streamID = ObjectIdentifier(streamToken)
    recorder.configure(directory: tempDirectory, micEnabled: true, systemAudioEnabled: false)
    recorder.attachStream(id: streamID)

    let buffers = try makePCMSampleBuffers(totalSeconds: 0.3)

    // No prepared/active segment yet: buffers are dropped.
    recorder.append(buffers[0], source: .microphone, from: streamID)

    recorder.prepareSegment(index: 1)
    // Prepared but not active: still dropped.
    recorder.append(buffers[0], source: .microphone, from: streamID)

    recorder.activatePreparedSegment(index: 1)
    for buffer in buffers {
      recorder.append(buffer, source: .microphone, from: streamID)
      // System audio is disabled; these must be ignored without side effects.
      recorder.append(buffer, source: .systemAudio, from: streamID)
      // Buffers from a stale stream must never reach the writers.
      recorder.append(buffer, source: .microphone, from: ObjectIdentifier(NSNull()))
    }

    let artifacts = await recorder.finishActiveSegment()
    XCTAssertEqual(artifacts.count, 1)
    XCTAssertEqual(artifacts.first?.kind, .microphone)
    XCTAssertEqual(artifacts.first?.index, 1)
    let micURL = tempDirectory.appendingPathComponent("mic.segment-001.m4a")
    XCTAssertEqual(artifacts.first?.url, micURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: tempDirectory.appendingPathComponent("system.segment-001.m4a").path))

    // Finishing again is a no-op.
    let secondFinish = await recorder.finishActiveSegment()
    XCTAssertTrue(secondFinish.isEmpty)
  }

  func testRecorderCancelAndCleanupDeletesInFlightFiles() async throws {
    let recorder = SourceAudioRecorder()
    let streamToken = NSObject()
    let streamID = ObjectIdentifier(streamToken)
    recorder.configure(directory: tempDirectory, micEnabled: true, systemAudioEnabled: true)
    recorder.attachStream(id: streamID)
    recorder.prepareSegment(index: 1)
    recorder.activatePreparedSegment(index: 1)

    for buffer in try makePCMSampleBuffers(totalSeconds: 0.2) {
      recorder.append(buffer, source: .microphone, from: streamID)
      recorder.append(buffer, source: .systemAudio, from: streamID)
    }

    recorder.cancelAndCleanup()

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: tempDirectory.appendingPathComponent("mic.segment-001.m4a").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: tempDirectory.appendingPathComponent("system.segment-001.m4a").path))

    let artifacts = await recorder.finishActiveSegment()
    XCTAssertTrue(artifacts.isEmpty)
  }

  func testRecorderCancelAndCleanupDeletesFinishedUnmergedFiles() async throws {
    // A segment finished by a pause, then a failure before the merge: the
    // finished file must not be orphaned inside the bundle.
    let recorder = SourceAudioRecorder()
    let streamID = ObjectIdentifier(NSObject())
    recorder.configure(directory: tempDirectory, micEnabled: true, systemAudioEnabled: false)
    recorder.attachStream(id: streamID)
    recorder.prepareSegment(index: 1)
    recorder.activatePreparedSegment(index: 1)
    for buffer in try makePCMSampleBuffers(totalSeconds: 0.2) {
      recorder.append(buffer, source: .microphone, from: streamID)
    }

    let artifacts = await recorder.finishActiveSegment()
    XCTAssertEqual(artifacts.count, 1)
    let finishedURL = artifacts[0].url
    XCTAssertTrue(FileManager.default.fileExists(atPath: finishedURL.path))

    recorder.cancelAndCleanup()
    XCTAssertFalse(FileManager.default.fileExists(atPath: finishedURL.path))
  }

  // MARK: - Segment merger

  func testMergerSingleSegmentRenamesToFinal() async throws {
    let segmentURL = try await writeAudioSegment(named: "mic.segment-001.m4a", seconds: 0.4)
    let finalURL = tempDirectory.appendingPathComponent("mic.m4a")

    let mergedURL = try await AudioSegmentMerger.mergeSegments(
      [.init(url: segmentURL, slotDuration: 0.4)],
      to: finalURL
    )

    XCTAssertEqual(mergedURL, finalURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: segmentURL.path))
  }

  func testMergerTilesSegmentsAtScreenSlotOffsetsWithSilenceFill() async throws {
    // Segment 1's audio (0.3s) is shorter than its screen slot (0.5s): the
    // shortfall must be silence-filled so segment 2 still starts at 0.5s.
    let segment1 = try await writeAudioSegment(named: "mic.segment-001.m4a", seconds: 0.3)
    let segment2 = try await writeAudioSegment(named: "mic.segment-002.m4a", seconds: 0.5)
    let finalURL = tempDirectory.appendingPathComponent("mic.m4a")

    try await AudioSegmentMerger.mergeSegments(
      [
        .init(url: segment1, slotDuration: 0.5),
        .init(url: segment2, slotDuration: 0.5),
      ],
      to: finalURL
    )

    let asset = AVURLAsset(url: finalURL)
    XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1)
    XCTAssertEqual(asset.duration.seconds, 1.0, accuracy: 0.15)
  }

  func testMergerFillsMissingSegmentWithSilence() async throws {
    // A segment whose writer failed contributes a nil URL; its slot must be
    // silence so later segments stay aligned with the merged screen video.
    let segment2 = try await writeAudioSegment(named: "mic.segment-002.m4a", seconds: 0.4)
    let finalURL = tempDirectory.appendingPathComponent("mic.m4a")

    try await AudioSegmentMerger.mergeSegments(
      [
        .init(url: nil, slotDuration: 0.5),
        .init(url: segment2, slotDuration: 0.4),
      ],
      to: finalURL
    )

    let asset = AVURLAsset(url: finalURL)
    XCTAssertEqual(asset.duration.seconds, 0.9, accuracy: 0.15)
  }

  func testMergerTrailingShortfallEndsEarlyByDesign() async throws {
    // Pinned accepted behavior: a trailing empty range is discarded by the
    // export, so when the LAST slot is under-filled the merged audio simply
    // ends early. Consumers already tolerate audio shorter than video; only
    // MID-timeline alignment is protected by silence fill.
    let segment1 = try await writeAudioSegment(named: "mic.segment-001.m4a", seconds: 0.5)
    let segment2 = try await writeAudioSegment(named: "mic.segment-002.m4a", seconds: 0.2)
    let finalURL = tempDirectory.appendingPathComponent("mic.m4a")

    try await AudioSegmentMerger.mergeSegments(
      [
        .init(url: segment1, slotDuration: 0.5),
        .init(url: segment2, slotDuration: 0.5),
      ],
      to: finalURL
    )

    let asset = AVURLAsset(url: finalURL)
    let duration = asset.duration.seconds
    // Segment 2's audio must still START at 0.5 (alignment holds)…
    XCTAssertGreaterThanOrEqual(duration, 0.55)
    // …but the trailing 0.3s shortfall is not padded out to 1.0.
    XCTAssertLessThanOrEqual(duration, 0.9)
  }

  func testMergerThrowsWhenNoSegmentHasAudio() async {
    let finalURL = tempDirectory.appendingPathComponent("mic.m4a")

    do {
      try await AudioSegmentMerger.mergeSegments(
        [.init(url: nil, slotDuration: 0.5)],
        to: finalURL
      )
      XCTFail("Expected merge to throw with no real audio")
    } catch {
      XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
    }
  }

  // MARK: - Bundle/manifest plumbing

  func testProjectPathsRegisterSeparatedAudioArtifacts() {
    let root = URL(fileURLWithPath: "/tmp/example.clingfyproj")
    let micURL = RecordingProjectPaths.micAudioURL(for: root)
    let systemURL = RecordingProjectPaths.systemAudioURL(for: root)

    XCTAssertEqual(micURL.path, "/tmp/example.clingfyproj/capture/mic.m4a")
    XCTAssertEqual(systemURL.path, "/tmp/example.clingfyproj/capture/system.m4a")
    XCTAssertEqual(RecordingProjectPaths.relativeMicAudioPath, "capture/mic.m4a")
    XCTAssertEqual(RecordingProjectPaths.relativeSystemAudioPath, "capture/system.m4a")

    XCTAssertTrue(RecordingProjectPaths.allProjectArtifactURLs(for: root).contains(micURL))
    XCTAssertTrue(RecordingProjectPaths.allProjectArtifactURLs(for: root).contains(systemURL))
    XCTAssertTrue(RecordingProjectPaths.durableProjectStateURLs(for: root).contains(micURL))
    XCTAssertTrue(RecordingProjectPaths.durableProjectStateURLs(for: root).contains(systemURL))
    XCTAssertTrue(RecordingProjectPaths.durableCaptureArtifactFileURLs(for: root).contains(micURL))
    XCTAssertTrue(
      RecordingProjectPaths.durableCaptureArtifactFileURLs(for: root).contains(systemURL))
  }

  func testManifestPreSeedsSeparatedAudioPaths() {
    let manifest = RecordingProjectManifest.create(
      projectId: "rec_test",
      displayName: "Test",
      includeCamera: false
    )
    XCTAssertEqual(manifest.capture.micAudio, "capture/mic.m4a")
    XCTAssertEqual(manifest.capture.systemAudio, "capture/system.m4a")
  }

  func testManifestWithoutAudioKeysStillDecodes() throws {
    // Manifests written before Phase 1.5 (and by the Windows writer) have no
    // micAudio/systemAudio keys; they must keep decoding with nil fields.
    let legacyJSON = """
      {
        "schemaVersion": 2,
        "projectId": "rec_legacy",
        "createdAt": "2026-01-01T00:00:00Z",
        "updatedAt": "2026-01-01T00:00:00Z",
        "displayName": "Legacy",
        "status": "ready",
        "capture": {
          "screenVideo": "capture/screen.mov",
          "screenMetadata": "capture/screen.meta.json"
        },
        "exportHistory": []
      }
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(
      RecordingProjectManifest.self, from: Data(legacyJSON.utf8))

    XCTAssertNil(manifest.capture.micAudio)
    XCTAssertNil(manifest.capture.systemAudio)
  }

  func testMediaSourcesGateSeparatedAudioOnFileExistence() throws {
    let projectRoot = tempDirectory.appendingPathComponent("proj.clingfyproj", isDirectory: true)
    let captureDir = projectRoot.appendingPathComponent("capture", isDirectory: true)
    try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)

    let manifest = RecordingProjectManifest.create(
      projectId: "proj",
      displayName: "Proj",
      includeCamera: false
    )
    try manifest.write(to: RecordingProjectPaths.manifestURL(for: projectRoot))

    let ref = try RecordingProjectRef.open(projectRoot: projectRoot)

    // Files absent: media sources must expose nil, not dangling paths.
    let before = ref.mediaSources()
    XCTAssertNil(before.micAudioURL)
    XCTAssertNil(before.systemAudioURL)

    // Files present: resolved from the manifest's relative paths.
    try Data().write(to: RecordingProjectPaths.micAudioURL(for: projectRoot))
    try Data().write(to: RecordingProjectPaths.systemAudioURL(for: projectRoot))
    let after = ref.mediaSources()
    XCTAssertEqual(after.micAudioURL, RecordingProjectPaths.micAudioURL(for: projectRoot))
    XCTAssertEqual(after.systemAudioURL, RecordingProjectPaths.systemAudioURL(for: projectRoot))
  }

  // MARK: - Helpers

  /// Builds Float32 48 kHz stereo PCM sample buffers covering `totalSeconds`,
  /// split into ~50ms chunks like a live capture stream. `interleaved: false`
  /// produces the non-interleaved (planar) layout ScreenCaptureKit delivers.
  private func makePCMSampleBuffers(
    totalSeconds: Double,
    sampleRate: Double = 48_000,
    channels: UInt32 = 2,
    interleaved: Bool = true
  ) throws -> [CMSampleBuffer] {
    let bytesPerFrame = interleaved ? 4 * channels : 4
    var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    if !interleaved {
      flags |= kAudioFormatFlagIsNonInterleaved
    }
    var asbd = AudioStreamBasicDescription(
      mSampleRate: sampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: flags,
      mBytesPerPacket: bytesPerFrame,
      mFramesPerPacket: 1,
      mBytesPerFrame: bytesPerFrame,
      mChannelsPerFrame: channels,
      mBitsPerChannel: 32,
      mReserved: 0
    )

    var formatDescription: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbd,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription else {
      throw NSError(domain: "AudioSourceRecordingTests", code: Int(formatStatus))
    }

    let chunkFrames = Int(sampleRate * 0.05)
    let totalFrames = Int(sampleRate * totalSeconds)
    var buffers: [CMSampleBuffer] = []
    var frameCursor = 0

    while frameCursor < totalFrames {
      let frames = min(chunkFrames, totalFrames - frameCursor)
      // Planar layouts store each channel's plane back-to-back in the block.
      let byteCount = frames * Int(asbd.mBytesPerFrame) * (interleaved ? 1 : Int(channels))

      var blockBuffer: CMBlockBuffer?
      var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: 0,
        blockBufferOut: &blockBuffer
      )
      guard status == kCMBlockBufferNoErr, let blockBuffer else {
        throw NSError(domain: "AudioSourceRecordingTests", code: Int(status))
      }
      status = CMBlockBufferFillDataBytes(
        with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
      guard status == kCMBlockBufferNoErr else {
        throw NSError(domain: "AudioSourceRecordingTests", code: Int(status))
      }

      var sampleBuffer: CMSampleBuffer?
      let pts = CMTime(
        value: CMTimeValue(frameCursor), timescale: CMTimeScale(sampleRate))
      status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: frames,
        presentationTimeStamp: pts,
        packetDescriptions: nil,
        sampleBufferOut: &sampleBuffer
      )
      guard status == noErr, let sampleBuffer else {
        throw NSError(domain: "AudioSourceRecordingTests", code: Int(status))
      }

      buffers.append(sampleBuffer)
      frameCursor += frames
    }

    return buffers
  }

  private func writeAudioSegment(named name: String, seconds: Double) async throws -> URL {
    let url = tempDirectory.appendingPathComponent(name)
    let writer = AudioSourceSegmentWriter(kind: .microphone, index: 1, url: url)
    for buffer in try makePCMSampleBuffers(totalSeconds: seconds) {
      writer.append(buffer)
    }
    guard let finishedURL = await writer.finish() else {
      throw NSError(domain: "AudioSourceRecordingTests", code: -1)
    }
    return finishedURL
  }
}
