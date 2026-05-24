import CoreGraphics
import Foundation

/// Project skeleton + manifest/metadata setup, extracted out of
/// `ScreenRecorderFacade.startRecording` (Slice 3 / PR 13 of the strangler
/// refactor).
///
/// Standalone and stateless. Two phases so the facade can keep the
/// storage preflight and all session-state assignment between them, in the
/// exact original order (skeleton → facade preflight + state assignment →
/// facade-built camera/seed → write files). The camera/editor-seed factories
/// stay in the facade (camera/NSScreen-coupled — move with PR 16); this
/// service takes the already-built `editorSeed` + `cameraCaptureInfo` as
/// inputs. Behavior is identical. Engine-domain project mechanics (the bundle
/// format is FS-portable — see windows-port-inventory §7).
struct RecordingProjectService {

  struct PreparedRecordingSkeleton {
    let projectId: String
    let projectRoot: URL
    let screenVideoURL: URL
  }

  /// Plain values the facade already has — kept as an input struct so no
  /// facade state is owned here.
  struct MetadataInputs {
    let displayMode: DisplayTargetMode
    let displayID: CGDirectDisplayID
    let cropRect: CGRect?
    let frameRate: Int
    let quality: RecordingQuality
    let cursorEnabled: Bool
    let cursorLinked: Bool
    let windowID: CGWindowID?
    let excludedRecorderApp: Bool
  }

  func createSkeleton() throws -> PreparedRecordingSkeleton {
    let projectId = RecordingProjectPaths.makeProjectID()
    let projectRoot = try RecordingProjectPaths.createProjectSkeleton(projectId: projectId)
    let screenVideoURL = RecordingProjectPaths.screenVideoURL(for: projectRoot)
    return PreparedRecordingSkeleton(
      projectId: projectId, projectRoot: projectRoot, screenVideoURL: screenVideoURL)
  }

  func writeProjectFiles(
    projectRoot: URL,
    projectId: String,
    metadataInputs: MetadataInputs,
    cameraCaptureInfo: RecordingMetadata.CameraCaptureInfo?,
    editorSeed: RecordingMetadata.EditorSeed,
    includeCameraInManifest: Bool
  ) throws -> RecordingMetadata {
    let metadata = RecordingMetadata.create(
      screenRawRelativePath: RecordingProjectPaths.relativeScreenVideoPath,
      displayMode: metadataInputs.displayMode,
      displayID: metadataInputs.displayID,
      cropRect: metadataInputs.cropRect,
      frameRate: metadataInputs.frameRate,
      quality: metadataInputs.quality,
      cursorEnabled: metadataInputs.cursorEnabled,
      cursorLinked: metadataInputs.cursorLinked,
      windowID: metadataInputs.windowID,
      excludedRecorderApp: metadataInputs.excludedRecorderApp,
      camera: cameraCaptureInfo,
      editorSeed: editorSeed
    )

    let manifest = RecordingProjectManifest.create(
      projectId: projectId,
      displayName: RecordingProjectPaths.displayName(),
      includeCamera: includeCameraInManifest
    )
    try manifest.write(to: RecordingProjectPaths.manifestURL(for: projectRoot))

    return metadata
  }
}
