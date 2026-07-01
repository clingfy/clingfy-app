import 'package:clingfy/app/home/home_error_mapper.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 10.3: previously-unmapped codes localize, and an unrecognized
/// code renders the native prose fallback instead of a raw token.
void main() {
  Future<HomeErrorPresentation> mapCode(
    WidgetTester tester,
    String? code, {
    String? fallback,
  }) async {
    late HomeErrorPresentation presentation;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            presentation = HomeErrorMapper.map(
              context,
              code,
              verbatimFallback: fallback,
              openSystemSettings: (_) {},
            );
            return const SizedBox();
          },
        ),
      ),
    );
    return presentation;
  }

  testWidgets('previously-unmapped codes now localize', (tester) async {
    for (final code in const [
      'BAD_MODE',
      'NO_CAMERA',
      'CAMERA_INPUT_ERROR',
      'FILE_NOT_FOUND',
      'WINDOWS_NOT_IMPLEMENTED',
      'EXPORT_DISK_FULL',
      'PREVIEW_INPUT_MISSING',
      'SCENE_INPUT_MISSING',
      // Phase 10.4 — native crash/error codes + Dart-synthesized watchdog
      // codes.
      'RECORDING_DISK_FULL',
      'PREVIEW_OPEN_ERROR',
      'PREVIEW_RENDER_ERROR',
      'INTERNAL_ERROR',
      'RECORDING_START_TIMEOUT',
      'RECORDING_FINALIZE_TIMEOUT',
      'PREVIEW_TIMEOUT',
    ]) {
      final presentation = await mapCode(tester, code);
      expect(presentation.message, isNotNull, reason: code);
      // Localized — never the raw token.
      expect(presentation.message, isNot(code), reason: code);
    }
  });

  testWidgets('RECORDING_DISK_FULL offers the storage settings action', (
    tester,
  ) async {
    final presentation = await mapCode(tester, 'RECORDING_DISK_FULL');
    expect(presentation.message, isNotNull);
    expect(presentation.action, isNotNull);
  });

  testWidgets('PREVIEW_OPEN_ERROR and the watchdog codes are message-only', (
    tester,
  ) async {
    for (final code in const [
      'PREVIEW_OPEN_ERROR',
      'PREVIEW_RENDER_ERROR',
      'INTERNAL_ERROR',
      'RECORDING_START_TIMEOUT',
      'RECORDING_FINALIZE_TIMEOUT',
      'PREVIEW_TIMEOUT',
    ]) {
      final presentation = await mapCode(tester, code);
      expect(presentation.action, isNull, reason: code);
    }
  });

  testWidgets('EXPORT_CANCELLED has NO mapper case — clean cancels are '
      'classified upstream, never toasted', (tester) async {
    // Falls through to the default branch: verbatim fallback (or the raw
    // token) — proof there is no localized mapping that could surface a
    // cancel as an error toast.
    final presentation = await mapCode(
      tester,
      'EXPORT_CANCELLED',
      fallback: 'native cancel prose',
    );
    expect(presentation.message, 'native cancel prose');
    expect(presentation.action, isNull);
  });

  testWidgets('unknown code prefers the native prose fallback', (tester) async {
    final presentation = await mapCode(
      tester,
      'SOME_FUTURE_CODE',
      fallback: 'native explanation prose',
    );
    expect(presentation.message, 'native explanation prose');
  });

  testWidgets('unknown code without fallback renders the raw value', (
    tester,
  ) async {
    final presentation = await mapCode(tester, 'SOME_FUTURE_CODE');
    expect(presentation.message, 'SOME_FUTURE_CODE');
  });
}
