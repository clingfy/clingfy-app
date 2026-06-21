import 'package:flutter_test/flutter_test.dart';
import 'package:clingfy/core/timeline/edit_command.dart';
import 'package:clingfy/core/timeline/edit_session.dart';

/// Records apply/revert order so tests can assert exact command sequencing.
class _RecordingCommand implements EditCommand {
  _RecordingCommand(this.id, this.log, {this.domain = EditDomain.zoom});

  final String id;
  final List<String> log;

  @override
  final EditDomain domain;

  @override
  String get label => 'cmd-$id';

  int applyCount = 0;
  int revertCount = 0;

  @override
  void apply() {
    applyCount++;
    log.add('apply:$id');
  }

  @override
  void revert() {
    revertCount++;
    log.add('revert:$id');
  }
}

void main() {
  group('EditSession', () {
    test('execute applies, records undo, and flushes the dirty domain', () {
      final log = <String>[];
      final flushed = <Set<EditDomain>>[];
      final session = EditSession(onFlush: flushed.add);
      final cmd = _RecordingCommand('a', log, domain: EditDomain.captions);

      session.execute(cmd);

      expect(cmd.applyCount, 1);
      expect(session.canUndo, isTrue);
      expect(session.canRedo, isFalse);
      expect(flushed.single, {EditDomain.captions});
    });

    test('undo reverts and moves the command to the redo stack', () {
      final log = <String>[];
      final session = EditSession();
      session.execute(_RecordingCommand('a', log));

      session.undo();

      expect(session.canUndo, isFalse);
      expect(session.canRedo, isTrue);
      expect(log, ['apply:a', 'revert:a']);
    });

    test('redo re-applies the command', () {
      final log = <String>[];
      final session = EditSession();
      session.execute(_RecordingCommand('a', log));
      session.undo();

      session.redo();

      expect(session.canRedo, isFalse);
      expect(session.canUndo, isTrue);
      expect(log, ['apply:a', 'revert:a', 'apply:a']);
    });

    test('executing a new command clears the redo stack', () {
      final log = <String>[];
      final session = EditSession();
      session.execute(_RecordingCommand('a', log));
      session.undo();
      expect(session.canRedo, isTrue);

      session.execute(_RecordingCommand('b', log));

      expect(session.canRedo, isFalse);
      expect(session.canUndo, isTrue);
    });

    test('undo/redo with no history is a safe no-op', () {
      final session = EditSession();
      session.undo();
      session.redo();
      expect(session.canUndo, isFalse);
      expect(session.canRedo, isFalse);
    });

    test('flush reports each touched domain in execution order', () {
      final flushed = <Set<EditDomain>>[];
      final session = EditSession(onFlush: flushed.add);

      session.execute(_RecordingCommand('a', [], domain: EditDomain.audio));
      session.execute(_RecordingCommand('b', [], domain: EditDomain.color));

      expect(flushed, hasLength(2));
      expect(flushed[0], {EditDomain.audio});
      expect(flushed[1], {EditDomain.color});
    });

    group('batch', () {
      test('collapses executed commands into one history entry', () {
        final log = <String>[];
        final flushed = <Set<EditDomain>>[];
        final session = EditSession(onFlush: flushed.add);

        session.beginBatch();
        session.execute(_RecordingCommand('a', log));
        session.execute(_RecordingCommand('b', log));
        expect(session.isBatching, isTrue);
        expect(flushed, isEmpty); // no flush mid-batch
        session.endBatch();

        expect(log, ['apply:a', 'apply:b']);
        expect(session.canUndo, isTrue);
        expect(flushed, hasLength(1)); // single flush at endBatch
        expect(flushed.single, {EditDomain.zoom});

        session.undo();
        // one history entry reverts both, in reverse order
        expect(log, ['apply:a', 'apply:b', 'revert:b', 'revert:a']);
        expect(session.canUndo, isFalse);
        expect(session.canRedo, isTrue);

        session.redo();
        expect(log.sublist(4), ['apply:a', 'apply:b']);
      });

      test('endBatch with no commands records nothing', () {
        final session = EditSession();
        session.beginBatch();
        session.endBatch();
        expect(session.canUndo, isFalse);
      });

      test('cancelBatch reverts everything and records no history', () {
        final log = <String>[];
        final session = EditSession();
        session.beginBatch();
        session.execute(_RecordingCommand('a', log));
        session.execute(_RecordingCommand('b', log));

        session.cancelBatch();

        expect(log, ['apply:a', 'apply:b', 'revert:b', 'revert:a']);
        expect(session.canUndo, isFalse);
        expect(session.isBatching, isFalse);
      });

      test('nested batches record one entry at the outermost end', () {
        final log = <String>[];
        final session = EditSession();

        session.beginBatch();
        session.execute(_RecordingCommand('a', log));
        session.beginBatch();
        session.execute(_RecordingCommand('b', log));
        session.endBatch(); // inner: no entry yet
        expect(session.canUndo, isFalse);
        session.execute(_RecordingCommand('c', log));
        session.endBatch(); // outer: one entry for a, b, c

        expect(session.canUndo, isTrue);
        session.undo();
        expect(log, [
          'apply:a',
          'apply:b',
          'apply:c',
          'revert:c',
          'revert:b',
          'revert:a',
        ]);
      });
    });

    test('clear drops all history', () {
      final session = EditSession();
      session.execute(_RecordingCommand('a', []));
      session.undo();
      expect(session.canRedo, isTrue);

      session.clear();

      expect(session.canUndo, isFalse);
      expect(session.canRedo, isFalse);
    });
  });
}
