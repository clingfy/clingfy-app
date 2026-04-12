import AVFoundation
import Cocoa
import FlutterMacOS
import Foundation

private enum NativeWorkflowPhase: Int {
  case idle = 0
  case startingRecording = 1
  case recording = 2
  case pausedRecording = 3
  case stoppingRecording = 4
  case finalizingRecording = 5
  case openingPreview = 6
  case previewLoading = 7
  case previewReady = 8
  case closingPreview = 9
  case exporting = 10
}

class MainFlutterWindow: NSWindow {
  private let screenRecorder = ScreenRecorderFacade()
  private let eventHandler = AudioDevicesEventHandler()
  private var channel: FlutterMethodChannel?
  private var menuBarController: MenuBarController?
  private var preRecordingBarController: PreRecordingBarController?

  private var isInlinePreviewActive = false
  private var preRecordingBarEnabled = true
  private var preRecordingBarDismissedForCurrentCycle = false
  private var isCountdownActive = false
  private var isAreaSelectionInProgress = false
  private var appPhaseRaw: Int = NativeWorkflowPhase.idle.rawValue

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    let registrar = flutterViewController.registrar(forPlugin: "InlinePreviewPlugin")
    let previewFactory = InlinePreviewViewFactory(messenger: registrar.messenger)
    registrar.register(previewFactory, withId: "inline_preview_view")

    RegisterGeneratedPlugins(registry: flutterViewController)

    self.channel = FlutterMethodChannel(
      name: "com.clingfy/screen_recorder",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    NativeLogger.configure(with: self.channel!)
    UpdaterController.shared.channel = self.channel
    NativeLogger.i("Main", "Logger configured")
    let playerEvents = FlutterEventChannel(
      name: "com.clingfy/player/events",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    playerEvents.setStreamHandler(PlayerEventHandler())
    let workflowEvents = FlutterEventChannel(
      name: NativeChannel.workflowEvents,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    workflowEvents.setStreamHandler(WorkflowEventHandler())

    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "startRecording":
        let args = call.arguments as? [String: Any]
        self.screenRecorder.startRecording(args: args, result: result)
      case "stopRecording":
        self.screenRecorder.stopRecording(result: result)
      case "pauseRecording":
        self.screenRecorder.pauseRecording(result: result)
      case "resumeRecording":
        self.screenRecorder.resumeRecording(result: result)
      case "togglePauseRecording":
        self.screenRecorder.togglePauseRecording(result: result)
      case "getRecordingCapabilities":
        self.screenRecorder.getRecordingCapabilities(result: result)
      case "getAudioSources":
        self.screenRecorder.getAudioSources(result: result)
      case "setAudioSource":
        let args = call.arguments as? [String: Any]
        self.screenRecorder.setAudioSource(id: args?["id"] as? String, result: result)

      case "getVideoSources":
        self.screenRecorder.getVideoSources(result: result)

      case "setVideoSource":
        let args = call.arguments as? [String: Any]
        self.screenRecorder.setVideoSource(id: args?["id"] as? String, result: result)

      case "showCameraOverlay":
        NativeLogger.w(
          "CameraOverlayBridge", "CALL showCameraOverlay() from channel",
          context: [
            "method": call.method,
            "args": call.arguments ?? "nil",
          ])
        let args = call.arguments as? [String: Any]
        let size = (args?["size"] as? Double)
        self.screenRecorder.showCameraOverlay(size: size, result: result)

      case "setCameraOverlaySize":
        let args = call.arguments as? [String: Any]
        let size = (args?["size"] as? Double)
        self.screenRecorder.setCameraOverlaySize(size: size, result: result)

      case "hideCameraOverlay":
        self.screenRecorder.hideCameraOverlay(result: result)

      case "setCameraOverlayFrame":
        let args = call.arguments as? [String: Any]
        let x = (args?["x"] as? Double) ?? 40
        let y = (args?["y"] as? Double) ?? 40
        let w = (args?["w"] as? Double) ?? 220
        let h = (args?["h"] as? Double) ?? 220
        self.screenRecorder.setCameraOverlayFrame(x: x, y: y, width: w, height: h, result: result)
      case "setOverlayEnabled":
        let args = call.arguments as? [String: Any]
        let enabled = (args?["enabled"] as? Bool) ?? false
        self.screenRecorder.setOverlayEnabled(enabled: enabled, result: result)
      case "setOverlayLinkedToRecording":
        let args = call.arguments as? [String: Any]
        let linked = (args?["linked"] as? Bool) ?? true
        self.screenRecorder.setOverlayLinkedToRecording(linked: linked, result: result)

      case "setCameraOverlayBorder":
        let args = call.arguments as? [String: Any]
        let border = args?["border"] as? Int ?? 0
        self.screenRecorder.setCameraOverlayBorder(border: border, result: result)
      case "setCameraOverlayPosition":
        let args = call.arguments as? [String: Any]
        let position = args?["position"] as? Int ?? 3
        self.screenRecorder.setCameraOverlayPosition(position: position, result: result)
      case "setCameraOverlayCustomPosition":
        if let args = call.arguments as? [String: Any],
          let normalizedX = args["normalizedX"] as? Double,
          let normalizedY = args["normalizedY"] as? Double
        {
          self.screenRecorder.setCameraOverlayCustomPosition(
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            result: result
          )
        } else {
          result(
            FlutterError(
              code: NativeErrorCode.badArgs,
              message: "Missing normalizedX/normalizedY",
              details: nil
            )
          )
        }
      case "setCameraOverlayShape":
        let args = call.arguments as? [String: Any]
        let shapeId =
          (args?["shapeId"] as? Int)
          ?? (args?["shape"] as? Int)
          ?? CameraOverlayShapeID.defaultValue.rawValue
        self.screenRecorder.setCameraOverlayShape(shapeId: shapeId, result: result)

      case "setCameraOverlayShadow":
        let args = call.arguments as? [String: Any]
        let shadow = (args?["shadow"] as? Int) ?? 0
        self.screenRecorder.setCameraOverlayShadow(shadow: shadow, result: result)

      case "setCameraOverlayRoundness":
        let args = call.arguments as? [String: Any]
        let roundness = (args?["roundness"] as? Double) ?? 0.0
        self.screenRecorder.setCameraOverlayRoundness(roundness: roundness, result: result)

      case "setCameraOverlayOpacity":
        let args = call.arguments as? [String: Any]
        let opacity = (args?["opacity"] as? Double) ?? 1.0
        self.screenRecorder.setCameraOverlayOpacity(opacity: opacity, result: result)

      case "setOverlayMirror":
        let args = call.arguments as? [String: Any]
        let mirrored = (args?["mirrored"] as? Bool) ?? true
        self.screenRecorder.setOverlayMirror(mirrored, result: result)

      case "setCameraOverlayHighlight":
        if let args = call.arguments as? [String: Any],
          let enabled = args["enabled"] as? Bool
        {
          self.screenRecorder.setCameraOverlayHighlight(enabled: enabled, result: result)
        } else {
          result(
            FlutterError(code: NativeErrorCode.badArgs, message: "Missing enabled", details: nil))
        }
      case "setCameraOverlayHighlightStrength":
        if let args = call.arguments as? [String: Any],
          let strength = args["strength"] as? Double
        {
          self.screenRecorder.setCameraOverlayHighlightStrength(strength: strength, result: result)
        } else {
          result(
            FlutterError(code: NativeErrorCode.badArgs, message: "Missing strength", details: nil))
        }

      case "setChromaKeyEnabled":
        if let args = call.arguments as? [String: Any],
          let enabled = args["enabled"] as? Bool
        {
          self.screenRecorder.setChromaKeyEnabled(enabled)
          result(nil)
        } else {
          result(
            FlutterError(
              code: NativeErrorCode.invalidArgument, message: "enabled is required", details: nil))
        }

      case "setChromaKeyColor":
        if let args = call.arguments as? [String: Any],
          let colorInt = args["color"] as? Int
        {
          let a = CGFloat((colorInt >> 24) & 0xFF) / 255.0
          let r = CGFloat((colorInt >> 16) & 0xFF) / 255.0
          let g = CGFloat((colorInt >> 8) & 0xFF) / 255.0
          let b = CGFloat(colorInt & 0xFF) / 255.0
          let color = NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
          self.screenRecorder.setChromaKeyColor(color, result: result)
        } else {
          result(
            FlutterError(code: NativeErrorCode.badArgs, message: "Missing color", details: nil))
        }

      case "setCameraOverlayBorderWidth":
        if let args = call.arguments as? [String: Any],
          let width = args["width"] as? Double
        {
          self.screenRecorder.setCameraOverlayBorderWidth(width: width, result: result)
        } else {
          result(
            FlutterError(code: NativeErrorCode.badArgs, message: "Missing width", details: nil))
        }

      case "setCameraOverlayBorderColor":
        if let args = call.arguments as? [String: Any],
          let colorInt = args["color"] as? Int
        {
          let a = CGFloat((colorInt >> 24) & 0xFF) / 255.0
          let r = CGFloat((colorInt >> 16) & 0xFF) / 255.0
          let g = CGFloat((colorInt >> 8) & 0xFF) / 255.0
          let b = CGFloat(colorInt & 0xFF) / 255.0
          let color = NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
          self.screenRecorder.setCameraOverlayBorderColor(color, result: result)
        } else {
          result(
            FlutterError(code: NativeErrorCode.badArgs, message: "Missing color", details: nil))
        }
      case "setChromaKeyStrength":
        if let args = call.arguments as? [String: Any],
          let strength = args["strength"] as? Double
        {
          self.screenRecorder.setChromaKeyStrength(strength)
          result(nil)
        } else {
          result(
            FlutterError(
              code: NativeErrorCode.invalidArgument, message: "strength is required", details: nil))
        }
      case "setCursorHighlightLinkedToRecording":
        let args = call.arguments as? [String: Any]
        let linked = (args?["linked"] as? Bool) ?? true
        self.screenRecorder.setCursorHighlightLinkedToRecording(linked: linked, result: result)

      case "setCursorHighlightEnabled":
        let args = call.arguments as? [String: Any]
        let enabled = (args?["enabled"] as? Bool) ?? false
        self.screenRecorder.setCursorHighlightEnabled(enabled, result: result)

      case "setRecordingQuality":
        let args = call.arguments as? [String: Any]
        self.screenRecorder.setRecordingQuality(args?["quality"] as? String, result: result)

      case "getExcludeRecorderApp":
        self.screenRecorder.getExcludeRecorderApp(result: result)

      case "setExcludeRecorderApp":
        let args = call.arguments as? [String: Any]
        let exclude = (args?["exclude"] as? Bool) ?? false
        self.screenRecorder.setExcludeRecorderApp(exclude, result: result)

      case "getExcludeMicFromSystemAudio":
        self.screenRecorder.getExcludeMicFromSystemAudio(result: result)

      case "setExcludeMicFromSystemAudio":
        let args = call.arguments as? [String: Any]
        let exclude = (args?["exclude"] as? Bool) ?? true
        self.screenRecorder.setExcludeMicFromSystemAudio(exclude, result: result)

      case "setCaptureFrameRate":
        let args = call.arguments as? [String: Any]
        if let fps = args?["fps"] as? Int {
          self.screenRecorder.setCaptureFrameRate(fps)
        }
        result(nil)

      case "getCaptureDiagnostics":
        self.screenRecorder.getCaptureDiagnostics(result: result)
      case "getStorageSnapshot":
        self.screenRecorder.getStorageSnapshot(result: result)

      case "getDisplays":
        self.screenRecorder.getDisplays(result: result)
      case "getAppWindows":
        self.screenRecorder.getAppWindows(result: result)

      case "setDisplay":
        let args = call.arguments as? [String: Any]
        // expect UInt32 coming from Dart (int)
        let id = args?["id"] as? NSNumber
        self.screenRecorder.setDisplay(id: id, result: result)
      case "setAppWindowTarget":
        let args = call.arguments as? [String: Any]
        let windowId = args?["windowId"] as? NSNumber
        self.screenRecorder.setAppWindow(windowId: windowId, result: result)

      case "setDisplayTargetMode":
        if let args = call.arguments as? [String: Any],
          let raw = args["mode"] as? NSNumber
        {
          self.screenRecorder.setDisplayTargetMode(modeRaw: raw, result: result)
        } else {
          result(
            FlutterError(
              code: NativeErrorCode.badMode, message: "Missing/invalid 'mode'", details: nil))
        }

      case "setFileNameTemplate":
        let args = call.arguments as? [String: Any]
        self.screenRecorder.setFileNameTemplate(args?["template"] as? String, result: result)

      case "getSaveFolder":
        let urlPath = self.screenRecorder.getSaveFolderPath()
        result(urlPath)

      case "chooseSaveFolder":
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = self.screenRecorder.resolveSaveFolderURL()

        panel.begin { resp in
          if resp == .OK, let url = panel.url {
            do {
              try self.screenRecorder.persistSaveFolderURL(url)
              result(url.path)
            } catch {
              result(
                FlutterError(
                  code: "SAVE_FOLDER_ERROR",
                  message: "Failed to save folder choice: \(error.localizedDescription)",
                  details: nil))
            }
          } else {
            result(nil)  // user cancelled
          }
        }

      case "resetSaveFolder":
        self.screenRecorder.resetSaveFolder()
        result(self.screenRecorder.resolveSaveFolderURL().path)

      case "openSaveFolder":
        self.screenRecorder.openSaveFolder()
        result(nil)

      case "getTodayLogFilePath":
        let logsRoot = AppPaths.logsRoot()
        let url = self.getTodayLogURL()
        if !FileManager.default.fileExists(atPath: logsRoot.path) {
          result(
            FlutterError(
              code: "LOG_FILE_UNAVAILABLE", message: "Log storage directory is unavailable",
              details: nil))
        } else if FileManager.default.fileExists(atPath: url.path) {
          result(url.path)
        } else {
          result(
            FlutterError(
              code: "LOG_FILE_NOT_FOUND", message: "Today's log file does not exist yet.",
              details: nil))
        }

      case "revealTodayLogFile":
        let logsRoot = AppPaths.logsRoot()
        let url = self.getTodayLogURL()
        if !FileManager.default.fileExists(atPath: logsRoot.path) {
          result(
            FlutterError(
              code: "LOG_FILE_UNAVAILABLE", message: "Log storage directory is unavailable",
              details: nil))
        } else if FileManager.default.fileExists(atPath: url.path) {
          NSWorkspace.shared.activateFileViewerSelecting([url])
          result(nil)
        } else {
          result(
            FlutterError(
              code: "LOG_FILE_NOT_FOUND", message: "Today's log file does not exist yet.",
              details: nil))
        }

      case "revealLogsFolder":
        let url = AppPaths.logsRoot()
        if FileManager.default.fileExists(atPath: url.path) {
          NSWorkspace.shared.open(url)
          result(nil)
        } else {
          result(
            FlutterError(
              code: "LOG_FILE_UNAVAILABLE", message: "Log storage directory is unavailable",
              details: nil))
        }

      case "revealRecordingsFolder":
        let url = AppPaths.recordingsRoot()
        if FileManager.default.fileExists(atPath: url.path) {
          NSWorkspace.shared.open(url)
          result(nil)
        } else {
          result(
            FlutterError(
              code: "RECORDINGS_FOLDER_UNAVAILABLE",
              message: "Recordings storage directory is unavailable",
              details: nil))
        }

      case "revealTempFolder":
        let url = AppPaths.tempRoot()
        if FileManager.default.fileExists(atPath: url.path) {
          NSWorkspace.shared.open(url)
          result(nil)
        } else {
          result(
            FlutterError(
              code: "TEMP_FOLDER_UNAVAILABLE",
              message: "Temporary storage directory is unavailable",
              details: nil))
        }

      case "clearCachedRecordings":
        guard self.screenRecorder.canClearCachedRecordings() else {
          result(
            FlutterError(
              code: "RECORDINGS_IN_USE",
              message: "Cached recordings cannot be cleared while recording is active.",
              details: nil))
          return
        }

        let deletedCount = self.screenRecorder.clearCachedRecordings()
        result(["deletedCount": deletedCount])

      case "revealFile":
        if let args = call.arguments as? [String: Any],
          let path = args["path"] as? String
        {
          if FileManager.default.fileExists(atPath: path) {
            self.screenRecorder.revealFile(path)
            result(nil)
          } else {
            result(
              FlutterError(
                code: NativeErrorCode.fileNotFound, message: "File not found", details: nil))
          }
        } else {
          result(FlutterError(code: NativeErrorCode.badArgs, message: "Missing path", details: nil))
        }

      case "setRecordingIndicatorPinned":
        let args = call.arguments as? [String: Any]
        let pinned = (args?["pinned"] as? Bool) ?? false
        self.screenRecorder.setRecordingIndicatorPinned(pinned, result: result)

      case "isAccessibilityTrusted":
        result(NSNumber(value: AXIsProcessTrusted()))

      case "previewOpen":
        if let args = call.arguments as? [String: Any],
          let projectPath = args["projectPath"] as? String,
          let sessionId = args["sessionId"] as? String,
          !sessionId.isEmpty
        {
          guard let mediaSources = self.screenRecorder.resolvePreviewMediaSources(
            projectPath: projectPath,
            explicitCameraPath: args["cameraPath"] as? String
          ) else {
            result(
              FlutterError(
                code: "PREVIEW_INPUT_MISSING",
                message: "Recording project not found. It may have been moved or deleted.",
                details: projectPath
              )
            )
            return
          }
          NativeLogger.i(
            "Preview", "Received previewOpen request",
            context: [
              "sessionId": sessionId,
              "projectPath": projectPath,
              "path": mediaSources.screenPath,
              "cameraPath": mediaSources.cameraPath ?? "nil",
              "hasInlinePreviewView": inlinePreviewViewInstance != nil,
            ])
          self.bringAppToFront()
          self.isInlinePreviewActive = true
          self.updatePreRecordingBarVisibility()
          beginActiveInlinePreviewSession(
            sessionId: sessionId,
            mediaSources: mediaSources
          )
          pendingPreviewOpenRequest = PendingPreviewOpenRequest(
            sessionId: sessionId,
            mediaSources: mediaSources
          )
          if let view = inlinePreviewViewInstance {
            let hadMatchingPendingScene = hasPendingPreviewSceneRequest(
              matching: sessionId
            )
            NativeLogger.i(
              "Preview", "Opening preview immediately on existing host view",
              context: [
              "sessionId": sessionId,
              "projectPath": projectPath,
              "path": mediaSources.screenPath,
              "cameraPath": mediaSources.cameraPath ?? "nil",
            ])
            view.open(mediaSources: mediaSources, sessionId: sessionId)
            let consumedPendingScene = applyPendingPreviewSceneRequestIfMatching(
              sessionId: sessionId,
              to: view
            )
            NativeLogger.d(
              "Preview", "Pending preview scene status after previewOpen",
              context: [
                "sessionId": sessionId,
                "hadMatchingPendingScene": hadMatchingPendingScene,
                "consumedPendingScene": consumedPendingScene,
              ])
            pendingPreviewOpenRequest = nil
          } else {
            NativeLogger.i(
              "Preview", "Stored pending previewOpen request until host view is created",
              context: [
              "sessionId": sessionId,
              "projectPath": projectPath,
              "path": mediaSources.screenPath,
              "cameraPath": mediaSources.cameraPath ?? "nil",
            ])
          }
          result(nil)
        } else {
          result(
            FlutterError(
              code: NativeErrorCode.badArgs,
              message: "missing projectPath/sessionId",
              details: nil
            )
          )
        }
      case "previewClose":
        if let args = call.arguments as? [String: Any],
          let sessionId = args["sessionId"] as? String,
          !sessionId.isEmpty
        {
          self.isInlinePreviewActive = false
          self.updatePreRecordingBarVisibility()
          clearAllInlinePreviewState()
          if !disposeInlinePreviewContentViewIfMatching(
            sessionId: sessionId,
            reason: "flutterRequest"
          ) {
            self.emitWorkflowEvent(
              [
                "type": "previewClosed",
                "sessionId": sessionId,
                "reason": "flutterRequest",
              ])
          }
          result(nil)
        } else {
          result(
            FlutterError(
              code: NativeErrorCode.badArgs,
              message: "missing sessionId",
              details: nil
            )
          )
        }

      case "previewPlay":
        if let args = call.arguments as? [String: Any],
          let sessionId = args["sessionId"] as? String
        {
          updateActiveInlinePreviewPlaybackSnapshot(
            sessionId: sessionId,
            isPlaying: true
          )
          if let view = inlinePreviewViewInstance, view.currentSessionId == sessionId {
            view.play()
          }
        }
        result(nil)

      case "previewPause":
        if let args = call.arguments as? [String: Any],
          let sessionId = args["sessionId"] as? String
        {
          updateActiveInlinePreviewPlaybackSnapshot(
            sessionId: sessionId,
            isPlaying: false
          )
          if let view = inlinePreviewViewInstance, view.currentSessionId == sessionId {
            view.pause()
          }
        }
        result(nil)

      case "previewSeekTo":
        if let args = call.arguments as? [String: Any],
          let sessionId = args["sessionId"] as? String
        {
          let ms = (args["ms"] as? Int) ?? 0
          updateActiveInlinePreviewPlaybackSnapshot(
            sessionId: sessionId,
            positionMs: ms
          )
          if let view = inlinePreviewViewInstance, view.currentSessionId == sessionId {
            view.seekTo(milliseconds: ms)
          }
        }
        result(nil)

      case "previewPeekTo":
        if let args = call.arguments as? [String: Any],
          let sessionId = args["sessionId"] as? String
        {
          let ms = (args["ms"] as? Int) ?? 0
          updateActiveInlinePreviewPlaybackSnapshot(
            sessionId: sessionId,
            positionMs: ms
          )
          if let view = inlinePreviewViewInstance, view.currentSessionId == sessionId {
            view.seekTo(milliseconds: ms)
          }
        }
        result(nil)

      case "playerPlay":
        updateActiveInlinePreviewPlaybackSnapshot(sessionId: nil, isPlaying: true)
        inlinePreviewViewInstance?.play()
        result(nil)
      case "playerPause":
        updateActiveInlinePreviewPlaybackSnapshot(sessionId: nil, isPlaying: false)
        inlinePreviewViewInstance?.pause()
        result(nil)
      case "playerSeekTo":
        let ms = (call.arguments as? [String: Any])?["ms"] as? Int ?? 0
        updateActiveInlinePreviewPlaybackSnapshot(sessionId: nil, positionMs: ms)
        inlinePreviewViewInstance?.seekTo(milliseconds: ms)
        result(nil)
      case "inlinePreviewStop":
        inlinePreviewViewInstance?.resetPlayback()
        result(nil)

      case "processVideo":
        if let args = call.arguments as? [String: Any],
          let projectPath = args["projectPath"] as? String
        {
          let cameraParams = self.screenRecorder.resolveCameraCompositionParams(
            projectPath: projectPath,
            args: args
          )
          let layout = (args["layoutPreset"] as? String) ?? "auto"
          let res = (args["resolutionPreset"] as? String) ?? "auto"
          let fit = (args["fitMode"] as? String) ?? "fit"
          let p = (args["padding"] as? Double) ?? 0.0
          let r = (args["cornerRadius"] as? Double) ?? 0.0
          let bgCol = args["backgroundColor"] as? Int
          let bgImg = args["backgroundImagePath"] as? String
          let cursorSize = (args["cursorSize"] as? Double) ?? 1.0
          let zoomFactor = (args["zoomFactor"] as? Double) ?? 1.5
          let showCursor = (args["showCursor"] as? Bool) ?? true
          let cameraPreviewChangeKind = CameraPreviewChangeKind(
            rawValue: (args["cameraPreviewChangeKind"] as? String) ?? CameraPreviewChangeKind.none.rawValue
          ) ?? .none

          let format = (args["format"] as? String) ?? "mov"
          let codec = (args["codec"] as? String) ?? "hevc"
          let bitrate = (args["bitrate"] as? String) ?? "auto"
          let zoomSegments = parseZoomTimelineSegments(args["zoomSegments"])

          self.screenRecorder.processVideo(
            projectPath: projectPath,
            layout: layout,
            resolution: res,
            fit: fit,
            padding: p,
            cornerRadius: r,
            backgroundColor: bgCol,
            backgroundImagePath: bgImg,
            cursorSize: cursorSize,
            zoomFactor: zoomFactor,
            showCursor: showCursor,
            format: format,
            codec: codec,
            bitrate: bitrate,
            audioGainDb: (args["audioGainDb"] as? Double) ?? 0.0,
            audioVolumePercent: (args["audioVolumePercent"] as? Double) ?? 100.0,
            zoomSegments: zoomSegments,
            cameraPreviewChangeKind: cameraPreviewChangeKind,
            sessionId: args["sessionId"] as? String,
            cameraPath: args["cameraPath"] as? String,
            cameraParams: cameraParams,
            result: result)
        } else {
          result(
            FlutterError(
              code: NativeErrorCode.badArgs, message: "Missing projectPath/width/height", details: nil))
        }

      case "previewSetCameraPlacement":
        if let args = call.arguments as? [String: Any],
          let projectPath = args["projectPath"] as? String
        {
          let cameraParams = self.screenRecorder.resolveCameraCompositionParams(
            projectPath: projectPath,
            args: args
          )
          let cameraPreviewChangeKind = CameraPreviewChangeKind(
            rawValue: (args["cameraPreviewChangeKind"] as? String) ?? CameraPreviewChangeKind.none.rawValue
          ) ?? .none
          self.screenRecorder.previewSetCameraPlacement(
            sessionId: args["sessionId"] as? String,
            cameraPreviewChangeKind: cameraPreviewChangeKind,
            cameraParams: cameraParams,
            result: result
          )
        } else {
          result(
            FlutterError(
              code: NativeErrorCode.badArgs, message: "Missing projectPath", details: nil))
        }

      case "previewSetAudioMix":
        let args = call.arguments as? [String: Any]
        let gain = (args?["audioGainDb"] as? Double) ?? 0.0
        let volume = (args?["audioVolumePercent"] as? Double) ?? 100.0
        let sessionId = args?["sessionId"] as? String
        self.screenRecorder.previewSetAudioMix(
          sessionId: sessionId,
          audioGainDb: gain,
          audioVolumePercent: volume,
          result: result
        )

      case "updateAudioPreview":
        let args = call.arguments as? [String: Any]
        let sessionId = args?["sessionId"] as? String
        let gain =
          (args?["gain"] as? Double)
          ?? (args?["audioGainDb"] as? Double)
          ?? 0.0
        let volume =
          (args?["volume"] as? Double)
          ?? (args?["audioVolumePercent"] as? Double)
          ?? 100.0
        self.screenRecorder.previewSetAudioMix(
          sessionId: sessionId,
          audioGainDb: gain,
          audioVolumePercent: volume,
          result: result
        )

      case "previewSetAudioGainDb":
        let args = call.arguments as? [String: Any]
        let value = (args?["audioGainDb"] as? Double) ?? 0.0
        self.screenRecorder.previewSetAudioGainDb(audioGainDb: value, result: result)

      case "exportVideo":
        if let args = call.arguments as? [String: Any],
          let projectPath = args["projectPath"] as? String
        {
          let cameraParams = self.screenRecorder.resolveCameraCompositionParams(
            projectPath: projectPath,
            args: args
          )
          let layout = (args["layoutPreset"] as? String) ?? "auto"
          let res = (args["resolutionPreset"] as? String) ?? "auto"
          let fit = (args["fitMode"] as? String) ?? "fit"
          let p = (args["padding"] as? Double) ?? 0.0
          let r = (args["cornerRadius"] as? Double) ?? 0.0
          let bgCol = args["backgroundColor"] as? Int
          let bgImg = args["backgroundImagePath"] as? String
          let cursorSize = (args["cursorSize"] as? Double) ?? 1.0
          let zoomFactor = (args["zoomFactor"] as? Double) ?? 1.5
          let showCursor = (args["showCursor"] as? Bool) ?? true
          let filename = args["filename"] as? String
          let directoryOverride = args["directoryOverride"] as? String
          let format = (args["format"] as? String) ?? "mov"
          let codec = (args["codec"] as? String) ?? "hevc"
          let bitrate = (args["bitrate"] as? String) ?? "auto"
          let autoNormalizeOnExport = (args["autoNormalizeOnExport"] as? Bool) ?? false
          let targetLoudnessDbfs = (args["targetLoudnessDbfs"] as? Double) ?? -16.0

          self.screenRecorder.exportVideo(
            projectPath: projectPath,
            layout: layout,
            resolution: res,
            fit: fit,
            padding: p,
            cornerRadius: r,
            backgroundColor: bgCol,
            backgroundImagePath: bgImg,
            cursorSize: cursorSize,
            zoomFactor: zoomFactor,
            showCursor: showCursor,
            filename: filename,
            directoryOverride: directoryOverride,
            format: format,
            codec: codec,
            bitrate: bitrate,
            audioGainDb: (args["audioGainDb"] as? Double) ?? 0.0,
            audioVolumePercent: (args["audioVolumePercent"] as? Double) ?? 100.0,
            autoNormalizeOnExport: autoNormalizeOnExport,
            targetLoudnessDbfs: targetLoudnessDbfs,
            cameraPath: args["cameraPath"] as? String,
            cameraParams: cameraParams,
            onProgress: { [weak self] progress in
              self?.channel?.invokeMethod("updateExportProgress", arguments: progress)
            },
            result: result)
        } else {
          result(
            FlutterError(
              code: NativeErrorCode.badArgs, message: "Missing projectPath/width/height", details: nil))
        }
      case "cancelExport":
        self.screenRecorder.cancelExport()
        result(nil)

      case "getRecordingSceneInfo":
        if let args = call.arguments as? [String: Any],
          let projectPath = args["projectPath"] as? String
        {
          self.screenRecorder.getRecordingSceneInfo(projectPath: projectPath, result: result)
        } else {
          result(
            FlutterError(
              code: NativeErrorCode.badArgs,
              message: "missing projectPath",
              details: nil
            )
          )
        }

      case "pickImage":
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["png", "jpg", "jpeg"]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
          if response == .OK, let url = panel.url {
            result(url.path)
          } else {
            result(nil)
          }
        }

      case "pickAreaRecordingRegion":
        self.isAreaSelectionInProgress = true
        self.updatePreRecordingBarVisibility()
        self.screenRecorder.pickAreaRecordingRegion(result: { [weak self] value in
          guard let self else {
            result(value)
            return
          }
          self.isAreaSelectionInProgress = false
          self.updatePreRecordingBarVisibility()
          result(value)
        })
      case "revealAreaRecordingRegion":
        self.screenRecorder.revealAreaRecordingRegion(result: result)
      case "clearAreaRecordingSelection":
        self.isAreaSelectionInProgress = false
        self.screenRecorder.clearAreaRecordingSelection(result: result)
        self.updatePreRecordingBarVisibility()

      case "setPreRecordingBarEnabled", "setPreRecordingBarVisible":
        let args = call.arguments as? [String: Any]
        let enabled = (args?["enabled"] as? Bool) ?? true
        self.setPreRecordingBarEnabled(enabled)
        result(nil)

      case "showPreRecordingBar":
        self.explicitlyShowPreRecordingBar()
        result(nil)

      case "togglePreRecordingBar":
        self.togglePreRecordingBar()
        result(nil)

      case "setPreRecordingBarState":
        if let args = call.arguments as? [String: Any] {
          self.isCountdownActive = (args["countdownActive"] as? Bool) ?? false
          if let phase = args["phase"] as? Int {
            self.setAppPhase(phase)
          }
          self.preRecordingBarController?.updateState(args)
          self.updatePreRecordingBarVisibility()
          result(nil)
        } else {
          result(FlutterError(code: NativeErrorCode.badArgs, message: "", details: nil))
        }

      case "cacheLocalizedStrings":
        if let strings = call.arguments as? [String: String] {
          NativeStringsStore.shared.updateCache(strings)
          NativeLogger.d("Localization", "Cached \(strings.count) localized strings from Flutter")
          result(nil)
        } else {
          result(FlutterError(code: NativeErrorCode.badArgs, message: "", details: nil))
        }

      case "getZoomSegments":
        if let args = call.arguments as? [String: Any],
          let path = args["projectPath"] as? String
        {
          self.screenRecorder.getZoomSegments(projectPath: path, result: result)
        } else {
          result(
            FlutterError(code: NativeErrorCode.badArgs, message: "Missing projectPath", details: nil))
        }

      case "getManualZoomSegments":
        if let args = call.arguments as? [String: Any],
          let path = args["projectPath"] as? String
        {
          result(ZoomManualStore.shared.load(projectPath: path))
        } else {
          result(
            FlutterError(code: NativeErrorCode.badArgs, message: "Missing projectPath", details: nil))
        }

      case "saveManualZoomSegments":
        if let args = call.arguments as? [String: Any],
          let path = args["projectPath"] as? String,
          let segments = args["segments"] as? [[String: Any]]
        {
          result(ZoomManualStore.shared.save(projectPath: path, segments: segments))
        } else {
          result(
            FlutterError(code: NativeErrorCode.badArgs, message: "Missing args", details: nil))
        }

      case "previewSetZoomSegments":
        if let args = call.arguments as? [String: Any],
          let sessionId = args["sessionId"] as? String,
          let segments = parseZoomTimelineSegments(args["segments"])
        {
          updateActiveInlinePreviewZoomSegments(
            sessionId: sessionId,
            segments: segments
          )
          if let previewView = inlinePreviewViewInstance,
            previewView.currentSessionId == sessionId
          {
            previewView.updateZoomSegmentsOnly(segments: segments)
          } else if pendingPreviewOpenRequest?.sessionId == sessionId {
            pendingPreviewZoomSegments = segments
          }
          result(nil)
        } else {
          result(
            FlutterError(code: NativeErrorCode.badArgs, message: "Missing segments", details: nil))
        }

      /*
        =================================================================
        ========================== PERMISSIONS ==========================
        =================================================================
      */
      case "getPermissionStatus":
        screenRecorder.getPermissionStatus(result: result)
      case "requestScreenRecordingPermission":
        screenRecorder.requestScreenRecordingPermission(result: result)
      case "requestMicrophonePermission":
        screenRecorder.requestMicrophonePermission(result: result)
      case "requestCameraPermission":
        screenRecorder.requestCameraPermission(result: result)
      case "openAccessibilitySettings":
        result(NSNumber(value: self.screenRecorder.ensureAccessibilityAllowedAndGuideUser()))
      case "openSystemSettings":
        let args = call.arguments as? [String: Any]
        let pane = (args?["pane"] as? String) ?? ""
        self.screenRecorder.openSystemSettings(pane: pane, result: result)

      case "openScreenRecordingSettings":
        screenRecorder.openScreenRecordingSettings()
        result(nil)

      case "relaunchApp":
        self.screenRecorder.relaunchApp()

      case "checkForUpdates":
        UpdaterController.shared.channel = self.channel
        UpdaterController.shared.checkForUpdates()
        result(true)

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let eventChannel = FlutterEventChannel(
      name: "com.clingfy/screen_recorder/events",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    eventChannel.setStreamHandler(eventHandler)

    // Setup Updater Event Channel
    let updaterEventChannel = FlutterEventChannel(
      name: "com.clingfy/updater/events",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    let updaterStreamHandler = UpdaterStreamHandler()
    updaterEventChannel.setStreamHandler(updaterStreamHandler)

    // Fire audio/video device changes
    screenRecorder.onDevicesChanged = { [weak self] in
      self?.eventHandler.fireAudioSourcesChanged()
    }
    screenRecorder.onVideoDevicesChanged = { [weak self] in
      self?.eventHandler.fireVideoSourcesChanged()
    }
    screenRecorder.onMicrophoneLevel = { [weak self] sample in
      self?.eventHandler.fireMicrophoneLevel(
        linear: sample.linear,
        dbfs: sample.dbfs,
        isLow: sample.isLow
      )
    }
    screenRecorder.onIndicatorPauseTapped = { [weak self] in
      self?.channel?.invokeMethod(NativeToFlutterMethod.indicatorPauseTapped, arguments: nil)
    }
    screenRecorder.onIndicatorStopTapped = { [weak self] in
      self?.channel?.invokeMethod(NativeToFlutterMethod.indicatorStopTapped, arguments: nil)
    }
    screenRecorder.onIndicatorResumeTapped = { [weak self] in
      self?.channel?.invokeMethod(NativeToFlutterMethod.indicatorResumeTapped, arguments: nil)
    }

    // --- Menu Bar Integration ---
    self.menuBarController = MenuBarController(
      recorder: screenRecorder,
      onOpenApp: { [weak self] in
        self?.bringAppToFront()
      },
      onRequestToggle: { [weak self] in
        self?.channel?.invokeMethod("menuBarToggleRequest", arguments: nil)
      }
    )

    // Wire up recording state changes to the menu bar icon
    screenRecorder.onRecordingStateChanged = { [weak self] isRecording in
      guard let self = self else { return }
      self.menuBarController?.update(isRecording: isRecording)
      // Visibility is driven by appPhaseRaw from Flutter.
      self.updateNativeUIVisibility()
    }

    // Initialize Pre-Recording Bar
    self.preRecordingBarController = PreRecordingBarController(
      recorder: screenRecorder, channel: channel)
    self.preRecordingBarController?.onAction = { [weak self] type, payload in
      guard let self else { return }

      if type == NativeBarAction.closeTapped {
        self.dismissPreRecordingBarForCurrentCycle()
        self.channel?.invokeMethod(
          NativeToFlutterMethod.preRecordingBarAction,
          arguments: ["type": type, "payload": payload as Any]
        )
        return
      }

      if type == NativeBarAction.areaTapped {
        self.isAreaSelectionInProgress = true
        self.updatePreRecordingBarVisibility()
      }

      self.channel?.invokeMethod(
        NativeToFlutterMethod.preRecordingBarAction,
        arguments: ["type": type, "payload": payload as Any]
      )
    }

    // Mirror external recording lifecycle changes back to Flutter.
    screenRecorder.onRecordingStarted = { [weak self] sessionId in
      NativeLogger.d("Recording", "Recording started callback from facade")
      self?.emitWorkflowEvent([
        "type": "recordingStarted",
        "sessionId": sessionId,
      ])
    }
    screenRecorder.onRecordingPaused = { [weak self] sessionId in
      self?.emitWorkflowEvent([
        "type": "recordingPaused",
        "sessionId": sessionId,
      ])
    }
    screenRecorder.onRecordingResumed = { [weak self] sessionId in
      self?.emitWorkflowEvent([
        "type": "recordingResumed",
        "sessionId": sessionId,
      ])
    }
    screenRecorder.onRecordingFinalized = { [weak self] sessionId, projectPath in
      NativeLogger.d("Recording", "Recording finalized callback from facade. Project: \(projectPath)")
      self?.emitWorkflowEvent([
        "type": "recordingFinalized",
        "sessionId": sessionId,
        "projectPath": projectPath,
      ])
    }
    screenRecorder.onRecordingFailed = { [weak self] payload in
      self?.emitWorkflowEvent(payload)
    }
    screenRecorder.onCameraOverlayMoved = { [weak self] payload in
      self?.channel?.invokeMethod(NativeToFlutterMethod.cameraOverlayMoved, arguments: payload)
    }
    screenRecorder.onAreaSelectionCleared = { [weak self] in
      self?.isAreaSelectionInProgress = false
      self?.updatePreRecordingBarVisibility()
      self?.channel?.invokeMethod(NativeToFlutterMethod.areaSelectionCleared, arguments: nil)
    }

    self.acceptsMouseMovedEvents = true
    super.awakeFromNib()
    configureWindowChrome()
  }

  private func configureWindowChrome() {
    titleVisibility = .hidden
    if #available(macOS 11.0, *) {
      subtitle = ""
    }
  }

  private func parseZoomTimelineSegments(_ raw: Any?) -> [ZoomTimelineSegment]? {
    guard let segmentsRaw = raw as? [[String: Any]] else { return nil }
    return segmentsRaw.compactMap { dict in
      guard let start = dict["startMs"] as? Int, let end = dict["endMs"] as? Int else {
        return nil
      }
      return ZoomTimelineSegment(startMs: start, endMs: end)
    }
  }

  private func updateNativeUIVisibility() {
    updatePreRecordingBarVisibility()
  }

  private func shouldShowPreRecordingBar() -> Bool {
    guard preRecordingBarEnabled else { return false }
    guard !preRecordingBarDismissedForCurrentCycle else { return false }
    let allowedPhases: Set<Int> = [
      NativeWorkflowPhase.idle.rawValue,
      NativeWorkflowPhase.recording.rawValue,
      NativeWorkflowPhase.pausedRecording.rawValue,
    ]
    guard allowedPhases.contains(appPhaseRaw) else { return false }
    if appPhaseRaw == NativeWorkflowPhase.idle.rawValue && isCountdownActive {
      return false
    }
    guard !isAreaSelectionInProgress else { return false }
    return true
  }

  private func updatePreRecordingBarVisibility() {
    self.preRecordingBarController?.setVisible(shouldShowPreRecordingBar())
  }

  private func setAppPhase(_ newRawPhase: Int) {
    let previousRawPhase = appPhaseRaw
    appPhaseRaw = newRawPhase

    let wasNonIdle = previousRawPhase != NativeWorkflowPhase.idle.rawValue
    let isNowIdle = newRawPhase == NativeWorkflowPhase.idle.rawValue

    if wasNonIdle && isNowIdle {
      preRecordingBarDismissedForCurrentCycle = false
    }

    updatePreRecordingBarVisibility()
  }

  private func dismissPreRecordingBarForCurrentCycle() {
    preRecordingBarDismissedForCurrentCycle = true
    updatePreRecordingBarVisibility()
  }

  private func explicitlyShowPreRecordingBar() {
    guard preRecordingBarEnabled else { return }
    preRecordingBarDismissedForCurrentCycle = false
    updatePreRecordingBarVisibility()
  }

  private func togglePreRecordingBar() {
    guard preRecordingBarEnabled else { return }

    if preRecordingBarController?.isVisible == true {
      dismissPreRecordingBarForCurrentCycle()
    } else {
      explicitlyShowPreRecordingBar()
    }
  }

  private func setPreRecordingBarEnabled(_ enabled: Bool) {
    preRecordingBarEnabled = enabled

    if enabled {
      preRecordingBarDismissedForCurrentCycle = false
    } else {
      preRecordingBarDismissedForCurrentCycle = true
    }

    updatePreRecordingBarVisibility()
  }

  private func bringAppToFront() {
    DispatchQueue.main.async {
      NSApp.activate(ignoringOtherApps: true)
      if self.isMiniaturized {
        self.deminiaturize(nil)
      }
      self.makeKeyAndOrderFront(nil)
      self.orderFrontRegardless()
    }
  }

  private func getTodayLogURL() -> URL {
    AppPaths.logFileURL()
  }

  private func emitWorkflowEvent(_ payload: [String: Any]) {
    workflowLifecycleEventSink?(payload)
  }
}

final class AudioDevicesEventHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
  func fireAudioSourcesChanged() { sink?(["type": "audioSourcesChanged"]) }
  func fireVideoSourcesChanged() { sink?(["type": "videoSourcesChanged"]) }
  func fireMicrophoneLevel(linear: Double, dbfs: Double, isLow: Bool) {
    sink?([
      "type": DeviceEventType.microphoneLevel,
      "linear": linear,
      "dbfs": dbfs,
      "isLow": isLow,
    ])
  }
}
