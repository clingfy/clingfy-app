import AVFoundation
import Foundation

/// Joins the parts of a paused recording that could not be joined when it
/// stopped.
///
/// When every merge preset fails, the screen side publishes one part as
/// `capture/screen.mov` and sets the others aside, listed in
/// `capture/segments.unmerged.json`. The camera side keeps its parts in
/// `camera/segments` with `camera/segments.unmerged.json` and the take
/// finishes with no camera. Both manifests hold what a later join needs, and
/// this is that join: it runs at launch, long after the session is gone.
///
/// Crash safety. Every output is built in `.repair/` inside the project,
/// never over a file it reads: `screen.mov`, `cursor.json` and the audio files
/// are inputs as well as outputs, and the mergers delete their output first.
/// Once everything is built, `.repair/commit.json` lists the moves and
/// deletions, and only then do they happen. A staging folder without
/// `commit.json` is thrown away at the next run; one with it is finished. A
/// staged file that is gone has already been moved, so re-running is safe.
///
/// Attempts are capped, since a failure can be reproducible. The count lives
/// in each manifest's `repair` block and is written BEFORE the attempt, so a
/// crash during the join still counts. The first attempt joins every part, as
/// the stop did, with the H.264 preset the stop lacked. Later ones leave out
/// parts that cannot play on their own, which is the likeliest reason the
/// join failed. Each new app version gets one more try.
/// Sendable by hand: it holds a file manager and a clock, used from one task.
struct SalvagedTakeRepairer: @unchecked Sendable {
  enum Outcome: Equatable {
    case nothingToRepair
    case repaired
    case failed(String)
    /// Stopped before committing (a recording started, or it ran too long).
    /// Nothing changed and the attempt is not counted: the next launch
    /// tries again.
    case cancelled
  }

  static let maxAttempts = 3
  static let stagingDirectoryName = ".repair"
  static let commitFileName = "commit.json"
  /// Written into the camera manifest by the stop that dropped the camera:
  /// the editor's camera visibility before it was turned off, so a repair can
  /// put it back as it was.
  static let cameraVisibleKey = "editorCameraVisible"

  static let screenPresetOrder = [
    AVAssetExportPresetPassthrough, AVAssetExportPresetHEVCHighestQuality,
    AVAssetExportPresetHighestQuality,
  ]

  let fileManager: FileManager
  let screenPresets: [String]
  let cameraPresets: [String]
  let appVersion: String
  let now: () -> Date

  init(
    fileManager: FileManager = .default,
    screenPresets: [String] = SalvagedTakeRepairer.screenPresetOrder,
    cameraPresets: [String] = CameraRecorder.mergePresetOrder,
    appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
      ?? "unknown",
    now: @escaping () -> Date = Date.init
  ) {
    self.fileManager = fileManager
    self.screenPresets = screenPresets
    self.cameraPresets = cameraPresets
    self.appVersion = appVersion
    self.now = now
  }

  // MARK: - Paths

  static func screenManifestURL(for projectRoot: URL) -> URL {
    RecordingProjectPaths.captureDirectoryURL(for: projectRoot)
      .appendingPathComponent(RecordingSegmentMerger.unmergedManifestName)
  }

  static func cameraManifestURL(for projectRoot: URL) -> URL {
    RecordingProjectPaths.cameraDirectoryURL(for: projectRoot)
      .appendingPathComponent(RecordingSegmentMerger.unmergedManifestName)
  }

  static func stagingURL(for projectRoot: URL) -> URL {
    projectRoot.appendingPathComponent(stagingDirectoryName, isDirectory: true)
  }

  static func commitURL(for projectRoot: URL) -> URL {
    stagingURL(for: projectRoot).appendingPathComponent(commitFileName)
  }

  // MARK: - What needs a repair

  /// True when the project has parts left to join that have not used up
  /// their attempts, a camera that is gone for good but still named in
  /// project.json, or a repair that stopped while committing.
  func needsRepair(projectRoot: URL) -> Bool {
    if fileManager.fileExists(atPath: Self.commitURL(for: projectRoot).path) { return true }
    if let screen = readJSON(Self.screenManifestURL(for: projectRoot)), !isSettled(screen) {
      return true
    }
    if let camera = readJSON(Self.cameraManifestURL(for: projectRoot)) {
      return !isSettled(camera) || cameraNeedsDropping(projectRoot: projectRoot)
    }
    return false
  }

  /// Out of attempts for this app version.
  private func isExhausted(_ manifest: [String: Any]) -> Bool {
    let repair = manifest["repair"] as? [String: Any] ?? [:]
    let attempts = repair["attempts"] as? Int ?? 0
    let lastVersion = repair["appVersion"] as? String
    return attempts >= Self.maxAttempts && lastVersion == appVersion
  }

  /// Nothing more to try: out of attempts, or joined already, with only the
  /// parts that could not be used left listed.
  private func isSettled(_ manifest: [String: Any]) -> Bool {
    (manifest["repair"] as? [String: Any])?["joinedAt"] != nil || isExhausted(manifest)
  }

  /// A camera that will not be rebuilt, while project.json still names its
  /// file: opening checks every named file, so the take would be refused.
  private func cameraNeedsDropping(projectRoot: URL) -> Bool {
    guard
      !fileManager.fileExists(atPath: RecordingProjectPaths.cameraRawURL(for: projectRoot).path),
      let manifest = try? RecordingProjectManifest.read(
        from: RecordingProjectPaths.manifestURL(for: projectRoot))
    else { return false }
    return manifest.camera != nil
  }

  /// Counts an attempt in [manifest] at [url] and returns its number, or nil
  /// when the count could not be saved (an attempt that cannot be counted
  /// could repeat forever, so it does not run).
  private func recordAttempt(_ manifest: inout [String: Any], at url: URL) -> Int? {
    var repair = manifest["repair"] as? [String: Any] ?? [:]
    let attempt = (repair["attempts"] as? Int ?? 0) + 1
    repair["attempts"] = attempt
    repair["appVersion"] = appVersion
    repair["lastAttemptAt"] = NativeLogger.isoFormatter.string(from: now())
    manifest["repair"] = repair
    return writeJSON(manifest, to: url) ? attempt : nil
  }

  /// Takes back an attempt that was cancelled rather than failed.
  private func undoAttempt(at url: URL) {
    guard var manifest = readJSON(url) else { return }
    var repair = manifest["repair"] as? [String: Any] ?? [:]
    repair["attempts"] = max(0, (repair["attempts"] as? Int ?? 1) - 1)
    manifest["repair"] = repair
    _ = writeJSON(manifest, to: url)
  }

  private func recordFailure(_ message: String, in manifest: inout [String: Any], at url: URL) {
    var repair = manifest["repair"] as? [String: Any] ?? [:]
    repair["lastError"] = message
    manifest["repair"] = repair
    _ = writeJSON(manifest, to: url)
  }

  /// What becomes of a manifest once its parts are joined: deleted when
  /// everything it lists was used, otherwise rewritten (as part of the
  /// commit) to list only what was left, marked joined so it is not retried.
  private func settleManifest(
    _ manifest: [String: Any], at url: URL, leftOut: [String], projectRoot: URL,
    stagedName: String, plan: inout CommitPlan
  ) {
    guard !leftOut.isEmpty else {
      plan.delete(url, root: projectRoot)
      return
    }
    var settled = manifest
    var repair = settled["repair"] as? [String: Any] ?? [:]
    repair["joinedAt"] = NativeLogger.isoFormatter.string(from: now())
    repair["leftOut"] = leftOut
    settled["repair"] = repair
    let staged = Self.stagingURL(for: projectRoot).appendingPathComponent(stagedName)
    if writeJSON(settled, to: staged) {
      plan.lateMove(staged, to: url, root: projectRoot)
    }
  }

  // MARK: - Repair

  func repair(projectRoot: URL) async -> Outcome {
    let staging = Self.stagingURL(for: projectRoot)
    if let plan = readJSON(Self.commitURL(for: projectRoot)) {
      NativeLogger.i(
        "Repair", "Finishing a repair that stopped while committing",
        context: ["project": projectRoot.lastPathComponent])
      guard commit(plan, projectRoot: projectRoot) else {
        return .failed("The commit could not finish; it is retried at the next launch")
      }
      return plan["outcome"] as? String == "repaired"
        ? .repaired : .failed("The repair only dropped a camera that could not be rebuilt")
    }
    if fileManager.fileExists(atPath: staging.path) {
      try? fileManager.removeItem(at: staging)
    }

    let screenManifestURL = Self.screenManifestURL(for: projectRoot)
    let cameraManifestURL = Self.cameraManifestURL(for: projectRoot)
    var screenManifest = readJSON(screenManifestURL).flatMap { isSettled($0) ? nil : $0 }
    let cameraRecord = readJSON(cameraManifestURL)
    var cameraManifest = cameraRecord.flatMap { isSettled($0) ? nil : $0 }
    let cameraDropDue =
      cameraRecord.map(isSettled) == true && cameraNeedsDropping(projectRoot: projectRoot)
    guard screenManifest != nil || cameraManifest != nil || cameraDropDue else {
      return .nothingToRepair
    }

    do {
      try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    } catch {
      return .failed("Could not create the staging folder: \(error.localizedDescription)")
    }

    var plan = CommitPlan()
    plan.dropCamera = cameraDropDue
    var failures: [String] = []
    var attempted: [URL] = []
    func cancelled() -> Outcome {
      try? fileManager.removeItem(at: staging)
      attempted.forEach(undoAttempt)
      NativeLogger.i(
        "Repair", "Repair stopped before committing; it is tried again at the next launch",
        context: ["project": projectRoot.lastPathComponent])
      return .cancelled
    }

    // The camera first: the screen metadata written below names it.
    var restoredCamera: CameraRecordingMetadata?
    if var manifest = cameraManifest {
      if let attempt = recordAttempt(&manifest, at: cameraManifestURL) {
        attempted.append(cameraManifestURL)
        do {
          restoredCamera = try await stageCamera(
            manifest, attempt: attempt, projectRoot: projectRoot, plan: &plan)
          if let visible = manifest[Self.cameraVisibleKey] as? Bool {
            plan.cameraVisible = visible
          }
        } catch {
          if Task.isCancelled { return cancelled() }
          let message = RecordingSegmentMerger.describe(error)
          failures.append("camera: \(message)")
          recordFailure(message, in: &manifest, at: cameraManifestURL)
          // Out of attempts: the take stays without a camera, and must open
          // as one. A later run does this too, if this one never commits.
          if isExhausted(manifest), cameraNeedsDropping(projectRoot: projectRoot) {
            plan.dropCamera = true
          }
        }
      } else {
        failures.append("camera: the attempt could not be counted")
      }
      cameraManifest = manifest
    }

    var screenSegments: [RecordingMetadata.CaptureSegment]?
    var screenWasMissing = false
    if var manifest = screenManifest {
      if #available(macOS 15.0, *) {
        if let attempt = recordAttempt(&manifest, at: screenManifestURL) {
          attempted.append(screenManifestURL)
          do {
            screenWasMissing = (manifest["publishedSegmentIndex"] as? Int) == nil
            screenSegments = try await stageScreen(
              manifest, attempt: attempt, projectRoot: projectRoot, plan: &plan)
          } catch {
            if Task.isCancelled { return cancelled() }
            let message = RecordingSegmentMerger.describe(error)
            failures.append("screen: \(message)")
            recordFailure(message, in: &manifest, at: screenManifestURL)
          }
        } else {
          failures.append("screen: the attempt could not be counted")
        }
      } else {
        // Separate screen parts only come from the macOS 15 backend.
        failures.append("screen: needs macOS 15")
      }
      screenManifest = manifest
    }

    let repairedSomething = restoredCamera != nil || screenSegments != nil
    guard repairedSomething || plan.dropCamera else {
      try? fileManager.removeItem(at: staging)
      NativeLogger.w(
        "Repair", "Could not join the parts of a paused recording",
        context: ["project": projectRoot.lastPathComponent, "errors": failures.joined(separator: "; ")])
      return .failed(failures.joined(separator: "; "))
    }

    do {
      try stageScreenMetadata(
        projectRoot: projectRoot, screenSegments: screenSegments,
        restoredCamera: restoredCamera, cameraVisible: plan.cameraVisible,
        screenWasMissing: screenWasMissing, dropCamera: plan.dropCamera, plan: &plan)
    } catch {
      try? fileManager.removeItem(at: staging)
      let message = "metadata: \(RecordingSegmentMerger.describe(error))"
      return .failed((failures + [message]).joined(separator: "; "))
    }

    // Ready once whole: a take whose join failed outright finished failed,
    // and one whose camera vanished was marked failed at a later launch.
    plan.markReady = true
    plan.restoreCamera = restoredCamera != nil
    plan.repaired = repairedSomething
    plan.delete(RecordingProjectPaths.waveformURL(for: projectRoot), root: projectRoot)

    // The last point at which stopping changes nothing.
    if Task.isCancelled { return cancelled() }
    guard writeJSON(plan.json, to: Self.commitURL(for: projectRoot)) else {
      try? fileManager.removeItem(at: staging)
      return .failed("Could not write the commit plan")
    }
    guard commit(plan.json, projectRoot: projectRoot) else {
      return .failed("The commit could not finish; it is retried at the next launch")
    }
    NativeLogger.i(
      "Repair", repairedSomething ? "Joined the parts of a paused recording" : "Dropped a lost camera",
      context: [
        "project": projectRoot.lastPathComponent,
        "screen": screenSegments.map { "\($0.count) parts" } ?? "unchanged",
        "camera": restoredCamera != nil ? "restored" : (plan.dropCamera ? "dropped" : "unchanged"),
        "errors": failures.joined(separator: "; "),
      ])
    return repairedSomething ? .repaired : .failed(failures.joined(separator: "; "))
  }

  // MARK: - Screen

  private struct ScreenPart {
    let index: Int
    let fileName: String
    let url: URL
    let cursorURL: URL?
    let micURL: URL?
    let systemURL: URL?
    let duration: TimeInterval
    let startWallClock: String
    let endWallClock: String
    let isPublished: Bool
  }

  @available(macOS 15.0, *)
  private func stageScreen(
    _ manifest: [String: Any], attempt: Int, projectRoot: URL, plan: inout CommitPlan
  ) async throws -> [RecordingMetadata.CaptureSegment] {
    let capture = RecordingProjectPaths.captureDirectoryURL(for: projectRoot)
    let staging = Self.stagingURL(for: projectRoot)
    let publishedIndex = manifest["publishedSegmentIndex"] as? Int
    let records = (manifest["segments"] as? [[String: Any]] ?? [])
      .compactMap { record -> (Int, [String: Any])? in
        guard let index = record["index"] as? Int else { return nil }
        return (index, record)
      }
      .sorted { $0.0 < $1.0 }

    func existing(_ url: URL?) -> URL? {
      guard let url, fileManager.fileExists(atPath: url.path) else { return nil }
      return url
    }

    var parts: [ScreenPart] = []
    var leftOut: [String] = []
    for (index, record) in records {
      guard let fileName = record["screen"] as? String,
        let start = record["startWallClock"] as? String,
        let end = record["endWallClock"] as? String
      else { continue }
      // The published part was moved: its media is screen.mov, cursor.json,
      // mic.m4a and system.m4a now, whatever the manifest names.
      let isPublished = index == publishedIndex
      let url =
        isPublished
        ? RecordingProjectPaths.screenVideoURL(for: projectRoot)
        : capture.appendingPathComponent(fileName)
      // A part before the published one is one the stop found unusable. It
      // stays out: joined in front, it would shift every edit already made
      // on the published part, and every cursor, zoom and caption time.
      if let publishedIndex, index < publishedIndex {
        leftOut.append(fileName)
        continue
      }
      guard fileManager.fileExists(atPath: url.path) else {
        leftOut.append(fileName)
        continue
      }
      let duration = AVURLAsset(url: url).duration.seconds
      guard duration.isFinite, duration > 0 else {
        leftOut.append(fileName)
        continue
      }
      // With nothing published, every part already failed the stop's check
      // for one that plays alone, so the check stands from the first try.
      if attempt > 1 || publishedIndex == nil, !RecordingSegmentMerger.isUsableSegment(url) {
        leftOut.append(fileName)
        continue
      }
      parts.append(
        ScreenPart(
          index: index, fileName: fileName, url: url,
          cursorURL: existing(
            isPublished
              ? RecordingProjectPaths.cursorDataURL(for: projectRoot)
              : (record["cursor"] as? String).map { capture.appendingPathComponent($0) }),
          micURL: existing(
            isPublished
              ? RecordingProjectPaths.micAudioURL(for: projectRoot)
              : (record["mic"] as? String).map { capture.appendingPathComponent($0) }),
          systemURL: existing(
            isPublished
              ? RecordingProjectPaths.systemAudioURL(for: projectRoot)
              : (record["system"] as? String).map { capture.appendingPathComponent($0) }),
          duration: duration, startWallClock: start, endWallClock: end,
          isPublished: isPublished))
    }

    // With a published part, one part is what the editor already has. With
    // none (every preset failed and nothing was published), one part is
    // already better than no recording.
    let enough = publishedIndex == nil ? 1 : 2
    guard parts.count >= enough else {
      throw RepairError("\(parts.count) usable part(s); left out: \(leftOut.joined(separator: ", "))")
    }

    let stagedScreen = staging.appendingPathComponent(RecordingProjectPaths.screenVideoFileName)
    if parts.count == 1 {
      // The mergers MOVE a lone input, which would take it from where it is
      // before the commit makes that safe.
      try fileManager.copyItem(at: parts[0].url, to: stagedScreen)
    } else {
      let outcome = try await RecordingSegmentMerger.mergeSegments(
        parts.map(\.url), to: stagedScreen, fileManager: fileManager, presets: screenPresets)
      if outcome.preset != AVAssetExportPresetPassthrough {
        NativeLogger.w(
          "Repair", "Re-encoded a paused recording to join its parts",
          context: ["preset": outcome.preset ?? "none"])
      }
    }
    // Nothing is deleted on the word of an export that wrote a file that
    // does not play.
    guard RecordingSegmentMerger.isUsableSegment(stagedScreen) else {
      throw RepairError("the joined screen recording does not play")
    }
    plan.move(stagedScreen, to: RecordingProjectPaths.screenVideoURL(for: projectRoot), root: projectRoot)
    for part in parts where !part.isPublished {
      plan.delete(part.url, root: projectRoot)
    }

    // Cursor and audio advance by the same measured durations as the screen,
    // so every timeline lines up with the file the screen merge produced. A
    // track that cannot be joined keeps what it had, and its parts' files
    // stay, listed in the manifest.
    let expectsCursor =
      parts.contains { $0.cursorURL != nil }
      || records.contains { $0.1["cursor"] != nil }
    if expectsCursor {
      let stagedCursor = staging.appendingPathComponent(RecordingProjectPaths.cursorDataFileName)
      do {
        try CursorSegmentMerger.mergeParts(
          parts.map { .init(index: $0.index, url: $0.cursorURL, duration: $0.duration) },
          outputURL: stagedCursor, missingPartsAreEmpty: true, fileManager: fileManager)
        plan.move(stagedCursor, to: RecordingProjectPaths.cursorDataURL(for: projectRoot), root: projectRoot)
        for part in parts where !part.isPublished {
          if let cursor = part.cursorURL { plan.delete(cursor, root: projectRoot) }
        }
      } catch {
        NativeLogger.w(
          "Repair", "Could not join the cursor; keeping the one there was",
          context: ["error": RecordingSegmentMerger.describe(error)])
        leftOut += parts.filter { !$0.isPublished }.compactMap { $0.cursorURL?.lastPathComponent }
      }
    }

    for kind in AudioSourceKind.allCases {
      let urls = parts.map { kind == .microphone ? $0.micURL : $0.systemURL }
      guard urls.contains(where: { $0 != nil }) else { continue }
      let staged = staging.appendingPathComponent(kind.finalFileName)
      let destination = capture.appendingPathComponent(kind.finalFileName)
      do {
        if parts.count == 1, let only = urls[0] {
          try fileManager.copyItem(at: only, to: staged)
        } else {
          try await AudioSegmentMerger.mergeSegments(
            zip(urls, parts).map { .init(url: $0, slotDuration: $1.duration) },
            to: staged, fileManager: fileManager)
        }
        plan.move(staged, to: destination, root: projectRoot)
        for (url, part) in zip(urls, parts) where !part.isPublished {
          if let url { plan.delete(url, root: projectRoot) }
        }
      } catch {
        NativeLogger.w(
          "Repair", "Could not join a source audio track; keeping the one there was",
          context: ["kind": kind.rawValue, "error": RecordingSegmentMerger.describe(error)])
        leftOut += zip(urls, parts).compactMap { $1.isPublished ? nil : $0?.lastPathComponent }
      }
    }

    if !leftOut.isEmpty {
      NativeLogger.w(
        "Repair", "Left out files that could not be joined",
        context: ["files": leftOut.joined(separator: ", ")])
    }
    settleManifest(
      manifest, at: Self.screenManifestURL(for: projectRoot), leftOut: leftOut,
      projectRoot: projectRoot, stagedName: "screen.unmerged.json", plan: &plan)

    return parts.map {
      RecordingMetadata.CaptureSegment(
        index: $0.index, relativePath: $0.fileName, startWallClock: $0.startWallClock,
        endWallClock: $0.endWallClock, durationSeconds: $0.duration)
    }
  }

  // MARK: - Camera

  private func stageCamera(
    _ manifest: [String: Any], attempt: Int, projectRoot: URL, plan: inout CommitPlan
  ) async throws -> CameraRecordingMetadata {
    let cameraDirectory = RecordingProjectPaths.cameraDirectoryURL(for: projectRoot)
    let staging = Self.stagingURL(for: projectRoot)
    let records = (manifest["segments"] as? [[String: Any]] ?? [])
      .sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }

    var files: [URL] = []
    var leftOut: [String] = []
    var stretches: [(fileName: String, start: String, end: String, duration: Double)] = []
    for record in records {
      guard let relative = record["camera"] as? String else { continue }
      let url = cameraDirectory.appendingPathComponent(relative)
      guard fileManager.fileExists(atPath: url.path) else { continue }
      let duration = AVURLAsset(url: url).duration.seconds
      let kept = (record["stretches"] as? [[String: Any]] ?? []).compactMap {
        stretch -> (String, String, String, Double)? in
        guard let start = stretch["startWallClock"] as? String,
          let end = stretch["endWallClock"] as? String,
          let seconds = stretch["durationSeconds"] as? Double, seconds > 0
        else { return nil }
        return (url.lastPathComponent, start, end, seconds)
      }
      // A file with no timed stretch cannot be placed on the timeline, and
      // joining it anyway would shift every file after it.
      guard duration.isFinite, duration > 0, !kept.isEmpty,
        attempt == 1 || RecordingSegmentMerger.isUsableSegment(url)
      else {
        leftOut.append(relative)
        continue
      }
      files.append(url)
      stretches.append(contentsOf: kept)
    }
    guard !files.isEmpty else { throw RepairError("no usable camera part") }

    let stagedRaw = staging.appendingPathComponent(RecordingProjectPaths.cameraRawFileName)
    if files.count == 1 {
      try fileManager.copyItem(at: files[0], to: stagedRaw)
    } else {
      _ = try await RecordingSegmentMerger.mergeSegments(
        files, to: stagedRaw, fileManager: fileManager, presets: cameraPresets)
    }
    guard RecordingSegmentMerger.isUsableSegment(stagedRaw) else {
      throw RepairError("the joined camera recording does not play")
    }

    // The stub written at start has what the manifest lacks: the recording
    // id and the size.
    let stub = (try? Data(contentsOf: RecordingProjectPaths.cameraMetadataURL(for: projectRoot)))
      .flatMap { try? JSONDecoder().decode(CameraRecordingMetadata.self, from: $0) }
    let first = records.first ?? [:]
    let dimensions =
      stub?.dimensions
      ?? AVURLAsset(url: stagedRaw).tracks(withMediaType: .video).first.map { track in
        let size = track.naturalSize.applying(track.preferredTransform)
        return CameraRecordingMetadata.Dimensions(
          width: Int(abs(size.width).rounded()), height: Int(abs(size.height).rounded()))
      }
    let segments = stretches.enumerated().map { offset, stretch in
      RecordingMetadata.CaptureSegment(
        index: offset, relativePath: stretch.fileName, startWallClock: stretch.start,
        endWallClock: stretch.end, durationSeconds: stretch.duration)
    }
    let metadata = CameraRecordingMetadata(
      version: 1,
      recordingId: stub?.recordingId ?? UUID().uuidString,
      rawRelativePath: RecordingProjectPaths.relativeCameraRawPath,
      metadataRelativePath: RecordingProjectPaths.relativeCameraMetadataPath,
      deviceId: stub?.deviceId ?? first["deviceId"] as? String,
      mirroredRaw: stub?.mirroredRaw ?? first["mirroredRaw"] as? Bool ?? false,
      nominalFrameRate: stub?.nominalFrameRate ?? first["nominalFrameRate"] as? Double,
      dimensions: dimensions,
      startedAt: stretches.first?.start ?? stub?.startedAt ?? "",
      endedAt: stretches.last?.end,
      segments: segments)
    let stagedMeta = staging.appendingPathComponent(RecordingProjectPaths.cameraMetadataFileName)
    try metadata.write(to: stagedMeta)

    plan.move(stagedRaw, to: RecordingProjectPaths.cameraRawURL(for: projectRoot), root: projectRoot)
    plan.lateMove(stagedMeta, to: RecordingProjectPaths.cameraMetadataURL(for: projectRoot), root: projectRoot)
    // Only what was joined goes; a part left out stays, listed.
    for file in files { plan.delete(file, root: projectRoot) }
    plan.removeIfEmpty(RecordingProjectPaths.cameraSegmentsDirectoryURL(for: projectRoot), root: projectRoot)
    settleManifest(
      manifest, at: Self.cameraManifestURL(for: projectRoot), leftOut: leftOut,
      projectRoot: projectRoot, stagedName: "camera.unmerged.json", plan: &plan)
    return metadata
  }

  // MARK: - Metadata

  private func stageScreenMetadata(
    projectRoot: URL, screenSegments: [RecordingMetadata.CaptureSegment]?,
    restoredCamera: CameraRecordingMetadata?, cameraVisible: Bool?, screenWasMissing: Bool,
    dropCamera: Bool, plan: inout CommitPlan
  ) throws {
    let metaURL = RecordingProjectPaths.screenMetadataURL(for: projectRoot)
    var metadata = try RecordingMetadata.read(from: metaURL)
    if let screenSegments {
      metadata.screen.segments = screenSegments
      if let end = screenSegments.last.flatMap({
        RecordingMetadata.date(fromISO8601: $0.endWallClock)
      }) {
        metadata = metadata.withEndTimestamp(end)
      }
    }
    if let restoredCamera {
      let hadCameraBlock = metadata.camera != nil
      metadata.camera = MetadataSidecarWriter.cameraCaptureInfo(
        from: CameraRecordingResult(
          rawURL: RecordingProjectPaths.cameraRawURL(for: projectRoot),
          metadataURL: RecordingProjectPaths.cameraMetadataURL(for: projectRoot),
          metadata: restoredCamera),
        screenRawURL: RecordingProjectPaths.screenVideoURL(for: projectRoot))
      // A stop that dropped the camera also turned it off, after noting what
      // it was. A take from before that note is shown with its camera. A
      // take whose screen join failed outright never had it turned off.
      if let cameraVisible {
        metadata.editorSeed.cameraVisible = cameraVisible
      } else if !hadCameraBlock {
        metadata.editorSeed.cameraVisible = true
      }
    } else if screenWasMissing, screenSegments != nil,
      fileManager.fileExists(atPath: RecordingProjectPaths.cameraRawURL(for: projectRoot).path),
      let data = try? Data(contentsOf: RecordingProjectPaths.cameraMetadataURL(for: projectRoot)),
      let camera = try? JSONDecoder().decode(CameraRecordingMetadata.self, from: data),
      camera.endedAt != nil
    {
      // A stop whose screen join failed outright never finished the metadata,
      // so its camera block is the empty one from the start, even though the
      // camera's own file was saved.
      metadata.camera = MetadataSidecarWriter.cameraCaptureInfo(
        from: CameraRecordingResult(
          rawURL: RecordingProjectPaths.cameraRawURL(for: projectRoot),
          metadataURL: RecordingProjectPaths.cameraMetadataURL(for: projectRoot),
          metadata: camera),
        screenRawURL: RecordingProjectPaths.screenVideoURL(for: projectRoot))
    } else if dropCamera {
      metadata.camera = nil
    }
    let staged = Self.stagingURL(for: projectRoot)
      .appendingPathComponent(RecordingProjectPaths.screenMetadataFileName)
    try metadata.write(to: staged)
    plan.lateMove(staged, to: metaURL, root: projectRoot)
  }

  // MARK: - Commit

  /// What a repair will change, written before any of it happens.
  struct CommitPlan {
    /// Media first, so a crash between moves never leaves metadata naming a
    /// file that is not there yet.
    var moves: [(from: String, to: String)] = []
    /// Metadata, moved after every media file.
    var lateMoves: [(from: String, to: String)] = []
    var deletes: [String] = []
    /// Folders removed once the deletes leave them empty.
    var emptyFolders: [String] = []
    var restoreCamera = false
    var dropCamera = false
    var markReady = false
    /// Whether anything was joined, as opposed to a lost camera dropped.
    var repaired = false
    var cameraVisible: Bool?

    mutating func move(_ from: URL, to: URL, root: URL) {
      guard let f = RecordingProjectPaths.relativePath(from: root, to: from),
        let t = RecordingProjectPaths.relativePath(from: root, to: to)
      else { return }
      moves.append((f, t))
    }

    mutating func lateMove(_ from: URL, to: URL, root: URL) {
      guard let f = RecordingProjectPaths.relativePath(from: root, to: from),
        let t = RecordingProjectPaths.relativePath(from: root, to: to)
      else { return }
      lateMoves.append((f, t))
    }

    mutating func delete(_ url: URL, root: URL) {
      guard let relative = RecordingProjectPaths.relativePath(from: root, to: url) else { return }
      deletes.append(relative)
    }

    mutating func removeIfEmpty(_ url: URL, root: URL) {
      guard let relative = RecordingProjectPaths.relativePath(from: root, to: url) else { return }
      emptyFolders.append(relative)
    }

    var json: [String: Any] {
      [
        "version": 1,
        "moves": (moves + lateMoves).map { ["from": $0.from, "to": $0.to] },
        "deletes": deletes,
        "emptyFolders": emptyFolders,
        "camera": restoreCamera ? "restore" : (dropCamera ? "drop" : "keep"),
        "markReady": markReady,
        "outcome": repaired ? "repaired" : "cameraDropped",
      ]
    }
  }

  /// Applies a written plan, and says whether it all landed. Every step can
  /// run again after a crash: a move whose source is gone already happened,
  /// and a delete of nothing is fine.
  ///
  /// A move that fails stops the commit before anything is deleted, and
  /// leaves the plan for the next launch: the parts are the only copy of
  /// what the joined file holds until that file is in place.
  @discardableResult
  func commit(_ plan: [String: Any], projectRoot: URL) -> Bool {
    for move in plan["moves"] as? [[String: String]] ?? [] {
      guard let from = move["from"], let to = move["to"] else { continue }
      let source = projectRoot.appendingPathComponent(from)
      let destination = projectRoot.appendingPathComponent(to)
      guard fileManager.fileExists(atPath: source.path) else { continue }
      do {
        if fileManager.fileExists(atPath: destination.path) {
          _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
          try fileManager.moveItem(at: source, to: destination)
        }
      } catch {
        NativeLogger.e(
          "Repair", "Could not move a repaired file into place; the commit waits for the next launch",
          context: ["file": to, "error": error.localizedDescription])
        return false
      }
    }
    for relative in plan["deletes"] as? [String] ?? [] {
      let url = projectRoot.appendingPathComponent(relative)
      if fileManager.fileExists(atPath: url.path) { try? fileManager.removeItem(at: url) }
    }
    for relative in plan["emptyFolders"] as? [String] ?? [] {
      let url = projectRoot.appendingPathComponent(relative)
      if (try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
        try? fileManager.removeItem(at: url)
      }
    }

    let manifestURL = RecordingProjectPaths.manifestURL(for: projectRoot)
    guard var manifest = try? RecordingProjectManifest.read(from: manifestURL) else {
      NativeLogger.e("Repair", "Could not read project.json to finish a repair")
      return false
    }
    switch plan["camera"] as? String {
    case "restore":
      manifest.camera = RecordingProjectManifest.CameraFiles(
        rawVideo: RecordingProjectPaths.relativeCameraRawPath,
        metadata: RecordingProjectPaths.relativeCameraMetadataPath,
        segmentsDirectory: RecordingProjectPaths.relativeCameraSegmentsDirectoryPath)
    case "drop":
      manifest.camera = nil
    default:
      break
    }
    manifest.reconcileInventory(projectRoot: projectRoot, fileManager: fileManager)
    if plan["markReady"] as? Bool == true,
      manifest.status == .failed || manifest.status == .ready,
      ProjectOpenValidator.missingRequiredProjectFiles(
        for: manifest, projectRootURL: projectRoot, fileManager: fileManager
      ).isEmpty
    {
      manifest.updateStatus(.ready)
    }
    do {
      try manifest.write(to: manifestURL)
    } catch {
      NativeLogger.e(
        "Repair", "Could not update project.json after a repair",
        context: ["error": error.localizedDescription])
      return false
    }
    try? fileManager.removeItem(at: Self.stagingURL(for: projectRoot))
    return true
  }

  // MARK: - JSON

  private func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private func writeJSON(_ object: [String: Any], to url: URL) -> Bool {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return false }
    do {
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      NativeLogger.w(
        "Repair", "Could not write repair state",
        context: ["path": url.lastPathComponent, "error": error.localizedDescription])
      return false
    }
  }
}

private struct RepairError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

/// Runs [SalvagedTakeRepairer] at launch over every project that needs it,
/// one at a time and off the main thread.
///
/// At launch nothing has a project open yet. A Finder open that arrives
/// while its project is being repaired waits for it
/// ([whenProjectIsFree]), so the editor never opens a file about to be
/// replaced. Flutter learns what was repaired from the startup recovery
/// report ([whenFinished]), which answers once the sweep is done.
///
/// Main thread only, like the facade that starts it; the background task
/// hands its result back on the main queue.
final class SalvagedTakeRepairSweep: @unchecked Sendable {
  static let shared = SalvagedTakeRepairSweep()

  /// How long one project may take before the repair is stopped, so a
  /// stuck export cannot hold its Finder open and the startup report for
  /// the whole session. Generous: re-encoding an hour-long take takes a
  /// while.
  static let projectTimeout: TimeInterval = 30 * 60
  /// After a stop, how long to wait for the repair to wind down before
  /// moving on without it (an export that ignores the stop).
  static let cancelGrace: TimeInterval = 10

  private(set) var isFinished = true
  private var pending: Set<String> = []
  private var current: Task<SalvagedTakeRepairer.Outcome, Never>?
  /// Bumped for each project, so a late result from one given up on is
  /// ignored.
  private var generation = 0
  private var timeout: TimeInterval = SalvagedTakeRepairSweep.projectTimeout
  private var grace: TimeInterval = SalvagedTakeRepairSweep.cancelGrace
  private var repaired: [String] = []
  private var finishWaiters: [([String]) -> Void] = []
  private var projectWaiters: [String: [() -> Void]] = [:]

  /// [canStart] is asked before each project: one is left for the next
  /// launch rather than started while a recording runs, which it would
  /// compete with for the encoder. A join already under way finishes.
  ///
  /// A second call while a sweep runs does nothing: two chains would repair
  /// one project at the same time.
  func start(
    rootURL: URL,
    repairer: SalvagedTakeRepairer = SalvagedTakeRepairer(),
    canStart: @escaping () -> Bool
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard isFinished else { return }
    let roots =
      ((try? FileManager.default.contentsOfDirectory(
        at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
      .filter(RecordingProjectPaths.isProjectDirectory)
      .filter { repairer.needsRepair(projectRoot: $0) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !roots.isEmpty else { return }

    isFinished = false
    pending = Set(roots.map(Self.key))
    NativeLogger.i("Repair", "Paused recordings to repair at launch", context: ["count": roots.count])
    run(roots[...], repairer: repairer, canStart: canStart)
  }

  private func run(
    _ roots: ArraySlice<URL>, repairer: SalvagedTakeRepairer, canStart: @escaping () -> Bool
  ) {
    guard let root = roots.first else {
      isFinished = true
      let waiters = finishWaiters
      finishWaiters = []
      waiters.forEach { $0(repaired) }
      return
    }
    let next = roots.dropFirst()
    guard canStart() else {
      NativeLogger.i(
        "Repair", "A recording is running; repair waits for the next launch",
        context: ["project": root.lastPathComponent])
      done(root)
      run(next, repairer: repairer, canStart: canStart)
      return
    }
    generation += 1
    let token = generation
    let work = repairOverride
    let task = Task.detached(priority: .utility) {
      if let work { return await work(root) }
      return await repairer.repair(projectRoot: root)
    }
    current = task
    let advance: (SalvagedTakeRepairer.Outcome?) -> Void = { [weak self] outcome in
      guard let self, self.generation == token else { return }
      self.generation += 1
      self.current = nil
      if outcome == .repaired { self.repaired.append(root.path) }
      self.done(root)
      // After a stop for a recording, the rest wait for the next launch too.
      self.run(next, repairer: repairer, canStart: outcome == .cancelled ? { false } : canStart)
    }
    Task.detached {
      let outcome = await task.value
      DispatchQueue.main.async { advance(outcome) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
      guard let self, self.generation == token else { return }
      NativeLogger.w(
        "Repair", "Repair took too long; stopping it",
        context: ["project": root.lastPathComponent, "seconds": Int(self.timeout)])
      self.stopCurrent(token: token, advance: advance)
    }
    pendingAdvance = advance
  }

  private var pendingAdvance: ((SalvagedTakeRepairer.Outcome?) -> Void)?
  /// Tests only: stands in for the repair, to make one that hangs or waits.
  private var repairOverride: (@Sendable (URL) async -> SalvagedTakeRepairer.Outcome)?

  /// Stops the repair under way: a recording is starting. It is tried again
  /// at the next launch, and so are the projects after it.
  func cancelCurrent() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard current != nil else { return }
    NativeLogger.i("Repair", "A recording is starting; stopping the launch repair")
    stopCurrent(token: generation, advance: pendingAdvance)
  }

  private func stopCurrent(
    token: Int, advance: ((SalvagedTakeRepairer.Outcome?) -> Void)?
  ) {
    current?.cancel()
    // Normally the repair returns `.cancelled` at once and advances the
    // sweep itself. One that ignores the stop is left behind after a grace
    // period, so what waits on it is released.
    DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
      guard let self, self.generation == token else { return }
      NativeLogger.w("Repair", "A stopped repair did not wind down; moving on without it")
      advance?(.cancelled)
    }
  }

  private func done(_ root: URL) {
    let key = Self.key(root)
    pending.remove(key)
    let waiters = projectWaiters.removeValue(forKey: key) ?? []
    waiters.forEach { $0() }
  }

  /// Calls [completion] with the repaired projects' paths once the sweep is
  /// over; at once when there is none.
  func whenFinished(_ completion: @escaping ([String]) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    if isFinished { completion(repaired) } else { finishWaiters.append(completion) }
  }

  /// Calls [completion] once the project at [path] is not being repaired.
  func whenProjectIsFree(_ path: String, _ completion: @escaping () -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    let key = Self.key(URL(fileURLWithPath: path))
    if pending.contains(key) {
      projectWaiters[key, default: []].append(completion)
    } else {
      completion()
    }
  }

  private static func key(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  #if DEBUG
    func _testSetTimeouts(project: TimeInterval, grace: TimeInterval) {
      timeout = project
      self.grace = grace
    }

    func _testSetRepair(_ work: (@Sendable (URL) async -> SalvagedTakeRepairer.Outcome)?) {
      repairOverride = work
    }

    func _testReset() {
      repairOverride = nil
      current?.cancel()
      current = nil
      pendingAdvance = nil
      generation += 1
      timeout = Self.projectTimeout
      grace = Self.cancelGrace
      isFinished = true
      pending = []
      repaired = []
      finishWaiters = []
      projectWaiters = [:]
    }
  #endif
}
