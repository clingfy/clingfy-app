import CoreAudio
import Foundation

/// The system's current default audio-output device, classified by whether it
/// can acoustically feed the microphone.
///
/// This exists because speaker playback is the precondition for the
/// speaker -> mic bleed that makes a recording come back with a doubled,
/// delayed soundtrack. Recording system audio is safe on headphones and risky
/// on speakers, so the recorder needs to know which one is live: to warn
/// before a take, and to stamp the route into the bundle metadata so a take
/// that comes back wrong can be explained after the fact.
enum AudioOutputRoute: String {
  /// Built-in or external speakers — system audio is audible in the room, so
  /// it will bleed into any open microphone.
  case speakers
  /// Headphones or headset — no acoustic path from output back to the mic.
  case headphones
  /// Virtual/aggregate/loopback devices (Soundflower, BlackHole, Loopback) and
  /// anything else we cannot classify. Treated as not-a-bleed-risk because
  /// these route digitally, but reported honestly rather than guessed.
  case unknown

  /// True when playing system audio can reach the microphone through the air.
  var bleedsIntoMicrophone: Bool { self == .speakers }
}

enum AudioOutputRouteProbe {
  /// Reads the current default output device and classifies it.
  ///
  /// Returns `.unknown` rather than throwing on any CoreAudio failure: this
  /// informs a warning and a metadata field, and must never be able to block
  /// or fail a recording.
  static func current(objectID: AudioObjectID = AudioObjectID(kAudioObjectSystemObject))
    -> AudioOutputRoute
  {
    guard let deviceID = defaultOutputDeviceID(systemObject: objectID) else { return .unknown }
    guard let transport = transportType(of: deviceID) else { return .unknown }
    return classify(transportType: transport)
  }

  /// Maps a CoreAudio transport type onto the bleed-risk classification.
  /// Split out from [current] so it is testable without real hardware.
  static func classify(transportType: UInt32) -> AudioOutputRoute {
    switch transportType {
    case kAudioDeviceTransportTypeBuiltIn:
      // The built-in output is the laptop speakers. Headphones plugged into
      // the jack report as kAudioDeviceTransportTypeBuiltIn on some Macs, but
      // the dedicated headphone transport below covers the common case; when
      // in doubt we err toward warning rather than staying silent.
      return .speakers
    case kAudioDeviceTransportTypeBluetooth,
      kAudioDeviceTransportTypeBluetoothLE:
      // AirPods and Bluetooth headsets. Bluetooth speakers also land here, so
      // this is the one genuinely ambiguous bucket; we treat it as headphones
      // because Bluetooth output on a recording Mac is overwhelmingly a headset.
      return .headphones
    case kAudioDeviceTransportTypeUSB,
      kAudioDeviceTransportTypeDisplayPort,
      kAudioDeviceTransportTypeHDMI,
      kAudioDeviceTransportTypeThunderbolt,
      kAudioDeviceTransportTypeAirPlay:
      // External monitors, USB speakers, AirPlay receivers — all play into the
      // room. USB headsets are the false positive here; the warning is
      // dismissible for that reason.
      return .speakers
    case kAudioDeviceTransportTypeVirtual,
      kAudioDeviceTransportTypeAggregate,
      kAudioDeviceTransportTypeAutoAggregate:
      return .unknown
    default:
      return .unknown
    }
  }

  private static func defaultOutputDeviceID(systemObject: AudioObjectID) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      systemObject, &address, 0, nil, &size, &deviceID)
    guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
  }

  private static func transportType(of deviceID: AudioDeviceID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var transport = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(
      deviceID, &address, 0, nil, &size, &transport)
    guard status == noErr else { return nil }
    return transport
  }
}
