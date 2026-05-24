import Foundation
import FlutterMacOS

/// Abstract control surface for a capture session. Conformers are platform-specific
/// (engine-domain contract; see windows-port-inventory §7).
protocol CaptureControlling: AnyObject {
  var isRecording: Bool { get }
  func start(
    includeAudio: Bool,
    to url: URL,
    didStart: @escaping (URL) -> Void,
    didFail: @escaping (Error) -> Void)
  // func stop(didFinish: @escaping (Result<URL, Error>) -> Void)
  func stop(didFinish: @escaping (Result<URL, FlutterError>) -> Void)
}
