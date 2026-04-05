import Foundation

/// Manages the internal recordings workspace: discovery, cleanup, and deletion.
final class RecordingStore {
  struct RecordingInfo {
    let projectRootURL: URL
    let manifestURL: URL
    let manifest: RecordingProjectManifest?
    let screenVideoURL: URL?
    let metadataURL: URL?
    let createdAt: Date?
  }

  struct ScanResult {
    let totalCount: Int
    let completeCount: Int
    let orphanedCount: Int
    let oldestDate: Date?
    let totalSizeBytes: UInt64
    let recordings: [RecordingInfo]
  }

  private let fm: FileManager
  private let rootURL: URL
  private let shouldLogInvalidProjects: Bool

  init(rootURL: URL = RecordingProjectPaths.projectsRoot(), fileManager: FileManager = .default) {
    self.rootURL = rootURL
    self.fm = fileManager
    self.shouldLogInvalidProjects = CaptureDestinationPreflightPolicy.isNonProductionBuild(
      bundleIdentifier: Bundle.main.bundleIdentifier
    )
  }

  func listRecordings() -> [RecordingInfo] {
    guard
      let contents = try? fm.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    return contents
      .filter(RecordingProjectPaths.isProjectDirectory)
      .compactMap { projectRootURL in
        let manifestURL = RecordingProjectPaths.manifestURL(for: projectRootURL)
        let manifest: RecordingProjectManifest
        do {
          manifest = try RecordingProjectManifest.read(from: manifestURL)
        } catch {
          if shouldLogInvalidProjects {
            NativeLogger.w(
              "RecordingStore",
              "Skipping invalid recording project",
              context: ["path": projectRootURL.path, "error": error.localizedDescription]
            )
          }
          return nil
        }

        let screenVideoURL = RecordingProjectPaths.resolvedURL(
          for: manifest.capture.screenVideo,
          projectRoot: projectRootURL
        )
        let metadataURL = RecordingProjectPaths.resolvedURL(
          for: manifest.capture.screenMetadata,
          projectRoot: projectRootURL
        )
        let createdAt = manifest.createdAt

        return RecordingInfo(
          projectRootURL: projectRootURL,
          manifestURL: manifestURL,
          manifest: manifest,
          screenVideoURL: screenVideoURL,
          metadataURL: metadataURL,
          createdAt: createdAt
        )
      }
      .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
  }

  func scanWorkspace() -> ScanResult {
    let recordings = listRecordings()

    var totalSize: UInt64 = 0
    var completeCount = 0
    var orphanedCount = 0
    var oldestDate: Date?

    for recording in recordings {
      totalSize += UInt64(StorageInfoProvider.directorySize(recording.projectRootURL))

      let isComplete =
        recording.manifest != nil
        && recording.screenVideoURL.map { fm.fileExists(atPath: $0.path) } == true
        && recording.metadataURL.map { fm.fileExists(atPath: $0.path) } == true

      if isComplete {
        completeCount += 1
      } else {
        orphanedCount += 1
      }

      if let created = recording.createdAt, oldestDate == nil || created < oldestDate! {
        oldestDate = created
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

  @discardableResult
  func deleteProject(projectRootURL: URL) -> Bool {
    guard RecordingProjectPaths.isProjectDirectory(projectRootURL) else {
      return false
    }

    if !fm.fileExists(atPath: projectRootURL.path) {
      return false
    }

    do {
      try fm.removeItem(at: projectRootURL)
      NativeLogger.d(
        "RecordingStore",
        "Deleted recording project",
        context: ["path": projectRootURL.lastPathComponent]
      )
      return true
    } catch {
      NativeLogger.e(
        "RecordingStore",
        "Failed to delete recording project",
        context: ["path": projectRootURL.path, "error": error.localizedDescription]
      )
      return false
    }
  }

  @discardableResult
  func deleteOlderThan(days: Int) -> Int {
    let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    var deletedCount = 0

    for recording in listRecordings() {
      guard let created = recording.createdAt, created < cutoff else { continue }
      if deleteProject(projectRootURL: recording.projectRootURL) {
        deletedCount += 1
      }
    }

    if deletedCount > 0 {
      NativeLogger.i(
        "RecordingStore",
        "Cleanup completed",
        context: ["deletedCount": deletedCount, "olderThanDays": days]
      )
    }

    return deletedCount
  }

  @discardableResult
  func deleteAll() -> Int {
    var deletedCount = 0
    for recording in listRecordings() {
      if deleteProject(projectRootURL: recording.projectRootURL) {
        deletedCount += 1
      }
    }
    return deletedCount
  }

  func cleanupAfterExport(projectRootURL: URL, keepOriginals: Bool) {
    guard !keepOriginals else {
      NativeLogger.d(
        "RecordingStore",
        "Keeping recording project after export",
        context: ["path": projectRootURL.lastPathComponent]
      )
      return
    }

    guard AppPaths.isInternalRecording(projectRootURL) else {
      NativeLogger.w(
        "RecordingStore",
        "Skipping cleanup: project not in internal workspace",
        context: ["path": projectRootURL.path]
      )
      return
    }

    _ = deleteProject(projectRootURL: projectRootURL)
    NativeLogger.i(
      "RecordingStore",
      "Cleaned up recording project after export",
      context: ["path": projectRootURL.lastPathComponent]
    )
  }

  func markInterruptedProjectsAsFailed() {
    for recording in listRecordings() {
      guard var manifest = recording.manifest else { continue }
      guard manifest.status == .capturing || manifest.status == .finalizing else { continue }
      manifest.updateStatus(.failed)
      do {
        try manifest.write(to: recording.manifestURL)
      } catch {
        NativeLogger.w(
          "RecordingStore",
          "Failed to mark interrupted project as failed",
          context: ["path": recording.manifestURL.path, "error": error.localizedDescription]
        )
      }
    }
  }

  func logWorkspaceStats() {
    let scan = scanWorkspace()

    let sizeFormatted: String = {
      let formatter = ByteCountFormatter()
      formatter.countStyle = .file
      return formatter.string(fromByteCount: Int64(scan.totalSizeBytes))
    }()

    let oldestFormatted: String = {
      guard let oldest = scan.oldestDate else { return "none" }
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      return formatter.string(from: oldest)
    }()

    NativeLogger.i(
      "RecordingStore",
      "Workspace scan complete",
      context: [
        "root": rootURL.path,
        "totalProjects": scan.totalCount,
        "completeProjects": scan.completeCount,
        "orphanedProjects": scan.orphanedCount,
        "oldest": oldestFormatted,
        "totalSize": sizeFormatted,
      ]
    )
  }
}
