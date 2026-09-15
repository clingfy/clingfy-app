import 'package:clingfy/app/home/post_processing/widgets/post_captions_section.dart';
import 'package:clingfy/core/captions/captions_capability.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:clingfy/core/captions/subtitle_serializer.dart';
import 'package:clingfy/core/captions/caption_reflow.dart';

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
    bool isCancelling = false,
    double? progress,
    bool isProcessing = false,
    bool engineBusyOffScreen = false,
    bool hasEverGenerated = false,
    bool failed = false,
    ValueChanged<bool>? onUseMicChanged,
    VoidCallback? onGenerate,
    VoidCallback? onCancel,
    void Function(String, String)? onCueTextChanged,
    SubtitleMode subtitleMode = SubtitleMode.burnIn,
    ValueChanged<SubtitleMode>? onSubtitleModeChanged,
    List<Clip>? clips,
  }) {
    return PostCaptionsSection(
      capability: capability,
      captions: captions,
      useMic: useMic,
      useSystem: useSystem,
      isGenerating: isGenerating,
      isCancelling: isCancelling,
      progress: progress,
      isProcessing: isProcessing,
      engineBusyOffScreen: engineBusyOffScreen,
      hasEverGenerated: hasEverGenerated,
      failed: failed,
      onUseMicChanged: onUseMicChanged ?? (_) {},
      onUseSystemChanged: (_) {},
      onGenerate: onGenerate ?? () {},
      onCancel: onCancel ?? () {},
      onCueTextChanged: onCueTextChanged ?? (_, _) {},
      subtitleMode: subtitleMode,
      onSubtitleModeChanged: onSubtitleModeChanged ?? (_) {},
      // Defaults to an unedited recording, so the timestamp a test sees is the
      // cue's own time unless the test supplies clips.
      reflowed: CaptionReflow.reflow(
        captions: captions,
        clips: clips ?? const <Clip>[],
      ),
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
      host(section(useMic: false, useSystem: false, onGenerate: () => fired++)),
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

  testWidgets('generate is dead — and says why — while the engine finishes '
      'another recording', (tester) async {
    // The engine takes one job at a time, and the cancel that frees it is
    // best-effort against a model download that cannot be interrupted. For as
    // long as that takes, this recording's Generate looked perfectly live and
    // the controller dropped every press on the floor.
    var fired = 0;
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(
      host(section(engineBusyOffScreen: true, onGenerate: () => fired++)),
    );

    await tester.tap(find.byKey(generateKey));
    await tester.pump();
    expect(
      fired,
      0,
      reason: 'the press cannot start a job, so it must not try',
    );
    expect(
      find.text(l10n.captionsEngineBusy),
      findsOneWidget,
      reason: 'a grey button with no reason reads as the feature being broken',
    );
  });

  testWidgets('an idle engine leaves generate live and says nothing', (
    tester,
  ) async {
    // The control for the test above: the notice is for a genuinely occupied
    // engine only. Shown always, it would be trained away.
    var fired = 0;
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(host(section(onGenerate: () => fired++)));

    await tester.tap(find.byKey(generateKey));
    await tester.pump();
    expect(fired, 1);
    expect(find.text(l10n.captionsEngineBusy), findsNothing);
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

  testWidgets('stopping is acknowledged the moment it is pressed', (
    tester,
  ) async {
    // The engine cannot be interrupted mid-download, so the press has to be
    // visibly received. It was not, and the logs show eleven presses in four
    // seconds because of it.
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(
      host(section(isGenerating: true, isCancelling: true, progress: 0.4)),
    );

    expect(find.text(l10n.captionsStopping), findsOneWidget);
  });

  testWidgets('a second stop press does nothing', (tester) async {
    var cancelled = 0;
    await tester.pumpWidget(
      host(
        section(
          isGenerating: true,
          isCancelling: true,
          onCancel: () => cancelled++,
        ),
      ),
    );

    await tester.tap(find.byKey(cancelKey), warnIfMissed: false);
    await tester.pump();
    expect(cancelled, 0);
  });

  testWidgets('the bar stops advancing once stop is pressed', (tester) async {
    // A bar still moving after Stop says the work is continuing, which is the
    // opposite of what the user just asked for.
    await tester.pumpWidget(
      host(section(isGenerating: true, isCancelling: true, progress: 0.4)),
    );
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, isNull);
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

  testWidgets('a failed run says so instead of blaming the recording', (
    tester,
  ) async {
    // A failure and a silent recording both end with `hasEverGenerated` true
    // and an empty cue list, so without the `failed` flag a model that would
    // not download is reported as "no speech found" — which tells the user the
    // wrong thing and gives them nothing to retry.
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(
      host(section(hasEverGenerated: true, failed: true)),
    );

    expect(find.text(l10n.captionsFailed), findsOneWidget);
    expect(find.text(l10n.captionsNoSpeechFound), findsNothing);
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

  testWidgets('typing reaches the preview without leaving the field', (
    tester,
  ) async {
    // Commit-on-blur alone meant the preview kept showing the old text until
    // the user clicked elsewhere, which reads as the edit not working — on a
    // feature whose entire point is watching the caption change.
    final commits = <(String, String)>[];
    await tester.pumpWidget(
      host(
        section(
          captions: [cue('cue-7', 'wrong name')],
          onCueTextChanged: (id, text) => commits.add((id, text)),
        ),
      ),
    );

    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'Clingfy');

    expect(commits, isEmpty, reason: 'not on the keystroke itself');
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      commits,
      [('cue-7', 'Clingfy')],
      reason: 'but shortly after typing stops, with the field still focused',
    );
  });

  testWidgets('a burst of typing commits once, not once per character', (
    tester,
  ) async {
    // Every commit is an undoable edit and re-rasterizes the cue, so
    // per-keystroke commits would bury real changes in the undo stack.
    final commits = <(String, String)>[];
    await tester.pumpWidget(
      host(
        section(
          captions: [cue('cue-7', 'x')],
          onCueTextChanged: (id, text) => commits.add((id, text)),
        ),
      ),
    );

    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    for (final text in ['C', 'Cl', 'Cli', 'Clin', 'Cling']) {
      await tester.enterText(find.byType(TextField).first, text);
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump(const Duration(milliseconds: 500));

    expect(commits, [('cue-7', 'Cling')]);
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

  // ---- Timestamps on an edited recording ---------------------------------

  Clip clip(String id, int inMs, int outMs) =>
      Clip(id: id, sourceInMs: inMs, sourceOutMs: outMs, timelineStartMs: inMs);

  testWidgets('a timestamp says where the cue is in the EXPORT', (
    tester,
  ) async {
    // Trimming the first 30s means the cue transcribed at 00:47 plays at 00:17.
    // Showing the source time sends the user to a different sentence, with
    // nothing on screen to explain the offset.
    await tester.pumpWidget(
      host(
        section(
          captions: [cue('a', 'the line', startMs: 47000)],
          clips: [clip('c', 30000, 120000)],
        ),
      ),
    );

    expect(find.text('00:17'), findsOneWidget);
    expect(find.text('00:47'), findsNothing);
  });

  testWidgets('an unedited recording still shows the cue time', (tester) async {
    await tester.pumpWidget(
      host(section(captions: [cue('a', 'the line', startMs: 65000)])),
    );
    expect(find.text('01:05'), findsOneWidget);
  });

  testWidgets('a cue whose footage was cut is marked, not timestamped', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(
      host(
        section(
          captions: [
            cue('kept', 'still here', startMs: 1000),
            cue('gone', 'removed', startMs: 40000),
          ],
          clips: [clip('c', 0, 30000)],
        ),
      ),
    );

    expect(find.text(l10n.captionsNotInExport), findsOneWidget);
    // Still listed rather than hidden: a correction the user typed into it is
    // real work, and undoing the cut must bring the line back.
    expect(find.text('removed'), findsOneWidget);
  });

  testWidgets('rows are ordered the way the export plays them', (tester) async {
    // Reordered clips: the tail plays first, so the cue transcribed later is
    // the one the viewer hears first.
    await tester.pumpWidget(
      host(
        section(
          captions: [
            cue('early', 'spoken first', startMs: 1000),
            cue('late', 'spoken last', startMs: 7000),
          ],
          clips: [clip('b', 6000, 10000), clip('a', 0, 4000)],
        ),
      ),
    );

    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields.first.controller!.text, 'spoken last');
    expect(fields.last.controller!.text, 'spoken first');
  });

  testWidgets('cut cues sort last, after everything still in the export', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        section(
          captions: [
            cue('gone', 'cut away', startMs: 1000),
            cue('kept', 'in the file', startMs: 40000),
          ],
          clips: [clip('c', 30000, 60000)],
        ),
      ),
    );

    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields.first.controller!.text, 'in the file');
    expect(fields.last.controller!.text, 'cut away');
  });

  // ---- Export destination ------------------------------------------------

  testWidgets('the destination picker only appears once cues exist', (
    tester,
  ) async {
    const key = ValueKey('captions_destination');
    await tester.pumpWidget(host(section()));
    expect(
      find.byKey(key),
      findsNothing,
      reason: 'nothing to burn in or write out yet',
    );

    await tester.pumpWidget(host(section(captions: [cue('a', 'hello')])));
    expect(find.byKey(key), findsOneWidget);
  });

  testWidgets('picking a destination reports it', (tester) async {
    final picked = <SubtitleMode>[];
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(
      host(
        section(
          captions: [cue('a', 'hello')],
          onSubtitleModeChanged: picked.add,
        ),
      ),
    );

    await tester.tap(find.text(l10n.captionsDestinationBoth));
    await tester.pumpAndSettle();
    expect(picked, [SubtitleMode.both]);
  });

  testWidgets('every destination is offered, each with its own label', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final labels = [
      l10n.captionsDestinationOff,
      l10n.captionsDestinationBurnIn,
      l10n.captionsDestinationSidecar,
      l10n.captionsDestinationBoth,
    ];
    expect(labels.toSet(), hasLength(SubtitleMode.values.length));

    await tester.pumpWidget(host(section(captions: [cue('a', 'hello')])));
    for (final label in labels) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // Burn-in and sidecar are not alternatives, so the trade-off is spelled
    // out rather than left to the four one-word labels.
    expect(find.text(l10n.captionsDestinationHint), findsOneWidget);
  });

  testWidgets('the destination is inert while an export runs', (tester) async {
    final picked = <SubtitleMode>[];
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(
      host(
        section(
          captions: [cue('a', 'hello')],
          isProcessing: true,
          onSubtitleModeChanged: picked.add,
        ),
      ),
    );

    await tester.tap(
      find.text(l10n.captionsDestinationBoth),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(
      picked,
      isEmpty,
      reason: 'changing the destination mid-export would not take effect',
    );
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
