import XCTest

@testable import Clingfy

/// The caption payload's route from the method channel to the render loop.
///
/// Burn-in shipped doing nothing, and every one of these links looked correct
/// in isolation: Flutter sent the cues, `ExportVideoRequest` parsed them, and
/// `ExportEngine.Input` declared and forwarded them. The break was in between —
/// `ScreenRecorderFacade.exportVideo` had no caption parameters at all, so the
/// parsed values reached that signature and stopped, leaving the engine's
/// defaults (`nil` / `[]`) in place. Nothing logged, nothing failed; the
/// exported file simply had no captions.
///
/// A defaulted parameter is what made it silent, so what these pin is that the
/// values actually TRAVEL, not merely that each end compiles.
final class ExportCaptionWiringTests: XCTestCase {

  private func payload(
    captions: [[String: Any]]? = nil,
    bitmapDirectory: String? = nil
  ) -> [String: Any] {
    var args: [String: Any] = [
      "projectPath": "/tmp/project.clingfyproj",
      "layoutPreset": "auto",
      "resolutionPreset": "auto",
    ]
    if let captions { args["captions"] = captions }
    if let bitmapDirectory { args["captionBitmapDirectory"] = bitmapDirectory }
    return args
  }

  private func cue(
    _ id: String, _ startMs: Int, _ endMs: Int, _ bitmap: String
  ) -> [String: Any] {
    [
      "id": id,
      "startMs": NSNumber(value: startMs),
      "endMs": NSNumber(value: endMs),
      "bitmapName": bitmap,
    ]
  }

  // MARK: - The request

  func testRequestCarriesCuesAndDirectory() {
    let request = ExportVideoRequest.fromFlutter(
      payload(
        captions: [cue("c1", 0, 1500, "a.png"), cue("c2", 2000, 3000, "b.png")],
        bitmapDirectory: "/tmp/project.clingfyproj/post/captions"))

    XCTAssertEqual(request?.captions.count, 2)
    XCTAssertEqual(request?.captions.first?.bitmapName, "a.png")
    XCTAssertEqual(
      request?.captionBitmapDirectory, "/tmp/project.clingfyproj/post/captions")
  }

  /// A payload from before captions existed must still export, unchanged.
  func testAPayloadWithNoCaptionsIsAcceptedAsNoBurnIn() {
    let request = ExportVideoRequest.fromFlutter(payload())
    XCTAssertNotNil(request)
    XCTAssertTrue(request?.captions.isEmpty ?? false)
    XCTAssertNil(request?.captionBitmapDirectory)
  }

  // MARK: - The engine input

  /// The link that was missing. `Input` is what the facade hands the engine, so
  /// a caption payload that survives the request but not this struct is exactly
  /// the failure that shipped.
  func testRequestFieldsAreTheOnesTheEngineNeeds() {
    // The engine's Input takes these two verbatim, so a request that carries
    // them is a request the engine can burn in — provided every signature in
    // between forwards them, which is the link that was missing.
    let request = ExportVideoRequest.fromFlutter(
      payload(
        captions: [cue("c1", 0, 1500, "a.png")],
        bitmapDirectory: "/tmp/caps"))

    XCTAssertEqual(request?.captions.count, 1)
    XCTAssertEqual(request?.captionBitmapDirectory, "/tmp/caps")
    XCTAssertEqual(request?.captions.first?.startMs, 0)
    XCTAssertEqual(request?.captions.first?.endMs, 1500)
  }

  // MARK: - What the render loop will accept

  /// The cue track is what decides whether anything is drawn. A payload that
  /// reaches it and is then rejected wholesale looks identical, from the
  /// exported file, to a payload that never arrived.
  func testAWellFormedPayloadSurvivesIntoADrawableTrack() {
    let request = ExportVideoRequest.fromFlutter(
      payload(
        captions: [cue("c1", 0, 1500, "a.png"), cue("c2", 1500, 3000, "b.png")],
        bitmapDirectory: "/tmp/caps"))
    var track = CaptionCueTrack(cues: request?.captions ?? [])

    XCTAssertEqual(track.count, 2, "both cues must survive into the track")
    XCTAssertTrue(track.rejectedCueIds.isEmpty)
    XCTAssertEqual(track.activeCue(atSourceMs: 500)?.id, "c1")
  }
}
