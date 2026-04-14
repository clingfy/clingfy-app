import Cocoa

extension NSImage {
  static func symbol(_ name: String, accessibilityDescription: String? = nil) -> NSImage? {
    if #available(macOS 11.0, *) {
      return NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
    } else {
      // Fallback for macOS 10.15 and older
      return NSImage(named: name)
    }
  }
}

class PreRecordingBarView: NSView {
  var onAction: ((String, [String: Any]?) -> Void)?

  private let stackView = NSStackView()
  private let visualEffectView = NSVisualEffectView()

  private var state: [String: Any] = [:]

  // Buttons
  public var closeButton: NSButton!
  public var displayButton: NSButton!
  public var windowButton: NSButton!
  public var areaButton: NSButton!
  public var cameraButton: NSButton!
  public var micButton: NSButton!
  public var systemAudioButton: NSButton!
  public var updateButton: NSButton!
  public var recordButton: NSButton!
  public var pauseResumeButton: NSButton!
  private let recordSpinner = NSProgressIndicator()

  private var updateAnimationTimer: Timer?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupUI()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupUI()
  }

  deinit {
    stopUpdateBounceAnimation()
  }

  private func setupUI() {
    // Visual Effect View for background
    visualEffectView.blendingMode = .withinWindow
    visualEffectView.material = .underWindowBackground
    visualEffectView.state = .active
    visualEffectView.wantsLayer = true
    visualEffectView.layer?.cornerRadius = 32
    visualEffectView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(visualEffectView)

    // Stack View for content
    stackView.orientation = .horizontal
    stackView.spacing = 16
    stackView.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
    stackView.alignment = .centerY
    stackView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stackView)

    NSLayoutConstraint.activate([
      visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      visualEffectView.topAnchor.constraint(equalTo: topAnchor),
      visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    setupButtons()
  }

  private func setupButtons() {
    let strings = NativeStringsStore.shared
    closeButton = createButton(imageName: "xmark", action: #selector(closeTapped))

    displayButton = createButton(
      imageName: "display",
      label: strings.string(for: NativeUIStringKey.preRecordingBarDisplay),
      action: #selector(displayTapped)
    )

    windowButton = createButton(
      imageName: "macwindow",
      label: strings.string(for: NativeUIStringKey.preRecordingBarWindow),
      action: #selector(windowTapped)
    )

    areaButton = createButton(
      imageName: "rectangle.dashed",
      label: strings.string(for: NativeUIStringKey.preRecordingBarArea),
      action: #selector(areaTapped)
    )

    cameraButton = createButton(
      imageName: "video",
      label: strings.string(for: NativeUIStringKey.preRecordingBarCamera),
      action: #selector(cameraTapped)
    )

    micButton = createButton(
      imageName: "mic",
      label: strings.string(for: NativeUIStringKey.preRecordingBarMic),
      action: #selector(micTapped)
    )

    systemAudioButton = createButton(
      imageName: "speaker.wave.2",
      label: strings.string(for: NativeUIStringKey.preRecordingBarSystem),
      action: #selector(systemAudioTapped)
    )

    updateButton = createButton(
      imageName: "arrow.up.circle",
      label: strings.string(for: NativeUIStringKey.preRecordingBarUpdate),
      action: #selector(updateTapped)
    )
    updateButton.contentTintColor = NSColor(red: 0x89/255.0, green: 0x57/255.0, blue: 0xE5/255.0, alpha: 1.0)

    pauseResumeButton = createButton(
      imageName: "pause.fill",
      label: strings.string(for: NativeUIStringKey.preRecordingBarPause),
      action: #selector(pauseResumeTapped)
    )
    pauseResumeButton.isHidden = true

    recordButton = createButton(
      imageName: "record.circle", action: #selector(recordTapped))

    stackView.addArrangedSubview(closeButton)
    stackView.addArrangedSubview(createSeparator())
    stackView.addArrangedSubview(displayButton)
    stackView.addArrangedSubview(windowButton)
    stackView.addArrangedSubview(areaButton)
    stackView.addArrangedSubview(createSeparator())
    stackView.addArrangedSubview(cameraButton)
    stackView.addArrangedSubview(micButton)
    stackView.addArrangedSubview(systemAudioButton)
    stackView.addArrangedSubview(pauseResumeButton)
    stackView.addArrangedSubview(recordButton)

    // Update button is hidden by default
    updateButton.isHidden = true
    updateButton.wantsLayer = true  // Used for the bounce animation
    stackView.addArrangedSubview(updateButton)

    // Setup Spinner
    recordSpinner.style = .spinning
    recordSpinner.controlSize = .small
    recordSpinner.isDisplayedWhenStopped = false
    recordSpinner.translatesAutoresizingMaskIntoConstraints = false
    addSubview(recordSpinner)

    NSLayoutConstraint.activate([
      recordButton.widthAnchor.constraint(equalToConstant: 32),
      recordButton.heightAnchor.constraint(equalToConstant: 32),

      recordSpinner.centerXAnchor.constraint(equalTo: recordButton.centerXAnchor),
      recordSpinner.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
    ])
  }

  func refreshLocalizedStrings() {
    let strings = NativeStringsStore.shared
    applyButtonPresentation(
      displayButton,
      imageName: "display",
      label: strings.string(for: NativeUIStringKey.preRecordingBarDisplay)
    )
    applyButtonPresentation(
      windowButton,
      imageName: "macwindow",
      label: strings.string(for: NativeUIStringKey.preRecordingBarWindow)
    )
    applyButtonPresentation(
      areaButton,
      imageName: "rectangle.dashed",
      label: strings.string(for: NativeUIStringKey.preRecordingBarArea)
    )
    applyButtonPresentation(
      cameraButton,
      imageName: "video",
      label: strings.string(for: NativeUIStringKey.preRecordingBarCamera)
    )
    applyButtonPresentation(
      micButton,
      imageName: "mic",
      label: strings.string(for: NativeUIStringKey.preRecordingBarMic)
    )
    applyButtonPresentation(
      systemAudioButton,
      imageName: "speaker.wave.2",
      label: strings.string(for: NativeUIStringKey.preRecordingBarSystem)
    )
    applyButtonPresentation(
      updateButton,
      imageName: "arrow.up.circle",
      label: strings.string(for: NativeUIStringKey.preRecordingBarUpdate)
    )
    updateState(state)
  }

  private func createButton(imageName: String, label: String? = nil, action: Selector) -> NSButton {
    let button = NSButton(frame: .zero)

    // FIX 1: Change .recolorOnHover to a valid AppKit style
    button.bezelStyle = .shadowlessSquare

    button.isBordered = false
    applyButtonPresentation(button, imageName: imageName, label: label)
    button.target = self
    button.action = action

    // Default color for non-active buttons
    button.contentTintColor = .secondaryLabelColor
    button.setButtonType(.momentaryChange)

    if label != nil {
      button.font = .systemFont(ofSize: 14, weight: .medium)
    }

    return button
  }

  private func applyButtonPresentation(_ button: NSButton, imageName: String, label: String?) {
    button.title = label ?? ""
    if #available(macOS 11.0, *) {
      let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
      button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: label)?
        .withSymbolConfiguration(config)
    } else {
      button.image = NSImage.symbol(imageName, accessibilityDescription: label)
    }
    button.imagePosition = label == nil ? .imageOnly : .imageLeft
  }

  private func createSeparator() -> NSView {
    let separator = NSView()
    separator.wantsLayer = true

    // FIX 3: Compatibility check for separator color if needed
    separator.layer?.backgroundColor = NSColor.separatorColor.cgColor

    separator.translatesAutoresizingMaskIntoConstraints = false
    separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
    separator.heightAnchor.constraint(equalToConstant: 28).isActive = true
    return separator
  }

  func updateState(_ newState: [String: Any]) {
    self.state = newState

    // NativeLogger.d("PreRecordingBar", "newState => \(newState)")
    // Update visibility
    let updateAvailable = newState["updateAvailable"] as? Bool ?? false
    updateButton.isHidden = !updateAvailable

    // Manage bounce animation
    if updateAvailable && updateAnimationTimer == nil {
      startUpdateBounceAnimation()
    } else if !updateAvailable {
      stopUpdateBounceAnimation()
    }

    // Update selection states (styling)
    let targetMode = newState["targetMode"] as? Int ?? DisplayTargetMode.explicitID.rawValue
    displayButton.contentTintColor =
      targetMode == DisplayTargetMode.explicitID.rawValue
      ? .controlAccentColor : .secondaryLabelColor
    windowButton.contentTintColor =
      targetMode == DisplayTargetMode.singleAppWindow.rawValue
      ? .controlAccentColor : .secondaryLabelColor
    areaButton.contentTintColor =
      targetMode == DisplayTargetMode.areaRecording.rawValue
      ? .controlAccentColor : .secondaryLabelColor

    let rawCamId = newState["selectedCamId"] as? String
    let camSelected =
      rawCamId != nil && rawCamId != "" && rawCamId != "none" && rawCamId != "__none__"
    cameraButton.contentTintColor = camSelected ? .controlAccentColor : .secondaryLabelColor

    let micEnabled = newState["micEnabled"] as? Bool ?? false
    micButton.contentTintColor = micEnabled ? .controlAccentColor : .secondaryLabelColor

    let systemAudioEnabled = newState["systemAudioEnabled"] as? Bool ?? false
    systemAudioButton.contentTintColor =
      systemAudioEnabled ? .controlAccentColor : .secondaryLabelColor

    // Record button state driven by phase
    let phase = newState["phase"] as? Int ?? 0
    // phases:
    // 0: idle
    // 1: startingRecording
    // 2: recording
    // 3: pausedRecording
    // 4: stoppingRecording
    // 5: finalizingRecording
    // 6: openingPreview
    // 7: previewLoading
    // 8: previewReady
    // 9: closingPreview
    // 10: exporting
    let isStarting = phase == 1
    let isRecording = phase == 2
    let isPaused = phase == 3
    let isStopping = phase == 4
    let isFinalizing = phase == 5
    let isExporting = phase == 10
    let canPauseResume = newState["canPauseResume"] as? Bool ?? false
    let pauseResumeInFlight = newState["pauseResumeInFlight"] as? Bool ?? false
    let recordEnabled = phase == 0

    let canInteract = !isStarting && !isRecording && !isPaused && !isStopping && !isFinalizing && !isExporting
    displayButton.isEnabled = canInteract
    windowButton.isEnabled = canInteract
    areaButton.isEnabled = canInteract
    cameraButton.isEnabled = canInteract
    micButton.isEnabled = canInteract
    systemAudioButton.isEnabled = canInteract
    closeButton.isEnabled = !isStarting && !isStopping

    pauseResumeButton.isHidden = !(canPauseResume && (isRecording || isPaused))
    pauseResumeButton.isEnabled = !pauseResumeInFlight && (isRecording || isPaused)
    if !pauseResumeButton.isHidden {
      let strings = NativeStringsStore.shared
      let buttonTitle = strings.string(
        for: isPaused ? NativeUIStringKey.preRecordingBarResume : NativeUIStringKey.preRecordingBarPause
      )
      let accessibilityDescription = strings.string(
        for: isPaused
          ? NativeUIStringKey.recordingIndicatorResumeRecording
          : NativeUIStringKey.recordingIndicatorPauseRecording
      )
      if #available(macOS 11.0, *) {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let symbolName = isPaused ? "play.fill" : "pause.fill"
        pauseResumeButton.image = NSImage(
          systemSymbolName: symbolName,
          accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(config)
      } else {
        pauseResumeButton.image = NSImage.symbol(
          isPaused ? "play.fill" : "pause.fill",
          accessibilityDescription: accessibilityDescription
        )
      }
      pauseResumeButton.title = buttonTitle
      pauseResumeButton.contentTintColor = isPaused ? .controlAccentColor : .secondaryLabelColor
    }

    if isStarting {
      recordButton.image = nil
      recordButton.isEnabled = false
      recordSpinner.startAnimation(nil)
    } else if isRecording || isPaused {
      recordSpinner.stopAnimation(nil)
      if #available(macOS 11.0, *) {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        recordButton.image = NSImage(
          systemSymbolName: "stop.circle.fill",
          accessibilityDescription: NativeStringsStore.shared.string(
            for: NativeUIStringKey.accessibilityStopRecording
          )
        )?
          .withSymbolConfiguration(config)
      } else {
        recordButton.image = NSImage.symbol(
          "stop.circle.fill",
          accessibilityDescription: NativeStringsStore.shared.string(
            for: NativeUIStringKey.accessibilityStopRecording
          )
        )
      }
      recordButton.contentTintColor = .systemRed
      recordButton.isEnabled = !isFinalizing
    } else if isStopping || isFinalizing {
      recordButton.image = nil
      recordButton.isEnabled = false
      recordSpinner.startAnimation(nil)
    } else {
      recordSpinner.stopAnimation(nil)
      if #available(macOS 11.0, *) {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        recordButton.image = NSImage(
          systemSymbolName: "record.circle",
          accessibilityDescription: NativeStringsStore.shared.string(
            for: NativeUIStringKey.accessibilityStartRecording
          )
        )?
          .withSymbolConfiguration(config)
      } else {
        recordButton.image = NSImage.symbol(
          "record.circle",
          accessibilityDescription: NativeStringsStore.shared.string(
            for: NativeUIStringKey.accessibilityStartRecording
          )
        )
      }
      recordButton.contentTintColor = recordEnabled ? .controlAccentColor : .secondaryLabelColor
      recordButton.isEnabled = recordEnabled
    }
  }

  @objc private func closeTapped() { onAction?(NativeBarAction.closeTapped, nil) }
  @objc private func displayTapped() { onAction?(NativeBarAction.displayTapped, nil) }
  @objc private func windowTapped() { onAction?(NativeBarAction.windowTapped, nil) }
  @objc private func areaTapped() { onAction?(NativeBarAction.areaTapped, nil) }
  @objc private func cameraTapped() { onAction?(NativeBarAction.cameraTapped, nil) }
  @objc private func micTapped() { onAction?(NativeBarAction.micTapped, nil) }
  @objc private func systemAudioTapped() { onAction?(NativeBarAction.systemAudioTapped, nil) }
  @objc private func updateTapped() { onAction?(NativeBarAction.updateTapped, nil) }
  @objc private func recordTapped() { onAction?(NativeBarAction.recordTapped, nil) }
  @objc private func pauseResumeTapped() {
    let phase = state["phase"] as? Int ?? 0
    if phase == 3 {
      onAction?(NativeBarAction.resumeTapped, nil)
    } else {
      onAction?(NativeBarAction.pauseTapped, nil)
    }
  }

  // MARK: - Animations

  private func startUpdateBounceAnimation() {
    // Initial bounce
    bounceUpdateButton()

    // Repeat every 3.5 seconds
    updateAnimationTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) {
      [weak self] _ in
      self?.bounceUpdateButton()
    }
  }

  private func stopUpdateBounceAnimation() {
    updateAnimationTimer?.invalidate()
    updateAnimationTimer = nil
    updateButton.layer?.removeAnimation(forKey: "bounce")
  }

  private func bounceUpdateButton() {
    guard let layer = updateButton.layer else { return }

    let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
    bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
    bounce.duration = 0.6

    // Keyframes for the bounce (up, down slightly, up again slightly, return)
    bounce.values = [0, 8, 0, 3, 0]

    // Key times corresponding to the values
    bounce.keyTimes = [0, 0.4, 0.7, 0.85, 1.0]

    bounce.isAdditive = true  // Add to current position without breaking autolayout

    layer.add(bounce, forKey: "bounce")
  }
}
