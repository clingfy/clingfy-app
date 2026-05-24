import AVFoundation
import CoreGraphics
import XCTest

@testable import Clingfy

/// Slice 7 / PR 25 guard: every `CaptureStartConfig` field the facade used
/// to assemble inline now flows through `CaptureStartConfigBuilder.build`,
/// and the audio-device sentinel filter
/// (`disableMicrophone | nil | "" | "__none__"` → no device) lives in
/// `resolveAudioDevice` on the same builder. Pure / deterministic.
@MainActor
final class CaptureStartConfigBuilderTests: XCTestCase {

  // MARK: - resolveAudioDevice sentinel filter

  func testResolveAudioDeviceReturnsNilWhenMicrophoneIsDisabled() {
    let sut = CaptureStartConfigBuilder()
    XCTAssertNil(
      sut.resolveAudioDevice(audioDeviceID: "some-real-uid", disableMicrophone: true),
      "disableMicrophone=true must short-circuit before the AVCaptureDevice lookup")
  }

  func testResolveAudioDeviceReturnsNilForSentinelIDs() {
    let sut = CaptureStartConfigBuilder()
    // nil / "" / "__none__" all map to "no real device selected".
    for sentinel in [nil, "", "__none__"] as [String?] {
      XCTAssertNil(
        sut.resolveAudioDevice(audioDeviceID: sentinel, disableMicrophone: false),
        "sentinel audioDeviceID=\(sentinel ?? "nil") must yield nil")
    }
  }

  func testResolveAudioDeviceReturnsNilForUnknownUIDWithoutCrashing() {
    let sut = CaptureStartConfigBuilder()
    // AVCaptureDevice(uniqueID:) returns nil for unknown IDs — the
    // builder must surface that nil cleanly instead of crashing.
    XCTAssertNil(
      sut.resolveAudioDevice(
        audioDeviceID: "this-uid-does-not-exist-on-any-system",
        disableMicrophone: false))
  }

  // MARK: - build wires every input into the right CaptureStartConfig slot

  private func makeAnyTarget() -> CaptureTarget {
    CaptureTarget(mode: .explicitID, displayID: 42, cropRect: nil, windowID: nil)
  }

  func testBuildPreservesTargetFrameRateAndQuality() {
    let sut = CaptureStartConfigBuilder()
    let target = makeAnyTarget()
    let cfg = sut.build(
      .init(
        target: target,
        frameRate: 60,
        outputURL: { URL(fileURLWithPath: "/tmp/out.mov") },
        effectiveOverlayID: nil,
        systemAudioEnabled: false,
        audioDeviceID: nil,
        disableMicrophone: true,
        excludeRecorderApp: false,
        shouldRecordSeparateCameraAsset: false,
        excludeMicFromSystemAudio: true))

    XCTAssertEqual(cfg.target, target)
    XCTAssertEqual(cfg.frameRate, 60)
    XCTAssertEqual(cfg.quality, .native)
  }

  func testBuildSystemAudioEnabledFlowsThrough() {
    let sut = CaptureStartConfigBuilder()
    let cfgOn = sut.build(makeInput(systemAudioEnabled: true))
    let cfgOff = sut.build(makeInput(systemAudioEnabled: false))
    XCTAssertTrue(cfgOn.includeSystemAudio)
    XCTAssertFalse(cfgOff.includeSystemAudio)
  }

  func testBuildExcludeRecorderAppFlowsThrough() {
    let sut = CaptureStartConfigBuilder()
    XCTAssertTrue(sut.build(makeInput(excludeRecorderApp: true)).excludeRecorderApp)
    XCTAssertFalse(sut.build(makeInput(excludeRecorderApp: false)).excludeRecorderApp)
  }

  func testBuildExcludeMicFromSystemAudioFlowsThrough() {
    let sut = CaptureStartConfigBuilder()
    XCTAssertTrue(sut.build(makeInput(excludeMicFromSystemAudio: true)).excludeMicFromSystemAudio)
    XCTAssertFalse(sut.build(makeInput(excludeMicFromSystemAudio: false)).excludeMicFromSystemAudio)
  }

  func testBuildEchoesEffectiveOverlayIDIntoCameraOverlayWindowID() {
    let sut = CaptureStartConfigBuilder()
    let withOverlay = sut.build(makeInput(effectiveOverlayID: 12345))
    let withoutOverlay = sut.build(makeInput(effectiveOverlayID: nil))
    XCTAssertEqual(withOverlay.cameraOverlayWindowID, 12345)
    XCTAssertNil(withoutOverlay.cameraOverlayWindowID)
  }

  func testBuildExcludeCameraOverlayWindowFollowsShouldRecordSeparateCameraAsset() {
    let sut = CaptureStartConfigBuilder()
    XCTAssertTrue(
      sut.build(makeInput(shouldRecordSeparateCameraAsset: true)).excludeCameraOverlayWindow)
    XCTAssertFalse(
      sut.build(makeInput(shouldRecordSeparateCameraAsset: false)).excludeCameraOverlayWindow)
  }

  // MARK: - build keeps the outputURL closure lazy

  func testBuildDoesNotInvokeOutputURLClosure() {
    let sut = CaptureStartConfigBuilder()
    var calls = 0
    _ = sut.build(
      .init(
        target: makeAnyTarget(),
        frameRate: 30,
        outputURL: {
          calls += 1
          return URL(fileURLWithPath: "/tmp/out.mov")
        },
        effectiveOverlayID: nil,
        systemAudioEnabled: false,
        audioDeviceID: nil,
        disableMicrophone: true,
        excludeRecorderApp: false,
        shouldRecordSeparateCameraAsset: false,
        excludeMicFromSystemAudio: false))

    XCTAssertEqual(
      calls, 0,
      "build must not materialise the output URL — backends call it lazily when they need it")
  }

  func testBuildOutputURLClosureRoundTripsToCaller() throws {
    let sut = CaptureStartConfigBuilder()
    let expected = URL(fileURLWithPath: "/tmp/expected.mov")
    let cfg = sut.build(
      .init(
        target: makeAnyTarget(),
        frameRate: 30,
        outputURL: { expected },
        effectiveOverlayID: nil,
        systemAudioEnabled: false,
        audioDeviceID: nil,
        disableMicrophone: true,
        excludeRecorderApp: false,
        shouldRecordSeparateCameraAsset: false,
        excludeMicFromSystemAudio: false))

    XCTAssertEqual(try cfg.makeOutputURL(), expected)
  }

  // MARK: - Audio-device gate: disableMicrophone overrides any UID

  func testBuildIncludeAudioDeviceIsNilWhenMicDisabledEvenIfUIDProvided() {
    let sut = CaptureStartConfigBuilder()
    let cfg = sut.build(
      .init(
        target: makeAnyTarget(),
        frameRate: 30,
        outputURL: { URL(fileURLWithPath: "/tmp/out.mov") },
        effectiveOverlayID: nil,
        systemAudioEnabled: false,
        audioDeviceID: "some-real-uid",
        disableMicrophone: true,
        excludeRecorderApp: false,
        shouldRecordSeparateCameraAsset: false,
        excludeMicFromSystemAudio: false))

    XCTAssertNil(cfg.includeAudioDevice)
  }

  func testBuildIncludeAudioDeviceIsNilForEachSentinelID() {
    let sut = CaptureStartConfigBuilder()
    for sentinel in [nil, "", "__none__"] as [String?] {
      let cfg = sut.build(
        .init(
          target: makeAnyTarget(),
          frameRate: 30,
          outputURL: { URL(fileURLWithPath: "/tmp/out.mov") },
          effectiveOverlayID: nil,
          systemAudioEnabled: false,
          audioDeviceID: sentinel,
          disableMicrophone: false,
          excludeRecorderApp: false,
          shouldRecordSeparateCameraAsset: false,
          excludeMicFromSystemAudio: false))
      XCTAssertNil(
        cfg.includeAudioDevice,
        "sentinel audioDeviceID=\(sentinel ?? "nil") must produce no audio device")
    }
  }

  // MARK: - Helper

  private func makeInput(
    target: CaptureTarget? = nil,
    frameRate: Int = 30,
    effectiveOverlayID: CGWindowID? = nil,
    systemAudioEnabled: Bool = false,
    audioDeviceID: String? = nil,
    disableMicrophone: Bool = true,
    excludeRecorderApp: Bool = false,
    shouldRecordSeparateCameraAsset: Bool = false,
    excludeMicFromSystemAudio: Bool = true
  ) -> CaptureStartConfigBuilder.Input {
    .init(
      target: target ?? makeAnyTarget(),
      frameRate: frameRate,
      outputURL: { URL(fileURLWithPath: "/tmp/out.mov") },
      effectiveOverlayID: effectiveOverlayID,
      systemAudioEnabled: systemAudioEnabled,
      audioDeviceID: audioDeviceID,
      disableMicrophone: disableMicrophone,
      excludeRecorderApp: excludeRecorderApp,
      shouldRecordSeparateCameraAsset: shouldRecordSeparateCameraAsset,
      excludeMicFromSystemAudio: excludeMicFromSystemAudio)
  }
}
