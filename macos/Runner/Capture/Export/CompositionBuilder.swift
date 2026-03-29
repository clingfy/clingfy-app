import AVFoundation
import AppKit
import AudioToolbox
import MediaToolbox
import QuartzCore

// Builds the final screen-plus-camera composition; camera-only pixel work must be pre-rendered.
extension NSImage {
  func cgImageForLayer() -> CGImage? {
    var rect = NSRect(origin: .zero, size: size)
    return cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }
}

struct ZoomTimelineSegment: Codable, Equatable {
  let startMs: Int
  let endMs: Int

  func contains(timeMs: Int) -> Bool {
    return timeMs >= startMs && timeMs < endMs
  }
}

extension Array where Element == ZoomTimelineSegment {
  func merged(gapMs: Int = 120) -> [ZoomTimelineSegment] {
    guard !isEmpty else { return [] }
    let sorted = self.sorted { $0.startMs < $1.startMs }
    var result: [ZoomTimelineSegment] = []
    var current = sorted[0]

    for i in 1..<sorted.count {
      let next = sorted[i]
      if next.startMs <= current.endMs + gapMs {
        current = ZoomTimelineSegment(
          startMs: current.startMs, endMs: Swift.max(current.endMs, next.endMs))
      } else {
        result.append(current)
        current = next
      }
    }
    result.append(current)
    return result
  }
}

struct CompositionParams: Equatable {
  let targetSize: CGSize
  let padding: Double
  let cornerRadius: Double
  let backgroundColor: Int?
  let backgroundImagePath: String?
  let cursorSize: Double
  let showCursor: Bool
  let zoomEnabled: Bool
  let zoomFactor: CGFloat
  let followStrength: CGFloat
  let fpsHint: Int32
  let fitMode: String?  // "fit" or "fill"
  let audioGainDb: Double
  let audioVolumePercent: Double
  var zoomSegments: [ZoomTimelineSegment]?
}

private enum AudioTapSampleType {
  case float32
  case float64
  case int16
  case int32
  case unknown
}

private final class AudioTapContext {
  let gainLinear: Float
  let gainDb: Double
  var sampleType: AudioTapSampleType = .unknown
  var didLogFirstProcess = false
  var didLogUnsupportedSampleType = false
  var didLogSignalProbe = false
  var processedAnyFrames = false
  var probeCallbacks = 0
  var probeMaxPrePeak = 0.0
  var probeMaxPostPeak = 0.0

  init(gainLinear: Float, gainDb: Double) {
    self.gainLinear = gainLinear
    self.gainDb = gainDb
  }

  var sampleTypeLabel: String {
    switch sampleType {
    case .float32: return "float32"
    case .float64: return "float64"
    case .int16: return "int16"
    case .int32: return "int32"
    case .unknown: return "unknown"
    }
  }
}

private func peakToDbfs(_ peak: Double) -> Double {
  let clamped = max(peak, 0.000000001)
  return 20.0 * log10(clamped)
}

private let audioTapProcessCallback: MTAudioProcessingTapProcessCallback = {
  tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in

  let status = MTAudioProcessingTapGetSourceAudio(
    tap,
    numberFrames,
    bufferListInOut,
    flagsOut,
    nil,
    numberFramesOut
  )
  guard status == noErr else { return }
  let storage = MTAudioProcessingTapGetStorage(tap)
  let context = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()
  let gainLinear = context.gainLinear
  if abs(gainLinear - 1.0) < 0.0001 { return }
  let shouldProbeSignal = !context.didLogSignalProbe
  var peakBefore = 0.0
  var peakAfter = 0.0

  let audioBufferList = UnsafeMutableAudioBufferListPointer(bufferListInOut)
  if !context.didLogFirstProcess {
    context.didLogFirstProcess = true
    NativeLogger.i(
      "AudioMixEngine",
      "Audio gain tap first process",
      context: [
        "gainDb": context.gainDb,
        "gainLinear": gainLinear,
        "sampleType": context.sampleTypeLabel,
        "numberFrames": numberFrames,
        "buffers": audioBufferList.count,
      ]
    )
  }

  switch context.sampleType {
  case .float32:
    context.processedAnyFrames = true
    for audioBuffer in audioBufferList {
      guard let data = audioBuffer.mData else { continue }
      let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
      let samples = data.assumingMemoryBound(to: Float.self)
      for i in 0..<sampleCount {
        let before = samples[i]
        if shouldProbeSignal {
          let beforeAbs = Double(abs(before))
          if beforeAbs > peakBefore { peakBefore = beforeAbs }
        }
        let after = before * gainLinear
        samples[i] = after
        if shouldProbeSignal {
          let afterAbs = Double(abs(after))
          if afterAbs > peakAfter { peakAfter = afterAbs }
        }
      }
    }

  case .float64:
    context.processedAnyFrames = true
    let gain = Double(gainLinear)
    for audioBuffer in audioBufferList {
      guard let data = audioBuffer.mData else { continue }
      let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
      let samples = data.assumingMemoryBound(to: Double.self)
      for i in 0..<sampleCount {
        let before = samples[i]
        if shouldProbeSignal {
          let beforeAbs = abs(before)
          if beforeAbs > peakBefore { peakBefore = beforeAbs }
        }
        let after = before * gain
        samples[i] = after
        if shouldProbeSignal {
          let afterAbs = abs(after)
          if afterAbs > peakAfter { peakAfter = afterAbs }
        }
      }
    }

  case .int16:
    context.processedAnyFrames = true
    let maxVal = Float(Int16.max)
    let minVal = Float(Int16.min)
    for audioBuffer in audioBufferList {
      guard let data = audioBuffer.mData else { continue }
      let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
      let samples = data.assumingMemoryBound(to: Int16.self)
      for i in 0..<sampleCount {
        let source = Float(samples[i])
        if shouldProbeSignal {
          let beforeAbs = Double(abs(source) / maxVal)
          if beforeAbs > peakBefore { peakBefore = beforeAbs }
        }
        let scaled = source * gainLinear
        let clipped = max(minVal, min(maxVal, scaled))
        samples[i] = Int16(clipped)
        if shouldProbeSignal {
          let afterAbs = Double(abs(clipped) / maxVal)
          if afterAbs > peakAfter { peakAfter = afterAbs }
        }
      }
    }

  case .int32:
    context.processedAnyFrames = true
    let maxVal = Double(Int32.max)
    let minVal = Double(Int32.min)
    for audioBuffer in audioBufferList {
      guard let data = audioBuffer.mData else { continue }
      let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
      let samples = data.assumingMemoryBound(to: Int32.self)
      for i in 0..<sampleCount {
        let source = Double(samples[i])
        if shouldProbeSignal {
          let beforeAbs = abs(source) / maxVal
          if beforeAbs > peakBefore { peakBefore = beforeAbs }
        }
        let scaled = source * Double(gainLinear)
        let clipped = max(minVal, min(maxVal, scaled))
        samples[i] = Int32(clipped)
        if shouldProbeSignal {
          let afterAbs = abs(clipped) / maxVal
          if afterAbs > peakAfter { peakAfter = afterAbs }
        }
      }
    }

  case .unknown:
    if !context.didLogUnsupportedSampleType {
      context.didLogUnsupportedSampleType = true
      NativeLogger.w(
        "AudioMixEngine",
        "Audio gain tap unsupported sample type; gain not applied",
        context: [
          "gainDb": context.gainDb,
          "gainLinear": gainLinear,
        ]
      )
    }
    break
  }

  if shouldProbeSignal && context.sampleType != .unknown {
    context.probeCallbacks += 1
    context.probeMaxPrePeak = max(context.probeMaxPrePeak, peakBefore)
    context.probeMaxPostPeak = max(context.probeMaxPostPeak, peakAfter)

    let reachedSignal = context.probeMaxPrePeak > 0.0001 || context.probeMaxPostPeak > 0.0001
    let reachedSampleWindow = context.probeCallbacks >= 24
    if reachedSignal || reachedSampleWindow {
      context.didLogSignalProbe = true
      NativeLogger.i(
        "AudioMixEngine",
        "Audio gain tap probe",
        context: [
          "gainDb": context.gainDb,
          "gainLinear": gainLinear,
          "sampleType": context.sampleTypeLabel,
          "numberFrames": numberFrames,
          "callbacksSampled": context.probeCallbacks,
          "prePeak": context.probeMaxPrePeak,
          "postPeak": context.probeMaxPostPeak,
          "prePeakDbfs": peakToDbfs(context.probeMaxPrePeak),
          "postPeakDbfs": peakToDbfs(context.probeMaxPostPeak),
        ]
      )
    }
  }
}

enum AudioMixEngine {
  static func makeAudioMix(
    asset: AVAsset,
    volumePercent: Double,
    gainDb: Double
  ) -> AVAudioMix? {
    return makeAudioMix(
      audioTracks: asset.tracks(withMediaType: .audio),
      volumePercent: volumePercent,
      gainDb: gainDb
    )
  }

  static func makeAudioMix(
    audioTracks: [AVAssetTrack],
    volumePercent: Double,
    gainDb: Double
  ) -> AVAudioMix? {
    guard !audioTracks.isEmpty else { return nil }

    let linearVolume = max(0.0, min(1.0, volumePercent / 100.0))
    let clampedGainDb = max(0.0, min(24.0, gainDb))
    let gainLinear = Float(pow(10.0, clampedGainDb / 20.0))

    let needsVolumeMix = abs(linearVolume - 1.0) > 0.0001
    let needsGainTap = gainLinear > 1.0001
    let combinedLinear = linearVolume * Double(gainLinear)
    NativeLogger.d(
      "AudioMixEngine",
      "AudioMixEngine data",
      context: [
        "audioTracks": audioTracks.count,
        "linearVolume": linearVolume,
        "gainDb": clampedGainDb,
        "gainLinear": gainLinear,
        "combinedLinear": combinedLinear,
        "needsVolumeMix": needsVolumeMix,
        "needsGainTap": needsGainTap,
      ]
    )

    if !needsVolumeMix && !needsGainTap {
      return nil
    }

    let mix = AVMutableAudioMix()
    var inputParams: [AVMutableAudioMixInputParameters] = []

    for track in audioTracks {
      let params = AVMutableAudioMixInputParameters(track: track)
      params.setVolume(Float(linearVolume), at: .zero)

      if needsGainTap {
        if let tap = makeGainTap(gainLinear: gainLinear, gainDb: clampedGainDb) {
          params.audioTapProcessor = tap
        } else {
          NativeLogger.w(
            "AudioMixEngine",
            "Failed to create gain tap; using volume-only mix",
            context: [
              "gainDb": clampedGainDb,
              "gainLinear": gainLinear,
            ]
          )
        }
      }
      inputParams.append(params)
    }

    mix.inputParameters = inputParams
    return mix
  }

  private static func makeGainTap(gainLinear: Float, gainDb: Double) -> MTAudioProcessingTap? {
    let contextPointer = UnsafeMutableRawPointer(
      Unmanaged.passRetained(AudioTapContext(gainLinear: gainLinear, gainDb: gainDb)).toOpaque()
    )

    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: contextPointer,
      init: { _, clientInfo, tapStorageOut in
        tapStorageOut.pointee = clientInfo
      },
      finalize: { tap in
        let storage = MTAudioProcessingTapGetStorage(tap)
        let context = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()
        if !context.didLogSignalProbe && context.sampleType != .unknown
          && context.probeCallbacks > 0
        {
          NativeLogger.i(
            "AudioMixEngine",
            "Audio gain tap probe (finalize)",
            context: [
              "gainDb": context.gainDb,
              "gainLinear": context.gainLinear,
              "sampleType": context.sampleTypeLabel,
              "callbacksSampled": context.probeCallbacks,
              "prePeak": context.probeMaxPrePeak,
              "postPeak": context.probeMaxPostPeak,
              "prePeakDbfs": peakToDbfs(context.probeMaxPrePeak),
              "postPeakDbfs": peakToDbfs(context.probeMaxPostPeak),
            ]
          )
        }
        if context.gainLinear > 1.0001 && !context.processedAnyFrames {
          NativeLogger.w(
            "AudioMixEngine",
            "Audio gain tap finalized without processing frames",
            context: [
              "gainDb": context.gainDb,
              "gainLinear": context.gainLinear,
              "sampleType": context.sampleTypeLabel,
            ]
          )
        }
        Unmanaged<AudioTapContext>.fromOpaque(storage).release()
      },
      prepare: { tap, _, processingFormat in
        let storage = MTAudioProcessingTapGetStorage(tap)
        let context = Unmanaged<AudioTapContext>.fromOpaque(storage).takeUnretainedValue()

        let format = processingFormat.pointee
        guard format.mFormatID == kAudioFormatLinearPCM else {
          context.sampleType = .unknown
          return
        }

        let flags = format.mFormatFlags
        let bitsPerChannel = format.mBitsPerChannel
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (flags & kAudioFormatFlagIsSignedInteger) != 0

        if isFloat && bitsPerChannel == 32 {
          context.sampleType = .float32
        } else if isFloat && bitsPerChannel == 64 {
          context.sampleType = .float64
        } else if isSignedInt && bitsPerChannel == 16 {
          context.sampleType = .int16
        } else if isSignedInt && bitsPerChannel == 32 {
          context.sampleType = .int32
        } else {
          context.sampleType = .unknown
        }

        NativeLogger.d(
          "AudioMixEngine",
          "Audio gain tap prepared",
          context: [
            "gainDb": context.gainDb,
            "gainLinear": context.gainLinear,
            "sampleType": context.sampleTypeLabel,
            "mFormatID": format.mFormatID,
            "mFormatFlags": format.mFormatFlags,
            "bitsPerChannel": bitsPerChannel,
            "channelsPerFrame": format.mChannelsPerFrame,
            "sampleRate": format.mSampleRate,
          ]
        )
      },
      unprepare: { _ in },
      process: audioTapProcessCallback
    )


    let status: OSStatus

    #if compiler(>=6.2)
    // ---------------------------------------------------------
    // SWIFT 6.2+ API: Used by Local Machine
    // ---------------------------------------------------------
    var tap: MTAudioProcessingTap?
    status = MTAudioProcessingTapCreate(
      kCFAllocatorDefault,
      &callbacks,
      kMTAudioProcessingTapCreationFlag_PostEffects,
      &tap
    )

    guard status == noErr, let finalTap = tap else {
      Unmanaged<AudioTapContext>.fromOpaque(contextPointer).release()
      return nil
    }
    return finalTap

    #else
    // ---------------------------------------------------------
    // SWIFT 6.1 OR OLDER: Used by Azure Pipeline
    // ---------------------------------------------------------
    var tapOut: Unmanaged<MTAudioProcessingTap>?
    status = MTAudioProcessingTapCreate(
      kCFAllocatorDefault,
      &callbacks,
      kMTAudioProcessingTapCreationFlag_PostEffects,
      &tapOut
    )

    guard status == noErr, let finalTap = tapOut?.takeRetainedValue() else {
      Unmanaged<AudioTapContext>.fromOpaque(contextPointer).release()
      return nil
    }
    return finalTap
    #endif
  }
}

final class CompositionBuilder {
  struct PreviewCompositionResult {
    let composition: AVVideoComposition
    let contentFrame: CGRect
    let videoToTargetScale: CGFloat
    let renderSize: CGSize
  }

  struct ExportCompositionResult {
    let asset: AVAsset
    let videoComposition: AVVideoComposition
  }

  // For Export
  func buildExport(
    asset: AVAsset,
    cameraAsset: AVAsset?,
    params: CompositionParams,
    cameraParams: CameraCompositionParams?,
    cursorRecording: CursorRecording?,
    cameraAssetIsPreStyled: Bool = false,
    cameraPlacementSourceRect: CGRect? = nil
  ) -> ExportCompositionResult? {
    if let cameraAsset,
      let cameraParams,
      cameraParams.visible,
      cameraParams.layoutPreset != .hidden
    {
      return buildTwoSourceExport(
        screenAsset: asset,
        cameraAsset: cameraAsset,
        params: params,
        cameraParams: cameraParams,
        cursorRecording: cursorRecording,
        cameraAssetIsPreStyled: cameraAssetIsPreStyled,
        cameraPlacementSourceRect: cameraPlacementSourceRect
      )
    }

    guard
      let composition = build(
        asset: asset,
        params: params,
        cursorRecording: cursorRecording,
        previewProfile: nil,
        forExport: true
      )?.composition
    else {
      return nil
    }

    return ExportCompositionResult(asset: asset, videoComposition: composition)
  }

  // For Preview
  func buildPreview(
    asset: AVAsset,
    scene: PreviewScene,
    profile: PreviewProfile
  ) -> PreviewCompositionResult? {
    let params = scene.screenParams
    NativeLogger.d(
      "Preview",
      "Building preview scene",
      context: [
        "screenPath": scene.mediaSources.screenPath,
        "cameraPath": scene.mediaSources.cameraPath ?? "nil",
        "hasCameraParams": scene.cameraParams != nil,
      ])
    guard
      let result = build(
        asset: asset,
        params: params,
        cursorRecording: nil,
        previewProfile: profile,
        forExport: false
      )
    else { return nil }

    return PreviewCompositionResult(
      composition: result.composition,
      contentFrame: result.contentRect,
      videoToTargetScale: result.videoToTargetScale,
      renderSize: result.renderSize
    )
  }

  private struct BuildResult {
    let composition: AVVideoComposition
    let contentRect: CGRect
    let videoToTargetScale: CGFloat
    let renderSize: CGSize
  }

  private struct ExportZoomSample {
    let time: Double
    let zoom: CGFloat
    let centerX: CGFloat
    let centerY: CGFloat
    let isActive: Bool
    let localTime: Double?
  }

  private struct CameraPresentationSample {
    let time: Double
    let zoom: CGFloat
    let zoomState: CameraAnimationZoomState
  }

  private enum ExportZoomApplicationMode {
    case compositeVideoLayer
    case screenOverlayOnly
  }

  private func orientedSize(_ track: AVAssetTrack) -> CGSize {
    let rect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    return .init(width: abs(rect.width), height: abs(rect.height))
  }

  private func build(
    asset: AVAsset,
    params: CompositionParams,
    cursorRecording: CursorRecording?,
    previewProfile: PreviewProfile?,
    forExport: Bool
  ) -> BuildResult? {
    guard let vTrack = asset.tracks(withMediaType: .video).first else { return nil }
    guard forExport || previewProfile != nil else { return nil }
    let src = orientedSize(vTrack)
    let target = params.targetSize
    let padding = params.padding

    let availableSize = CGSize(
      width: max(1, target.width - 2 * padding), height: max(1, target.height - 2 * padding))
    let fit = params.fitMode ?? "fit"
    let s: CGFloat = {
      let sw = availableSize.width / max(src.width, 1)
      let sh = availableSize.height / max(src.height, 1)
      return fit == "fill" ? max(sw, sh) : min(sw, sh)
    }()

    let contentWidth = src.width * s
    let contentHeight = src.height * s
    let tx = (target.width - contentWidth) / 2
    let ty = (target.height - contentHeight) / 2
    let contentRect = CGRect(x: tx, y: ty, width: contentWidth, height: contentHeight)
    let exportZoomSamples = forExport
      ? buildExportZoomSamplesIfNeeded(
        recording: cursorRecording,
        params: params,
        target: target,
        contentRect: contentRect,
        contentWidth: contentWidth,
        contentHeight: contentHeight,
        videoDuration: asset.duration.seconds
      )
      : []

    let comp = AVMutableVideoComposition()
    let renderSize: CGSize
    if forExport {
      renderSize = target
    } else if let profile = previewProfile {
      renderSize = scaledRenderSize(for: contentRect.size, scale: profile.renderScale)
    } else {
      renderSize = contentRect.size
    }
    comp.renderSize = renderSize

    let previewFps = previewProfile?.fps ?? PreviewProfile.defaultFps
    let timescale = max(1, forExport ? params.fpsHint : previewFps)
    comp.frameDuration = CMTime(value: 1, timescale: timescale)

    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)

    if forExport {
      layerInstruction.setTransform(
        fittedTransform(
          for: vTrack,
          sourceSize: src,
          destinationRect: contentRect,
          fitMode: fit,
          mirror: false
        ),
        at: .zero
      )
    } else {
      let renderScale = previewProfile?.renderScale ?? 1.0
      let transform = vTrack.preferredTransform
        .concatenating(CGAffineTransform(scaleX: s * renderScale, y: s * renderScale))
      layerInstruction.setTransform(transform, at: .zero)
    }
    instruction.layerInstructions = [layerInstruction]
    comp.instructions = [instruction]

    if forExport {
      configureExportAnimationTool(
        composition: comp,
        target: target,
        params: params,
        cursorRecording: cursorRecording,
        asset: asset,
        contentRect: contentRect,
        contentWidth: contentWidth,
        contentHeight: contentHeight,
        tx: tx,
        ty: ty,
        videoToTargetScale: s,
        zoomSamples: exportZoomSamples,
        zoomApplicationMode: .compositeVideoLayer,
        includeRoundedMask: true
      )
    }

    return BuildResult(
      composition: comp,
      contentRect: contentRect,
      videoToTargetScale: s,
      renderSize: renderSize
    )
  }

  private func buildTwoSourceExport(
    screenAsset: AVAsset,
    cameraAsset: AVAsset,
    params: CompositionParams,
    cameraParams: CameraCompositionParams,
    cursorRecording: CursorRecording?,
    cameraAssetIsPreStyled: Bool,
    cameraPlacementSourceRect: CGRect?
  ) -> ExportCompositionResult? {
    guard let screenTrack = screenAsset.tracks(withMediaType: .video).first else { return nil }

    let target = params.targetSize
    let padding = params.padding
    let screenSourceSize = orientedSize(screenTrack)

    let availableSize = CGSize(
      width: max(1, target.width - 2 * padding),
      height: max(1, target.height - 2 * padding)
    )
    let screenFitMode = params.fitMode ?? "fit"
    let screenScale: CGFloat = {
      let sw = availableSize.width / max(screenSourceSize.width, 1)
      let sh = availableSize.height / max(screenSourceSize.height, 1)
      return screenFitMode == "fill" ? max(sw, sh) : min(sw, sh)
    }()

    let contentWidth = screenSourceSize.width * screenScale
    let contentHeight = screenSourceSize.height * screenScale
    let tx = (target.width - contentWidth) / 2
    let ty = (target.height - contentHeight) / 2
    let screenContentRect = CGRect(x: tx, y: ty, width: contentWidth, height: contentHeight)
    let exportZoomSamples = buildExportZoomSamplesIfNeeded(
      recording: cursorRecording,
      params: params,
      target: target,
      contentRect: screenContentRect,
      contentWidth: contentWidth,
      contentHeight: contentHeight,
      videoDuration: screenAsset.duration.seconds
    )

    let composition = AVMutableComposition()

    do {
      guard
        let composedScreenTrack = composition.addMutableTrack(
          withMediaType: .video,
          preferredTrackID: kCMPersistentTrackID_Invalid
        )
      else {
        return nil
      }

      try composedScreenTrack.insertTimeRange(
        CMTimeRange(start: .zero, duration: screenAsset.duration),
        of: screenTrack,
        at: .zero
      )

      if let screenAudioTrack = screenAsset.tracks(withMediaType: .audio).first,
        let composedAudioTrack = composition.addMutableTrack(
          withMediaType: .audio,
          preferredTrackID: kCMPersistentTrackID_Invalid
        )
      {
        try composedAudioTrack.insertTimeRange(
          CMTimeRange(start: .zero, duration: screenAsset.duration),
          of: screenAudioTrack,
          at: .zero
        )
      }

      var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []

      let screenLayerInstruction = AVMutableVideoCompositionLayerInstruction(
        assetTrack: composedScreenTrack
      )
      let baseScreenTransform = fittedTransform(
        for: screenTrack,
        sourceSize: screenSourceSize,
        destinationRect: screenContentRect,
        fitMode: screenFitMode,
        mirror: false
      )
      applyZoomTransformRamps(
        to: screenLayerInstruction,
        baseTransform: baseScreenTransform,
        zoomSamples: exportZoomSamples,
        focusX: screenContentRect.midX,
        focusY: screenContentRect.midY,
        effectiveDuration: screenAsset.duration.seconds
      )
      layerInstructions.append(screenLayerInstruction)

      let cameraResolution = CameraLayoutResolver.effectiveFrame(
        canvasSize: target,
        params: cameraParams
      )

      if cameraResolution.shouldRender,
        let cameraTrack = cameraAsset.tracks(withMediaType: .video).first,
        let composedCameraTrack = composition.addMutableTrack(
          withMediaType: .video,
          preferredTrackID: kCMPersistentTrackID_Invalid
        )
      {
        let cameraDuration = min(cameraAsset.duration.seconds, screenAsset.duration.seconds)
        let insertionDuration = CMTime(seconds: max(0.0, cameraDuration), preferredTimescale: 600)
        if insertionDuration.seconds > 0 {
          try composedCameraTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: insertionDuration),
            of: cameraTrack,
            at: .zero
          )

          let cameraLayerInstruction = AVMutableVideoCompositionLayerInstruction(
            assetTrack: composedCameraTrack
          )
          let cameraFitMode: String =
            cameraAssetIsPreStyled ? "fit" : (cameraParams.contentMode == .fit ? "fit" : "fill")
          let cameraSourceSize = orientedSize(cameraTrack)
          let effectiveDuration = min(insertionDuration.seconds, screenAsset.duration.seconds)
          let presentationSamples = buildCameraPresentationSamples(
            params: params,
            cameraParams: cameraParams,
            zoomSamples: exportZoomSamples,
            effectiveDuration: effectiveDuration
          )
          let cameraPresentation = presentationSamples.isEmpty
            ? [
              CameraPresentationSample(
                time: 0.0,
                zoom: 1.0,
                zoomState: .inactive
              )
            ]
            : presentationSamples
          let resolvedCameraPresentation = cameraPresentation.map { sample in
            CameraAnimationTimelineBuilder.resolvePresentation(
              canvasSize: target,
              baseResolution: cameraResolution,
              cameraParams: cameraParams,
              screenZoom: sample.zoom,
              time: sample.time,
              totalDuration: effectiveDuration,
              zoomState: sample.zoomState
            )
          }
          let cameraTransforms = resolvedCameraPresentation.map { animatedCamera in
            fittedTransform(
              for: cameraTrack,
              sourceSize: cameraSourceSize,
              sourceRect: cameraAssetIsPreStyled ? cameraPlacementSourceRect : nil,
              destinationRect: animatedCamera.frame,
              fitMode: cameraFitMode,
              mirror: cameraAssetIsPreStyled ? false : cameraParams.mirror
            )
          }
          let cameraOpacities = resolvedCameraPresentation.map { animatedCamera in
            Float(max(0.0, min(1.0, animatedCamera.opacity)))
          }

          if let firstTransform = cameraTransforms.first {
            cameraLayerInstruction.setTransform(firstTransform, at: .zero)
          }
          if let firstOpacity = cameraOpacities.first {
            cameraLayerInstruction.setOpacity(firstOpacity, at: .zero)
          }

          if cameraTransforms.count >= 2,
            let firstTransform = cameraTransforms.first,
            cameraTransforms.dropFirst().contains(where: {
              !transformsApproximatelyEqual($0, firstTransform)
            })
          {
            for idx in 0..<(cameraPresentation.count - 1) {
              let startSeconds = cameraPresentation[idx].time
              let endSeconds = min(cameraPresentation[idx + 1].time, effectiveDuration)
              guard endSeconds > startSeconds else { continue }

              let startTime = CMTime(seconds: startSeconds, preferredTimescale: 600)
              let endTime = CMTime(seconds: endSeconds, preferredTimescale: 600)
              let timeRange = CMTimeRange(start: startTime, end: endTime)
              cameraLayerInstruction.setTransformRamp(
                fromStart: cameraTransforms[idx],
                toEnd: cameraTransforms[idx + 1],
                timeRange: timeRange
              )
            }
          }

          if cameraOpacities.count >= 2,
            let firstOpacity = cameraOpacities.first,
            cameraOpacities.dropFirst().contains(where: { abs($0 - firstOpacity) > 0.0001 })
          {
            for idx in 0..<(cameraPresentation.count - 1) {
              let startSeconds = cameraPresentation[idx].time
              let endSeconds = min(cameraPresentation[idx + 1].time, effectiveDuration)
              guard endSeconds > startSeconds else { continue }

              let startTime = CMTime(seconds: startSeconds, preferredTimescale: 600)
              let endTime = CMTime(seconds: endSeconds, preferredTimescale: 600)
              let timeRange = CMTimeRange(start: startTime, end: endTime)
              cameraLayerInstruction.setOpacityRamp(
                fromStartOpacity: cameraOpacities[idx],
                toEndOpacity: cameraOpacities[idx + 1],
                timeRange: timeRange
              )
            }
          }

          if cameraResolution.zOrder == .behindScreen {
            layerInstructions = [screenLayerInstruction, cameraLayerInstruction]
          } else {
            layerInstructions = [cameraLayerInstruction, screenLayerInstruction]
          }
        }
      }

      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = CMTimeRange(start: .zero, duration: screenAsset.duration)
      instruction.layerInstructions = layerInstructions

      let videoComposition = AVMutableVideoComposition()
      videoComposition.renderSize = target
      let timescale = max(1, params.fpsHint)
      videoComposition.frameDuration = CMTime(value: 1, timescale: timescale)
      videoComposition.instructions = [instruction]

      configureExportAnimationTool(
        composition: videoComposition,
        target: target,
        params: params,
        cursorRecording: cursorRecording,
        asset: screenAsset,
        contentRect: screenContentRect,
        contentWidth: contentWidth,
        contentHeight: contentHeight,
        tx: tx,
        ty: ty,
        videoToTargetScale: screenScale,
        zoomSamples: exportZoomSamples,
        zoomApplicationMode: .screenOverlayOnly,
        includeRoundedMask: false
      )

      return ExportCompositionResult(asset: composition, videoComposition: videoComposition)
    } catch {
      NativeLogger.e(
        "Export",
        "Failed to build two-source export composition",
        context: ["error": error.localizedDescription]
      )
      return nil
    }
  }

  private func fittedTransform(
    for track: AVAssetTrack,
    sourceSize: CGSize,
    sourceRect: CGRect? = nil,
    destinationRect: CGRect,
    fitMode: String,
    mirror: Bool
  ) -> CGAffineTransform {
    let orientedRect = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
    let normalizedPreferredTransform = track.preferredTransform.concatenating(
      CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY)
    )
    let fullNormalizedSourceSize = CGSize(
      width: max(abs(orientedRect.width), sourceSize.width),
      height: max(abs(orientedRect.height), sourceSize.height)
    )
    let effectiveSourceRect = (sourceRect?.standardized).flatMap { rect in
      guard rect.width > 0.0, rect.height > 0.0 else { return nil }
      return rect
    } ?? CGRect(origin: .zero, size: fullNormalizedSourceSize)
    let normalizedSourceSize = effectiveSourceRect.size
    let scaleX = destinationRect.width / max(normalizedSourceSize.width, 1.0)
    let scaleY = destinationRect.height / max(normalizedSourceSize.height, 1.0)
    let scale = fitMode == "fill" ? max(scaleX, scaleY) : min(scaleX, scaleY)
    let renderedWidth = normalizedSourceSize.width * scale
    let renderedHeight = normalizedSourceSize.height * scale
    let offsetX = destinationRect.minX + ((destinationRect.width - renderedWidth) / 2.0)
    let offsetY = destinationRect.minY + ((destinationRect.height - renderedHeight) / 2.0)

    var transform = normalizedPreferredTransform
    if sourceRect != nil {
      transform = transform.concatenating(
        CGAffineTransform(
          translationX: -effectiveSourceRect.minX,
          y: -effectiveSourceRect.minY
        )
      )
    }
    if mirror {
      transform = transform
        .concatenating(CGAffineTransform(translationX: normalizedSourceSize.width, y: 0))
        .concatenating(CGAffineTransform(scaleX: -1.0, y: 1.0))
    }
    transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
    transform = transform.concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
    return transform
  }

  func _testFittedRect(
    for track: AVAssetTrack,
    sourceSize: CGSize,
    sourceRect: CGRect? = nil,
    destinationRect: CGRect,
    fitMode: String,
    mirror: Bool
  ) -> CGRect {
    ((sourceRect?.standardized).flatMap { rect in
      guard rect.width > 0.0, rect.height > 0.0 else { return nil }
      return rect
    } ?? CGRect(origin: .zero, size: track.naturalSize))
      .applying(
        fittedTransform(
          for: track,
          sourceSize: sourceSize,
          sourceRect: sourceRect,
          destinationRect: destinationRect,
          fitMode: fitMode,
          mirror: mirror
        )
      )
      .standardized
  }

  private func buildExportZoomSamplesIfNeeded(
    recording: CursorRecording?,
    params: CompositionParams,
    target: CGSize,
    contentRect: CGRect,
    contentWidth: Double,
    contentHeight: Double,
    videoDuration: Double
  ) -> [ExportZoomSample] {
    guard let recording, !recording.frames.isEmpty else {
      return []
    }

    return buildExportZoomSamples(
      recording: recording,
      params: params,
      target: target,
      contentRect: contentRect,
      contentWidth: contentWidth,
      contentHeight: contentHeight,
      videoDuration: videoDuration
    )
  }

  private func exportZoomTransform(
    focusX: CGFloat,
    focusY: CGFloat,
    sample: ExportZoomSample
  ) -> CGAffineTransform {
    CGAffineTransform.identity
      .translatedBy(x: focusX, y: focusY)
      .scaledBy(x: sample.zoom, y: sample.zoom)
      .translatedBy(x: -sample.centerX, y: -sample.centerY)
  }

  private func applyZoomTransformRamps(
    to layerInstruction: AVMutableVideoCompositionLayerInstruction,
    baseTransform: CGAffineTransform,
    zoomSamples: [ExportZoomSample],
    focusX: CGFloat,
    focusY: CGFloat,
    effectiveDuration: Double
  ) {
    guard !zoomSamples.isEmpty else {
      layerInstruction.setTransform(baseTransform, at: .zero)
      return
    }

    let transforms = zoomSamples.map { sample in
      baseTransform.concatenating(
        exportZoomTransform(
          focusX: focusX,
          focusY: focusY,
          sample: sample
        )
      )
    }

    if let firstTransform = transforms.first {
      layerInstruction.setTransform(firstTransform, at: .zero)
    }

    guard
      transforms.count >= 2,
      let firstTransform = transforms.first,
      transforms.dropFirst().contains(where: { !transformsApproximatelyEqual($0, firstTransform) })
    else {
      return
    }

    for idx in 0..<(zoomSamples.count - 1) {
      let startSeconds = zoomSamples[idx].time
      let endSeconds = min(zoomSamples[idx + 1].time, effectiveDuration)
      guard endSeconds > startSeconds else { continue }

      let startTime = CMTime(seconds: startSeconds, preferredTimescale: 600)
      let endTime = CMTime(seconds: endSeconds, preferredTimescale: 600)
      let timeRange = CMTimeRange(start: startTime, end: endTime)
      layerInstruction.setTransformRamp(
        fromStart: transforms[idx],
        toEnd: transforms[idx + 1],
        timeRange: timeRange
      )
    }
  }

  private func configureExportAnimationTool(
    composition: AVMutableVideoComposition,
    target: CGSize,
    params: CompositionParams,
    cursorRecording: CursorRecording?,
    asset: AVAsset,
    contentRect: CGRect,
    contentWidth: Double,
    contentHeight: Double,
    tx: Double,
    ty: Double,
    videoToTargetScale: CGFloat,
    zoomSamples: [ExportZoomSample],
    zoomApplicationMode: ExportZoomApplicationMode,
    includeRoundedMask: Bool
  ) {
    guard
      params.cornerRadius > 0
        || params.backgroundColor != nil
        || params.backgroundImagePath != nil
        || params.showCursor
        || (zoomApplicationMode == .compositeVideoLayer && !zoomSamples.isEmpty)
    else {
      return
    }

    let parentLayer = CALayer()
    parentLayer.frame = CGRect(origin: .zero, size: target)

    let bgLayer = CALayer()
    bgLayer.frame = CGRect(origin: .zero, size: target)

    if let bgPath = params.backgroundImagePath, let img = NSImage(contentsOfFile: bgPath) {
      bgLayer.contents = img.cgImageForLayer()
      bgLayer.contentsGravity = .resizeAspectFill
    } else if let color = params.backgroundColor {
      let r = CGFloat((color >> 16) & 0xFF) / 255.0
      let g = CGFloat((color >> 8) & 0xFF) / 255.0
      let b = CGFloat(color & 0xFF) / 255.0
      let a = (color > 0xFFFFFF) ? CGFloat((color >> 24) & 0xFF) / 255.0 : 1.0
      bgLayer.backgroundColor = CGColor(red: r, green: g, blue: b, alpha: a)
    } else {
      bgLayer.backgroundColor = CGColor.black
    }
    parentLayer.addSublayer(bgLayer)

    let videoLayer = CALayer()
    videoLayer.frame = CGRect(origin: .zero, size: target)
    videoLayer.anchorPoint = .zero
    videoLayer.position = .zero
    parentLayer.addSublayer(videoLayer)

    if includeRoundedMask, params.cornerRadius > 0 {
      let maskLayer = CAShapeLayer()
      let path = CGPath(
        roundedRect: contentRect,
        cornerWidth: CGFloat(params.cornerRadius),
        cornerHeight: CGFloat(params.cornerRadius),
        transform: nil
      )
      maskLayer.path = path
      videoLayer.mask = maskLayer
    }

    let screenOverlayLayer: CALayer? = {
      guard zoomApplicationMode == .screenOverlayOnly, params.showCursor else {
        return nil
      }
      let overlayLayer = CALayer()
      overlayLayer.frame = CGRect(origin: .zero, size: target)
      overlayLayer.anchorPoint = .zero
      overlayLayer.position = .zero
      overlayLayer.masksToBounds = false
      parentLayer.addSublayer(overlayLayer)
      return overlayLayer
    }()

    if params.showCursor, let recording = cursorRecording, !recording.frames.isEmpty {
      addCursorLayer(
        to: screenOverlayLayer ?? videoLayer,
        recording: recording,
        params: params,
        target: target,
        contentRect: contentRect,
        contentWidth: contentWidth,
        contentHeight: contentHeight,
        tx: tx,
        ty: ty,
        asset: asset,
        videoToTargetScale: videoToTargetScale
      )
    }

    if !zoomSamples.isEmpty {
      let zoomTargetLayer: CALayer?
      switch zoomApplicationMode {
      case .compositeVideoLayer:
        zoomTargetLayer = videoLayer
      case .screenOverlayOnly:
        zoomTargetLayer = screenOverlayLayer
      }
      if let zoomTargetLayer {
        applyZoomAnimation(
          to: zoomTargetLayer,
          zoomSamples: zoomSamples,
          focusX: contentRect.midX,
          focusY: contentRect.midY,
          videoDuration: asset.duration.seconds
        )
      }
    }

    composition.animationTool = AVVideoCompositionCoreAnimationTool(
      postProcessingAsVideoLayer: videoLayer,
      in: parentLayer
    )
  }

  private func scaledRenderSize(for size: CGSize, scale: CGFloat) -> CGSize {
    CGSize(
      width: max(1, (size.width * scale).rounded()),
      height: max(1, (size.height * scale).rounded())
    )
  }

  // MARK: - Export Logic Fix
  func inBounds(_ f: CursorFrame) -> Bool {
    f.spriteID >= 0 && (0.0...1.0).contains(f.x) && (0.0...1.0).contains(f.y)
  }

  private func buildExportZoomSamples(
    recording: CursorRecording,
    params: CompositionParams,
    target: CGSize,
    contentRect: CGRect,
    contentWidth: Double,
    contentHeight: Double,
    videoDuration: Double
  ) -> [ExportZoomSample] {
    let frames = recording.frames
    guard params.zoomEnabled, !frames.isEmpty, videoDuration > 0 else { return [] }

    let mapX: (Double) -> CGFloat = { contentRect.minX + CGFloat($0) * contentWidth }
    let mapYTopDown: (Double) -> CGFloat = { contentRect.minY + CGFloat($0) * contentHeight }
    let focusX = contentRect.midX
    let focusY = contentRect.midY

    let fps = params.fpsHint > 0 ? Double(params.fpsHint) : 60.0
    let step = 1.0 / fps
    let totalExportFrames = Int(videoDuration * fps)

    var samples: [ExportZoomSample] = []
    samples.reserveCapacity(totalExportFrames + 1)

    var smoothZ: CGFloat = 1.0
    var smoothCx: CGFloat = focusX
    var smoothCy: CGFloat = focusY
    var didLogZoomSmootherProfile = false
    var frameIndex = 0
    var stableZoomStartTime: Double?

    let defaultSpriteID: Int =
      frames.first(where: inBounds)?.spriteID
      ?? frames.first(where: { $0.spriteID >= 0 })?.spriteID
      ?? 0
    let zoomHysteresis = ZoomHysteresis()

    for i in 0...totalExportFrames {
      let t = Double(i) * step

      while frameIndex < frames.count - 1 && frames[frameIndex + 1].t <= t {
        frameIndex += 1
      }
      let frame = frames[frameIndex]

      let rawCx = mapX(frame.x)
      let rawCyTop = mapYTopDown(frame.y)
      let rawCy = target.height - rawCyTop

      let isInside = inBounds(frame)
      let rawZoomWanted = isInside && (frame.spriteID != defaultSpriteID)

      let stableZoomActive: Bool
      if isInside {
        if let manualSegments = params.zoomSegments {
          let tMs = Int(t * 1000)
          stableZoomActive = manualSegments.contains { $0.contains(timeMs: tMs) }
        } else {
          stableZoomActive = zoomHysteresis.update(time: t, rawZoomWanted: rawZoomWanted)
        }
      } else {
        zoomHysteresis.reset()
        stableZoomActive = false
      }

      if stableZoomActive {
        if let manualSegments = params.zoomSegments,
          let activeSegment = manualSegments.first(where: { $0.contains(timeMs: Int(t * 1000)) })
        {
          stableZoomStartTime = Double(activeSegment.startMs) / 1000.0
        } else if stableZoomStartTime == nil {
          stableZoomStartTime = t
        }
      } else {
        stableZoomStartTime = nil
      }

      let targetZ: CGFloat = stableZoomActive ? params.zoomFactor : 1.0
      let targetLookAtX = stableZoomActive ? rawCx : focusX
      let targetLookAtY = stableZoomActive ? rawCy : focusY

      let alpha = ZoomFollowSmoother.alpha(
        baseStrength: params.followStrength,
        dt: step
      )

      smoothZ = ZoomFollowSmoother.lerp(current: smoothZ, target: targetZ, alpha: alpha)
      smoothCx = ZoomFollowSmoother.lerp(current: smoothCx, target: targetLookAtX, alpha: alpha)
      smoothCy = ZoomFollowSmoother.lerp(current: smoothCy, target: targetLookAtY, alpha: alpha)

      if !didLogZoomSmootherProfile {
        didLogZoomSmootherProfile = true
        NativeLogger.d(
          "ZoomSmoother",
          "Export smoother configured",
          context: [
            "followStrength": ZoomFollowSmoother.clampedFollowStrength(params.followStrength),
            "alpha": alpha,
            "fpsHint": params.fpsHint,
            "dt": ZoomFollowSmoother.clampedDtSeconds(step),
          ]
        )
      }

      let safeZoom = max(smoothZ, 0.0001)
      let halfWidth = contentRect.width / (2.0 * safeZoom)
      let halfHeight = contentRect.height / (2.0 * safeZoom)
      let minCenterX = contentRect.minX + halfWidth
      let maxCenterX = contentRect.maxX - halfWidth
      let minCenterY = contentRect.minY + halfHeight
      let maxCenterY = contentRect.maxY - halfHeight
      smoothCx = min(max(smoothCx, minCenterX), maxCenterX)
      smoothCy = min(max(smoothCy, minCenterY), maxCenterY)

      if ZoomFollowParityDebug.shouldLogExport(frameIndex: i) {
        ZoomFollowParityDebug.logSample(
          source: "export",
          time: t,
          zoom: smoothZ,
          centerX: smoothCx,
          centerY: smoothCy,
          targetZoom: targetZ,
          targetCenterX: targetLookAtX,
          targetCenterY: targetLookAtY
        )
      }

      samples.append(
        ExportZoomSample(
          time: t,
          zoom: smoothZ,
          centerX: smoothCx,
          centerY: smoothCy,
          isActive: stableZoomActive,
          localTime: stableZoomStartTime.map { max(t - $0, 0.0) }
        )
      )
    }

    return samples
  }

  private func buildCameraPresentationSamples(
    params: CompositionParams,
    cameraParams: CameraCompositionParams,
    zoomSamples: [ExportZoomSample],
    effectiveDuration: Double
  ) -> [CameraPresentationSample] {
    let needsZoomSamples =
      !zoomSamples.isEmpty
      && (
        cameraParams.zoomBehavior == .scaleWithScreenZoom
          || cameraParams.zoomEmphasisPreset == .pulse
      )

    var samples: [CameraPresentationSample] = []

    if needsZoomSamples {
      samples = zoomSamples
        .filter { $0.time <= effectiveDuration + 0.0001 }
        .map {
        CameraPresentationSample(
          time: $0.time,
          zoom: $0.zoom,
          zoomState: CameraAnimationZoomState(isActive: $0.isActive, localTime: $0.localTime)
        )
      }
    }

    guard CameraAnimationTimelineBuilder.hasPresentationEffects(cameraParams) else {
      return samples
    }

    let fps = params.fpsHint > 0 ? Double(params.fpsHint) : 30.0
    let animationStep = 1.0 / max(fps, 30.0)
    var timePoints = Set(samples.map { roundedSampleTime($0.time) })
    timePoints.insert(0.0)
    timePoints.insert(roundedSampleTime(effectiveDuration))

    if cameraParams.introPreset != .none {
      let introDuration = min(Double(cameraParams.introDurationMs) / 1000.0, effectiveDuration)
      var t = 0.0
      while t <= introDuration + 0.0001 {
        timePoints.insert(roundedSampleTime(t))
        t += animationStep
      }
      timePoints.insert(roundedSampleTime(introDuration))
    }

    if cameraParams.outroPreset != .none {
      let outroDuration = min(Double(cameraParams.outroDurationMs) / 1000.0, effectiveDuration)
      let outroStart = max(effectiveDuration - outroDuration, 0.0)
      var t = outroStart
      while t <= effectiveDuration + 0.0001 {
        timePoints.insert(roundedSampleTime(t))
        t += animationStep
      }
      timePoints.insert(roundedSampleTime(outroStart))
    }

    if samples.isEmpty {
      return timePoints.sorted().map {
        CameraPresentationSample(
          time: $0,
          zoom: 1.0,
          zoomState: .inactive
        )
      }
    }

    let sampleLookup = Dictionary(uniqueKeysWithValues: samples.map { (roundedSampleTime($0.time), $0) })
    let sortedSamples = samples.sorted { $0.time < $1.time }
    var index = 0

    return timePoints.sorted().map { time in
      if let sample = sampleLookup[time] {
        return sample
      }
      while index < sortedSamples.count - 1 && sortedSamples[index + 1].time <= time + 0.0001 {
        index += 1
      }
      let source = sortedSamples[min(index, sortedSamples.count - 1)]
      return CameraPresentationSample(
        time: time,
        zoom: source.zoom,
        zoomState: source.zoomState
      )
    }
  }

  private func roundedSampleTime(_ time: Double) -> Double {
    (time * 1000.0).rounded() / 1000.0
  }

  private func transformsApproximatelyEqual(
    _ lhs: CGAffineTransform,
    _ rhs: CGAffineTransform,
    epsilon: CGFloat = 0.0001
  ) -> Bool {
    abs(lhs.a - rhs.a) <= epsilon
      && abs(lhs.b - rhs.b) <= epsilon
      && abs(lhs.c - rhs.c) <= epsilon
      && abs(lhs.d - rhs.d) <= epsilon
      && abs(lhs.tx - rhs.tx) <= epsilon
      && abs(lhs.ty - rhs.ty) <= epsilon
  }

  private func addCursorLayer(
    to hostLayer: CALayer,
    recording: CursorRecording,
    params: CompositionParams,
    target: CGSize,
    contentRect: CGRect,
    contentWidth: Double,
    contentHeight: Double,
    tx: Double,
    ty: Double,
    asset: AVAsset,
    videoToTargetScale: CGFloat
  ) {
    let frames = recording.frames
    let sprites = recording.sprites
    let videoDuration = asset.duration.seconds
    guard !frames.isEmpty else { return }

    // 1. Prepare Images & Metadata Caches
    var spriteImages: [Int: CGImage] = [:]
    var spriteSizes: [Int: CGSize] = [:]
    var spriteHotspots: [Int: CGPoint] = [:]

    for sprite in sprites {
      if let img = cgImageFromSprite(sprite) {
        spriteImages[sprite.id] = img
        spriteSizes[sprite.id] = CGSize(width: Double(sprite.width), height: Double(sprite.height))
        spriteHotspots[sprite.id] = CGPoint(x: Double(sprite.hotspotX), y: Double(sprite.hotspotY))
      }
    }

    // Safety check: ensure we have at least defaults
    let defaultSize = CGSize(width: 32, height: 32)
    let defaultHotspot = CGPoint(x: 0, y: 0)

    // 2. Create Layers
    let cursorContainer = CALayer()
    cursorContainer.anchorPoint = .zero
    cursorContainer.bounds = .zero
    // Ensure container doesn't clip (important for zoom)
    cursorContainer.masksToBounds = false

    let cursorLayer = CALayer()
    // STRICT: Use 'resize' or 'resizeAspectFill'.
    // 'resizeAspect' might introduce subpixel centering offsets if bounds != image ratio slightly.
    // Since we control width/height exactly, 'resize' is safest.
    // cursorLayer.contentsGravity = .resize
    cursorLayer.masksToBounds = false
    cursorLayer.contentsGravity = .resizeAspect
    cursorLayer.magnificationFilter = .nearest
    cursorLayer.minificationFilter = .nearest
    cursorLayer.contentsScale = 1.0

    cursorContainer.addSublayer(cursorLayer)

    hostLayer.anchorPoint = .zero
    hostLayer.position = .zero
    hostLayer.addSublayer(cursorContainer)

    // Helper map functions (Video Space)
    let mapX: (Double) -> CGFloat = { tx + CGFloat($0) * contentWidth }
    let mapYTopDown: (Double) -> CGFloat = { ty + CGFloat($0) * contentHeight }

    // 3. Build Keyframe Arrays

    // We want ONE keyframe per frame event in the recording.
    // Core Animation interpolates 'position' naturally.
    // 'contents', 'bounds', 'anchorPoint' should be DISCRETE (step function).

    // Map time to normalized [0..1]
    let keyTimes = frames.map { NSNumber(value: $0.t / max(videoDuration, 0.001)) }

    let opacityValues: [NSNumber] = frames.map { inBounds($0) ? 1.0 : 0.0 }

    let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
    opacityAnim.values = opacityValues
    opacityAnim.keyTimes = keyTimes
    opacityAnim.calculationMode = .discrete
    opacityAnim.isRemovedOnCompletion = false
    opacityAnim.fillMode = .forwards

    opacityAnim.duration = videoDuration
    opacityAnim.beginTime = AVCoreAnimationBeginTimeAtZero

    cursorContainer.add(opacityAnim, forKey: "cursorOpacity")
    cursorContainer.opacity = Float(opacityValues.last?.doubleValue ?? 1.0)

    // A) Position (Container) - Continuous
    let positionValues = frames.map { f -> NSValue in
      let x = mapX(f.x)
      let yTop = mapYTopDown(f.y)
      let y = target.height - yTop
      return NSValue(point: CGPoint(x: x, y: y))
    }

    // B) Contents (Sprite Image) - Discrete
    let fallback = transparent1x1()
    var lastImg: CGImage = fallback

    let contentsValues: [CGImage] = frames.map { f in
      if f.spriteID >= 0, let img = spriteImages[f.spriteID] {
        lastImg = img
        return img
      }
      return lastImg  // out-of-bounds or missing -> keep last (opacity will hide it)
    }

    // Prime the layer so first frame is correct
    cursorLayer.contents = contentsValues.first ?? fallback

    let missing = sprites.filter { spriteImages[$0.id] == nil }.map { $0.id }
    NativeLogger.w("Export", "Sprites missing CGImage", context: ["missing": missing])

    let nonNullCount = contentsValues.filter { !($0 is NSNull) }.count
    NativeLogger.i(
      "Export", "Cursor overlay stats",
      context: [
        "frames": frames.count,
        "sprites": sprites.count,
        "spriteImages": spriteImages.count,
        "nonNullImages": nonNullCount,
        "firstSpriteID": frames.first?.spriteID ?? -999,
        "lastSpriteID": frames.last?.spriteID ?? -999,
      ])

    // C) Bounds (Sprite Size) - Discrete
    let finalScale = CGFloat(params.cursorSize) * videoToTargetScale
    NativeLogger.d(
      "Export", "Cursor scale mapping",
      context: [
        "cursorSize": params.cursorSize,
        "videoToTargetScale": videoToTargetScale,
        "finalScale": finalScale,
      ])
    let boundsValues: [Any] = frames.map { f in
      guard f.spriteID >= 0 else { return NSValue(rect: .zero) }
      let sz = spriteSizes[f.spriteID] ?? defaultSize
      let w = sz.width * finalScale
      let h = sz.height * finalScale
      return NSValue(rect: CGRect(x: 0, y: 0, width: w, height: h))
    }
    // D) AnchorPoint (Hotspot) - Discrete
    // AnchorPoint is normalized (0..1).
    // (0,0) is Bottom-Left in Core Animation (usually).
    // Sprite Hotspot is from Top-Left.
    // AnchorX = hotX / width
    // AnchorY = 1.0 - (hotY / height)
    let anchorValues: [Any] = frames.map { f in
      guard f.spriteID >= 0 else { return NSValue(point: CGPoint(x: 0, y: 0)) }
      let sz = spriteSizes[f.spriteID] ?? defaultSize
      let hot = spriteHotspots[f.spriteID] ?? defaultHotspot
      let ax = (sz.width > 0) ? (hot.x / sz.width) : 0
      let ay = (sz.height > 0) ? (1.0 - (hot.y / sz.height)) : 1.0
      return NSValue(point: CGPoint(x: ax, y: ay))
    }

    // 4. Apply Animations

    let animDuration = videoDuration
    let beginTime = AVCoreAnimationBeginTimeAtZero

    // Function to simplify adding CAKeyframeAnimation
    func addAnim(to layer: CALayer, key: String, values: [Any], discrete: Bool) {
      let anim = CAKeyframeAnimation(keyPath: key)
      anim.values = values
      anim.keyTimes = keyTimes
      anim.duration = animDuration
      anim.beginTime = beginTime
      anim.isRemovedOnCompletion = false
      anim.fillMode = .forwards
      if discrete {
        anim.calculationMode = .discrete
      }
      layer.add(anim, forKey: key)
    }

    // Apply to Container
    addAnim(to: cursorContainer, key: "position", values: positionValues, discrete: false)

    // Apply to Inner Layer
    addAnim(to: cursorLayer, key: "contents", values: contentsValues, discrete: true)

    addAnim(to: cursorLayer, key: "bounds", values: boundsValues, discrete: true)
    addAnim(to: cursorLayer, key: "anchorPoint", values: anchorValues, discrete: true)
    let missingFrameCount = frames.filter { $0.spriteID >= 0 && spriteImages[$0.spriteID] == nil }
      .count
    NativeLogger.w("Export", "Frames missing sprite image", context: ["count": missingFrameCount])

    // Force set initial values to FIRST frame to avoid glitches before animation kicks in
    if let first = frames.first {
      let firstIdx = 0
      // Position
      if let posVal = positionValues[firstIdx] as? NSValue {
        cursorContainer.position = posVal.pointValue
      }
      // Bounds
      if let bVal = boundsValues[firstIdx] as? NSValue {
        cursorLayer.bounds = bVal.rectValue
      }
      // Anchor
      if let aVal = anchorValues[firstIdx] as? NSValue {
        cursorLayer.anchorPoint = aVal.pointValue
      }
    }

  }

  private func applyZoomAnimation(
    to layer: CALayer,
    zoomSamples: [ExportZoomSample],
    focusX: CGFloat,
    focusY: CGFloat,
    videoDuration: Double
  ) {
    guard !zoomSamples.isEmpty else { return }

    layer.anchorPoint = .zero
    layer.position = .zero

    let times = zoomSamples.map { NSNumber(value: $0.time / max(videoDuration, 0.0001)) }
    let values = zoomSamples.map { sample -> NSValue in
      let transform = exportZoomTransform(
        focusX: focusX,
        focusY: focusY,
        sample: sample
      )
      return NSValue(caTransform3D: CATransform3DMakeAffineTransform(transform))
    }

    let zoomAnim = CAKeyframeAnimation(keyPath: "transform")
    zoomAnim.values = values
    zoomAnim.keyTimes = times
    zoomAnim.duration = videoDuration
    zoomAnim.beginTime = AVCoreAnimationBeginTimeAtZero
    zoomAnim.isRemovedOnCompletion = false
    zoomAnim.fillMode = .forwards
    zoomAnim.calculationMode = .linear

    layer.add(zoomAnim, forKey: "transform")
    if let lastSample = zoomSamples.last {
      layer.transform = CATransform3DMakeAffineTransform(
        exportZoomTransform(
          focusX: focusX,
          focusY: focusY,
          sample: lastSample
        )
      )
    }
  }

  // In CompositionBuilder.swift -> cgImageFromSprite(...)

  private func cgImageFromSprite(_ sprite: CursorSprite) -> CGImage? {
    let width = sprite.width
    let height = sprite.height
    let length = width * height * 4

    // Sanity check data length
    guard sprite.pixels.count >= length else { return nil }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    // Create provider directly from packed data
    guard let provider = CGDataProvider(data: sprite.pixels as CFData) else { return nil }

    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,  // strictly packed
      space: colorSpace,
      bitmapInfo: bitmapInfo,
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent
    )
  }
  private func transparent1x1() -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var pixel: [UInt8] = [0, 0, 0, 0]  // RGBA transparent
    let data = Data(pixel)
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(
      width: 1, height: 1,
      bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: 4,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )!
  }

}
