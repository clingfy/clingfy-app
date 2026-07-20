import Foundation

/// The single serial queue every heavy offline audio pass runs on: mic echo
/// cancellation (`CleanedMicCache`) and voice cleanup (`EnhancedMicCache`).
///
/// Sharing ONE queue across all projects and all stages is what bounds peak
/// memory. Each pass decodes an entire recording into 48 kHz float arrays — an
/// hour-long mic is hundreds of MB, and a pass holds several such arrays at
/// once — so two concurrent passes could exhaust memory on a small Mac. The
/// cost is that a synchronous caller (the export preamble) can wait behind an
/// unrelated in-flight pass; that is the accepted price of the hard bound.
///
/// **Never call one queue user from inside another.** Both caches expose a
/// blocking `outcome` that does `queue.sync`, so nesting them would deadlock.
/// The chain is always sequential: echo cancellation finishes and returns,
/// then voice cleanup is invoked on its result.
enum AudioComputeQueue {
  static let shared = DispatchQueue(label: "com.clingfy.audio.compute", qos: .userInitiated)
}
