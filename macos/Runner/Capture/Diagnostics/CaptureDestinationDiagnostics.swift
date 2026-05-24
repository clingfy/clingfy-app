import Foundation

/// Resolves the URL used for capture-destination disk diagnostics.
/// Engine-domain (path resolution is FS-portable; see windows-port-inventory §7).
struct CaptureDestinationDiagnostics {
  static func url(for activeProjectRoot: URL?) -> URL {
    activeProjectRoot.map { RecordingProjectPaths.screenVideoURL(for: $0) } ?? AppPaths.tempRoot()
  }
}
