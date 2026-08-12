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

  /// The one refusal every delete gate answers with.
  ///
  /// Two places decide: the method dispatcher checks `canDeleteCaptionModel()`
  /// before the call, and the unload below refuses when the engine will not hand
  /// the weights back. Flutter matches on the code and renders the message
  /// verbatim, so the two must not drift into different sentences.
  static func captionModelInUseError() -> FlutterError {
    FlutterError(
      code: "MODEL_IN_USE",
      message:
        "The speech model is in use. Wait for the transcription to finish, then try again.",
      details: nil)
  }

  /// Unload, then remove. In that order, always — and only if the unload
  /// actually happened.
  ///
  /// Core ML keeps the weights mmapped, so deleting the directory under a live
  /// pipeline frees nothing, leaves the engine transcribing from an unlinked
  /// inode, and reports success — three lies at once.
  ///
  /// The unload can decline: while a cancelled job's abandoned task still owns
  /// the engine it may be mid-`WhisperKit(config)`, so the release skips rather
  /// than race it. That skip used to be indistinguishable from a successful
  /// unload, and the delete ran anyway — removing files that were never unloaded
  /// and that an uninterruptible download was still writing into.
  ///
  /// - Parameter removeModel: what actually removes the files, defaulted to the
  ///   real store. Injected only so a test can watch it: the defect the refusal
  ///   guards is not "the wrong error came back", it is that ~730 MB was removed
  ///   while Core ML still had it mmapped, and a spy on the delete is the only
  ///   thing that sees that. Defaulting to the production function means there is
  ///   no second implementation for the two to drift apart into, and no test can
  ///   pass by exercising a path the app does not take.
  func deleteCaptionModel(
    removeModel: @escaping () -> Int64 = CaptionModelStore.delete,
    result: @escaping FlutterResult
  ) {
    captionsService.releaseModel { [weak self] released in
      guard released else {
        NativeLogger.i(
          "Captions", "Refused to remove the speech model: the engine still holds it")
        DispatchQueue.main.async {
          result(ScreenRecorderFacade.captionModelInUseError())
        }
        return
      }
      let freed = removeModel()
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
