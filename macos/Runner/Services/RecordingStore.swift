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
    return projectDirectories()
      .compactMap { projectRootURL -> RecordingInfo? in
        guard let manifestEntry = loadManifestEntry(for: projectRootURL) else {
          return nil
        }

        if !ProjectOpenValidator.isOpenableStatus(manifestEntry.manifest.status) {
          if shouldLogInvalidProjects {
            NativeLogger.w(
              "RecordingStore",
              "Skipping recording project with non-openable status",
              context: [
                "path": projectRootURL.path,
                "status": manifestEntry.manifest.status.rawValue,
              ]
            )
          }
          return nil
        }

        let missingFiles = ProjectOpenValidator.missingRequiredProjectFiles(
          for: manifestEntry.manifest,
          projectRootURL: projectRootURL,
          fileManager: fm
        )
        if !missingFiles.isEmpty {
          if shouldLogInvalidProjects {
            NativeLogger.w(
              "RecordingStore",
              "Skipping recording project with missing durable files",
              context: [
                "path": projectRootURL.path,
                "status": manifestEntry.manifest.status.rawValue,
                "missingFiles": missingFiles.map(\.lastPathComponent).joined(separator: ","),
              ]
            )
          }
          return nil
        }

        let screenVideoURL = RecordingProjectPaths.resolvedURL(
          for: manifestEntry.manifest.capture.screenVideo,
          projectRoot: projectRootURL
        )
        let metadataURL = RecordingProjectPaths.resolvedURL(
          for: manifestEntry.manifest.capture.screenMetadata,
          projectRoot: projectRootURL
        )

        return RecordingInfo(
          projectRootURL: projectRootURL,
          manifestURL: manifestEntry.manifestURL,
          manifest: manifestEntry.manifest,
          screenVideoURL: screenVideoURL,
          metadataURL: metadataURL,
          createdAt: manifestEntry.manifest.createdAt
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
    for projectRootURL in projectDirectories() {
      if deleteProject(projectRootURL: projectRootURL) {
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
    for projectRootURL in projectDirectories() {
      guard let manifestEntry = loadManifestEntry(for: projectRootURL) else { continue }
      var manifest = manifestEntry.manifest
      guard manifest.status == .capturing || manifest.status == .finalizing else { continue }
      manifest.updateStatus(.failed)
      do {
        try manifest.write(to: manifestEntry.manifestURL)
      } catch {
        NativeLogger.w(
          "RecordingStore",
          "Failed to mark interrupted project as failed",
          context: ["path": manifestEntry.manifestURL.path, "error": error.localizedDescription]
        )
      }
    }
  }

  @discardableResult
  func markInvalidReadyProjectsAsFailed() -> Int {
    var updatedCount = 0

    for projectRootURL in projectDirectories() {
      guard let manifestEntry = loadManifestEntry(for: projectRootURL) else { continue }
      var manifest = manifestEntry.manifest
      guard manifest.status == .ready else { continue }

      let missingFiles = missingRequiredProjectFiles(
        for: manifest,
        projectRootURL: projectRootURL
      )
      guard !missingFiles.isEmpty else { continue }

      manifest.updateStatus(.failed)
      do {
        try manifest.write(to: manifestEntry.manifestURL)
        updatedCount += 1
      } catch {
        NativeLogger.w(
          "RecordingStore",
          "Failed to mark invalid ready project as failed",
          context: [
            "path": manifestEntry.manifestURL.path,
            "missingFiles": missingFiles.map(\.lastPathComponent).joined(separator: ","),
            "error": error.localizedDescription,
          ]
        )
      }
    }

    return updatedCount
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

  private func projectDirectories() -> [URL] {
    guard
      let contents = try? fm.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    return contents.filter(RecordingProjectPaths.isProjectDirectory)
  }

  private func loadManifestEntry(
    for projectRootURL: URL
  ) -> (manifestURL: URL, manifest: RecordingProjectManifest)? {
    let manifestURL = RecordingProjectPaths.manifestURL(for: projectRootURL)

    do {
      let manifest = try RecordingProjectManifest.read(from: manifestURL)
      let expectedProjectID = RecordingProjectPaths.projectID(for: projectRootURL)
      guard manifest.projectId == expectedProjectID else {
        throw RecordingProjectManifestError.projectDirectoryMismatch(
          expectedProjectID: expectedProjectID,
          actualProjectID: manifest.projectId
        )
      }
      return (manifestURL, manifest)
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
  }

  private func missingRequiredProjectFiles(
    for manifest: RecordingProjectManifest,
    projectRootURL: URL
  ) -> [URL] {
    ProjectOpenValidator.missingRequiredProjectFiles(
      for: manifest,
      projectRootURL: projectRootURL,
      fileManager: fm
    )
  }
}
