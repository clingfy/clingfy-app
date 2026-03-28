//
//  Permissions.swift
//  Runner
//
//  Created by Nabil Alhafez on 07/02/2026.
//

import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import FlutterMacOS
import Foundation

extension ScreenRecorderFacade {

  // MARK: - Permission Status (keep ONE shape)
  func getPermissionStatus(result: @escaping FlutterResult) {
    let screen = CGPreflightScreenCaptureAccess()
    let camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    let accessibility = AXIsProcessTrusted()

    result([
      "getPermissionStatus": "SECOND",
      "screenRecording": screen,
      "microphone": microphone,
      "camera": camera,
      "accessibility": accessibility,
    ])
  }

  // MARK: - Requests
  func requestScreenRecordingPermission(result: @escaping FlutterResult) {
    result(CGRequestScreenCaptureAccess())
  }

  func requestMicrophonePermission(result: @escaping FlutterResult) {
    requestAVPermission(mediaType: .audio, result: result)
  }

  func requestCameraPermission(result: @escaping FlutterResult) {
    requestAVPermission(mediaType: .video, result: result)
  }

  func requestAccessibilityPermission(result: @escaping FlutterResult) {
    if AXIsProcessTrusted() {
      result(true)
      return
    }
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let opts: CFDictionary = [key: true] as CFDictionary
    result(AXIsProcessTrustedWithOptions(opts))
  }

  // MARK: - Open Settings
  func openAccessibilitySettings() {
    openSystemSettings(pane: "accessibility", result: { _ in })
  }

  func openScreenRecordingSettings() {
    openSystemSettings(pane: "screen", result: { _ in })
  }

  func openSystemSettings(pane: String, result: @escaping FlutterResult) {
    let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

    let baseOld = "x-apple.systempreferences:com.apple.preference.security?Privacy_"
    let baseNew = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_"
    let prefix = (major >= 13) ? baseNew : baseOld

    let urlString: String = {
      switch pane {
      case "screen": return prefix + "ScreenCapture"
      case "camera": return prefix + "Camera"
      case "microphone": return prefix + "Microphone"
      case "accessibility": return prefix + "Accessibility"
      case "storage":
        return (major >= 13)
          ? "x-apple.systempreferences:com.apple.systempreferences.GeneralSettings?com.apple.settings.Storage"
          : "x-apple.systempreferences:com.apple.preference.general?Storage"
      default:
        return (major >= 13)
          ? "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
          : "x-apple.systempreferences:com.apple.preference.security"
      }
    }()

    if let url = URL(string: urlString) {
      NSWorkspace.shared.open(url)
    }
    result(nil)
  }

  // MARK: - Helpers used by recording logic (must NOT be private if used elsewhere)
  func ensureCameraPermission(
    allowed: @escaping () -> Void,
    denied: @escaping (FlutterError) -> Void
  ) {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      allowed()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { ok in
        DispatchQueue.main.async {
          ok ? allowed() : denied(flutterError(NativeErrorCode.cameraPermissionDenied, ""))
        }
      }
    default:
      denied(flutterError(NativeErrorCode.cameraPermissionDenied, ""))
    }
  }

  // Tracks whether the accessibility prompt has already been shown.
  private var kAXPrompted: String { "axPromptedOnce" }

  @discardableResult
  func ensureAccessibilityAllowedAndGuideUser() -> Bool {
    if AXIsProcessTrusted() { return true }

    let prompted = UserDefaults.standard.bool(forKey: kAXPrompted)
    if !prompted {
      let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(opts)
      UserDefaults.standard.set(true, forKey: kAXPrompted)
    }

    openAccessibilitySettings()
    return false
  }

  private func requestAVPermission(mediaType: AVMediaType, result: @escaping FlutterResult) {
    let status = AVCaptureDevice.authorizationStatus(for: mediaType)
    if status == .authorized {
      result(true)
      return
    }
    if status != .notDetermined {
      result(false)
      return
    }

    AVCaptureDevice.requestAccess(for: mediaType) { ok in
      DispatchQueue.main.async { result(ok) }
    }
  }
}
