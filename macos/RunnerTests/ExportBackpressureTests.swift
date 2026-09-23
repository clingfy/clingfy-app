import AVFoundation
import XCTest

@testable import Clingfy

/// What a render does when the pixel-buffer pool has nothing to give.
///
/// Exceeding the pool's allocation threshold is ordinary backpressure: the
/// writer is behind, and buffers come back as it drains. Every render loop used
/// to treat it as a reason to stop — returning out of the
/// `requestMediaDataWhenReady` block with no sample appended, no
/// `markAsFinished()` and no failure. `AVAssetWriterInput` re-invokes that
/// block on a NO -> YES transition of `isReadyForMoreMediaData`, and the loop
/// left while it was still YES, so nothing rescheduled it. The export produced
/// no file, no error and no progress, and its completion never fired.
///
/// These test the allocator, which is where the decision now lives. Whether a
/// given render loop is wired to it is a matter of reading the four call sites;
/// what is verified here is that waiting actually happens, that a recovered
/// pool is used, and that an unrecoverable one ends in a status the caller must
/// turn into a failure rather than a silent return.
final class ExportBackpressureTests: XCTestCase {

  /// A pool that can only ever have `threshold` buffers in flight at once.
  private func makePool(width: Int = 64, height: Int = 64) throws
    -> CVPixelBufferPool
  {
    let pixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String:
        Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(
      kCFAllocatorDefault,
      nil,
      pixelBufferAttributes as CFDictionary,
      &pool
    )
    guard status == kCVReturnSuccess, let pool else {
      throw XCTSkip("could not create a pixel buffer pool: \(status)")
    }
    return pool
  }

  func testAnUncontendedPoolAllocatesImmediately() throws {
    let pool = try makePool()

    let started = Date()
    let allocation = awaitPooledPixelBuffer(from: pool, maxInFlightBuffers: 4)

    XCTAssertEqual(allocation.status, kCVReturnSuccess)
    XCTAssertNotNil(allocation.pixelBuffer)
    XCTAssertLessThan(
      Date().timeIntervalSince(started), 1,
      "an available buffer must not be waited for")
  }

  /// The timeout path. A pool that never recovers must end in the
  /// would-exceed status, because that is what the call sites turn into a real
  /// export failure.
  func testAPoolThatNeverRecoversReportsTheThresholdStatus() throws {
    let pool = try makePool()
    // Hold every permitted buffer for the whole test.
    var held: [CVPixelBuffer] = []
    for _ in 0..<2 {
      let allocation = makePooledPixelBuffer(from: pool, maxInFlightBuffers: 2)
      guard let buffer = allocation.pixelBuffer else {
        throw XCTSkip("pool did not vend its first buffers")
      }
      held.append(buffer)
    }

    let started = Date()
    let allocation = awaitPooledPixelBuffer(
      from: pool, maxInFlightBuffers: 2, timeout: 0.15)
    let waited = Date().timeIntervalSince(started)

    XCTAssertEqual(
      allocation.status, kCVReturnWouldExceedAllocationThreshold,
      "the caller must see a terminal status it can fail on")
    XCTAssertNil(allocation.pixelBuffer)
    XCTAssertGreaterThanOrEqual(
      waited, 0.1,
      "it must actually wait before giving up, not return instantly")
    XCTAssertEqual(held.count, 2)
  }

  /// The point of waiting: a buffer returned mid-wait is picked up, and the
  /// frame that would have been abandoned is rendered instead.
  func testABufferReleasedDuringTheWaitIsUsed() throws {
    let pool = try makePool()
    var held: [CVPixelBuffer] = []
    for _ in 0..<2 {
      let allocation = makePooledPixelBuffer(from: pool, maxInFlightBuffers: 2)
      guard let buffer = allocation.pixelBuffer else {
        throw XCTSkip("pool did not vend its first buffers")
      }
      held.append(buffer)
    }

    // Give one back shortly after the wait begins, the way a draining writer
    // would.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
      held.removeLast()
    }

    let allocation = awaitPooledPixelBuffer(
      from: pool, maxInFlightBuffers: 2, timeout: 5)

    XCTAssertEqual(
      allocation.status, kCVReturnSuccess,
      "backpressure is transient; the frame must still be rendered")
    XCTAssertNotNil(allocation.pixelBuffer)
  }

  /// A cancelled export must not sit out the full timeout.
  func testCancellationEndsTheWaitEarly() throws {
    let pool = try makePool()
    var held: [CVPixelBuffer] = []
    for _ in 0..<2 {
      let allocation = makePooledPixelBuffer(from: pool, maxInFlightBuffers: 2)
      guard let buffer = allocation.pixelBuffer else {
        throw XCTSkip("pool did not vend its first buffers")
      }
      held.append(buffer)
    }

    let cancelled = NSLock()
    var isCancelled = false
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
      cancelled.lock()
      isCancelled = true
      cancelled.unlock()
    }

    let started = Date()
    let allocation = awaitPooledPixelBuffer(
      from: pool,
      maxInFlightBuffers: 2,
      timeout: 30,
      isCancelled: {
        cancelled.lock()
        defer { cancelled.unlock() }
        return isCancelled
      }
    )
    let waited = Date().timeIntervalSince(started)

    XCTAssertEqual(allocation.status, kCVReturnWouldExceedAllocationThreshold)
    XCTAssertLessThan(
      waited, 5,
      "pressing Stop must not leave the user waiting out the timeout")
    XCTAssertEqual(held.count, 2)
  }

  /// The default timeout is a deliberate value, not an accident. If someone
  /// shortens it to something a normal stall could hit, exports start failing
  /// on load rather than waiting it out.
  func testTheDefaultWaitIsGenerous() {
    XCTAssertGreaterThanOrEqual(
      exportPixelBufferWaitTimeout, 5,
      "the wait exists to outlast a normal stall, not to police a slow writer")
  }
}
