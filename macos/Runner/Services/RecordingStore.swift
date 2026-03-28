import Foundation

/// Manages the internal recordings workspace: discovery, cleanup, and deletion.
///
/// This class provides:
/// - Enumeration of raw recordings in the internal workspace
/// - Deletion of raw recordings and their sidecars
/// - Age-based cleanup policies
/// - Startup scanning for diagnostics
final class RecordingStore {

  /// Information about a recording in the internal workspace.
  struct RecordingInfo {
    let rawURL: URL
    let cursorURL: URL
    let metaURL: URL
    let hasCursor: Bool
    let hasMeta: Bool
    let createdAt: Date?
    let metadata: RecordingMetadata?
  }

  /// Result of a startup scan.
  struct ScanResult {
    let totalCount: Int
    let completeCount: Int  // has both cursor and meta
    let orphanedCount: Int  // missing cursor or meta
    let oldestDate: Date?
    let totalSizeBytes: UInt64
    let recordings: [RecordingInfo]
  }

  private let fm: FileManager
  private let rootURL: URL

  init(rootURL: URL = AppPaths.recordingsRoot(), fileManager: FileManager = .default) {
    self.rootURL = rootURL
    self.fm = fileManager
  }

  // MARK: - Discovery

  /// Lists all raw recordings (.mov files) in the internal workspace.
  func listRecordings() -> [RecordingInfo] {
    guard
      let contents = try? fm.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]
      )
    else {
      return []
    }

    return contents
      .filter { rawURL in
        guard rawURL.pathExtension.lowercased() == "mov" else { return false }
        let name = rawURL.lastPathComponent.lowercased()
        return !name.contains(".camera.") && !name.contains(".segment-") && !name.contains("segment_")
      }
      .map { rawURL in
        let cursorURL = AppPaths.cursorSidecarURL(for: rawURL)
        let metaURL = AppPaths.metadataSidecarURL(for: rawURL)
        let hasCursor = fm.fileExists(atPath: cursorURL.path)
        let hasMeta = fm.fileExists(atPath: metaURL.path)

        let createdAt: Date? = {
          let values = try? rawURL.resourceValues(forKeys: [.creationDateKey])
          return values?.creationDate
        }()

        let metadata: RecordingMetadata? = {
          guard hasMeta else { return nil }
          return try? RecordingMetadata.read(from: metaURL)
        }()

        return RecordingInfo(
          rawURL: rawURL,
          cursorURL: cursorURL,
          metaURL: metaURL,
          hasCursor: hasCursor,
          hasMeta: hasMeta,
          createdAt: createdAt,
          metadata: metadata
        )
      }
      .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
  }

  /// Scans the internal workspace and returns statistics.
  func scanWorkspace() -> ScanResult {
    let recordings = listRecordings()

    var totalSize: UInt64 = 0
    var completeCount = 0
    var orphanedCount = 0
    var oldestDate: Date?

    for recording in recordings {
      // Calculate size
      if let size = try? fm.attributesOfItem(atPath: recording.rawURL.path)[.size] as? UInt64 {
        totalSize += size
      }
      if recording.hasCursor, let size = try? fm.attributesOfItem(atPath: recording.cursorURL.path)[.size] as? UInt64 {
        totalSize += size
      }
      if recording.hasMeta, let size = try? fm.attributesOfItem(atPath: recording.metaURL.path)[.size] as? UInt64 {
        totalSize += size
      }

      // Check completeness
      if recording.hasCursor && recording.hasMeta {
        completeCount += 1
      } else {
        orphanedCount += 1
      }

      // Track oldest
      if let created = recording.createdAt {
        if oldestDate == nil || created < oldestDate! {
          oldestDate = created
        }
      }
    }

    return ScanResult(
      totalCount: recordings.count,
      completeCount: completeCount,
      orphanedCount: orphanedCount,
      oldestDate: oldestDate,
      totalSizeBytes: totalSize,
      recordings: recordings
    )
  }

  // MARK: - Deletion

  /// Deletes a raw recording and all its sidecars.
  ///
  /// - Parameter rawURL: The URL of the raw .mov file
  /// - Returns: true if at least the raw file was deleted
  @discardableResult
  func deleteRawAndSidecars(rawURL: URL) -> Bool {
    var deletedRaw = false

    // Delete raw .mov
    if fm.fileExists(atPath: rawURL.path) {
      do {
        try fm.removeItem(at: rawURL)
        deletedRaw = true
        NativeLogger.d("RecordingStore", "Deleted raw recording", context: ["path": rawURL.lastPathComponent])
      } catch {
        NativeLogger.e("RecordingStore", "Failed to delete raw recording", context: ["error": error.localizedDescription])
      }
    }

    // Delete related artifacts (best-effort).
    for artifactURL in AppPaths.allRecordingArtifactURLs(for: rawURL) where artifactURL != rawURL {
      if !fm.fileExists(atPath: artifactURL.path) {
        continue
      }
      do {
        try fm.removeItem(at: artifactURL)
        NativeLogger.d(
          "RecordingStore",
          "Deleted related recording artifact",
          context: ["path": artifactURL.lastPathComponent]
        )
      } catch {
        NativeLogger.w(
          "RecordingStore",
          "Failed to delete related artifact",
          context: ["error": error.localizedDescription, "path": artifactURL.lastPathComponent]
        )
      }
    }

    return deletedRaw
  }

  /// Deletes all recordings older than the specified number of days.
  ///
  /// - Parameter days: Number of days after which recordings are considered old
  /// - Returns: Number of recordings deleted
  @discardableResult
  func deleteOlderThan(days: Int) -> Int {
    let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    var deletedCount = 0

    for recording in listRecordings() {
      guard let created = recording.createdAt, created < cutoff else { continue }
      if deleteRawAndSidecars(rawURL: recording.rawURL) {
        deletedCount += 1
      }
    }

    if deletedCount > 0 {
      NativeLogger.i("RecordingStore", "Cleanup completed", context: [
        "deletedCount": deletedCount,
        "olderThanDays": days
      ])
    }

    return deletedCount
  }

  /// Deletes all recordings in the internal workspace.
  ///
  /// - Returns: Number of recordings deleted
  @discardableResult
  func deleteAll() -> Int {
    var deletedCount = 0
    for recording in listRecordings() {
      if deleteRawAndSidecars(rawURL: recording.rawURL) {
        deletedCount += 1
      }
    }
    return deletedCount
  }

  // MARK: - Cleanup After Export

  /// Cleans up the raw recording and sidecars after a successful export.
  ///
  /// This method only deletes files if:
  /// - `keepOriginals` is false
  /// - The raw URL is in the internal workspace (safety check)
  ///
  /// - Parameters:
  ///   - rawURL: The URL of the raw recording that was exported
  ///   - keepOriginals: If true, files are preserved; if false, they are deleted
  func cleanupAfterExport(rawURL: URL, keepOriginals: Bool) {
    guard !keepOriginals else {
      NativeLogger.d("RecordingStore", "Keeping original files after export", context: ["path": rawURL.lastPathComponent])
      return
    }

    // Safety check: only delete files in the internal workspace
    guard AppPaths.isInternalRecording(rawURL) else {
      NativeLogger.w("RecordingStore", "Skipping cleanup: file not in internal workspace", context: ["path": rawURL.path])
      return
    }

    deleteRawAndSidecars(rawURL: rawURL)
    NativeLogger.i("RecordingStore", "Cleaned up after export", context: ["path": rawURL.lastPathComponent])
  }

  // MARK: - Diagnostics

  /// Logs workspace statistics for diagnostics.
  func logWorkspaceStats() {
    let scan = scanWorkspace()

    let sizeFormatted: String = {
      let formatter = ByteCountFormatter()
      formatter.countStyle = .file
      return formatter.string(fromByteCount: Int64(scan.totalSizeBytes))
    }()

    let oldestFormatted: String = {
      guard let oldest = scan.oldestDate else { return "none" }
      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .full
      return formatter.localizedString(for: oldest, relativeTo: Date())
    }()

    NativeLogger.i("RecordingStore", "Workspace scan complete", context: [
      "totalRecordings": scan.totalCount,
      "completeRecordings": scan.completeCount,
      "orphanedRecordings": scan.orphanedCount,
      "totalSize": sizeFormatted,
      "oldestRecording": oldestFormatted,
      "workspacePath": rootURL.path
    ])

    // Log orphaned recordings for debugging
    for recording in scan.recordings where !recording.hasCursor || !recording.hasMeta {
      NativeLogger.w("RecordingStore", "Orphaned recording found", context: [
        "file": recording.rawURL.lastPathComponent,
        "hasCursor": recording.hasCursor,
        "hasMeta": recording.hasMeta
      ])
    }
  }
}
