import 'dart:io';

import 'package:clingfy/core/logging/file_log_sink.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the observable effect of the log-level gate: a sub-threshold log must
/// actually be dropped (not just have the threshold field set). The sink is the
/// only thing that proves the `_emit` / `nativeEvent` guards work, so these
/// drive real logs through to the file sink and assert what landed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('log_emit_gate');
    FileLogSink().resetForTest();
    await FileLogSink().initForTest(logsDir: tmp);
    // These tests drive the sink directly without Log.init — skip the
    // pre-init buffer so emits land in the file immediately.
    Log.markInitializedForTest();
  });

  tearDown(() async {
    FileLogSink().resetForTest();
    Log.resetForTest();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<String> readLog() async {
    await FileLogSink().flushForTest();
    final file = FileLogSink().currentFile;
    if (file == null || !file.existsSync()) return '';
    return file.readAsString();
  }

  test(
    'a warning threshold drops debug/info and keeps warning/error',
    () async {
      Log.setMinLevel(LogLevel.warning);

      Log.d('GateTest', 'dropped-debug');
      Log.i('GateTest', 'dropped-info');
      Log.w('GateTest', 'kept-warning');
      Log.e('GateTest', 'kept-error');

      final contents = await readLog();
      expect(contents, isNot(contains('dropped-debug')));
      expect(contents, isNot(contains('dropped-info')));
      expect(contents, contains('kept-warning'));
      expect(contents, contains('kept-error'));
    },
  );

  test(
    'the native-event ingest gate drops sub-threshold native logs',
    () async {
      Log.setMinLevel(LogLevel.warning);

      Log.nativeEvent({
        'level': 'DEBUG',
        'category': 'Native',
        'message': 'native-dropped-debug',
      });
      Log.nativeEvent({
        'level': 'ERROR',
        'category': 'Native',
        'message': 'native-kept-error',
      });

      final contents = await readLog();
      expect(contents, isNot(contains('native-dropped-debug')));
      expect(contents, contains('native-kept-error'));
    },
  );

  test(
    'lowering the threshold to debug lets debug through (toggle-on)',
    () async {
      Log.setMinLevel(LogLevel.debug);

      Log.d('GateTest', 'now-visible-debug');

      final contents = await readLog();
      expect(contents, contains('now-visible-debug'));
    },
  );
}
