import AVFoundation
import FlutterMacOS

final class CursorView: NSView {
  private let ring = CAShapeLayer()
  private let clickRing = CAShapeLayer()

  var ringSize: CGFloat = 60 {
    didSet { needsLayout = true }
  }
  var baseColor: NSColor = .systemYellow.withAlphaComponent(0.25) {
    didSet { ring.fillColor = baseColor.cgColor }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    ring.fillColor = baseColor.cgColor
    layer?.addSublayer(ring)

    clickRing.fillColor = NSColor.clear.cgColor
    clickRing.strokeColor = NSColor.systemYellow.cgColor
    clickRing.lineWidth = 3
    clickRing.opacity = 0
    layer?.addSublayer(clickRing)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    // Both rings fill the view, so a transform scales them about its centre.
    // With the default zero-size frame the anchor point sat at the view's
    // bottom-left corner: the click pulse grew the outline up and to the
    // right, off the panel, where it was clipped, and showed on screen and
    // in recordings as a quarter of a circle beside the pointer.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for layer in [ring, clickRing] {
      layer.frame = bounds
    }
    let d = ringSize
    let rect = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
    ring.path = CGPath(ellipseIn: rect, transform: nil)
    clickRing.path = CGPath(ellipseIn: rect.insetBy(dx: -2, dy: -2), transform: nil)
    CATransaction.commit()
  }

  // Sublayers do not follow the window's scale on their own, so on a Retina
  // display the rings rendered at 1x and looked soft.
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    ring.contentsScale = scale
    clickRing.contentsScale = scale
  }

  func pulseClick() {
    clickRing.removeAllAnimations()
    // At rest the outline is hidden; the animation alone shows it. Setting
    // the resting opacity to 1 here left the outline on for good after the
    // first click, once the animation was removed.
    clickRing.opacity = 0
    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 1.0
    scale.toValue = 1.35
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1.0
    fade.toValue = 0.0
    let group = CAAnimationGroup()
    group.animations = [scale, fade]
    group.duration = 0.35
    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
    group.isRemovedOnCompletion = true
    clickRing.add(group, forKey: "pulse")
  }

  #if DEBUG
    /// The fill ring and the click outline, for tests.
    var _testLayers: (ring: CAShapeLayer, clickRing: CAShapeLayer) { (ring, clickRing) }
  #endif
}
