import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum CursorKind: String, Codable {
  case arrow
  case iBeam
  case pointingHand
  case crosshair
  case resize
  case other
}

struct CursorSprite: Codable {
  let id: Int
  let width: Int
  let height: Int
  let hotspotX: Double
  let hotspotY: Double
  let pixels: Data  // raw RGBA bytes
}

struct CursorFrame: Codable {
  let t: TimeInterval  // seconds since recording start
  let x: Double  // normalized 0..1
  let y: Double
  let spriteID: Int  // index into sprites[]
}

struct CursorRecording: Codable {
  let sprites: [CursorSprite]
  let frames: [CursorFrame]
}

private struct SpriteKey: Hashable {
  let width: Int
  let height: Int
  let hash: Int
}

final class CursorRecorder {
  private var timer: DispatchSourceTimer?
  private var frames: [CursorFrame] = []
  private var sprites: [CursorSprite] = []
  private var spriteIndexByKey: [SpriteKey: Int] = [:]
  private var isActive = false

  private var startTime: TimeInterval = 0
  private let queue = DispatchQueue(label: "com.clingfy.cursor", qos: .userInteractive)
  private var displayID: CGDirectDisplayID = CGMainDisplayID()
  private var baseRect: CGRect = .zero
  private var cursorRasterScale: Double = 1.0
  private var didLogRasterShape = false
  private let lock = NSLock()
  private var activity: NSObjectProtocol?

  func start(displayID: CGDirectDisplayID, captureRect: CGRect?) {
    start(displayID: displayID, captureRect: captureRect, cursorRasterScale: 1.0)
  }

  func start(displayID: CGDirectDisplayID, captureRect: CGRect?, cursorRasterScale: Double) {
    self.displayID = displayID
    if let rect = captureRect {
      self.baseRect = rect
    } else {
      self.baseRect = CGDisplayBounds(displayID)
    }
    self.cursorRasterScale = min(max(cursorRasterScale, 0.1), 8.0)
    self.didLogRasterShape = false

    NativeLogger.d(
      "CursorRecorder",
      "Started",
      context: [
        "displayID": Int(displayID),
        "baseRect": "\(baseRect)",
        "cursorRasterScale": self.cursorRasterScale,
      ]
    )

    // Prompt for Accessibility permission
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options: CFDictionary = [promptKey: true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(options)

    NativeLogger.d("CursorRecorder", "AXIsProcessTrusted check", context: ["trusted": trusted])

    self.activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiated,
      reason: "Cursor Recording"
    )

    lock.lock()
    self.frames = []
    self.sprites = []
    self.spriteIndexByKey = [:]
    lock.unlock()

    self.startTime = ProcessInfo.processInfo.systemUptime

    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now(), repeating: 1.0 / 60.0)
    t.setEventHandler { [weak self] in
      self?.captureFrame()
    }
    t.resume()
    self.timer = t
    self.isActive = true
  }

  func stop(outputURL: URL, completion: @escaping () -> Void) {
    let wasActive = isActive
    isActive = false

    guard wasActive else {
      NativeLogger.d(
        "CursorRecorder",
        "Stop skipped because cursor capture was not active",
        context: ["path": outputURL.path]
      )
      DispatchQueue.main.async {
        completion()
      }
      return
    }

    timer?.cancel()
    timer = nil

    if let act = activity {
      ProcessInfo.processInfo.endActivity(act)
      activity = nil
    }

    let localFrames: [CursorFrame]
    let localSprites: [CursorSprite]
    lock.lock()
    localFrames = frames
    localSprites = sprites
    lock.unlock()

    NativeLogger.d(
      "CursorRecorder",
      "Stopping",
      context: [
        "frames": localFrames.count,
        "sprites": localSprites.count,
      ]
    )

    let recording = CursorRecording(sprites: localSprites, frames: localFrames)

    queue.async {
      do {
        let data = try JSONEncoder().encode(recording)
        try data.write(to: outputURL)

        NativeLogger.i(
          "CursorRecorder",
          "Saved cursor recording",
          context: ["path": outputURL.path]
        )
      } catch {
        NativeLogger.e(
          "CursorRecorder",
          "Failed to save cursor recording",
          context: ["error": error.localizedDescription]
        )
      }
      DispatchQueue.main.async {
        completion()
      }
    }
  }

  func cancel() {
    isActive = false
    timer?.cancel()
    timer = nil

    if let act = activity {
      ProcessInfo.processInfo.endActivity(act)
      activity = nil
    }

    lock.lock()
    frames = []
    sprites = []
    spriteIndexByKey = [:]
    lock.unlock()

    startTime = 0
    didLogRasterShape = false

    NativeLogger.d("CursorRecorder", "Cancelled")
  }

  private func captureFrame() {
    let now = ProcessInfo.processInfo.systemUptime
    let t = now - startTime

    guard let event = CGEvent(source: nil) else { return }
    let loc = event.location

    let relX = loc.x - baseRect.origin.x
    let relY = loc.y - baseRect.origin.y

    let nx = relX / max(baseRect.width, 1)
    let ny = relY / max(baseRect.height, 1)

    // Moved Logger here so variables nx, ny, etc are defined before use
    if frames.count % 60 == 0 {
      NativeLogger.d(
        "CursorRecorder",
        "Frame Stats",
        context: [
          "loc": "\(loc.x), \(loc.y)",
          "rel": "\(relX), \(relY)",
          "n": "\(String(format: "%.2f", nx)), \(String(format: "%.2f", ny))",
          "frameCount": frames.count,
        ]
      )
    }

    let isInside = (0.0...1.0).contains(nx) && (0.0...1.0).contains(ny)

    // ✅ If outside: record position, but no sprite / no cursor
    if !isInside {
      let frame = CursorFrame(t: t, x: nx, y: ny, spriteID: -1)
      lock.lock()
      frames.append(frame)
      lock.unlock()
      return
    }

    // Get current cursor
    let cursor: NSCursor
    if #available(macOS 13.0, *) {
      cursor = NSCursor.currentSystem ?? NSCursor.current
    } else {
      cursor = NSCursor.current
    }

    // 1. Get Logical Size (Points)
    let logicalSize = cursor.image.size

    // 2. Get cursor image representation and rasterize to deterministic pixel size.
    guard let cgCursor = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return
    }

    let width = max(1, Int((Double(logicalSize.width) * cursorRasterScale).rounded()))
    let height = max(1, Int((Double(logicalSize.height) * cursorRasterScale).rounded()))

    // 3. Convert hotspot to pixels with the same deterministic scale
    let hotXPixels = Double(cursor.hotSpot.x) * cursorRasterScale
    let hotYPixels = Double(cursor.hotSpot.y) * cursorRasterScale

    if !didLogRasterShape {
      didLogRasterShape = true
      NativeLogger.d(
        "CursorRecorder",
        "Cursor rasterized",
        context: [
          "logical_w": logicalSize.width,
          "logical_h": logicalSize.height,
          "rasterScale": cursorRasterScale,
          "target_w": width,
          "target_h": height,
          "hotspotX": hotXPixels,
          "hotspotY": hotYPixels,
        ]
      )
    }

    // Dedup Logic
    let spriteHash = width ^ height ^ Int(hotXPixels) ^ Int(hotYPixels)
    let key = SpriteKey(width: width, height: height, hash: spriteHash)

    let spriteIndex: Int
    if let existing = spriteIndexByKey[key] {
      spriteIndex = existing
    } else {
      // 5. Sanitize Pixels
      let colorSpace = CGColorSpaceCreateDeviceRGB()
      let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
      var rawData = Data(count: width * height * 4)

      rawData.withUnsafeMutableBytes { ptr in
        guard
          let ctx = CGContext(
            data: ptr.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
          )
        else { return }

        ctx.interpolationQuality = .high
        ctx.draw(cgCursor, in: CGRect(x: 0, y: 0, width: width, height: height))
      }

      let sprite = CursorSprite(
        id: sprites.count,
        width: width,
        height: height,
        hotspotX: hotXPixels,
        hotspotY: hotYPixels,
        pixels: rawData
      )
      spriteIndex = sprites.count
      sprites.append(sprite)
      spriteIndexByKey[key] = spriteIndex
    }

    let frame = CursorFrame(t: t, x: nx, y: ny, spriteID: spriteIndex)

    lock.lock()
    frames.append(frame)
    lock.unlock()
  }
}
