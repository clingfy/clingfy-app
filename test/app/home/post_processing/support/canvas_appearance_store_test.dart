import 'dart:io';

import 'package:clingfy/app/home/post_processing/support/canvas_appearance_store.dart';
import 'package:clingfy/core/models/app_models.dart';
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
  });
}
