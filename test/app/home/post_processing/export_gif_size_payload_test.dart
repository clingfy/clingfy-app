import 'dart:async';
import 'dart:io';

import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/captions/caption_rasterizer.dart';
import 'package:clingfy/core/captions/subtitle_serializer.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../../test_helpers/native_test_setup.dart';

/// Guards the Dart side of the GIF-size bridge contract end-to-end: driving the
/// real export dialog must send the persisted `gifSize` on the `exportVideo`
/// method-channel payload. Without this, a misspelled payload key or a dropped
/// persist branch would let native silently fall back to "large" (the 1080
/// cap) on every GIF export, and the isolated dialog/DTO/policy tests would all
/// still pass. See the adversarial-review finding that motivated it.
///
/// It guards the caption contract on the same payload for the same reason, and
/// this is the only file that does. Captions reach a real export through
/// exactly two lines in `exportCurrentRecording` — the `...?captionArgs` spread
/// and the `writeSubtitleSidecars` call — and every other caption test routes
/// AROUND them, through `rasterizeCaptionsForExport` and
/// `writeSubtitleSidecars` directly. Both lines were deleted during an audit
/// and the entire suite stayed green: burn-in and sidecars were disconnected
/// from export and nothing noticed. The mode cases below are what notice.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String projectPath;
  late String exportedPath;
  late List<MethodCall> calls;
  late List<MethodCall> exportCalls;

  /// Whether every bitmap named on the `exportVideo` payload was on disk at the
  /// moment native was handed it.
  ///
  /// Sampled inside the mock rather than after the fact because that instant is
  /// the one that matters: native reads these PNGs while it renders, and a
  /// manifest naming a file that was never written (or one already swept away)
  /// burns nothing in while reporting success.
  late List<bool> bitmapsReadableAtInvoke;
  late SettingsController settings;
  late PlayerController player;
  late PostProcessingController post;

  /// The canvas native reports for a GIF at the `small` preset — the long edge
  /// capped, which is what the exporter actually renders a GIF at.
  const Size gifCanvas = Size(480, 270);

  /// The canvas native reports for everything else.
  const Size fullCanvas = Size(1920, 1080);

  /// Long enough that laid out for [fullCanvas] it would be several times wider
  /// than a [gifCanvas] frame, so a bitmap built for the wrong canvas cannot
  /// pass for one built for the right one.
  const String cueText = 'a fairly long line of dialogue to lay out and wrap';

  setUp(() async {
    await installCommonNativeMocks();
    tempDir = await Directory.systemTemp.createTemp('clingfy_export_payload');
    projectPath = '${tempDir.path}/project.clingfyproj';
    // Inside a real directory: the sidecar is written beside the file native
    // says it wrote, so a path that cannot be created would pass the mode gate
    // and still leave no `.srt` on disk.
    exportedPath = '${tempDir.path}/My Recording.mp4';
    calls = <MethodCall>[];
    exportCalls = <MethodCall>[];
    bitmapsReadableAtInvoke = <bool>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getExcludeRecorderApp':
          return false;
        case 'getExcludeMicFromSystemAudio':
          return true;
        case 'captionsCapability':
          return {
            'available': true,
            'hasMicAudio': true,
            'hasSystemAudio': true,
          };
        case 'generateCaptions':
          return [
            {'id': 'c1', 'startMs': 0, 'endMs': 1500, 'text': cueText},
          ];
        case 'resolveExportSize':
          // Answers the way native does: a GIF is not rendered at the
          // resolution preset, it is capped to the size preset's long edge. A
          // caller that forgets to say which format it is asking about gets the
          // uncapped canvas, exactly as an older binary would reply.
          final args = call.arguments as Map<dynamic, dynamic>;
          final isSmallGif =
              args['format'] == 'gif' && args['gifSize'] == 'small';
          final size = isSmallGif ? gifCanvas : fullCanvas;
          return {'width': size.width, 'height': size.height};
        case 'exportVideo':
          exportCalls.add(call);
          final args = call.arguments as Map<dynamic, dynamic>;
          final directory = args['captionBitmapDirectory'] as String?;
          bitmapsReadableAtInvoke = [
            for (final cue in (args['captions'] as List<dynamic>?) ?? const [])
              File(
                '$directory/${(cue as Map<dynamic, dynamic>)['bitmapName']}',
              ).existsSync(),
          ];
          return exportedPath;
        default:
          return null;
      }
    });

    final nativeBridge = NativeBridge.instance;
    settings = SettingsController(nativeBridge: nativeBridge);
    await settings.loadPreferences();
    player = PlayerController(nativeBridge: nativeBridge);
    post = PostProcessingController(
      settings: settings,
      player: player,
      channel: nativeBridge,
    );
    post.attachToRecording(
      sessionId: 'rec_test_session',
      projectPath: projectPath,
    );
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    post.dispose();
    player.dispose();
    settings.dispose();
    await clearCommonNativeMocks();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {
      // A fire-and-forget project write that outlived the test can hold the
      // directory; leaking a temp dir beats failing a green test on cleanup.
    }
  });

  Widget hostFor(void Function(BuildContext) onTap) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: buildDarkTheme(),
      home: MacosTheme(
        data: buildMacosTheme(Brightness.dark),
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => onTap(context),
                child: const Text('open-export'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Bounded pumps until [done], each paired with a REAL-time yield.
  ///
  /// `pumpAndSettle` alone can never finish a captioned export: rasterizing a
  /// cue writes a PNG and round-trips the engine to encode it, and neither
  /// completes on the fake clock — the export future simply stays pending while
  /// the test spins. The yield is what lets that real work land between frames.
  Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 400; i++) {
      if (done()) return;
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
  }

  /// Seeds a transcript through the real `generateCaptions` path, in [mode].
  ///
  /// Run inside `runAsync` because generating cues persists the track and
  /// pushes freshly rasterized bitmaps to the preview — real file and image
  /// work that the fake clock never lets complete, so awaiting it from a normal
  /// `testWidgets` body deadlocks the test rather than failing it.
  Future<void> seedTranscript(WidgetTester tester, SubtitleMode mode) async {
    post.setSubtitleMode(mode);
    await tester.runAsync(() async {
      await post.generateCaptions();
      // The persist and the preview push are fire-and-forget; let them land
      // here rather than leaving real I/O in flight across the export.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(
      post.exportSubtitleMode,
      mode,
      reason: 'the export has to be about to run in the mode under test',
    );
  }

  /// Drives the real export dialog to completion and returns the payload native
  /// was handed.
  Future<Map<String, dynamic>> runExportAndCapture(WidgetTester tester) async {
    String? exportedTo;
    var finished = false;
    await tester.pumpWidget(
      hostFor((context) {
        unawaited(
          post.exportCurrentRecording(context).then((path) {
            exportedTo = path;
            finished = true;
          }),
        );
      }),
    );
    await tester.tap(find.text('open-export'));
    await tester.pumpAndSettle();

    // The export dialog is up; submit it with the persisted selection.
    expect(find.text('Export'), findsOneWidget);
    // Everything from here belongs to the export itself. Cleared so a
    // `resolveExportSize` the preview asked while seeding cues cannot be
    // mistaken for the one the export asks.
    calls.clear();
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    await settleUntil(tester, () => finished);

    expect(
      finished,
      isTrue,
      reason: 'the export must run to completion before anything is asserted',
    );
    expect(
      exportedTo,
      exportedPath,
      reason: 'native reported where the file landed; the sidecar goes there',
    );
    expect(
      exportCalls,
      isNotEmpty,
      reason:
          'exportCurrentRecording must invoke the native exportVideo method',
    );
    return Map<String, dynamic>.from(
      exportCalls.last.arguments! as Map<dynamic, dynamic>,
    );
  }

  File srt() => File(exportedPath.replaceAll('.mp4', '.srt'));
  File vtt() => File(exportedPath.replaceAll('.mp4', '.vtt'));

  /// The cue entries on an `exportVideo` payload, or null when the payload
  /// carries no burn-in at all.
  List<Map<dynamic, dynamic>>? burnInCues(Map<String, dynamic> args) {
    final raw = args['captions'] as List<dynamic>?;
    if (raw == null) return null;
    return [for (final e in raw) e as Map<dynamic, dynamic>];
  }

  testWidgets('exportVideo payload carries the persisted GIF size (small)', (
    tester,
  ) async {
    await settings.export.updateExportFormat('gif');
    await settings.export.updateGifSize('small');

    final args = await runExportAndCapture(tester);

    expect(args['format'], 'gif');
    expect(
      args['gifSize'],
      'small',
      reason:
          'A misspelled key or dropped persist branch would send no/"large" '
          'gifSize, silently pinning every GIF export to the 1080 cap.',
    );
  });

  testWidgets(
    'exportVideo payload reflects a different persisted size (medium)',
    (tester) async {
      await settings.export.updateExportFormat('gif');
      await settings.export.updateGifSize('medium');

      final args = await runExportAndCapture(tester);

      expect(args['format'], 'gif');
      expect(args['gifSize'], 'medium');
    },
  );

  // ---- Captions reach a real export -------------------------------------

  testWidgets('burn-in sends the cue payload and writes no sidecar', (
    tester,
  ) async {
    await seedTranscript(tester, SubtitleMode.burnIn);

    final args = await runExportAndCapture(tester);

    final cues = burnInCues(args);
    expect(
      cues,
      isNotNull,
      reason:
          'the export payload is the only thing that puts a caption into the '
          'video; without it native renders a subtitle-free file and reports '
          'success',
    );
    expect(cues!.single['id'], 'c1');
    expect(cues.single['startMs'], 0);
    expect(cues.single['endMs'], 1500);
    expect(args['captionBitmapDirectory'], isNotNull);
    expect(
      bitmapsReadableAtInvoke,
      [isTrue],
      reason:
          'native composites the PNG named here; a manifest pointing at a file '
          'that was never written, or one already swept away, burns nothing in',
    );
    expect(
      srt().existsSync(),
      isFalse,
      reason: 'burn-in alone puts the text in the pixels, not beside the file',
    );

    // Deliberately AFTER the export has finished. The bitmaps used to be
    // deleted in the export's `finally`, which threw away the whole
    // content-addressed cache: the next export of the same transcript re-ran
    // layout, toImage and a PNG encode for every cue, serially, on the UI
    // isolate.
    final directory = args['captionBitmapDirectory'] as String;
    final name = cues.single['bitmapName'] as String;
    expect(
      File('$directory/$name').existsSync(),
      isTrue,
      reason:
          'the finished export leaves its bitmaps for the next one to reuse',
    );
  });

  testWidgets('sidecar mode writes the .srt and burns nothing in', (
    tester,
  ) async {
    // The mode gate, in the direction that cannot be undone. A user who chose
    // "Separate file (.srt)" and got a burn-in has captions welded into the
    // pixels of a file they have already published; the only remedy is a
    // re-export. The opposite mistake — a missing sidecar — costs a click.
    await seedTranscript(tester, SubtitleMode.sidecar);

    final args = await runExportAndCapture(tester);

    expect(
      args.containsKey('captions'),
      isFalse,
      reason:
          'an inverted gate burns subtitles permanently into a video the user '
          'asked to keep clean',
    );
    expect(args.containsKey('captionBitmapDirectory'), isFalse);
    expect(
      srt().existsSync(),
      isTrue,
      reason: 'the sidecar is the whole of what this mode produces',
    );
    expect(srt().readAsStringSync(), contains(cueText));
    expect(vtt().existsSync(), isTrue);
  });

  testWidgets('both mode sends the cue payload AND writes the sidecar', (
    tester,
  ) async {
    await seedTranscript(tester, SubtitleMode.both);

    final args = await runExportAndCapture(tester);

    expect(burnInCues(args), isNotNull);
    expect(args['captionBitmapDirectory'], isNotNull);
    expect(srt().existsSync(), isTrue);
    expect(srt().readAsStringSync(), contains(cueText));
  });

  testWidgets('subtitles off send nothing and write nothing', (tester) async {
    // With a transcript in hand, so this is the mode gate refusing and not
    // simply an export with nothing to say.
    await seedTranscript(tester, SubtitleMode.none);

    final args = await runExportAndCapture(tester);

    expect(args.containsKey('captions'), isFalse);
    expect(args.containsKey('captionBitmapDirectory'), isFalse);
    expect(srt().existsSync(), isFalse);
    expect(vtt().existsSync(), isFalse);
  });

  // ---- The canvas a GIF's captions are drawn for -------------------------

  testWidgets('a GIF burn-in rasterizes at the GIF canvas, not the full one', (
    tester,
  ) async {
    // A GIF is not rendered at the resolution preset: the exporter caps its
    // intermediate to the chosen size preset's long edge. Asking native for the
    // canvas without saying "gif, small" gets the uncapped 1920x1080 back, and
    // the caption renderer only ever shrinks a bitmap WIDER than the frame — so
    // the pill is drawn 1:1 and swallows the picture.
    await settings.export.updateExportFormat('gif');
    await settings.export.updateGifSize('small');
    await seedTranscript(tester, SubtitleMode.burnIn);

    final args = await runExportAndCapture(tester);

    final sizeCall = calls.singleWhere((c) => c.method == 'resolveExportSize');
    expect(sizeCall.arguments, containsPair('format', 'gif'));
    expect(sizeCall.arguments, containsPair('gifSize', 'small'));

    // Exact, not approximate: the bitmap's name is a hash of everything its
    // pixels depend on, the canvas included, so the name IS the canvas it was
    // laid out for.
    String nameFor(Size canvas) => CaptionRasterizer.bitmapName(
      text: cueText,
      videoSize: canvas,
      style: const CaptionStyle(),
      fontFamily: CaptionRasterizer.bundledCaptionFontFamily,
      maxWidthFraction: 0.9,
      referenceHeight: 1080.0,
    );

    final cues = burnInCues(args);
    expect(cues, isNotNull);
    expect(
      cues!.single['bitmapName'],
      nameFor(gifCanvas),
      reason:
          'the cue must be drawn for the frame the GIF is really rendered '
          'at',
    );
    expect(
      cues.single['bitmapName'],
      isNot(nameFor(fullCanvas)),
      reason: 'laid out for the uncapped canvas is the defect itself',
    );
  });
}
