import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:clingfy/app/infrastructure/logging/file_log_sink.dart';

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
  final String ts; // ISO8601
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

  Map<String, dynamic> toJson() {
    return {
      'ts': ts,
      'level': level,
      'origin': origin,
      'category': category,
      'message': message,
      'file': file,
      'line': line,
      'sessionId': sessionId,
      'recordingId': recordingId,
      'context': context,
      'error': error,
      'stack': stack,
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
    _sessionId = DateTime.now().toIso8601String();
    _remoteSink = remoteSink;
    _minLevel = _resolveDefaultLevel();

    // Initialize file sink
    await FileLogSink().init();

    _initialized = true;
    i(
      'Log',
      'Logger initialized. SessionId: $_sessionId, minLevel: ${_minLevel.name}',
    );
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
      _processEvent(event);
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
    final ts = payload['ts'] as String? ?? DateTime.now().toIso8601String();
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
      error: error is String && error.isNotEmpty ? error : null,
      stack: stack is String && stack.isNotEmpty ? stack : null,
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
      ts: DateTime.now().toIso8601String(),
      level: level.toString().split('.').last.toUpperCase(),
      origin: 'flutter',
      category: category,
      message: message,
      sessionId: sessionId,
      recordingId: recordingId,
      context: context,
      error: error?.toString(),
      stack: stack?.toString(),
    );

    _processEvent(event);
  }

  static void _processEvent(LogEvent event) {
    // 1. Console
    if (_printToConsole) {
      // Use debugPrint to avoid truncating lengthy logs on Android
      debugPrint(event.toString());
    }

    // 2. File Sink
    FileLogSink().append(event);

    // 3. Remote Sink
    _remoteSink?.send(event);
  }
}
