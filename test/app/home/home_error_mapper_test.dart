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
}
