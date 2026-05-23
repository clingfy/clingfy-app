import 'dart:io';

import 'package:clingfy/app/infrastructure/logging/file_log_sink.dart';
import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late Directory logsDir;
  late DateTime fakeNow;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('file_log_sink_test_');
    logsDir = Directory.fromUri(tempDir.uri.resolve('Logs/'));
    fakeNow = DateTime(2026, 5, 23, 23, 59, 30);
  });

  tearDown(() async {
    FileLogSink().resetForTest();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  LogEvent eventAt(DateTime ts, String message) {
    return LogEvent(
      ts: ts.toIso8601String(),
      level: 'INFO',
      origin: 'flutter',
      category: 'Test',
      message: message,
      sessionId: 'session',
    );
  }

  Future<String?> readIfExists(File file) async {
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  test('writes to today\'s daily file', () async {
    await FileLogSink().initForTest(logsDir: logsDir, clock: () => fakeNow);

    FileLogSink().append(eventAt(fakeNow, 'hello'));
    await FileLogSink().flushForTest();

    final expected = File.fromUri(logsDir.uri.resolve('logs_2026-05-23.jsonl'));
    expect(await expected.exists(), isTrue);
    final contents = await expected.readAsString();
    expect(contents, contains('"message":"hello"'));
  });

  test(
    'rolls over to a new file when local date changes mid-session',
    () async {
      await FileLogSink().initForTest(logsDir: logsDir, clock: () => fakeNow);

      FileLogSink().append(eventAt(fakeNow, 'before-midnight'));
      await FileLogSink().flushForTest();

      // Advance the clock past midnight.
      fakeNow = DateTime(2026, 5, 24, 0, 0, 1);
      FileLogSink().append(eventAt(fakeNow, 'after-midnight'));
      await FileLogSink().flushForTest();

      final yesterdayFile = File.fromUri(
        logsDir.uri.resolve('logs_2026-05-23.jsonl'),
      );
      final todayFile = File.fromUri(
        logsDir.uri.resolve('logs_2026-05-24.jsonl'),
      );

      final yesterday = await readIfExists(yesterdayFile);
      final today = await readIfExists(todayFile);

      expect(yesterday, isNotNull);
      expect(yesterday, contains('"message":"before-midnight"'));
      expect(yesterday, isNot(contains('"message":"after-midnight"')));

      expect(today, isNotNull);
      expect(today, contains('"message":"after-midnight"'));
      expect(today, isNot(contains('"message":"before-midnight"')));
    },
  );

  test('init prunes log files older than the retention window', () async {
    await logsDir.create(recursive: true);
    final old = File.fromUri(logsDir.uri.resolve('logs_2026-01-01.jsonl'));
    final recent = File.fromUri(logsDir.uri.resolve('logs_2026-05-20.jsonl'));
    final unrelated = File.fromUri(logsDir.uri.resolve('readme.txt'));
    await old.writeAsString('{"old":true}\n');
    await recent.writeAsString('{"recent":true}\n');
    await unrelated.writeAsString('keep me');

    await FileLogSink().initForTest(
      logsDir: logsDir,
      clock: () => fakeNow,
      retentionDays: 30,
    );

    expect(
      await old.exists(),
      isFalse,
      reason: 'logs older than retention window should be deleted',
    );
    expect(
      await recent.exists(),
      isTrue,
      reason: 'logs within retention window should be kept',
    );
    expect(
      await unrelated.exists(),
      isTrue,
      reason: 'non-matching files in the logs dir must not be touched',
    );
  });

  test('retentionDays = 0 disables pruning', () async {
    await logsDir.create(recursive: true);
    final ancient = File.fromUri(logsDir.uri.resolve('logs_2020-01-01.jsonl'));
    await ancient.writeAsString('{"ancient":true}\n');

    await FileLogSink().initForTest(
      logsDir: logsDir,
      clock: () => fakeNow,
      retentionDays: 0,
    );

    expect(await ancient.exists(), isTrue);
  });

  test('append is a no-op when init has not run', () async {
    // Singleton starts unconfigured after resetForTest in tearDown of prior
    // tests; here we explicitly do not call initForTest.
    FileLogSink().append(eventAt(fakeNow, 'dropped'));
    await FileLogSink().flushForTest();

    expect(FileLogSink().currentFile, isNull);
    // The logs directory should not have been created.
    expect(await logsDir.exists(), isFalse);
  });
}
