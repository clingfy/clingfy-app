import 'package:clingfy/app/home/home_error_mapper.dart';
import 'package:clingfy/core/bridges/recording_warning_codes.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 10.2: every Windows recordingWarning code maps to a localized
/// message, and codes where a settings page can actually help carry an
/// Open Settings action targeting the right pane.
void main() {
  tearDown(() {
    debugPlatformKindOverride = null;
  });

  Future<HomeErrorPresentation> mapCode(
    WidgetTester tester,
    String code,
    void Function(String pane) onPane,
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
              code,
              openSystemSettings: onPane,
            );
            return const SizedBox();
          },
        ),
      ),
    );
    return presentation;
  }

  testWidgets('actionable warning codes deep-link to the right pane', (
    tester,
  ) async {
    const expectedPanes = {
      RecordingWarningCode.micOpenFailed: 'microphone',
      RecordingWarningCode.micDisconnected: 'sound',
      RecordingWarningCode.systemAudioOpenFailed: 'sound',
      RecordingWarningCode.systemAudioStopped: 'sound',
      RecordingWarningCode.cameraUnavailable: 'camera',
      RecordingWarningCode.cameraOpenFailed: 'camera',
    };
    for (final entry in expectedPanes.entries) {
      String? openedPane;
      final presentation = await mapCode(
        tester,
        entry.key,
        (pane) => openedPane = pane,
      );
      expect(presentation.message, isNotNull, reason: entry.key);
      // Localized, never the raw code.
      expect(presentation.message, isNot(entry.key), reason: entry.key);
      expect(presentation.action, isNotNull, reason: entry.key);
      presentation.action!.onPressed();
      expect(openedPane, entry.value, reason: entry.key);
    }
  });

  testWidgets('hardware/encoder warning codes are message-only', (
    tester,
  ) async {
    const messageOnly = [
      RecordingWarningCode.cameraDisconnected,
      // No Windows settings page fixes a SetWindowDisplayAffinity failure.
      RecordingWarningCode.cameraPreviewHidden,
      RecordingWarningCode.encoderVideoError,
      RecordingWarningCode.encoderAudioError,
    ];
    for (final code in messageOnly) {
      final presentation = await mapCode(tester, code, (_) {});
      expect(presentation.message, isNotNull, reason: code);
      expect(presentation.message, isNot(code), reason: code);
      expect(presentation.action, isNull, reason: code);
    }
  });

  testWidgets('preview-hidden copy does not read as camera loss', (
    tester,
  ) async {
    // The failure mode this wording exists to prevent: a user reading the
    // toast, believing the camera was lost, and stopping the recording. The
    // camera IS captured and DOES appear in the export — only the live bubble
    // is missing, and the copy has to say so.
    final presentation = await mapCode(
      tester,
      RecordingWarningCode.cameraPreviewHidden,
      (_) {},
    );
    expect(presentation.message, isNotNull);
    final message = presentation.message!.toLowerCase();
    expect(message, contains('preview'));
    expect(
      message,
      anyOf(contains('finished video'), contains('still captured')),
      reason: 'copy must reassure that the camera still reaches the export',
    );
  });

  testWidgets('permission error copy forks by platform', (tester) async {
    debugPlatformKindOverride = PlatformKind.windows;
    var presentation = await mapCode(
      tester,
      'MICROPHONE_PERMISSION_REQUIRED',
      (_) {},
    );
    expect(presentation.message, contains('Windows Settings'));

    debugPlatformKindOverride = PlatformKind.macos;
    presentation = await mapCode(
      tester,
      'MICROPHONE_PERMISSION_REQUIRED',
      (_) {},
    );
    expect(presentation.message, contains('System Settings'));
  });
}
