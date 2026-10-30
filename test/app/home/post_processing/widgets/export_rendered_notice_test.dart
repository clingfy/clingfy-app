import 'package:clingfy/app/home/post_processing/widgets/post_audio_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_cursor_section.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_zoom_section.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

/// Phase 10.3: on Windows the zoom/cursor/audio effect controls work at
/// EXPORT time but the inline preview doesn't reflect them — each section
/// says so. On macOS (live preview compositing) no notice shows.
void main() {
  tearDown(() {
    debugPlatformKindOverride = null;
  });

  Widget host(Widget child) {
    return MaterialApp(
      localizationsDelegates: const [
        ...AppLocalizations.localizationsDelegates,
        fluent.FluentLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      // Platform widgets render fluent variants under the Windows override
      // and macos variants under the macOS override — provide both theme
      // ancestors so either branch can build.
      builder: (context, c) => fluent.FluentTheme(
        data: fluent.FluentThemeData(),
        child: MacosTheme(data: MacosThemeData.light(), child: c!),
      ),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );
  }

  Widget zoomSection() => PostZoomSection(
    isProcessing: false,
    zoomEffectEnabled: true,
    zoomFactor: 1.5,
    onZoomEffectEnabledChanged: (_) {},
    onZoomFactorChanged: (_) {},
    onZoomFactorChangeEnd: (_) {},
  );

  testWidgets('Windows: zoom section carries the export-rendered notice', (
    tester,
  ) async {
    debugPlatformKindOverride = PlatformKind.windows;
    await tester.pumpWidget(host(zoomSection()));
    expect(
      find.byKey(const ValueKey('post_zoom_export_notice')),
      findsOneWidget,
    );
  });

  testWidgets('macOS: zoom section has no export notice', (tester) async {
    debugPlatformKindOverride = PlatformKind.macos;
    await tester.pumpWidget(host(zoomSection()));
    expect(find.byKey(const ValueKey('post_zoom_export_notice')), findsNothing);
  });

  testWidgets(
    'Windows: the cursor section carries the notice, audio does not',
    (tester) async {
      debugPlatformKindOverride = PlatformKind.windows;
      await tester.pumpWidget(
        host(
          Column(
            children: [
              PostCursorSection(
                showCursor: true,
                cursorAvailable: true,
                cursorSize: 1.0,
                onCursorShowChanged: (_) {},
                onCursorSizeChanged: (_) {},
                onCursorSizeChangeEnd: (_) {},
              ),
              PostAudioSection(
                hasAudio: true,
                audioGainDb: 0,
                voiceCleanup: const VoiceCleanup(),
                audioVolume: 100,
                onAudioGainChanged: (_) {},
                onAudioGainChangeEnd: (_) {},
                onVoiceCleanupChanged: (_) {},
                onAudioVolumeChanged: (_) {},
                onAudioVolumeChangeEnd: (_) {},
              ),
            ],
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('post_cursor_export_notice')),
        findsOneWidget,
      );
      // W13: every Windows preview plays through the owned audio renderer, so
      // gain above 0 dB is heard live, uncut or not. The audio panel no longer
      // says "applied on export".
      expect(
        find.byKey(const ValueKey('post_audio_export_notice')),
        findsNothing,
      );

      // Regression guard (#281 hijacked appliedOnExportNoticeWindows to an
      // audio-gain sentence, so the cursor + zoom panels rendered a gain
      // message). The cursor notice must say the effect renders on export, NOT
      // talk about gain.
      final cursorMessage = tester
          .widget<AppInlineNotice>(
            find.byKey(const ValueKey('post_cursor_export_notice')),
          )
          .message;
      expect(cursorMessage, isNot(contains('Gain')));
    },
  );
}
