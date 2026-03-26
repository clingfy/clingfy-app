import Cocoa

enum IndicatorState: Equatable {
  case hidden
  case recording
  case paused
  case stopping
}

private enum PrimarySymbolMode {
  case none
  case stop
  case resume
}

private struct IndicatorPresentation {
  let primaryTint: NSColor
  let primarySymbolMode: PrimarySymbolMode
  let showsPrimaryAction: Bool
  let showsElapsed: Bool
  let showsStopping: Bool
  let showsSecondaryStop: Bool
  let primaryTooltip: String?
  let secondaryStopTooltip: String?
}

final class RecordingIndicatorView: NSView {
  static let preferredSize = NSSize(width: 176, height: 42)
  private static let defaultElapsedText = "00:00:00"

  private enum ToolTipRegion: Int {
    case primaryAction = 1
    case secondaryStop = 2
  }

  private enum TapTarget {
    case primary
    case secondaryStop
  }

  private let primaryActionLayer = CAShapeLayer()
  private let primarySymbolLayer = CAShapeLayer()
  private let secondaryStopLayer = CAShapeLayer()
  private let secondaryStopSymbolLayer = CAShapeLayer()
  private let elapsedLabel = CATextLayer()
  private let spinner = NSProgressIndicator()
  private let stoppingLabel = CATextLayer()

  var elapsedProvider: (() -> String)?
  var onStopTapped: (() -> Void)?
  var onResumeTapped: (() -> Void)?

  var state: IndicatorState = .hidden {
    didSet {
      updateUIForState()
    }
  }

  private var tickTimer: Timer?
  private var primaryHitRect: CGRect = .zero
  private var secondaryStopHitRect: CGRect = .zero
  private var primaryToolTipTag: NSView.ToolTipTag?
  private var secondaryToolTipTag: NSView.ToolTipTag?
  private var primaryToolTipText: String?
  private var secondaryToolTipText: String?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true

    layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
    layer?.borderWidth = 0
    layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    layer?.masksToBounds = true

    primarySymbolLayer.fillColor = NSColor.white.cgColor
    primarySymbolLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    primaryActionLayer.addSublayer(primarySymbolLayer)
    layer?.addSublayer(primaryActionLayer)

    secondaryStopLayer.fillColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.18).cgColor
    secondaryStopLayer.strokeColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
    secondaryStopLayer.lineWidth = 1
    secondaryStopSymbolLayer.fillColor = NSColor.labelColor.withAlphaComponent(0.9).cgColor
    secondaryStopSymbolLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    secondaryStopLayer.addSublayer(secondaryStopSymbolLayer)
    layer?.addSublayer(secondaryStopLayer)

    elapsedLabel.string = Self.defaultElapsedText
    elapsedLabel.opacity = 0
    elapsedLabel.alignmentMode = .left
    elapsedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    elapsedLabel.fontSize = 15
    elapsedLabel.foregroundColor = NSColor.labelColor.cgColor
    elapsedLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    layer?.addSublayer(elapsedLabel)

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

    updateUIForState()
  }

  required init?(coder: NSCoder) { fatalError() }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard handleClick(at: point) else {
      super.mouseDown(with: event)
      return
    }
  }

  override func resetCursorRects() {
    super.resetCursorRects()

    if !primaryHitRect.isEmpty {
      addCursorRect(primaryHitRect, cursor: .pointingHand)
    }
    if !secondaryStopHitRect.isEmpty {
      addCursorRect(secondaryStopHitRect, cursor: .pointingHand)
    }
  }

  override func layout() {
    super.layout()
    guard let containerLayer = layer else { return }

    let presentation = Self.presentation(for: state)
    let height = bounds.height
    containerLayer.cornerRadius = height / 2

    let horizontalInset: CGFloat = 12
    let primarySize: CGFloat = 20
    let secondarySize: CGFloat = 18
    let primaryFrame = CGRect(
      x: horizontalInset,
      y: (height - primarySize) / 2,
      width: primarySize,
      height: primarySize
    )

    primaryActionLayer.frame = primaryFrame
    primaryActionLayer.path = CGPath(ellipseIn: primaryActionLayer.bounds, transform: nil)
    primarySymbolLayer.frame = primaryActionLayer.bounds
    primarySymbolLayer.path = Self.symbolPath(
      for: presentation.primarySymbolMode,
      in: primarySymbolLayer.bounds.insetBy(dx: 4, dy: 4)
    )

    let textX = primaryFrame.maxX + 10
    let lineHeight: CGFloat = 17
    let secondaryFrame: CGRect
    let textMaxX: CGFloat
    if presentation.showsSecondaryStop {
      secondaryFrame = CGRect(
        x: bounds.width - horizontalInset - secondarySize,
        y: (height - secondarySize) / 2,
        width: secondarySize,
        height: secondarySize
      )
      textMaxX = secondaryFrame.minX - 8
    } else {
      secondaryFrame = .zero
      textMaxX = bounds.width - horizontalInset
    }

    secondaryStopLayer.frame = secondaryFrame
    secondaryStopLayer.path = CGPath(ellipseIn: secondaryStopLayer.bounds, transform: nil)
    secondaryStopSymbolLayer.frame = secondaryStopLayer.bounds
    secondaryStopSymbolLayer.path = Self.stopSymbolPath(
      in: secondaryStopSymbolLayer.bounds.insetBy(dx: 5.5, dy: 5.5)
    )

    let textWidth = max(0, textMaxX - textX)
    let labelFrame = CGRect(
      x: textX,
      y: (height - lineHeight) / 2,
      width: textWidth,
      height: lineHeight
    )
    elapsedLabel.frame = labelFrame

    let spinnerSize: CGFloat = 18
    let spinnerFrame = CGRect(
      x: horizontalInset,
      y: (height - spinnerSize) / 2,
      width: spinnerSize,
      height: spinnerSize
    )
    spinner.frame = spinnerFrame
    stoppingLabel.frame = CGRect(
      x: spinnerFrame.maxX + 8,
      y: (height - lineHeight) / 2,
      width: max(0, bounds.width - (spinnerFrame.maxX + 20)),
      height: lineHeight
    )

    primaryHitRect = presentation.showsPrimaryAction
      ? primaryFrame.insetBy(dx: -8, dy: -8)
      : .zero
    secondaryStopHitRect = presentation.showsSecondaryStop
      ? secondaryFrame.insetBy(dx: -8, dy: -8)
      : .zero

    updateToolTips(for: presentation)
    window?.invalidateCursorRects(for: self)
  }

  func view(
    _ view: NSView,
    stringForToolTip tag: NSView.ToolTipTag,
    point: NSPoint,
    userData data: UnsafeMutableRawPointer?
  ) -> String {
    switch ToolTipRegion(rawValue: Int(bitPattern: data)) {
    case .primaryAction:
      return primaryToolTipText ?? ""
    case .secondaryStop:
      return secondaryToolTipText ?? ""
    case .none:
      return ""
    }
  }

  override func isAccessibilityElement() -> Bool {
    state != .hidden
  }

  override func accessibilityRole() -> NSAccessibility.Role? {
    .group
  }

  override func accessibilityLabel() -> String? {
    switch state {
    case .hidden:
      return nil
    case .recording:
      return "Recording in progress, \(formattedBaseElapsedText())"
    case .paused:
      return "Recording paused, \(formattedBaseElapsedText())"
    case .stopping:
      return "Stopping recording"
    }
  }

  override func accessibilityHelp() -> String? {
    switch state {
    case .hidden:
      return nil
    case .recording:
      return "Press to stop recording."
    case .paused:
      return "Primary action resumes recording. Secondary stop control stops recording."
    case .stopping:
      return "Recording is stopping."
    }
  }

  override func accessibilityPerformPress() -> Bool {
    switch state {
    case .recording:
      onStopTapped?()
      return true
    case .paused:
      onResumeTapped?()
      return true
    case .hidden, .stopping:
      return false
    }
  }

  func hideNow() {
    stopTicking()
    elapsedLabel.string = Self.defaultElapsedText
  }

  private func updateUIForState() {
    let presentation = Self.presentation(for: state)

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    primaryActionLayer.opacity = presentation.showsPrimaryAction ? 1 : 0
    primarySymbolLayer.opacity = presentation.showsPrimaryAction ? 1 : 0
    primaryActionLayer.fillColor = presentation.primaryTint.cgColor

    secondaryStopLayer.opacity = presentation.showsSecondaryStop ? 1 : 0
    secondaryStopSymbolLayer.opacity = presentation.showsSecondaryStop ? 1 : 0

    elapsedLabel.opacity = presentation.showsElapsed ? 1 : 0
    stoppingLabel.opacity = presentation.showsStopping ? 1 : 0

    if presentation.showsStopping {
      spinner.startAnimation(nil)
    } else {
      spinner.stopAnimation(nil)
    }

    if state == .recording {
      startTicking()
    } else {
      stopTicking()
    }
    updateElapsedText()

    CATransaction.commit()
    needsLayout = true
  }

  private func startTicking() {
    guard tickTimer == nil else {
      updateElapsedText()
      return
    }

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
    guard state == .recording || state == .paused else {
      elapsedLabel.string = Self.defaultElapsedText
      return
    }

    let baseText = formattedBaseElapsedText()
    let text = state == .paused ? "Paused • \(baseText)" : baseText
    if elapsedLabel.string as? String != text {
      elapsedLabel.string = text
    }
  }

  private func formattedBaseElapsedText() -> String {
    let text = (elapsedProvider?() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? Self.defaultElapsedText : text
  }

  @discardableResult
  private func handleClick(at point: CGPoint) -> Bool {
    guard let tapTarget = tapTarget(at: point) else { return false }

    performAction(for: tapTarget)
    return true
  }

  private func tapTarget(at point: CGPoint) -> TapTarget? {
    if !secondaryStopHitRect.isEmpty && secondaryStopHitRect.contains(point) {
      return .secondaryStop
    }
    if !primaryHitRect.isEmpty && primaryHitRect.contains(point) {
      return .primary
    }
    return nil
  }

  private func performAction(for target: TapTarget) {
    switch target {
    case .primary:
      animateTap(on: primaryActionLayer)
      switch state {
      case .recording:
        onStopTapped?()
      case .paused:
        onResumeTapped?()
      case .hidden, .stopping:
        break
      }
    case .secondaryStop:
      guard state == .paused else { return }
      animateTap(on: secondaryStopLayer)
      onStopTapped?()
    }
  }

  private func animateTap(on layer: CALayer) {
    let animation = CAKeyframeAnimation(keyPath: "transform.scale")
    animation.values = [1.0, 0.88, 1.0]
    animation.keyTimes = [0, 0.5, 1]
    animation.duration = 0.15
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(animation, forKey: "tap")
  }

  private func updateToolTips(for presentation: IndicatorPresentation) {
    if let primaryToolTipTag {
      removeToolTip(primaryToolTipTag)
      self.primaryToolTipTag = nil
    }
    if let secondaryToolTipTag {
      removeToolTip(secondaryToolTipTag)
      self.secondaryToolTipTag = nil
    }

    primaryToolTipText = presentation.primaryTooltip
    secondaryToolTipText = presentation.secondaryStopTooltip

    if let primaryToolTipText, !primaryHitRect.isEmpty {
      _ = primaryToolTipText
      primaryToolTipTag = addToolTip(
        primaryHitRect,
        owner: self,
        userData: UnsafeMutableRawPointer(bitPattern: ToolTipRegion.primaryAction.rawValue)
      )
    }

    if let secondaryToolTipText, !secondaryStopHitRect.isEmpty {
      _ = secondaryToolTipText
      secondaryToolTipTag = addToolTip(
        secondaryStopHitRect,
        owner: self,
        userData: UnsafeMutableRawPointer(bitPattern: ToolTipRegion.secondaryStop.rawValue)
      )
    }
  }

  private static func presentation(for state: IndicatorState) -> IndicatorPresentation {
    switch state {
    case .hidden:
      return IndicatorPresentation(
        primaryTint: .clear,
        primarySymbolMode: .none,
        showsPrimaryAction: false,
        showsElapsed: false,
        showsStopping: false,
        showsSecondaryStop: false,
        primaryTooltip: nil,
        secondaryStopTooltip: nil
      )
    case .recording:
      return IndicatorPresentation(
        primaryTint: .systemRed,
        primarySymbolMode: .stop,
        showsPrimaryAction: true,
        showsElapsed: true,
        showsStopping: false,
        showsSecondaryStop: false,
        primaryTooltip: "Stop recording",
        secondaryStopTooltip: nil
      )
    case .paused:
      return IndicatorPresentation(
        primaryTint: .systemOrange,
        primarySymbolMode: .resume,
        showsPrimaryAction: true,
        showsElapsed: true,
        showsStopping: false,
        showsSecondaryStop: true,
        primaryTooltip: "Resume recording",
        secondaryStopTooltip: "Stop recording"
      )
    case .stopping:
      return IndicatorPresentation(
        primaryTint: .clear,
        primarySymbolMode: .none,
        showsPrimaryAction: false,
        showsElapsed: false,
        showsStopping: true,
        showsSecondaryStop: false,
        primaryTooltip: nil,
        secondaryStopTooltip: nil
      )
    }
  }

  private static func symbolPath(for mode: PrimarySymbolMode, in bounds: CGRect) -> CGPath? {
    switch mode {
    case .none:
      return nil
    case .stop:
      return stopSymbolPath(in: bounds)
    case .resume:
      return resumeSymbolPath(in: bounds)
    }
  }

  private static func stopSymbolPath(in bounds: CGRect) -> CGPath {
    let size = min(bounds.width, bounds.height)
    let squareSize = min(size, 8)
    let rect = CGRect(
      x: bounds.midX - squareSize / 2,
      y: bounds.midY - squareSize / 2,
      width: squareSize,
      height: squareSize
    )
    return CGPath(
      roundedRect: rect,
      cornerWidth: 1.5,
      cornerHeight: 1.5,
      transform: nil
    )
  }

  private static func resumeSymbolPath(in bounds: CGRect) -> CGPath {
    let width = min(bounds.width, 8)
    let height = min(bounds.height, 10)
    let rect = CGRect(
      x: bounds.midX - width / 2 + 0.5,
      y: bounds.midY - height / 2,
      width: width,
      height: height
    )

    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.closeSubpath()
    return path
  }

#if DEBUG
  var debugDisplayedElapsedText: String {
    elapsedLabel.string as? String ?? ""
  }

  var debugPrimaryHitRect: CGRect {
    primaryHitRect
  }

  var debugSecondaryStopHitRect: CGRect {
    secondaryStopHitRect
  }

  var debugPrimaryTooltip: String? {
    primaryToolTipText
  }

  var debugSecondaryTooltip: String? {
    secondaryToolTipText
  }

  var debugHasTickTimer: Bool {
    tickTimer != nil
  }

  @discardableResult
  func debugHandleClick(at point: CGPoint) -> Bool {
    handleClick(at: point)
  }
#endif
}

final class RecordingIndicator {
  private var panel: NSPanel?
  private var indicatorView: RecordingIndicatorView?
  private var pinned = false
  private var lastFrame: NSRect?

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
      return
    }

    showIfNeeded()
    indicatorView?.elapsedProvider = elapsedProvider
    indicatorView?.onStopTapped = onStopTapped
    indicatorView?.onResumeTapped = onResumeTapped
    indicatorView?.state = state
    applyPinnedBehavior()
    if let panel {
      clampToVisibleFrame(panel)
    }
  }

  func update(
    pinned: Bool,
    isRecording: Bool,
    onStopTapped: (() -> Void)? = nil,
    elapsedProvider: @escaping () -> String
  ) {
    setState(
      isRecording ? .recording : .hidden,
      pinned: pinned,
      onStopTapped: onStopTapped,
      elapsedProvider: elapsedProvider
    )
  }

  func hideNow() {
    indicatorView?.hideNow()

    if let panel, !pinned {
      lastFrame = panel.frame
    }

    panel?.orderOut(nil)
    panel = nil
    indicatorView = nil
  }

  private func showIfNeeded() {
    guard panel == nil else { return }

    let size = RecordingIndicatorView.preferredSize

    let startRect: NSRect
    if let lastFrame {
      startRect = NSRect(origin: lastFrame.origin, size: size)
    } else {
      let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
      let origin = CGPoint(
        x: screen.maxX - size.width - 24,
        y: screen.maxY - size.height - 36
      )
      startRect = NSRect(origin: origin, size: size)
    }

    let panel = NSPanel(
      contentRect: startRect,
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    let indicatorView = RecordingIndicatorView(frame: NSRect(origin: .zero, size: size))
    panel.contentView = indicatorView

    self.panel = panel
    self.indicatorView = indicatorView
    applyPinnedBehavior()
    panel.orderFrontRegardless()
  }

  private func applyPinnedBehavior() {
    guard let panel else { return }

    if pinned {
      let size = panel.frame.size
      let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
      let origin = CGPoint(
        x: screen.maxX - size.width - 24,
        y: screen.maxY - size.height - 36
      )
      panel.setFrameOrigin(origin)
      panel.isMovableByWindowBackground = false
    } else {
      if let lastFrame {
        panel.setFrameOrigin(lastFrame.origin)
      }
      panel.isMovableByWindowBackground = true
    }

    panel.ignoresMouseEvents = false
  }

  private func clampToVisibleFrame(_ window: NSWindow) {
    guard let screen = window.screen ?? NSScreen.main else { return }
    let visibleFrame = screen.visibleFrame
    var frame = window.frame

    if frame.maxX > visibleFrame.maxX { frame.origin.x = visibleFrame.maxX - frame.width }
    if frame.minX < visibleFrame.minX { frame.origin.x = visibleFrame.minX }
    if frame.maxY > visibleFrame.maxY { frame.origin.y = visibleFrame.maxY - frame.height }
    if frame.minY < visibleFrame.minY { frame.origin.y = visibleFrame.minY }

    window.setFrame(frame, display: true)
  }
}
