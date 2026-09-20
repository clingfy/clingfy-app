import 'package:clingfy/core/timeline/commands/set_captions_command.dart';
import 'package:clingfy/core/timeline/edit_command.dart';
import 'package:clingfy/core/timeline/edit_session.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter_test/flutter_test.dart';

/// The caption track's undo command.
///
/// Before this existed, `EditDomain.captions` had zero producers: a corrected
/// cue could not be undone at all, while the bar directly above the panel
/// showed Undo/Redo for Zoom, Clips and Color.
void main() {
  Caption cue(String id, String text) =>
      Caption(id: id, startMs: 0, endMs: 1000, text: text);

  group('SetCaptionsCommand', () {
    test('apply sets the next cues, revert restores the previous', () {
      var cues = [cue('c1', 'machine text')];
      final cmd = SetCaptionsCommand(
        get: () => cues,
        set: (next) => cues = next,
        next: [cue('c1', 'corrected text')],
      );

      cmd.apply();
      expect(cues.single.text, 'corrected text');

      cmd.revert();
      expect(cues.single.text, 'machine text');
    });

    test('reports the captions domain', () {
      var cues = <Caption>[];
      final cmd = SetCaptionsCommand(
        get: () => cues,
        set: (next) => cues = next,
        next: [cue('c1', 'hello')],
      );
      expect(cmd.domain, EditDomain.captions);
    });

    test('reverts a wholesale replacement, not just one cue', () {
      // The destructive edit users actually hit is "Generate again", which
      // replaces the track. A per-cue command could not undo it.
      var cues = [cue('c1', 'mine one'), cue('c2', 'mine two')];
      final cmd = SetCaptionsCommand(
        get: () => cues,
        set: (next) => cues = next,
        next: [cue('g1', 'machine one')],
      );

      cmd.apply();
      expect(cues, hasLength(1));
      expect(cues.single.id, 'g1');

      cmd.revert();
      expect(cues.map((c) => c.text), ['mine one', 'mine two']);
    });

    test('the snapshot is taken at construction, not at revert', () {
      // The holder keeps mutating its own list; the command must restore what
      // was there when it was built.
      var cues = [cue('c1', 'first')];
      final cmd = SetCaptionsCommand(
        get: () => cues,
        set: (next) => cues = next,
        next: [cue('c1', 'second')],
      );
      cues = [cue('c1', 'someone else wrote this')];

      cmd.revert();
      expect(cues.single.text, 'first');
    });

    test('a reverted list is mutable by the holder', () {
      // The command stores an unmodifiable view; handing that back would make
      // the next correction throw instead of editing.
      var cues = [cue('c1', 'before')];
      final cmd = SetCaptionsCommand(
        get: () => cues,
        set: (next) => cues = next,
        next: [cue('c1', 'after')],
      );

      cmd.apply();
      expect(() => cues.add(cue('c2', 'appended')), returnsNormally);
      cmd.revert();
      expect(() => cues.add(cue('c3', 'appended')), returnsNormally);
    });

    test('round-trips through EditSession undo/redo and flushes captions', () {
      var cues = [cue('c1', 'machine text')];
      final flushed = <Set<EditDomain>>[];
      final session = EditSession(onFlush: flushed.add);

      session.execute(
        SetCaptionsCommand(
          get: () => cues,
          set: (next) => cues = next,
          next: [cue('c1', 'corrected text')],
        ),
      );
      expect(cues.single.text, 'corrected text');
      expect(flushed.last, contains(EditDomain.captions));

      session.undo();
      expect(cues.single.text, 'machine text');
      expect(session.canRedo, isTrue);

      session.redo();
      expect(cues.single.text, 'corrected text');
    });
  });
}
