import AVFoundation
import CoreGraphics
import Foundation

struct PreviewMediaSources: Equatable {
  let projectPath: String
  let screenPath: String
  let cameraPath: String?
  let metadataPath: String?
  let cursorPath: String?
  let zoomManualPath: String?
  let cameraSyncTimeline: CameraSyncTimeline?

  init(
    projectPath: String,
    screenPath: String,
    cameraPath: String?,
    metadataPath: String?,
    cursorPath: String?,
    zoomManualPath: String?,
    cameraSyncTimeline: CameraSyncTimeline? = nil
  ) {
    self.projectPath = projectPath
    self.screenPath = screenPath
    self.cameraPath = cameraPath
    self.metadataPath = metadataPath
    self.cursorPath = cursorPath
    self.zoomManualPath = zoomManualPath
    self.cameraSyncTimeline = cameraSyncTimeline
  }
}

struct CameraSyncTimeline: Equatable {
  struct Segment: Equatable {
    let screenStartSeconds: Double
    let cameraStartSeconds: Double
    let durationSeconds: Double
  }

  struct Mapping: Equatable {
    let screenTimeSeconds: Double
    let cameraTimeSeconds: Double
    let segment: Segment
  }

  let segments: [Segment]

  var isEmpty: Bool { segments.isEmpty }

  func mapping(forScreenTime time: Double) -> Mapping? {
    guard !segments.isEmpty else { return nil }

    let normalizedTime = max(0.0, time)
    for (index, segment) in segments.enumerated() {
      let segmentEnd = segment.screenStartSeconds + segment.durationSeconds
      let inRange =
        normalizedTime + CameraSyncTimelineResolver.timeEpsilon >= segment.screenStartSeconds
        && normalizedTime < segmentEnd - CameraSyncTimelineResolver.timeEpsilon
      let atTerminalSample =
        abs(normalizedTime - segmentEnd) <= CameraSyncTimelineResolver.timeEpsilon
        && index == segments.count - 1
      guard inRange || atTerminalSample else { continue }

      let clampedScreenTime = min(
        max(normalizedTime, segment.screenStartSeconds),
        segmentEnd
      )
      let cameraTime =
        segment.cameraStartSeconds + (clampedScreenTime - segment.screenStartSeconds)
      return Mapping(
        screenTimeSeconds: clampedScreenTime,
        cameraTimeSeconds: cameraTime,
        segment: segment
      )
    }

    return nil
  }

  func containsScreenTime(_ time: Double) -> Bool {
    mapping(forScreenTime: time) != nil
  }
}

enum CameraSyncTimelineResolver {
  fileprivate static let timeEpsilon = 0.0001

  private struct AbsoluteSegment: Equatable {
    let index: Int
    let startDate: Date
    let endDate: Date
    let durationSeconds: Double
    let relativePath: String?
    let source: String
  }

  static func resolve(
    recordingMetadata: RecordingMetadata?,
    cameraMetadata: CameraRecordingMetadata?,
    screenAsset: AVAsset?,
    cameraAsset: AVAsset?,
    logContext: [String: Any] = [:]
  ) -> CameraSyncTimeline? {
    guard let cameraAsset else { return nil }

    let screenDurationSeconds = mediaDurationSeconds(for: screenAsset)
    let cameraDurationSeconds = mediaDurationSeconds(for: cameraAsset)
    guard screenDurationSeconds > timeEpsilon, cameraDurationSeconds > timeEpsilon else {
      NativeLogger.w(
        "CameraSync",
        "Skipping sync timeline resolution: missing media duration",
        context: mergedContext(
          logContext,
          [
            "screenDurationSeconds": screenDurationSeconds,
            "cameraDurationSeconds": cameraDurationSeconds,
          ]
        )
      )
      return nil
    }

    let screenSegments = resolvedScreenSegments(
      recordingMetadata: recordingMetadata,
      screenDurationSeconds: screenDurationSeconds
    )
    let cameraSegments = resolvedCameraSegments(
      recordingMetadata: recordingMetadata,
      cameraMetadata: cameraMetadata,
      cameraDurationSeconds: cameraDurationSeconds
    )

    guard !screenSegments.isEmpty, !cameraSegments.isEmpty else {
      let fallback = zeroOffsetTimeline(
        screenDurationSeconds: screenDurationSeconds,
        cameraDurationSeconds: cameraDurationSeconds
      )
      NativeLogger.w(
        "CameraSync",
        "Falling back to zero-offset camera sync timeline",
        context: mergedContext(
          logContext,
          [
            "reason": "missingAuthoritativeSegments",
            "screenDurationSeconds": screenDurationSeconds,
            "cameraDurationSeconds": cameraDurationSeconds,
            "fallbackSegments": fallback.segments.map(segmentPayload),
          ]
        )
      )
      return fallback
    }

    let mappingSegments = intersectSegments(screenSegments: screenSegments, cameraSegments: cameraSegments)
    if mappingSegments.isEmpty {
      let fallback = zeroOffsetTimeline(
        screenDurationSeconds: screenDurationSeconds,
        cameraDurationSeconds: cameraDurationSeconds
      )
      NativeLogger.w(
        "CameraSync",
        "Falling back to zero-offset camera sync timeline",
        context: mergedContext(
          logContext,
          [
            "reason": "noSegmentOverlap",
            "screenSegments": screenSegments.map(absoluteSegmentPayload),
            "cameraSegments": cameraSegments.map(absoluteSegmentPayload),
            "fallbackSegments": fallback.segments.map(segmentPayload),
          ]
        )
      )
      return fallback
    }

    NativeLogger.i(
      "CameraSync",
      "Resolved camera sync timeline",
      context: mergedContext(
        logContext,
        [
          "screenSegments": screenSegments.map(absoluteSegmentPayload),
          "cameraSegments": cameraSegments.map(absoluteSegmentPayload),
          "syncSegments": mappingSegments.map(segmentPayload),
        ]
      )
    )

    return CameraSyncTimeline(segments: mappingSegments)
  }

  private static func resolvedScreenSegments(
    recordingMetadata: RecordingMetadata?,
    screenDurationSeconds: Double
  ) -> [AbsoluteSegment] {
    if let authoritative = authoritativeSegments(
      from: recordingMetadata?.screen.segments,
      source: "screen.metadata.segments"
    ) {
      return authoritative
    }

    guard let recordingMetadata else { return [] }
    if let endedAt = date(from: recordingMetadata.endedAt) {
      return [
        AbsoluteSegment(
          index: 0,
          startDate: endedAt.addingTimeInterval(-screenDurationSeconds),
          endDate: endedAt,
          durationSeconds: screenDurationSeconds,
          relativePath: recordingMetadata.screen.rawRelativePath,
          source: "screen.metadata.endedAt"
        )
      ]
    }
    if let startedAt = date(from: recordingMetadata.startedAt) {
      return [
        AbsoluteSegment(
          index: 0,
          startDate: startedAt,
          endDate: startedAt.addingTimeInterval(screenDurationSeconds),
          durationSeconds: screenDurationSeconds,
          relativePath: recordingMetadata.screen.rawRelativePath,
          source: "screen.metadata.startedAt"
        )
      ]
    }

    return []
  }

  private static func resolvedCameraSegments(
    recordingMetadata: RecordingMetadata?,
    cameraMetadata: CameraRecordingMetadata?,
    cameraDurationSeconds: Double
  ) -> [AbsoluteSegment] {
    if let authoritative = authoritativeSegments(
      from: recordingMetadata?.camera?.segments,
      source: "recordingMetadata.camera.segments"
    ) {
      return authoritative
    }
    if let authoritative = authoritativeSegments(
      from: cameraMetadata?.segments,
      source: "cameraMetadata.segments"
    ) {
      return authoritative
    }

    guard let cameraMetadata else { return [] }
    if let endedAt = date(from: cameraMetadata.endedAt) {
      return [
        AbsoluteSegment(
          index: 0,
          startDate: endedAt.addingTimeInterval(-cameraDurationSeconds),
          endDate: endedAt,
          durationSeconds: cameraDurationSeconds,
          relativePath: cameraMetadata.rawRelativePath,
          source: "camera.metadata.endedAt"
        )
      ]
    }
    if let startedAt = date(from: cameraMetadata.startedAt) {
      return [
        AbsoluteSegment(
          index: 0,
          startDate: startedAt,
          endDate: startedAt.addingTimeInterval(cameraDurationSeconds),
          durationSeconds: cameraDurationSeconds,
          relativePath: cameraMetadata.rawRelativePath,
          source: "camera.metadata.startedAt"
        )
      ]
    }

    return []
  }

  private static func authoritativeSegments(
    from segments: [RecordingMetadata.CaptureSegment]?,
    source: String
  ) -> [AbsoluteSegment]? {
    guard let segments, !segments.isEmpty else { return nil }

    let resolved = segments.compactMap { segment -> AbsoluteSegment? in
      guard
        let durationSeconds = segment.durationSeconds,
        durationSeconds > timeEpsilon,
        let startDate = date(from: segment.startWallClock),
        let endDate = date(from: segment.endWallClock)
      else {
        return nil
      }

      return AbsoluteSegment(
        index: segment.index,
        startDate: startDate,
        endDate: endDate,
        durationSeconds: durationSeconds,
        relativePath: segment.relativePath,
        source: source
      )
    }

    guard resolved.count == segments.count else { return nil }
    return resolved.sorted(by: { $0.startDate < $1.startDate })
  }

  private static func intersectSegments(
    screenSegments: [AbsoluteSegment],
    cameraSegments: [AbsoluteSegment]
  ) -> [CameraSyncTimeline.Segment] {
    var result: [CameraSyncTimeline.Segment] = []
    var screenIndex = 0
    var cameraIndex = 0
    var cumulativeScreenSeconds = 0.0
    var cumulativeCameraSeconds = 0.0

    while screenIndex < screenSegments.count, cameraIndex < cameraSegments.count {
      let screenSegment = screenSegments[screenIndex]
      let cameraSegment = cameraSegments[cameraIndex]

      let overlapStart = max(screenSegment.startDate, cameraSegment.startDate)
      let overlapEnd = min(screenSegment.endDate, cameraSegment.endDate)
      let overlapDuration = overlapEnd.timeIntervalSince(overlapStart)

      if overlapDuration > timeEpsilon {
        let screenOffset = overlapStart.timeIntervalSince(screenSegment.startDate)
        let cameraOffset = overlapStart.timeIntervalSince(cameraSegment.startDate)
        result.append(
          CameraSyncTimeline.Segment(
            screenStartSeconds: cumulativeScreenSeconds + screenOffset,
            cameraStartSeconds: cumulativeCameraSeconds + cameraOffset,
            durationSeconds: overlapDuration
          )
        )
      }

      if screenSegment.endDate <= cameraSegment.endDate {
        cumulativeScreenSeconds += screenSegment.durationSeconds
        screenIndex += 1
      }
      if cameraSegment.endDate <= screenSegment.endDate {
        cumulativeCameraSeconds += cameraSegment.durationSeconds
        cameraIndex += 1
      }
    }

    return result
  }

  private static func zeroOffsetTimeline(
    screenDurationSeconds: Double,
    cameraDurationSeconds: Double
  ) -> CameraSyncTimeline {
    CameraSyncTimeline(
      segments: [
        CameraSyncTimeline.Segment(
          screenStartSeconds: 0.0,
          cameraStartSeconds: 0.0,
          durationSeconds: min(screenDurationSeconds, cameraDurationSeconds)
        )
      ]
    )
  }

  private static func mediaDurationSeconds(for asset: AVAsset?) -> Double {
    guard let asset else { return 0.0 }
    let duration = asset.duration
    guard duration.isNumeric else { return 0.0 }
    let seconds = duration.seconds
    guard seconds.isFinite, seconds > 0 else { return 0.0 }
    return seconds
  }

  private static func date(from value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
  }

  private static func absoluteSegmentPayload(_ segment: AbsoluteSegment) -> [String: Any] {
    [
      "index": segment.index,
      "relativePath": segment.relativePath ?? "nil",
      "startWallClock": RecordingMetadata.iso8601String(from: segment.startDate),
      "endWallClock": RecordingMetadata.iso8601String(from: segment.endDate),
      "durationSeconds": segment.durationSeconds,
      "source": segment.source,
    ]
  }

  private static func segmentPayload(_ segment: CameraSyncTimeline.Segment) -> [String: Any] {
    [
      "screenStartSeconds": segment.screenStartSeconds,
      "cameraStartSeconds": segment.cameraStartSeconds,
      "durationSeconds": segment.durationSeconds,
    ]
  }

  private static func mergedContext(
    _ lhs: [String: Any],
    _ rhs: [String: Any]
  ) -> [String: Any] {
    var context = lhs
    rhs.forEach { context[$0.key] = $0.value }
    return context
  }
}

enum CameraPreviewChangeKind: String, Equatable {
  case none
  case placementJump
  case dragPreview
}

struct CameraCompositionParams: Equatable {
  static let defaultZoomBehavior: CameraZoomBehavior = .scaleWithScreenZoom
  static let defaultZoomScaleMultiplier = 0.35
  static let defaultIntroPreset: CameraIntroPreset = .fade
  static let defaultOutroPreset: CameraOutroPreset = .shrink
  static let defaultIntroDurationMs = 220
  static let defaultOutroDurationMs = 180
  static let defaultZoomEmphasisStrength = 0.10

  var visible: Bool
  var layoutPreset: CameraLayoutPreset
  var normalizedCanvasCenter: CGPoint?
  var sizeFactor: Double
  var shape: CameraShape
  var cornerRadius: Double
  var opacity: Double
  var mirror: Bool
  var contentMode: CameraContentMode
  var zoomBehavior: CameraZoomBehavior
  var zoomScaleMultiplier: Double = CameraCompositionParams.defaultZoomScaleMultiplier
  var introPreset: CameraIntroPreset = CameraCompositionParams.defaultIntroPreset
  var outroPreset: CameraOutroPreset = CameraCompositionParams.defaultOutroPreset
  var zoomEmphasisPreset: CameraZoomEmphasisPreset = .none
  var introDurationMs: Int = CameraCompositionParams.defaultIntroDurationMs
  var outroDurationMs: Int = CameraCompositionParams.defaultOutroDurationMs
  var zoomEmphasisStrength: Double = CameraCompositionParams.defaultZoomEmphasisStrength
  var borderWidth: Double
  var borderColorArgb: Int?
  var shadowPreset: Int
  var chromaKeyEnabled: Bool
  var chromaKeyStrength: Double
  var chromaKeyColorArgb: Int?

  static let hidden = CameraCompositionParams(
    visible: false,
    layoutPreset: .hidden,
    normalizedCanvasCenter: nil,
    sizeFactor: 0.18,
    shape: .circle,
    cornerRadius: 0.0,
    opacity: 1.0,
    mirror: true,
    contentMode: .fill,
    zoomBehavior: CameraCompositionParams.defaultZoomBehavior,
    zoomScaleMultiplier: CameraCompositionParams.defaultZoomScaleMultiplier,
    introPreset: CameraCompositionParams.defaultIntroPreset,
    outroPreset: CameraCompositionParams.defaultOutroPreset,
    zoomEmphasisPreset: .none,
    introDurationMs: CameraCompositionParams.defaultIntroDurationMs,
    outroDurationMs: CameraCompositionParams.defaultOutroDurationMs,
    zoomEmphasisStrength: CameraCompositionParams.defaultZoomEmphasisStrength,
    borderWidth: 0.0,
    borderColorArgb: nil,
    shadowPreset: 0,
    chromaKeyEnabled: false,
    chromaKeyStrength: 0.4,
    chromaKeyColorArgb: nil
  )
}

struct PreviewScene: Equatable {
  let mediaSources: PreviewMediaSources
  let screenParams: CompositionParams
  let cameraParams: CameraCompositionParams?
  let cameraPreviewChangeKind: CameraPreviewChangeKind

  init(
    mediaSources: PreviewMediaSources,
    screenParams: CompositionParams,
    cameraParams: CameraCompositionParams?,
    cameraPreviewChangeKind: CameraPreviewChangeKind = .none
  ) {
    self.mediaSources = mediaSources
    self.screenParams = screenParams
    self.cameraParams = cameraParams
    self.cameraPreviewChangeKind = cameraPreviewChangeKind
  }
}

struct CameraLayoutResolution: Equatable {
  enum ZOrder: Equatable {
    case behindScreen
    case aboveScreen
  }

  let frame: CGRect
  let zOrder: ZOrder
  let shouldRender: Bool
}

// Resolves the base camera frame and mask geometry shared by preview and export.
enum CameraLayoutResolver {
  static func resolve(
    canvasSize: CGSize,
    params: CameraCompositionParams
  ) -> CameraLayoutResolution {
    guard params.visible, params.layoutPreset != .hidden else {
      return CameraLayoutResolution(frame: .zero, zOrder: .aboveScreen, shouldRender: false)
    }

    let size = clampedCameraSize(canvasSize: canvasSize, sizeFactor: params.sizeFactor)
    let margin = max(16.0, min(canvasSize.width, canvasSize.height) * 0.03)

    switch params.layoutPreset {
    case .overlayTopLeft:
      return resolvedOverlay(
        origin: CGPoint(x: margin, y: canvasSize.height - margin - size.height),
        size: size
      )
    case .overlayTopRight:
      return resolvedOverlay(
        origin: CGPoint(x: canvasSize.width - margin - size.width, y: canvasSize.height - margin - size.height),
        size: size
      )
    case .overlayBottomLeft:
      return resolvedOverlay(origin: CGPoint(x: margin, y: margin), size: size)
    case .overlayBottomRight:
      return resolvedOverlay(
        origin: CGPoint(x: canvasSize.width - margin - size.width, y: margin),
        size: size
      )
    case .sideBySideLeft:
      return CameraLayoutResolution(
        frame: CGRect(
          x: margin,
          y: margin,
          width: max(120.0, canvasSize.width * 0.32),
          height: max(120.0, canvasSize.height - (margin * 2.0))
        ),
        zOrder: .aboveScreen,
        shouldRender: true
      )
    case .sideBySideRight:
      let width = max(120.0, canvasSize.width * 0.32)
      return CameraLayoutResolution(
        frame: CGRect(
          x: canvasSize.width - margin - width,
          y: margin,
          width: width,
          height: max(120.0, canvasSize.height - (margin * 2.0))
        ),
        zOrder: .aboveScreen,
        shouldRender: true
      )
    case .stackedTop:
      let height = max(120.0, canvasSize.height * 0.28)
      return CameraLayoutResolution(
        frame: CGRect(
          x: margin,
          y: canvasSize.height - margin - height,
          width: max(160.0, canvasSize.width - (margin * 2.0)),
          height: height
        ),
        zOrder: .aboveScreen,
        shouldRender: true
      )
    case .stackedBottom:
      let height = max(120.0, canvasSize.height * 0.28)
      return CameraLayoutResolution(
        frame: CGRect(
          x: margin,
          y: margin,
          width: max(160.0, canvasSize.width - (margin * 2.0)),
          height: height
        ),
        zOrder: .aboveScreen,
        shouldRender: true
      )
    case .backgroundBehind:
      return CameraLayoutResolution(
        frame: CGRect(origin: .zero, size: canvasSize),
        zOrder: .behindScreen,
        shouldRender: true
      )
    case .hidden:
      return CameraLayoutResolution(frame: .zero, zOrder: .aboveScreen, shouldRender: false)
    }
  }

  static func manualFrame(
    canvasSize: CGSize,
    params: CameraCompositionParams
  ) -> CGRect? {
    guard let center = params.normalizedCanvasCenter else { return nil }
    let size = clampedCameraSize(canvasSize: canvasSize, sizeFactor: params.sizeFactor)
    let rawCenter = CGPoint(
      x: max(0.0, min(1.0, center.x)) * canvasSize.width,
      y: max(0.0, min(1.0, center.y)) * canvasSize.height
    )
    return CGRect(
      x: rawCenter.x - (size.width / 2.0),
      y: rawCenter.y - (size.height / 2.0),
      width: size.width,
      height: size.height
    )
  }

  static func effectiveFrame(
    canvasSize: CGSize,
    params: CameraCompositionParams
  ) -> CameraLayoutResolution {
    if let manual = manualFrame(canvasSize: canvasSize, params: params) {
      return CameraLayoutResolution(
        frame: clamp(frame: manual, within: canvasSize),
        zOrder: params.layoutPreset == .backgroundBehind ? .behindScreen : .aboveScreen,
        shouldRender: params.visible && params.layoutPreset != .hidden
      )
    }

    return resolve(canvasSize: canvasSize, params: params)
  }

  static func clampPresentationFrame(
    _ frame: CGRect,
    within canvasSize: CGSize,
    params: CameraCompositionParams
  ) -> CGRect {
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    guard canvasRect.width > 0.0, canvasRect.height > 0.0 else {
      return .zero
    }

    let outset = presentationVisualOutset(for: params)
    let safeWidth = max(canvasRect.width - (outset * 2.0), 1.0)
    let safeHeight = max(canvasRect.height - (outset * 2.0), 1.0)
    let safeRect = CGRect(
      x: canvasRect.midX - (safeWidth / 2.0),
      y: canvasRect.midY - (safeHeight / 2.0),
      width: safeWidth,
      height: safeHeight
    )

    let width = max(frame.width, 1.0)
    let height = max(frame.height, 1.0)
    let uniformScale = min(1.0, safeRect.width / width, safeRect.height / height)
    let scaledSize = CGSize(
      width: width * uniformScale,
      height: height * uniformScale
    )

    let scaledFrame = CGRect(
      x: frame.midX - (scaledSize.width / 2.0),
      y: frame.midY - (scaledSize.height / 2.0),
      width: scaledSize.width,
      height: scaledSize.height
    )

    let originX = min(
      max(safeRect.minX, scaledFrame.minX),
      max(safeRect.minX, safeRect.maxX - scaledSize.width)
    )
    let originY = min(
      max(safeRect.minY, scaledFrame.minY),
      max(safeRect.minY, safeRect.maxY - scaledSize.height)
    )

    return CGRect(
      x: originX,
      y: originY,
      width: scaledSize.width,
      height: scaledSize.height
    )
  }

  static func maskPath(
    in rect: CGRect,
    params: CameraCompositionParams
  ) -> CGPath {
    switch params.shape {
    case .circle:
      return CGPath(ellipseIn: rect, transform: nil)
    case .square:
      return CGPath(rect: rect, transform: nil)
    case .roundedRect:
      let radius = resolvedCornerRadius(size: rect.size, value: params.cornerRadius)
      return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    case .squircle:
      return squirclePath(in: rect)
    }
  }

  static func contentRect(
    for sourceSize: CGSize,
    in bounds: CGRect,
    contentMode: CameraContentMode
  ) -> CGRect {
    let safeSourceWidth = max(sourceSize.width, 1.0)
    let safeSourceHeight = max(sourceSize.height, 1.0)
    let scaleX = bounds.width / safeSourceWidth
    let scaleY = bounds.height / safeSourceHeight
    let scale = contentMode == .fit ? min(scaleX, scaleY) : max(scaleX, scaleY)
    let width = safeSourceWidth * scale
    let height = safeSourceHeight * scale
    return CGRect(
      x: bounds.minX + ((bounds.width - width) / 2.0),
      y: bounds.minY + ((bounds.height - height) / 2.0),
      width: width,
      height: height
    )
  }

  private static func resolvedOverlay(origin: CGPoint, size: CGSize) -> CameraLayoutResolution {
    CameraLayoutResolution(
      frame: CGRect(origin: origin, size: size),
      zOrder: .aboveScreen,
      shouldRender: true
    )
  }

  private static func clampedCameraSize(canvasSize: CGSize, sizeFactor: Double) -> CGSize {
    let factor = min(max(sizeFactor, 0.08), 0.45)
    let edge = min(canvasSize.width, canvasSize.height) * factor
    let size = max(96.0, edge)
    return CGSize(width: size, height: size)
  }

  private static func presentationVisualOutset(
    for params: CameraCompositionParams
  ) -> CGFloat {
    let borderOutset = max(0.0, CGFloat(params.borderWidth) / 2.0)
    let shadowOutset: CGFloat
    switch params.shadowPreset {
    case 1:
      shadowOutset = 12.0
    case 2:
      shadowOutset = 20.0
    case 3:
      shadowOutset = 28.0
    default:
      shadowOutset = 0.0
    }

    return max(borderOutset, shadowOutset)
  }

  private static func clamp(frame: CGRect, within canvasSize: CGSize) -> CGRect {
    let width = min(frame.width, canvasSize.width)
    let height = min(frame.height, canvasSize.height)
    let originX = min(max(0.0, frame.minX), max(0.0, canvasSize.width - width))
    let originY = min(max(0.0, frame.minY), max(0.0, canvasSize.height - height))
    return CGRect(x: originX, y: originY, width: width, height: height)
  }

  private static func resolvedCornerRadius(size: CGSize, value: Double) -> CGFloat {
    let clamped = max(0.0, value)
    if clamped <= 1.0 {
      return min(size.width, size.height) * CGFloat(clamped)
    }
    return CGFloat(clamped)
  }

  private static func squirclePath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let radiusX = rect.width / 2.0
    let radiusY = rect.height / 2.0
    let exponent = 4.0
    let stepCount = 64

    for step in 0..<stepCount {
      let angle = (CGFloat(step) / CGFloat(stepCount)) * (.pi * 2.0)
      let cosValue = cos(angle)
      let sinValue = sin(angle)
      let xSign: CGFloat = cosValue < 0 ? -1.0 : 1.0
      let ySign: CGFloat = sinValue < 0 ? -1.0 : 1.0
      let xCurve = CGFloat(pow(Double(abs(cosValue)), 2.0 / exponent))
      let yCurve = CGFloat(pow(Double(abs(sinValue)), 2.0 / exponent))
      let point = CGPoint(
        x: center.x + radiusX * xSign * xCurve,
        y: center.y + radiusY * ySign * yCurve
      )
      if step == 0 {
        path.move(to: point)
      } else {
        path.addLine(to: point)
      }
    }

    path.closeSubpath()
    return path
  }
}
