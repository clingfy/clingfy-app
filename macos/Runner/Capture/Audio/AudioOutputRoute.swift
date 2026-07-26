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
    return classify(transportType: transport, dataSource: outputDataSource(of: deviceID))
  }

  /// Maps a CoreAudio transport type, plus the built-in device's data source,
  /// onto the bleed-risk classification.
  ///
  /// The transport type alone is NOT enough for the built-in device: the laptop
  /// speakers and the headphone jack are the SAME device with the same
  /// `kAudioDeviceTransportTypeBuiltIn` transport, distinguished only by the
  /// output data source. Classifying built-in as speakers therefore warned
  /// every wired-headphone user — the exact false alarm this warning must not
  /// produce, since a false alarm teaches people to ignore the real one.
  ///
  /// [dataSource] is the output-scope `kAudioDevicePropertyDataSource` value,
  /// or nil when it could not be read.
  static func classify(transportType: UInt32, dataSource: UInt32? = nil) -> AudioOutputRoute {
    switch transportType {
    case kAudioDeviceTransportTypeBuiltIn:
      // 'hdpn' is the headphone jack; 'ispk' the internal speakers. Anything
      // else on the built-in device (or an unreadable source) is treated as
      // speakers, because on a laptop that is the overwhelmingly likely case
      // and a missed warning is the more expensive mistake here.
      switch dataSource {
      case headphoneDataSource:
        return .headphones
      default:
        return .speakers
      }
    case kAudioDeviceTransportTypeBluetooth,
      kAudioDeviceTransportTypeBluetoothLE:
      // AirPods and Bluetooth headsets. Bluetooth SPEAKERS also land here and
      // will not be warned about — see the TODOS entry; the transport genuinely
      // does not carry enough information to tell them apart.
      return .headphones
    case kAudioDeviceTransportTypeDisplayPort,
      kAudioDeviceTransportTypeHDMI,
      kAudioDeviceTransportTypeAirPlay:
      // Monitors and AirPlay receivers play into the room.
      return .speakers
    case kAudioDeviceTransportTypeUSB,
      kAudioDeviceTransportTypeThunderbolt:
      // USB is genuinely ambiguous — headsets and desk speakers share the
      // transport. Reported as unknown rather than guessed, so neither a false
      // alarm nor a confident-but-wrong silence is produced.
      return .unknown
    case kAudioDeviceTransportTypeVirtual,
      kAudioDeviceTransportTypeAggregate,
      kAudioDeviceTransportTypeAutoAggregate:
      return .unknown
    default:
      return .unknown
    }
  }

  /// `'hdpn'` — the built-in headphone jack data source.
  static let headphoneDataSource: UInt32 = 0x6864_706E

  /// `'ispk'` — the built-in internal speakers data source.
  static let internalSpeakerDataSource: UInt32 = 0x6973_706B

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

  /// Reads the OUTPUT-scope data source, which is what separates the built-in
  /// speakers from the built-in headphone jack. Many devices do not implement
  /// it; nil simply means "no extra information".
  private static func outputDataSource(of deviceID: AudioDeviceID) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDataSource,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return nil }
    var source = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &source)
    guard status == noErr else { return nil }
    return source
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
