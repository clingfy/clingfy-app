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
    _ category: String, _ message: String, context: [String: Any]? = nil, file: String = #file,
    line: Int = #line
  ) {
    send(
      level: "DEBUG", category: category, message: message, context: context, file: file, line: line
    )
  }

  static func i(
    _ category: String, _ message: String, context: [String: Any]? = nil, file: String = #file,
    line: Int = #line
  ) {
    send(
      level: "INFO", category: category, message: message, context: context, file: file, line: line)
  }

  static func w(
    _ category: String, _ message: String, context: [String: Any]? = nil, file: String = #file,
    line: Int = #line
  ) {
    send(
      level: "WARNING", category: category, message: message, context: context, file: file,
      line: line)
  }

  static func e(
    _ category: String, _ message: String, context: [String: Any]? = nil, file: String = #file,
    line: Int = #line
  ) {
    send(
      level: "ERROR", category: category, message: message, context: context, file: file, line: line
    )
  }

  private static func send(
    level: String, category: String, message: String, context: [String: Any]?, file: String,
    line: Int
  ) {
    // Drop below-threshold logs at the source so they never cross the channel.
    guard shouldSend(level: level) else { return }

    let filename = (file as NSString).lastPathComponent

    let payload: [String: Any] = [
      "ts": ISO8601DateFormatter().string(from: Date()),
      "level": level,
      "category": category,
      "message": message,
      "file": filename,
      "line": line,
      "context": context ?? [:],
    ]

    // Always NSLog for Xcode visibility
    // NSLog("[\(category)] [\(level)] \(message)")

    DispatchQueue.main.async {
      channel?.invokeMethod("log", arguments: payload)
    }
  }
}
