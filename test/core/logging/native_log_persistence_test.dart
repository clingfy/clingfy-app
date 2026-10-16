import 'dart:convert';
import 'dart:io';

import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/logging/file_log_sink.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// macOS writes its native log lines to disk itself, when they are logged, so
/// a line logged just before a crash survives it. Dart's half of that contract:
/// it must not write those lines again, it must give native the ids every line
/// carries, and its own lines must not wait in memory when the app goes down.
class _RemoteSpy implements RemoteLogSink {
  final events = <LogEvent>[];
  @override
  void send(LogEvent event) => events.add(event);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _RemoteSpy remote;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('native_log_persist_');
    Log.resetForTest();
    FileLogSink().resetForTest();
    remote = _RemoteSpy();
    await Log.init(remoteSink: remote);
    await FileLogSink().initForTest(logsDir: Directory('${tempDir.path}/Logs'));
  });

  tearDown(() async {
    FileLogSink().resetForTest();
    Log.resetForTest();
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  List<Map<String, dynamic>> fileLines() {
    final file = FileLogSink().currentFile;
    if (file == null || !file.existsSync()) return const [];
    return file
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();
  }

  Map<String, dynamic> nativePayload(String message, {bool? persisted}) => {
    'ts': '2026-10-16T10:00:00.000Z',
    'level': 'INFO',
    'category': 'NativePersist',
    'message': message,
    'context': <String, dynamic>{},
    if (persisted != null) 'persisted': persisted,
  };

  group('native lines', () {
    test('a line native already wrote is not written again', () {
      Log.nativeEvent(nativePayload('written by native', persisted: true));
      expect(
        fileLines().where((l) => l['message'] == 'written by native'),
        isEmpty,
        reason: 'it would appear twice in the file',
      );
    });

    test('but it still reaches Sentry', () {
      Log.nativeEvent(nativePayload('written by native', persisted: true));
      expect(
        remote.events.map((e) => e.message),
        contains('written by native'),
      );
    });

    /// Windows and older macOS builds never set the flag, and must keep
    /// having Dart write their lines.
    test('an unflagged line is still written by Dart', () {
      Log.nativeEvent(nativePayload('written by dart'));
      expect(
        fileLines().where((l) => l['message'] == 'written by dart'),
        hasLength(1),
      );
    });
  });

  group('Dart lines', () {
    /// The line that explains a crash is usually the last one before it.
    /// Every line, not only errors, is on disk when the call returns, with
    /// nothing awaited.
    test('every line is on disk the moment it is logged', () {
      Log.i('Persist', 'an info line');
      expect(fileLines().map((l) => l['message']), contains('an info line'));
      Log.e('Persist', 'the last words');
      expect(fileLines().map((l) => l['message']), contains('the last words'));
    });

    /// Each write lands after the previous one. With the old async queue a
    /// synchronous write could be overwritten by a batch already in flight,
    /// because Dart's append mode seeks once instead of appending atomically.
    test('a burst of lines all survive, in order', () {
      for (var i = 0; i < 50; i++) {
        i.isEven ? Log.i('Persist', 'line $i') : Log.e('Persist', 'line $i');
      }
      final messages = fileLines()
          .where((l) => l['category'] == 'Persist')
          .map((l) => l['message'])
          .toList();
      expect(messages, [for (var i = 0; i < 50; i++) 'line $i']);
    });
  });

  group('the ids native stamps its lines with', () {
    const channel = MethodChannel('com.clingfy/screen_recorder');
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'the session is sent before the drain, so held lines carry it',
      () async {
        NativeBridge.instance.startNativeLogHandshake();
        await pumpEventQueue();
        final names = calls.map((c) => c.method).toList();
        expect(
          names.indexOf('setNativeLogContext'),
          lessThan(names.indexOf('flushPendingNativeLogs')),
        );
        final args =
            calls.firstWhere((c) => c.method == 'setNativeLogContext').arguments
                as Map;
        expect(args['sessionId'], Log.sessionId);
      },
      skip: Platform.isMacOS ? false : 'macOS only',
    );

    test(
      'starting and ending a recording tells native',
      () async {
        NativeBridge.instance.startNativeLogHandshake();
        await pumpEventQueue();
        calls.clear();

        Log.recordingId = 'rec-1';
        Log.recordingId = 'rec-1'; // unchanged: no second call
        Log.recordingId = null;
        await pumpEventQueue();

        final sent = calls
            .where((c) => c.method == 'setNativeLogContext')
            .map((c) => (c.arguments as Map)['recordingId'])
            .toList();
        expect(sent, ['rec-1', null]);
      },
      skip: Platform.isMacOS ? false : 'macOS only',
    );
  });
}
