import 'package:clingfy/core/bridges/native_error_codes.dart';
import 'package:clingfy/app/home/home_error_mapper.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'maps screen recording permission error to localized message and settings action',
    (tester) async {
      late HomeErrorPresentation presentation;
      String? openedPane;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              presentation = HomeErrorMapper.map(
                context,
                NativeErrorCode.screenRecordingPermission,
                openSystemSettings: (pane) {
                  openedPane = pane;
                },
              );
              return const SizedBox();
            },
          ),
        ),
      );

      expect(presentation.message, isNotNull);
      expect(presentation.action?.label, 'Open Settings');
      presentation.action?.onPressed();
      expect(openedPane, 'screen');
    },
  );

  testWidgets('maps camera and accessibility errors to settings actions', (
    tester,
  ) async {
    late HomeErrorPresentation cameraPresentation;
    late HomeErrorPresentation accessibilityPresentation;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            cameraPresentation = HomeErrorMapper.map(
              context,
              NativeErrorCode.cameraPermissionDenied,
              openSystemSettings: (_) {},
            );
            accessibilityPresentation = HomeErrorMapper.map(
              context,
              NativeErrorCode.accessibilityPermissionRequired,
              openSystemSettings: (_) {},
            );
            return const SizedBox();
          },
        ),
      ),
    );

    expect(cameraPresentation.action?.label, 'Open Settings');
    expect(accessibilityPresentation.action?.label, 'Open Settings');
  });

  testWidgets('maps a GIF refused for its length to the cap message', (
    tester,
  ) async {
    late HomeErrorPresentation presentation;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            presentation = HomeErrorMapper.map(
              context,
              NativeErrorCode.exportGifTooLong,
              openSystemSettings: (_) {},
            );
            return const SizedBox();
          },
        ),
      ),
    );

    expect(presentation.message, contains('at most 60 seconds'));
    expect(presentation.message, isNot(NativeErrorCode.exportGifTooLong));
  });

  group('errors that carry a native reason', () {
    Future<String?> mapped(
      WidgetTester tester,
      String code, {
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
      return presentation.message;
    }

    for (final code in [
      NativeErrorCode.recordingError,
      NativeErrorCode.exportError,
      NativeErrorCode.outputUrlError,
    ]) {
      testWidgets('$code shows the native reason', (tester) async {
        final message = await mapped(
          tester,
          code,
          fallback: 'The capture session was interrupted.',
        );
        expect(message, contains('The capture session was interrupted.'));
      });

      testWidgets('$code with no reason is a whole sentence', (tester) async {
        // Windows with no prose, and macOS echoing the code as its message.
        for (final fallback in [null, '', '   ', code]) {
          final message = await mapped(tester, code, fallback: fallback);
          expect(message, isNotNull);
          expect(message, isNot(endsWith(': ')), reason: 'fallback: $fallback');
          expect(message!.trim(), isNot(endsWith(':')));
          expect(message, isNot(contains(code)));
        }
      });
    }

    testWidgets('a failed recording with no reason says what to do', (
      tester,
    ) async {
      final message = await mapped(tester, NativeErrorCode.recordingError);
      expect(message, contains('no reason was reported'));
      expect(message, contains('Diagnostics'));
    });
  });

  testWidgets('the export toast shows the reason, or a whole sentence', (
    tester,
  ) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context)!;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(
      HomeErrorMapper.exportErrorMessage(l10n, 'The disk was ejected.'),
      contains('The disk was ejected.'),
    );
    for (final reason in [null, '', 'EXPORT_ERROR']) {
      final message = HomeErrorMapper.exportErrorMessage(l10n, reason);
      expect(message, isNot(contains('Unknown error')));
      expect(message.trim(), isNot(endsWith(':')));
      expect(message, contains('no reason was reported'));
    }
  });
}
