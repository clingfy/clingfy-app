import FlutterMacOS
import Foundation

class NativeLogger {
  static var channel: FlutterMethodChannel?

  /// Runtime env var that overrides the log threshold in any build (matches the
  /// Dart `Log.logLevelEnvVar`). e.g. `CLINGFY_LOG_LEVEL=debug`.
  static let logLevelEnvVar = "CLINGFY_LOG_LEVEL"

  /// Minimum emitted level as a rank (debug=0 < info=1 < warning=2 < error=3).
  /// Resolved once from the env var or the build default; adjustable at runtime
  /// via [setMinLevel] so the Settings "verbose logging" toggle reaches native.
  static var minLevelRank: Int = resolveDefaultRank()

  /// Lines emitted while no channel was attached, oldest first. Main-queue
  /// confined (all mutation happens in main-queue closures). Bounded
  /// drop-oldest so an engine that never attaches can't grow it unbounded.
  /// Drained by [flushPending] when Dart signals its 'log' handler is
  /// installed (the `flushPendingNativeLogs` bridge call) — mirrors the
  /// Windows NativeLogPublisher pending buffer.
  private static var pending: [[String: Any]] = []
  static let maxPending = 512

  /// UTC ISO8601 with fractional seconds and a trailing 'Z' — the shared
  /// cross-platform timestamp base (Dart Log and Windows NativeLogPublisher
  /// emit the same shape). Cached: ISO8601DateFormatter is thread-safe and
  /// allocating one per line was pure waste.
  static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  static func configure(with channel: FlutterMethodChannel) {
    self.channel = channel
  }

  /// Env override > build default (DEBUG build → debug, release → info).
  private static func resolveDefaultRank() -> Int {
    if let raw = ProcessInfo.processInfo.environment[logLevelEnvVar],
      let rank = rank(forLevelName: raw)
    {
      return rank
    }
    #if DEBUG
      return 0  // debug
    #else
      return 1  // info
    #endif
  }

  /// Sets the minimum emitted level at runtime from a level name (debug/info/
  /// warning/error). Unknown names are ignored.
  static func setMinLevel(_ name: String) {
    guard let rank = rank(forLevelName: name) else { return }
    minLevelRank = rank
  }

  /// Rank for a level name (the values Dart sends down for the toggle), or nil.
  private static func rank(forLevelName name: String) -> Int? {
    switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "debug", "d", "verbose", "trace": return 0
    case "info", "i": return 1
    case "warning", "warn", "w": return 2
    case "error", "e": return 3
    default: return nil
    }
  }

  /// Rank for an emitted level constant ("DEBUG"/"INFO"/"WARNING"/"ERROR").
  private static func rank(forEmittedLevel level: String) -> Int {
    switch level {
    case "INFO": return 1
    case "WARNING": return 2
    case "ERROR": return 3
    default: return 0  // DEBUG / unknown
    }
  }

  /// Whether an emitted level passes the current threshold. Exposed for tests.
  static func shouldSend(level: String) -> Bool {
    return rank(forEmittedLevel: level) >= minLevelRank
  }

  static func d(
    _ category: String, _ message: String, context: [String: Any]? = nil,
    error: String? = nil, stack: String? = nil,
    file: String = #file, line: Int = #line
  ) {
    send(
      level: "DEBUG", category: category, message: message, context: context,
      error: error, stack: stack, file: file, line: line)
  }

  static func i(
    _ category: String, _ message: String, context: [String: Any]? = nil,
    error: String? = nil, stack: String? = nil,
    file: String = #file, line: Int = #line
  ) {
    send(
      level: "INFO", category: category, message: message, context: context,
      error: error, stack: stack, file: file, line: line)
  }

  static func w(
    _ category: String, _ message: String, context: [String: Any]? = nil,
    error: String? = nil, stack: String? = nil,
    file: String = #file, line: Int = #line
  ) {
    send(
      level: "WARNING", category: category, message: message, context: context,
      error: error, stack: stack, file: file, line: line)
  }

  static func e(
    _ category: String, _ message: String, context: [String: Any]? = nil,
    error: String? = nil, stack: String? = nil,
    file: String = #file, line: Int = #line
  ) {
    send(
      level: "ERROR", category: category, message: message, context: context,
      error: error, stack: stack, file: file, line: line)
  }

  /// Pure payload builder — the shape contract with Dart's `Log.nativeEvent`
  /// parser (keys: ts/level/category/message/file/line/context, plus
  /// error/stack only when set). Exposed for tests; keep in sync with the
  /// Windows `NativeLogPublisher::BuildPayload`.
  static func buildPayload(
    level: String, category: String, message: String, context: [String: Any]?,
    error: String? = nil, stack: String? = nil,
    file: String = #file, line: Int = #line
  ) -> [String: Any] {
    let filename = (file as NSString).lastPathComponent
    var payload: [String: Any] = [
      "ts": isoFormatter.string(from: Date()),
      "level": level,
      "category": category,
      "message": message,
      "file": filename,
      "line": line,
      "context": context ?? [:],
    ]
    if let error = error, !error.isEmpty {
      payload["error"] = error
    }
    if let stack = stack, !stack.isEmpty {
      payload["stack"] = stack
    }
    return payload
  }

  /// Drains the pending (pre-channel) buffer through the channel, oldest
  /// first. Dispatched to the main queue so lines queued by in-flight sends
  /// keep their order. No-op (buffer retained) while no channel is attached.
  static func flushPending() {
    DispatchQueue.main.async {
      guard let channel = channel, !pending.isEmpty else { return }
      let drained = pending
      pending = []
      for payload in drained {
        channel.invokeMethod("log", arguments: payload)
      }
    }
  }

  /// Test-only: number of buffered lines (read on the main queue).
  static var pendingCountForTest: Int { pending.count }

  /// Test-only: clear channel + buffer so static state can't leak.
  static func resetForTest() {
    channel = nil
    pending = []
  }

  private static func send(
    level: String, category: String, message: String, context: [String: Any]?,
    error: String?, stack: String?, file: String, line: Int
  ) {
    // Drop below-threshold logs at the source so they never cross the channel.
    guard shouldSend(level: level) else { return }

    // Stamp the timestamp at emit time (not delivery time) so buffering can't
    // skew the log order story.
    let payload = buildPayload(
      level: level, category: category, message: message, context: context,
      error: error, stack: stack, file: file, line: line)

    DispatchQueue.main.async {
      guard let channel = channel else {
        // No listener yet (startup) or torn down: hold the line for the
        // flushPendingNativeLogs drain instead of dropping it.
        if pending.count >= maxPending {
          pending.removeFirst()
        }
        pending.append(payload)
        return
      }
      channel.invokeMethod("log", arguments: payload)
    }
  }
}
