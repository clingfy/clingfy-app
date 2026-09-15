import AppKit
import XCTest

@testable import Clingfy

/// Hardware-free tests for the pure display ordering + labelling.
///
/// The literal outputs asserted here are mirrored by
/// `windows/runner_tests/display_label_test.cpp`. If either platform's
/// algorithm drifts, one of the two suites goes red.
final class DisplayLabelerTests: XCTestCase {

  private func desc(
    id: CGDirectDisplayID,
    osName: String? = nil,
    x: Double = 0,
    y: Double = 0,
    width: Double = 2560,
    height: Double = 1440,
    scale: Double = 2,
    isPrimary: Bool = false,
    isAppWindowHost: Bool = false
  ) -> DisplayLabeler.Descriptor {
    DisplayLabeler.Descriptor(
      id: id, osName: DisplayLabeler.normalizedOSName(osName), x: x, y: y,
      width: width, height: height, scale: scale,
      isPrimary: isPrimary, isAppWindowHost: isAppWindowHost)
  }

  // MARK: - Ordering

  func testOrderingIsLeftToRightThenTopToBottom() {
    let payloads = DisplayLabeler.payloads(
      from: [
        desc(id: 3, osName: "C", x: 4072),
        desc(id: 1, osName: "A", x: 0),
        desc(id: 2, osName: "B", x: 1512),
      ], screenWord: "Screen")

    XCTAssertEqual(payloads.map { $0["id"] as! UInt32 }, [1, 2, 3])
    XCTAssertEqual(payloads.map { $0["ordinal"] as! Int }, [1, 2, 3])
  }

  func testStackedDisplaysAreNumberedTopDown() {
    // AppKit is y-up: the display with the greater (y + height) is physically
    // HIGHER. Win32's rcMonitor.top is y-down. Sorting each on its own native
    // y would number a stacked pair in opposite directions on the two
    // platforms, so this pins the shared top-down semantic.
    //
    // An external monitor mounted ABOVE a laptop, laptop as the main display:
    //   laptop   origin.y = 0,    height 900  -> top edge at  900
    //   external origin.y = 900,  height 1080 -> top edge at 1980
    let stacked = DisplayLabeler.payloads(
      from: [
        desc(id: 1, osName: "Laptop", x: 0, y: 0, height: 900),
        desc(id: 2, osName: "External", x: 0, y: 900, height: 1080),
      ], screenWord: "Screen")

    XCTAssertEqual(
      stacked.map { $0["id"] as! UInt32 }, [2, 1],
      "the physically higher display must be number 1")
    XCTAssertEqual(stacked[0]["name"] as! String, "1. External")
    XCTAssertEqual(stacked[1]["name"] as! String, "2. Laptop")
  }

  func testOrderingTieBreaksOnId() {
    let byID = DisplayLabeler.payloads(
      from: [desc(id: 7, x: 0, y: 0), desc(id: 3, x: 0, y: 0)],
      screenWord: "Screen")
    XCTAssertEqual(byID.map { $0["id"] as! UInt32 }, [3, 7], "identical geometry falls back to id")
  }

  func testOrderingIsIndependentOfInputPermutation() {
    // The hotplug / enumeration-order drift guard: whatever order the OS hands
    // us its screens in, a display keeps the same ordinal.
    let a = desc(id: 11, osName: "A", x: 0)
    let b = desc(id: 22, osName: "B", x: 1512)
    let c = desc(id: 33, osName: "C", x: 4072)

    let permutations: [[DisplayLabeler.Descriptor]] = [
      [a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a],
    ]

    var expected: [UInt32: Int] = [:]
    for payload in DisplayLabeler.payloads(from: permutations[0], screenWord: "Screen") {
      expected[payload["id"] as! UInt32] = (payload["ordinal"] as! Int)
    }
    XCTAssertEqual(expected, [11: 1, 22: 2, 33: 3])

    for permutation in permutations.dropFirst() {
      var actual: [UInt32: Int] = [:]
      for payload in DisplayLabeler.payloads(from: permutation, screenWord: "Screen") {
        actual[payload["id"] as! UInt32] = (payload["ordinal"] as! Int)
      }
      XCTAssertEqual(actual, expected, "ordinals must not depend on input order")
    }
  }

  // MARK: - Names

  func testEmptyOSNameFallsBackToLocalizedScreenWord() {
    let payloads = DisplayLabeler.payloads(from: [desc(id: 1, osName: "")], screenWord: "Ecran")
    XCTAssertEqual(payloads[0]["name"] as! String, "1. Ecran")
    XCTAssertNil(payloads[0]["osName"])
  }

  func testGenericOSNamesAreRejected() {
    XCTAssertNil(DisplayLabeler.normalizedOSName("Generic PnP Monitor"))
    XCTAssertNil(DisplayLabeler.normalizedOSName("  generic non-pnp monitor  "))
    XCTAssertNil(DisplayLabeler.normalizedOSName("Display"))
    XCTAssertNil(DisplayLabeler.normalizedOSName("Unknown"))
    XCTAssertNil(DisplayLabeler.normalizedOSName("Unknown Display"))
    XCTAssertNil(DisplayLabeler.normalizedOSName("Default Monitor"))
    XCTAssertNil(DisplayLabeler.normalizedOSName(nil))
    XCTAssertEqual(DisplayLabeler.normalizedOSName("DELL U2720Q"), "DELL U2720Q")
  }

  func testInternalWhitespaceIsCollapsed() {
    let payloads = DisplayLabeler.payloads(
      from: [desc(id: 1, osName: "DELL   U2720Q\n")], screenWord: "Screen")
    XCTAssertEqual(payloads[0]["name"] as! String, "1. DELL U2720Q")
    XCTAssertEqual(payloads[0]["osName"] as! String, "DELL U2720Q")
  }

  func testDuplicateModelNamesAreDisambiguatedByOrdinal() {
    let payloads = DisplayLabeler.payloads(
      from: [
        desc(id: 1, osName: "DELL U2720Q", x: 0),
        desc(id: 2, osName: "DELL U2720Q", x: 2560),
      ], screenWord: "Screen")

    XCTAssertEqual(payloads[0]["name"] as! String, "1. DELL U2720Q")
    XCTAssertEqual(payloads[1]["name"] as! String, "2. DELL U2720Q")
  }

  // MARK: - Payload shape

  func testPayloadCarriesEveryKeyWithTheRightType() {
    let payloads = DisplayLabeler.payloads(
      from: [
        desc(
          id: 42, osName: "Studio Display", x: 1512, y: -120, width: 5120, height: 2880,
          scale: 2, isPrimary: true, isAppWindowHost: true)
      ], screenWord: "Screen")

    let payload = payloads[0]
    XCTAssertEqual(payload["id"] as! UInt32, 42)
    XCTAssertEqual(payload["name"] as! String, "1. Studio Display")
    XCTAssertEqual(payload["x"] as! Double, 1512)
    XCTAssertEqual(payload["y"] as! Double, -120)
    XCTAssertEqual(payload["width"] as! Double, 5120)
    XCTAssertEqual(payload["height"] as! Double, 2880)
    XCTAssertEqual(payload["scale"] as! Double, 2)
    XCTAssertEqual(payload["ordinal"] as! Int, 1)
    XCTAssertEqual(payload["osName"] as! String, "Studio Display")
    XCTAssertTrue(payload["isPrimary"] as! Bool)
    XCTAssertTrue(payload["isAppWindowHost"] as! Bool)
  }

  func testOsNameIsAbsentRatherThanEmpty() {
    let payloads = DisplayLabeler.payloads(
      from: [desc(id: 1, osName: "Generic PnP Monitor")], screenWord: "Screen")
    XCTAssertNil(payloads[0]["osName"], "an unusable name must be absent, not empty")
    XCTAssertFalse((payloads[0]["name"] as! String).isEmpty)
  }

  func testOrdinalIsTheNamePrefix() {
    // The coherence invariant, as an executable assertion: the number the
    // overlay paints is the number the picker row shows.
    let payloads = DisplayLabeler.payloads(
      from: [
        desc(id: 1, osName: "A", x: 0),
        desc(id: 2, osName: nil, x: 1512),
        desc(id: 3, osName: "C", x: 3000),
        desc(id: 4, osName: "D", x: 5000),
      ], screenWord: "Screen")

    XCTAssertEqual(payloads.count, 4)
    for payload in payloads {
      let name = payload["name"] as! String
      let ordinal = payload["ordinal"] as! Int
      XCTAssertTrue(
        name.hasPrefix("\(ordinal). "), "\(name) must be prefixed with its own ordinal \(ordinal)")
    }
    XCTAssertEqual(payloads.map { $0["ordinal"] as! Int }, [1, 2, 3, 4])
  }

  func testEmptyInputProducesEmptyPayloads() {
    XCTAssertTrue(DisplayLabeler.payloads(from: [], screenWord: "Screen").isEmpty)
  }

  // MARK: - Card geometry

  func testCardSizeClampsToTheShortSide() {
    let big = DisplayIdentifyView.cardSize(for: CGRect(x: 0, y: 0, width: 3840, height: 2160))
    XCTAssertLessThanOrEqual(big.height, 380)
    XCTAssertGreaterThanOrEqual(big.height, 180)

    let small = DisplayIdentifyView.cardSize(for: CGRect(x: 0, y: 0, width: 1280, height: 800))
    XCTAssertLessThanOrEqual(small.height, 380)
    XCTAssertGreaterThanOrEqual(small.height, 180)

    XCTAssertEqual(big.width / big.height, 1.8, accuracy: 0.0001)
  }

  func testSubtitleIsTheMonitorNameNotTheWholePickerRow() {
    // The ordinal is already the huge glyph; repeating it in the subtitle
    // wastes the width that the monitor's actual name needs.
    XCTAssertEqual(
      DisplayIdentifyView.subtitle(
        osName: "DELL U2720Q", fallback: "2. DELL U2720Q — Main · This window"),
      "DELL U2720Q")
    XCTAssertEqual(
      DisplayIdentifyView.subtitle(osName: nil, fallback: "2. Screen — Main"),
      "2. Screen — Main")
    XCTAssertEqual(
      DisplayIdentifyView.subtitle(osName: "", fallback: "2. Screen"), "2. Screen")
  }

  func testASmallScreenStillFitsATypicalMonitorName() {
    // 1440x900 MacBook: the card must leave room for a real product name.
    let size = DisplayIdentifyView.cardSize(for: CGRect(x: 0, y: 0, width: 1440, height: 900))
    let usable = size.width - 36
    XCTAssertGreaterThan(
      usable, 340, "a 1440x900 screen must fit a name like 'DELL U2720Q' unclipped")
  }

  func testOrdinalFontScalesWithTheCard() {
    XCTAssertEqual(DisplayIdentifyView.ordinalFontSize(for: 300), 138, accuracy: 0.0001)
    XCTAssertEqual(DisplayIdentifyView.subtitleFontSize(for: 300), 22, accuracy: 0.0001)
    XCTAssertEqual(DisplayIdentifyView.subtitleFontSize(for: 180), 19.8, accuracy: 0.0001)
  }
}
