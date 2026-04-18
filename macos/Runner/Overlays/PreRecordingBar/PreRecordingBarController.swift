import Cocoa
import FlutterMacOS

class PreRecordingBarController: NSWindowController, NSPopoverDelegate {
  private var barView: PreRecordingBarView!
  private var panel: NSPanel!

  var onAction: ((String, [String: Any]?) -> Void)?

  private let recorder: ScreenRecorderFacade
  private weak var channel: FlutterMethodChannel?

  // Current selection state for popovers
  private var selectedDisplayId: Int?
  private var selectedAppWindowId: Int?
  private var selectedAudioSourceId: String?
  private var selectedCamId: String?
  private var targetMode: Int = DisplayTargetMode.explicitID.rawValue

  private var currentPopover: NSPopover?
  private var outsideClickLocalMonitor: Any?
  private var outsideClickGlobalMonitor: Any?
  private let frameAutosaveName = NSWindow.FrameAutosaveName("ClingfyPreRecordingBarFrame")

  var isVisible: Bool {
    panel.isVisible
  }

  init(recorder: ScreenRecorderFacade, channel: FlutterMethodChannel?) {
    self.recorder = recorder
    self.channel = channel

    let contentRect = NSRect(x: 0, y: 0, width: 600, height: 64)
    let panel = NSPanel(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isMovableByWindowBackground = true

    self.panel = panel
    super.init(window: panel)

    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.ignoresMouseEvents = false

    barView = PreRecordingBarView(frame: contentRect)
    barView.onAction = { [weak self] type, payload in
      self?.handleBarAction(type: type, payload: payload)
    }
    panel.contentView = barView

    NativeLogger.d("PreRecordingBar", "init")
    restoreOrPlaceInitialFrame()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setVisible(_ visible: Bool) {
    if visible {
      if !panel.isVisible {
        panel.orderFront(nil)
      }
    } else {
      currentPopover?.performClose(nil)
      panel.orderOut(nil)
    }
  }

  func updateState(_ state: [String: Any]) {
    barView.updateState(state)

    self.targetMode = state["targetMode"] as? Int ?? DisplayTargetMode.explicitID.rawValue
    self.selectedDisplayId = state["selectedDisplayId"] as? Int
    self.selectedAppWindowId = state["selectedAppWindowId"] as? Int
    self.selectedAudioSourceId = state["selectedAudioSourceId"] as? String
    self.selectedCamId = state["selectedCamId"] as? String

    // 1. Force the view to calculate its layout immediately so 'fittingSize' reflects
    // changes (like hidden/shown buttons)
    barView.layoutSubtreeIfNeeded()

    // 2. Get the current frame (where the user dragged it)
    let currentFrame = panel.frame

    // 3. Get the new required width
    let newWidth = barView.fittingSize.width

    // 4. Calculate the X position so the bar stays centered on its current location
    let newX = currentFrame.midX - (newWidth / 2)

    // 5. Apply the new frame
    panel.setFrame(
      NSRect(
        x: newX,
        y: currentFrame.origin.y,  // Keep the current Y
        width: newWidth,
        height: 64
      ),
      display: true,
      animate: true
    )
    // NativeLogger.d(
    //   "PreRecordingBar",
    //   "updateState newX: \(newX), newWidth: \(newWidth), currentFrame.origin.x: \(currentFrame.origin.x), currentFrame.origin.y: \(currentFrame.origin.y), currentFrame.size.width: \(currentFrame.size.width), currentFrame.size.height: \(currentFrame.size.height), panel.frame.origin.x: \(panel.frame.origin.x), panel.frame.origin.y: \(panel.frame.origin.y), panel.frame.size.width: \(panel.frame.size.width), panel.frame.size.height: \(panel.frame.size.height)"
    // )

    // REMOVED: updatePosition()
    // We removed this call because it forced the window back to the default start position
  }

  func refreshLocalizedStrings() {
    barView.refreshLocalizedStrings()
  }

  // func updateState2(_ state: [String: Any]) {
  //   barView.updateState(state)

  //   self.targetMode = state["targetMode"] as? Int ?? DisplayTargetMode.explicitID.rawValue
  //   self.selectedDisplayId = state["selectedDisplayId"] as? Int
  //   self.selectedAppWindowId = state["selectedAppWindowId"] as? Int
  //   self.selectedAudioSourceId = state["selectedAudioSourceId"] as? String
  //   self.selectedCamId = state["selectedCamId"] as? String

  //   // Adjust size based on content
  //   panel.setFrame(
  //     NSRect(
  //       x: panel.frame.origin.x, y: panel.frame.origin.y, width: barView.fittingSize.width,
  //       height: 64), display: true)
  //   updatePosition()
  // }

  private func handleBarAction(type: String, payload: [String: Any]?) {
    switch type {
    case "displayTapped":
      showDisplayPopover()
    case "windowTapped":
      showWindowPopover()
    case "areaTapped":
      onAction?("areaTapped", nil)
    case "cameraTapped":
      showCameraPopover()
    case "micTapped":
      showMicPopover()
    case "systemAudioTapped":
      onAction?(NativeBarAction.systemAudioTapped, nil)
    default:
      onAction?(type, payload)
    }
  }

  private func restoreOrPlaceInitialFrame() {
    let restored = panel.setFrameUsingName(frameAutosaveName)
    panel.setFrameAutosaveName(frameAutosaveName)

    if !restored {
      placeDefaultPosition()
    }
  }

  private func placeDefaultPosition() {
    guard let screen = NSScreen.main else { return }
    let screenFrame = screen.visibleFrame
    let barWidth = barView.fittingSize.width
    let x = screenFrame.origin.x + (screenFrame.width - barWidth) / 2
    let y = screenFrame.origin.y + 32

    panel.setFrameOrigin(NSPoint(x: x, y: y))
  }

  // MARK: - Popovers

  private func showDisplayPopover() {
    NativeLogger.d("PreRecordingBar", "showDisplayPopover")
    fetchDisplayOptions { [weak self] options in
      guard let self = self else { return }
      self.presentPopover(
        title: NativeStringsStore.shared.string(for: NativeUIStringKey.preRecordingBarSelectDisplay),
        options: options,
        anchor: self.barView.displayButton
      ) { selectedId in
        NativeLogger.d("PreRecordingBar", "Display selected: \(selectedId)")
        if let idInt = Int(selectedId) {
          self.recorder.setDisplayTargetMode(modeRaw: 0, result: { _ in })
          self.recorder.setDisplay(id: idInt as NSNumber, result: { _ in })
          self.notifyFlutterSelection(type: "display", id: idInt)
          self.notifyFlutterSelection(type: "mode", id: DisplayTargetMode.explicitID.rawValue)
        }
      } refresh: { controller, finish in
        self.fetchDisplayOptions { newOptions in
          DispatchQueue.main.async {
            controller.updateOptions(newOptions)
            finish()
          }
        }
      }
    }
  }

  private func fetchDisplayOptions(completion: @escaping ([PickerOption]) -> Void) {
    recorder.getDisplays { [weak self] result in
      guard let self = self, let displays = result as? [[String: Any]] else {
        completion([])
        return
      }
      let options = displays.map { dict -> PickerOption in
        let rawId = dict["id"] as? NSNumber
        let id = rawId?.stringValue ?? "0"
        let name =
          dict["name"] as? String
          ?? NativeStringsStore.shared.string(for: NativeUIStringKey.preRecordingBarUnknownDisplay)
        let isSelected =
          (self.selectedDisplayId == rawId?.intValue
            && self.targetMode == DisplayTargetMode.explicitID.rawValue)
        return PickerOption(id: id, label: name, isSelected: isSelected)
      }
      completion(options)
    }
  }

  private func showWindowPopover() {
    NativeLogger.d("PreRecordingBar", "showWindowPopover")
    fetchWindowOptions { [weak self] options in
      guard let self = self else { return }
      self.presentPopover(
        title: NativeStringsStore.shared.string(for: NativeUIStringKey.preRecordingBarSelectWindow),
        options: options,
        anchor: self.barView.windowButton
      ) { selectedId in
        NativeLogger.d("PreRecordingBar", "Window selected: \(selectedId)")
        let winId = selectedId == "none" ? nil : Int(selectedId)
        // FIX: Use mode 2 (singleAppWindow)
        self.recorder.setDisplayTargetMode(modeRaw: 2, result: { _ in })
        self.recorder.setAppWindow(windowId: winId as NSNumber?, result: { _ in })
        self.notifyFlutterSelection(type: "window", id: winId)
        self.notifyFlutterSelection(type: "mode", id: DisplayTargetMode.singleAppWindow.rawValue)
      } refresh: { controller, finish in
        self.fetchWindowOptions { newOptions in
          DispatchQueue.main.async {
            controller.updateOptions(newOptions)
            finish()
          }
        }
      }
    }
  }

  private func fetchWindowOptions(completion: @escaping ([PickerOption]) -> Void) {
    recorder.getAppWindows { [weak self] result in
      guard let self = self, let windows = result as? [[String: Any]] else {
        completion([])
        return
      }
      var options = windows.map { dict -> PickerOption in
        let rawId = dict["windowId"] as? NSNumber
        let id = rawId?.stringValue ?? "0"
        let appName = dict["appName"] as? String ?? ""
        let title = dict["title"] as? String ?? ""
        var name = appName
        if !title.isEmpty && title != appName { name = "\(appName) - \(title)" }
        if name.isEmpty {
          name = NativeStringsStore.shared.string(
            for: NativeUIStringKey.preRecordingBarUnknownWindow
          )
        }
        // FIX: Check against singleAppWindow (2)
        let isSelected =
          (self.selectedAppWindowId == rawId?.intValue
            && self.targetMode == DisplayTargetMode.singleAppWindow.rawValue)

        var icon: NSImage? = nil
        if let pid = dict["pid"] as? Int {
          icon = NSRunningApplication(processIdentifier: pid_t(pid))?.icon
        }
        if icon == nil {
          if #available(macOS 11.0, *) {
            icon = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
          } else {
            icon = NSImage(named: NSImage.applicationIconName)
          }
        }
        return PickerOption(id: id, label: name, isSelected: isSelected, icon: icon)
      }

      let noneIcon: NSImage?
      if #available(macOS 11.0, *) {
        noneIcon = NSImage(systemSymbolName: "nosign", accessibilityDescription: nil)
      } else {
        noneIcon = NSImage(named: NSImage.stopProgressTemplateName)
      }
      options.insert(
        PickerOption(
          id: "none",
          label: NativeStringsStore.shared.string(for: NativeUIStringKey.preRecordingBarNone),
          // FIX: Check against mode 2
          isSelected: self.selectedAppWindowId == nil && self.targetMode == 2,
          icon: noneIcon), at: 0)
      completion(options)
    }
  }

  private func showMicPopover() {
    NativeLogger.d("PreRecordingBar", "showMicPopover")
    fetchMicOptions { [weak self] options in
      guard let self = self else { return }
      self.presentPopover(
        title: NativeStringsStore.shared.string(
          for: NativeUIStringKey.preRecordingBarSelectMicrophone
        ),
        options: options,
        anchor: self.barView.micButton
      ) { selectedId in
        NativeLogger.d("PreRecordingBar", "Mic selected: \(selectedId)")
        self.recorder.setAudioSource(
          id: selectedId == "__none__" ? nil : selectedId, result: { _ in })
        self.notifyFlutterSelection(type: "mic", id: selectedId)
      } refresh: { controller, finish in
        self.fetchMicOptions { newOptions in
          DispatchQueue.main.async {
            controller.updateOptions(newOptions)
            finish()
          }
        }
      }
    }
  }

  private func fetchMicOptions(completion: @escaping ([PickerOption]) -> Void) {
    recorder.getAudioSources { [weak self] result in
      guard let self = self, let devices = result as? [[String: Any]] else {
        completion([])
        return
      }
      var options = devices.map { dict -> PickerOption in
        let id = dict["id"] as? String ?? ""
        let name =
          dict["name"] as? String
          ?? NativeStringsStore.shared.string(for: NativeUIStringKey.preRecordingBarUnknownMic)
        return PickerOption(id: id, label: name, isSelected: (self.selectedAudioSourceId == id))
      }
      options.insert(
        PickerOption(
          id: "__none__",
          label: NativeStringsStore.shared.string(
            for: NativeUIStringKey.preRecordingBarDoNotRecordAudio
          ),
          isSelected: self.selectedAudioSourceId == "__none__"), at: 0)
      completion(options)
    }
  }

  private func showCameraPopover() {
    NativeLogger.d("PreRecordingBar", "showCameraPopover")
    fetchCameraOptions { [weak self] options in
      guard let self = self else { return }
      self.presentPopover(
        title: NativeStringsStore.shared.string(for: NativeUIStringKey.preRecordingBarSelectCamera),
        options: options,
        anchor: self.barView.cameraButton
      ) { selectedId in
        NativeLogger.d("PreRecordingBar", "Camera selected: \(selectedId)")
        let camId = selectedId == "none" ? nil : selectedId
        self.recorder.setVideoSource(id: camId, result: { _ in })
        self.notifyFlutterSelection(type: "camera", id: camId)
      } refresh: { controller, finish in
        self.fetchCameraOptions { newOptions in
          DispatchQueue.main.async {
            controller.updateOptions(newOptions)
            finish()
          }
        }
      }
    }
  }

  private func fetchCameraOptions(completion: @escaping ([PickerOption]) -> Void) {
    recorder.getVideoSources { [weak self] result in
      guard let self = self, let devices = result as? [[String: Any]] else {
        completion([])
        return
      }

      let raw = self.selectedCamId
      let normalizedSelected =
        (raw == nil || raw == "" || raw == "none" || raw == "__none__") ? nil : raw

      var options = devices.map { dict -> PickerOption in
        let id = dict["id"] as? String ?? ""
        let name =
          dict["name"] as? String
          ?? NativeStringsStore.shared.string(for: NativeUIStringKey.preRecordingBarUnknownCamera)
        return PickerOption(id: id, label: name, isSelected: (normalizedSelected == id))
      }
      options.insert(
        PickerOption(
          id: "none",
          label: NativeStringsStore.shared.string(for: NativeUIStringKey.preRecordingBarNoCamera),
          isSelected: normalizedSelected == nil
        ),
        at: 0
      )
      completion(options)
    }
  }

  private func presentPopover(
    title: String,
    options: [PickerOption],
    anchor: NSView,
    select: @escaping (String) -> Void,
    refresh: @escaping (OptionPickerPopover, @escaping () -> Void) -> Void
  ) {
    // IMPORTANT: schedule on main queue (and on next tick)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }

      // Reuse the current popover when the content type matches.
      if let popover = self.currentPopover, popover.isShown,
        let controller = popover.contentViewController as? OptionPickerPopover,
        controller.titleText == title
      {
        NativeLogger.d("PreRecordingBar", "Reusing existing popover for '\(title)'")
        controller.onSelect = { [weak popover] id in
          select(id)
          popover?.performClose(nil)
        }
        controller.onRefresh = { finish in refresh(controller, finish) }
        controller.updateOptions(options)
        return
      }

      // 2. Otherwise, close any existing popover and create a new one
      if self.currentPopover?.isShown == true {
        self.currentPopover?.performClose(nil)
      }

      // Force layout so anchor.bounds is correct
      anchor.superview?.layoutSubtreeIfNeeded()

      guard let w = anchor.window, w.isVisible, !anchor.isHidden else { return }

      let controller = OptionPickerPopover(title: title, options: options)

      let popover = NSPopover()
      popover.contentViewController = controller
      popover.behavior = .transient
      popover.animates = true
      popover.delegate = self

      controller.onSelect = { [weak popover] id in
        select(id)
        popover?.performClose(nil)
      }
      controller.onRefresh = { finish in refresh(controller, finish) }

      popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
      // Install the outside click monitors AFTER showing
      self.installOutsideClickMonitors(popover: popover)

      self.currentPopover = popover

      DispatchQueue.main.async { [weak self, weak popover] in
        guard let self, let popover else { return }
        if let popoverWindow = popover.contentViewController?.view.window {
          popoverWindow.level = self.panel.level + 1
        }
      }
    }
  }

  private func notifyFlutterSelection(type: String, id: Any?) {
    NativeLogger.d(
      "PreRecordingBar", "notifyFlutterSelection \(type) id: \(String(describing: id))")
    channel?.invokeMethod(
      "nativeSelectionChanged",
      arguments: [
        "type": type,
        "id": id as Any,
      ])
  }

  private func removeOutsideClickMonitors() {
    if let m = outsideClickLocalMonitor { NSEvent.removeMonitor(m) }
    if let m = outsideClickGlobalMonitor { NSEvent.removeMonitor(m) }
    outsideClickLocalMonitor = nil
    outsideClickGlobalMonitor = nil
  }

  func popoverWillClose(_ notification: Notification) {
    removeOutsideClickMonitors()
    currentPopover = nil
  }

  private func installOutsideClickMonitors(popover: NSPopover) {
    removeOutsideClickMonitors()

    let handler: () -> Void = { [weak self, weak popover] in
      guard let self, let popover, popover.isShown else { return }

      // Global screen coords (origin bottom-left)
      let mouse = NSEvent.mouseLocation

      // Frames in screen coords
      let popFrame = popover.contentViewController?.view.window?.frame ?? .zero
      let barFrame = self.panel.frame

      // If click is inside popover or inside the bar, do nothing
      if popFrame.contains(mouse) { return }
      if barFrame.contains(mouse) { return }

      popover.performClose(nil)
    }

    // Local monitor: catches clicks while our app is active
    outsideClickLocalMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { event in
      handler()
      return event
    }

    // Global monitor: catches clicks when user clicks outside and activates another app
    outsideClickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { _ in
      DispatchQueue.main.async { handler() }
    }
  }
}
