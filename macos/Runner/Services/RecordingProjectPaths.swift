import Foundation

enum RecordingProjectPaths {
  static let projectExtension = "clingfyproj"
  static let manifestFileName = "project.json"
  static let schemaSentinelFileName = ".schema-v3-clingfyproj"

  static let captureDirectoryName = "capture"
  static let cameraDirectoryName = "camera"
  static let cameraSegmentsDirectoryName = "segments"
  static let postDirectoryName = "post"
  static let derivedDirectoryName = "derived"

  static let screenVideoFileName = "screen.mov"
  static let screenMetadataFileName = "screen.meta.json"
  static let cursorDataFileName = "cursor.json"
  static let zoomManualFileName = "zoom.manual.json"

  static let cameraRawFileName = "raw.mov"
  static let cameraMetadataFileName = "meta.json"

  static let postStateFileName = "state.json"
  static let thumbnailFileName = "thumbnail.jpg"
  static let waveformFileName = "waveform.json"

  static var relativeScreenVideoPath: String {
    "\(captureDirectoryName)/\(screenVideoFileName)"
  }

  static var relativeScreenMetadataPath: String {
    "\(captureDirectoryName)/\(screenMetadataFileName)"
  }

  static var relativeCursorDataPath: String {
    "\(captureDirectoryName)/\(cursorDataFileName)"
  }

  static var relativeZoomManualPath: String {
    "\(captureDirectoryName)/\(zoomManualFileName)"
  }

  static var relativeCameraRawPath: String {
    "\(cameraDirectoryName)/\(cameraRawFileName)"
  }

  static var relativeCameraMetadataPath: String {
    "\(cameraDirectoryName)/\(cameraMetadataFileName)"
  }

  static var relativeCameraSegmentsDirectoryPath: String {
    "\(cameraDirectoryName)/\(cameraSegmentsDirectoryName)"
  }

  static var relativePostStatePath: String {
    "\(postDirectoryName)/\(postStateFileName)"
  }

  static var relativeThumbnailPath: String {
    "\(postDirectoryName)/\(thumbnailFileName)"
  }

  static var relativeWaveformPath: String {
    "\(derivedDirectoryName)/\(waveformFileName)"
  }

  static func projectsRoot() -> URL {
    AppPaths.recordingsRoot()
  }

  static func projectDirectoryName(for projectId: String) -> String {
    "\(projectId).\(projectExtension)"
  }

  static func projectRoot(for projectId: String) -> URL {
    projectsRoot().appendingPathComponent(projectDirectoryName(for: projectId), isDirectory: true)
  }

  static func manifestURL(for projectRoot: URL) -> URL {
    projectRoot.appendingPathComponent(manifestFileName, isDirectory: false)
  }

  static func captureDirectoryURL(for projectRoot: URL) -> URL {
    projectRoot.appendingPathComponent(captureDirectoryName, isDirectory: true)
  }

  static func screenVideoURL(for projectRoot: URL) -> URL {
    captureDirectoryURL(for: projectRoot).appendingPathComponent(screenVideoFileName, isDirectory: false)
  }

  static func screenMetadataURL(for projectRoot: URL) -> URL {
    captureDirectoryURL(for: projectRoot).appendingPathComponent(screenMetadataFileName, isDirectory: false)
  }

  static func cursorDataURL(for projectRoot: URL) -> URL {
    captureDirectoryURL(for: projectRoot).appendingPathComponent(cursorDataFileName, isDirectory: false)
  }

  static func zoomManualURL(for projectRoot: URL) -> URL {
    captureDirectoryURL(for: projectRoot).appendingPathComponent(zoomManualFileName, isDirectory: false)
  }

  static func cameraDirectoryURL(for projectRoot: URL) -> URL {
    projectRoot.appendingPathComponent(cameraDirectoryName, isDirectory: true)
  }

  static func cameraRawURL(for projectRoot: URL) -> URL {
    cameraDirectoryURL(for: projectRoot).appendingPathComponent(cameraRawFileName, isDirectory: false)
  }

  static func cameraMetadataURL(for projectRoot: URL) -> URL {
    cameraDirectoryURL(for: projectRoot).appendingPathComponent(cameraMetadataFileName, isDirectory: false)
  }

  static func cameraSegmentsDirectoryURL(for projectRoot: URL) -> URL {
    cameraDirectoryURL(for: projectRoot).appendingPathComponent(
      cameraSegmentsDirectoryName,
      isDirectory: true
    )
  }

  static func postDirectoryURL(for projectRoot: URL) -> URL {
    projectRoot.appendingPathComponent(postDirectoryName, isDirectory: true)
  }

  static func postStateURL(for projectRoot: URL) -> URL {
    postDirectoryURL(for: projectRoot).appendingPathComponent(postStateFileName, isDirectory: false)
  }

  static func thumbnailURL(for projectRoot: URL) -> URL {
    postDirectoryURL(for: projectRoot).appendingPathComponent(thumbnailFileName, isDirectory: false)
  }

  static func derivedDirectoryURL(for projectRoot: URL) -> URL {
    projectRoot.appendingPathComponent(derivedDirectoryName, isDirectory: true)
  }

  static func waveformURL(for projectRoot: URL) -> URL {
    derivedDirectoryURL(for: projectRoot).appendingPathComponent(waveformFileName, isDirectory: false)
  }

  static func schemaSentinelURL(rootURL: URL = projectsRoot()) -> URL {
    rootURL.appendingPathComponent(schemaSentinelFileName, isDirectory: false)
  }

  @discardableResult
  static func createProjectSkeleton(
    projectId: String,
    fileManager: FileManager = .default
  ) throws -> URL {
    let root = projectRoot(for: projectId)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: captureDirectoryURL(for: root), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: cameraSegmentsDirectoryURL(for: root), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: postDirectoryURL(for: root), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: derivedDirectoryURL(for: root), withIntermediateDirectories: true)
    return root
  }

  static func allProjectArtifactURLs(for projectRoot: URL) -> [URL] {
    [
      projectRoot,
      manifestURL(for: projectRoot),
      captureDirectoryURL(for: projectRoot),
      screenVideoURL(for: projectRoot),
      screenMetadataURL(for: projectRoot),
      cursorDataURL(for: projectRoot),
      zoomManualURL(for: projectRoot),
      cameraDirectoryURL(for: projectRoot),
      cameraRawURL(for: projectRoot),
      cameraMetadataURL(for: projectRoot),
      cameraSegmentsDirectoryURL(for: projectRoot),
      postDirectoryURL(for: projectRoot),
      postStateURL(for: projectRoot),
      thumbnailURL(for: projectRoot),
      derivedDirectoryURL(for: projectRoot),
      waveformURL(for: projectRoot),
    ]
  }

  static func durableProjectStateURLs(for projectRoot: URL) -> [URL] {
    [
      manifestURL(for: projectRoot),
      captureDirectoryURL(for: projectRoot),
      screenVideoURL(for: projectRoot),
      screenMetadataURL(for: projectRoot),
      cursorDataURL(for: projectRoot),
      zoomManualURL(for: projectRoot),
      cameraDirectoryURL(for: projectRoot),
      cameraRawURL(for: projectRoot),
      cameraMetadataURL(for: projectRoot),
      cameraSegmentsDirectoryURL(for: projectRoot),
      postDirectoryURL(for: projectRoot),
      postStateURL(for: projectRoot),
      thumbnailURL(for: projectRoot),
    ]
  }

  static func rebuildableProjectArtifactURLs(for projectRoot: URL) -> [URL] {
    [
      derivedDirectoryURL(for: projectRoot),
      waveformURL(for: projectRoot),
    ]
  }

  static func durableCaptureArtifactFileURLs(for projectRoot: URL) -> [URL] {
    [
      screenVideoURL(for: projectRoot),
      screenMetadataURL(for: projectRoot),
      cursorDataURL(for: projectRoot),
      zoomManualURL(for: projectRoot),
      cameraRawURL(for: projectRoot),
      cameraMetadataURL(for: projectRoot),
      postStateURL(for: projectRoot),
      thumbnailURL(for: projectRoot),
    ]
  }

  static func hasDurableCaptureArtifacts(
    in projectRoot: URL,
    fileManager: FileManager = .default
  ) -> Bool {
    durableCaptureArtifactFileURLs(for: projectRoot).contains {
      fileManager.fileExists(atPath: $0.path)
    }
  }

  static func projectExists(_ projectRoot: URL, fileManager: FileManager = .default) -> Bool {
    isProjectDirectory(projectRoot)
      && fileManager.fileExists(atPath: manifestURL(for: projectRoot).path)
  }

  static func isProjectDirectory(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == projectExtension
  }

  static func projectID(for projectRoot: URL) -> String {
    projectRoot.deletingPathExtension().lastPathComponent
  }

  static func relativePath(from projectRoot: URL, to url: URL) -> String? {
    let projectPath = projectRoot.standardizedFileURL.path
    let artifactPath = url.standardizedFileURL.path
    guard artifactPath.hasPrefix(projectPath + "/") else {
      return nil
    }
    return String(artifactPath.dropFirst(projectPath.count + 1))
  }

  static func resolvedURL(for relativePath: String?, projectRoot: URL) -> URL? {
    guard let relativePath, !relativePath.isEmpty else { return nil }
    return projectRoot.appendingPathComponent(relativePath, isDirectory: false)
  }

  static func enclosingProjectRoot(for artifactURL: URL) -> URL? {
    var current = artifactURL.standardizedFileURL
    if !isProjectDirectory(current) {
      current.deleteLastPathComponent()
    }

    while current.path != current.deletingLastPathComponent().path {
      if isProjectDirectory(current) {
        return current
      }
      current.deleteLastPathComponent()
    }

    return isProjectDirectory(current) ? current : nil
  }

  static func resolvedCursorDataURL(forScreenVideoURL screenVideoURL: URL) -> URL {
    if let projectRoot = enclosingProjectRoot(for: screenVideoURL) {
      return cursorDataURL(for: projectRoot)
    }

    return screenVideoURL.deletingPathExtension().appendingPathExtension("cursor.json")
  }

  static func makeProjectID(date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let randomSuffix = UUID().uuidString
      .replacingOccurrences(of: "-", with: "")
      .prefix(8)
      .lowercased()
    return "rec_\(formatter.string(from: date))_\(randomSuffix)"
  }

  static func displayName(for date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return "Clingfy \(formatter.string(from: date))"
  }

  static func ensureSchemaSentinel(
    rootURL: URL = projectsRoot(),
    fileManager: FileManager = .default
  ) throws {
    let sentinel = schemaSentinelURL(rootURL: rootURL)
    if !fileManager.fileExists(atPath: sentinel.path) {
      try Data().write(to: sentinel)
    }
  }

  static func hasLegacyFlatArtifacts(
    in rootURL: URL = projectsRoot(),
    fileManager: FileManager = .default
  ) -> Bool {
    guard let contents = try? fileManager.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return false
    }

    return contents.contains { url in
      if isProjectDirectory(url) { return false }
      let name = url.lastPathComponent
      if name == schemaSentinelFileName { return false }
      return true
    }
  }

  @discardableResult
  static func performOneTimeLegacyWorkspaceResetIfNeeded(
    isNonProductionBuild: Bool,
    rootURL: URL = projectsRoot(),
    fileManager: FileManager = .default
  ) -> Bool {
    guard isNonProductionBuild else { return false }

    let sentinelURL = schemaSentinelURL(rootURL: rootURL)
    if fileManager.fileExists(atPath: sentinelURL.path) {
      return false
    }

    if hasLegacyFlatArtifacts(in: rootURL, fileManager: fileManager),
      let contents = try? fileManager.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    {
      for url in contents where url.lastPathComponent != schemaSentinelFileName {
        try? fileManager.removeItem(at: url)
      }
    }

    do {
      try ensureSchemaSentinel(rootURL: rootURL, fileManager: fileManager)
    } catch {
      NativeLogger.w(
        "ProjectPaths",
        "Failed to create recording schema sentinel",
        context: ["path": sentinelURL.path, "error": error.localizedDescription]
      )
    }

    return true
  }
}
