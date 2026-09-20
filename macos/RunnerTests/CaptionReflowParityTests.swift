import XCTest

@testable import Clingfy

/// The Swift half of the caption-reflow parity contract.
///
/// `CaptionReflow` on the Dart side re-implements the native clip-placement
/// maths so cue times survive cuts, splits, trims and reorders. Its own
/// docstring names the three behaviours it mirrors -- `ClipKeptRange.fromFlutter`,
/// `ClipPlaybackPlanner.coalesce`, and `ClipPlaybackPlanner.editedMsForKeptSourceMs`
/// -- but nothing compared the two implementations. Each was checked against
/// its own author's belief, so changing one side moved burned-in caption
/// timings in the exported video while the `.srt`/`.vtt` beside it stayed
/// correct, with every test on both sides green.
///
/// This reads the same `test/fixtures/caption_reflow_cases.json` that
/// `caption_reflow_parity_test.dart` reads, and drives it through the real
/// production functions rather than a local re-derivation. The expected numbers
/// live in the fixture and nowhere else; that single authorship is the whole
/// mechanism. A re-implementation here would just be a third opinion.
///
/// WHAT THIS DOES AND DOES NOT DISCRIMINATE. Of the three mirrored behaviours,
/// the fixture pins two: `ClipKeptRange.fromFlutter` (which clips are kept, in
/// what order, and that `timelineStartMs` is ignored) and
/// `editedMsForKeptSourceMs` (where a kept source moment lands). `coalesce` is
/// exercised but cannot be discriminated by this table, and saying so is more
/// use than implying coverage: merging two touching ranges [a,b) and [b,c) is
/// mapping-invariant, because unmerged gives (b-a) + (s-b) and merged gives
/// (s-a) -- the same number. Coalescing matters elsewhere, for reader windows
/// and `isSourceMonotonic`, and needs its own pin if that is wanted.
final class CaptionReflowParityTests: XCTestCase {

  private struct Probe {
    let sourceMs: Int
    /// nil = cut away, with no place on the edited timeline.
    let outputMs: Int?
  }

  private struct Case {
    let name: String
    let clips: [[String: Any]]
    let probes: [Probe]
  }

  /// Walks up from this file to the repo root rather than taking a path from
  /// the build environment: the fixture is shared with the Dart suite, and it
  /// is not copied into the test bundle's resources.
  private func fixtureURL() throws -> URL {
    var dir = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // macos/RunnerTests
      .deletingLastPathComponent()  // macos
      .deletingLastPathComponent()  // repo root
    let candidate = dir.appendingPathComponent("test/fixtures/caption_reflow_cases.json")
    guard FileManager.default.fileExists(atPath: candidate.path) else {
      // Be loud about WHERE it looked. A silently skipped parity test is the
      // same nothing as not having one.
      dir = URL(fileURLWithPath: #filePath)
      throw XCTSkip(
        "shared fixture not found at \(candidate.path) (from \(dir.path)) -- if it moved, "
          + "move it in the Dart test too or the two suites stop comparing anything")
    }
    return candidate
  }

  private func loadCases() throws -> [Case] {
    let data = try Data(contentsOf: try fixtureURL())
    let root = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let raw = try XCTUnwrap(root["cases"] as? [[String: Any]])

    return try raw.map { item in
      Case(
        name: try XCTUnwrap(item["name"] as? String),
        clips: try XCTUnwrap(item["clips"] as? [[String: Any]]),
        probes: try XCTUnwrap(item["probes"] as? [[String: Any]]).map { p in
          // `NSNull` is how JSONSerialization represents an explicit null, and
          // it is NOT the same as an absent key: absent would mean the fixture
          // forgot to say, which must not read as "cut away".
          let out = p["outputMs"]
          return Probe(
            sourceMs: (p["sourceMs"] as? NSNumber)?.intValue ?? -1,
            outputMs: (out is NSNull) ? nil : (out as? NSNumber)?.intValue
          )
        }
      )
    }
  }

  func testTheSourceToOutputMappingMatchesTheSharedFixture() throws {
    let cases = try loadCases()
    XCTAssertFalse(
      cases.isEmpty, "the fixture parsed to no cases, so this asserts nothing")

    var checked = 0
    for testCase in cases {
      // The real production path, in the order the exporter uses it.
      let ranges = ClipPlaybackPlanner.coalesce(
        ranges: ClipKeptRange.fromFlutter(testCase.clips))

      for probe in testCase.probes {
        let actual = ClipPlaybackPlanner.editedMsForKeptSourceMs(
          probe.sourceMs, ranges: ranges)
        XCTAssertEqual(
          actual, probe.outputMs,
          "\(testCase.name): source \(probe.sourceMs)ms should land at "
            + "\(probe.outputMs.map(String.init) ?? "nowhere (cut away)") "
            + "but Swift places it at \(actual.map(String.init) ?? "nowhere"). "
            + "If Dart still agrees with the fixture, this side has diverged.")
        checked += 1
      }
    }

    // Guards the shape of the fixture itself: a file that parsed into cases
    // with no probes would pass every assertion above by running none.
    XCTAssertGreaterThan(
      checked, 20,  // the fixture carries 24
      "far fewer probes than the fixture carries -- the parse dropped some")
  }
}
