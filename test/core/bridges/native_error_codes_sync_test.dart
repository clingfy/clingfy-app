import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Phase 10.4: three-way contract sync between the Windows native headers
/// and the Dart constant sets.
///
/// Every quoted UPPER_SNAKE code declared in
/// `windows/runner/Bridge/native_error_codes.h` must exist in Dart's
/// `NativeErrorCode`, and every code in
/// `windows/runner/Bridge/recording_warning_codes.h` must exist in
/// `RecordingWarningCode`. The check is a subset check (.h ⊆ .dart): Dart
/// may declare extra Dart-only codes (e.g. `DartSynthesizedErrorCode`,
/// macOS-only codes) that native never emits.
///
/// The files are compared as text so a native-side addition that forgets
/// the Dart constant fails CI without needing reflection.
void main() {
  final upperSnake = RegExp(r'''["']([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)["']''');

  Set<String> extractCodes(String path) {
    final file = File(path);
    expect(
      file.existsSync(),
      isTrue,
      reason:
          '$path not found — flutter test runs from the repo root, and the '
          'native headers are part of the bridge contract.',
    );
    final content = file.readAsStringSync();
    return upperSnake.allMatches(content).map((m) => m.group(1)!).toSet();
  }

  test('every code in native_error_codes.h exists in NativeErrorCode', () {
    final nativeCodes = extractCodes(
      'windows/runner/Bridge/native_error_codes.h',
    );
    final dartCodes = extractCodes('lib/core/bridges/native_error_codes.dart');

    expect(nativeCodes, isNotEmpty);
    final missing = nativeCodes.difference(dartCodes);
    expect(
      missing,
      isEmpty,
      reason:
          'Codes declared in windows/runner/Bridge/native_error_codes.h but '
          'missing from lib/core/bridges/native_error_codes.dart: $missing. '
          'Add the Dart constant (and a HomeErrorMapper case if it is '
          'user-facing).',
    );
  });

  test(
    'every code in recording_warning_codes.h exists in RecordingWarningCode',
    () {
      final nativeCodes = extractCodes(
        'windows/runner/Bridge/recording_warning_codes.h',
      );
      final dartCodes = extractCodes(
        'lib/core/bridges/recording_warning_codes.dart',
      );

      expect(nativeCodes, isNotEmpty);
      final missing = nativeCodes.difference(dartCodes);
      expect(
        missing,
        isEmpty,
        reason:
            'Codes declared in windows/runner/Bridge/recording_warning_codes.h '
            'but missing from lib/core/bridges/recording_warning_codes.dart: '
            '$missing.',
      );
    },
  );

  test('Phase 10.4 codes are present on both sides', () {
    // Pin the six codes this phase introduced so a future "cleanup" on
    // either side trips loudly.
    final nativeCodes = extractCodes(
      'windows/runner/Bridge/native_error_codes.h',
    );
    final dartCodes = extractCodes('lib/core/bridges/native_error_codes.dart');
    const phase104Codes = {
      'RECORDING_DISK_FULL',
      'EXPORT_CANCELLED',
      'PREVIEW_INPUT_MISSING',
      'SCENE_INPUT_MISSING',
      'PREVIEW_OPEN_ERROR',
      'INTERNAL_ERROR',
    };
    expect(nativeCodes.containsAll(phase104Codes), isTrue);
    expect(dartCodes.containsAll(phase104Codes), isTrue);
  });
}
