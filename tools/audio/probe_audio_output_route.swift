// Dumps every CoreAudio signal Clingfy could use to decide whether the current
// audio OUTPUT route can acoustically feed the microphone — which is what
// decides whether the pre-recording speaker-bleed warning should fire.
//
// Why this exists: transportType alone cannot tell a Bluetooth/USB HEADSET from
// a Bluetooth/USB SPEAKER, and guessing wrong either cries wolf (training the
// user to ignore a real warning) or stays silent and ruins an unrepeatable take.
//
// Run it, then run it again with each device connected:
//   swiftc -O tools/audio/probe_audio_output_route.swift -o /tmp/probe && /tmp/probe
//
// Measured so far (MacBook Pro, 2026-07-26):
//   MacBook Pro Speakers  -> transport 'bltn', dataSource 'ispk',
//                            terminalType 0x301,  0 input streams  => speakers
//   JBL WAVE100TWS earbud -> transport 'blue', dataSource n/a,
//                            terminalType 'hdph', 0 input streams  => headphones
//
// STILL UNMEASURED, and the only case that matters now: a Bluetooth SPEAKER.
// If it reports 'spkr' or a USB-AC speaker code it is already handled; if it
// reports 'hdph' or 0 it will be missed. Also unmeasured: USB headsets and USB
// desk speakers.
//
// NOTE on terminalType: BOTH encodings occur in the wild. The built-in device
// reports 0x301 (the USB Audio Class numeric code for Speaker) while a Bluetooth
// earbud reports 'hdph' (the CoreAudio constant). AudioOutputRoute therefore
// accepts both families. Add a row above for every device you connect.

import CoreAudio
import Foundation

func fourCC(_ v: UInt32) -> String {
  if v == 0 { return "0 (unknown)" }
  let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
  let s = String(bytes: b, encoding: .ascii) ?? "?"
  return "'\(s)' (0x\(String(v, radix: 16)))"
}

func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32? {
  var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  guard AudioObjectHasProperty(obj, &a) else { return nil }
  var v = UInt32(0); var sz = UInt32(MemoryLayout<UInt32>.size)
  guard AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v) == noErr else { return nil }
  return v
}

var addr = AudioObjectPropertyAddress(
  mSelector: kAudioHardwarePropertyDefaultOutputDevice,
  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var dev = AudioDeviceID(0); var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev) == noErr else {
  print("could not read default output device"); exit(1)
}

var nameAddr = AudioObjectPropertyAddress(
  mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
  mElement: kAudioObjectPropertyElementMain)
var nameRef: Unmanaged<CFString>? = nil
var nsz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nsz, &nameRef)
let deviceName = nameRef?.takeRetainedValue() as String? ?? "?" 

print("device id      : \(dev)")
print("name           : \(deviceName)")
print("transportType  : \(u32(dev, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal).map(fourCC) ?? "n/a")")
print("dataSource(out): \(u32(dev, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput).map(fourCC) ?? "n/a")")

// output streams and their terminal types
var sAddr = AudioObjectPropertyAddress(
  mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
  mElement: kAudioObjectPropertyElementMain)
var ssz = UInt32(0)
if AudioObjectGetPropertyDataSize(dev, &sAddr, 0, nil, &ssz) == noErr, ssz > 0 {
  let n = Int(ssz) / MemoryLayout<AudioStreamID>.size
  var streams = [AudioStreamID](repeating: 0, count: n)
  if AudioObjectGetPropertyData(dev, &sAddr, 0, nil, &ssz, &streams) == noErr {
    print("output streams : \(n)")
    for (i, st) in streams.enumerated() {
      let t = u32(st, kAudioStreamPropertyTerminalType, kAudioObjectPropertyScopeGlobal)
      print("  stream[\(i)] terminalType = \(t.map(fourCC) ?? "n/a")")
    }
  }
} else { print("output streams : none/err") }

// does the device also expose INPUT streams? (headset heuristic)
var iAddr = AudioObjectPropertyAddress(
  mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
  mElement: kAudioObjectPropertyElementMain)
var isz = UInt32(0)
AudioObjectGetPropertyDataSize(dev, &iAddr, 0, nil, &isz)
print("input streams  : \(Int(isz) / max(1, MemoryLayout<AudioStreamID>.size))")
