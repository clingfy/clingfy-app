import Cocoa

enum IndicatorState {
  case hidden
  case recording
  case paused
  case stopping
}

final class RecordingIndicatorView: NSView {
  private let dot = CAShapeLayer()
  private let stopIconLayer = CAShapeLayer()
  private let elapsedLabel = CATextLayer()

  // Idle content
  private let idleContainer = CALayer()
  private let dotsReplicator = CAReplicatorLayer()
  private let baseDot = CAShapeLayer()

  // Injected by ScreenRecorder
  var elapsedProvider: (() -> String)?
  var onStopTapped: (() -> Void)?
  var onResumeTapped: (() -> Void)?

  // State
  var state: IndicatorState = .hidden {
    didSet {
      updateUIForState()
    }
  }

  private let spinner = NSProgressIndicator()
  private let stoppingLabel = CATextLayer()

  // Timers
  private var tickTimer: Timer?

  // Cache the dot rect for hit testing
  private var dotHitRect: CGRect = .zero

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true

    // --- Container Styling ---
    // Polished background, slightly more opaque
    layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
    layer?.borderWidth = 0
    layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    layer?.masksToBounds = true
    // cornerRadius is set in layout() to ensure pill shape

    // --- Red Status Dot ---
    dot.fillColor = NSColor.systemRed.cgColor
    layer?.addSublayer(dot)

    // --- Stop Icon (white square inside dot) ---
    stopIconLayer.fillColor = NSColor.white.cgColor
    stopIconLayer.opacity = 1.0
    stopIconLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    dot.addSublayer(stopIconLayer)

    // --- Elapsed Timer Label (Always visible during recording) ---
    elapsedLabel.string = "00:00:00"
    elapsedLabel.opacity = 0
    elapsedLabel.alignmentMode = .left
    elapsedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    elapsedLabel.fontSize = 15
    elapsedLabel.foregroundColor = NSColor.labelColor.cgColor
    elapsedLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    layer?.addSublayer(elapsedLabel)

    // --- Stopping State UI ---
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    addSubview(spinner)

    stoppingLabel.string = "Stopping..."
    stoppingLabel.opacity = 0
    stoppingLabel.alignmentMode = .left
    stoppingLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
    stoppingLabel.fontSize = 15
    stoppingLabel.foregroundColor = NSColor.secondaryLabelColor.cgColor
    stoppingLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    layer?.addSublayer(stoppingLabel)
  }

  required init?(coder: NSCoder) { fatalError() }

  // MARK: - Mouse Events

  override func mouseDown(with event: NSEvent) {
    guard state == .recording || state == .paused else { return }
    let p = convert(event.locationInWindow, from: nil)
    if dotHitRect.contains(p) {
      animateDotTap()
      switch state {
      case .recording:
        onStopTapped?()
      case .paused:
        onResumeTapped?()
      case .hidden, .stopping:
        break
      }
      return
    }
    super.mouseDown(with: event)
  }

  private func animateDotTap() {
    // Quick scale down/up to feel like a button press
    let anim = CAKeyframeAnimation(keyPath: "transform.scale")
    anim.values = [1.0, 0.85, 1.0]
    anim.keyTimes = [0, 0.5, 1]
    anim.duration = 0.15
    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    dot.add(anim, forKey: "tap")
  }

  private func updateUIForState() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    switch state {
    case .hidden:
      stopTicking()
      elapsedLabel.opacity = 0
      stoppingLabel.opacity = 0
      spinner.stopAnimation(nil)
      dot.opacity = 0

    case .recording:
      startTicking()
      elapsedLabel.opacity = 1
      stoppingLabel.opacity = 0
      spinner.stopAnimation(nil)
      dot.opacity = 1
      dot.fillColor = NSColor.systemRed.cgColor
      updateElapsedText()
      updateIconPath()

    case .paused:
      stopTicking()
      elapsedLabel.opacity = 1
      stoppingLabel.opacity = 0
      spinner.stopAnimation(nil)
      dot.opacity = 1
      dot.fillColor = NSColor.systemOrange.cgColor
      updateIconPath()

    case .stopping:
      stopTicking()
      elapsedLabel.opacity = 0
      stoppingLabel.opacity = 1
      spinner.startAnimation(nil)
      dot.opacity = 0  // Hide stop button in stopping state
    }

    CATransaction.commit()
    needsLayout = true
  }

  private func updateIconPath() {
    needsLayout = true
  }

  // MARK: - Layout

  override func layout() {
    super.layout()
    guard let layer = self.layer else { return }

    let h = bounds.height
    // Capsule shape
    layer.cornerRadius = h / 2

    // --- Dot Layout (Stop Button Area) ---
    let s: CGFloat = 20  // Larger dot
    let dotX: CGFloat = 12
    let dotFrame = CGRect(x: dotX, y: (h - s) / 2, width: s, height: s)

    dot.frame = dotFrame
    dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)

    // Hit rect slightly larger for easier clicking
    dotHitRect = dotFrame.insetBy(dx: -10, dy: -10)

    // --- Stop Icon (inside Dot) ---
    let iconPath = CGMutablePath()
    switch state {
    case .paused:
      let barWidth: CGFloat = 4
      let barHeight: CGFloat = 10
      let gap: CGFloat = 3
      let totalWidth = barWidth * 2 + gap
      let startX = (s - totalWidth) / 2
      let y = (s - barHeight) / 2
      iconPath.addRoundedRect(
        in: CGRect(x: startX, y: y, width: barWidth, height: barHeight),
        cornerWidth: 1,
        cornerHeight: 1
      )
      iconPath.addRoundedRect(
        in: CGRect(x: startX + barWidth + gap, y: y, width: barWidth, height: barHeight),
        cornerWidth: 1,
        cornerHeight: 1
      )
    case .recording, .hidden, .stopping:
      let iconS: CGFloat = 8
      let iconRect = CGRect(x: (s - iconS) / 2, y: (s - iconS) / 2, width: iconS, height: iconS)
      iconPath.addRoundedRect(in: iconRect, cornerWidth: 1.5, cornerHeight: 1.5)
    }
    stopIconLayer.path = iconPath

    // --- Labels & Spinner Layout ---
    let textX = dotFrame.maxX + 10
    let labelW = bounds.width - textX - 12
    let lineHeight: CGFloat = 17
    let labelFrame = CGRect(x: textX, y: (h - lineHeight) / 2, width: labelW, height: lineHeight)

    elapsedLabel.frame = labelFrame

    // Spinner + "Stopping..." next to each other
    let spinnerSize: CGFloat = 18
    let spinnerFrame = CGRect(
      x: 12, y: (h - spinnerSize) / 2, width: spinnerSize, height: spinnerSize)
    spinner.frame = spinnerFrame

    let stoppingTextX = spinnerFrame.maxX + 8
    let stoppingTextW = bounds.width - stoppingTextX - 10
    stoppingLabel.frame = CGRect(
      x: stoppingTextX, y: (h - lineHeight) / 2, width: stoppingTextW, height: lineHeight)
  }

  // REMOVED hover logic: ALWAYS show labels during recording/stopping
  override func updateTrackingAreas() {}
  override func mouseEntered(with event: NSEvent) {}
  override func mouseExited(with event: NSEvent) {}

  private func startTicking() {
    tickTimer?.invalidate()
    tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.updateElapsedText()
    }
    updateElapsedText()
  }

  private func stopTicking() {
    tickTimer?.invalidate()
    tickTimer = nil
  }

  private func updateElapsedText() {
    let baseText = elapsedProvider?() ?? ""
    let text = state == .paused ? "Paused • \(baseText)" : baseText
    if elapsedLabel.string as? String != text {
      elapsedLabel.string = text
    }
  }

  private func fade(layer: CALayer, to opacity: Float, duration: CFTimeInterval) {
    let anim = CABasicAnimation(keyPath: "opacity")
    anim.fromValue = layer.opacity
    anim.toValue = opacity
    anim.duration = duration
    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(anim, forKey: "fade")
    layer.opacity = opacity
  }

  private func animateScale(layer: CALayer, to scale: CGFloat, duration: CFTimeInterval) {
    let anim = CABasicAnimation(keyPath: "transform.scale")
    let currentScale = layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? 1.0
    anim.fromValue = currentScale
    anim.toValue = scale
    anim.duration = duration
    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(anim, forKey: "scale")
    layer.transform = CATransform3DMakeScale(scale, scale, 1)
  }

  // Call when recording stops so the label hides immediately
  func hideNow() {
    stopTicking()
    elapsedLabel.string = "00:00:00"
  }
}

final class RecordingIndicator {
  private var panel: NSPanel?
  private var indicatorView: RecordingIndicatorView?
  private var pinned = false

  // Persist position within session
  private var lastFrame: NSRect?

  /// Show/hide + update pin and the elapsed-time provider.
  /// - Parameters:
  ///   - isEnabled: show indicator when true, hide when false
  ///   - pinned: when true the panel ignores mouse and stays at top-right
  ///   - elapsedProvider: closure returning formatted elapsed time (HH:mm:ss)
  /// Show/hide + update pin and the elapsed-time provider.
  /// - Parameters:
  ///   - isEnabled: show indicator when true, hide when false
  ///   - pinned: when true the panel ignores mouse and stays at top-right
  ///   - isRecording: true if recording active (shows Stop icon), false if idle (shows Play icon)
  ///   - elapsedProvider: closure returning formatted elapsed time (HH:mm:ss)
  func setState(
    _ state: IndicatorState,
    pinned: Bool,
    onStopTapped: (() -> Void)? = nil,
    onResumeTapped: (() -> Void)? = nil,
    elapsedProvider: (() -> String)? = nil
  ) {
    self.pinned = pinned
    if state == .hidden {
      hideNow()
    } else {
      showIfNeeded()
      indicatorView?.state = state
      indicatorView?.elapsedProvider = elapsedProvider
      indicatorView?.onStopTapped = onStopTapped
      indicatorView?.onResumeTapped = onResumeTapped
      applyPinnedBehavior()
      if let w = panel { clampToVisibleFrame(w) }
    }
  }

  // Compatibility overload for callers that still pass pinning state explicitly.
  func update(
    pinned: Bool,
    isRecording: Bool,
    onStopTapped: (() -> Void)? = nil,
    elapsedProvider: @escaping () -> String
  ) {
    setState(
      isRecording ? .recording : .hidden, pinned: pinned, onStopTapped: onStopTapped,
      elapsedProvider: elapsedProvider)
  }

  /// Immediately hide with the view’s fade logic.
  func hideNow() {
    indicatorView?.hideNow()

    // Save last frame if visible (and not pinned, because pinned ignores manual pos)
    if let p = panel, !pinned {
      lastFrame = p.frame
    }

    panel?.orderOut(nil)
    panel = nil
    indicatorView = nil
  }

  // MARK: - internals

  private func showIfNeeded() {
    guard panel == nil else { return }

    // Updated larger size for modern look: 150w x 42h
    let size = NSSize(width: 140, height: 42)

    // Determine start rect
    let startRect: NSRect
    if let lf = lastFrame {
      startRect = NSRect(origin: lf.origin, size: size)
    } else {
      // Default top right
      let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
      let origin = CGPoint(
        x: screen.maxX - size.width - 24,  // slightly more padding from edge
        y: screen.maxY - size.height - 36)
      startRect = NSRect(origin: origin, size: size)
    }

    let p = NSPanel(
      contentRect: startRect,
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )
    p.isFloatingPanel = true
    p.hidesOnDeactivate = false
    p.becomesKeyOnlyIfNeeded = true
    p.level = .statusBar
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    let v = RecordingIndicatorView(frame: NSRect(origin: .zero, size: size))
    p.contentView = v

    panel = p
    indicatorView = v
    applyPinnedBehavior()
    p.orderFrontRegardless()
  }

  private func applyPinnedBehavior() {
    guard let p = panel else { return }

    if pinned {
      // Pinned: force top-right
      let size = p.frame.size
      let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
      let origin = CGPoint(
        x: screen.maxX - size.width - 24,  // Consistent padding
        y: screen.maxY - size.height - 36)
      p.setFrameOrigin(origin)

      // Even when pinned, allow clicks (red dot) but DISALLOW dragging
      p.isMovableByWindowBackground = false
    } else {
      if let lf = lastFrame {
        // Restore last known user position
        p.setFrameOrigin(lf.origin)
      }

      p.isMovableByWindowBackground = true
    }

    // Allow mouse events (for the stop button)
    p.ignoresMouseEvents = false
  }

  private func clampToVisibleFrame(_ window: NSWindow) {
    guard let screen = window.screen ?? NSScreen.main else { return }
    let vf = screen.visibleFrame
    var f = window.frame
    if f.maxX > vf.maxX { f.origin.x = vf.maxX - f.width }
    if f.minX < vf.minX { f.origin.x = vf.minX }
    if f.maxY > vf.maxY { f.origin.y = vf.maxY - f.height }
    if f.minY < vf.minY { f.origin.y = vf.minY }
    window.setFrame(f, display: true)  // display=true to repaint
  }
}
