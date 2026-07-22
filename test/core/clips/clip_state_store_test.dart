import 'dart:io';

import 'package:clingfy/core/clips/clip_state_store.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory projectDir;

  setUp(() async {
    projectDir = await Directory.systemTemp.createTemp('clingfy_clips_test_');
  });

  tearDown(() async {
    if (await projectDir.exists()) {
      await projectDir.delete(recursive: true);
    }
  });

  group('ClipStateStore', () {
    test('load returns null when no clips_state.json exists', () {
      expect(ClipStateStore.load(projectDir.path), isNull);
    });

    test('round-trips a clip list', () async {
      const state = ClipPersistState(
        recordingDurationMs: 10000,
        clips: [
          Clip(
            id: 'clip_0',
            sourceInMs: 0,
            sourceOutMs: 4000,
            timelineStartMs: 0,
          ),
          Clip(
            id: 'clip_1',
            sourceInMs: 4000,
            sourceOutMs: 10000,
            timelineStartMs: 4000,
          ),
        ],
      );
      await ClipStateStore.save(projectDir.path, state);

      final loaded = ClipStateStore.load(projectDir.path);
      expect(loaded, isNotNull);
      expect(loaded!.recordingDurationMs, 10000);
      expect(loaded.clips, hasLength(2));
      expect(loaded.clips.first.id, 'clip_0');
      expect(loaded.clips.first.sourceOutMs, 4000);
      expect(loaded.clips.last.sourceInMs, 4000);
    });

    test('writes clips_state.json at the project root', () async {
      const state = ClipPersistState(
        recordingDurationMs: 5000,
        clips: [
          Clip(
            id: 'clip_0',
            sourceInMs: 0,
            sourceOutMs: 5000,
            timelineStartMs: 0,
          ),
        ],
      );
      await ClipStateStore.save(projectDir.path, state);
      expect(
        await File('${projectDir.path}/clips_state.json').exists(),
        isTrue,
      );
    });

    test('load returns null for a malformed file', () async {
      await File(
        '${projectDir.path}/clips_state.json',
      ).writeAsString('not json {');
      expect(ClipStateStore.load(projectDir.path), isNull);
    });

    test('load returns null for an empty clip list', () async {
      await File('${projectDir.path}/clips_state.json').writeAsString(
        '{"version": 1, "recordingDurationMs": 10000, "clips": []}',
      );
      expect(ClipStateStore.load(projectDir.path), isNull);
    });
  });
}
