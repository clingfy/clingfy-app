import Cocoa

// MARK: - Data Model
struct PickerOption {
  let id: String
  let label: String
  var isSelected: Bool
  var icon: NSImage? = nil
}

// MARK: - The "Astonishing" Popover
class OptionPickerPopover: NSViewController {

  // MARK: - Properties
  let titleText: String
  private var options: [PickerOption]

  var onSelect: ((String) -> Void)?
  var onRefresh: ((@escaping () -> Void) -> Void)?

  private var isRefreshing = false

  // UI Elements
  private let scrollView = NSScrollView()
  private let stackView = NSStackView()
  private let headerView = NSView()
  private let refreshButton = NSButton()
  private let spinner = NSProgressIndicator()

  // MARK: - Init
  init(title: String, options: [PickerOption]) {
    self.titleText = title
    self.options = options
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

  // MARK: - Lifecycle
  override func loadView() {
    view = NSView()
    view.wantsLayer = true
    view.layer?.cornerRadius = 12
    view.layer?.masksToBounds = true

    setupVisualEffect()
    setupHeader()
    setupScrollView()
    setupStackView()
    updateOptionsUI()
  }

  // MARK: - Layout Setup
  private func setupVisualEffect() {
    let vev = NSVisualEffectView()
    vev.material = .popover
    vev.blendingMode = .behindWindow
    vev.state = .active
    vev.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(vev)

    NSLayoutConstraint.activate([
      vev.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      vev.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      vev.topAnchor.constraint(equalTo: view.topAnchor),
      vev.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func setupHeader() {
    headerView.translatesAutoresizingMaskIntoConstraints = false

    // 1. ESSENTIAL: Enable layer backing for animations to render correctly
    headerView.wantsLayer = true

    view.addSubview(headerView)

    let label = NSTextField(labelWithString: titleText)
    label.font = .systemFont(ofSize: 11, weight: .bold)
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    headerView.addSubview(label)

    // -- Refresh Button --
    refreshButton.bezelStyle = .shadowlessSquare
    refreshButton.isBordered = false
    if #available(macOS 11.0, *) {
      let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
      let refreshLabel = NativeStringsStore.shared.string(
        for: NativeUIStringKey.preRecordingBarRefresh
      )
      refreshButton.image = NSImage(
        systemSymbolName: "arrow.clockwise", accessibilityDescription: refreshLabel)?
        .withSymbolConfiguration(config)
    } else {
      refreshButton.image = NSImage(named: NSImage.refreshTemplateName)
    }
    refreshButton.contentTintColor = .secondaryLabelColor
    refreshButton.target = self
    refreshButton.action = #selector(refreshTapped)
    refreshButton.translatesAutoresizingMaskIntoConstraints = false
    refreshButton.isHidden = (onRefresh == nil)
    headerView.addSubview(refreshButton)

    // -- Spinner --
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isIndeterminate = true
    spinner.isDisplayedWhenStopped = true  // 2. Keep it in layout, we toggle opacity/hidden manually if needed
    spinner.isHidden = true  // Start hidden
    spinner.translatesAutoresizingMaskIntoConstraints = false
    headerView.addSubview(spinner)

    // Separator line
    let separator = NSBox()
    separator.boxType = .separator
    separator.translatesAutoresizingMaskIntoConstraints = false
    headerView.addSubview(separator)

    NSLayoutConstraint.activate([
      headerView.topAnchor.constraint(equalTo: view.topAnchor),
      headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      headerView.heightAnchor.constraint(equalToConstant: 34),

      label.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
      label.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

      // Button Constraints
      refreshButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),
      refreshButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
      refreshButton.widthAnchor.constraint(equalToConstant: 24),
      refreshButton.heightAnchor.constraint(equalToConstant: 24),

      // 3. Spinner Constraints: Center it exactly where the button is
      // Do NOT set fixed width/height for the spinner, let intrinsic size work
      spinner.centerXAnchor.constraint(equalTo: refreshButton.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),

      separator.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
      separator.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
      separator.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
    ])
  }

  // Add near our properties
  private let minSpinnerDuration: TimeInterval = 0.1
  private var refreshStartedAt: CFTimeInterval?

  @objc private func refreshTapped() {
    guard !isRefreshing else { return }

    refreshStartedAt = CACurrentMediaTime()
    setRefreshing(true)

    onRefresh? { [weak self] in
      DispatchQueue.main.async {
        self?.finishRefreshingWithMinimumSpinnerTime()
      }
    }
  }

  private func finishRefreshingWithMinimumSpinnerTime() {
    let start = refreshStartedAt ?? CACurrentMediaTime()
    let elapsed = CACurrentMediaTime() - start
    let remaining = max(0, minSpinnerDuration - elapsed)

    if remaining > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
        self?.setRefreshing(false)
      }
    } else {
      setRefreshing(false)
    }
  }

  private func setRefreshing(_ enabled: Bool) {
    isRefreshing = enabled

    // Toggle visibility explicitly
    refreshButton.isHidden = enabled
    spinner.isHidden = !enabled

    if enabled {
      spinner.startAnimation(nil)
      scrollView.alphaValue = 0.5
    } else {
      spinner.stopAnimation(nil)
      scrollView.alphaValue = 1.0
    }
  }

  private func setupScrollView() {
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scrollView)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func setupStackView() {
    stackView.orientation = .vertical
    // FIXED: .fill is not valid for alignment. Used .leading (left aligned) instead.
    stackView.alignment = .leading
    stackView.distribution = .fill
    stackView.spacing = 2
    stackView.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

    stackView.translatesAutoresizingMaskIntoConstraints = false

    let clipView = NSClipView()
    clipView.documentView = stackView
    clipView.drawsBackground = false
    scrollView.contentView = clipView

    stackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
  }

  // MARK: - Logic
  func updateOptions(_ newOptions: [PickerOption]) {
    NativeLogger.d("Popover", "updateOptions: \(newOptions)")
    self.options = newOptions
    updateOptionsUI()
  }

  private func updateOptionsUI() {
    stackView.setViews([], in: .top)

    for opt in options {
      let row = OptionRowView(option: opt)
      row.onClick = { [weak self] id in
        self?.onSelect?(id)
      }
      stackView.addArrangedSubview(row)
      // Ensure row spans full width inside the stack
      row.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -16).isActive = true
    }

    layoutPopoverSize()
  }

  private func layoutPopoverSize() {
    let headerHeight: CGFloat = 34
    let padding: CGFloat = 16
    let rowHeight: CGFloat = 32
    let spacing: CGFloat = 2

    let contentHeight = CGFloat(options.count) * (rowHeight + spacing) + padding
    let totalHeight = headerHeight + contentHeight

    let clampedHeight = min(max(totalHeight, 100), 400)
    self.preferredContentSize = NSSize(width: 260, height: clampedHeight)
  }
}

// MARK: - The Custom "Beautified" Row
class OptionRowView: NSView {

  private let option: PickerOption
  var onClick: ((String) -> Void)?

  // UI Components
  private let titleLabel = NSTextField(labelWithString: "")
  private let iconView = NSImageView()
  private let trailingIconView = NSImageView()
  private var trackingArea: NSTrackingArea?

  init(option: PickerOption) {
    self.option = option
    super.init(frame: .zero)
    setupUI()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

  private func setupUI() {
    self.translatesAutoresizingMaskIntoConstraints = false
    self.wantsLayer = true
    self.layer?.cornerRadius = 6

    self.heightAnchor.constraint(equalToConstant: 32).isActive = true

    // -- Icon Logic (Backwards Compatible) --
    setupIcon()

    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)

    trailingIconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(trailingIconView)

    // -- Label --
    titleLabel.stringValue = option.label
    titleLabel.font = .systemFont(ofSize: 13, weight: option.isSelected ? .medium : .regular)
    titleLabel.textColor = option.isSelected ? .labelColor : .secondaryLabelColor
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(titleLabel)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 10),
      iconView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 18),
      iconView.heightAnchor.constraint(equalToConstant: 18),

      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
      titleLabel.trailingAnchor.constraint(equalTo: trailingIconView.leadingAnchor, constant: -8),
      titleLabel.centerYAnchor.constraint(equalTo: self.centerYAnchor),

      trailingIconView.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -10),
      trailingIconView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      trailingIconView.widthAnchor.constraint(equalToConstant: 14),
      trailingIconView.heightAnchor.constraint(equalToConstant: 14),
    ])
  }

  private func setupIcon() {
    if let customIcon = option.icon {
      // Use provided icon (e.g. app icon)
      iconView.image = customIcon
      iconView.contentTintColor = nil  // Keep original colors for app icons

      if option.isSelected {
        if #available(macOS 11.0, *) {
          trailingIconView.image = NSImage(
            systemSymbolName: "checkmark", accessibilityDescription: nil)
        } else {
          trailingIconView.image = NSImage(named: NSImage.menuOnStateTemplateName)
        }
        trailingIconView.contentTintColor = .controlAccentColor
      } else {
        trailingIconView.image = nil
      }
    } else {
      // Fallback: standard selection circle on leading edge
      iconView.contentTintColor = option.isSelected ? .controlAccentColor : .tertiaryLabelColor
      trailingIconView.image = nil

      if #available(macOS 11.0, *) {
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let iconName = option.isSelected ? "checkmark.circle.fill" : "circle"
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
          .withSymbolConfiguration(symbolConfig)
      } else {
        if option.isSelected {
          iconView.image = NSImage(named: NSImage.menuOnStateTemplateName)
        } else {
          iconView.image = NSImage(named: NSImage.statusNoneName)
        }
      }
    }
  }

  // MARK: - Interactions & Hover Effects

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let ta = trackingArea { removeTrackingArea(ta) }

    trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeAlways],
      owner: self,
      userInfo: nil)
    addTrackingArea(trackingArea!)
  }

  override func mouseEntered(with event: NSEvent) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      self.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }
  }

  override func mouseExited(with event: NSEvent) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      self.layer?.backgroundColor = NSColor.clear.cgColor
    }
  }

  override func mouseDown(with event: NSEvent) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.05
      self.animator().alphaValue = 0.7
    }
  }

  override func mouseUp(with event: NSEvent) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.1
      self.animator().alphaValue = 1.0
    } completionHandler: {
      let loc = self.convert(event.locationInWindow, from: nil)
      if self.bounds.contains(loc) {
        self.onClick?(self.option.id)
      }
    }
  }
}
