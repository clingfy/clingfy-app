import AVFoundation
import Foundation

/// Which separated capture source an audio artifact belongs to.
///
/// Phase 1.5 of the editing initiative keeps microphone and system audio as
/// separate files inside the `.clingfyproj` bundle (`capture/mic.m4a` +
/// `capture/system.m4a`) so later enhancement stages can process the mic
/// without damaging system/music/game audio. The embedded audio tracks in
/// `capture/screen.mov` are unchanged — these files are additive.
enum AudioSourceKind: String, CaseIterable {
  case microphone = "mic"
  case systemAudio = "system"

  var finalFileName: String { "\(rawValue).m4a" }

  func segmentFileName(index: Int) -> String {
    "\(rawValue).segment-\(String(format: "%03d", index)).m4a"
  }
}

/// One finished per-segment audio file for one source.
struct AudioSegmentArtifact {
  let index: Int
  let kind: AudioSourceKind
  let url: URL
}

/// Encodes one audio source's sample buffers for a single recording segment
/// into an AAC `.m4a` file.
///
/// Appends arrive on the SCStream sample-handler queue for that source;
/// lifecycle transitions (finish/cancel) arrive from the backend's task
/// context. All state is guarded by `lock` so a finish can never race an
/// in-flight append. Failures are terminal for the writer but must never
/// affect the recording itself — callers treat a nil finish result as
/// "this source has no separated audio".
@available(macOS 15.0, *)
final class AudioSourceSegmentWriter {
  private enum State {
    case awaitingFirstBuffer
    case writing
    case finishing
    case failed
  }

  /// AAC bitrate per channel at 48 kHz; stereo sources encode at 192 kbps —
  /// strictly above the 64-100 kbps track SCRecordingOutput embeds in screen.mov.
  static let aacBitRatePerChannel = 96_000

  /// Floor so a pathologically low sample rate cannot ask for an unusably thin
  /// stream.
  static let minAacBitRatePerChannel = 16_000

  /// The AAC bitrate to request for a source arriving at [sampleRate].
  ///
  /// AAC's legal bitrate range scales with the sample rate, and the mic is the
  /// one source whose rate we do not control: a Bluetooth headset runs HFP and
  /// arrives at 8 or 16 kHz, where a flat 96 kbps per channel is far out of
  /// range. AVAssetWriter then rejects the whole writer with
  /// `-11861 "The encoding parameters are not supported"` (underlying -12651),
  /// the segment is discarded with zero samples appended, and the take comes
  /// back with no voice at all.
  ///
  /// Observed in the field on a JBL WAVE100TWS (Bluetooth "Headset"): the mic
  /// writer failed to start while `system.m4a` — 48 kHz from ScreenCaptureKit —
  /// encoded fine, which is what isolated the sample rate as the variable.
  ///
  /// ~2 bits per sample, which evaluates to exactly [aacBitRatePerChannel] at
  /// 48 kHz, so every existing 48 kHz path is bit-for-bit unchanged.
  static func aacBitRate(sampleRate: Double, channels: Int) -> Int {
    let perChannel = min(
      aacBitRatePerChannel,
      max(minAacBitRatePerChannel, Int(sampleRate * 2))
    )
    return perChannel * channels
  }

  let kind: AudioSourceKind
  let index: Int
  let url: URL

  private let lock = NSLock()
  private var state: State = .awaitingFirstBuffer
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var appendedBufferCount = 0
  private var droppedBufferCount = 0

  init(kind: AudioSourceKind, index: Int, url: URL) {
    self.kind = kind
    self.index = index
    self.url = url
  }

  /// Hot path — called once per sample buffer on the capture queue.
  func append(_ sampleBuffer: CMSampleBuffer) {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

    lock.lock()
    defer { lock.unlock() }

    switch state {
    case .awaitingFirstBuffer:
      do {
        try setUpLocked(firstBuffer: sampleBuffer)
        state = .writing
      } catch {
        state = .failed
        NativeLogger.w(
          "SourceAudio", "Failed to start source audio writer",
          context: ["kind": kind.rawValue, "segment": index, "error": "\(error)"])
        return
      }
      appendLocked(sampleBuffer)
    case .writing:
      appendLocked(sampleBuffer)
    case .finishing, .failed:
      return
    }
  }

  private func appendLocked(_ sampleBuffer: CMSampleBuffer) {
    guard let writer, let input else { return }
    if writer.status == .failed {
      state = .failed
      NativeLogger.w(
        "SourceAudio", "Source audio writer failed mid-segment",
        context: [
          "kind": kind.rawValue,
          "segment": index,
          "error": "\(writer.error.map { "\($0)" } ?? "unknown")",
        ])
      return
    }
    guard input.isReadyForMoreMediaData else {
      droppedBufferCount += 1
      return
    }
    if input.append(sampleBuffer) {
      appendedBufferCount += 1
    } else {
      droppedBufferCount += 1
    }
  }

  private func setUpLocked(firstBuffer: CMSampleBuffer) throws {
    guard let formatDescription = CMSampleBufferGetFormatDescription(firstBuffer) else {
      throw flutterError(NativeErrorCode.recordingError, "Audio buffer missing format description")
    }
    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
    let sampleRate = (asbd?.mSampleRate ?? 0) > 0 ? asbd!.mSampleRate : 48_000
    let channels = min(max(Int(asbd?.mChannelsPerFrame ?? 2), 1), 2)

    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: url.path) {
      try? fileManager.removeItem(at: url)
    }

    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: channels,
      AVEncoderBitRateKey: Self.aacBitRate(sampleRate: sampleRate, channels: channels),
    ]
    let input = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: settings,
      sourceFormatHint: formatDescription
    )
    input.expectsMediaDataInRealTime = true

    guard writer.canAdd(input) else {
      throw flutterError(NativeErrorCode.recordingError, "Audio writer rejected input")
    }
    writer.add(input)
    guard writer.startWriting() else {
      throw writer.error
        ?? flutterError(NativeErrorCode.recordingError, "Audio writer failed to start")
    }
    writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(firstBuffer))

    self.writer = writer
    self.input = input
  }

  /// Finalizes the segment file. Returns the URL when a playable file with at
  /// least one appended buffer was produced, nil otherwise (partials deleted).
  func finish() async -> URL? {
    lock.lock()
    let priorState = state
    state = .finishing
    let writer = self.writer
    let input = self.input
    let appended = appendedBufferCount
    let dropped = droppedBufferCount
    lock.unlock()

    guard priorState == .writing, let writer, let input, appended > 0 else {
      cancelWriterAndDeleteFile(writer)
      if priorState != .awaitingFirstBuffer {
        NativeLogger.w(
          "SourceAudio", "Discarding source audio segment",
          context: [
            "kind": kind.rawValue,
            "segment": index,
            "priorState": "\(priorState)",
            "appended": appended,
          ])
      }
      return nil
    }

    input.markAsFinished()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      writer.finishWriting {
        continuation.resume()
      }
    }

    guard writer.status == .completed else {
      NativeLogger.w(
        "SourceAudio", "Source audio finalize failed",
        context: [
          "kind": kind.rawValue,
          "segment": index,
          "status": "\(writer.status.rawValue)",
          "error": "\(writer.error.map { "\($0)" } ?? "unknown")",
        ])
      try? FileManager.default.removeItem(at: url)
      return nil
    }

    if dropped > 0 {
      NativeLogger.w(
        "SourceAudio", "Source audio segment dropped buffers",
        context: ["kind": kind.rawValue, "segment": index, "dropped": dropped])
    }
    return url
  }

  /// Aborts the segment and deletes any partial file. Safe to call twice.
  func cancel() {
    lock.lock()
    state = .finishing
    let writer = self.writer
    self.writer = nil
    self.input = nil
    lock.unlock()

    cancelWriterAndDeleteFile(writer)
  }

  private func cancelWriterAndDeleteFile(_ writer: AVAssetWriter?) {
    if let writer, writer.status == .writing {
      writer.cancelWriting()
    }
    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }
  }
}

/// Owns the per-segment source audio writers for one recording run.
///
/// The backend prepares a segment's writers when it prepares the matching
/// SCRecordingOutput, activates them when the segment actually starts
/// recording, and finishes them when the segment is removed — so the audio
/// files track the screen segments' lifecycle. Buffers that arrive while no
/// segment is active (before start, while paused) are dropped, matching what
/// SCRecordingOutput records.
@available(macOS 15.0, *)
final class SourceAudioRecorder {
  private struct SegmentWriters {
    let index: Int
    let writers: [AudioSourceKind: AudioSourceSegmentWriter]
  }

  private let lock = NSLock()
  private var directory: URL?
  private var enabledSources: Set<AudioSourceKind> = []
  private var prepared: SegmentWriters?
  private var active: SegmentWriters?
  private var attachedStreamID: ObjectIdentifier?
  private var finishedArtifactURLs: [URL] = []

  func configure(directory: URL, micEnabled: Bool, systemAudioEnabled: Bool) {
    var sources: Set<AudioSourceKind> = []
    if micEnabled { sources.insert(.microphone) }
    if systemAudioEnabled { sources.insert(.systemAudio) }

    lock.lock()
    self.directory = directory
    self.enabledSources = sources
    lock.unlock()

    NativeLogger.i(
      "SourceAudio", "Source audio recorder configured",
      context: [
        "directory": directory.path,
        "mic": micEnabled,
        "system": systemAudioEnabled,
      ])
  }

  /// Records which SCStream's buffers this run accepts. A dying stream from a
  /// failed prior attempt can keep delivering on the shared capture queues
  /// after `stopCapture` was requested; its buffers must never reach the new
  /// run's writers.
  func attachStream(id: ObjectIdentifier) {
    lock.lock()
    attachedStreamID = id
    lock.unlock()
  }

  func prepareSegment(index: Int) {
    lock.lock()
    guard let directory, !enabledSources.isEmpty else {
      lock.unlock()
      return
    }
    let stalePrepared = prepared
    var writers: [AudioSourceKind: AudioSourceSegmentWriter] = [:]
    for kind in enabledSources {
      let url = directory.appendingPathComponent(kind.segmentFileName(index: index), isDirectory: false)
      writers[kind] = AudioSourceSegmentWriter(kind: kind, index: index, url: url)
    }
    prepared = SegmentWriters(index: index, writers: writers)
    lock.unlock()

    stalePrepared?.writers.values.forEach { $0.cancel() }
  }

  func activatePreparedSegment(index: Int) {
    lock.lock()
    guard let prepared, prepared.index == index else {
      lock.unlock()
      return
    }
    let staleActive = active
    active = prepared
    self.prepared = nil
    lock.unlock()

    staleActive?.writers.values.forEach { $0.cancel() }
  }

  /// Hot path — called once per sample buffer on the source's capture queue.
  /// Buffers from any stream other than the attached one are dropped.
  func append(_ sampleBuffer: CMSampleBuffer, source: AudioSourceKind, from streamID: ObjectIdentifier) {
    lock.lock()
    let writer = attachedStreamID == streamID ? active?.writers[source] : nil
    lock.unlock()
    writer?.append(sampleBuffer)
  }

  func finishActiveSegment() async -> [AudioSegmentArtifact] {
    lock.lock()
    let segment = active
    active = nil
    lock.unlock()

    guard let segment else { return [] }

    var artifacts: [AudioSegmentArtifact] = []
    for (kind, writer) in segment.writers {
      if let url = await writer.finish() {
        artifacts.append(AudioSegmentArtifact(index: segment.index, kind: kind, url: url))
      }
    }

    lock.lock()
    finishedArtifactURLs.append(contentsOf: artifacts.map(\.url))
    lock.unlock()

    return artifacts
  }

  /// Cancels everything in flight and deletes partial segment files — plus
  /// finished-but-unmerged segment files, so a mid-recording failure can't
  /// orphan audio inside the bundle. Used on failure/retry/reset paths; a
  /// no-op after a successful merge (the merger consumed/deleted the files).
  func cancelAndCleanup() {
    lock.lock()
    let stale = [prepared, active].compactMap { $0 }
    let finished = finishedArtifactURLs
    prepared = nil
    active = nil
    directory = nil
    enabledSources = []
    attachedStreamID = nil
    finishedArtifactURLs = []
    lock.unlock()

    for segment in stale {
      segment.writers.values.forEach { $0.cancel() }
    }
    let fileManager = FileManager.default
    for url in finished where fileManager.fileExists(atPath: url.path) {
      try? fileManager.removeItem(at: url)
    }
  }
}

/// Merges per-segment source audio files into the final `capture/mic.m4a` /
/// `capture/system.m4a`, tiling each segment at the same cumulative offsets
/// the screen segment merger uses (each slot advances by the SCREEN segment's
/// recorded duration). Audio shorter than its slot is padded with explicit
/// silence; audio longer is truncated — so pauses can never accumulate drift
/// between the merged audio and the merged screen video.
///
/// Accepted tail behavior: a TRAILING empty range is discarded by
/// AVAssetExportSession, so when the LAST segment's audio under-fills its
/// slot the merged file simply ends early. Every downstream consumer of
/// project audio already tolerates audio shorter than video (the embedded
/// screen.mov track has the same property); mid-timeline alignment is what
/// the silence fill must — and does — protect.
@available(macOS 15.0, *)
enum AudioSegmentMerger {
  struct SegmentInput {
    /// nil when this source has no file for the segment (writer failed) —
    /// the slot is filled with silence to preserve alignment.
    let url: URL?
    let slotDuration: TimeInterval
  }

  private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
  }

  @discardableResult
  static func mergeSegments(
    _ segments: [SegmentInput],
    to outputURL: URL,
    fileManager: FileManager = .default
  ) async throws -> URL {
    guard !segments.isEmpty, segments.contains(where: { $0.url != nil }) else {
      throw flutterError(NativeErrorCode.recordingError, "No source audio segments to merge")
    }

    if fileManager.fileExists(atPath: outputURL.path) {
      try fileManager.removeItem(at: outputURL)
    }

    if segments.count == 1, let onlyURL = segments[0].url {
      try fileManager.moveItem(at: onlyURL, to: outputURL)
      return outputURL
    }

    let composition = AVMutableComposition()
    guard
      let compositionTrack = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      throw flutterError(
        NativeErrorCode.recordingError, "Unable to create source audio composition track")
    }

    var cursorTime = CMTime.zero
    var insertedAnyAudio = false
    var hasGaps = false

    for segment in segments {
      let slotDuration = CMTime(
        seconds: max(0, segment.slotDuration), preferredTimescale: 1000)
      guard slotDuration > .zero else { continue }

      var insertedDuration = CMTime.zero
      if let url = segment.url {
        let asset = AVURLAsset(url: url)
        if let track = asset.tracks(withMediaType: .audio).first {
          insertedDuration = CMTimeMinimum(track.timeRange.duration, slotDuration)
          if insertedDuration > .zero {
            try compositionTrack.insertTimeRange(
              CMTimeRange(start: track.timeRange.start, duration: insertedDuration),
              of: track,
              at: cursorTime
            )
            insertedAnyAudio = true
          }
        }
      }

      if insertedDuration < slotDuration {
        compositionTrack.insertEmptyTimeRange(
          CMTimeRange(start: cursorTime + insertedDuration, duration: slotDuration - insertedDuration)
        )
        hasGaps = true
      }
      cursorTime = cursorTime + slotDuration
    }

    guard insertedAnyAudio else {
      throw flutterError(NativeErrorCode.recordingError, "Source audio segments contained no audio")
    }

    // Passthrough cannot export a composition containing empty ranges — with
    // gaps, go straight to the re-encoding preset instead of a doomed attempt.
    let presetNames =
      hasGaps
      ? [AVAssetExportPresetAppleM4A]
      : [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A]
    var lastError: Error?

    for presetName in presetNames {
      guard let export = AVAssetExportSession(asset: composition, presetName: presetName) else {
        continue
      }
      let exportBox = ExportSessionBox(export)

      export.outputURL = outputURL
      export.outputFileType = .m4a
      export.shouldOptimizeForNetworkUse = false

      do {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          export.exportAsynchronously {
            let export = exportBox.session
            switch export.status {
            case .completed:
              continuation.resume(returning: ())
            case .failed:
              continuation.resume(
                throwing: export.error
                  ?? flutterError(NativeErrorCode.recordingError, "Source audio merge failed")
              )
            case .cancelled:
              continuation.resume(
                throwing: flutterError(NativeErrorCode.recordingError, "Source audio merge cancelled")
              )
            default:
              continuation.resume(
                throwing: flutterError(NativeErrorCode.recordingError, "Source audio merge incomplete")
              )
            }
          }
        }
        return outputURL
      } catch {
        lastError = error
        if fileManager.fileExists(atPath: outputURL.path) {
          try? fileManager.removeItem(at: outputURL)
        }
      }
    }

    throw lastError
      ?? flutterError(
        NativeErrorCode.recordingError, "Unable to create export session for source audio merge")
  }
}
