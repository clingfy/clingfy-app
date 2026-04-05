import CoreGraphics
import Foundation

struct PreviewMediaSources: Equatable {
  let projectPath: String
  let screenPath: String
  let cameraPath: String?
  let metadataPath: String?
  let cursorPath: String?
  let zoomManualPath: String?
}

enum CameraPreviewChangeKind: String, Equatable {
  case none
  case placementJump
  case dragPreview
}

struct CameraCompositionParams: Equatable {
  static let defaultZoomScaleMultiplier = 0.35
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
  var introPreset: CameraIntroPreset = .none
  var outroPreset: CameraOutroPreset = .none
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
    zoomBehavior: .fixed,
    zoomScaleMultiplier: CameraCompositionParams.defaultZoomScaleMultiplier,
    introPreset: .none,
    outroPreset: .none,
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
