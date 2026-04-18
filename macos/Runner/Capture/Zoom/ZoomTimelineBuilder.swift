import Foundation

struct ZoomSegment: Codable {
  let startMs: Int
  let endMs: Int
}

final class ZoomTimelineBuilder {
  static func buildSegments(
    cursorRecording: CursorRecording,
    durationSeconds: Double,
    fps: Double = 60.0
  ) -> [ZoomSegment] {
    guard !cursorRecording.frames.isEmpty else { return [] }

    func isInBounds(_ frame: CursorFrame) -> Bool {
      return (0.0...1.0).contains(frame.x) && (0.0...1.0).contains(frame.y)
        && frame.spriteID >= 0
    }

    // 1. Determine defaultSpriteID to match InlinePreviewView:
    // First in-bounds frame where spriteID >= 0
    let defaultSpriteID =
      cursorRecording.frames.first(where: { isInBounds($0) })?.spriteID
      ?? cursorRecording.frames.first?.spriteID ?? 0

    NativeLogger.d(
      "ZoomTimelineBuilder", "Default sprite ID chosen",
      context: [
        "defaultSpriteID": defaultSpriteID
      ])

    // 2. Simulate over time at fps steps based on hysteresis output only:
    let zoomHysteresis = ZoomHysteresis()
    var segments: [ZoomSegment] = []
    var currentSegmentStart: Double? = nil
    var lastStable = false
    var lastRaw = false
    var rawChangedAt = 0.0

    let totalSteps = Int(durationSeconds * fps)
    var frameIndex = 0
    let frames = cursorRecording.frames

    for i in 0...totalSteps {
      let time = Double(i) / fps

      // Get the most recent cursor frame at or before 'time' (efficient scan using frameIndex pointer)
      while frameIndex < frames.count - 1 && frames[frameIndex + 1].t <= time {
        frameIndex += 1
      }
      let frame = frames[frameIndex]

      if !isInBounds(frame) {
        if lastStable, let start = currentSegmentStart {
          segments.append(
            ZoomSegment(
              startMs: Int((start * 1000).rounded()),
              endMs: Int((time * 1000).rounded())
            ))
        }
        zoomHysteresis.reset()
        currentSegmentStart = nil
        lastStable = false
        continue
      }

      let rawZoomWanted = (frame.spriteID != defaultSpriteID)
      if rawZoomWanted != lastRaw {
        rawChangedAt = time
        lastRaw = rawZoomWanted
      }
      let stableZoomActive = zoomHysteresis.update(time: time, rawZoomWanted: rawZoomWanted)

      if stableZoomActive && !lastStable {
        currentSegmentStart = rawChangedAt
      } else if !stableZoomActive && lastStable, let start = currentSegmentStart {
        segments.append(
          ZoomSegment(
            startMs: Int((start * 1000).rounded()),
            endMs: Int((rawChangedAt * 1000).rounded())
          ))
        currentSegmentStart = nil
      }
      lastStable = stableZoomActive
    }

    // If segment is open at end => close at durationSeconds
    if let start = currentSegmentStart, lastStable {
      segments.append(
        ZoomSegment(
          startMs: Int((start * 1000).rounded()),
          endMs: Int((durationSeconds * 1000).rounded())
        ))
    }

    // Merge segments with tiny gaps (optional but recommended):
    // If gap < 120ms, merge into one segment
    var merged: [ZoomSegment] = []
    for seg in segments {
      if let last = merged.last, (seg.startMs - last.endMs) < 120 {
        merged[merged.count - 1] = ZoomSegment(startMs: last.startMs, endMs: seg.endMs)
      } else {
        merged.append(seg)
      }
    }

    // Clamp: startMs >= 0, endMs <= durationMs, endMs > startMs
    let durationMs = Int((durationSeconds * 1000).rounded())
    let minDurationMs = Int(((1000.0 / fps) * 2).rounded())
    let finalSegments = merged
      .map {
        ZoomSegment(
          startMs: max(0, $0.startMs),
          endMs: min(durationMs, $0.endMs)
        )
      }
      .filter { $0.endMs - $0.startMs >= minDurationMs }

    NativeLogger.d(
      "ZoomTimelineBuilder", "Built segments",
      context: [
        "count": finalSegments.count,
        "segments": "\(finalSegments.prefix(5))",
      ])

    return finalSegments
  }
}
