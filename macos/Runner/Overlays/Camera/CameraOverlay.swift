import AVFoundation
import AppKit
import CoreImage
import FlutterMacOS

/// A custom view that only captures mouse events within the video frame.
class OverlayInteractiveView: NSView {
  /// The frame of the actual video content (excluding shadow padding)
  var interactiveFrame: CGRect = .zero
  private var initialLocation: NSPoint?
  var onPositionChanged: ((CGPoint, CGPoint?) -> Void)?

  // Helper to calculate normalized center relative to a screen
  private func calculateNormalizedCenter(for windowOrigin: CGPoint) -> CGPoint? {
    guard let window = self.window, let screen = window.screen else { return nil }
    let centerX = windowOrigin.x + (window.frame.width / 2)
    let centerY = windowOrigin.y + (window.frame.height / 2)

    let visibleFrame = screen.visibleFrame
    let nx = (centerX - visibleFrame.minX) / visibleFrame.width
    let ny = (centerY - visibleFrame.minY) / visibleFrame.height

    return CGPoint(x: nx, y: ny)
  }

  // 1. Pass clicks through transparent areas
  override func hitTest(_ point: NSPoint) -> NSView? {
    let localPoint = self.convert(point, from: nil)
    if interactiveFrame.contains(localPoint) {
      return self
    }
    return nil
  }

  // 2. Enable dragging on the video itself
  override func mouseDown(with event: NSEvent) {
    self.initialLocation = event.locationInWindow
    NativeLogger.d("OverlayView", "mouseDown at \(event.locationInWindow)")
  }

  override func mouseDragged(with event: NSEvent) {
    guard let window = self.window, let start = initialLocation, let screen = window.screen else {
      return
    }

    // Use NSEvent.mouseLocation for global coordinates
    let currentLocation = NSEvent.mouseLocation

    // Calculate new origin so that the mouse stays at the same point relative to the window
    let proposedOrigin = CGPoint(
      x: currentLocation.x - start.x,
      y: currentLocation.y - start.y)
    let newOrigin = cameraOverlayClampedOrigin(
      proposedOrigin,
      visibleFrame: screen.visibleFrame,
      windowSize: window.frame.size
    )

    // Log the drag movement (throttling might be needed in high-frequency logs, but useful for debugging)
    // NativeLogger.d("OverlayView", "mouseDragged to \(newOrigin)")

    window.setFrameOrigin(newOrigin)
    let normalized = calculateNormalizedCenter(for: newOrigin)
    onPositionChanged?(newOrigin, normalized)
  }

  override func mouseUp(with event: NSEvent) {
    super.mouseUp(with: event)
    if let window = self.window {
      NativeLogger.i("OverlayView", "Drag finished. Final Window Origin: \(window.frame.origin)")
    }
  }
}

let padding: CGFloat = 6.0

private func clamp01(_ value: CGFloat) -> CGFloat {
  min(max(value, 0.0), 1.0)
}

private func cameraOverlayClampedOrigin(
  _ origin: CGPoint,
  visibleFrame: CGRect,
  windowSize: CGSize
) -> CGPoint {
  let maxX = max(visibleFrame.minX, visibleFrame.maxX - windowSize.width)
  let maxY = max(visibleFrame.minY, visibleFrame.maxY - windowSize.height)
  return CGPoint(
    x: min(max(origin.x, visibleFrame.minX), maxX),
    y: min(max(origin.y, visibleFrame.minY), maxY)
  )
}

private func cameraOverlayClampedNormalizedCenter(
  _ normalizedCenter: CGPoint,
  visibleFrame: CGRect,
  windowSize: CGSize
) -> CGPoint {
  guard visibleFrame.width > 0, visibleFrame.height > 0 else {
    return CGPoint(
      x: clamp01(normalizedCenter.x),
      y: clamp01(normalizedCenter.y)
    )
  }

  let halfWidth = min(0.5, max(0.0, (windowSize.width / 2) / visibleFrame.width))
  let halfHeight = min(0.5, max(0.0, (windowSize.height / 2) / visibleFrame.height))
  let minX = halfWidth
  let maxX = max(minX, 1.0 - halfWidth)
  let minY = halfHeight
  let maxY = max(minY, 1.0 - halfHeight)

  return CGPoint(
    x: min(max(clamp01(normalizedCenter.x), minX), maxX),
    y: min(max(clamp01(normalizedCenter.y), minY), maxY)
  )
}

private func cameraOverlayOrigin(
  forNormalizedCenter normalizedCenter: CGPoint,
  visibleFrame: CGRect,
  windowSize: CGSize
) -> CGPoint {
  let centerX = visibleFrame.minX + (normalizedCenter.x * visibleFrame.width)
  let centerY = visibleFrame.minY + (normalizedCenter.y * visibleFrame.height)
  return CGPoint(
    x: centerX - (windowSize.width / 2),
    y: centerY - (windowSize.height / 2)
  )
}

final class CameraOverlay: NSObject {
  private var deviceId: String?
  private let captureCoordinator: CameraCaptureCoordinator
  private var window: NSWindow?

  private var isCustomPosition: Bool = false
  private var customOrigin: CGPoint = .zero
  private var customNormalizedCenter: CGPoint?  // Relative to screen (0..1)

  var targetDisplayID: CGDirectDisplayID?

  private var activeChromaKeyEnabled: Bool?
  private var activeDeviceId: String?

  // Pipeline A: Standard Preview (Efficient)
  private var preview: AVCaptureVideoPreviewLayer?

  // Pipeline B: Processing (Chroma Key)
  private lazy var ciContext: CIContext = { CIContext() }()
  private lazy var chromaKeyKernel: CIColorKernel? = {
    // Simple RGB distance kernel that accepts a target keyColor
    return CIColorKernel(
      source:
        "kernel vec4 chromaKey(__sample s, vec3 keyColor, float strength) {" + "  vec3 rgb = s.rgb;"
        + "  float dist = distance(rgb, keyColor);"
        + "  float alpha = (dist < strength) ? 0.0 : 1.0;"
        + "  return vec4(rgb, alpha * s.a);" + "}"
    )
  }()

  private var containerLayer: CALayer?  // Holds the video
  private var maskLayer: CAShapeLayer?  // Masks the container
  private var borderLayer: CAShapeLayer?  // Draws the border
  private var shadowLayer: CAShapeLayer?  // Dedicated layer for shadow
  private var ringLayer: CAShapeLayer?  // Glow ring layer

  var preferredSize: Double = 220
  var shape: CameraOverlayShapeID = .defaultValue
  var shadow: Int = 0  // 0: none, 1: light, 2: med, 3: strong
  var border: Int = 0  // 0: none, 1: white, 2: black, 3: green, 4: cyan, 5: custom
  var position: Int = 3  // 0: TL, 1: TR, 2: BL, 3: BR
  var roundness: Double = 0.0
  var opacity: Double = 1.0
  var isMirrored: Bool = true

  var chromaKeyEnabled: Bool = false
  var chromaKeyStrength: Double = 0.4
  var chromaKeyColor: NSColor = .green
  private var chromaKeyColorVector: CIVector = CIVector(x: 0.0, y: 1.0, z: 0.0)

  var borderWidth: CGFloat = 4.0
  var borderColor: NSColor = .white

  var recordingHighlightEnabled: Bool = false  // Track if highlight should be shown
  var recordingHighlightStrength: CGFloat = 0.70  // 0.10 .. 1.00
  var onMovedNormalized: ((Double, Double) -> Void)?

  private let shadowPadding: CGFloat = 6.0

  // Helper to check if currently showing
  var isShowing: Bool {
    return window != nil
  }

  var overlayWindowID: CGWindowID? {
    guard let win = window else { return nil }
    return CGWindowID(win.windowNumber)
  }

  var currentCustomNormalizedCenter: CGPoint? {
    customNormalizedCenter
  }

  init(captureCoordinator: CameraCaptureCoordinator) {
    self.captureCoordinator = captureCoordinator
    super.init()
  }

  convenience override init() {
    self.init(captureCoordinator: CameraCaptureCoordinator())
  }

  func setDevice(id: String?) {
    NativeLogger.i("CameraOverlay", "setDevice: \(id ?? "nil")")
    let changed = (deviceId != id)
    deviceId = id

    if changed && isShowing {
      NativeLogger.d("CameraOverlay", "Device changed while showing, restarting stream...")
      show(size: nil) { _ in }
    }
  }

  func setChromaKeyEnabled(_ enabled: Bool) {
    if chromaKeyEnabled != enabled {
      NativeLogger.i("CameraOverlay", "setChromaKeyEnabled: \(enabled)")
      chromaKeyEnabled = enabled
      if isShowing {
        // Rebuild pipeline to switch between efficient preview and processing output
        show(size: nil) { _ in }
      }
    }
  }

  func setChromaKeyStrength(_ strength: Double) {
    chromaKeyStrength = strength
  }

  func setChromaKeyColor(_ color: NSColor) {
    chromaKeyColor = color
    chromaKeyColorVector = CIVector(
      x: color.redComponent, y: color.greenComponent, z: color.blueComponent)
  }

  func setMirror(_ mirrored: Bool) {
    if isMirrored != mirrored {
      NativeLogger.i("CameraOverlay", "setMirror: \(mirrored)")
      updateMirror(isMirrored: mirrored)
    }
  }

  // New method for highlight
  func setRecordingHighlight(enabled: Bool) {
    NativeLogger.d("CameraOverlay", "setRecordingHighlight: \(enabled)")
    recordingHighlightEnabled = enabled
    updateRingLayer()
  }

  func setRecordingHighlightStrength(_ strength: CGFloat) {
    let clamped = max(0.10, min(1.00, strength))
    recordingHighlightStrength = clamped
    NativeLogger.d(
      "CameraOverlay",
      "setRecordingHighlightStrength",
      context: ["strength": Double(clamped)]
    )
    updateRingLayer()
  }

  func setCustomNormalizedCenter(x: CGFloat, y: CGFloat) {
    var normalizedCenter = CGPoint(x: clamp01(x), y: clamp01(y))
    isCustomPosition = true

    guard let win = window else {
      customNormalizedCenter = normalizedCenter
      NativeLogger.d(
        "CameraOverlay",
        "Stored custom normalized center for next show",
        context: [
          "normalizedX": Double(normalizedCenter.x),
          "normalizedY": Double(normalizedCenter.y),
        ]
      )
      return
    }

    let screenFrame =
      findScreen(for: targetDisplayID)?.visibleFrame ?? win.screen?.visibleFrame
      ?? NSScreen.main?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    normalizedCenter = cameraOverlayClampedNormalizedCenter(
      normalizedCenter,
      visibleFrame: screenFrame,
      windowSize: win.frame.size
    )
    customNormalizedCenter = normalizedCenter
    let newOrigin = cameraOverlayClampedOrigin(
      cameraOverlayOrigin(
        forNormalizedCenter: normalizedCenter,
        visibleFrame: screenFrame,
        windowSize: win.frame.size
      ),
      visibleFrame: screenFrame,
      windowSize: win.frame.size
    )
    customOrigin = newOrigin
    win.setFrameOrigin(newOrigin)
    NativeLogger.d(
      "CameraOverlay",
      "Applied custom normalized center",
      context: [
        "normalizedX": Double(normalizedCenter.x),
        "normalizedY": Double(normalizedCenter.y),
        "originX": Double(newOrigin.x),
        "originY": Double(newOrigin.y),
      ]
    )
  }

  func updateStyle(shape: CameraOverlayShapeID, shadow: Int, border: Int, roundness: Double) {
    self.shape = shape
    self.shadow = shadow
    self.border = border
    self.roundness = roundness

    NativeLogger.d("CameraOverlay", "updateStyle: shape=\(shape), border=\(border)")

    // Update presets if using the legacy enum patterns
    switch border {
    case 1:  // White
      self.borderColor = .white
      if self.borderWidth == 0 { self.borderWidth = 4 }
    case 2:  // Black
      self.borderColor = .black
      if self.borderWidth == 0 { self.borderWidth = 4 }
    case 3:  // Green
      self.borderColor = .green
      if self.borderWidth == 0 { self.borderWidth = 4 }
    case 4:  // Cyan
      self.borderColor = .cyan
      if self.borderWidth == 0 { self.borderWidth = 4 }
    default:
      break
    }

    if isShowing, let win = window {
      applyStyle(
        rootLayer: win.contentView?.layer,
        containerLayer: containerLayer,
        shadowLayer: shadowLayer,
        videoSize: CGFloat(preferredSize)
      )
    }
  }

  func setBorderWidth(_ width: CGFloat) {
    self.borderWidth = width
    if isShowing, let win = window {
      applyStyle(
        rootLayer: win.contentView?.layer, containerLayer: containerLayer, shadowLayer: shadowLayer,
        videoSize: CGFloat(preferredSize))
    }
  }

  func setBorderColor(_ color: NSColor) {
    self.borderColor = color
    if isShowing, let win = window {
      applyStyle(
        rootLayer: win.contentView?.layer, containerLayer: containerLayer, shadowLayer: shadowLayer,
        videoSize: CGFloat(preferredSize))
    }
  }

  private func updateRingLayer() {
    guard let root = window?.contentView?.layer else { return }
    let strength = max(0.10, min(1.00, recordingHighlightStrength))

    if !recordingHighlightEnabled {
      ringLayer?.removeFromSuperlayer()
      ringLayer = nil
      return
    }

    if ringLayer == nil {
      let ring = CAShapeLayer()
      ring.fillColor = NSColor.clear.cgColor
      ring.shadowColor = NSColor.systemRed.cgColor
      ring.shadowOffset = .zero

      root.addSublayer(ring)
      ringLayer = ring
    }

    if let ring = ringLayer {
      ring.removeAnimation(forKey: "pulse")
      ring.lineWidth = 3.0 + (strength * 7.0)
      ring.strokeColor = NSColor.systemRed.withAlphaComponent(0.60 + (0.40 * strength)).cgColor
      ring.shadowOpacity = Float(0.28 + (0.62 * strength))
      ring.shadowRadius = 6.0 + (20.0 * strength)

      let pulse = CABasicAnimation(keyPath: "opacity")
      pulse.fromValue = 0.35 + (0.40 * strength)
      pulse.toValue = min(1.0, 0.70 + (0.30 * strength))
      pulse.duration = 0.95 - (0.35 * strength)
      pulse.autoreverses = true
      pulse.repeatCount = .infinity
      ring.add(pulse, forKey: "pulse")
    }

    // Re-apply style to update path/frame of the ring.
    if let container = containerLayer, let shadow = shadowLayer {
      applyStyle(
        rootLayer: root, containerLayer: container, shadowLayer: shadow,
        videoSize: CGFloat(preferredSize))
    }
  }

  func updateOpacity(_ value: Double) {
    self.opacity = max(0.3, min(1.0, value))
    if isShowing, let win = window {
      applyStyle(
        rootLayer: win.contentView?.layer,
        containerLayer: containerLayer,
        shadowLayer: shadowLayer,
        videoSize: CGFloat(preferredSize)
      )
    }
  }

  func updateMirror(isMirrored: Bool) {
    self.isMirrored = isMirrored
    captureCoordinator.setMirrored(isMirrored)

    // Update Standard Preview
    if let preview = preview {
      applyMirror(to: preview)
    }
  }

  func updatePosition(position: Int) {
    NativeLogger.i(
      "CameraOverlay", "updatePosition: \(position) (Current isCustomPosition: \(isCustomPosition))"
    )

    self.position = position
    self.isCustomPosition = false  // Reset custom flag when grid position is selected
    guard let win = window else {
      NativeLogger.w("CameraOverlay", "updatePosition called but window is nil")
      return
    }

    let contentSize = CGFloat(preferredSize)
    let targetScreen = findScreen(for: targetDisplayID)
    let placementFrame = cameraOverlayPresetPlacementFrame(
      screenFrame: targetScreen?.frame ?? NSScreen.main?.frame,
      visibleFrame: targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame
    )

    let newOrigin = cameraOverlayPresetOrigin(
      for: position,
      contentSize: contentSize,
      shadowPadding: shadowPadding,
      screenFrame: placementFrame
    )

    NativeLogger.d(
      "CameraOverlay", "Moving window to Grid Origin: \(newOrigin) on screen \(placementFrame)")
    win.setFrameOrigin(newOrigin)
  }

  func resize(size: Double) {
    dispatchPrecondition(condition: .onQueue(.main))
    NativeLogger.i("CameraOverlay", "resize to: \(size). isCustomPos: \(isCustomPosition)")
    guard let win = window else { return }

    // 1. Capture the TRUE visual center of the current window
    let centerX = win.frame.midX
    let centerY = win.frame.midY

    // 2. Update size
    preferredSize = max(120, size)
    let contentSize = CGFloat(preferredSize)
    let windowSize = contentSize + (shadowPadding * 2)

    var newOrigin: CGPoint
    let targetScreen = findScreen(for: targetDisplayID)
    let customScreenFrame =
      targetScreen?.visibleFrame ?? win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

    if isCustomPosition {
      if let norm = customNormalizedCenter {
        let normalized = cameraOverlayClampedNormalizedCenter(
          norm,
          visibleFrame: customScreenFrame,
          windowSize: CGSize(width: windowSize, height: windowSize)
        )
        customNormalizedCenter = normalized
        newOrigin = cameraOverlayClampedOrigin(
          cameraOverlayOrigin(
            forNormalizedCenter: normalized,
            visibleFrame: customScreenFrame,
            windowSize: CGSize(width: windowSize, height: windowSize)
          ),
          visibleFrame: customScreenFrame,
          windowSize: CGSize(width: windowSize, height: windowSize)
        )
      } else {
        // Fallback to visual center if normalization isn't available yet
        newOrigin = cameraOverlayClampedOrigin(
          CGPoint(x: centerX - (windowSize / 2), y: centerY - (windowSize / 2)),
          visibleFrame: customScreenFrame,
          windowSize: CGSize(width: windowSize, height: windowSize)
        )
      }
      customOrigin = newOrigin
      NativeLogger.d(
        "CameraOverlay",
        "Resize maintaining Custom Normalized Center: \(String(describing: customNormalizedCenter)) -> NewOrigin: \(newOrigin)"
      )
    } else {
      // Recalculate origin based on current position setting (Grid)
      newOrigin = cameraOverlayPresetOrigin(
        for: position,
        contentSize: contentSize,
        shadowPadding: shadowPadding,
        screenFrame: cameraOverlayPresetPlacementFrame(
          screenFrame: targetScreen?.frame ?? NSScreen.main?.frame,
          visibleFrame: targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame
        )
      )
      NativeLogger.d(
        "CameraOverlay",
        "Resize maintaining Grid Position: \(position) -> NewOrigin: \(newOrigin)"
      )
    }

    // 4. Apply new frame
    let newFrame = NSRect(origin: newOrigin, size: .init(width: windowSize, height: windowSize))
    win.setFrame(newFrame, display: true)

    applyStyle(
      rootLayer: win.contentView?.layer,
      containerLayer: containerLayer,
      shadowLayer: shadowLayer,
      videoSize: contentSize
    )
  }

  // MARK: - Updated Show Method
  func show(
    size: Double?,
    completion: @escaping (FlutterError?) -> Void,
    file: String = #file,
    line: Int = #line
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    NativeLogger.d("CameraOverlay", "Show file= \(file):\(line)")
    let desired = size ?? preferredSize
    NativeLogger.i(
      "CameraOverlay", "SHOW requested. Size: \(desired). DeviceID: \(deviceId ?? "default")")

    // 1. Capture Center BEFORE updating size or destroying window
    if isCustomPosition, let win = window {
      let centerX = win.frame.midX
      let centerY = win.frame.midY
      let newWindowSize = CGFloat(max(120, desired)) + (shadowPadding * 2)

      if let norm = customNormalizedCenter, let targetScreen = findScreen(for: targetDisplayID) {
        let screenFrame = targetScreen.visibleFrame
        let normalized = cameraOverlayClampedNormalizedCenter(
          norm,
          visibleFrame: screenFrame,
          windowSize: CGSize(width: newWindowSize, height: newWindowSize)
        )
        self.customNormalizedCenter = normalized
        self.customOrigin = cameraOverlayClampedOrigin(
          cameraOverlayOrigin(
            forNormalizedCenter: normalized,
            visibleFrame: screenFrame,
            windowSize: CGSize(width: newWindowSize, height: newWindowSize)
          ),
          visibleFrame: screenFrame,
          windowSize: CGSize(width: newWindowSize, height: newWindowSize)
        )
      } else {
        // Fallback to absolute centering on old window if no target screen yet
        self.customOrigin = cameraOverlayClampedOrigin(
          CGPoint(
            x: centerX - (newWindowSize / 2),
            y: centerY - (newWindowSize / 2)
          ),
          visibleFrame: win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero,
          windowSize: CGSize(width: newWindowSize, height: newWindowSize)
        )
      }
      NativeLogger.d(
        "CameraOverlay",
        "Preserving custom position for re-show using NormalizedCenter: \(String(describing: customNormalizedCenter))"
      )
    }

    // 2. Update Size
    let oldPreferredSize = preferredSize
    preferredSize = max(120, desired)
    let videoSize = CGFloat(preferredSize)
    let windowSize = videoSize + (shadowPadding * 2)

    // --- IDEMPOTENCY CHECK ---
    let pipelineChanged =
      (activeChromaKeyEnabled != chromaKeyEnabled) || (activeDeviceId != (deviceId ?? "default"))

    if isShowing, window != nil, !pipelineChanged,
      oldPreferredSize == preferredSize
    {
      NativeLogger.i("CameraOverlay", "show() - resize applied (no rebuild)")
      resize(size: desired)
      completion(nil)
      return
    }

    if pipelineChanged {
      NativeLogger.i(
        "CameraOverlay",
        "show() - pipeline changed (rebuild required). ChromaKey: \(chromaKeyEnabled), Device: \(deviceId ?? "default")"
      )
    }

    if window != nil {
      NativeLogger.d("CameraOverlay", "Window already exists, hiding first.")
      hide()
    }

    do {
      try captureCoordinator.acquirePreview(deviceID: deviceId)
      captureCoordinator.setMirrored(isMirrored)
    } catch let flutterError as FlutterError {
      completion(
        flutterError
      )
      return
    } catch {
      NativeLogger.e("CameraOverlay", "Input Error: \(error.localizedDescription)")
      completion(
        FlutterError(
          code: NativeErrorCode.cameraInputError, message: error.localizedDescription, details: nil)
      )
      return
    }

    // --- Pipeline Selection ---
    if chromaKeyEnabled {
      NativeLogger.d("CameraOverlay", "Setting up ChromaKey Pipeline")
      captureCoordinator.setSampleBufferHandler { [weak self] sampleBuffer in
        self?.processSampleBuffer(sampleBuffer)
      }
    } else {
      NativeLogger.d("CameraOverlay", "Setting up Standard Preview Pipeline")
      captureCoordinator.setSampleBufferHandler(nil)
      let layer = captureCoordinator.makePreviewLayer()
      layer.videoGravity = .resizeAspectFill
      applyMirror(to: layer)
      self.preview = layer
    }

    // --- PIPELINE ORIGIN ---
    var origin: CGPoint
    let targetScreen = findScreen(for: targetDisplayID)
    let customScreenFrame =
      targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let placementFrame = cameraOverlayPresetPlacementFrame(
      screenFrame: targetScreen?.frame ?? NSScreen.main?.frame,
      visibleFrame: targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame
    )

    if isCustomPosition {
      if let norm = customNormalizedCenter {
        let normalized = cameraOverlayClampedNormalizedCenter(
          norm,
          visibleFrame: customScreenFrame,
          windowSize: CGSize(width: windowSize, height: windowSize)
        )
        customNormalizedCenter = normalized
        origin = cameraOverlayClampedOrigin(
          cameraOverlayOrigin(
            forNormalizedCenter: normalized,
            visibleFrame: customScreenFrame,
            windowSize: CGSize(width: windowSize, height: windowSize)
          ),
          visibleFrame: customScreenFrame,
          windowSize: CGSize(width: windowSize, height: windowSize)
        )
      } else {
        origin = cameraOverlayClampedOrigin(
          customOrigin,
          visibleFrame: customScreenFrame,
          windowSize: CGSize(width: windowSize, height: windowSize)
        )
      }
      NativeLogger.d("CameraOverlay", "Using Custom Origin (re-mapped): \(origin)")
    } else {
      origin = cameraOverlayPresetOrigin(
        for: position,
        contentSize: videoSize,
        shadowPadding: shadowPadding,
        screenFrame: placementFrame
      )
      NativeLogger.d(
        "CameraOverlay",
        "Using Grid Origin: \(origin) on screen \(placementFrame) (Position index: \(position))")
    }

    let panel = NSPanel(
      contentRect: NSRect(origin: origin, size: .init(width: windowSize, height: windowSize)),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered, defer: false)

    panel.hasShadow = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear

    // --- FIX 2: DISABLE WINDOW BACKGROUND DRAGGING ---
    panel.isMovableByWindowBackground = false

    panel.ignoresMouseEvents = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    // --- FIX 3: USE CUSTOM INTERACTIVE VIEW ---
    let view = OverlayInteractiveView(
      frame: NSRect(x: 0, y: 0, width: windowSize, height: windowSize))
    view.wantsLayer = true
    view.onPositionChanged = { [weak self] newOrigin, normalized in
      self?.isCustomPosition = true
      self?.customOrigin = newOrigin
      if let normalized = normalized {
        let nx = max(0.0, min(1.0, normalized.x))
        let ny = max(0.0, min(1.0, normalized.y))
        self?.customNormalizedCenter = CGPoint(x: nx, y: ny)
        self?.onMovedNormalized?(Double(nx), Double(ny))
      }
      // NativeLogger.d(
      //   "CameraOverlay",
      //   "User moved overlay to: \(newOrigin) (Normalized: \(String(describing: normalized)))")
    }

    let rootLayer = CALayer()
    rootLayer.frame = view.bounds
    rootLayer.masksToBounds = false
    view.layer = rootLayer

    // Layout Layers
    let videoFrame = CGRect(x: shadowPadding, y: shadowPadding, width: videoSize, height: videoSize)

    // Pass the interactive frame to the custom view so it knows where to accept clicks
    view.interactiveFrame = videoFrame

    // Shadow Layer
    let shadowL = CAShapeLayer()
    shadowL.frame = videoFrame
    shadowL.fillColor = NSColor.black.cgColor
    shadowL.masksToBounds = false
    rootLayer.addSublayer(shadowL)

    // Container Layer
    let container = CALayer()
    container.frame = videoFrame
    container.masksToBounds = true
    rootLayer.addSublayer(container)

    // Video Layer / Visuals
    if chromaKeyEnabled {
      container.backgroundColor = NSColor.clear.cgColor
      container.contentsGravity = .resizeAspectFill
    } else {
      // Standard Preview Layer
      if let preview = self.preview {
        preview.frame = container.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        container.addSublayer(preview)
      }
    }

    panel.contentView = view

    self.window = panel
    self.containerLayer = container
    self.shadowLayer = shadowL

    let mask = CAShapeLayer()
    container.mask = mask
    self.maskLayer = mask

    let border = CAShapeLayer()
    border.fillColor = nil
    rootLayer.addSublayer(border)
    self.borderLayer = border

    applyStyle(
      rootLayer: rootLayer, containerLayer: container, shadowLayer: shadowL, videoSize: videoSize)

    // Re-apply highlight state just in case we are rebuilding while recording
    updateRingLayer()

    NativeLogger.i("CameraOverlay", "Window constructed & Ordered Front. Starting session...")
    panel.orderFrontRegardless()

    // Update active state tracking
    self.activeChromaKeyEnabled = chromaKeyEnabled
    self.activeDeviceId = deviceId ?? "default"

    completion(nil)
  }

  private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
    guard chromaKeyEnabled, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }
    // Logging here is dangerous (60fps flood). Uncomment only if debugging image processing failure.
    // NativeLogger.d("CameraOverlay", "Frame received for processing")

    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

    // Apply Filter
    var processedImage: CIImage?
    if let kernel = chromaKeyKernel {
      processedImage = kernel.apply(
        extent: ciImage.extent,
        arguments: [ciImage, chromaKeyColorVector, Float(chromaKeyStrength)])
    } else {
      processedImage = ciImage
    }

    guard let outputImage = processedImage else { return }

    if let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) {
      DispatchQueue.main.async { [weak self] in
        // Only update if we are still showing and mode is correct
        guard let self = self, self.isShowing, self.chromaKeyEnabled else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.containerLayer?.contents = cgImage
        CATransaction.commit()
      }
    }
  }

  func hide() {
    dispatchPrecondition(condition: .onQueue(.main))
    NativeLogger.i("CameraOverlay", "Hide called")
    captureCoordinator.setSampleBufferHandler(nil)
    captureCoordinator.removePreviewLayer(preview)
    captureCoordinator.releasePreview()
    preview?.removeFromSuperlayer()
    preview = nil

    containerLayer?.contents = nil
    containerLayer?.removeFromSuperlayer()
    containerLayer = nil
    maskLayer = nil
    borderLayer?.removeFromSuperlayer()
    borderLayer = nil
    shadowLayer?.removeFromSuperlayer()
    shadowLayer = nil
    ringLayer?.removeFromSuperlayer()
    ringLayer = nil

    if let win = window {
      NativeLogger.d("CameraOverlay", "Ordering window out")
      win.orderOut(nil)
    }
    window = nil
  }

  func setFrame(x: Double, y: Double, width: Double, height: Double) {
    dispatchPrecondition(condition: .onQueue(.main))
    NativeLogger.i("CameraOverlay", "setFrame explicit: x=\(x), y=\(y), w=\(width)")
    guard let win = window else { return }
    var f = win.frame
    f.origin = .init(x: x, y: y)
    f.size = .init(width: width, height: height)
    win.setFrame(f, display: true)

    let vSize = CGFloat(width) - (shadowPadding * 2)
    preferredSize = Double(max(10, vSize))

    applyStyle(
      rootLayer: win.contentView?.layer,
      containerLayer: containerLayer,
      shadowLayer: shadowLayer,
      videoSize: vSize
    )
  }

  // MARK: - Updated ApplyStyle
  private func applyStyle(
    rootLayer: CALayer?, containerLayer: CALayer?, shadowLayer: CAShapeLayer?, videoSize: CGFloat
  ) {
    guard let container = containerLayer, let shadowL = shadowLayer else { return }

    NativeLogger.d("CameraOverlay", "Applying Style. VideoSize: \(videoSize)")

    let frame = CGRect(x: shadowPadding, y: shadowPadding, width: videoSize, height: videoSize)
    shadowL.frame = frame
    container.frame = frame
    borderLayer?.frame = frame

    // Update the hit-test area in case size changed
    if let overlayView = window?.contentView as? OverlayInteractiveView {
      overlayView.interactiveFrame = frame
    }

    // ... (Rest of styling logic remains the same) ...
    let bounds = CGRect(origin: .zero, size: frame.size)
    let path = getPath(for: shape, rect: bounds)

    maskLayer?.path = path
    maskLayer?.frame = bounds

    shadowL.path = path
    shadowL.cornerRadius = 0
    shadowL.shadowPath = path
    shadowL.shadowColor = NSColor.black.cgColor

    switch shadow {
    case 1:
      shadowL.shadowOpacity = 0.30
      shadowL.shadowRadius = 6
      shadowL.shadowOffset = CGSize(width: 0, height: -2)
    case 2:
      shadowL.shadowOpacity = 0.45
      shadowL.shadowRadius = 12
      shadowL.shadowOffset = CGSize(width: 0, height: -5)
    case 3:
      shadowL.shadowOpacity = 0.70
      shadowL.shadowRadius = 20
      shadowL.shadowOffset = CGSize(width: 0, height: -10)
    default:
      shadowL.shadowOpacity = 0
    }

    // 4. Border (Top)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if let bLayer = borderLayer {
      bLayer.path = path
      bLayer.fillColor = nil

      if border == 0 {
        bLayer.strokeColor = nil
        bLayer.lineWidth = 0
      } else {
        bLayer.strokeColor = borderColor.cgColor
        bLayer.lineWidth = borderWidth
      }

      bLayer.opacity = Float(opacity)
      bLayer.zPosition = 100
    }
    CATransaction.commit()

    container.opacity = Float(opacity)

    if let rLayer = ringLayer {
      rLayer.frame = frame
      rLayer.path = path
    }
  }

  func getPath(for shape: CameraOverlayShapeID, rect: CGRect) -> CGPath {
    let r = rect.width * CGFloat(roundness)

    switch shape {
    case .circle:
      return CGPath(ellipseIn: rect, transform: nil)
    case .roundedRect:
      return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    case .square:
      return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    case .hexagon:
      var points: [CGPoint] = []
      let center = CGPoint(x: rect.midX, y: rect.midY)
      let radius = min(rect.width, rect.height) / 2.0
      for i in 0..<6 {
        let angle = (CGFloat(i) * 60.0 - 30.0) * .pi / 180.0
        points.append(
          CGPoint(
            x: center.x + radius * cos(angle),
            y: center.y + radius * sin(angle)
          ))
      }
      return createRoundedPath(points: points, radius: r)
    case .star:
      var points: [CGPoint] = []
      let center = CGPoint(x: rect.midX, y: rect.midY)
      let outerRadius = min(rect.width, rect.height) / 2.0
      let innerRadius = outerRadius * 0.4
      let angleStep = .pi / 5.0
      var angle = -CGFloat.pi / 2.0
      for i in 0..<10 {
        let rad = (i % 2 == 0) ? outerRadius : innerRadius
        points.append(
          CGPoint(
            x: center.x + rad * cos(angle),
            y: center.y + rad * sin(angle)
          ))
        angle += angleStep
      }
      // Scale radius down for star to avoid artifacts at inner corners
      return createRoundedPath(points: points, radius: r * 0.3)
    case .squircle:
      return createSquirclePath(in: rect)
    }
  }

  func createSquirclePath(in rect: CGRect) -> CGPath {
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
      let x =
        center.x
        + radiusX * xSign * xCurve
      let y =
        center.y
        + radiusY * ySign * yCurve
      let point = CGPoint(x: x, y: y)
      if step == 0 {
        path.move(to: point)
      } else {
        path.addLine(to: point)
      }
    }

    path.closeSubpath()
    return path
  }

  private func createRoundedPath(points: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    if points.isEmpty { return path }

    if radius <= 0 {
      path.move(to: points[0])
      for i in 1..<points.count {
        path.addLine(to: points[i])
      }
      path.closeSubpath()
      return path
    }

    let pLast = points.last!
    let pFirst = points[0]
    let mid = CGPoint(x: (pLast.x + pFirst.x) / 2, y: (pLast.y + pFirst.y) / 2)
    path.move(to: mid)

    for i in 0..<points.count {
      let current = points[i]
      let next = points[(i + 1) % points.count]
      path.addArc(tangent1End: current, tangent2End: next, radius: radius)
    }
    path.closeSubpath()
    return path
  }

  private func applyMirror(to layer: AVCaptureVideoPreviewLayer) {
    if let connection = layer.connection, connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = isMirrored
    } else {
      // Fallback using transform if needed
      let flipX: CGFloat = isMirrored ? -1.0 : 1.0
      layer.setAffineTransform(CGAffineTransform(scaleX: flipX, y: 1.0))
    }
  }

  private func findScreen(for displayID: CGDirectDisplayID?) -> NSScreen? {
    guard let id = displayID else { return nil }
    return NSScreen.screens.first {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        == id
    }
  }
}

func cameraOverlayPresetOrigin(
  for pos: Int, contentSize: CGFloat, shadowPadding: CGFloat, screenFrame: CGRect? = nil
) -> CGPoint {
  let screen =
    screenFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

  // Debug logic for coordinates (Optional, disabled by default to avoid noise)
  NativeLogger.d(
    "CameraOverlay", "cameraOverlayPresetOrigin: pos=\(pos), contentSize=\(contentSize), screen=\(screen)"
  )

  // We calculate where the *visual* edge should be, then offset the window origin
  // by the shadowPadding amount to align the content, not the container.

  switch pos {
  case 0:  // Top-Left
    // X: Start at minX + padding, then shift LEFT by shadowPadding because window starts before content
    let x = screen.minX + padding - shadowPadding
    // Y: Start at maxY - padding, then shift DOWN by (content height + shadowPadding)
    let y = screen.maxY - padding - contentSize - shadowPadding
    return CGPoint(x: x, y: y)

  case 1:  // Top-Right
    // X: Start at maxX - padding - content width, shift LEFT by shadowPadding
    let x = screen.maxX - padding - contentSize - shadowPadding
    let y = screen.maxY - padding - contentSize - shadowPadding
    return CGPoint(x: x, y: y)

  case 2:  // Bottom-Left
    let x = screen.minX + padding - shadowPadding
    // Y: Start at minY + padding, shift DOWN by shadowPadding to align bottom visual edge
    let y = screen.minY + padding - shadowPadding
    return CGPoint(x: x, y: y)

  case 3:  // Bottom-Right
    let x = screen.maxX - padding - contentSize - shadowPadding
    let y = screen.minY + padding - shadowPadding
    return CGPoint(x: x, y: y)

  default:
    return CGPoint(
      x: screen.maxX - padding - contentSize - shadowPadding,
      y: screen.minY + padding - shadowPadding
    )
  }
}

func cameraOverlayPresetPlacementFrame(screenFrame: CGRect?, visibleFrame: CGRect?) -> CGRect {
  switch (screenFrame, visibleFrame) {
  case let (screen?, visible?):
    return CGRect(
      x: visible.minX,
      y: visible.minY,
      width: visible.width,
      height: screen.maxY - visible.minY
    )
  case let (screen?, nil):
    return screen
  case let (nil, visible?):
    return visible
  case (nil, nil):
    return NSRect(x: 0, y: 0, width: 1440, height: 900)
  }
}
