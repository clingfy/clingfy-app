import 'package:clingfy/core/logging/logger_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 10.4: native log payloads thread `error`, `stack`, and `context`
/// onto the LogEvent — previously `error`/`stack` were silently dropped,
/// which kept the Sentry sink's exception promotion (event.error /
/// event.stack) from ever firing for native ERROR logs.
void main() {
  test('parseNativeEvent threads error, stack, and context through', () {
    final event = Log.parseNativeEvent({
      'ts': '2026-06-11T10:00:00.000',
      'level': 'ERROR',
      'category': 'Recording',
      'message': 'capture device lost',
      'file': 'recording_engine.cpp',
      'line': 512,
      'context': {'code': 'ENCODER_VIDEO_ERROR', 'hr': '0xC00D4A44'},
      'error': 'MF_E_HW_MFT_FAILED_START_STREAMING',
      'stack': 'frame0\nframe1',
    });

    expect(event.origin, 'native');
    expect(event.level, 'ERROR');
    expect(event.category, 'Recording');
    expect(event.message, 'capture device lost');
    expect(event.file, 'recording_engine.cpp');
    expect(event.line, 512);
    expect(event.context, {'code': 'ENCODER_VIDEO_ERROR', 'hr': '0xC00D4A44'});
    expect(event.error, 'MF_E_HW_MFT_FAILED_START_STREAMING');
    expect(event.stack, 'frame0\nframe1');
  });

  test('parseNativeEvent treats absent/empty/non-string error and stack as '
      'null', () {
    final absent = Log.parseNativeEvent({
      'level': 'ERROR',
      'category': 'Recording',
      'message': 'no extras',
    });
    expect(absent.error, isNull);
    expect(absent.stack, isNull);

    final empty = Log.parseNativeEvent({
      'level': 'ERROR',
      'category': 'Recording',
      'message': 'empty extras',
      'error': '',
      'stack': '',
    });
    expect(empty.error, isNull);
    expect(empty.stack, isNull);

    final wrongType = Log.parseNativeEvent({
      'level': 'ERROR',
      'category': 'Recording',
      'message': 'typed wrong',
      'error': 42,
      'stack': {'not': 'a string'},
    });
    expect(wrongType.error, isNull);
    expect(wrongType.stack, isNull);
  });

  test('parseNativeEvent coerces non-string context keys', () {
    final event = Log.parseNativeEvent({
      'level': 'INFO',
      'category': 'Native',
      'message': 'm',
      'context': <dynamic, dynamic>{1: 'one', 'code': 'X_Y'},
    });

    expect(event.context, {'1': 'one', 'code': 'X_Y'});
  });
}
