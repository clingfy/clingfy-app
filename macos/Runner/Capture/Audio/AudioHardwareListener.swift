import CoreAudio
import Foundation

/// Push notifications from the CoreAudio HAL.
///
/// Two gaps closed by one registry, because they are the same mechanism:
///
/// 1. **Device list.** `AVCaptureDevice.was{Connected,Disconnected}` already
///    drives the microphone and camera pickers, but it only reports devices
///    AVFoundation models. It misses a device being *renamed*, aggregate and
///    virtual devices created in Audio MIDI Setup, and a Bluetooth headset
///    flipping between A2DP and HFP — which changes the sample rate the mic
///    delivers without any connect or disconnect.
///
/// 2. **Default output route.** The speaker-bleed warning is computed from
///    the current output device. It used to be probed at exactly two moments —
///    app start, and toggling system audio — so plugging in headphones
///    mid-session left a stale warning on screen, and unplugging them showed
///    no warning at all. A stale warning erodes trust in the real one.
///
/// Callbacks arrive on an arbitrary HAL thread and are coalesced before being
/// forwarded: a single dock connect can fire several of these.
final class AudioHardwareListener {

  /// Long enough to swallow the burst one connect produces, short enough that
  /// the warning updates while the user is still looking at the sidebar.
  static let coalesceInterval: TimeInterval = 0.25

  /// The device list changed — added, removed, renamed, or reconfigured.
  var onDeviceListChanged: (() -> Void)?

  /// The default output device changed, so the bleed risk may have inverted.
  var onDefaultOutputChanged: (() -> Void)?

  /// The default input device changed.
  var onDefaultInputChanged: (() -> Void)?

  private let systemObject = AudioObjectID(kAudioObjectSystemObject)
  private let queue = DispatchQueue(label: "com.clingfy.audio-hardware-listener")

  private let deviceListDebouncer = TrailingDebouncer(delay: coalesceInterval)
  private let outputDebouncer = TrailingDebouncer(delay: coalesceInterval)
  private let inputDebouncer = TrailingDebouncer(delay: coalesceInterval)

  private var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
  private var isListening = false

  deinit {
    stop()
  }

  static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  func start() {
    guard !isListening else { return }
    isListening = true

    register(kAudioHardwarePropertyDevices) { [weak self] in
      guard let self else { return }
      self.deviceListDebouncer.schedule { self.onDeviceListChanged?() }
    }
    register(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
      guard let self else { return }
      self.outputDebouncer.schedule { self.onDefaultOutputChanged?() }
    }
    register(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
      guard let self else { return }
      self.inputDebouncer.schedule { self.onDefaultInputChanged?() }
    }
  }

  func stop() {
    guard isListening else { return }
    isListening = false

    for (address, block) in registrations {
      var mutableAddress = address
      AudioObjectRemovePropertyListenerBlock(systemObject, &mutableAddress, queue, block)
    }
    registrations = []

    deviceListDebouncer.cancel()
    outputDebouncer.cancel()
    inputDebouncer.cancel()
  }

  private func register(
    _ selector: AudioObjectPropertySelector,
    handler: @escaping () -> Void
  ) {
    var propertyAddress = Self.address(selector)
    let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }

    let status = AudioObjectAddPropertyListenerBlock(
      systemObject, &propertyAddress, queue, block)

    guard status == noErr else {
      // A failed registration is not fatal: every list it feeds still has a
      // manual refresh, and the AVCaptureDevice path still covers plain
      // connect/disconnect. Losing it silently is what would be wrong.
      NativeLogger.w(
        "AudioHardware", "Failed to register CoreAudio property listener",
        context: ["selector": selector, "status": status])
      return
    }

    registrations.append((propertyAddress, block))
  }
}
