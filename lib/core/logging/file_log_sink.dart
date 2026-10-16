import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:clingfy/core/logging/logger_service.dart';

/// Appends [LogEvent]s as JSONL to a daily file under the app-support `Logs/`
/// directory.
///
/// Every line is written synchronously when it is logged, so nothing waits in
/// memory to be lost if the app goes down: the line that explains a crash is
/// usually the last one before it. Within the app, this sink is the only
/// writer of its file. That matters, because Dart's `FileMode.append` seeks to
/// the end once rather than appending atomically, so a second writer's lines
/// would be overwritten. macOS native code therefore writes its own
/// companion, `logs_<date>.native.jsonl`, which pruning below also manages.
/// A second running instance of the same app would share the file; the
/// re-seek before each write narrows that to a window of microseconds.
///
/// The daily file name is checked on every line, so a session that crosses
/// midnight rolls over to the new day's file. Files older than
/// [retentionDays] are pruned on initialization.
class FileLogSink {
  static final FileLogSink _instance = FileLogSink._internal();

  factory FileLogSink() {
    return _instance;
  }

  FileLogSink._internal();

  /// Default number of days of historical log files to keep on disk.
  static const int defaultRetentionDays = 30;

  static final RegExp _logFileNamePattern = RegExp(
    r'^logs_(\d{4})-(\d{2})-(\d{2})(?:\.native)?\.jsonl$',
  );

  Directory? _logsDir;
  File? _logFile;
  String? _currentDateStamp;
  DateTime Function() _clock = DateTime.now;
  int _retentionDays = defaultRetentionDays;

  /// Held open for the current day; reopened on rollover.
  RandomAccessFile? _handle;

  Future<void> init() async {
    try {
      final logsDir = await _ensureLogsDirectory();
      if (logsDir == null) {
        _logsDir = null;
        _logFile = null;
        _currentDateStamp = null;
        return;
      }
      _logsDir = logsDir;
      _rollToCurrentDate();
      debugPrint("FileLogSink initialized: ${_logFile?.path}");
      await _pruneOldLogs();
    } catch (e) {
      _logsDir = null;
      _logFile = null;
      _currentDateStamp = null;
      debugPrint("Error initializing FileLogSink: $e");
    }
  }

  /// Test-only initializer that bypasses `path_provider` and accepts an
  /// injectable clock + retention window.
  @visibleForTesting
  Future<void> initForTest({
    required Directory logsDir,
    DateTime Function()? clock,
    int retentionDays = defaultRetentionDays,
  }) async {
    _clock = clock ?? DateTime.now;
    _retentionDays = retentionDays;
    await logsDir.create(recursive: true);
    _logsDir = logsDir;
    _rollToCurrentDate();
    await _pruneOldLogs();
  }

  /// Test-only hook, kept for callers written when writes were asynchronous.
  /// Every line is on disk once [append] returns, so there is nothing to wait
  /// for.
  @visibleForTesting
  Future<void> flushForTest() async {}

  /// Test-only hook: return the file the sink would write to right now.
  @visibleForTesting
  File? get currentFile => _logFile;

  /// Test-only hook: tear down all singleton state between tests.
  @visibleForTesting
  void resetForTest() {
    _logsDir = null;
    _logFile = null;
    _currentDateStamp = null;
    _closeHandle();
    _clock = DateTime.now;
    _retentionDays = defaultRetentionDays;
  }

  void append(LogEvent event) {
    if (_logsDir == null) return;
    try {
      final line = '${jsonEncode(event.toJson())}\n';
      _rollIfDateChanged();
      final handle = _openHandle();
      if (handle == null) return;
      // Re-seek before every write: append mode positions once, at open, so a
      // second app instance writing the same file would otherwise be
      // overwritten from a stale position.
      handle.setPositionSync(handle.lengthSync());
      handle.writeStringSync(line);
    } catch (e) {
      debugPrint("Error writing log line: $e");
    }
  }

  RandomAccessFile? _openHandle() {
    final file = _logFile;
    if (file == null) return null;
    final existing = _handle;
    // A file deleted or trashed while held would swallow every later line
    // until midnight, silently. Reopen (and recreate the folder) instead.
    if (existing != null && file.existsSync()) return existing;
    _closeHandle();
    _logsDir?.createSync(recursive: true);
    return _handle = file.openSync(mode: FileMode.append);
  }

  void _closeHandle() {
    try {
      _handle?.closeSync();
    } catch (_) {}
    _handle = null;
  }

  void _rollIfDateChanged() {
    final stamp = _dateStamp(_clock());
    if (_logFile != null && stamp == _currentDateStamp) return;
    _rollToCurrentDate();
  }

  void _rollToCurrentDate() {
    final dir = _logsDir;
    if (dir == null) return;
    final stamp = _dateStamp(_clock());
    _closeHandle();
    _currentDateStamp = stamp;
    _logFile = File.fromUri(dir.uri.resolve('logs_$stamp.jsonl'));
  }

  Future<Directory?> _ensureLogsDirectory() async {
    try {
      final appSupport = await getApplicationSupportDirectory();
      final logsDir = Directory.fromUri(appSupport.uri.resolve('Logs/'));
      await logsDir.create(recursive: true);
      return logsDir;
    } catch (e) {
      debugPrint("Error preparing log directory: $e");
      return null;
    }
  }

  Future<void> _pruneOldLogs() async {
    final dir = _logsDir;
    if (dir == null || _retentionDays <= 0) return;
    try {
      final now = _clock();
      final today = DateTime(now.year, now.month, now.day);
      final cutoff = today.subtract(Duration(days: _retentionDays));

      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final match = _logFileNamePattern.firstMatch(name);
        if (match == null) continue;
        final fileDate = DateTime(
          int.parse(match.group(1)!),
          int.parse(match.group(2)!),
          int.parse(match.group(3)!),
        );
        if (fileDate.isBefore(cutoff)) {
          try {
            await entity.delete();
          } catch (e) {
            debugPrint("Error deleting old log $name: $e");
          }
        }
      }
    } catch (e) {
      debugPrint("Error pruning old logs: $e");
    }
  }

  String _dateStamp(DateTime now) {
    return "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
  }
}
