import Foundation

/// Stateless project-metadata writers extracted out of the
/// ScreenRecorderFacade body (Slice 2 / PR 10a of the strangler refactor).
///
/// Only the genuinely pure pieces are moved here: both take explicit inputs and
/// touch no facade session state. The session-state-coupled writers
/// (writeMetadataSidecar / writeCameraMetadataSidecarIfNeeded /
/// updateMetadataSidecarOnFinish) intentionally stay in the facade until the
/// later state-ownership migration — moving them now would either leak the
/// deferred session state as `internal` or require editing the deferred
/// setCaptureBackend finalize tree.
///
/// This is the seed of the future RecordingFinalizer's collaborator
/// (engine-domain; see windows-port-inventory §7). Uninstantiable namespace.
enum MetadataSidecarWriter {
  static func cameraCaptureInfo(
    from result: CameraRecordingResult,
    screenRawURL _: URL
  ) -> RecordingMetadata.CameraCaptureInfo {
    RecordingMetadata.CameraCaptureInfo(
      mode: .separateCameraAsset,
      enabled: true,
      rawRelativePath: RecordingProjectPaths.relativeCameraRawPath,
      metadataRelativePath: RecordingProjectPaths.relativeCameraMetadataPath,
      deviceId: result.metadata.deviceId,
      mirroredRaw: result.metadata.mirroredRaw,
      nominalFrameRate: result.metadata.nominalFrameRate,
      dimensions: result.metadata.dimensions.map {
        RecordingMetadata.Dimensions(width: $0.width, height: $0.height)
      },
      segments: result.metadata.segments
    )
  }

  static func updateProjectManifestStatus(
    _ status: RecordingProjectStatus,
    projectRoot: URL
  ) {
    let manifestURL = RecordingProjectPaths.manifestURL(for: projectRoot)
    guard var manifest = try? RecordingProjectManifest.read(from: manifestURL) else {
      NativeLogger.w(
        "Facade",
        "Could not update recording project manifest status",
        context: ["path": manifestURL.path, "status": status.rawValue]
      )
      return
    }

    manifest.updateStatus(status)
    do {
      try manifest.write(to: manifestURL)
    } catch {
      NativeLogger.w(
        "Facade",
        "Failed writing recording project manifest status",
        context: [
          "path": manifestURL.path,
          "status": status.rawValue,
          "error": error.localizedDescription,
        ]
      )
    }
  }
}
