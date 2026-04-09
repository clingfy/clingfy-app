import Foundation

/// Centralized path management for app-internal and user-facing directories.
///
/// This class provides a clear separation between:
/// - **Internal workspace**: App-private storage for raw recordings, cursor data, and metadata
/// - **Export folder**: User-facing folder for final exported files (managed by SaveFolderStore)
enum AppPaths {
  private static let fallbackAppFolder = "com.tiin.clingfy"

  // MARK: - Internal Workspace (App-Private)

  /// Returns the root directory for internal recordings storage.
  /// Location: `~/Library/Application Support/<app-id>/Recordings/`
  ///
  /// This directory is:
  /// - Not user-facing (hidden in Application Support)
  /// - Excluded from backups (best-effort)
  /// - Safe from accidental user deletion
  /// - Works in both sandboxed and non-sandboxed builds
  static func recordingsRoot() -> URL {
    let recordingsDir = applicationSupportRoot()
      .appendingPathComponent("Recordings", isDirectory: true)
    ensureDirectory(recordingsDir, label: "recordings workspace", excludeFromBackup: true)
    return recordingsDir
  }

  /// Returns the root directory for internal log storage.
  /// Location: `~/Library/Application Support/<app-id>/Logs/`
  static func logsRoot() -> URL {
    let logsDir = applicationSupportRoot().appendingPathComponent("Logs", isDirectory: true)
    ensureDirectory(logsDir, label: "logs workspace", excludeFromBackup: true)
    return logsDir
  }

  /// Returns the daily log file URL for the provided date.
  static func logFileURL(for date: Date = Date()) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let fileName = "logs_\(formatter.string(from: date)).jsonl"
    return logsRoot().appendingPathComponent(fileName, isDirectory: false)
  }

  /// Returns a temporary directory for intermediate operations.
  /// Location: `~/Library/Caches/<app-id>/Temp/`
  ///
  /// Use this for temporary export files or other transient data.
  static func tempRoot() -> URL {
    let tempDir = cachesRoot().appendingPathComponent("Temp", isDirectory: true)
    ensureDirectory(tempDir, label: "temp directory")
    return tempDir
  }

  // MARK: - Validation

  /// Checks if a URL is within the internal recordings workspace.
  static func isInternalRecording(_ url: URL) -> Bool {
    let standardizedPath = url.standardizedFileURL.path
    let currentRoot = recordingsRoot().standardizedFileURL.path
    return standardizedPath.hasPrefix(currentRoot)
  }

  // MARK: - Private Helpers

  private static func appFolderName() -> String {
    let bundleID = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let bundleID, !bundleID.isEmpty {
      return bundleID
    }
    return fallbackAppFolder
  }

  private static func applicationSupportRoot() -> URL {
    let root = systemRoot(
      for: .applicationSupportDirectory,
      fallbackSubpath: "Library/Application Support"
    ).appendingPathComponent(appFolderName(), isDirectory: true)
    ensureDirectory(root, label: "application support root")
    return root
  }

  private static func cachesRoot() -> URL {
    let root = systemRoot(for: .cachesDirectory, fallbackSubpath: "Library/Caches")
      .appendingPathComponent(appFolderName(), isDirectory: true)
    ensureDirectory(root, label: "caches root")
    return root
  }

  private static func systemRoot(
    for searchPath: FileManager.SearchPathDirectory,
    fallbackSubpath: String
  ) -> URL {
    if let url = FileManager.default.urls(for: searchPath, in: .userDomainMask).first {
      return url
    }

    return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(fallbackSubpath, isDirectory: true)
  }

  private static func ensureDirectory(
    _ url: URL,
    label: String,
    excludeFromBackup shouldExcludeFromBackup: Bool = false
  ) {
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
      if shouldExcludeFromBackup {
        excludeFromBackup(url)
      }
    } catch {
      NativeLogger.e(
        "AppPaths", "Failed to create \(label)",
        context: ["path": url.path, "error": error.localizedDescription])
    }
  }

  private static func excludeFromBackup(_ url: URL) {
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    var mutableURL = url
    do {
      try mutableURL.setResourceValues(resourceValues)
    } catch {
      // Best-effort, don't fail if this doesn't work
      NativeLogger.w("AppPaths", "Could not exclude from backup", context: ["path": url.path])
    }
  }
}
