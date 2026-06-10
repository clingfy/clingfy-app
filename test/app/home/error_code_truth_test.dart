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
    ]) {
      final presentation = await mapCode(tester, code);
      expect(presentation.message, isNotNull, reason: code);
      // Localized — never the raw token.
      expect(presentation.message, isNot(code), reason: code);
    }
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
