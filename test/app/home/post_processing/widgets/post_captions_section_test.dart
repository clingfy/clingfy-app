import 'package:clingfy/app/home/post_processing/widgets/post_captions_section.dart';
import 'package:clingfy/core/captions/captions_capability.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

/// The captions panel: what it refuses to offer, when it offers it, and what
/// an edit actually commits.
///
/// The gates here are the point — a Generate button that is live when there is
/// nothing to transcribe, or a bar pinned at 0% through a 626 MB model
/// download, are the two failures this pins.
void main() {
  const generateKey = Key('captions_generate_button');
  const cancelKey = Key('captions_cancel_button');
  const micKey = Key('captions_source_mic');
  const systemKey = Key('captions_source_system');

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

  PostCaptionsSection section({
    CaptionsCapabilityInfo? capability = const CaptionsCapabilityInfo(
      available: true,
      hasMicAudio: true,
      hasSystemAudio: true,
    ),
    List<Caption> captions = const [],
    bool useMic = true,
    bool useSystem = true,
    bool isGenerating = false,
    double? progress,
    bool isProcessing = false,
    bool hasEverGenerated = false,
    ValueChanged<bool>? onUseMicChanged,
    VoidCallback? onGenerate,
    VoidCallback? onCancel,
    void Function(String, String)? onCueTextChanged,
  }) {
    return PostCaptionsSection(
      capability: capability,
      captions: captions,
      useMic: useMic,
      useSystem: useSystem,
      isGenerating: isGenerating,
      progress: progress,
      isProcessing: isProcessing,
      hasEverGenerated: hasEverGenerated,
      onUseMicChanged: onUseMicChanged ?? (_) {},
      onUseSystemChanged: (_) {},
      onGenerate: onGenerate ?? () {},
      onCancel: onCancel ?? () {},
      onCueTextChanged: onCueTextChanged ?? (_, _) {},
    );
  }

  Caption cue(String id, String text, {int startMs = 0}) =>
      Caption(id: id, startMs: startMs, endMs: startMs + 2000, text: text);

  // ---- Capability gating -----------------------------------------------

  testWidgets('shows nothing until the capability probe answers', (
    tester,
  ) async {
    await tester.pumpWidget(host(section(capability: null)));
    expect(find.byKey(generateKey), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('an unavailable machine gets a reason, not a dead button', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        section(
          capability: const CaptionsCapabilityInfo(
            available: false,
            reason: CaptionsUnavailableReason.unsupportedOs,
          ),
        ),
      ),
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.captionsUnavailableOs), findsOneWidget);
    expect(find.byKey(generateKey), findsNothing);
  });

  testWidgets('each unavailable reason gets its own message', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final expected = {
      CaptionsUnavailableReason.unsupportedOs: l10n.captionsUnavailableOs,
      CaptionsUnavailableReason.intelSlowPath: l10n.captionsUnavailableIntel,
      CaptionsUnavailableReason.noAudio: l10n.captionsUnavailableNoAudio,
      CaptionsUnavailableReason.platformNotSupported:
          l10n.captionsUnavailablePlatform,
    };
    // Distinct text per reason — a shared string would make three of these
    // notices lie about why captions are off.
    expect(expected.values.toSet().length, expected.length);

    for (final entry in expected.entries) {
      await tester.pumpWidget(
        host(
          section(
            capability: CaptionsCapabilityInfo(
              available: false,
              reason: entry.key,
            ),
          ),
        ),
      );
      expect(find.text(entry.value), findsOneWidget, reason: '${entry.key}');
    }
  });

  // ---- Source picker ---------------------------------------------------

  testWidgets('the source picker only appears when there is a choice', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        section(
          capability: const CaptionsCapabilityInfo(
            available: true,
            hasMicAudio: true,
          ),
        ),
      ),
    );
    expect(find.byKey(micKey), findsNothing);
    expect(find.byKey(systemKey), findsNothing);

    await tester.pumpWidget(host(section()));
    expect(find.byKey(micKey), findsOneWidget);
    expect(find.byKey(systemKey), findsOneWidget);
  });

  testWidgets('a pre-separation recording says what it cannot caption', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        section(
          capability: const CaptionsCapabilityInfo(
            available: true,
            usesEmbeddedAudioOnly: true,
          ),
        ),
      ),
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.captionsMicOnlyRecording), findsOneWidget);
  });

  // ---- Generate gating -------------------------------------------------

  testWidgets('generate is dead when every source is off', (tester) async {
    var fired = 0;
    await tester.pumpWidget(
      host(
        section(useMic: false, useSystem: false, onGenerate: () => fired++),
      ),
    );
    await tester.tap(find.byKey(generateKey));
    await tester.pump();
    expect(fired, 0, reason: 'nothing selected means nothing to transcribe');

    await tester.pumpWidget(host(section(onGenerate: () => fired++)));
    await tester.tap(find.byKey(generateKey));
    await tester.pump();
    expect(fired, 1);
  });

  testWidgets('generate is dead while an export is running', (tester) async {
    var fired = 0;
    await tester.pumpWidget(
      host(section(isProcessing: true, onGenerate: () => fired++)),
    );
    await tester.tap(find.byKey(generateKey));
    await tester.pump();
    expect(fired, 0);
  });

  testWidgets('the button says regenerate once cues exist', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(host(section()));
    expect(find.text(l10n.captionsGenerate), findsOneWidget);

    await tester.pumpWidget(host(section(captions: [cue('a', 'hello')])));
    expect(find.text(l10n.captionsRegenerate), findsOneWidget);
    expect(
      find.text(l10n.captionsGenerate),
      findsNothing,
      reason: 'regenerating discards edits — the label must warn of that',
    );
  });

  // ---- Progress --------------------------------------------------------

  testWidgets('a null fraction renders indeterminate, not zero', (
    tester,
  ) async {
    await tester.pumpWidget(host(section(isGenerating: true)));
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(
      bar.value,
      isNull,
      reason: 'a bar stuck at 0% through a model download reads as a hang',
    );
  });

  testWidgets('a real fraction reaches the bar and the percentage', (
    tester,
  ) async {
    await tester.pumpWidget(host(section(isGenerating: true, progress: 0.42)));
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.42, 1e-9));
    expect(find.textContaining('42%'), findsOneWidget);
  });

  testWidgets('generating swaps generate for cancel', (tester) async {
    var cancelled = 0;
    await tester.pumpWidget(
      host(section(isGenerating: true, onCancel: () => cancelled++)),
    );
    expect(find.byKey(generateKey), findsNothing);
    await tester.tap(find.byKey(cancelKey));
    await tester.pump();
    expect(cancelled, 1);
  });

  testWidgets('the first-run download notice is shown once, not forever', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(host(section(isGenerating: true)));
    expect(find.text(l10n.captionsFirstRunDownload), findsOneWidget);

    await tester.pumpWidget(
      host(section(isGenerating: true, hasEverGenerated: true)),
    );
    expect(find.text(l10n.captionsFirstRunDownload), findsNothing);
  });

  // ---- Results ---------------------------------------------------------

  testWidgets('"no speech" is only said after a run, never before', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(host(section()));
    expect(
      find.text(l10n.captionsNoSpeechFound),
      findsNothing,
      reason: 'not run yet is not the same as found nothing',
    );

    await tester.pumpWidget(host(section(hasEverGenerated: true)));
    expect(find.text(l10n.captionsNoSpeechFound), findsOneWidget);
  });

  testWidgets('every cue gets a field and a timestamp', (tester) async {
    await tester.pumpWidget(
      host(
        section(
          captions: [
            cue('a', 'first line'),
            cue('b', 'second line', startMs: 65000),
          ],
        ),
      ),
    );
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('first line'), findsOneWidget);
    expect(find.text('01:05'), findsOneWidget);
  });

  // ---- Editing ---------------------------------------------------------

  testWidgets('an edit commits on blur, once, with the cue id', (tester) async {
    final commits = <(String, String)>[];
    await tester.pumpWidget(
      host(
        section(
          captions: [cue('cue-7', 'wrong name'), cue('cue-8', 'other')],
          onCueTextChanged: (id, text) => commits.add((id, text)),
        ),
      ),
    );

    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'Clingfy');
    await tester.pump();
    expect(
      commits,
      isEmpty,
      reason: 'per-keystroke commits would bury real edits in the undo stack',
    );

    // Blur by focusing the sibling field.
    await tester.tap(find.byType(TextField).last);
    await tester.pumpAndSettle();
    expect(commits, [('cue-7', 'Clingfy')]);
  });

  testWidgets('an unchanged field commits nothing on blur', (tester) async {
    final commits = <(String, String)>[];
    await tester.pumpWidget(
      host(
        section(
          captions: [cue('a', 'unchanged'), cue('b', 'other')],
          onCueTextChanged: (id, text) => commits.add((id, text)),
        ),
      ),
    );
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.tap(find.byType(TextField).last);
    await tester.pumpAndSettle();
    expect(commits, isEmpty);
  });

  testWidgets('regenerating replaces the text under an unfocused field', (
    tester,
  ) async {
    await tester.pumpWidget(host(section(captions: [cue('a', 'old text')])));
    expect(find.text('old text'), findsOneWidget);

    await tester.pumpWidget(host(section(captions: [cue('a', 'new text')])));
    await tester.pump();
    expect(find.text('new text'), findsOneWidget);
    expect(find.text('old text'), findsNothing);
  });

  testWidgets('cue fields are inert while a transcription runs', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(section(captions: [cue('a', 'hello')], isGenerating: true)),
    );
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
  });

  // ---- Direction -------------------------------------------------------

  TextDirection directionOf(WidgetTester tester, String text) {
    final field = find.ancestor(
      of: find.text(text),
      matching: find.byType(TextField),
    );
    return Directionality.of(tester.element(field));
  }

  testWidgets('a cue lays out in its own script, not the editor shell\'s', (
    tester,
  ) async {
    // The post-processing shell pins LTR. An Arabic transcript rendered under
    // that reads with its punctuation and numerals on the wrong side.
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: host(
          section(
            captions: [
              cue('en', 'hello there'),
              cue('ar', 'مرحبا بالعالم', startMs: 3000),
            ],
          ),
        ),
      ),
    );

    expect(directionOf(tester, 'hello there'), TextDirection.ltr);
    expect(directionOf(tester, 'مرحبا بالعالم'), TextDirection.rtl);
  });

  testWidgets('leading punctuation does not decide direction', (tester) async {
    // Bidi rule: the FIRST STRONG character sets the paragraph direction.
    // Quotes and digits are neutral, so a quoted Arabic line is still RTL.
    await tester.pumpWidget(
      host(
        section(
          captions: [
            cue('a', '"مرحبا"'),
            cue('b', '— hello', startMs: 3000),
            cue('c', '123 456', startMs: 6000),
          ],
        ),
      ),
    );
    expect(directionOf(tester, '"مرحبا"'), TextDirection.rtl);
    expect(directionOf(tester, '— hello'), TextDirection.ltr);
    expect(
      directionOf(tester, '123 456'),
      TextDirection.ltr,
      reason: 'no strong character at all falls back to LTR',
    );
  });
}
