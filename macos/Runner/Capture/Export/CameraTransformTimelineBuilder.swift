import CoreGraphics
import Foundation

// Resolves camera-only time-varying geometry that belongs in the final composition stage.
struct CameraTransformResolution: Equatable {
  let frame: CGRect
  let scale: CGFloat
}

enum CameraTransformTimelineBuilder {
  static func resolve(
    baseResolution: CameraLayoutResolution,
    cameraParams: CameraCompositionParams,
    screenZoom: CGFloat
  ) -> CameraTransformResolution {
    guard baseResolution.shouldRender else {
      return CameraTransformResolution(frame: .zero, scale: 1.0)
    }

    let scale = resolvedScale(
      layoutPreset: cameraParams.layoutPreset,
      behavior: cameraParams.zoomBehavior,
      multiplier: cameraParams.zoomScaleMultiplier,
      screenZoom: screenZoom
    )

    guard scale != 1.0 else {
      return CameraTransformResolution(frame: baseResolution.frame, scale: 1.0)
    }

    let baseFrame = baseResolution.frame
    let scaledSize = CGSize(
      width: baseFrame.width * scale,
      height: baseFrame.height * scale
    )
    let scaledFrame = CGRect(
      x: baseFrame.midX - (scaledSize.width / 2.0),
      y: baseFrame.midY - (scaledSize.height / 2.0),
      width: scaledSize.width,
      height: scaledSize.height
    )

    return CameraTransformResolution(frame: scaledFrame, scale: scale)
  }

  static func resolvedScale(
    layoutPreset: CameraLayoutPreset,
    behavior: CameraZoomBehavior,
    multiplier: Double,
    screenZoom: CGFloat
  ) -> CGFloat {
    guard layoutPreset != .backgroundBehind else { return 1.0 }
    guard behavior == .scaleWithScreenZoom else { return 1.0 }

    let clampedScreenZoom = max(1.0, screenZoom)
    let clampedMultiplier = CGFloat(min(max(multiplier, 0.0), 1.0))
    return 1.0 + ((clampedScreenZoom - 1.0) * clampedMultiplier)
  }
}
