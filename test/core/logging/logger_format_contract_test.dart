import 'dart:convert';
import 'dart:io';

import 'package:clingfy/core/logging/file_log_sink.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the unified cross-platform log line contract: UTC 'Z' timestamps,
/// null-free JSONL lines, native context error/stack promotion, and the
/// pre-init buffer that keeps bootstrap logs from vanishing.
///
/// The native producers pin the same shape on their side:
/// windows/runner_tests/native_log_publisher_test.cpp (BuildPayload…) and
/// macos/RunnerTests NativeLoggerTests (buildPayload…). Keep the three in sync.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // UTC ISO8601 with fractional seconds and a trailing Z.
  final utcTs = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z$');

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('log_format_contract');
    FileLogSink().resetForTest();
    await FileLogSink().initForTest(logsDir: tmp);
    Log.resetForTest();
  });

  tearDown(() async {
    FileLogSink().resetForTest();
    Log.resetForTest();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<List<Map<String, dynamic>>> readLines() async {
    await FileLogSink().flushForTest();
    final file = FileLogSink().currentFile;
    if (file == null || !file.existsSync()) return const [];
    return file
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => (jsonDecode(l) as Map).cast<String, dynamic>())
        .toList();
  }

  group('flutter-origin line shape', () {
    test('ts is UTC with a trailing Z and absent fields are omitted', () async {
      Log.markInitializedForTest();
      Log.i('Contract', 'plain line');

      final lines = await readLines();
      expect(lines, hasLength(1));
      final line = lines.single;

      expect(line['ts'], matches(utcTs));
      expect(line['level'], 'INFO');
      expect(line['origin'], 'flutter');
      expect(line['category'], 'Contract');
      expect(line['message'], 'plain line');
      expect(line.containsKey('sessionId'), isTrue);

      // No null padding: a line carries only what the producer knew.
      expect(line.containsKey('file'), isFalse);
      expect(line.containsKey('line'), isFalse);
      expect(line.containsKey('recordingId'), isFalse);
      expect(line.containsKey('context'), isFalse);
      expect(line.containsKey('error'), isFalse);
      expect(line.containsKey('stack'), isFalse);
    });

    test('error/stack/context appear when provided', () async {
      Log.markInitializedForTest();
      Log.e('Contract', 'boom', StateError('bad'), StackTrace.current, {
        'code': 'X1',
      });

      final lines = await readLines();
      final line = lines.single;
      expect(line['error'], contains('bad'));
      expect(line['stack'], isNotEmpty);
      expect((line['context'] as Map)['code'], 'X1');
    });
  });

  group('native-origin ingest', () {
    test('keeps the native UTC ts and omits absent fields', () async {
      Log.markInitializedForTest();
      Log.nativeEvent({
        'ts': '2026-07-12T10:00:00.123Z',
        'level': 'INFO',
        'category': 'Recording',
        'message': 'from native',
        'context': <String, dynamic>{},
      });

      final line = (await readLines()).single;
      expect(line['ts'], '2026-07-12T10:00:00.123Z');
      expect(line['origin'], 'native');
      // The always-sent-but-empty native context map is omitted, not {}.
      expect(line.containsKey('context'), isFalse);
      expect(line.containsKey('error'), isFalse);
    });

    test('promotes context error/stack to the top-level fields', () {
      final event = Log.parseNativeEvent({
        'level': 'ERROR',
        'category': 'Capture',
        'message': 'stream stopped',
        'context': {'error': 'device disconnected', 'stack': 'frame0\nframe1'},
      });

      expect(event.error, 'device disconnected');
      expect(event.stack, 'frame0\nframe1');
      // Promotion copies — context keeps its keys.
      expect(event.context?['error'], 'device disconnected');
    });

    test('top-level error wins over the context value', () {
      final event = Log.parseNativeEvent({
        'level': 'ERROR',
        'category': 'Capture',
        'message': 'stream stopped',
        'error': 'top-level',
        'context': {'error': 'from-context'},
      });

      expect(event.error, 'top-level');
    });

    test('non-string context error is not promoted', () {
      final event = Log.parseNativeEvent({
        'level': 'ERROR',
        'category': 'Capture',
        'message': 'stream stopped',
        'context': {'error': 42},
      });

      expect(event.error, isNull);
    });
  });

  group('pre-init buffer', () {
    test('bootstrap logs buffer and replay into the file on init', () async {
      // Not initialized: the emit must not reach the file yet.
      Log.w('Bootstrap', 'early warning');
      expect(Log.preInitBufferLengthForTest, 1);
      expect(await readLines(), isEmpty);

      Log.drainPreInitBufferForTest();

      final lines = await readLines();
      expect(lines, hasLength(1));
      expect(lines.single['message'], 'early warning');
      expect(Log.preInitBufferLengthForTest, 0);
    });

    test('buffer is bounded and drops the oldest entries', () async {
      for (var i = 0; i < 600; i++) {
        Log.i('Bootstrap', 'line $i');
      }
      expect(Log.preInitBufferLengthForTest, 512);

      Log.drainPreInitBufferForTest();
      final lines = await readLines();
      expect(lines, hasLength(512));
      // Oldest dropped, newest kept.
      expect(lines.first['message'], 'line 88');
      expect(lines.last['message'], 'line 599');
    });

    test('sub-threshold logs are not buffered', () {
      Log.setMinLevel(LogLevel.warning);
      Log.d('Bootstrap', 'dropped');
      expect(Log.preInitBufferLengthForTest, 0);
    });
  });
}
