import AVFoundation
import AudioToolbox

/// Pure DSP: peak/dBFS estimation from a CMSampleBuffer.
/// Engine-domain (input is the cross-platform CoreMedia value type; on Windows the
/// equivalent reads a WASAPI buffer — see windows-port-inventory §7).
enum AudioLevelEstimator {
  static func dbfs(for linear: Double) -> Double {
    let clamped = max(linear, 0.000000001)
    return 20.0 * log10(clamped)
  }

  static func estimatePeak(sampleBuffer: CMSampleBuffer) -> (linear: Double, dbfs: Double)? {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
      let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(format)
    else { return nil }

    let asbd = asbdPtr.pointee
    let channelCount = max(1, Int(asbd.mChannelsPerFrame))
    let bufferListSize =
      MemoryLayout<AudioBufferList>.size + (channelCount - 1) * MemoryLayout<AudioBuffer>.size
    let rawPointer = UnsafeMutableRawPointer.allocate(
      byteCount: bufferListSize,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawPointer.deallocate() }
    let audioBufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)

    var blockBuffer: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: audioBufferListPointer,
      bufferListSize: bufferListSize,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: &blockBuffer
    )
    guard status == noErr else { return nil }
    let audioBufferList = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)

    let flags = asbd.mFormatFlags
    let bitsPerChannel = asbd.mBitsPerChannel
    let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
    let isSignedInt = (flags & kAudioFormatFlagIsSignedInteger) != 0
    var peak = 0.0

    if isFloat && bitsPerChannel == 32 {
      for audioBuffer in audioBufferList {
        guard let data = audioBuffer.mData else { continue }
        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.assumingMemoryBound(to: Float.self)
        for i in 0..<sampleCount {
          let value = Double(abs(samples[i]))
          if value > peak { peak = value }
        }
      }
    } else if isFloat && bitsPerChannel == 64 {
      for audioBuffer in audioBufferList {
        guard let data = audioBuffer.mData else { continue }
        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
        let samples = data.assumingMemoryBound(to: Double.self)
        for i in 0..<sampleCount {
          let value = abs(samples[i])
          if value > peak { peak = value }
        }
      }
    } else if isSignedInt && bitsPerChannel == 16 {
      let denom = Double(Int16.max)
      for audioBuffer in audioBufferList {
        guard let data = audioBuffer.mData else { continue }
        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
        let samples = data.assumingMemoryBound(to: Int16.self)
        for i in 0..<sampleCount {
          let sample = samples[i]
          let value =
            sample == Int16.min ? 1.0 : (Double(abs(Int(sample))) / denom)
          if value > peak { peak = value }
        }
      }
    } else if isSignedInt && bitsPerChannel == 32 {
      let denom = Double(Int32.max)
      for audioBuffer in audioBufferList {
        guard let data = audioBuffer.mData else { continue }
        let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
        let samples = data.assumingMemoryBound(to: Int32.self)
        for i in 0..<sampleCount {
          let sample = samples[i]
          let value =
            sample == Int32.min ? 1.0 : (Double(abs(Int64(sample))) / denom)
          if value > peak { peak = value }
        }
      }
    } else {
      return nil
    }

    let clampedPeak = max(0.0, min(1.0, peak))
    return (linear: clampedPeak, dbfs: dbfs(for: clampedPeak))
  }
}
