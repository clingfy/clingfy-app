import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:clingfy/core/logging/file_log_sink.dart';

enum LogLevel { debug, info, warning, error }

/// Parses a level name (case-insensitive; accepts a few aliases and the
/// UPPERCASE names native emits). Returns null for an unknown/empty value.
LogLevel? logLevelFromName(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'debug':
    case 'd':
    case 'verbose':
    case 'trace':
      return LogLevel.debug;
    case 'info':
    case 'i':
      return LogLevel.info;
    case 'warning':
    case 'warn':
    case 'w':
      return LogLevel.warning;
    case 'error':
    case 'e':
      return LogLevel.error;
  }
  return null;
}

class LogEvent {
  final String ts; // ISO8601 UTC with a trailing "Z" — same base on all origins
  final String level; // "DEBUG", "INFO", "WARNING", "ERROR"
  final String origin; // "flutter" | "native"
  final String category;
  final String message;
  final String? file;
  final int? line;
  final String sessionId;
  final String? recordingId;
  final Map<String, dynamic>? context;
  final String? error;
  final String? stack;

  LogEvent({
    required this.ts,
    required this.level,
    required this.origin,
    required this.category,
    required this.message,
    required this.sessionId,
    this.file,
    this.line,
    this.recordingId,
    this.context,
    this.error,
    this.stack,
  });

  /// Null/absent fields are omitted (not serialized as JSON null) so a line
  /// carries only what its producer actually knew — one compact shape across
  /// flutter/macOS/Windows origins instead of per-origin null padding.
  Map<String, dynamic> toJson() {
    return {
      'ts': ts,
      'level': level,
      'origin': origin,
      'category': category,
      'message': message,
      if (file != null) 'file': file,
      if (line != null) 'line': line,
      'sessionId': sessionId,
      if (recordingId != null) 'recordingId': recordingId,
      if (context != null && context!.isNotEmpty) 'context': context,
      if (error != null) 'error': error,
      if (stack != null) 'stack': stack,
    };
  }

  @override
  String toString() {
    final sb = StringBuffer();
    sb.write('[$ts] [$level] [$origin] [$category] ');
    if (file != null) {
      sb.write('($file');
      if (line != null) sb.write(':$line');
      sb.write(') ');
    }
    sb.write(message);
    if (error != null) sb.write('\nError: $error');
    if (stack != null) sb.write('\nStack: $stack');
    return sb.toString();
  }
}

/// Interface for external/remote log sinks (e.g. Sentry, Crashlytics)
abstract class RemoteLogSink {
  void send(LogEvent event);
}

class Log {
  static String? _sessionId;
  static String? recordingId;
  static RemoteLogSink? _remoteSink;
  static bool _initialized = false;

  /// Events emitted before [init] (bootstrap: error handlers, window setup,
  /// Sentry init). Bounded drop-oldest buffer, replayed into the sinks by
  /// [init] so the earliest — often most valuable — lines aren't lost.
  static const int _preInitBufferCapacity = 512;
  static final List<LogEvent> _preInitBuffer = <LogEvent>[];

  /// UTC ISO8601 with a trailing 'Z' — the single timestamp base shared with
  /// both native producers (macOS NativeLogger / Windows NativeLogPublisher).
  static String _nowUtcIso() => DateTime.now().toUtc().toIso8601String();
  static final bool _printToConsole =
      kDebugMode &&
      !Platform.environment.containsKey('FLUTTER_TEST') &&
      !Platform.environment.containsKey('DART_TEST');

  /// Runtime env var that overrides the log threshold in any build (including
  /// release) — e.g. `CLINGFY_LOG_LEVEL=debug`. Read on both the Dart and the
  /// native side so a tester can capture verbose logs without a custom build.
  static const String logLevelEnvVar = 'CLINGFY_LOG_LEVEL';

  /// The minimum level that is emitted; anything below it is dropped on both the
  /// Dart producer side and the native-event ingest side. Resolved at [init]
  /// from the env var or the build default, and adjustable at runtime via
  /// [setMinLevel] / [setVerbose] (the Settings "verbose logging" toggle).
  static LogLevel _minLevel = _buildDefaultIsVerbose
      ? LogLevel.debug
      : LogLevel.info;

  // Debug runs log verbosely; release AND profile builds default to info — the
  // native side keys its default off `#if DEBUG` (false for both release and
  // profile), so this must match or the two sides diverge in profile builds.
  static bool get _buildDefaultIsVerbose => kDebugMode;

  static LogLevel get minLevel => _minLevel;

  /// Pure precedence used for the default level: an explicit env override wins,
  /// else the build default (verbose build → debug, otherwise → info). Exposed
  /// for tests so the non-debug default is verifiable from a debug test run.
  @visibleForTesting
  static LogLevel resolveLevel({
    required String? envValue,
    required bool buildDefaultIsVerbose,
  }) {
    return logLevelFromName(envValue) ??
        (buildDefaultIsVerbose ? LogLevel.debug : LogLevel.info);
  }

  static LogLevel _resolveDefaultLevel() => resolveLevel(
    envValue: Platform.environment[logLevelEnvVar],
    buildDefaultIsVerbose: _buildDefaultIsVerbose,
  );

  static Future<void> init({RemoteLogSink? remoteSink}) async {
    if (_initialized) return;
    _sessionId = _nowUtcIso();
    _remoteSink = remoteSink;
    _minLevel = _resolveDefaultLevel();

    // Initialize file sink
    await FileLogSink().init();

    _initialized = true;

    // Replay anything logged before init first — buffered events carry older
    // timestamps, so draining before the init line keeps the file sorted.
    // Early bootstrap failures land in the file/remote sinks instead of
    // vanishing (they were console-only).
    _drainPreInitBuffer();

    i(
      'Log',
      'Logger initialized. SessionId: $_sessionId, minLevel: ${_minLevel.name}',
    );
  }

  static void _drainPreInitBuffer() {
    if (_preInitBuffer.isEmpty) return;
    final buffered = List<LogEvent>.of(_preInitBuffer);
    _preInitBuffer.clear();
    for (final event in buffered) {
      // Already echoed to the console when first emitted.
      _processEvent(event, echoConsole: false);
    }
  }

  /// Sets the minimum emitted level at runtime (the native side is updated
  /// separately, by the caller, so both stay in sync).
  static void setMinLevel(LogLevel level) {
    if (_minLevel == level) return;
    final previous = _minLevel;
    _minLevel = level;
    // Emit at info so the transition is visible at the new (or old) threshold.
    i('Log', 'Log level changed: ${previous.name} -> ${level.name}');
  }

  /// Convenience for the "verbose logging" toggle: on → debug; off → the env /
  /// build default. Returns the resolved level so the caller can mirror it to
  /// native.
  static LogLevel setVerbose(bool enabled) {
    final level = enabled ? LogLevel.debug : _resolveDefaultLevel();
    setMinLevel(level);
    return level;
  }

  static String get sessionId => _sessionId ?? 'unknown-session';

  // --- Public API ---

  static void d(
    String category,
    String message, [
    dynamic error,
    StackTrace? stack,
    Map<String, dynamic>? context,
  ]) {
    _emit(LogLevel.debug, category, message, error, stack, context);
  }

  static void i(
    String category,
    String message, [
    dynamic error,
    StackTrace? stack,
    Map<String, dynamic>? context,
  ]) {
    _emit(LogLevel.info, category, message, error, stack, context);
  }

  static void w(
    String category,
    String message, [
    dynamic error,
    StackTrace? stack,
    Map<String, dynamic>? context,
  ]) {
    _emit(LogLevel.warning, category, message, error, stack, context);
  }

  static void e(
    String category,
    String message, [
    dynamic error,
    StackTrace? stack,
    Map<String, dynamic>? context,
  ]) {
    _emit(LogLevel.error, category, message, error, stack, context);
  }

  /// Entry point for logs coming from Native side
  static void nativeEvent(Map<String, dynamic> payload) {
    try {
      final event = parseNativeEvent(payload);
      // Native gates at its own threshold before sending, but apply the Dart
      // threshold too (defense in depth, and they can briefly differ around a
      // runtime level change). An unparseable level is treated as debug — the
      // lowest rank — matching the native gate's fallback so both sides agree.
      final level = logLevelFromName(event.level) ?? LogLevel.debug;
      if (level.index < _minLevel.index) return;
      _dispatch(event);
    } catch (e) {
      if (kDebugMode) {
        debugPrint("Error parsing native log event: $e");
      }
    }
  }

  /// Builds a [LogEvent] from a native `log` method-channel payload.
  ///
  /// Phase 10.4: also threads the optional `error`, `stack`, and `context`
  /// keys onto the event — previously `error`/`stack` were dropped, which
  /// kept the Sentry sink's exception-promotion path (event.error /
  /// event.stack) from ever firing for native ERROR logs.
  @visibleForTesting
  static LogEvent parseNativeEvent(Map<String, dynamic> payload) {
    final ts = payload['ts'] as String? ?? _nowUtcIso();
    final levelRaw = payload['level'] as String? ?? 'DEBUG';
    final category = payload['category'] as String? ?? 'Native';
    final message = payload['message'] as String? ?? '';
    final file = payload['file'] as String?;
    final line = payload['line'] as int?;
    final ctx = payload['context'] as Map<dynamic, dynamic>?;
    final error = payload['error'];
    final stack = payload['stack'];

    // Coerce context keys to String
    final Map<String, dynamic>? contextMap = ctx?.map(
      (key, value) => MapEntry(key.toString(), value),
    );

    // The long-standing native convention puts the failure text in
    // context['error'] / context['stack'] (~100 macOS call sites). Promote
    // those to the top-level fields when the payload didn't set them, so the
    // Sentry sink's native-ERROR exception path sees the real error text.
    // The keys stay in context too — promotion adds, it never moves.
    String? promoted(String key, dynamic topLevel) {
      if (topLevel is String && topLevel.isNotEmpty) return topLevel;
      final fromContext = contextMap?[key];
      return fromContext is String && fromContext.isNotEmpty
          ? fromContext
          : null;
    }

    return LogEvent(
      ts: ts,
      level: levelRaw,
      origin: 'native',
      category: category,
      message: message,
      sessionId: sessionId,
      recordingId: recordingId,
      file: file,
      line: line,
      context: contextMap,
      error: promoted('error', error),
      stack: promoted('stack', stack),
    );
  }

  // --- Internal Pipeline ---

  static void _emit(
    LogLevel level,
    String category,
    String message, [
    dynamic error,
    StackTrace? stack,
    Map<String, dynamic>? context,
  ]) {
    if (level.index < _minLevel.index) return;

    final event = LogEvent(
      ts: _nowUtcIso(),
      level: level.name.toUpperCase(),
      origin: 'flutter',
      category: category,
      message: message,
      sessionId: sessionId,
      recordingId: recordingId,
      context: context,
      error: error?.toString(),
      stack: stack?.toString(),
    );

    _dispatch(event);
  }

  /// Routes an event to the sinks, or to the bounded pre-init buffer when
  /// [init] hasn't run yet (console echo still happens immediately so debug
  /// runs see bootstrap lines live).
  static void _dispatch(LogEvent event) {
    if (!_initialized) {
      if (_printToConsole) debugPrint(event.toString());
      if (_preInitBuffer.length >= _preInitBufferCapacity) {
        _preInitBuffer.removeAt(0);
      }
      _preInitBuffer.add(event);
      return;
    }

    _processEvent(event);
  }

  /// Test-only: number of events waiting for [init].
  @visibleForTesting
  static int get preInitBufferLengthForTest => _preInitBuffer.length;

  /// Test-only: mark the logger initialized without running [init], so tests
  /// that drive the sinks directly bypass the pre-init buffer.
  @visibleForTesting
  static void markInitializedForTest() {
    _initialized = true;
  }

  /// Test-only: run [init]'s buffer replay without the real [init] (which
  /// would re-target the file sink through path_provider).
  @visibleForTesting
  static void drainPreInitBufferForTest() {
    _initialized = true;
    _drainPreInitBuffer();
  }

  /// Test-only: tear down all static state between tests.
  @visibleForTesting
  static void resetForTest() {
    _initialized = false;
    _sessionId = null;
    _remoteSink = null;
    recordingId = null;
    _preInitBuffer.clear();
    _minLevel = _resolveDefaultLevel();
  }

  static void _processEvent(LogEvent event, {bool echoConsole = true}) {
    // 1. Console
    if (echoConsole && _printToConsole) {
      // Use debugPrint to avoid truncating lengthy logs on Android
      debugPrint(event.toString());
    }

    // 2. File Sink
    FileLogSink().append(event);

    // 3. Remote Sink
    _remoteSink?.send(event);
  }
}
