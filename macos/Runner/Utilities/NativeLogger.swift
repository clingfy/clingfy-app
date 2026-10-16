import AppKit
import FlutterMacOS
import Foundation

/// Native log lines are written to disk by NATIVE code, at the moment they are
/// logged, into a daily companion file `Logs/logs_<local date>.native.jsonl`
/// beside the Dart sink's `logs_<local date>.jsonl`, in the same line shape.
/// They are still forwarded over the channel, flagged `persisted`, for the
/// console and Sentry breadcrumbs, and Dart skips the file for those.
///
/// A separate file, not the shared one, because Dart's `FileMode.append` is
/// not `O_APPEND`: it seeks to the end once and writes at that position, so a
/// line another writer appends in between is overwritten (measured: Dart's
/// "C" landed on top of an `O_APPEND` writer's "NATIVE"). Each file has one
/// writer, so neither can clobber the other.
///
/// Why: a line used to reach disk only after a `DispatchQueue.main.async` hop,
/// a channel crossing and an async Dart write. On 2026-07-30 an AVFoundation
/// exception aborted the app on the main thread, and "Starting camera
/// segment", logged right before the crashing call, was still in an unrun
/// main-queue block. It never reached disk, and the diagnosis had to come from
/// the .ips report. A flush on terminate could not have saved it: it was not
/// in `pending`. Only a write made when the line is logged survives that.
class NativeLogger {
  static var channel: FlutterMethodChannel?

  /// Runtime env var that overrides the log threshold in any build (matches the
  /// Dart `Log.logLevelEnvVar`). e.g. `CLINGFY_LOG_LEVEL=debug`.
  static let logLevelEnvVar = "CLINGFY_LOG_LEVEL"

  /// Minimum emitted level as a rank (debug=0 < info=1 < warning=2 < error=3).
  /// Resolved once from the env var or the build default; adjustable at runtime
  /// via [setMinLevel] so the Settings "verbose logging" toggle reaches native.
  static var minLevelRank: Int = resolveDefaultRank()

  /// Lines emitted before Dart confirmed its 'log' handler is installed,
  /// oldest first. Main-queue confined (all mutation happens in main-queue
  /// closures). Bounded drop-oldest so an engine that never attaches can't
  /// grow it unbounded. Drained by [flushPending] (the
  /// `flushPendingNativeLogs` bridge call) — mirrors the Windows
  /// NativeLogPublisher pending buffer.
  private static var pending: [[String: Any]] = []
  static let maxPending = 512

  /// True once Dart's flushPendingNativeLogs handshake ran. The channel is
  /// configured in awakeFromNib — long before Dart main executes — and
  /// Flutter's ChannelBuffers holds only ONE undelivered platform→Dart
  /// message per channel, so invoking before the Dart handler exists silently
  /// drops all but the newest line. Buffer until the handshake proves the
  /// handler is there. Main-queue confined.
  private static var dartReady = false

  /// UTC ISO8601 with fractional seconds and a trailing 'Z' — the shared
  /// cross-platform timestamp base (Dart Log and Windows NativeLogPublisher
  /// emit the same shape). Cached: ISO8601DateFormatter is thread-safe and
  /// allocating one per line was pure waste.
  static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  // MARK: - Writing to disk

  /// Guards [fileWriter], [logSessionId] and [logRecordingId], which are
  /// written from the main queue (bridge calls) and read from every emitting
  /// thread.
  private static let stateLock = NSLock()
  private static var fileWriter: NativeLogFileWriter?
  /// Dart's `Log.sessionId`. Nil until the first `setNativeLogContext`.
  private static var logSessionId: String?
  private static var logRecordingId: String?

  /// Dart's fallback for a line with no session, so a line written before the
  /// handshake reads the same as Dart's own pre-session lines.
  static let unknownSessionId = "unknown-session"

  /// Builds the production writer on first use. Replaced by tests, so nothing
  /// in the suite writes into the developer's real log folder.
  ///
  /// Must not log: it runs from inside the logger. Hence the side-effect-free
  /// path, not `AppPaths.logsRoot()`, whose failure path logs.
  static var makeFileWriter: () -> NativeLogFileWriter? = {
    NativeLogFileWriter(directory: AppPaths.logsRootURLIfPresent())
  }

  /// True while [makeFileWriter] runs, so a line logged from inside it (a
  /// replaced factory that logs, say) is not written, rather than re-entering
  /// the non-recursive [stateLock] or building writers recursively.
  private static var makingWriter = false

  /// The writer, built on first use OUTSIDE [stateLock], so the factory can
  /// never deadlock the logger.
  private static func ensureWriter() -> NativeLogFileWriter? {
    stateLock.lock()
    if let existing = fileWriter {
      stateLock.unlock()
      return existing
    }
    if makingWriter {
      stateLock.unlock()
      return nil
    }
    makingWriter = true
    stateLock.unlock()

    let made = makeFileWriter()

    stateLock.lock()
    defer { stateLock.unlock() }
    makingWriter = false
    if fileWriter == nil { fileWriter = made }
    return fileWriter
  }

  /// Receives Dart's session and recording ids (`setNativeLogContext`), which
  /// every line carries. Sent before the `flushPendingNativeLogs` handshake,
  /// and again whenever a recording starts or ends.
  static func setLogContext(sessionId: String?, recordingId: String?) {
    // Ignored while a test holds the logger detached, as `configure` is: the
    // test host is the live app, and its own Dart startup sends this mid-test.
    guard !detachedForTest else { return }
    applyLogContext(sessionId: sessionId, recordingId: recordingId)
  }

  /// Test-only: set the context even while detached.
  static func setLogContextForTest(sessionId: String?, recordingId: String?) {
    applyLogContext(sessionId: sessionId, recordingId: recordingId)
  }

  private static func applyLogContext(sessionId: String?, recordingId: String?) {
    stateLock.lock()
    let firstSession = logSessionId == nil && !(sessionId?.isEmpty ?? true)
    if let sessionId, !sessionId.isEmpty { logSessionId = sessionId }
    logRecordingId = (recordingId?.isEmpty ?? true) ? nil : recordingId
    stateLock.unlock()
    _ = ensureWriter()
    // Ties the startup lines written as `unknown-session` (everything above
    // this line from the same launch) to the session they belong to.
    if firstSession {
      writeThrough(
        buildPayload(
          level: "INFO", category: "Log", message: "Native log session started",
          context: ["note": "earlier unknown-session lines in this file are this launch"]))
    }
  }

  /// Writes [payload] to disk now, on the calling thread, and returns whether
  /// it was written.
  ///
  /// Written even before Dart has sent its session, stamped with
  /// [unknownSessionId]. A startup crash is the case that matters: a line
  /// held for the handshake would die with the process, which is exactly the
  /// 2026-07-30 failure moved into the startup window. Being on disk beats
  /// carrying the right session id.
  @discardableResult
  private static func writeThrough(_ payload: [String: Any]) -> Bool {
    stateLock.lock()
    let sessionId = logSessionId ?? unknownSessionId
    let recordingId = logRecordingId
    stateLock.unlock()
    guard let writer = ensureWriter() else { return false }
    guard
      let line = NativeLogLine.encode(
        payload: payload, sessionId: sessionId, recordingId: recordingId)
    else { return false }
    // The writer has its own lock; [stateLock] is not held across the write.
    return writer.write(line: line)
  }

  /// Called when the app is about to quit (willTerminate). Main thread, and
  /// synchronous: nothing queued after this runs. Writes a final line and any
  /// lines still waiting for a handshake that never came, then closes the file.
  static func handleTerminate() {
    // Held lines first: they were logged earlier, so the file stays in order.
    pending = pending.map { line in
      guard (line["persisted"] as? Bool) != true, writeThrough(line) else { return line }
      var copy = line
      copy["persisted"] = true
      return copy
    }
    writeThrough(
      buildPayload(level: "INFO", category: "App", message: "App terminating", context: nil))
    stateLock.lock()
    fileWriter?.close()
    stateLock.unlock()
  }

  /// Installs the quit and uncaught-exception hooks. Call from
  /// `applicationDidFinishLaunching`, which runs before Dart starts Sentry, so
  /// sentry-cocoa saves this exception handler as the previous one and calls
  /// it after writing its own report. This handler calls whatever was there
  /// before it, too, so no crash reporter loses its turn.
  ///
  /// Not every exception reaches it. AppKit catches one raised during event
  /// dispatch (an action, a menu item), reports it through
  /// `-[NSApplication reportException:]` and keeps running, so no uncaught
  /// handler (Sentry's included) sees it. That is AppKit's choice to survive,
  /// left alone here; `NSApplicationCrashOnExceptions` would turn those into
  /// crashes. The 2026-07-30 abort came through the ObjC terminate path, which
  /// does call this handler.
  ///
  /// Deliberately no signal handler: sentry-cocoa owns those, and with every
  /// line written when it is logged, a signal handler would add nothing but a
  /// "died with signal N" marker that is not async-signal-safe to produce.
  static func installLifecycleHooks() {
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: nil
    ) { _ in
      handleTerminate()
    }
    previousUncaughtExceptionHandler = NSGetUncaughtExceptionHandler()
    NSSetUncaughtExceptionHandler { exception in
      NativeLogger.recordUncaughtException(exception)
      NativeLogger.previousUncaughtExceptionHandler?(exception)
    }
  }

  private static var previousUncaughtExceptionHandler:
    (@convention(c) (NSException) -> Void)?

  /// The line an uncaught exception leaves behind: its name, reason and the
  /// top of its stack, written synchronously before the process aborts.
  static func recordUncaughtException(_ exception: NSException) {
    let payload = uncaughtExceptionPayload(
      name: exception.name.rawValue, reason: exception.reason,
      symbols: exception.callStackSymbols)
    writeThrough(payload)
  }

  /// Exposed for tests: the payload [recordUncaughtException] writes.
  static func uncaughtExceptionPayload(
    name: String, reason: String?, symbols: [String]
  ) -> [String: Any] {
    let stack = symbols.prefix(25).joined(separator: "\n")
    return buildPayload(
      level: "ERROR", category: "Crash", message: "Uncaught exception: \(name)",
      context: ["exceptionName": name, "reason": reason ?? ""],
      error: reason ?? name, stack: stack)
  }

  static func configure(with channel: FlutterMethodChannel) {
    // Ignored while a buffering test holds the logger detached. The test host
    // is a live app: its Flutter startup calls this, and if it lands mid-test
    // the lines under test get delivered instead of buffered.
    guard !detachedForTest else { return }
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

  /// The Dart-ready handshake: marks direct invoking as safe (the handshake
  /// itself arrived over the channel, so Dart's 'log' handler is provably
  /// installed) and drains the pending buffer, oldest first. Dispatched to
  /// the main queue so lines queued by in-flight sends keep their order.
  /// Buffer retained while no channel is attached.
  static func flushPending() {
    DispatchQueue.main.async {
      dartReady = true
      // Lines held since startup reach disk now, when Dart's session id is
      // known (`setNativeLogContext` is sent just before this). Written even
      // if no channel is attached, so they are on disk either way.
      pending = pending.map { line in
        guard (line["persisted"] as? Bool) != true, writeThrough(line) else { return line }
        var copy = line
        copy["persisted"] = true
        return copy
      }
      guard let channel = channel, !pending.isEmpty else { return }
      let drained = pending
      pending = []
      for payload in drained {
        channel.invokeMethod("log", arguments: payload)
      }
    }
  }

  /// Test-only: number of buffered lines (read on the main queue).
  ///
  /// Process-global, so asserting on it directly is flaky: the test host is a
  /// running app whose own components keep logging from background work, and
  /// `resetForTest` detaches the channel, which is precisely the state in
  /// which `send` buffers instead of delivering. Foreign lines therefore land
  /// in `pending` between a reset and an assertion. Prefer the category
  /// filter below for anything that asserts an exact count.
  static var pendingCountForTest: Int { pending.count }

  /// Test-only: buffered lines emitted under one category.
  ///
  /// Lets a test count only its own emissions, so unrelated logging from the
  /// host app cannot change the result.
  static func pendingCountForTest(category: String) -> Int {
    pending.filter { ($0["category"] as? String) == category }.count
  }

  /// Test-only: whether the Dart-ready handshake ran.
  static var dartReadyForTest: Bool { dartReady }

  /// Test-only: holds the logger in the detached state while set, so
  /// `configure(with:)` from the host app's Flutter startup cannot attach a
  /// channel mid-test. Always cleared by `resetForTest`, so it cannot leak
  /// into a later test even if one forgets to unset it.
  private static var detachedForTest = false

  /// Test-only: keep the logger detached for the duration of a buffering test.
  ///
  /// Buffering only happens while no channel is attached. Without this the
  /// host app's startup races the test and the lines are delivered instead,
  /// which is a genuine 1-in-7 flake, not a timing artefact that a longer
  /// wait would fix.
  static func stayDetachedForTest() {
    detachedForTest = true
  }

  /// Test-only: clear channel + buffer + handshake so static state can't leak.
  static func resetForTest() {
    channel = nil
    pending = []
    dartReady = false
    detachedForTest = false
  }

  /// Test-only: route writes to [writer] with the given context, returning
  /// what was there so `restoreFileStateForTest` can put it back.
  static func installFileStateForTest(
    writer: NativeLogFileWriter?, sessionId: String?, recordingId: String?
  ) -> (NativeLogFileWriter?, String?, String?) {
    stateLock.lock()
    defer { stateLock.unlock() }
    let saved = (fileWriter, logSessionId, logRecordingId)
    fileWriter = writer
    logSessionId = sessionId
    logRecordingId = recordingId
    return saved
  }

  static func restoreFileStateForTest(_ saved: (NativeLogFileWriter?, String?, String?)) {
    stateLock.lock()
    defer { stateLock.unlock() }
    (fileWriter, logSessionId, logRecordingId) = saved
  }

  /// Test-only: buffered lines under one category, for inspecting flags.
  static func pendingLinesForTest(category: String) -> [[String: Any]] {
    pending.filter { ($0["category"] as? String) == category }
  }

  /// Test-only: buffer a line as if it were logged before the handshake.
  static func appendPendingForTest(_ payload: [String: Any]) {
    pending.append(payload)
  }

  private static func send(
    level: String, category: String, message: String, context: [String: Any]?,
    error: String?, stack: String?, file: String, line: Int
  ) {
    // Drop below-threshold logs at the source so they never cross the channel.
    guard shouldSend(level: level) else { return }

    // Stamp the timestamp at emit time (not delivery time) so buffering can't
    // skew the log order story.
    var payload = buildPayload(
      level: level, category: category, message: message, context: context,
      error: error, stack: stack, file: file, line: line)

    // On disk before anything is queued: this is the line that survives a
    // crash in the next instruction. Flagged so Dart does not write it again.
    if writeThrough(payload) {
      payload["persisted"] = true
    }

    DispatchQueue.main.async {
      guard dartReady, let channel = channel else {
        // Dart's handler isn't confirmed yet (startup) or the channel is
        // gone (teardown): hold the line for the flushPendingNativeLogs
        // drain instead of dropping it.
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

// MARK: - The JSONL line

/// One log line in the exact shape Dart's `LogEvent.toJson` writes for a
/// native event, so a file read by people, the diagnostics export or a
/// script looks the same whichever side wrote the line.
///
/// Mirrors `Log.parseNativeEvent`: `origin` is "native", an empty context is
/// omitted, and `error`/`stack` are promoted from the context when the payload
/// did not set them (the long-standing convention at ~100 call sites). Keys
/// are written in `toJson`'s order, which JSONSerialization cannot preserve,
/// so the object is assembled by hand from individually encoded values.
enum NativeLogLine {
  static func encode(payload: [String: Any], sessionId: String, recordingId: String?) -> String? {
    let context = payload["context"] as? [String: Any] ?? [:]
    func promoted(_ key: String) -> String? {
      if let top = payload[key] as? String, !top.isEmpty { return top }
      if let fromContext = context[key] as? String, !fromContext.isEmpty { return fromContext }
      return nil
    }

    var fields: [(String, Any)] = [
      ("ts", payload["ts"] as? String ?? NativeLogger.isoFormatter.string(from: Date())),
      ("level", payload["level"] as? String ?? "DEBUG"),
      ("origin", "native"),
      ("category", payload["category"] as? String ?? "Native"),
      ("message", payload["message"] as? String ?? ""),
    ]
    if let file = payload["file"] as? String { fields.append(("file", file)) }
    if let line = payload["line"] as? Int { fields.append(("line", line)) }
    fields.append(("sessionId", sessionId))
    if let recordingId { fields.append(("recordingId", recordingId)) }
    if !context.isEmpty { fields.append(("context", context)) }
    if let error = promoted("error") { fields.append(("error", error)) }
    if let stack = promoted("stack") { fields.append(("stack", stack)) }

    var parts: [String] = []
    for (key, value) in fields {
      guard let k = fragment(key), let v = fragment(sanitized(value)) else { return nil }
      parts.append("\(k):\(v)")
    }
    return "{" + parts.joined(separator: ",") + "}"
  }

  /// JSON for one value. Slashes are not escaped, matching Dart's jsonEncode.
  private static func fragment(_ value: Any) -> String? {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// A value JSONSerialization accepts. Anything it would raise on (a Date, a
  /// URL, an error, NaN) is turned into text instead: an ObjC exception here
  /// would make logging itself the crash.
  static func sanitized(_ value: Any) -> Any {
    switch value {
    case let string as String:
      return string
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
      let double = number.doubleValue
      return double.isFinite ? number : String(describing: double)
    case is NSNull:
      return NSNull()
    case let array as [Any]:
      return array.map(sanitized)
    case let dict as [String: Any]:
      return dict.mapValues(sanitized)
    case let dict as [AnyHashable: Any]:
      var out: [String: Any] = [:]
      for (key, inner) in dict { out[String(describing: key)] = sanitized(inner) }
      return out
    case let date as Date:
      return NativeLogger.isoFormatter.string(from: date)
    case let url as URL:
      return url.isFileURL ? url.path : url.absoluteString
    default:
      return String(describing: value)
    }
  }
}

// MARK: - The file

/// Appends lines to `logs_<local date>.native.jsonl` in [directory], the
/// companion of Dart's `logs_<local date>.jsonl`. Its only writer.
///
/// One `write(2)` per line on a file opened with `O_APPEND`, so a line lands
/// whole at the end of the file, and is safe in the kernel the moment the call
/// returns: a process crash cannot take it back. No fsync, which would only matter for a kernel panic or power loss.
/// The date is checked on every line, as Dart's sink does, so both roll over
/// at the same local midnight.
final class NativeLogFileWriter {
  private let directory: URL
  private let clock: () -> Date
  private let lock = NSLock()
  private var fd: Int32 = -1
  private var openStamp: String?

  /// Local calendar date, following time-zone changes like Dart's local
  /// `DateTime`. Cached: one formatter per line was pure waste.
  private static let stampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.autoupdatingCurrent
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  init(directory: URL, clock: @escaping () -> Date = Date.init) {
    self.directory = directory
    self.clock = clock
  }

  /// `logs_<yyyy-MM-dd>.native.jsonl`. Dart's pruning and the diagnostics
  /// export both recognise the `.native` companion by this shape.
  static func fileName(stamp: String) -> String { "logs_\(stamp).native.jsonl" }

  deinit { closeLocked() }

  /// The file a line written at [date] goes to.
  func fileURL(for date: Date) -> URL {
    directory.appendingPathComponent(Self.fileName(stamp: Self.stampFormatter.string(from: date)))
  }

  /// Appends [line] and a newline. Returns false when the file cannot be
  /// opened or written, so the caller lets Dart write the line instead.
  @discardableResult
  func write(line: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let stamp = Self.stampFormatter.string(from: clock())
    // A file deleted or trashed while open would swallow every later line
    // until midnight, silently. One fstat per line notices and reopens.
    if fd >= 0 {
      var info = stat()
      if fstat(fd, &info) != 0 || info.st_nlink == 0 { closeLocked() }
    }
    if fd < 0 || stamp != openStamp {
      closeLocked()
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let path = directory.appendingPathComponent(Self.fileName(stamp: stamp)).path
      fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
      openStamp = fd >= 0 ? stamp : nil
    }
    guard fd >= 0 else { return false }
    let bytes = Array((line + "\n").utf8)
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBufferPointer { buffer in
        Darwin.write(fd, buffer.baseAddress! + offset, bytes.count - offset)
      }
      if written < 0 {
        if errno == EINTR { continue }
        // Part of the line may already be in the file. End it, so the next
        // line starts on its own line instead of being glued to a fragment.
        if offset > 0 { _ = "\n".withCString { Darwin.write(fd, $0, 1) } }
        return false
      }
      offset += written
    }
    return true
  }

  func close() {
    lock.lock()
    defer { lock.unlock() }
    closeLocked()
  }

  private func closeLocked() {
    if fd >= 0 { Darwin.close(fd) }
    fd = -1
    openStamp = nil
  }
}
