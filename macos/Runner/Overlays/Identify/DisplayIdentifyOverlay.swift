import AppKit

/// Flashes a large ordinal (and the monitor's name) onto physical displays,
/// mirroring System Settings ▸ Displays ▸ Identify.
///
/// The records handed in are the same dictionaries `DisplayService` just
/// produced, so the glyph painted on a screen is by construction the number in
/// that screen's picker row.
@MainActor
enum DisplayIdentifyOverlay {
  private static var panels: [CGDirectDisplayID: NSPanel] = [:]
  private static var hideToken: UUID?
  private static var reconfigObserver: NSObjectProtocol?

  /// - Parameters:
  ///   - records: the payload snapshot being shown in the picker.
  ///   - labels: display id -> the exact label Dart is rendering. Falls back to
  ///     the record's own composed `name` when a label is missing.
  ///   - onlyDisplayID: nil flashes every display; otherwise just that one.
  ///   - duration: seconds before the cards tear themselves down.
  static func show(
    records: [[String: Any]],
    labels: [CGDirectDisplayID: String],
    onlyDisplayID: CGDirectDisplayID?,
    duration: TimeInterval
  ) {
    dispatchPrecondition(condition: .onQueue(.main))

    // Idempotent: a second flash always replaces the first rather than
    // stacking panels or inheriting its dismiss timer.
    hide()

    var byID: [CGDirectDisplayID: [String: Any]] = [:]
    for record in records {
      guard let raw = record["id"] as? NSNumber else { continue }
      byID[CGDirectDisplayID(raw.uint32Value)] = record
    }

    for screen in NSScreen.screens {
      guard
        let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      else { continue }
      let did = CGDirectDisplayID(num.uint32Value)
      if let onlyDisplayID, onlyDisplayID != did { continue }
      guard let record = byID[did] else { continue }

      let ordinal = (record["ordinal"] as? Int) ?? 0
      let subtitle = DisplayIdentifyView.subtitle(
        osName: record["osName"] as? String,
        fallback: labels[did] ?? (record["name"] as? String) ?? "")

      // Always the loop's own screen frame — `window.screen` can be nil.
      let frame = screen.frame
      let size = DisplayIdentifyView.cardSize(for: frame)
      let origin = CGPoint(
        x: frame.origin.x + (frame.size.width - size.width) / 2,
        y: frame.origin.y + (frame.size.height - size.height) / 2)

      let panel = NSPanel(
        contentRect: CGRect(origin: origin, size: size),
        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
      panel.isFloatingPanel = true
      panel.hidesOnDeactivate = false
      panel.becomesKeyOnlyIfNeeded = true
      panel.level = .screenSaver
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.ignoresMouseEvents = true
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
      // Keeps the card out of a capture. Must be set before the first
      // order-front. `excludeRecorderApp` defaults false and the SCContentFilter
      // is built once at stream start, so this is the only thing protecting a
      // recording that begins while a card is up.
      panel.sharingType = .none
      panel.contentView = DisplayIdentifyView(
        frame: CGRect(origin: .zero, size: size), ordinal: ordinal, subtitle: subtitle)
      // Never makeKey / NSApp.activate — identifying screens must not yank the
      // user out of whatever app they are in.
      panel.orderFrontRegardless()

      panels[did] = panel
    }

    guard !panels.isEmpty else { return }

    // A stale digit is worse than no digit: drop everything the moment the
    // display configuration changes underneath us.
    reconfigObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { hide() }
    }

    let token = UUID()
    hideToken = token
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
      // A newer flash cancelled this one.
      guard hideToken == token else { return }
      hide()
    }
  }

  static func hide() {
    hideToken = nil
    if let observer = reconfigObserver {
      NotificationCenter.default.removeObserver(observer)
      reconfigObserver = nil
    }
    // orderOut, never close: NSWindow.isReleasedWhenClosed defaults true and we
    // hold these strongly. Every overlay in this repo tears down the same way.
    for panel in panels.values { panel.orderOut(nil) }
    panels.removeAll()
  }
}

/// The card itself. The sizing statics are pure so they can be unit-tested
/// without a screen.
final class DisplayIdentifyView: NSView {
  private let ordinal: Int
  private let subtitle: String

  init(frame: NSRect, ordinal: Int, subtitle: String) {
    self.ordinal = ordinal
    self.subtitle = subtitle
    super.init(frame: frame)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// A centred card rather than a full-screen wash: `.screenSaver` sits above
  /// the recording indicator (`.statusBar`) and the camera bubble
  /// (`.floating`), so a full-screen panel would blanket all of them.
  static func cardSize(for frame: CGRect) -> CGSize {
    let shortSide = min(frame.width, frame.height)
    let height = min(380, max(180, shortSide * 0.26))
    // 1.8 rather than 1.5: the subtitle is a monitor product name, and at 1.5
    // a 1440x900 screen clipped "DELL U2720Q"-length names.
    return CGSize(width: height * 1.8, height: height)
  }

  /// What to print under the big number.
  ///
  /// Prefers the bare monitor name over the composed picker row: the row
  /// already starts with the ordinal, which is the glyph filling the card, so
  /// repeating it costs the width the name needs. Falls back to the row when
  /// the OS gave no name, since "2. Screen — Main" still beats nothing.
  static func subtitle(osName: String?, fallback: String) -> String {
    if let osName, !osName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return osName
    }
    return fallback
  }

  static func ordinalFontSize(for cardHeight: CGFloat) -> CGFloat { cardHeight * 0.46 }

  static func subtitleFontSize(for cardHeight: CGFloat) -> CGFloat {
    min(cardHeight * 0.11, 22)
  }

  override func draw(_ dirtyRect: NSRect) {
    let card = bounds.insetBy(dx: 1, dy: 1)
    let path = NSBezierPath(roundedRect: card, xRadius: 28, yRadius: 28)
    NSColor.black.withAlphaComponent(0.82).setFill()
    path.fill()
    NSColor.white.withAlphaComponent(0.28).setStroke()
    path.lineWidth = 2
    path.stroke()

    let ordinalSize = Self.ordinalFontSize(for: bounds.height)
    let subtitleSize = Self.subtitleFontSize(for: bounds.height)

    let ordinalStyle = NSMutableParagraphStyle()
    ordinalStyle.alignment = .center
    let ordinalText = NSAttributedString(
      string: "\(ordinal)",
      attributes: [
        .font: NSFont.systemFont(ofSize: ordinalSize, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: ordinalStyle,
      ])

    let subtitleStyle = NSMutableParagraphStyle()
    subtitleStyle.alignment = .center
    subtitleStyle.lineBreakMode = .byTruncatingTail
    let subtitleText = NSAttributedString(
      string: subtitle,
      attributes: [
        .font: NSFont.systemFont(ofSize: subtitleSize, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        .paragraphStyle: subtitleStyle,
      ])

    let subtitleHeight = subtitleSize * 1.4
    let subtitleRect = CGRect(
      x: card.minX + 18, y: card.minY + subtitleSize * 0.9,
      width: card.width - 36, height: subtitleHeight)
    let ordinalRect = CGRect(
      x: card.minX, y: subtitleRect.maxY,
      width: card.width, height: card.maxY - subtitleRect.maxY - ordinalSize * 0.18)

    let ordinalBounds = ordinalText.boundingRect(
      with: CGSize(width: ordinalRect.width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin])
    ordinalText.draw(
      in: CGRect(
        x: ordinalRect.minX,
        y: ordinalRect.midY - ordinalBounds.height / 2,
        width: ordinalRect.width, height: ordinalBounds.height))

    if !subtitle.isEmpty { subtitleText.draw(in: subtitleRect) }
  }
}
