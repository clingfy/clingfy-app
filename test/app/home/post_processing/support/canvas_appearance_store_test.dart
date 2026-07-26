import 'dart:convert';
import 'dart:io';

import 'package:clingfy/app/home/post_processing/support/canvas_appearance_store.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/timeline/model/color_grade.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory projectDir;

  setUp(() async {
    projectDir = await Directory.systemTemp.createTemp('clingfy_canvas_test_');
  });

  tearDown(() async {
    if (await projectDir.exists()) {
      await projectDir.delete(recursive: true);
    }
  });

  group('CanvasAppearanceStore', () {
    test('load returns null when no editor_state.json exists', () async {
      expect(CanvasAppearanceStore.load(projectDir.path), isNull);
    });

    test('round-trips a solid-color background', () async {
      const state = CanvasAppearanceState(
        padding: 48,
        cornerRadius: 16,
        backgroundKind: BackgroundKind.color,
        backgroundColorArgb: 0xFF8957E5,
        backgroundImagePath: null,
        backgroundPreset: null,
      );
      await CanvasAppearanceStore.save(projectDir.path, state);

      final loaded = CanvasAppearanceStore.load(projectDir.path);
      expect(loaded, isNotNull);
      expect(loaded!.padding, 48);
      expect(loaded.cornerRadius, 16);
      expect(loaded.backgroundKind, BackgroundKind.color);
      expect(loaded.backgroundColorArgb, 0xFF8957E5);
      expect(loaded.backgroundImagePath, isNull);
      expect(loaded.backgroundPreset, isNull);
    });

    test('round-trips a preset background', () async {
      const preset = CanvasBackgroundPreset(
        id: 'abstractWaves',
        palette: 'sunset',
        intensity: 0.8,
        blur: 0.25,
        seed: 1234,
      );
      const state = CanvasAppearanceState(
        padding: 0,
        cornerRadius: 0,
        backgroundKind: BackgroundKind.preset,
        backgroundColorArgb: null,
        backgroundImagePath: null,
        backgroundPreset: preset,
      );
      await CanvasAppearanceStore.save(projectDir.path, state);

      final loaded = CanvasAppearanceStore.load(projectDir.path);
      expect(loaded!.backgroundKind, BackgroundKind.preset);
      expect(loaded.backgroundPreset, preset);
    });

    test('writes editor_state.json at the project root', () async {
      const state = CanvasAppearanceState(
        padding: 1,
        cornerRadius: 2,
        backgroundKind: BackgroundKind.color,
        backgroundColorArgb: null,
        backgroundImagePath: null,
        backgroundPreset: null,
      );
      await CanvasAppearanceStore.save(projectDir.path, state);
      expect(
        await File('${projectDir.path}/editor_state.json').exists(),
        isTrue,
      );
    });

    test('load returns null for a malformed file', () async {
      await File(
        '${projectDir.path}/editor_state.json',
      ).writeAsString('not json {');
      expect(CanvasAppearanceStore.load(projectDir.path), isNull);
    });

    test('round-trips the color grade alongside the canvas', () async {
      const state = CanvasAppearanceState(
        padding: 24,
        cornerRadius: 8,
        backgroundKind: BackgroundKind.color,
        backgroundColorArgb: null,
        backgroundImagePath: null,
        backgroundPreset: null,
        colorGrade: ColorGrade(
          autoEnabled: true,
          exposure: 0.4,
          contrast: -0.2,
          saturation: 0.1,
          temperature: -0.3,
          tint: 0.05,
        ),
      );
      await CanvasAppearanceStore.save(projectDir.path, state);

      final loaded = CanvasAppearanceStore.load(projectDir.path);
      expect(loaded, isNotNull);
      expect(loaded!.colorGrade.autoEnabled, isTrue);
      expect(loaded.colorGrade.exposure, 0.4);
      expect(loaded.colorGrade.contrast, -0.2);
      expect(loaded.colorGrade.saturation, 0.1);
      expect(loaded.colorGrade.temperature, -0.3);
      expect(loaded.colorGrade.tint, 0.05);
    });

    test('defaults to the neutral grade when omitted', () async {
      const state = CanvasAppearanceState(
        padding: 0,
        cornerRadius: 0,
        backgroundKind: BackgroundKind.color,
        backgroundColorArgb: null,
        backgroundImagePath: null,
        backgroundPreset: null,
      );
      await CanvasAppearanceStore.save(projectDir.path, state);

      final loaded = CanvasAppearanceStore.load(projectDir.path);
      expect(loaded!.colorGrade, const ColorGrade());
      expect(loaded.colorGrade.isIdentity, isTrue);
    });

    test('reads a v1 file (no colorGrade key) as the neutral grade', () async {
      // A recording last edited before color persistence: the on-disk file has
      // no `colorGrade` key. It must still load, falling back to neutral.
      final v1 = jsonEncode({
        'version': 1,
        'padding': 12.0,
        'cornerRadius': 4.0,
        'background': {
          'kind': 'color',
          'colorArgb': 0xFF112233,
          'imagePath': null,
          'preset': null,
        },
      });
      await File('${projectDir.path}/editor_state.json').writeAsString(v1);

      final loaded = CanvasAppearanceStore.load(projectDir.path);
      expect(loaded, isNotNull);
      expect(loaded!.padding, 12.0);
      expect(loaded.backgroundColorArgb, 0xFF112233);
      expect(loaded.colorGrade, const ColorGrade());
    });

    test('overlapping saves serialize; the last writer wins intact', () async {
      // Callers fire-and-forget these writes, and one user action can produce
      // two in the same turn. writeAsString opens truncating, so unserialized
      // overlap could leave a short payload plus the tail of a longer one —
      // unparseable JSON, which load() turns into "all settings lost".
      const short = CanvasAppearanceState(
        padding: 0,
        cornerRadius: 0,
        backgroundKind: BackgroundKind.color,
        backgroundColorArgb: null,
        backgroundImagePath: null,
        backgroundPreset: null,
      );
      const long = CanvasAppearanceState(
        padding: 48,
        cornerRadius: 16,
        backgroundKind: BackgroundKind.image,
        backgroundColorArgb: 0xFF8957E5,
        backgroundImagePath:
            '/some/deliberately/long/background/image/path.png',
        backgroundPreset: null,
        colorGrade: ColorGrade(
          autoEnabled: true,
          exposure: 0.25,
          contrast: -0.125,
          saturation: 0.5,
          temperature: -0.375,
          tint: 0.0625,
        ),
      );

      // Issue both without awaiting, the way the controller does.
      final first = CanvasAppearanceStore.save(projectDir.path, long);
      final second = CanvasAppearanceStore.save(projectDir.path, short);
      await Future.wait([first, second]);

      final loaded = CanvasAppearanceStore.load(projectDir.path);
      expect(loaded, isNotNull, reason: 'the file must still parse');
      expect(loaded!.padding, 0);
      expect(loaded.backgroundImagePath, isNull);
      expect(loaded.colorGrade, const ColorGrade());
    });

    test('a failed write does not poison the queue for that path', () async {
      const state = CanvasAppearanceState(
        padding: 7,
        cornerRadius: 0,
        backgroundKind: BackgroundKind.color,
        backgroundColorArgb: null,
        backgroundImagePath: null,
        backgroundPreset: null,
      );
      final missing = '${projectDir.path}${Platform.pathSeparator}missing';

      // The directory does not exist yet, so both writes fail inside the
      // chain — and they OVERLAP, so the second is queued behind a failing
      // link. Both must still resolve; a rejected link would stall every
      // later save for this recording.
      final first = CanvasAppearanceStore.save(missing, state);
      final second = CanvasAppearanceStore.save(missing, state);
      await Future.wait([first, second]);
      expect(CanvasAppearanceStore.load(missing), isNull);

      await Directory(missing).create();
      const next = CanvasAppearanceState(
        padding: 21,
        cornerRadius: 0,
        backgroundKind: BackgroundKind.color,
        backgroundColorArgb: null,
        backgroundImagePath: null,
        backgroundPreset: null,
      );
      await CanvasAppearanceStore.save(missing, next);

      expect(CanvasAppearanceStore.load(missing)?.padding, 21);
    });

    test('writes to different projects do not block each other', () async {
      final other = await Directory.systemTemp.createTemp('clingfy_canvas_b_');
      addTearDown(() async {
        if (await other.exists()) await other.delete(recursive: true);
      });

      CanvasAppearanceState stateFor(double padding) => CanvasAppearanceState(
        padding: padding,
        cornerRadius: 0,
        backgroundKind: BackgroundKind.color,
        backgroundColorArgb: null,
        backgroundImagePath: null,
        backgroundPreset: null,
      );

      final a = CanvasAppearanceStore.save(projectDir.path, stateFor(3));
      final b = CanvasAppearanceStore.save(other.path, stateFor(9));
      await Future.wait([a, b]);

      // Each project keeps its own queue — neither clobbers the other.
      expect(CanvasAppearanceStore.load(projectDir.path)!.padding, 3);
      expect(CanvasAppearanceStore.load(other.path)!.padding, 9);
    });

    test('the last of many overlapping saves is the one on disk', () async {
      CanvasAppearanceState stateFor(double padding) => CanvasAppearanceState(
        padding: padding,
        cornerRadius: 0,
        backgroundKind: BackgroundKind.color,
        backgroundColorArgb: null,
        backgroundImagePath: null,
        backgroundPreset: null,
      );

      final writes = <Future<void>>[
        for (var i = 1; i <= 8; i++)
          CanvasAppearanceStore.save(projectDir.path, stateFor(i.toDouble())),
      ];
      await Future.wait(writes);

      final loaded = CanvasAppearanceStore.load(projectDir.path);
      expect(loaded, isNotNull);
      expect(loaded!.padding, 8);
    });
  });
}
