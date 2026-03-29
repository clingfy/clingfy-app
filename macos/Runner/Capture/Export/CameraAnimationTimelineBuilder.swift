import CoreGraphics
import Foundation

// Resolves camera presentation effects after the base layout and zoom-size geometry are known.
struct CameraAnimationZoomState: Equatable {
  let isActive: Bool
  let localTime: Double?

  static let inactive = CameraAnimationZoomState(isActive: false, localTime: nil)
}

struct CameraAnimationResolution: Equatable {
  let frame: CGRect
  let opacity: CGFloat
  let additionalScale: CGFloat
  let translation: CGPoint
  let shouldBypass: Bool
}

enum CameraAnimationTimelineBuilder {
  private static let slideMargin: CGFloat = 1.0
  private static let pulseFrequencyHz = 2.0

  static func resolvePresentation(
    canvasSize: CGSize,
    baseResolution: CameraLayoutResolution,
    cameraParams: CameraCompositionParams,
    screenZoom: CGFloat,
    time: Double,
    totalDuration: Double,
    zoomState: CameraAnimationZoomState = .inactive
  ) -> CameraAnimationResolution {
    let transformed = CameraTransformTimelineBuilder.resolve(
      baseResolution: baseResolution,
      cameraParams: cameraParams,
      screenZoom: screenZoom
    )
    return resolve(
      canvasSize: canvasSize,
      baseResolution: baseResolution,
      transformedResolution: transformed,
      cameraParams: cameraParams,
      time: time,
      totalDuration: totalDuration,
      zoomState: zoomState
    )
  }

  static func resolve(
    canvasSize: CGSize,
    baseResolution: CameraLayoutResolution,
    transformedResolution: CameraTransformResolution,
    cameraParams: CameraCompositionParams,
    time: Double,
    totalDuration: Double,
    zoomState: CameraAnimationZoomState = .inactive
  ) -> CameraAnimationResolution {
    let clampedTime = min(max(time, 0.0), max(totalDuration, 0.0))
    let baseFrame = transformedResolution.frame
    let baseOpacity = CGFloat(max(0.0, min(1.0, cameraParams.opacity)))

    guard
      baseResolution.shouldRender,
      cameraParams.layoutPreset != .backgroundBehind,
      cameraParams.layoutPreset != .hidden
    else {
      return CameraAnimationResolution(
        frame: baseFrame,
        opacity: baseOpacity,
        additionalScale: 1.0,
        translation: .zero,
        shouldBypass: true
      )
    }

    let introOpacity = introOpacity(
      preset: cameraParams.introPreset,
      time: clampedTime,
      durationMs: cameraParams.introDurationMs
    )
    let outroOpacity = outroOpacity(
      preset: cameraParams.outroPreset,
      time: clampedTime,
      totalDuration: totalDuration,
      durationMs: cameraParams.outroDurationMs
    )

    let introScale = introScale(
      preset: cameraParams.introPreset,
      time: clampedTime,
      durationMs: cameraParams.introDurationMs
    )
    let outroScale = outroScale(
      preset: cameraParams.outroPreset,
      time: clampedTime,
      totalDuration: totalDuration,
      durationMs: cameraParams.outroDurationMs
    )
    let pulseScale = pulseScale(
      preset: cameraParams.zoomEmphasisPreset,
      strength: cameraParams.zoomEmphasisStrength,
      zoomState: zoomState
    )

    let additionalScale = introScale * outroScale * pulseScale
    var resolvedFrame = scaled(frame: baseFrame, by: additionalScale)

    let slideEdge = resolvedSlideEdge(
      layoutPreset: cameraParams.layoutPreset,
      baseFrame: baseResolution.frame,
      canvasSize: canvasSize,
      isManualPositioned: cameraParams.normalizedCanvasCenter != nil
    )
    let translation = CGPoint(
      x: introTranslation(
        preset: cameraParams.introPreset,
        frame: resolvedFrame,
        canvasSize: canvasSize,
        edge: slideEdge,
        time: clampedTime,
        durationMs: cameraParams.introDurationMs
      ).x + outroTranslation(
        preset: cameraParams.outroPreset,
        frame: resolvedFrame,
        canvasSize: canvasSize,
        edge: slideEdge,
        time: clampedTime,
        totalDuration: totalDuration,
        durationMs: cameraParams.outroDurationMs
      ).x,
      y: introTranslation(
        preset: cameraParams.introPreset,
        frame: resolvedFrame,
        canvasSize: canvasSize,
        edge: slideEdge,
        time: clampedTime,
        durationMs: cameraParams.introDurationMs
      ).y + outroTranslation(
        preset: cameraParams.outroPreset,
        frame: resolvedFrame,
        canvasSize: canvasSize,
        edge: slideEdge,
        time: clampedTime,
        totalDuration: totalDuration,
        durationMs: cameraParams.outroDurationMs
      ).y
    )

    resolvedFrame = resolvedFrame.offsetBy(dx: translation.x, dy: translation.y)

    return CameraAnimationResolution(
      frame: resolvedFrame,
      opacity: max(0.0, min(1.0, baseOpacity * introOpacity * outroOpacity)),
      additionalScale: additionalScale,
      translation: translation,
      shouldBypass: false
    )
  }

  static func hasPresentationEffects(_ params: CameraCompositionParams) -> Bool {
    params.introPreset != .none
      || params.outroPreset != .none
      || params.zoomEmphasisPreset != .none
  }

  private enum SlideEdge {
    case left
    case right
    case top
    case bottom
  }

  private static func resolvedSlideEdge(
    layoutPreset: CameraLayoutPreset,
    baseFrame: CGRect,
    canvasSize: CGSize,
    isManualPositioned: Bool
  ) -> SlideEdge {
    guard isManualPositioned else {
      switch layoutPreset {
      case .overlayTopLeft, .overlayBottomLeft, .sideBySideLeft:
        return .left
      case .overlayTopRight, .overlayBottomRight, .sideBySideRight:
        return .right
      case .stackedTop:
        return .top
      case .stackedBottom:
        return .bottom
      case .backgroundBehind, .hidden:
        return .right
      }
    }

    let center = CGPoint(x: baseFrame.midX, y: baseFrame.midY)
    let leftDistance = center.x
    let rightDistance = max(canvasSize.width - center.x, 0.0)
    let bottomDistance = center.y
    let topDistance = max(canvasSize.height - center.y, 0.0)
    let minHorizontal = min(leftDistance, rightDistance)
    let minVertical = min(bottomDistance, topDistance)

    if minHorizontal <= minVertical {
      return leftDistance <= rightDistance ? .left : .right
    }
    return bottomDistance <= topDistance ? .bottom : .top
  }

  private static func introOpacity(
    preset: CameraIntroPreset,
    time: Double,
    durationMs: Int
  ) -> CGFloat {
    guard preset != .none else { return 1.0 }
    let progress = normalizedProgress(time: time, durationMs: durationMs)
    switch preset {
    case .none:
      return 1.0
    case .fade, .pop, .slide:
      return CGFloat(progress)
    }
  }

  private static func outroOpacity(
    preset: CameraOutroPreset,
    time: Double,
    totalDuration: Double,
    durationMs: Int
  ) -> CGFloat {
    guard preset != .none else { return 1.0 }
    let progress = normalizedOutroProgress(time: time, totalDuration: totalDuration, durationMs: durationMs)
    switch preset {
    case .none:
      return 1.0
    case .fade, .shrink, .slide:
      return CGFloat(1.0 - progress)
    }
  }

  private static func introScale(
    preset: CameraIntroPreset,
    time: Double,
    durationMs: Int
  ) -> CGFloat {
    guard preset == .pop else { return 1.0 }
    let eased = easeOutCubic(normalizedProgress(time: time, durationMs: durationMs))
    return CGFloat(lerp(from: 0.90, to: 1.0, progress: eased))
  }

  private static func outroScale(
    preset: CameraOutroPreset,
    time: Double,
    totalDuration: Double,
    durationMs: Int
  ) -> CGFloat {
    guard preset == .shrink else { return 1.0 }
    let eased = easeInCubic(
      normalizedOutroProgress(time: time, totalDuration: totalDuration, durationMs: durationMs)
    )
    return CGFloat(lerp(from: 1.0, to: 0.90, progress: eased))
  }

  private static func pulseScale(
    preset: CameraZoomEmphasisPreset,
    strength: Double,
    zoomState: CameraAnimationZoomState
  ) -> CGFloat {
    guard preset == .pulse, zoomState.isActive, let localTime = zoomState.localTime else {
      return 1.0
    }
    let clampedStrength = min(max(strength, 0.0), 0.20)
    let phase = 2.0 * Double.pi * pulseFrequencyHz * max(localTime, 0.0)
    return CGFloat(1.0 + (clampedStrength * 0.5 * (1.0 - cos(phase))))
  }

  private static func introTranslation(
    preset: CameraIntroPreset,
    frame: CGRect,
    canvasSize: CGSize,
    edge: SlideEdge,
    time: Double,
    durationMs: Int
  ) -> CGPoint {
    guard preset == .slide else { return .zero }
    let progress = normalizedProgress(time: time, durationMs: durationMs)
    let eased = easeOutCubic(progress)
    let target = offscreenFrame(for: frame, canvasSize: canvasSize, edge: edge)
    return CGPoint(
      x: CGFloat(lerp(from: Double(target.minX - frame.minX), to: 0.0, progress: eased)),
      y: CGFloat(lerp(from: Double(target.minY - frame.minY), to: 0.0, progress: eased))
    )
  }

  private static func outroTranslation(
    preset: CameraOutroPreset,
    frame: CGRect,
    canvasSize: CGSize,
    edge: SlideEdge,
    time: Double,
    totalDuration: Double,
    durationMs: Int
  ) -> CGPoint {
    guard preset == .slide else { return .zero }
    let progress = normalizedOutroProgress(time: time, totalDuration: totalDuration, durationMs: durationMs)
    let eased = easeInCubic(progress)
    let target = offscreenFrame(for: frame, canvasSize: canvasSize, edge: edge)
    return CGPoint(
      x: CGFloat(lerp(from: 0.0, to: Double(target.minX - frame.minX), progress: eased)),
      y: CGFloat(lerp(from: 0.0, to: Double(target.minY - frame.minY), progress: eased))
    )
  }

  private static func normalizedProgress(time: Double, durationMs: Int) -> Double {
    let duration = max(Double(durationMs) / 1000.0, 0.0001)
    return min(max(time / duration, 0.0), 1.0)
  }

  private static func normalizedOutroProgress(
    time: Double,
    totalDuration: Double,
    durationMs: Int
  ) -> Double {
    let duration = max(Double(durationMs) / 1000.0, 0.0001)
    let start = max(totalDuration - duration, 0.0)
    return min(max((time - start) / duration, 0.0), 1.0)
  }

  private static func scaled(frame: CGRect, by scale: CGFloat) -> CGRect {
    guard abs(scale - 1.0) > 0.0001 else { return frame }
    let scaledSize = CGSize(width: frame.width * scale, height: frame.height * scale)
    return CGRect(
      x: frame.midX - (scaledSize.width / 2.0),
      y: frame.midY - (scaledSize.height / 2.0),
      width: scaledSize.width,
      height: scaledSize.height
    )
  }

  private static func offscreenFrame(
    for frame: CGRect,
    canvasSize: CGSize,
    edge: SlideEdge
  ) -> CGRect {
    switch edge {
    case .left:
      return frame.offsetBy(dx: -(frame.maxX + slideMargin), dy: 0.0)
    case .right:
      return CGRect(
        x: canvasSize.width + slideMargin,
        y: frame.minY,
        width: frame.width,
        height: frame.height
      )
    case .top:
      return CGRect(
        x: frame.minX,
        y: canvasSize.height + slideMargin,
        width: frame.width,
        height: frame.height
      )
    case .bottom:
      return CGRect(
        x: frame.minX,
        y: -(frame.height + slideMargin),
        width: frame.width,
        height: frame.height
      )
    }
  }

  private static func lerp(from: Double, to: Double, progress: Double) -> Double {
    from + ((to - from) * progress)
  }

  private static func easeOutCubic(_ value: Double) -> Double {
    1.0 - pow(1.0 - value, 3.0)
  }

  private static func easeInCubic(_ value: Double) -> Double {
    pow(value, 3.0)
  }
}
