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
    CaptureDestinationDiagnostics.url(for: activeRecordingProjectRoot)
  }

  func availableDiskSpaceBytes(at url: URL) -> Int64? {
    StorageInfoProvider.availableCapacity(for: url)
  }
}
