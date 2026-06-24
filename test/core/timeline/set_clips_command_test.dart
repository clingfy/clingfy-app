import 'package:clingfy/core/timeline/clip_operations.dart';
import 'package:clingfy/core/timeline/clip_timeline.dart';
import 'package:clingfy/core/timeline/commands/set_clips_command.dart';
import 'package:clingfy/core/timeline/edit_command.dart';
import 'package:clingfy/core/timeline/edit_session.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SetClipsCommand', () {
    test('apply sets the next list; revert restores the previous', () {
      var clips = [ClipTimeline.wholeRecording(10000)];
      final next = ClipOperations.splitAt(clips, 4000, newId: 'c1');

      final cmd = SetClipsCommand(
        get: () => clips,
        set: (v) => clips = v,
        next: next,
        label: 'Split',
      );

      cmd.apply();
      expect(clips, hasLength(2));

      cmd.revert();
      expect(clips, hasLength(1));
      expect(clips.first.sourceOutMs, 10000);
    });

    test('reports the clips domain', () {
      var clips = <Clip>[ClipTimeline.wholeRecording(10000)];
      final cmd = SetClipsCommand(
        get: () => clips,
        set: (v) => clips = v,
        next: clips,
      );
      expect(cmd.domain, EditDomain.clips);
    });

    test(
      'drives undo/redo through EditSession and flushes the clips domain',
      () {
        var clips = [ClipTimeline.wholeRecording(10000)];
        final flushed = <Set<EditDomain>>[];
        final session = EditSession(onFlush: flushed.add);

        void run(List<Clip> next, String label) {
          session.execute(
            SetClipsCommand(
              get: () => clips,
              set: (v) => clips = v,
              next: next,
              label: label,
            ),
          );
        }

        run(ClipOperations.splitAt(clips, 4000, newId: 'c1'), 'Split');
        run(ClipOperations.remove(clips, 'clip_0'), 'Cut');

        expect(clips, hasLength(1));
        expect(clips.first.id, 'c1');
        expect(ClipTimeline.totalDurationMs(clips), 6000);

        session.undo(); // undo the cut
        expect(clips, hasLength(2));

        session.undo(); // undo the split
        expect(clips, hasLength(1));
        expect(clips.first.sourceOutMs, 10000);

        session.redo(); // redo the split
        expect(clips, hasLength(2));

        expect(flushed, isNotEmpty);
        expect(flushed.every((d) => d.contains(EditDomain.clips)), isTrue);
      },
    );

    test('snapshots are immutable copies, not references to live state', () {
      var clips = [ClipTimeline.wholeRecording(10000)];
      final cmd = SetClipsCommand(
        get: () => clips,
        set: (v) => clips = v,
        next: ClipOperations.splitAt(clips, 4000, newId: 'c1'),
      );
      // Mutating the holder after construction must not change what revert
      // restores — the command snapshotted the previous list by copy.
      clips = ClipOperations.splitAt(clips, 2000, newId: 'x');
      cmd.apply();
      cmd.revert();
      expect(clips, hasLength(1));
      expect(clips.first.sourceOutMs, 10000);
    });
  });
}
