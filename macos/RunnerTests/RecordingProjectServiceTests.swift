import CoreGraphics
import XCTest

@testable import Clingfy

/// PR 13 guard: RecordingProjectService reproduces the skeleton + metadata +
/// manifest setup that was inline in startRecording. Real-FS integration
/// (mirrors RecordingFailureRecoveryTests conventions); the created project is
/// cleaned up.
final class RecordingProjectServiceTests: XCTestCase {
  private let service = RecordingProjectService()

  private func makeBasicEditorSeed() -> RecordingMetadata.EditorSeed {
    RecordingMetadata.EditorSeed(
      cameraVisible: true,
      cameraLayoutPreset: .overlayBottomRight,
      cameraNormalizedCenter: nil,
      cameraSizeFactor: 0.18,
      cameraShape: .circle,
      cameraCornerRadius: 0.0,
      cameraBorderWidth: 0.0,
      cameraBorderColorArgb: nil,
      cameraShadow: 0,
      cameraOpacity: 1.0,
      cameraMirror: true,
      cameraContentMode: .fill,
      cameraZoomBehavior: CameraCompositionParams.defaultZoomBehavior,
      cameraZoomScaleMultiplier: CameraCompositionParams.defaultZoomScaleMultiplier,
      cameraIntroPreset: CameraCompositionParams.defaultIntroPreset,
      cameraOutroPreset: CameraCompositionParams.defaultOutroPreset,
      cameraZoomEmphasisPreset: .none,
      cameraIntroDurationMs: CameraCompositionParams.defaultIntroDurationMs,
      cameraOutroDurationMs: CameraCompositionParams.defaultOutroDurationMs,
      cameraZoomEmphasisStrength: CameraCompositionParams.defaultZoomEmphasisStrength,
      cameraChromaKeyEnabled: false,
      cameraChromaKeyStrength: 0.4,
      cameraChromaKeyColorArgb: nil
    )
  }

  func testCreateSkeletonBuildsProjectDirectories() throws {
    let skeleton = try service.createSkeleton()
    addTeardownBlock { try? FileManager.default.removeItem(at: skeleton.projectRoot) }

    let fm = FileManager.default
    XCTAssertTrue(skeleton.projectId.hasPrefix("rec_"))
    XCTAssertTrue(fm.fileExists(atPath: skeleton.projectRoot.path))
    XCTAssertTrue(
      fm.fileExists(atPath: RecordingProjectPaths.captureDirectoryURL(for: skeleton.projectRoot).path))
    XCTAssertTrue(
      fm.fileExists(
        atPath: RecordingProjectPaths.cameraSegmentsDirectoryURL(for: skeleton.projectRoot).path))
    XCTAssertTrue(
      fm.fileExists(atPath: RecordingProjectPaths.postDirectoryURL(for: skeleton.projectRoot).path))
    XCTAssertTrue(
      fm.fileExists(
        atPath: RecordingProjectPaths.derivedDirectoryURL(for: skeleton.projectRoot).path))
    XCTAssertEqual(
      skeleton.screenVideoURL,
      RecordingProjectPaths.screenVideoURL(for: skeleton.projectRoot))
  }

  func testWriteProjectFilesWritesCapturingManifestAndReturnsMetadata() throws {
    let skeleton = try service.createSkeleton()
    addTeardownBlock { try? FileManager.default.removeItem(at: skeleton.projectRoot) }

    let seed = makeBasicEditorSeed()
    let metadata = try service.writeProjectFiles(
      projectRoot: skeleton.projectRoot,
      projectId: skeleton.projectId,
      metadataInputs: .init(
        displayMode: .explicitID,
        displayID: 7,
        cropRect: nil,
        frameRate: 60,
        quality: .fhd,
        cursorEnabled: true,
        cursorLinked: true,
        windowID: nil,
        excludedRecorderApp: false
      ),
      cameraCaptureInfo: nil,
      editorSeed: seed,
      includeCameraInManifest: false
    )

    XCTAssertEqual(metadata.editorSeed, seed)
    XCTAssertNil(metadata.camera)

    let manifest = try RecordingProjectManifest.read(
      from: RecordingProjectPaths.manifestURL(for: skeleton.projectRoot))
    XCTAssertEqual(manifest.status, .capturing)
  }
}
