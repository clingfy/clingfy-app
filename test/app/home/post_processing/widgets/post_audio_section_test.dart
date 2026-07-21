import 'package:clingfy/app/home/post_processing/widgets/post_audio_section.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

/// Voice-cleanup UI on Windows (Phase 4 slice): the RNNoise engine denoises on
/// EXPORT, so the toggle is now shown, but the mode selector stays macOS-only
/// (Windows runs full strength for either mode) and an export notice replaces
/// the WYSIWYG the live preview can't give yet.
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
      builder: (context, c) => fluent.FluentTheme(
        data: fluent.FluentThemeData(),
        child: MacosTheme(data: MacosThemeData.light(), child: c!),
      ),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );
  }

  Widget audioSection(VoiceCleanup voiceCleanup) => PostAudioSection(
    hasAudio: true,
    audioGainDb: 0,
    voiceCleanup: voiceCleanup,
    audioVolume: 100,
    onAudioGainChanged: (_) {},
    onAudioGainChangeEnd: (_) {},
    onVoiceCleanupChanged: (_) {},
    onAudioVolumeChanged: (_) {},
    onAudioVolumeChangeEnd: (_) {},
  );

  const toggle = ValueKey('post_audio_voice_cleanup_toggle');
  const mode = ValueKey('post_audio_voice_cleanup_mode');
  const voiceNotice = ValueKey('post_audio_voice_cleanup_export_notice');

  testWidgets('Windows: the voice-cleanup toggle is shown', (tester) async {
    debugPlatformKindOverride = PlatformKind.windows;
    await tester.pumpWidget(host(audioSection(const VoiceCleanup())));
    expect(find.byKey(toggle), findsOneWidget);
  });

  testWidgets('Windows enabled: mode selector hidden, export notice shown', (
    tester,
  ) async {
    debugPlatformKindOverride = PlatformKind.windows;
    await tester.pumpWidget(
      host(audioSection(const VoiceCleanup(enabled: true))),
    );
    expect(find.byKey(toggle), findsOneWidget);
    expect(find.byKey(mode), findsNothing);
    expect(find.byKey(voiceNotice), findsOneWidget);
  });

  testWidgets('macOS enabled: mode selector shown, no export notice', (
    tester,
  ) async {
    debugPlatformKindOverride = PlatformKind.macos;
    await tester.pumpWidget(
      host(audioSection(const VoiceCleanup(enabled: true))),
    );
    expect(find.byKey(toggle), findsOneWidget);
    expect(find.byKey(mode), findsOneWidget);
    expect(find.byKey(voiceNotice), findsNothing);
  });
}
