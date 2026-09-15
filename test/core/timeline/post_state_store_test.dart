import 'dart:convert';
import 'dart:io';

import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/timeline/model/canvas_state.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/core/timeline/model/timeline.dart';
import 'package:clingfy/core/timeline/post_state_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The unified `post/state.json` and the migration off the three legacy files.
///
/// Everything here is about not losing a customer's edits. A project made by
/// 1.0.5 has `clips_state.json`; one made by the caption release also has
/// `captions_state.json`; both have `editor_state.json`. Opening any of them
/// after this change must produce exactly what the user last saw, and the
/// legacy files must not be removed until the replacement is safely on disk.
void main() {
  late Directory project;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('clingfy_post_state');
  });

  tearDown(() async {
    await PostStateStore.settled();
    if (project.existsSync()) project.deleteSync(recursive: true);
  });

  File unified() => File('${project.path}/post/state.json');
  File legacy(String name) => File('${project.path}/$name');

  void writeLegacyClips() {
    legacy('clips_state.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'clips': [
          {
            'id': 'a',
            'sourceInMs': 0,
            'sourceOutMs': 5000,
            'timelineStartMs': 0,
            'enabled': true,
          },
        ],
      }),
    );
  }

  void writeLegacyCaptions() {
    legacy('captions_state.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'captions': [
          {'id': 'c1', 'startMs': 0, 'endMs': 1000, 'text': 'hello'},
        ],
      }),
    );
  }

  void writeLegacyEditor() {
    legacy('editor_state.json').writeAsStringSync(
      jsonEncode({
        'version': 2,
        'padding': 24.0,
        'cornerRadius': 12.0,
        'background': {
          'kind': 'color',
          'colorArgb': 0xFF102030,
          'imagePath': null,
          'preset': null,
        },
        'colorGrade': {
          'autoEnabled': true,
          'exposure': 0.25,
          'contrast': 0.0,
          'saturation': 0.0,
          'temperature': 0.0,
          'tint': 0.0,
        },
      }),
    );
  }

  // ---- Reading a project that has never been migrated -------------------

  test(
    'a project with all three legacy files opens with every edit intact',
    () {
      writeLegacyClips();
      writeLegacyCaptions();
      writeLegacyEditor();

      final t = PostStateStore.load(project.path);

      expect(t.trackOfType<ClipTrack>()?.clips, hasLength(1));
      expect(t.trackOfType<ClipTrack>()!.clips.single.sourceOutMs, 5000);
      expect(t.trackOfType<CaptionTrack>()?.captions.single.text, 'hello');
      expect(t.canvas.padding, 24.0);
      expect(t.canvas.cornerRadius, 12.0);
      expect(t.canvas.backgroundColorArgb, 0xFF102030);
      expect(t.grade.exposure, 0.25);
      expect(t.grade.autoEnabled, isTrue);
    },
  );

  test(
    'a 1.0.5-era project — clips and canvas, no transcript — still opens',
    () {
      writeLegacyClips();
      writeLegacyEditor();

      final t = PostStateStore.load(project.path);

      expect(t.trackOfType<ClipTrack>()?.clips, hasLength(1));
      expect(
        t.trackOfType<CaptionTrack>(),
        isNull,
        reason: 'never transcribed',
      );
      expect(t.canvas.padding, 24.0);
    },
  );

  test('a project with nothing at all opens as an empty timeline', () {
    final t = PostStateStore.load(project.path);
    expect(t.tracks, isEmpty);
    expect(t.canvas, const CanvasState());
    expect(t.grade, const ColorGrade());
  });

  test('the recorder-written {} placeholder counts as not-yet-migrated', () {
    // Both recorders pre-create post/state.json as `{}` to satisfy the manifest
    // pointer. Treating that as a real empty timeline would silently discard
    // every legacy edit the moment this shipped.
    unified().createSync(recursive: true);
    unified().writeAsStringSync('{}\n');
    writeLegacyClips();

    expect(PostStateStore.needsMigration(project.path), isTrue);
    expect(
      PostStateStore.load(project.path).trackOfType<ClipTrack>(),
      isNotNull,
    );
  });

  test('a legacy procedural background migrates with all five fields', () {
    // The richest thing editor_state.json held. Losing a field here would not
    // throw — the background would just render differently than the user left
    // it, which is the kind of loss nobody reports as a bug.
    legacy('editor_state.json').writeAsStringSync(
      jsonEncode({
        'version': 2,
        'padding': 8.0,
        'cornerRadius': 4.0,
        'background': {
          'kind': 'preset',
          'colorArgb': null,
          'imagePath': null,
          'preset': {
            'id': 'abstractWaves',
            'palette': 'bluePurple',
            'intensity': 0.35,
            'blur': 0.7,
            'seed': 99,
          },
        },
        'colorGrade': const ColorGrade().toMap(),
      }),
    );

    final canvas = PostStateStore.load(project.path).canvas;
    expect(canvas.backgroundKind, BackgroundKind.preset);
    expect(canvas.backgroundPreset?.id, 'abstractWaves');
    expect(canvas.backgroundPreset?.palette, 'bluePurple');
    expect(canvas.backgroundPreset?.intensity, 0.35);
    expect(canvas.backgroundPreset?.blur, 0.7);
    expect(canvas.backgroundPreset?.seed, 99);
  });

  test('a legacy image background migrates with its path', () {
    legacy('editor_state.json').writeAsStringSync(
      jsonEncode({
        'version': 2,
        'padding': 0.0,
        'cornerRadius': 0.0,
        'background': {
          'kind': 'image',
          'colorArgb': null,
          'imagePath': '/pictures/backdrop.png',
          'preset': null,
        },
        'colorGrade': const ColorGrade().toMap(),
      }),
    );

    final canvas = PostStateStore.load(project.path).canvas;
    expect(canvas.backgroundKind, BackgroundKind.image);
    expect(canvas.backgroundImagePath, '/pictures/backdrop.png');
  });

  // ---- Writing, and retiring what it replaces ---------------------------

  test('saving writes the unified file and retires the legacy trio', () async {
    writeLegacyClips();
    writeLegacyCaptions();
    writeLegacyEditor();

    final migrated = PostStateStore.load(project.path);
    await PostStateStore.save(project.path, migrated);

    expect(unified().existsSync(), isTrue);
    expect(legacy('clips_state.json').existsSync(), isFalse);
    expect(legacy('captions_state.json').existsSync(), isFalse);
    expect(legacy('editor_state.json').existsSync(), isFalse);
    expect(PostStateStore.needsMigration(project.path), isFalse);
  });

  test('a migrated project reloads byte-for-byte equivalent', () async {
    writeLegacyClips();
    writeLegacyCaptions();
    writeLegacyEditor();

    final before = PostStateStore.load(project.path);
    await PostStateStore.save(project.path, before);
    final after = PostStateStore.load(project.path);

    expect(
      after.trackOfType<ClipTrack>()!.clips,
      before.trackOfType<ClipTrack>()!.clips,
    );
    expect(
      after.trackOfType<CaptionTrack>()!.captions.single.text,
      before.trackOfType<CaptionTrack>()!.captions.single.text,
    );
    expect(after.canvas, before.canvas);
    expect(after.grade.exposure, before.grade.exposure);
  });

  test('the unified file wins over stale legacy files if both exist', () async {
    // Belt and braces: retirement is best-effort, so a leftover must never
    // outrank the file that replaced it.
    await PostStateStore.save(
      project.path,
      const Timeline(canvas: CanvasState(padding: 99.0)),
    );
    writeLegacyEditor(); // padding 24 — must be ignored

    expect(PostStateStore.load(project.path).canvas.padding, 99.0);
  });

  test(
    'a save into a bundle that does not exist is refused, not invented',
    () async {
      final missing = '${project.path}${Platform.pathSeparator}gone';
      await PostStateStore.save(missing, const Timeline(durationMs: 5));
      expect(
        Directory(missing).existsSync(),
        isFalse,
        reason: 'no project tree may be conjured at a path with no bundle',
      );
    },
  );

  // ---- Schema ------------------------------------------------------------

  test('a v2 file with no canvas block decodes to canvas defaults', () {
    unified().createSync(recursive: true);
    unified().writeAsStringSync(
      jsonEncode({
        'schemaVersion': 2,
        'timeline': {
          'durationMs': 1000,
          'grade': const ColorGrade().toMap(),
          'tracks': [],
        },
      }),
    );

    final t = PostStateStore.load(project.path);
    expect(t.schemaVersion, 2);
    expect(t.canvas, const CanvasState());
    expect(t.durationMs, 1000);
  });

  test(
    'an untouched canvas is not written, so v3 costs nothing to a plain project',
    () async {
      await PostStateStore.save(project.path, const Timeline(durationMs: 500));
      final raw = jsonDecode(unified().readAsStringSync()) as Map;
      expect((raw['timeline'] as Map).containsKey('canvas'), isFalse);
    },
  );

  test('a background preset survives the round trip', () async {
    const preset = CanvasBackgroundPreset(
      id: 'abstractWaves',
      palette: 'bluePurple',
      intensity: 0.4,
      blur: 0.8,
      seed: 7,
    );
    await PostStateStore.save(
      project.path,
      const Timeline(
        canvas: CanvasState(
          backgroundKind: BackgroundKind.preset,
          backgroundPreset: preset,
        ),
      ),
    );

    final t = PostStateStore.load(project.path);
    expect(t.canvas.backgroundKind, BackgroundKind.preset);
    expect(t.canvas.backgroundPreset, preset);
  });

  test('a corrupt unified file falls back rather than refusing to open', () {
    unified().createSync(recursive: true);
    unified().writeAsStringSync('{ this is not json');
    writeLegacyClips();

    expect(
      PostStateStore.load(project.path).trackOfType<ClipTrack>(),
      isNotNull,
    );
  });

  test('two editors saving at once do not drop each other\'s work', () async {
    // The hazard unification introduces: clips, captions and canvas are written
    // by independent controllers that now share one file. If the read happened
    // outside the write queue both of these would see the same empty state, and
    // whichever landed second would win — the other edit gone, nothing logged.
    await Future.wait([
      PostStateStore.update(
        project.path,
        (t) => t.withTrack(
          const ClipTrack(
            clips: [
              Clip(
                id: 'a',
                sourceInMs: 0,
                sourceOutMs: 5000,
                timelineStartMs: 0,
              ),
            ],
          ),
        ),
      ),
      PostStateStore.update(
        project.path,
        (t) => t.withTrack(
          const CaptionTrack(
            captions: [Caption(id: 'c1', startMs: 0, endMs: 900, text: 'kept')],
          ),
        ),
      ),
    ]);

    final t = PostStateStore.load(project.path);
    expect(
      t.trackOfType<ClipTrack>()?.clips,
      hasLength(1),
      reason: 'the clip edit survived',
    );
    expect(
      t.trackOfType<CaptionTrack>()?.captions.single.text,
      'kept',
      reason: 'the caption edit survived the concurrent clip write',
    );
  });

  test('a mutation that throws leaves the previous state untouched', () async {
    await PostStateStore.save(project.path, const Timeline(durationMs: 42));
    await PostStateStore.update(project.path, (_) => throw StateError('boom'));
    expect(PostStateStore.load(project.path).durationMs, 42);
  });

  test(
    'concurrent saves on two spellings of one bundle do not interleave',
    () async {
      await Future.wait([
        PostStateStore.save(project.path, const Timeline(durationMs: 1)),
        PostStateStore.save('${project.path}/', const Timeline(durationMs: 2)),
        PostStateStore.save(project.path, const Timeline(durationMs: 3)),
      ]);

      final raw = jsonDecode(unified().readAsStringSync()) as Map;
      expect((raw['timeline'] as Map)['durationMs'], isIn([1, 2, 3]));
      expect(unified().existsSync(), isTrue);
      expect(File('${unified().path}.tmp').existsSync(), isFalse);
    },
  );
}
