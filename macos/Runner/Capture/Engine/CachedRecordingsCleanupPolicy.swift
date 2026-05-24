import Foundation

/// Whether cached recordings may be cleared given the recorder state.
/// Pure policy (engine-domain; see windows-port-inventory §7).
enum CachedRecordingsCleanupPolicy {
  static func canClear(recorderState: RecorderState) -> Bool {
    recorderState == .idle
  }
}
