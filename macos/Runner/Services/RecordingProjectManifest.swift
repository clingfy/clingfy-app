import Foundation

enum RecordingProjectStatus: String, Codable {
  case capturing
  case finalizing
  case ready
  case cancelled
  case failed
  case deleted
}

enum RecordingProjectManifestError: LocalizedError {
  case invalidProjectDirectory(String)
  case unsupportedSchemaVersion(Int)

  var errorDescription: String? {
    switch self {
    case .invalidProjectDirectory(let path):
      return "Invalid recording project directory: \(path)"
    case .unsupportedSchemaVersion(let version):
      return "Unsupported recording project schema version \(version)"
    }
  }
}

struct RecordingProjectManifest: Codable {
  struct CaptureFiles: Codable {
    let screenVideo: String
    let screenMetadata: String
    let cursorData: String?
    let zoomManual: String?
  }

  struct CameraFiles: Codable {
    let rawVideo: String
    let metadata: String?
    let segmentsDirectory: String?
  }

  struct PostFiles: Codable {
    let state: String?
    let thumbnail: String?
  }

  struct DerivedFiles: Codable {
    let waveform: String?
  }

  struct ExportRecord: Codable, Equatable {
    let createdAt: Date
    let format: String
    let resolution: String
    let destinationPath: String
  }

  static let currentSchemaVersion = 2

  static func isSupportedSchemaVersion(_ version: Int) -> Bool {
    version == currentSchemaVersion
  }

  let schemaVersion: Int
  let projectId: String
  let createdAt: Date
  var updatedAt: Date
  var displayName: String
  var status: RecordingProjectStatus
  var capture: CaptureFiles
  var camera: CameraFiles?
  var post: PostFiles?
  var derived: DerivedFiles?
  var exportHistory: [ExportRecord]

  init(
    schemaVersion: Int = RecordingProjectManifest.currentSchemaVersion,
    projectId: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    displayName: String,
    status: RecordingProjectStatus,
    capture: CaptureFiles,
    camera: CameraFiles?,
    post: PostFiles?,
    derived: DerivedFiles?,
    exportHistory: [ExportRecord] = []
  ) {
    self.schemaVersion = schemaVersion
    self.projectId = projectId
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.displayName = displayName
    self.status = status
    self.capture = capture
    self.camera = camera
    self.post = post
    self.derived = derived
    self.exportHistory = exportHistory
  }

  static func create(
    projectId: String,
    displayName: String,
    includeCamera: Bool,
    createdAt: Date = Date()
  ) -> RecordingProjectManifest {
    RecordingProjectManifest(
      projectId: projectId,
      createdAt: createdAt,
      updatedAt: createdAt,
      displayName: displayName,
      status: .capturing,
      capture: CaptureFiles(
        screenVideo: RecordingProjectPaths.relativeScreenVideoPath,
        screenMetadata: RecordingProjectPaths.relativeScreenMetadataPath,
        cursorData: RecordingProjectPaths.relativeCursorDataPath,
        zoomManual: RecordingProjectPaths.relativeZoomManualPath
      ),
      camera: includeCamera
        ? CameraFiles(
            rawVideo: RecordingProjectPaths.relativeCameraRawPath,
            metadata: RecordingProjectPaths.relativeCameraMetadataPath,
            segmentsDirectory: RecordingProjectPaths.relativeCameraSegmentsDirectoryPath
          )
        : nil,
      post: PostFiles(
        state: RecordingProjectPaths.relativePostStatePath,
        thumbnail: RecordingProjectPaths.relativeThumbnailPath
      ),
      derived: DerivedFiles(
        waveform: RecordingProjectPaths.relativeWaveformPath
      ),
      exportHistory: []
    )
  }

  mutating func updateStatus(_ status: RecordingProjectStatus, at date: Date = Date()) {
    self.status = status
    self.updatedAt = date
  }

  mutating func touch(at date: Date = Date()) {
    updatedAt = date
  }

  mutating func appendExportRecord(
    format: String,
    resolution: String,
    destinationPath: String,
    at date: Date = Date()
  ) {
    exportHistory.append(
      ExportRecord(
        createdAt: date,
        format: format,
        resolution: resolution,
        destinationPath: destinationPath
      )
    )
    updatedAt = date
  }

  func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(self)
    let fileManager = FileManager.default
    let directoryURL = url.deletingLastPathComponent()
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let temporaryURL = directoryURL.appendingPathComponent(
      ".\(UUID().uuidString).\(url.lastPathComponent).tmp",
      isDirectory: false
    )

    do {
      try data.write(to: temporaryURL)
      if fileManager.fileExists(atPath: url.path) {
        _ = try fileManager.replaceItemAt(
          url,
          withItemAt: temporaryURL,
          backupItemName: nil,
          options: [.usingNewMetadataOnly]
        )
      } else {
        try fileManager.moveItem(at: temporaryURL, to: url)
      }
    } catch {
      try? fileManager.removeItem(at: temporaryURL)
      throw error
    }
  }

  static func read(from url: URL) throws -> RecordingProjectManifest {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(RecordingProjectManifest.self, from: Data(contentsOf: url))
    guard isSupportedSchemaVersion(manifest.schemaVersion) else {
      throw RecordingProjectManifestError.unsupportedSchemaVersion(manifest.schemaVersion)
    }
    return manifest
  }
}

struct ProjectMediaSources: Equatable {
  let projectRootURL: URL
  let screenVideoURL: URL
  let metadataURL: URL?
  let cursorDataURL: URL?
  let zoomManualURL: URL?
  let cameraVideoURL: URL?
  let cameraMetadataURL: URL?

  var projectPath: String { projectRootURL.path }
  var screenPath: String { screenVideoURL.path }
  var metadataPath: String? { metadataURL?.path }
  var cursorPath: String? { cursorDataURL?.path }
  var zoomManualPath: String? { zoomManualURL?.path }
  var cameraPath: String? { cameraVideoURL?.path }
}

struct RecordingProjectRef {
  let projectId: String
  let rootURL: URL
  let manifest: RecordingProjectManifest

  static func open(projectRoot: URL) throws -> RecordingProjectRef {
    guard RecordingProjectPaths.isProjectDirectory(projectRoot) else {
      throw RecordingProjectManifestError.invalidProjectDirectory(projectRoot.path)
    }
    let manifest = try RecordingProjectManifest.read(
      from: RecordingProjectPaths.manifestURL(for: projectRoot)
    )
    return RecordingProjectRef(
      projectId: manifest.projectId,
      rootURL: projectRoot,
      manifest: manifest
    )
  }

  static func open(projectPath: String) throws -> RecordingProjectRef {
    try open(projectRoot: URL(fileURLWithPath: projectPath))
  }

  func mediaSources(fileManager: FileManager = .default) -> ProjectMediaSources {
    let screenVideoURL =
      RecordingProjectPaths.resolvedURL(for: manifest.capture.screenVideo, projectRoot: rootURL)
      ?? RecordingProjectPaths.screenVideoURL(for: rootURL)
    let metadataURL =
      RecordingProjectPaths.resolvedURL(for: manifest.capture.screenMetadata, projectRoot: rootURL)
      ?? RecordingProjectPaths.screenMetadataURL(for: rootURL)
    let cursorURL = RecordingProjectPaths.resolvedURL(
      for: manifest.capture.cursorData,
      projectRoot: rootURL
    )
    let zoomManualURL = RecordingProjectPaths.resolvedURL(
      for: manifest.capture.zoomManual,
      projectRoot: rootURL
    )
    let cameraVideoURL = RecordingProjectPaths.resolvedURL(
      for: manifest.camera?.rawVideo,
      projectRoot: rootURL
    )
    let cameraMetadataURL = RecordingProjectPaths.resolvedURL(
      for: manifest.camera?.metadata,
      projectRoot: rootURL
    )

    return ProjectMediaSources(
      projectRootURL: rootURL,
      screenVideoURL: screenVideoURL,
      metadataURL: fileManager.fileExists(atPath: metadataURL.path) ? metadataURL : nil,
      cursorDataURL: cursorURL.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil },
      zoomManualURL: zoomManualURL.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil },
      cameraVideoURL: cameraVideoURL.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil },
      cameraMetadataURL: cameraMetadataURL.flatMap {
        fileManager.fileExists(atPath: $0.path) ? $0 : nil
      }
    )
  }

  func manifestURL() -> URL {
    RecordingProjectPaths.manifestURL(for: rootURL)
  }

  func writeManifest(_ manifest: RecordingProjectManifest) throws {
    try manifest.write(to: manifestURL())
  }
}
