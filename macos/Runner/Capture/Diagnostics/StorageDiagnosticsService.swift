import FlutterMacOS
import Foundation

/// Capture/storage diagnostics surface, extracted out of the
/// ScreenRecorderFacade body (Slice 2 / PR 7 of the strangler refactor).
///
/// Implemented as an `extension ScreenRecorderFacade` (the
/// ScreenRecorderFacade+Permissions pattern) — no new stored state, methods
/// stay on the facade so every call site (method dispatcher / MainFlutterWindow
/// switch / `preflightCaptureDestination`) is unchanged. Pure relocation;
/// behavior identical. Engine-domain policy + FS query (see
/// windows-port-inventory §7).
extension ScreenRecorderFacade {
  func getCaptureDiagnostics(result: @escaping FlutterResult) {
    var payload: [String: Any] = [
      "backend": currentBackendName(),
      "captureFps": captureFPS,
    ]
    if let bytes = availableDiskSpaceBytes(at: currentCaptureDestinationURL()) {
      payload["captureDestinationFreeBytes"] = bytes
    }
    if let bytes = availableDiskSpaceBytes(at: AppPaths.recordingsRoot()) {
      payload["recordingsFreeBytes"] = bytes
    }
    if let bytes = availableDiskSpaceBytes(at: resolveSaveFolderURL()) {
      payload["saveFolderFreeBytes"] = bytes
    }
    result(payload)
  }

  /// What the speech model costs, and whether it can be removed right now.
  ///
  /// Kept off `getStorageSnapshot` on purpose. That payload is a fixed ten keys
  /// pinned on three platforms, it is fetched on the record-start preflight and
  /// on a timer, and it has nowhere to express installed / busy / loaded or a
  /// second byte bucket. This is asked for lazily, by the one page that shows
  /// it.
  func getCaptionModelInfo(result: @escaping FlutterResult) {
    let info = CaptionModelStore.info(variant: CaptionsService.modelVariant)
    result(
      info.toFlutter(
        busy: captionsService.isBusy,
        loaded: captionsService.isModelLoaded
      ))
  }

  /// True when nothing is touching the model. The UI mirrors this to grey the
  /// button, but this side is the authority — the UI's copy is up to 30s stale.
  func canDeleteCaptionModel() -> Bool { !captionsService.isBusy }

  /// Unload, then remove. In that order, always.
  ///
  /// Core ML keeps the weights mmapped, so deleting the directory under a live
  /// pipeline frees nothing, leaves the engine transcribing from an unlinked
  /// inode, and reports success — three lies at once.
  func deleteCaptionModel(result: @escaping FlutterResult) {
    captionsService.releaseModel { [weak self] in
      let freed = CaptionModelStore.delete()
      NativeLogger.i(
        "Captions", "Removed the speech model",
        context: ["freedBytes": Int(freed)])
      _ = self
      DispatchQueue.main.async {
        result(["freedBytes": Int(freed)])
      }
    }
  }

  func getStorageSnapshot(result: @escaping FlutterResult) {
    let snapshot = StorageInfoProvider.buildSnapshot(
      captureDestinationURL: currentCaptureDestinationURL(),
      recordingsURL: AppPaths.recordingsRoot(),
      tempURL: AppPaths.tempRoot(),
      logsURL: AppPaths.logsRoot()
    )
    result(snapshot.asMap())
  }

  func currentCaptureDestinationURL() -> URL {
    CaptureDestinationDiagnostics.url(for: sessionState.activeRecordingProjectRoot)
  }

  func availableDiskSpaceBytes(at url: URL) -> Int64? {
    StorageInfoProvider.availableCapacity(for: url)
  }
}
