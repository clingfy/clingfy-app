import FlutterMacOS
import XCTest

@testable import Clingfy

/// PR 7 guard: getCaptureDiagnostics / getStorageSnapshot still resolve and
/// behave after being moved into the StorageDiagnosticsService extension.
/// Read-only (disk-capacity / snapshot queries only) — no recording started.
///
/// Also covers the speech-model delete gate. Nothing here removes a real model:
/// `deleteCaptionModel` takes its remover as a parameter defaulted to
/// `CaptionModelStore.delete`, and these pass a spy — running this suite on a
/// machine with a 730 MB model installed must not cost the developer the model,
/// and a test that only asserted the reply would do exactly that the moment the
/// refusal regressed.
@MainActor
final class StorageDiagnosticsServiceTests: XCTestCase {

  func testCaptureDiagnosticsPayloadHasBackendAndFps() {
    let facade = ScreenRecorderFacade()
    var payload: [String: Any]?
    facade.getCaptureDiagnostics { payload = $0 as? [String: Any] }

    let p = try? XCTUnwrap(payload)
    XCTAssertNotNil(p?["backend"] as? String)
    XCTAssertEqual(p?["captureFps"] as? Int, 30)
  }

  func testStorageSnapshotReturnsNonEmptyMap() {
    let facade = ScreenRecorderFacade()
    var snapshot: [String: Any]?
    facade.getStorageSnapshot { snapshot = $0 as? [String: Any] }

    XCTAssertFalse((snapshot ?? [:]).isEmpty)
  }

  func testCaptureDestinationURLFallsBackToTempWhenNoActiveProject() {
    let facade = ScreenRecorderFacade()
    XCTAssertEqual(facade.currentCaptureDestinationURL(), AppPaths.tempRoot())
  }

  // MARK: - Deleting the speech model

  /// An engine that can be told whether to hand its (imaginary) weights back.
  ///
  /// The real engine only declines after a real cancelled 626 MB download, which
  /// is why the refusal path had no coverage at all.
  private final class StubTranscriber: CaptionTranscriber {
    var availability: TranscriberAvailability = .available
    private let releaseSucceeds: Bool

    init(releaseSucceeds: Bool) { self.releaseSucceeds = releaseSucceeds }

    func releaseModel() async -> Bool { releaseSucceeds }

    func transcribe(
      url: URL,
      options: TranscriptionOptions,
      progress: @escaping (TranscriptionProgress) -> Void,
      isCancelled: @escaping () -> Bool
    ) throws -> [TranscribedSegment] { [] }
  }

  /// Counts the deletes the production code would have performed.
  private final class DeleteSpy {
    private let lock = NSLock()
    private var calls = 0
    let freedBytes: Int64

    init(freedBytes: Int64 = 730_000_000) { self.freedBytes = freedBytes }

    var callCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return calls
    }

    func remove() -> Int64 {
      lock.lock()
      calls += 1
      lock.unlock()
      return freedBytes
    }
  }

  private func facade(releaseSucceeds: Bool) -> ScreenRecorderFacade {
    let facade = ScreenRecorderFacade()
    facade.useCaptionsServiceForTesting(
      CaptionsService(transcriber: StubTranscriber(releaseSucceeds: releaseSucceeds)))
    return facade
  }

  private func delete(
    on facade: ScreenRecorderFacade, using spy: DeleteSpy
  ) -> Any? {
    var reply: Any?
    let done = expectation(description: "deleteCaptionModel replied")
    facade.deleteCaptionModel(
      removeModel: { spy.remove() },
      result: { value in
        reply = value
        done.fulfill()
      })
    wait(for: [done], timeout: 5)
    return reply
  }

  /// The refusal has to ACT, not merely be reported one layer down.
  ///
  /// `CaptionsService.releaseModel` propagating `false` and the engine answering
  /// `false` were both covered; nothing proved this method did anything with it.
  /// Removing the guard left every one of those tests green while the defect —
  /// ~730 MB unlinked while Core ML still had it mmapped, and an uninterruptible
  /// download still writing more of it into the same folder — shipped. Deleting
  /// then frees nothing, leaves the engine reading from an inode with no name,
  /// and reports success: three lies at once.
  func testDeletingIsRefusedWhenTheEngineWouldNotHandTheWeightsBack() throws {
    let spy = DeleteSpy()
    let reply = delete(on: facade(releaseSucceeds: false), using: spy)

    XCTAssertEqual(
      spy.callCount, 0,
      "the weights were never unloaded, so removing them frees nothing and races a live mapping")
    let error = try XCTUnwrap(
      reply as? FlutterError, "got \(String(describing: reply)) — a refusal must not read as success")
    XCTAssertEqual(error.code, "MODEL_IN_USE")
    XCTAssertEqual(error.message, ScreenRecorderFacade.captionModelInUseError().message)
  }

  /// And the guard must not be a permanent no: an engine that did unload has to
  /// let the delete through, or the button never works.
  func testDeletingProceedsOnceTheEngineHasHandedTheWeightsBack() throws {
    let spy = DeleteSpy(freedBytes: 1_234)
    let reply = delete(on: facade(releaseSucceeds: true), using: spy)

    XCTAssertEqual(spy.callCount, 1)
    let payload = try XCTUnwrap(
      reply as? [String: Any], "got \(String(describing: reply))")
    XCTAssertEqual(payload["freedBytes"] as? Int, 1_234)
  }
}
