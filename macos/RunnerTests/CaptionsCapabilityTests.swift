import XCTest

@testable import Clingfy

/// Pins the capability decision table and the bridge payload keys.
///
/// The keys matter as much as the logic: they are mirrored by the Dart side and
/// by the Windows router, and renaming one silently disables captions rather
/// than failing loudly.
final class CaptionsCapabilityTests: XCTestCase {

  private func resolve(
    appleSilicon: Bool = true,
    minimumOS: Bool = true,
    mic: Bool = false,
    system: Bool = false,
    embedded: Bool = false
  ) -> CaptionsCapability {
    CaptionsCapability.resolve(
      isAppleSilicon: appleSilicon,
      meetsMinimumOS: minimumOS,
      hasDecodableMic: mic,
      hasDecodableSystem: system,
      hasDecodableEmbedded: embedded)
  }

  // MARK: - Platform gates come first

  /// A Mac that cannot run the engine should say so, rather than complaining
  /// about the recording it was never going to transcribe.
  func testOSCheckWinsOverEverythingElse() {
    let capability = resolve(minimumOS: false, mic: true, system: true)
    XCTAssertFalse(capability.isAvailable)
    XCTAssertEqual(capability.reason, .unsupportedOS)
  }

  func testIntelIsReportedAsItsOwnReasonNotAsNoAudio() {
    let capability = resolve(appleSilicon: false, mic: true)
    XCTAssertEqual(
      capability.reason, .intelSlowPath,
      "Intel is a slow path, not a missing recording — the message differs")
  }

  func testIntelOutranksMissingAudio() {
    XCTAssertEqual(resolve(appleSilicon: false).reason, .intelSlowPath)
  }

  // MARK: - Recording contents

  func testNoDecodableAudioAnywhereIsUnavailable() {
    let capability = resolve()
    XCTAssertFalse(capability.isAvailable)
    XCTAssertEqual(capability.reason, .noAudio)
  }

  func testMicOnlyRecordingIsAvailable() {
    let capability = resolve(mic: true)
    XCTAssertTrue(capability.isAvailable)
    XCTAssertNil(capability.reason)
    XCTAssertTrue(capability.hasMicAudio)
    XCTAssertFalse(capability.hasSystemAudio)
  }

  func testSystemOnlyRecordingIsAvailable() {
    let capability = resolve(system: true)
    XCTAssertTrue(capability.isAvailable)
    XCTAssertFalse(capability.hasMicAudio)
    XCTAssertTrue(capability.hasSystemAudio)
  }

  func testBothSourcesAreReportedIndependently() {
    let capability = resolve(mic: true, system: true)
    XCTAssertTrue(capability.hasMicAudio)
    XCTAssertTrue(capability.hasSystemAudio)
    XCTAssertFalse(capability.usesEmbeddedAudioOnly)
  }

  // MARK: - The pre-macOS-15 fallback

  /// Sidecars only exist on the ScreenCaptureKit backend, which is macOS 15+.
  /// Recordings made below that have audio only inside screen.mov — and on that
  /// backend it is the MICROPHONE alone, because it never captured system audio.
  func testEmbeddedAudioAloneIsAvailableAndFlagged() {
    let capability = resolve(embedded: true)
    XCTAssertTrue(capability.isAvailable)
    XCTAssertTrue(capability.usesEmbeddedAudioOnly)
    XCTAssertFalse(capability.hasMicAudio, "not a sidecar")
    XCTAssertFalse(capability.hasSystemAudio)
  }

  func testSidecarsAlwaysWinOverEmbeddedAudio() {
    let capability = resolve(mic: true, embedded: true)
    XCTAssertFalse(
      capability.usesEmbeddedAudioOnly,
      "a real sidecar must never fall back to the premix")
  }

  func testEmbeddedFallbackStillDefaultsToTranscribingSomething() {
    let capability = resolve(embedded: true)
    XCTAssertTrue(capability.defaultUsesMic, "the premix is the microphone")
    XCTAssertFalse(capability.defaultUsesSystem)
  }

  // MARK: - Source defaults

  /// The owner's call: meetings, demos and tutorials are the common case and
  /// both sides matter, so both sources are on by default when both exist.
  func testBothSourcesAreOnByDefaultWhenBothExist() {
    let capability = resolve(mic: true, system: true)
    XCTAssertTrue(capability.defaultUsesMic)
    XCTAssertTrue(capability.defaultUsesSystem)
  }

  func testASingleSourceIsSelectedWithoutOfferingAChoice() {
    XCTAssertFalse(resolve(mic: true).shouldOfferSourcePicker)
    XCTAssertFalse(resolve(system: true).shouldOfferSourcePicker)
    XCTAssertTrue(resolve(mic: true, system: true).shouldOfferSourcePicker)
  }

  func testSystemOnlyRecordingDoesNotDefaultToTheAbsentMic() {
    let capability = resolve(system: true)
    XCTAssertFalse(capability.defaultUsesMic)
    XCTAssertTrue(capability.defaultUsesSystem)
  }

  // MARK: - Bridge payload

  /// Renaming any of these silently disables captions instead of failing
  /// loudly, so the shape is pinned here and mirrored in the Dart test.
  func testPayloadCarriesTheExactKeysTheOtherSidesParse() {
    let payload = resolve(mic: true, system: true).toFlutter()
    XCTAssertEqual(payload["available"] as? Bool, true)
    XCTAssertEqual(payload["hasMicAudio"] as? Bool, true)
    XCTAssertEqual(payload["hasSystemAudio"] as? Bool, true)
    XCTAssertEqual(payload["usesEmbeddedAudioOnly"] as? Bool, false)
    XCTAssertNil(payload["reason"], "no reason key when available")
  }

  func testUnavailablePayloadCarriesAMachineReadableReason() {
    let payload = CaptionsCapability.unavailable(.intelSlowPath).toFlutter()
    XCTAssertEqual(payload["available"] as? Bool, false)
    XCTAssertEqual(
      payload["reason"] as? String, "intelSlowPath",
      "the UI localises from this, so it must be stable and not a message")
  }

  func testEveryReasonHasAStableWireValue() {
    // These strings cross the bridge and get localised on the Dart side.
    // Changing one is a breaking change, not a rename.
    XCTAssertEqual(CaptionsCapability.Reason.unsupportedOS.rawValue, "unsupportedOS")
    XCTAssertEqual(CaptionsCapability.Reason.intelSlowPath.rawValue, "intelSlowPath")
    XCTAssertEqual(CaptionsCapability.Reason.noAudio.rawValue, "noAudio")
    XCTAssertEqual(
      CaptionsCapability.Reason.platformNotSupported.rawValue, "platformNotSupported")
  }

  /// Windows reports a reason rather than not implementing the method. An
  /// unhandled method throws MissingPluginException in Dart, which surfaces as
  /// a crash-shaped error instead of an explanation.
  func testWindowsReasonExistsSoTheMethodIsNeverSimplyMissing() {
    let payload = CaptionsCapability.unavailable(.platformNotSupported).toFlutter()
    XCTAssertEqual(payload["available"] as? Bool, false)
    XCTAssertEqual(payload["reason"] as? String, "platformNotSupported")
  }
}
