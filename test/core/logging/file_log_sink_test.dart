import 'dart:convert';
import 'dart:io';

import 'package:clingfy/core/logging/file_log_sink.dart';
import 'package:clingfy/core/logging/logger_service.dart';
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
  // --- Truncation: the open TODO "Log files lose their beginning while the
  //     app is still running" ---
  //
  // Reproduced twice in the wild, never explained: a day's file went from
  // 313,453 bytes / 917 rows to 3,439 bytes / 7 rows in four minutes while a
  // session was running, then kept appending normally. Diagnosis of two
  // unrelated bugs has been blocked by it.
  //
  // The sink was cleared by reading the code — `FileMode.append` everywhere,
  // one `delete()` that can only reach files named 30+ days ago. Reading is
  // not the same as pinning, and the TODO's own leading hypothesis ("a
  // crash-and-restart cycle that reopens the path without append") was never
  // actually exercised. These are that exercise. If the sink is innocent they
  // stay green forever and the search moves outside the app for good.

  test(
    'a second launch on the same day appends, it does not truncate',
    () async {
      // The crash-and-restart hypothesis, stated directly. `init` runs on every
      // launch and calls `_rollToCurrentDate` + `_pruneOldLogs` against a file
      // that already has a session's worth of lines in it.
      await FileLogSink().initForTest(logsDir: logsDir, clock: () => fakeNow);
      FileLogSink().append(eventAt(fakeNow, 'first-session'));
      await FileLogSink().flushForTest();

      final file = File.fromUri(logsDir.uri.resolve('logs_2026-05-23.jsonl'));
      final sizeAfterFirst = await file.length();
      expect(sizeAfterFirst, greaterThan(0));

      // Relaunch: same day, same directory, fresh singleton state.
      FileLogSink().resetForTest();
      await FileLogSink().initForTest(logsDir: logsDir, clock: () => fakeNow);

      expect(
        await file.length(),
        sizeAfterFirst,
        reason: 'init alone must not shorten the file it is about to append to',
      );

      FileLogSink().append(eventAt(fakeNow, 'second-session'));
      await FileLogSink().flushForTest();

      final contents = await file.readAsString();
      expect(contents, contains('first-session'));
      expect(contents, contains('second-session'));
      expect(await file.length(), greaterThan(sizeAfterFirst));
    },
  );

  test('pruning never deletes the file being written to', () async {
    // `_pruneOldLogs` holds the sink's only `delete()`. With a one-day
    // retention the cutoff sits closest to today's file, which is the case
    // that would matter.
    await FileLogSink().initForTest(
      logsDir: logsDir,
      clock: () => fakeNow,
      retentionDays: 1,
    );
    FileLogSink().append(eventAt(fakeNow, 'today'));
    await FileLogSink().flushForTest();

    final today = File.fromUri(logsDir.uri.resolve('logs_2026-05-23.jsonl'));
    expect(await today.exists(), isTrue);

    // Re-init, which prunes again.
    FileLogSink().resetForTest();
    await FileLogSink().initForTest(
      logsDir: logsDir,
      clock: () => fakeNow,
      retentionDays: 1,
    );

    expect(await today.exists(), isTrue);
    expect(await today.readAsString(), contains('today'));
  });

  test('a clock that jumps backwards appends to the earlier file', () async {
    // An NTP correction across midnight re-points the sink at a file that
    // already has content. Append, never replace.
    await FileLogSink().initForTest(logsDir: logsDir, clock: () => fakeNow);
    FileLogSink().append(eventAt(fakeNow, 'day-one'));
    await FileLogSink().flushForTest();

    fakeNow = DateTime(2026, 5, 24, 0, 0, 1);
    FileLogSink().append(eventAt(fakeNow, 'day-two'));
    await FileLogSink().flushForTest();

    // Clock corrected backwards, onto the first day again.
    fakeNow = DateTime(2026, 5, 23, 23, 59, 45);
    FileLogSink().append(eventAt(fakeNow, 'day-one-again'));
    await FileLogSink().flushForTest();

    final dayOne = await File.fromUri(
      logsDir.uri.resolve('logs_2026-05-23.jsonl'),
    ).readAsString();
    expect(dayOne, contains('day-one'));
    expect(
      dayOne,
      contains('day-one-again'),
      reason: 'rolling back onto a file must append to it',
    );
  });

  test('a burst of appends loses no lines to the write queue', () async {
    // `_processQueue` snapshots `_writeQueue`, clears it, then awaits the
    // write — so anything enqueued DURING that await lands in the next batch.
    // A dropped line there would read as a hole in the file, which is what
    // the TODO is chasing.
    await FileLogSink().initForTest(logsDir: logsDir, clock: () => fakeNow);

    for (var i = 0; i < 200; i++) {
      FileLogSink().append(eventAt(fakeNow, 'line-$i'));
    }
    await FileLogSink().flushForTest();

    final contents = await File.fromUri(
      logsDir.uri.resolve('logs_2026-05-23.jsonl'),
    ).readAsString();
    for (var i = 0; i < 200; i++) {
      expect(contents, contains('"message":"line-$i"'), reason: 'line $i');
    }
    expect(
      const LineSplitter().convert(contents.trim()).length,
      200,
      reason: 'no line may be duplicated either',
    );
  });

  // Guards the DIAGNOSIS, not the sink.
  //
  // The TODO calls "no `Logger initialized` line, and a first row later than
  // the session's own id" a truncation signature. It is not — it is exactly
  // what a normal midnight rollover leaves behind, and `logs_2026-09-16.jsonl`
  // on a real machine shows precisely that for session
  // `2026-09-15T20:16:42Z`. Anyone matching on that signature will chase
  // rollovers. Pin it so the next reader sees it is expected.
  test(
    'the post-midnight file legitimately has no session-start line',
    () async {
      await FileLogSink().initForTest(logsDir: logsDir, clock: () => fakeNow);
      FileLogSink().append(
        eventAt(fakeNow, 'Logger initialized. SessionId: s1'),
      );
      await FileLogSink().flushForTest();

      fakeNow = DateTime(2026, 5, 24, 0, 30, 0);
      FileLogSink().append(eventAt(fakeNow, 'work after midnight'));
      await FileLogSink().flushForTest();

      final today = await File.fromUri(
        logsDir.uri.resolve('logs_2026-05-24.jsonl'),
      ).readAsString();

      expect(today, contains('work after midnight'));
      expect(
        today,
        isNot(contains('Logger initialized')),
        reason:
            'the continuation file never carries the start line — absence of it '
            'is rollover, not loss',
      );
    },
  );
}
