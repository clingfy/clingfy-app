import XCTest

@testable import Clingfy

/// The latch that ends a recording segment.
///
/// It is awaited inside `finalizeSegment`, which both Stop and Pause run
/// through. Before it had a deadline, an `SCRecordingOutput` that reported
/// neither success nor failure left that await suspended forever: Stop never
/// completed, and because the recording keep-awake is released only where
/// `didStart` becomes false — all of which is past the await — the Mac could
/// not sleep either.
///
/// The risk in fixing it is worse than the bug. A timeout resumes a
/// continuation that a late `succeed()` may then resume again, and
/// double-resuming a `CheckedContinuation` traps the process rather than
/// returning an error. Several of these exist to pin exactly that ordering.
final class RecordingOutputFinalizationWaiterTests: XCTestCase {

  /// A resolved latch returns without suspending at all.
  func testSucceedBeforeWaitReturnsImmediately() async throws {
    let waiter = RecordingOutputFinalizationWaiter()
    waiter.succeed()
    try await waiter.wait(timeout: 30)
  }

  func testFailBeforeWaitThrowsThatError() async {
    struct Boom: Error {}
    let waiter = RecordingOutputFinalizationWaiter()
    waiter.fail(Boom())
    do {
      try await waiter.wait(timeout: 30)
      XCTFail("a failed latch must not report success")
    } catch is Boom {
      // expected
    } catch {
      XCTFail("wrong error: \(error)")
    }
  }

  func testAWaiterIsReleasedBySucceed() async throws {
    let waiter = RecordingOutputFinalizationWaiter()
    Task {
      try? await Task.sleep(nanoseconds: 30_000_000)
      waiter.succeed()
    }
    try await waiter.wait(timeout: 30)
  }

  /// The bug this exists for: nothing ever reports in.
  func testAnUnansweredWaitTimesOutInsteadOfHangingForever() async {
    let waiter = RecordingOutputFinalizationWaiter()
    let started = Date()
    do {
      try await waiter.wait(timeout: 0.3)
      XCTFail("an unanswered latch must not report success")
    } catch let error as RecordingOutputFinalizationWaiter.TimedOut {
      XCTAssertEqual(error.seconds, 0.3, accuracy: 0.001)
    } catch {
      XCTFail("wrong error: \(error)")
    }
    let waited = Date().timeIntervalSince(started)
    XCTAssertGreaterThanOrEqual(
      waited, 0.25, "it must actually wait, not fail instantly")
    XCTAssertLessThan(
      waited, 5, "and it must not keep waiting past the deadline")
  }

  /// THE ONE THAT MATTERS. A callback arriving after the deadline must be a
  /// no-op, not a second resume of a continuation the timeout already used.
  /// If this regresses the process traps with SWIFT TASK CONTINUATION MISUSE,
  /// so a passing run is the assertion.
  func testALateSucceedAfterTimeoutDoesNotDoubleResume() async {
    let waiter = RecordingOutputFinalizationWaiter()
    do {
      try await waiter.wait(timeout: 0.2)
      XCTFail("expected the timeout")
    } catch is RecordingOutputFinalizationWaiter.TimedOut {
      // expected
    } catch {
      XCTFail("wrong error: \(error)")
    }

    // The delegate finally reports in. This must not trap.
    waiter.succeed()
    waiter.fail(NSError(domain: "late", code: 1))
    waiter.succeed()

    // And the latch now tells the truth rather than the timeout it invented:
    // finalization really did land, so a later wait sees success.
    do {
      try await waiter.wait(timeout: 5)
    } catch {
      XCTFail("a late success must be recorded as success, got \(error)")
    }
  }

  /// A timeout is a property of ONE wait, not of the latch. A second waiter
  /// must not inherit the first one's expiry.
  func testATimeoutDoesNotPoisonTheLatchForOtherWaiters() async throws {
    let waiter = RecordingOutputFinalizationWaiter()
    do {
      try await waiter.wait(timeout: 0.2)
      XCTFail("expected the timeout")
    } catch is RecordingOutputFinalizationWaiter.TimedOut {
      // expected
    } catch {
      XCTFail("wrong error: \(error)")
    }

    waiter.succeed()
    try await waiter.wait(timeout: 5)
  }

  /// Several segments can be awaiting the same latch; all are released, and
  /// none is resumed twice.
  func testEveryConcurrentWaiterIsReleasedExactlyOnce() async throws {
    let waiter = RecordingOutputFinalizationWaiter()
    Task {
      try? await Task.sleep(nanoseconds: 50_000_000)
      waiter.succeed()
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask { try await waiter.wait(timeout: 30) }
      }
      try await group.waitForAll()
    }
  }

  /// A success that lands in the same instant as the deadline must resolve one
  /// way or the other, never both. Repeated because the interleaving is a
  /// race — a single pass would not be evidence.
  func testSucceedRacingTheDeadlineNeverDoubleResumes() async {
    for _ in 0..<40 {
      let waiter = RecordingOutputFinalizationWaiter()
      Task {
        try? await Task.sleep(nanoseconds: 20_000_000)
        waiter.succeed()
      }
      // Deadline deliberately set at the same moment the success arrives.
      do {
        try await waiter.wait(timeout: 0.02)
      } catch is RecordingOutputFinalizationWaiter.TimedOut {
        // Either outcome is legitimate; the point is that neither traps.
      } catch {
        XCTFail("wrong error: \(error)")
      }
    }
  }

  /// The default is a deliberate value. Shortening it to something a slow disk
  /// could hit would turn a rare hang into routine failed stops.
  func testTheDefaultDeadlineIsGenerous() {
    XCTAssertGreaterThanOrEqual(
      RecordingOutputFinalizationWaiter.defaultTimeout, 60,
      "this bounds a wedge; it does not police a slow volume")
  }
}
