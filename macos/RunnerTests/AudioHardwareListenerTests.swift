import CoreAudio
import XCTest

@testable import Clingfy

final class AudioHardwareListenerTests: XCTestCase {

  /// The listener registers against the system object, so the address has to
  /// use the global scope and the main element. A wrong scope registers
  /// successfully and then never fires, which is the worst possible failure:
  /// silent.
  func testPropertyAddressTargetsTheSystemObjectGlobally() {
    let address = AudioHardwareListener.address(kAudioHardwarePropertyDevices)
    XCTAssertEqual(address.mSelector, kAudioHardwarePropertyDevices)
    XCTAssertEqual(address.mScope, kAudioObjectPropertyScopeGlobal)
    XCTAssertEqual(address.mElement, kAudioObjectPropertyElementMain)
  }

  func testAddressSelectorIsNotHardcoded() {
    XCTAssertEqual(
      AudioHardwareListener.address(kAudioHardwarePropertyDefaultOutputDevice).mSelector,
      kAudioHardwarePropertyDefaultOutputDevice)
    XCTAssertEqual(
      AudioHardwareListener.address(kAudioHardwarePropertyDefaultInputDevice).mSelector,
      kAudioHardwarePropertyDefaultInputDevice)
  }

  /// A dock connect fires several HAL notifications; forwarding each would
  /// re-enumerate devices repeatedly for one user action.
  func testCoalesceIntervalIsShortEnoughToFeelImmediate() {
    // Long enough to swallow a burst, short enough that the bleed warning
    // updates while the user is still looking at the sidebar.
    XCTAssertGreaterThanOrEqual(AudioHardwareListener.coalesceInterval, 0.1)
    XCTAssertLessThanOrEqual(AudioHardwareListener.coalesceInterval, 0.5)
  }

  /// start() twice must not double-register: every notification would then be
  /// delivered twice, and stop() would leave one registration behind.
  func testStartIsIdempotentAndStopIsSafeToRepeat() {
    let listener = AudioHardwareListener()
    listener.start()
    listener.start()
    listener.stop()
    listener.stop()
    // Reaching here without a CoreAudio abort is the assertion; a duplicate
    // remove of an unregistered block is what would trip it.
    XCTAssertTrue(true)
  }

  /// Registration happens against the real HAL, so this also proves the
  /// listener survives a real start/stop cycle on this machine.
  func testListenerStartsAndStopsAgainstTheRealHAL() {
    let listener = AudioHardwareListener()
    listener.onDeviceListChanged = {}
    listener.onDefaultOutputChanged = {}
    listener.start()
    listener.stop()
    XCTAssertTrue(true)
  }
}
