import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:clingfy/app/infrastructure/logging/logger_service.dart';

/// Appends [LogEvent]s as JSONL to a daily file under the app-support `Logs/`
/// directory.
///
/// The previous implementation captured the file name once at app launch, so a
/// session that crossed midnight kept writing to the previous day's file. This
/// sink instead recomputes the daily file name on every flush and rolls over
/// when the local calendar date changes. It also prunes files older than
/// [retentionDays] on initialization.
class FileLogSink {
  static final FileLogSink _instance = FileLogSink._internal();

  factory FileLogSink() {
    return _instance;
  }

  FileLogSink._internal();

  /// Default number of days of historical log files to keep on disk.
  static const int defaultRetentionDays = 30;

  static final RegExp _logFileNamePattern = RegExp(
    r'^logs_(\d{4})-(\d{2})-(\d{2})\.jsonl$',
  );

  Directory? _logsDir;
  File? _logFile;
  String? _currentDateStamp;
  DateTime Function() _clock = DateTime.now;
  int _retentionDays = defaultRetentionDays;

  final _writeQueue = <String>[];
  bool _isWriting = false;

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

  /// Test-only hook: drain any in-flight writes before assertions.
  @visibleForTesting
  Future<void> flushForTest() async {
    while (_isWriting || _writeQueue.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  /// Test-only hook: return the file the sink would write to right now.
  @visibleForTesting
  File? get currentFile => _logFile;

  /// Test-only hook: tear down all singleton state between tests.
  @visibleForTesting
  void resetForTest() {
    _logsDir = null;
    _logFile = null;
    _currentDateStamp = null;
    _writeQueue.clear();
    _isWriting = false;
    _clock = DateTime.now;
    _retentionDays = defaultRetentionDays;
  }

  void append(LogEvent event) {
    if (_logsDir == null) return;
    try {
      final jsonStr = jsonEncode(event.toJson());
      _writeQueue.add(jsonStr);
      _processQueue();
    } catch (e) {
      debugPrint("Error encoding log event: $e");
    }
  }

  Future<void> _processQueue() async {
    if (_isWriting || _writeQueue.isEmpty || _logsDir == null) return;
    _isWriting = true;

    try {
      _rollIfDateChanged();
      final file = _logFile;
      if (file == null) return;

      final batch = List<String>.from(_writeQueue);
      _writeQueue.clear();
      final content = '${batch.join('\n')}\n';
      await file.writeAsString(content, mode: FileMode.append);
    } catch (e) {
      debugPrint("Error writing logs to file: $e");
      // If write fails, maybe put back in queue? Avoiding for now to prevent loops.
    } finally {
      _isWriting = false;
      if (_writeQueue.isNotEmpty) {
        _processQueue();
      }
    }
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
