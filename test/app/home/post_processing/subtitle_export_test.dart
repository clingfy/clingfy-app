import 'dart:io';

import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/captions/subtitle_serializer.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:flutter/services.dart';
import 'package:clingfy/core/timeline/post_state_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../test_helpers/native_test_setup.dart';
import '../../../test_helpers/wait_until.dart';
import 'package:clingfy/core/clips/clip_editor_controller.dart';
import 'package:clingfy/core/clips/clip_state_store.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';

/// What the export carries, and what lands next to the file afterwards.
///
/// Burn-in is native's job (it owns the frames); the sidecar is written here,
/// from the same cue list, once native reports where the video actually landed.
/// Exposes a clip editor the controller will read, so an export can be run
/// against a genuinely edited timeline.
class _EditedPlayer extends PlayerController {
  _EditedPlayer({required super.nativeBridge, this.editor});

  final ClipEditorController? editor;

  @override
  ClipEditorController? get clipEditor => editor ?? super.clipEditor;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late List<MethodCall> calls;
  late String exportedPath;

  setUp(() async {
    await installCommonNativeMocks();
    tempDir = await Directory.systemTemp.createTemp('clingfy_subs_test');
    exportedPath = '${tempDir.path}/My Recording.mp4';
    calls = [];
  });

  tearDown(() async {
    await clearCommonNativeMocks();
    await PostStateStore.settled();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<PostProcessingController> createController({
    required SubtitleMode mode,
    List<Map<String, Object?>> transcript = const [
      {'id': 'c1', 'startMs': 0, 'endMs': 1500, 'text': 'hello there'},
    ],
    String? exportReturns,
    Object? exportSizeReturns = const {'width': 1920, 'height': 1080},
    List<Clip>? clips,
    int recordingDurationMs = 120000,
  }) async {
    SharedPreferences.setMockInitialValues({
      'postSubtitleMode': mode.wireValue,
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'captionsCapability':
          return {
            'available': true,
            'hasMicAudio': true,
            'hasSystemAudio': true,
          };
        case 'generateCaptions':
          return transcript;
        case 'resolveExportSize':
          return exportSizeReturns;
        case 'exportVideo':
          return exportReturns ?? exportedPath;
        case 'processVideo':
          return '/tmp/preview.mov';
        default:
          return null;
      }
    });

    final nativeBridge = NativeBridge.instance;
    final settings = SettingsController(nativeBridge: nativeBridge);
    await settings.loadPreferences();
    ClipEditorController? editor;
    if (clips != null) {
      // Through the real restore path, so the clips the export sees are the
      // ones the editor would actually hold.
      await ClipStateStore.save(
        tempDir.path,
        ClipPersistState(
          recordingDurationMs: recordingDurationMs,
          clips: clips,
        ),
      );
      editor = ClipEditorController(
        nativeBridge: nativeBridge,
        durationMs: recordingDurationMs,
        sessionId: 'rec_export',
        projectPath: tempDir.path,
      );
      addTearDown(editor.dispose);
    }
    final player = _EditedPlayer(nativeBridge: nativeBridge, editor: editor);
    final post = PostProcessingController(
      settings: settings,
      player: player,
      channel: nativeBridge,
    );
    addTearDown(() {
      post.dispose();
      player.dispose();
      settings.dispose();
    });
    post.attachToRecording(
      sessionId: 'rec_export',
      projectPath: clips == null
          ? '${tempDir.path}/project.clingfyproj'
          : tempDir.path,
    );
    await pumpEventQueue();
    return post;
  }

  /// Runs the private sidecar step the way a completed export does, without a
  /// save dialog or a real render.
  Future<void> exportWith(
    PostProcessingController post,
    SubtitleMode mode, {
    String? outputPath,
  }) async {
    await post.writeSubtitleSidecars(outputPath ?? exportedPath, mode);
  }

  File srt([String? path]) =>
      File((path ?? exportedPath).replaceAll('.mp4', '.srt'));
  File vtt([String? path]) =>
      File((path ?? exportedPath).replaceAll('.mp4', '.vtt'));

  // ---- Sidecar output ---------------------------------------------------

  test('sidecar mode writes both formats beside the video', () async {
    final post = await createController(mode: SubtitleMode.sidecar);
    await post.generateCaptions();

    await exportWith(post, SubtitleMode.sidecar);

    expect(srt().existsSync(), isTrue);
    expect(vtt().existsSync(), isTrue);
    expect(srt().readAsStringSync(), contains('hello there'));
    expect(vtt().readAsStringSync(), startsWith('WEBVTT'));
  });

  test('both mode also writes the sidecar', () async {
    final post = await createController(mode: SubtitleMode.both);
    await post.generateCaptions();

    await exportWith(post, SubtitleMode.both);

    expect(srt().existsSync(), isTrue);
  });

  test('burn-in alone writes no files', () async {
    final post = await createController(mode: SubtitleMode.burnIn);
    await post.generateCaptions();

    await exportWith(post, SubtitleMode.burnIn);

    expect(srt().existsSync(), isFalse);
    expect(vtt().existsSync(), isFalse);
  });

  test('off writes nothing even with a transcript in hand', () async {
    final post = await createController(mode: SubtitleMode.none);
    await post.generateCaptions();

    await exportWith(post, SubtitleMode.none);

    expect(srt().existsSync(), isFalse);
  });

  test('no cues means no empty sidecar files', () async {
    // An empty .srt beside a video looks like a broken subtitle track.
    final post = await createController(mode: SubtitleMode.sidecar);

    await exportWith(post, SubtitleMode.sidecar);

    expect(srt().existsSync(), isFalse);
    expect(vtt().existsSync(), isFalse);
  });

  test('edits are what get written, not the raw transcript', () async {
    final post = await createController(mode: SubtitleMode.sidecar);
    await post.generateCaptions();
    post.updateCaptionText('c1', 'Clingfy');

    await exportWith(post, SubtitleMode.sidecar);

    expect(srt().readAsStringSync(), contains('Clingfy'));
    expect(srt().readAsStringSync(), isNot(contains('hello there')));
  });

  test('the sidecar is written as UTF-8 with no BOM', () async {
    final post = await createController(
      mode: SubtitleMode.sidecar,
      transcript: const [
        {'id': 'c1', 'startMs': 0, 'endMs': 1000, 'text': 'مرحبا'},
      ],
    );
    await post.generateCaptions();

    await exportWith(post, SubtitleMode.sidecar);

    final bytes = srt().readAsBytesSync();
    // WebVTT requires UTF-8 and SubRip declares no encoding at all, so a BOM
    // is at best ignored and at worst parsed as part of the first cue number.
    expect(bytes.take(3), isNot([0xEF, 0xBB, 0xBF]));
    expect(srt().readAsStringSync(), contains('مرحبا'));
  });

  // ---- Path handling ----------------------------------------------------

  test('a dot in a folder name does not move the sidecar', () async {
    // Cutting at the last dot in the whole path would write the sidecar as a
    // sibling of the directory instead of beside the video.
    final dotted = Directory('${tempDir.path}/My.Videos')
      ..createSync(recursive: true);
    final video = '${dotted.path}/clip';

    final post = await createController(mode: SubtitleMode.sidecar);
    await post.generateCaptions();
    await exportWith(post, SubtitleMode.sidecar, outputPath: video);

    expect(File('$video.srt').existsSync(), isTrue);
    expect(File('${tempDir.path}/My.srt').existsSync(), isFalse);
  });

  test('an extensionless output still gets its sidecars', () async {
    final video = '${tempDir.path}/clip';
    final post = await createController(mode: SubtitleMode.sidecar);
    await post.generateCaptions();

    await exportWith(post, SubtitleMode.sidecar, outputPath: video);

    expect(File('$video.srt').existsSync(), isTrue);
  });

  test('a sidecar failure does not throw at the export', () async {
    // The video is already on disk. Re-running a whole render to retry two
    // small text files would be far worse than a missing subtitle track.
    final post = await createController(mode: SubtitleMode.sidecar);
    await post.generateCaptions();

    await expectLater(
      exportWith(
        post,
        SubtitleMode.sidecar,
        outputPath: '${tempDir.path}/no such dir/clip.mp4',
      ),
      completes,
    );
  });

  // ---- Edited recordings -------------------------------------------------

  Clip clip(String id, int inMs, int outMs) =>
      Clip(id: id, sourceInMs: inMs, sourceOutMs: outMs, timelineStartMs: inMs);

  test(
    'sidecar timestamps are on the exported timeline, not the source',
    () async {
      // Trims the first 3s. A cue transcribed at 5.0s plays at 2.0s in the file;
      // writing 5.0s would put every subtitle 3 seconds late.
      final post = await createController(
        mode: SubtitleMode.sidecar,
        transcript: const [
          {'id': 'c1', 'startMs': 5000, 'endMs': 6000, 'text': 'hello there'},
        ],
        clips: [clip('a', 3000, 120000)],
      );
      await post.generateCaptions();

      await exportWith(post, SubtitleMode.sidecar);

      final srtText = srt().readAsStringSync();
      expect(srtText, contains('00:00:02,000 --> 00:00:03,000'));
      expect(srtText, isNot(contains('00:00:05,000')));
    },
  );

  test('a cue inside cut footage reaches neither destination', () async {
    final post = await createController(
      mode: SubtitleMode.both,
      transcript: const [
        {'id': 'gone', 'startMs': 40000, 'endMs': 41000, 'text': 'removed'},
        {'id': 'kept', 'startMs': 1000, 'endMs': 2000, 'text': 'survives'},
      ],
      clips: [clip('a', 0, 30000)],
    );
    await post.generateCaptions();

    final args = await post.rasterizeCaptionsForExport();
    await exportWith(post, SubtitleMode.both);

    final cueIds = (args!['captions'] as List)
        .map((c) => (c as Map)['id'])
        .toList();
    expect(cueIds, ['kept'], reason: 'a cut cue must not be rasterised');
    expect(srt().readAsStringSync(), contains('survives'));
    expect(srt().readAsStringSync(), isNot(contains('removed')));
  });

  test(
    'burn-in keeps source times while the sidecar gets output times',
    () async {
      // The one invariant that makes both destinations correct at once: native
      // looks cues up by source time, players read the sidecar in output time.
      final post = await createController(
        mode: SubtitleMode.both,
        transcript: const [
          {'id': 'c1', 'startMs': 8000, 'endMs': 9000, 'text': 'the line'},
        ],
        clips: [clip('a', 5000, 120000)],
      );
      await post.generateCaptions();

      final args = await post.rasterizeCaptionsForExport();
      await exportWith(post, SubtitleMode.both);

      final burnIn = (args!['captions'] as List).first as Map;
      expect(burnIn['startMs'], 8000, reason: 'source time for native');
      expect(srt().readAsStringSync(), contains('00:00:03,000'));
    },
  );

  test('an unedited recording is unaffected by reflow', () async {
    final post = await createController(
      mode: SubtitleMode.sidecar,
      clips: [clip('whole', 0, 120000)],
    );
    await post.generateCaptions();

    await exportWith(post, SubtitleMode.sidecar);

    expect(srt().readAsStringSync(), contains('00:00:00,000 --> 00:00:01,500'));
  });

  // ---- Preview push ------------------------------------------------------

  List<MethodCall> previewPushes() =>
      calls.where((c) => c.method == 'previewSetCaptions').toList();

  /// The push is fire-and-forget and rasterizes to disk on the way, so a fixed
  /// number of event-loop pumps is a race. Poll for the most recent push whose
  /// CONTENT matches, rather than counting: matching on a count makes the
  /// assertion depend on how many pushes happened to be in flight.
  Future<Map<dynamic, dynamic>> waitForPush(
    bool Function(Map<dynamic, dynamic>) matches, {
    String? reason,
  }) => waitForValue(() {
    for (final call in previewPushes().reversed) {
      final args = call.arguments as Map<dynamic, dynamic>;
      if (matches(args)) return args;
    }
    return null;
  }, reason: reason ?? 'expected a matching preview caption push');

  bool hasCues(Map<dynamic, dynamic> args) => (args['cues'] as List).isNotEmpty;
  bool hasNoCues(Map<dynamic, dynamic> args) => (args['cues'] as List).isEmpty;

  test('generating captions hands them to the live preview', () async {
    final post = await createController(mode: SubtitleMode.burnIn);
    await post.generateCaptions();

    final args = await waitForPush(hasCues);
    expect(args['bitmapDirectory'], isA<String>());
    expect((args['cues'] as List), hasLength(1));
    expect(args['canvasWidth'], 1920);
    expect(args['canvasHeight'], 1080);
  });

  test('preview cues are on the EDITED timeline', () async {
    // The preview player's clock is edited time, so this payload is the mirror
    // image of the export one: same cues, other timebase.
    final post = await createController(
      mode: SubtitleMode.burnIn,
      transcript: const [
        {'id': 'c1', 'startMs': 8000, 'endMs': 9000, 'text': 'the line'},
      ],
      clips: [clip('a', 5000, 120000)],
    );
    await post.generateCaptions();

    final cue = ((await waitForPush(hasCues))['cues'] as List).first as Map;
    expect(cue['startMs'], 3000, reason: '8000 - 5000');
  });

  test('subtitles off clears the preview instead of leaving a burn-in', () async {
    // The preview shows what the exported FRAMES will contain. Leaving captions
    // up after the user switches subtitles off would have them proof-reading a
    // look the export is not going to produce.
    final post = await createController(mode: SubtitleMode.burnIn);
    await post.generateCaptions();
    await waitForPush(hasCues);

    post.setSubtitleMode(SubtitleMode.none);

    final cleared = await waitForPush(hasNoCues);
    expect(cleared['bitmapDirectory'], isNull);
  });

  test('sidecar-only shows no burn-in in the preview', () async {
    // The captions go in a separate file; the frames stay clean. Showing them
    // burned in would misrepresent the export.
    final post = await createController(mode: SubtitleMode.burnIn);
    await post.generateCaptions();
    await waitForPush(hasCues);

    post.setSubtitleMode(SubtitleMode.sidecar);

    await waitForPush(hasNoCues, reason: 'sidecar-only must clear the burn-in');
  });

  test('both mode does show a preview burn-in', () async {
    final post = await createController(mode: SubtitleMode.sidecar);
    await post.generateCaptions();
    post.setSubtitleMode(SubtitleMode.both);

    await waitForPush(hasCues, reason: 'both mode burns in');
  });

  test('an edit re-pushes with the corrected text', () async {
    final post = await createController(mode: SubtitleMode.burnIn);
    await post.generateCaptions();
    await waitForPush(hasCues);
    final before = previewPushes().length;

    post.updateCaptionText('c1', 'Clingfy');

    await waitUntil(
      () => previewPushes().length > before,
      reason: 'a corrected cue must reach the preview',
    );
  });

  test('a push that would change nothing is skipped', () async {
    // Player notifications fire at 60Hz during playback and throughout a trim
    // drag, and each one reaches this path. Without the signature check every
    // one of them would rasterize the transcript again.
    final post = await createController(mode: SubtitleMode.burnIn);
    await post.generateCaptions();
    await waitForPush(hasCues);
    final before = previewPushes().length;

    for (var i = 0; i < 20; i++) {
      await post.pushPreviewCaptions();
    }

    expect(previewPushes().length, before);
  });

  test('no transcript pushes nothing at all', () async {
    final post = await createController(mode: SubtitleMode.burnIn);
    await post.pushPreviewCaptions();
    await pumpEventQueue();
    expect(previewPushes(), isEmpty);
  });

  // ---- Export payload ---------------------------------------------------

  test('the burn-in payload carries bitmaps, not text', () async {
    // The contract native actually parses is {id, startMs, endMs, bitmapName}.
    // A cue sent as text is rejected by native's own parser and silently
    // produces zero cues — no burn-in, no error, nothing in the log.
    final post = await createController(mode: SubtitleMode.burnIn);
    await post.generateCaptions();

    final args = await post.rasterizeCaptionsForExport();

    expect(args, isNotNull);
    expect(args!['captionBitmapDirectory'], isA<String>());
    final cues = args['captions'] as List;
    expect(cues, hasLength(1));
    expect(cues.first, containsPair('bitmapName', isA<String>()));
    expect(cues.first, containsPair('id', 'c1'));
    expect(cues.first, isNot(contains('text')));
  });

  test('the bitmaps are really on disk where native is pointed', () async {
    final post = await createController(mode: SubtitleMode.burnIn);
    await post.generateCaptions();

    final args = await post.rasterizeCaptionsForExport();
    final dir = args!['captionBitmapDirectory'] as String;
    final name = (args['captions'] as List).first['bitmapName'] as String;

    final bitmap = File('$dir/$name');
    expect(bitmap.existsSync(), isTrue);
    // PNG magic. Native decodes these by content, so an empty or truncated
    // file would fail at render time rather than here.
    expect(bitmap.readAsBytesSync().take(4), [0x89, 0x50, 0x4E, 0x47]);
  });

  test('no export size means no burn-in rather than a guessed one', () async {
    // Rasterising at a made-up size burns permanently wrong captions into the
    // video. Skipping is the honest failure.
    final post = await createController(
      mode: SubtitleMode.burnIn,
      exportSizeReturns: null,
    );
    await post.generateCaptions();

    expect(await post.rasterizeCaptionsForExport(), isNull);
  });

  test('a degenerate export size is refused', () async {
    final post = await createController(
      mode: SubtitleMode.burnIn,
      exportSizeReturns: {'width': 0, 'height': 1080},
    );
    await post.generateCaptions();

    expect(await post.rasterizeCaptionsForExport(), isNull);
  });

  test('no transcript rasterises nothing', () async {
    final post = await createController(mode: SubtitleMode.burnIn);
    expect(await post.rasterizeCaptionsForExport(), isNull);
  });

  test(
    'a rasterization failure skips burn-in instead of failing the export',
    () async {
      // The bitmap directory cannot be created when a FILE already occupies the
      // path. A throw here would abort an export the user has already waited
      // through the transcription for; losing the burn-in is the lesser harm.
      final post = await createController(mode: SubtitleMode.burnIn);
      await post.generateCaptions();

      final blocked = File('${tempDir.path}/project.clingfyproj/post');
      if (blocked.parent.existsSync()) {
        blocked.parent.listSync().whereType<Directory>().forEach(
          (d) => d.deleteSync(recursive: true),
        );
      }
      blocked.parent.createSync(recursive: true);
      blocked.writeAsStringSync('not a directory');

      // A throw fails this line outright; null is the documented outcome.
      expect(await post.rasterizeCaptionsForExport(), isNull);
    },
  );

  test('the resolved size is asked for with the current presets', () async {
    final post = await createController(mode: SubtitleMode.burnIn);
    await post.generateCaptions();
    await post.rasterizeCaptionsForExport();

    final call = calls.lastWhere((c) => c.method == 'resolveExportSize');
    expect(call.arguments, containsPair('projectPath', isA<String>()));
    expect(call.arguments, containsPair('layoutPreset', isA<String>()));
    expect(call.arguments, containsPair('resolutionPreset', isA<String>()));
  });

  test('the payload always states the destination', () async {
    final post = await createController(mode: SubtitleMode.burnIn);
    await post.generateCaptions();

    expect(post.captions, isNotEmpty);
    // The mode is read from settings at export time, so what the panel shows
    // and what native is told cannot drift.
    expect(post.exportSubtitleMode, SubtitleMode.burnIn);
  });

  test(
    'no transcript means the destination is off regardless of preference',
    () async {
      // A stored "burn in" must not put native into a caption path with an
      // empty track.
      final post = await createController(mode: SubtitleMode.burnIn);

      expect(post.captions, isEmpty);
      expect(post.exportSubtitleMode, SubtitleMode.none);
    },
  );
}
