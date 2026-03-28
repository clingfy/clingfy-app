import AVFoundation
import AppKit
import QuartzCore

final class LetterboxExporter {
  private let builder = CompositionBuilder()
  private var currentSession: AVAssetExportSession?
  private var progressTimer: Timer?

  func cancel() {
    progressTimer?.invalidate()
    progressTimer = nil
    currentSession?.cancelExport()
    currentSession = nil
  }

  func export(
    inputURL: URL,
    cameraInputURL: URL? = nil,
    target: CGSize,
    padding: Double = 0,
    cornerRadius: Double = 0,
    backgroundColor: Int? = nil,
    backgroundImagePath: String? = nil,
    cursorSize: Double = 1.0,
    showCursor: Bool = true,
    zoomEnabled: Bool = false,
    zoomFactor: CGFloat = 1.5,
    followStrength: CGFloat = 0.15,
    fpsHint: Int32 = 60,
    outputURL: URL,
    format: String,
    codec: String,
    bitrate: String,
    fitMode: String? = nil,
    audioGainDb: Double = 0.0,
    audioVolumePercent: Double = 100.0,
    autoNormalizeOnExport: Bool = false,
    targetLoudnessDbfs: Double = -16.0,
    cameraParams: CameraCompositionParams? = nil,
    onProgress: ((Double) -> Void)? = nil,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    // Cancel any existing session
    cancel()

    let asset = AVAsset(url: inputURL)

    // Load cursor recording if needed (gracefully handle missing cursor file)
    var cursorRecording: CursorRecording?
    if showCursor {
      let cursorDataURL = AppPaths.cursorSidecarURL(for: inputURL)
      if let data = try? Data(contentsOf: cursorDataURL),
        let recording = try? JSONDecoder().decode(CursorRecording.self, from: data)
      {
        cursorRecording = recording
        NativeLogger.d(
          "Export", "Loaded cursor data",
          context: ["frames": recording.frames.count, "sprites": recording.sprites.count])
      } else {
        // Cursor file missing - this is OK, we just proceed without cursor overlay
        NativeLogger.i(
          "Export", "Cursor data missing or invalid, proceeding without cursor overlay",
          context: ["expectedPath": cursorDataURL.lastPathComponent])
      }
    }

    // Load manual segments
    let manualURL = AppPaths.zoomManualSidecarURL(for: inputURL)
    var manualSegments: [ZoomTimelineSegment] = []
    var overriddenAutoIds: Set<String> = []

    if let data = try? Data(contentsOf: manualURL),
      let manualData = try? JSONDecoder().decode(ZoomManualData.self, from: data)
    {
      let allManual = manualData.segments
      overriddenAutoIds = Set(allManual.compactMap { $0.baseId })

      manualSegments = allManual
        .filter { $0.endMs > $0.startMs }  // exclude tombstones
        .map { ZoomTimelineSegment(startMs: $0.startMs, endMs: $0.endMs) }

      NativeLogger.d(
        "Export", "Loaded manual zoom segments",
        context: ["count": manualSegments.count, "overrides": overriddenAutoIds.count])
    }

    // Load auto segments from cursorRecording if available
    var autoSegments: [ZoomTimelineSegment] = []
    if let recording = cursorRecording {
      let duration = asset.duration.seconds
      let rawAuto = ZoomTimelineBuilder.buildSegments(
        cursorRecording: recording,
        durationSeconds: duration
      )

      // Filter out overridden auto segments
      autoSegments = rawAuto.enumerated().compactMap { (index, seg) in
        let id = "auto_\(index)"
        if overriddenAutoIds.contains(id) {
          return nil
        }
        return ZoomTimelineSegment(startMs: seg.startMs, endMs: seg.endMs)
      }

      NativeLogger.d(
        "Export", "Processed auto zoom segments",
        context: ["raw": rawAuto.count, "effective": autoSegments.count])
    }

    let effectiveSegments = (autoSegments + manualSegments).merged()

    var params = CompositionParams(
      targetSize: target,
      padding: padding,
      cornerRadius: cornerRadius,
      backgroundColor: backgroundColor,
      backgroundImagePath: backgroundImagePath,
      cursorSize: cursorSize,
      showCursor: showCursor,
      zoomEnabled: zoomEnabled,
      zoomFactor: zoomFactor,
      followStrength: followStrength,
      fpsHint: fpsHint,
      fitMode: fitMode,
      audioGainDb: audioGainDb,
      audioVolumePercent: audioVolumePercent
    )
    params.zoomSegments = effectiveSegments

    let resolvedAudioMix = resolveAudioMixControls(
      asset: asset,
      userGainDb: audioGainDb,
      userVolumePercent: audioVolumePercent,
      autoNormalizeOnExport: autoNormalizeOnExport,
      targetLoudnessDbfs: targetLoudnessDbfs
    )

    let compatible = Set(AVAssetExportSession.exportPresets(compatibleWith: asset))

    func pickPreset(_ candidates: [String]) -> String {
      for p in candidates where compatible.contains(p) { return p }
      return AVAssetExportPresetHighestQuality
    }

    let useHevc = codec == "hevc"
    let preset: String

    NativeLogger.i(
      "Export", "Export resolved",
      context: [
        "input": inputURL.path,
        "output": outputURL.path,
        "target": "\(Int(target.width))x\(Int(target.height))",
        "fpsHint": fpsHint,
        "format": format,
        "codec": codec,
      ])

    if target.width >= 7680 || target.height >= 4320 {
      // 8K
      if #available(macOS 13.0, *) {
        preset =
          useHevc
          ? pickPreset([
            "AVAssetExportPresetHEVC7680x4320", AVAssetExportPresetHEVCHighestQuality,
            AVAssetExportPresetHighestQuality,
          ])
          : pickPreset([AVAssetExportPresetHighestQuality])
      } else {
        preset =
          useHevc
          ? pickPreset([AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality])
          : pickPreset([AVAssetExportPresetHighestQuality])
      }
    } else if target.width >= 3840 || target.height >= 2160 {
      // 4K
      preset =
        useHevc
        ? pickPreset([
          AVAssetExportPresetHEVC3840x2160,
          AVAssetExportPreset3840x2160,
          AVAssetExportPresetHEVCHighestQuality,
          AVAssetExportPresetHighestQuality,
        ])
        : pickPreset([
          AVAssetExportPreset3840x2160,
          AVAssetExportPresetHighestQuality,
        ])
    } else if target.width >= 1920 || target.height >= 1080 {
      // 1080p+
      preset =
        useHevc
        ? pickPreset([
          AVAssetExportPresetHEVC1920x1080,
          AVAssetExportPreset1920x1080,
          AVAssetExportPresetHEVCHighestQuality,
        ])
        : pickPreset([
          AVAssetExportPreset1920x1080,
          AVAssetExportPresetHighestQuality,
        ])
    } else {
      preset =
        useHevc
        ? pickPreset([AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality])
        : pickPreset([AVAssetExportPresetHighestQuality])
    }

    let cameraAsset = cameraInputURL.map(AVAsset.init(url:))

    guard
      let comp = builder.buildExport(
        asset: asset,
        cameraAsset: cameraAsset,
        params: params,
        cameraParams: cameraParams,
        cursorRecording: cursorRecording
      )
    else {
      completion(
        .failure(
          NSError(
            domain: "Letterbox", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to build composition"])))
      return
    }

    guard let export = AVAssetExportSession(asset: comp.asset, presetName: preset) else {
      completion(
        .failure(
          NSError(
            domain: "Letterbox", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Cannot create export session (preset=\(preset))"]
          )))
      return
    }

    export.videoComposition = comp.videoComposition

    export.audioMix = AudioMixEngine.makeAudioMix(
      asset: comp.asset,
      volumePercent: resolvedAudioMix.volumePercent,
      gainDb: resolvedAudioMix.gainDb
    )

    let requestedType = requestedFileType(for: format)

    if let requestedType, export.supportedFileTypes.contains(requestedType) {
      export.outputFileType = requestedType
    } else if let first = export.supportedFileTypes.first {
      export.outputFileType = first
    } else {
      completion(
        .failure(
          NSError(
            domain: "Letterbox",
            code: -10,
            userInfo: [NSLocalizedDescriptionKey: "No supported output file types"]
          )))
      return
    }

    // IMPORTANT: fix URL extension to match chosen outputFileType
    let chosenType = export.outputFileType ?? .mov
    let finalURL =
      outputURL
      .deletingPathExtension()
      .appendingPathExtension(ext(for: chosenType))

    if FileManager.default.fileExists(atPath: finalURL.path) {
      try? FileManager.default.removeItem(at: finalURL)
    }

    export.outputURL = finalURL

    export.shouldOptimizeForNetworkUse = true

    self.currentSession = export

    let exportContext: [String: Any] = [
      "input": inputURL.path,
      "output": outputURL.path,
      "target": "\(Int(target.width))x\(Int(target.height))",
      "renderSize":
        "\(Int(comp.videoComposition.renderSize.width))x\(Int(comp.videoComposition.renderSize.height))",
      "fpsHint": fpsHint,
      "format": format,
      "codec": codec,
      "bitrate": bitrate,
      "autoNormalizeOnExport": autoNormalizeOnExport,
      "targetLoudnessDbfs": targetLoudnessDbfs,
      "resolvedGainDb": resolvedAudioMix.gainDb,
      "resolvedVolumePercent": resolvedAudioMix.volumePercent,
      "sourcePeakDbfs": resolvedAudioMix.sourcePeakDbfs ?? NSNull(),
      "normalizationGainDb": resolvedAudioMix.normalizationGainDb ?? NSNull(),
      "supportedTypes": export.supportedFileTypes.map(\.rawValue),
      "finalURL": finalURL.path,
    ]
    NativeLogger.i("Export", "Export resolved", context: exportContext)

    // Polling timer for progress
    progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak export] _ in
      guard let export = export else { return }
      onProgress?(Double(export.progress))
    }

    export.exportAsynchronously { [weak self] in
      DispatchQueue.main.async {
        self?.progressTimer?.invalidate()
        self?.progressTimer = nil

        switch export.status {
        case .completed:
          onProgress?(1.0)
          // Debug exported file quality
          self?.logExportedFileInfo(url: finalURL)
          completion(.success(finalURL))

        case .cancelled:
          completion(
            .failure(
              NSError(
                domain: "Letterbox", code: -999,
                userInfo: [NSLocalizedDescriptionKey: "Export cancelled"])))
        case .failed:
          completion(
            .failure(
              export.error
                ?? NSError(
                  domain: "Letterbox", code: -3,
                  userInfo: [NSLocalizedDescriptionKey: "Export failed"])))
        default: break
        }
        self?.currentSession = nil
      }
    }
  }

  private struct ResolvedAudioMixControls {
    let gainDb: Double
    let volumePercent: Double
    let sourcePeakDbfs: Double?
    let normalizationGainDb: Double?
  }

  private func resolveAudioMixControls(
    asset: AVAsset,
    userGainDb: Double,
    userVolumePercent: Double,
    autoNormalizeOnExport: Bool,
    targetLoudnessDbfs: Double
  ) -> ResolvedAudioMixControls {
    let clampedGainDb = max(0.0, min(24.0, userGainDb))
    let clampedVolumePercent = max(0.0, min(100.0, userVolumePercent))

    guard autoNormalizeOnExport else {
      return ResolvedAudioMixControls(
        gainDb: clampedGainDb,
        volumePercent: clampedVolumePercent,
        sourcePeakDbfs: nil,
        normalizationGainDb: nil
      )
    }

    guard let sourcePeakLinear = estimateAudioPeakLinear(asset: asset), sourcePeakLinear > 0.000001 else {
      NativeLogger.w(
        "Export",
        "Auto-normalize skipped: no measurable audio peak"
      )
      return ResolvedAudioMixControls(
        gainDb: clampedGainDb,
        volumePercent: clampedVolumePercent,
        sourcePeakDbfs: nil,
        normalizationGainDb: nil
      )
    }

    let clampedTargetDbfs = max(-24.0, min(-6.0, targetLoudnessDbfs))
    let targetLinear = pow(10.0, clampedTargetDbfs / 20.0)
    let userLinear = (clampedVolumePercent / 100.0) * pow(10.0, clampedGainDb / 20.0)
    let normalizeLinear = targetLinear / sourcePeakLinear
    let normalizationGainDb = 20.0 * log10(max(normalizeLinear, 0.000000001))

    // Apply user controls after normalization intent.
    var resolvedLinear = userLinear * normalizeLinear
    let maxLinear = pow(10.0, 24.0 / 20.0)  // aligns with current +24dB max
    resolvedLinear = max(0.0, min(maxLinear, resolvedLinear))

    let resolvedGainDb: Double
    let resolvedVolumePercent: Double
    if resolvedLinear <= 1.0 {
      resolvedGainDb = 0.0
      resolvedVolumePercent = resolvedLinear * 100.0
    } else {
      resolvedGainDb = min(24.0, 20.0 * log10(resolvedLinear))
      resolvedVolumePercent = 100.0
    }

    return ResolvedAudioMixControls(
      gainDb: resolvedGainDb,
      volumePercent: resolvedVolumePercent,
      sourcePeakDbfs: AudioLevelEstimator.dbfs(for: sourcePeakLinear),
      normalizationGainDb: normalizationGainDb
    )
  }

  private func estimateAudioPeakLinear(asset: AVAsset) -> Double? {
    guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
      return nil
    }

    do {
      let reader = try AVAssetReader(asset: asset)
      let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
      let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
      output.alwaysCopiesSampleData = false
      guard reader.canAdd(output) else { return nil }
      reader.add(output)
      guard reader.startReading() else { return nil }

      var peak = 0.0
      while reader.status == .reading {
        guard let sample = output.copyNextSampleBuffer() else { break }
        if let estimate = AudioLevelEstimator.estimatePeak(sampleBuffer: sample) {
          peak = max(peak, estimate.linear)
        }
        CMSampleBufferInvalidate(sample)
      }

      if reader.status == .failed {
        NativeLogger.w(
          "Export",
          "Audio peak analysis failed",
          context: ["error": reader.error?.localizedDescription ?? "unknown"]
        )
      }

      return peak
    } catch {
      NativeLogger.w(
        "Export",
        "Audio peak analysis failed to start",
        context: ["error": error.localizedDescription]
      )
      return nil
    }
  }

  private func ext(for type: AVFileType) -> String {
    switch type {
    case .mp4: return "mp4"
    case .mov: return "mov"
    case .m4v: return "m4v"

    default:
      // Last-resort safe default
      return "mov"
    }
  }

  private func requestedFileType(for format: String) -> AVFileType? {
    switch format.lowercased() {
    case "mp4": return .mp4
    case "mov": return .mov
    case "m4v": return .m4v
    case "gif": return nil  // handled by a separate GIF export pipeline
    default: return .mov
    }
  }

  private func logExportedFileInfo(url: URL) {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else {
      NativeLogger.w("Export", "No video track", context: ["url": url.path])
      return
    }

    let t = track.preferredTransform
    let rect = CGRect(origin: .zero, size: track.naturalSize).applying(t)
    let w = abs(rect.width)
    let h = abs(rect.height)

    let bytes =
      (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
      .doubleValue ?? 0
    let seconds = max(asset.duration.seconds, 0.001)
    let bpsFromFile = (bytes * 8.0) / seconds

    NativeLogger.i(
      "Export", "Exported file info",
      context: [
        "url": url.path,
        "w": w, "h": h,
        "nominalFps": track.nominalFrameRate,
        "estimatedDataRate_bps": track.estimatedDataRate,
        "file_bytes": bytes,
        "duration_s": seconds,
        "bitrate_from_file_bps": bpsFromFile,
      ])
  }

}
