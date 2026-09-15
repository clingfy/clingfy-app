import AVFoundation
import CoreGraphics
import FlutterMacOS
import Foundation

/// Slice 8 / PR 27: the Export engine — owns `LetterboxExporter` and runs
/// the full `exportVideo(...)` orchestration that previously lived inline
/// on `ScreenRecorderFacade`. The engine is a stateful class (it holds the
/// exporter) but the orchestration is parametrised on `Input` +
/// `Dependencies` so it stays decoupled from the facade.
///
/// What this engine does, in order:
///   1. Load the recording project ref via the injected closure (returns
///      `EXPORT_INPUT_MISSING` on failure).
///   2. Read the source video track + derive `srcSize` (`AVAsset` query).
///   3. Resolve the target output size via `dependencies.resolveTargetSize`.
///   4. Verify the input file exists (`EXPORT_INPUT_MISSING` if missing —
///      this is the catch for "manifest exists but raw file deleted").
///   5. Resolve the output folder (`input.directoryOverride` wins;
///      otherwise `dependencies.saveFolderURL()`).
///   6. Build the output URL with collision avoidance (`stem (N).ext`).
///   7. Snapshot `keepOriginals` + `recordingStore` for use in the
///      completion block (matches the original capture-at-start
///      behavior — changing prefs mid-export must not affect cleanup).
///   8. Clamp audio params: gain 0…24 dB, volume 0…100 %, loudness
///      −24…−6 dBFS.
///   9. Sanitize camera params via the injected closure.
///   10. Call `exporter.export(...)` with the full param list.
///   11. On completion: write export record to manifest + schedule
///       background cleanup (or map error via
///       `dependencies.flutterExportFailure`).
///
/// The facade keeps its public `exportVideo(...)` /
/// `cancelExport()` entry points but they delegate to the engine.
/// Dependencies are passed per-call rather than stored on the engine to
/// keep ownership flat — the facade still owns `prefs`, `saveFolder`,
/// `recordingStore`, and the Slice-2 / PR-11 ExportPrep helpers
/// (`resolveTargetSize`, `exportFormatInfo`, `flutterExportFailure` are
/// extensions on the facade).
///
/// Engine-domain; see `windows-port-inventory.md` §7.
@MainActor
final class ExportEngine {

  private let exporter: LetterboxExporter

  /// Live GIF transcode (runs after the render). Retained so `cancel()` can
  /// stop it mid-transcode.
  private var gifSession: GifExportSession?

  init(exporter: LetterboxExporter = LetterboxExporter()) {
    self.exporter = exporter
  }

  /// The 22 export parameters that flow from MainFlutterWindow through
  /// the facade. Mirrors the existing `exportVideo(...)` arg list 1:1 so
  /// the facade can build one without renaming.
  struct Input {
    let projectPath: String
    let layout: String
    let resolution: String
    let fit: String
    let padding: Double
    let cornerRadius: Double
    let backgroundColor: Int?
    let backgroundImagePath: String?
    let backgroundPreset: CanvasBackgroundPreset?
    let cursorSize: Double
    let zoomFactor: Double
    let showCursor: Bool
    let filename: String?
    let directoryOverride: String?
    let format: String
    let codec: String
    let bitrate: String
    /// GIF-only long-edge size preset ("small"/"medium"/"large"). Resolved to a
    /// pixel cap via `GifExportPolicy.maxLongEdge(forSizePreset:)`; unknown/older
    /// values fall back to "large" (today's output). Ignored for non-GIF formats.
    var gifSize: String = "large"
    let audioGainDb: Double
    let audioVolumePercent: Double
    let autoNormalizeOnExport: Bool
    let targetLoudnessDbfs: Double
    /// Mic noise reduction. Disabled by default so older payloads are unchanged.
    var voiceCleanup: VoiceCleanupRequest = .disabled
    let cameraPath: String?
    let cameraParams: CameraCompositionParams?
    /// Canvas-wide color grade baked into the exported screen content.
    /// `.identity` = no adjustment (the manual render path skips the pass).
    var colorGrade: ColorGrade = .identity
    /// Kept source ranges (enabled clips, timeline order) to bake in. Empty =
    /// no cuts, so the export keeps the whole source (a passthrough).
    var clips: [ClipKeptRange] = []
    /// Directory of pre-rasterized caption bitmaps (one PNG per cue), or `nil`
    /// when captions are off. Defaults to `nil` so every existing caller and
    /// every older Flutter payload exports byte-for-byte as before.
    var captionBitmapDirectory: String? = nil
    /// Caption cues in source time. Empty = no burn-in.
    var captions: [CaptionCueTrack.Cue] = []
  }

  /// Facade-owned collaborators + ExportPrep helpers, injected per-call.
  /// Closures (rather than stored references) so the engine doesn't
  /// require ownership of `prefs` / `saveFolder` / the facade extensions;
  /// the facade is still the single owner of those.
  struct Dependencies {
    let loadRecordingProject: (String) -> RecordingProjectRef?
    let resolveTargetSize: (CGSize, String, String) -> CGSize
    let exportFormatInfo: (String) -> ExportFormatInfo
    let flutterExportFailure: (Error) -> FlutterError
    let sanitizeCameraParams: (CameraCompositionParams?, String?) -> CameraCompositionParams?
    let saveFolderURL: () -> URL
    let recordingStore: RecordingStore
    /// Snapshot of `prefs.keepOriginals` at call time — matches the
    /// original `let keepOriginals = prefs.keepOriginals` capture at the
    /// top of `exportVideo`. Changing the pref mid-export must not affect
    /// the cleanup that runs in the completion block.
    let keepOriginals: Bool
    let defaultZoomFollowStrength: CGFloat
  }

  /// Why the destination cannot receive an export, or nil when it can.
  ///
  /// Deliberately checks reachability and writability separately: an ejected
  /// drive and a permission problem need different actions from the user, and
  /// "Cannot create file" tells them neither.
  static func destinationProblem(folder: URL) -> String? {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) else {
      // A path under /Volumes that no longer exists is almost always an
      // unmounted disk rather than a deleted folder.
      if folder.path.hasPrefix("/Volumes/") {
        return
          "The export folder is on a disk that is not connected. Reconnect it, or choose another folder."
      }
      return "The export folder no longer exists. Choose another folder."
    }
    guard isDirectory.boolValue else {
      return "The export destination is not a folder. Choose another folder."
    }
    // An actual write probe rather than a permission bit: under the sandbox a
    // folder can be POSIX-writable and still refused, and a network or
    // read-only volume only reveals itself on the write.
    let probe = folder.appendingPathComponent(".clingfy-write-probe-\(UUID().uuidString)")
    do {
      try Data().write(to: probe, options: .atomic)
      try? fileManager.removeItem(at: probe)
    } catch {
      return "The export folder cannot be written to. Choose another folder."
    }
    return nil
  }

  func export(
    input: Input,
    dependencies: Dependencies,
    onProgress: ((Double) -> Void)? = nil,
    result: @escaping FlutterResult
  ) {
    // 1. Load project.
    guard let projectRef = dependencies.loadRecordingProject(input.projectPath) else {
      result(
        FlutterError(
          code: "EXPORT_INPUT_MISSING",
          message: "Recording project not found. It may have been moved or deleted.",
          details: input.projectPath))
      return
    }

    // 2. Derive source size from the screen video track.
    let mediaSources = projectRef.mediaSources()
    let inputURL = mediaSources.screenVideoURL
    let asset = AVAsset(url: inputURL)

    func orientedSize(_ track: AVAssetTrack) -> CGSize {
      let rect = CGRect(origin: .zero, size: track.naturalSize)
        .applying(track.preferredTransform)
      return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    let srcSize: CGSize = {
      if let track = asset.tracks(withMediaType: .video).first {
        return orientedSize(track)
      }
      return CGSize(width: 1920, height: 1080)
    }()

    // 3. Target size from ExportPrep.
    let targetSize = dependencies.resolveTargetSize(srcSize, input.layout, input.resolution)

    // 4. Input file must exist on disk.
    if !FileManager.default.fileExists(atPath: inputURL.path) {
      result(
        FlutterError(
          code: "EXPORT_INPUT_MISSING",
          message: "Recording file not found. It may have been moved or deleted.",
          details: inputURL.path))
      return
    }

    // 5. Output folder: explicit override or saveFolder default.
    let folder: URL
    if let directoryOverride = input.directoryOverride, !directoryOverride.isEmpty {
      folder = URL(fileURLWithPath: directoryOverride)
    } else {
      folder = dependencies.saveFolderURL()
    }

    // 6. Output URL with collision avoidance.
    let info = dependencies.exportFormatInfo(input.format)
    let name = (input.filename?.isEmpty ?? true) ? "processed" : input.filename!
    let stem = (name as NSString).deletingPathExtension
    let finalName = "\(stem).\(info.ext)"
    var outputURL = folder.appendingPathComponent(finalName)
    var idx = 1
    while FileManager.default.fileExists(atPath: outputURL.path) {
      outputURL = folder.appendingPathComponent("\(stem) (\(idx)).\(info.ext)")
      idx += 1
    }

    // 6b. Pre-flight the destination BEFORE any rendering.
    //
    // The save folder is remembered as a plain path string, so a folder on a
    // volume that has since been ejected still looks valid in the export
    // dialog. Without this check the export renders every intermediate first —
    // minutes of work on a long recording — and only fails when AVAssetWriter
    // finally tries to create the output, with a bare "Cannot create file".
    // Fail immediately instead, and say which folder is unreachable.
    if let destinationError = Self.destinationProblem(folder: folder) {
      NativeLogger.w(
        "Export", "Export destination is not writable; refusing before rendering",
        context: ["folder": folder.path, "reason": destinationError])
      result(
        FlutterError(
          code: NativeErrorCode.exportError,
          message: destinationError,
          details: folder.path))
      return
    }

    // 7. Capture cleanup state.
    let keepOriginals = dependencies.keepOriginals
    let recordingStoreRef = dependencies.recordingStore

    // 8. Clamp audio params.
    let clampedGainDb = max(0, min(24, input.audioGainDb))
    let clampedVolumePercent = max(0, min(100, input.audioVolumePercent))
    let clampedTargetLoudnessDbfs = max(-24.0, min(-6.0, input.targetLoudnessDbfs))

    // 9. Sanitize camera params.
    let exportCameraParams = dependencies.sanitizeCameraParams(
      input.cameraParams, input.cameraPath)

    // 10. Run the exporter. GIF has no AVFileType container, so render the
    // fully-composited video to a temp MOV first and transcode it to GIF
    // afterwards (grade/camera/cuts are baked into the render — see
    // GifExportSession). The temp MOV uses the user's codec/bitrate; only the
    // container differs.
    let flutterExportFailureMap = dependencies.flutterExportFailure
    let isGif = input.format == "gif"
    let tempMovURL: URL? =
      isGif
      ? FileManager.default.temporaryDirectory
        .appendingPathComponent("clingfy-gif-source-\(UUID().uuidString).mov")
      : nil
    let renderURL = tempMovURL ?? outputURL
    let renderFormat = isGif ? "mov" : input.format
    // GIF long-edge cap for the chosen size preset (small/medium/large). Older
    // payloads without `gifSize` resolve to "large" (== today's 1080 cap).
    let gifMaxLongEdge = GifExportPolicy.maxLongEdge(forSizePreset: input.gifSize)
    // GIF is downscaled to the long-edge cap, so render the intermediate at that
    // capped (even) size — otherwise a 4K/8K selection (or a large source at the
    // Small/Medium preset) renders a huge frame just to throw it away. Non-GIF
    // is unchanged.
    let renderTarget =
      isGif ? Self.gifIntermediateSize(from: targetSize, maxLongEdge: gifMaxLongEdge) : targetSize
    // Reserve the tail of the progress bar for the GIF transcode.
    let renderProgressSpan = isGif ? 0.85 : 1.0
    let renderProgress: ((Double) -> Void)? = onProgress.map { callback in
      { value in callback(min(max(value, 0), 1) * renderProgressSpan) }
    }

    exporter.export(
      project: projectRef,
      target: renderTarget,
      padding: input.padding,
      cornerRadius: input.cornerRadius,
      backgroundColor: input.backgroundColor,
      backgroundImagePath: input.backgroundImagePath,
      backgroundPreset: input.backgroundPreset,
      cursorSize: input.cursorSize,
      showCursor: input.showCursor,
      zoomEnabled: true,
      zoomFactor: CGFloat(input.zoomFactor),
      followStrength: dependencies.defaultZoomFollowStrength,
      outputURL: renderURL,
      format: renderFormat,
      codec: input.codec,
      bitrate: input.bitrate,
      fitMode: input.fit,
      audioGainDb: clampedGainDb,
      audioVolumePercent: clampedVolumePercent,
      autoNormalizeOnExport: input.autoNormalizeOnExport,
      targetLoudnessDbfs: clampedTargetLoudnessDbfs,
      voiceCleanup: input.voiceCleanup,
      cameraParams: exportCameraParams,
      colorGrade: input.colorGrade,
      clips: input.clips,
      captionBitmapDirectory: input.captionBitmapDirectory,
      captions: input.captions,
      onProgress: renderProgress
    ) { res in
      switch res {
      case .success(let final):
        // Non-GIF: finish directly.
        guard isGif, let tempMovURL else {
          Self.finishExportSuccess(
            finalPath: final.path, input: input, projectRef: projectRef,
            keepOriginals: keepOriginals, recordingStore: recordingStoreRef, result: result)
          return
        }
        // GIF: transcode the rendered MOV -> GIF, delete the temp, then finish.
        DispatchQueue.main.async {
          let session = GifExportSession()
          self.gifSession = session
          session.run(
            sourceVideoURL: final,
            outputURL: outputURL,
            maxLongEdge: gifMaxLongEdge,
            onProgress: onProgress.map { callback in
              { value in callback(renderProgressSpan + value * (1 - renderProgressSpan)) }
            }
          ) { gifResult in
            self.gifSession = nil
            try? FileManager.default.removeItem(at: tempMovURL)
            switch gifResult {
            case .success(let gifURL):
              Self.finishExportSuccess(
                finalPath: gifURL.path, input: input, projectRef: projectRef,
                keepOriginals: keepOriginals, recordingStore: recordingStoreRef, result: result)
            case .failure(let error):
              result(flutterExportFailureMap(error))
            }
          }
        }
      case .failure(let err):
        if let tempMovURL { try? FileManager.default.removeItem(at: tempMovURL) }
        // Map error to FlutterError via the facade's ExportPrep extension.
        result(flutterExportFailureMap(err))
      }
    }
  }

  /// Append the export record to the manifest, schedule cleanup, and return the
  /// final path to Flutter. `nonisolated` + static so it can run from either the
  /// direct render completion or the GIF transcode completion, on any thread.
  /// The intermediate render size for a GIF: the chosen target capped to the
  /// GIF long-edge (`maxLongEdge`, from the size preset) and rounded to even
  /// dimensions (the H.264 intermediate wants even width/height). Keeps a
  /// 4K/8K selection — or any source larger than the preset cap — from
  /// rendering a giant frame just to downscale it.
  ///
  /// Delegates to `GifExportPolicy` rather than computing it here: Flutter asks
  /// the same question through `resolveExportSize` so it can rasterise caption
  /// bitmaps at the canvas the frames will really be, and two implementations
  /// of this would drift into captions composited at the wrong scale.
  nonisolated private static func gifIntermediateSize(
    from target: CGSize,
    maxLongEdge: CGFloat = GifExportPolicy.defaultMaxLongEdge
  ) -> CGSize {
    GifExportPolicy.intermediateRenderSize(canvasSize: target, maxLongEdge: maxLongEdge)
  }

  nonisolated private static func finishExportSuccess(
    finalPath: String,
    input: Input,
    projectRef: RecordingProjectRef,
    keepOriginals: Bool,
    recordingStore: RecordingStore,
    result: @escaping FlutterResult
  ) {
    if var manifest = try? RecordingProjectManifest.read(
      from: RecordingProjectPaths.manifestURL(for: projectRef.rootURL))
    {
      manifest.appendExportRecord(
        format: input.format,
        resolution: input.resolution,
        destinationPath: finalPath)
      try? manifest.write(
        to: RecordingProjectPaths.manifestURL(for: projectRef.rootURL))
    }
    DispatchQueue.global(qos: .utility).async {
      recordingStore.cleanupAfterExport(
        projectRootURL: projectRef.rootURL,
        keepOriginals: keepOriginals)
    }
    result(finalPath)
  }

  func cancel() {
    exporter.cancel()
    gifSession?.cancel()
  }
}
