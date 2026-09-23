import XCTest

@testable import Clingfy

/// The sleep hold that keeps a long export from being killed by idle sleep.
///
/// These test the SLOT, not `ProcessInfo`. macOS gives no readable
/// back-channel for "is an activity held" — `pmset -g assertions` is a
/// subprocess, not an API — so a test that claimed to verify the real hold
/// would be asserting nothing. What is worth testing is the part that can
/// actually be wrong: the bookkeeping. A hold acquired and never released
/// keeps the user's Mac awake until the app quits, which is a worse bug than
/// the one this fixes and is invisible until their battery is flat.
final class KeepAwakeTests: XCTestCase {

  /// Counts instead of holding anything.
  ///
  /// Internally synchronised because the slot is exercised from several
  /// threads below, and an unsynchronised array here would corrupt under that
  /// — a crash in the harness that reads exactly like a bug in the subject.
  private final class FakeKeepAwake: KeepAwake {
    private let lock = NSLock()
    private var beginsByReason: [String] = []
    private var endedTokens: [ObjectIdentifier] = []
    /// Issued tokens are RETAINED for the life of the fake. `ObjectIdentifier`
    /// is the object's address, so a token that is released and deallocated
    /// lets the next allocation reuse that address — two logically different
    /// holds would then share an identifier and a leak could hide behind the
    /// arithmetic. Holding them keeps every identifier distinct.
    private var issued: [Token] = []

    final class Token {}

    func begin(reason: String) -> Any {
      let token = Token()
      lock.lock()
      beginsByReason.append(reason)
      issued.append(token)
      lock.unlock()
      return token
    }

    func end(_ token: Any) {
      guard let token = token as? Token else {
        XCTFail("ended a token this service never issued")
        return
      }
      lock.lock()
      endedTokens.append(ObjectIdentifier(token))
      lock.unlock()
    }

    var begun: [String] {
      lock.lock()
      defer { lock.unlock() }
      return beginsByReason
    }

    var ended: [ObjectIdentifier] {
      lock.lock()
      defer { lock.unlock() }
      return endedTokens
    }

    /// Distinct tokens ended, so a double-end cannot mask a leak by making the
    /// arithmetic come out right.
    var liveCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return beginsByReason.count - Set(endedTokens).count
    }
  }

  func testAcquireThenReleaseLeavesNothingHeld() {
    let fake = FakeKeepAwake()
    let slot = KeepAwakeSlot(service: fake)

    slot.acquire(reason: "export")
    XCTAssertTrue(slot.isHeld)
    XCTAssertEqual(fake.liveCount, 1)

    slot.release()
    XCTAssertFalse(slot.isHeld)
    XCTAssertEqual(
      fake.liveCount, 0,
      "an export that finished must not leave the Mac awake")
  }

  func testReleaseWithoutAcquireIsHarmless() {
    let fake = FakeKeepAwake()
    let slot = KeepAwakeSlot(service: fake)

    slot.release()
    slot.release()

    XCTAssertEqual(fake.begun.count, 0)
    XCTAssertEqual(fake.ended.count, 0)
  }

  /// A completion that fires twice must not end the same activity twice.
  func testDoubleReleaseEndsTheActivityOnce() {
    let fake = FakeKeepAwake()
    let slot = KeepAwakeSlot(service: fake)

    slot.acquire(reason: "export")
    slot.release()
    slot.release()

    XCTAssertEqual(fake.ended.count, 1)
    XCTAssertEqual(fake.liveCount, 0)
  }

  /// The orphan this type exists to prevent.
  ///
  /// `LetterboxExporter.export` supports re-entrancy on purpose — it opens by
  /// cancelling the previous export — and the exporter is one app-lifetime
  /// instance, so a second export overwrites these fields before the first is
  /// told to stop. A plain `var token: Any?` would drop the only reference to
  /// the first token with nothing left able to end it.
  func testAcquiringTwiceEndsTheFirstHoldRatherThanOrphaningIt() {
    let fake = FakeKeepAwake()
    let slot = KeepAwakeSlot(service: fake)

    slot.acquire(reason: "export A")
    slot.acquire(reason: "export B")

    XCTAssertEqual(fake.begun, ["export A", "export B"])
    XCTAssertEqual(
      fake.ended.count, 1,
      "the first hold must be ended when it is replaced, not leaked")
    XCTAssertEqual(fake.liveCount, 1, "export B is still running")

    slot.release()
    XCTAssertEqual(
      fake.liveCount, 0,
      "and B's release must leave nothing behind")
  }

  /// Many exports in a row must not accumulate holds.
  func testRepeatedExportsBalanceOut() {
    let fake = FakeKeepAwake()
    let slot = KeepAwakeSlot(service: fake)

    for index in 0..<25 {
      slot.acquire(reason: "export \(index)")
      slot.release()
    }

    XCTAssertEqual(fake.begun.count, 25)
    XCTAssertEqual(fake.liveCount, 0)
    XCTAssertFalse(slot.isHeld)
  }

  /// Completions fire off the main queue, so the slot is touched from several
  /// threads. It must not lose a token or over-release one.
  func testConcurrentAcquireAndReleaseStayBalanced() {
    let fake = FakeKeepAwake()
    let slot = KeepAwakeSlot(service: fake)
    let queue = DispatchQueue(
      label: "keepawake.test", attributes: .concurrent)
    let group = DispatchGroup()

    for index in 0..<200 {
      queue.async(group: group) {
        if index.isMultiple(of: 2) {
          slot.acquire(reason: "export \(index)")
        } else {
          slot.release()
        }
      }
    }
    group.wait()

    slot.release()

    XCTAssertFalse(slot.isHeld)
    XCTAssertEqual(
      fake.liveCount, 0,
      "every begin must be matched by exactly one end")
  }

  /// The real service must hand back something it can end again, and ending it
  /// must not throw or trap. This is as far as ProcessInfo can be verified
  /// without shelling out to pmset.
  func testProcessInfoServiceRoundTripsAToken() {
    let service = ProcessInfoKeepAwake()
    let token = service.begin(reason: "RunnerTests keep-awake probe")
    XCTAssertTrue(token is NSObjectProtocol)
    service.end(token)
  }

  /// The exporter exposes its slot so an export's acquire/release can be
  /// observed; if this stops compiling the wiring has been renamed.
  func testExporterOwnsAKeepAwakeSlot() {
    let exporter = LetterboxExporter()
    XCTAssertFalse(
      exporter.exportKeepAwake.isHeld,
      "a fresh exporter holds nothing")
  }
}
