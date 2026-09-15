import AVFoundation
import XCTest

@testable import Clingfy

/// Renders a REAL recording with captions burned in, so a human can look at it.
///
/// This is the visual half of the caption spike. Shaping, legibility, position
/// and colour over real screen content are judgement calls no assertion makes:
/// a test can prove the caption pixels are the colour that was authored, it
/// cannot tell you the caption is too small, sits over the thing the user was
/// pointing at, or that the Arabic letters failed to join.
///
/// Two-step, because rasterizing needs a Flutter engine and compositing needs
/// AVFoundation:
///
/// ```
///   flutter test test/core/captions/caption_proof_bitmaps.dart
///     └─ writes /tmp/clingfy-caption-proof/{cue_N.png, manifest.json}
///
///   xcodebuild test -only-testing:RunnerTests/CaptionBurnInProofTests
///     └─ writes /tmp/clingfy-caption-proof/burned-in.mov
/// ```
///
/// Skips rather than fails when the bitmaps or a source recording are absent,
/// so it never breaks CI on a machine that has neither.
final class CaptionBurnInProofTests: XCTestCase {

  private let proofDirectory = URL(fileURLWithPath: "/tmp/clingfy-caption-proof")

  /// Newest `.clingfyproj` in the dev app's recordings folder that has a
  /// readable `screen.mov`.
  private func newestRecordingScreenURL() -> URL? {
    let recordings = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/com.clingfy.clingfy.dev/Recordings")
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: recordings, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return nil }

    let projects =
      entries
      .filter { $0.pathExtension == "clingfyproj" }
      .map { url -> (URL, Date) in
        let date =
          (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        return (url, date)
      }
      .sorted { $0.1 > $1.1 }

    for (project, _) in projects {
      let screen = project.appendingPathComponent("capture/screen.mov")
      if FileManager.default.fileExists(atPath: screen.path),
        AVAsset(url: screen).tracks(withMediaType: .video).first != nil
      {
        return screen
      }
    }
    return nil
  }

  private func loadCues() -> [CaptionCueTrack.Cue] {
    let manifest = proofDirectory.appendingPathComponent("manifest.json")
    guard
      let data = try? Data(contentsOf: manifest),
      let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return CaptionCueTrack.Cue.listFromFlutter(raw)
  }

  func testBurnsCaptionsIntoARealRecordingForVisualInspection() throws {
    let cues = loadCues()
    try XCTSkipIf(
      cues.isEmpty,
      """
      No caption bitmaps found. Generate them first:
        flutter test test/core/captions/caption_proof_bitmaps.dart
      """)

    let screenURL = try XCTSkipIfNil(
      newestRecordingScreenURL(),
      "No .clingfyproj with a readable screen.mov in the dev recordings folder")

    let asset = AVAsset(url: screenURL)
    let params = CompositionParams(
      targetSize: CGSize(width: 1920, height: 1080),
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: false,
      zoomFactor: 1.0,
      followStrength: 0.15,
      fpsHint: 30,
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0
    )

    let composition = try XCTUnwrap(
      CompositionBuilder().buildExport(
        asset: asset,
        cameraAsset: nil,
        params: params,
        cameraParams: nil,
        cursorRecording: nil,
        cameraAssetIsPreStyled: false
      ))

    // A non-identity grade on purpose. If captions were composited at the
    // CALayer seat instead of the writer-loop seat, this warm/bright grade
    // would visibly tint them and the exported file would show it.
    let grade = ColorGrade(
      autoEnabled: false, exposure: 0.35, contrast: 0.15, saturation: 0.2,
      temperature: 0.25, tint: 0
    )

    let outputURL = proofDirectory.appendingPathComponent("burned-in.mov")
    try? FileManager.default.removeItem(at: outputURL)

    let exporter = LetterboxExporter()
    let done = expectation(description: "caption burn-in proof render")
    var outcome: Result<URL, Error>?

    exporter._testRenderFinalExport(
      result: composition,
      outputURL: outputURL,
      colorGrade: grade,
      captionBitmapDirectory: proofDirectory.path,
      captions: cues
    ) { result in
      outcome = result
      done.fulfill()
    }
    wait(for: [done], timeout: 600)

    switch try XCTUnwrap(outcome) {
    case .failure(let error):
      XCTFail("render failed: \(error)")
    case .success(let url):
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
      let size =
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
          as? Int) ?? 0
      XCTAssertGreaterThan(size ?? 0, 0, "wrote an empty file")
      let summary = """

        ────────────────────────────────────────────────────────────
        CAPTION BURN-IN PROOF
          source : \(screenURL.path)
          output : \(url.path)
          cues   : \(cues.count)
          grade  : exposure 0.35, contrast 0.15, saturation 0.2, temp 0.25

        LOOK FOR:
          • Arabic letters JOINED, not isolated boxes  (cue at 9.5s)
          • mixed line reads  مرحبا Clingfy  in the right visual order (13.5s)
          • captions NOT tinted by the warm grade — they should stay neutral
          • text sharp, not upscaled or soft
          • pill sits at a sensible height and does not cover the content
        ────────────────────────────────────────────────────────────

        """
      NSLog("%@", summary)
      print(summary)
    }
  }

  /// `XCTSkipIf` has no optional-unwrapping variant.
  private func XCTSkipIfNil<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw XCTSkip(message) }
    return value
  }
}
