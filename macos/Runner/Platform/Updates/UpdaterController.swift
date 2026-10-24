//
//  UpdaterController.swift
//  Runner
//
//  Created by Nabil Alhafez on 08/02/2026.
//

import FlutterMacOS
import Foundation
import Sparkle

final class UpdaterController: NSObject, SPUUpdaterDelegate {
  static let shared = UpdaterController()

  // Lazily initialized so we can pass `self` as updaterDelegate after NSObject.init()
  private(set) lazy var updaterController: SPUStandardUpdaterController = {
    #if DEBUG
      let shouldStart = false
    #else
      let shouldStart = true
    #endif
    // let shouldStart = true

    return SPUStandardUpdaterController(
      startingUpdater: shouldStart,
      updaterDelegate: self,
      userDriverDelegate: nil
    )
  }()

  /// Weak reference to the Flutter method channel for sending update events.
  weak var channel: FlutterMethodChannel?

  /// Event sink for streaming updates to Flutter
  var eventSink: FlutterEventSink?

  private override init() {
    super.init()
    // Force the lazy var to initialize immediately
    _ = updaterController
  }

  func checkForUpdates() {
    updaterController.checkForUpdates(nil)
  }

  // MARK: - SPUUpdaterDelegate

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    let version = item.displayVersionString
    let build = item.versionString
    NativeLogger.i(
      "Sparkle", "Update available",
      context: [
        "version": version,
        "build": build,
      ])

    // Notify Flutter through both update channels for compatibility.
    DispatchQueue.main.async { [weak self] in
      // 1. Send via MethodChannel (if anyone is listening to an invocation callback, typically they aren't for events, but we keep it for backward compatibility)
      self?.channel?.invokeMethod(
        "updateAvailable",
        arguments: [
          "version": version,
          "build": build,
        ])

      // 2. Send via EventChannel sink
      self?.eventSink?([
        "type": "updateAvailable",
        "version": version,
        "build": build,
      ])
    }
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
    NativeLogger.d("Sparkle", "No update available")
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    NativeLogger.e(
      "Sparkle", "Update check aborted",
      context: [
        "error": error.localizedDescription
      ])
  }

  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    let version = item.displayVersionString
    NativeLogger.i(
      "Sparkle", "Installing update",
      context: [
        "version": version
      ])
  }
}

class UpdaterStreamHandler: NSObject, FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    UpdaterController.shared.eventSink = FlutterMainThread.eventSink(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    UpdaterController.shared.eventSink = nil
    return nil
  }
}
