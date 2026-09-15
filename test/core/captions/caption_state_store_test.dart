import 'dart:convert';
import 'dart:io';

import 'package:clingfy/core/captions/caption_state_store.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter_test/flutter_test.dart';

/// Transcript persistence.
///
/// This is the one piece of editor state that is expensive to recreate: minutes
/// of on-device compute, plus whatever corrections the user typed. The failure
/// mode that matters is a partially-restored track, which looks like subtitles
/// that stop halfway with nothing to explain why.
void main() {
  late Directory project;

  setUp(() async {
    project = await Directory.systemTemp.createTemp('clingfy_caps_store');
  });

  tearDown(() {
    if (project.existsSync()) project.deleteSync(recursive: true);
  });

  File file() => File('${project.path}/captions_state.json');

  Caption cue(String id, String text, {int startMs = 0, int endMs = 1000}) =>
      Caption(id: id, startMs: startMs, endMs: endMs, text: text);

  // ---- Round trip -------------------------------------------------------

  test('a saved transcript reloads intact', () async {
    await CaptionStateStore.save(
      project.path,
      CaptionPersistState(
        captions: [
          cue('c1', 'hello there'),
          cue('c2', 'second', startMs: 1000, endMs: 2500),
        ],
      ),
    );

    final loaded = CaptionStateStore.load(project.path);
    expect(loaded, isNotNull);
    expect(loaded!.captions, hasLength(2));
    expect(loaded.captions.first.id, 'c1');
    expect(loaded.captions.first.text, 'hello there');
    expect(loaded.captions.last.startMs, 1000);
    expect(loaded.captions.last.endMs, 2500);
  });

  test('word timings survive the round trip', () async {
    // Cut-reflow needs these. Dropping them on save would break re-cutting a
    // recording that was transcribed in an earlier session.
    await CaptionStateStore.save(
      project.path,
      CaptionPersistState(
        captions: [
          Caption(
            id: 'c1',
            startMs: 0,
            endMs: 1000,
            text: 'hello world',
            words: const [
              CaptionWord(startMs: 0, endMs: 400, text: 'hello'),
              CaptionWord(startMs: 400, endMs: 1000, text: 'world'),
            ],
          ),
        ],
      ),
    );

    final loaded = CaptionStateStore.load(project.path);
    expect(loaded!.captions.first.words, hasLength(2));
    expect(loaded.captions.first.words.last.text, 'world');
    expect(loaded.captions.first.words.last.startMs, 400);
  });

  test('non-latin text survives the round trip', () async {
    await CaptionStateStore.save(
      project.path,
      CaptionPersistState(captions: [cue('c1', 'مرحبا بالعالم')]),
    );
    expect(
      CaptionStateStore.load(project.path)!.captions.first.text,
      'مرحبا بالعالم',
    );
  });

  test('the language is recorded when known and omitted when not', () async {
    await CaptionStateStore.save(
      project.path,
      CaptionPersistState(captions: [cue('c1', 'hi')], language: 'en'),
    );
    expect(CaptionStateStore.load(project.path)!.language, 'en');

    await CaptionStateStore.save(
      project.path,
      CaptionPersistState(captions: [cue('c1', 'hi')]),
    );
    expect(CaptionStateStore.load(project.path)!.language, isNull);
    expect(file().readAsStringSync(), isNot(contains('language')));
  });

  // ---- Absence ----------------------------------------------------------

  test('a recording that was never transcribed loads nothing', () {
    expect(CaptionStateStore.load(project.path), isNull);
  });

  test(
    'an empty transcript deletes the file rather than writing one',
    () async {
      await CaptionStateStore.save(
        project.path,
        CaptionPersistState(captions: [cue('c1', 'hi')]),
      );
      expect(file().existsSync(), isTrue);

      await CaptionStateStore.save(
        project.path,
        const CaptionPersistState(captions: []),
      );

      expect(file().existsSync(), isFalse);
      expect(CaptionStateStore.load(project.path), isNull);
    },
  );

  test('deleting an already-absent transcript is harmless', () async {
    await CaptionStateStore.save(
      project.path,
      const CaptionPersistState(captions: []),
    );
    expect(file().existsSync(), isFalse);
  });

  // ---- Corruption -------------------------------------------------------

  test('unparseable json loads as no transcript, not a crash', () {
    file().writeAsStringSync('{ this is not json');
    expect(CaptionStateStore.load(project.path), isNull);
  });

  test('a cue missing an id fails the whole file, not just that cue', () {
    // Half a transcript is worse than none: the user sees subtitles that stop
    // partway with no reason to suspect the file.
    file().writeAsStringSync(
      jsonEncode({
        'version': 1,
        'captions': [
          {'id': 'c1', 'startMs': 0, 'endMs': 1000, 'text': 'kept?'},
          {'startMs': 1000, 'endMs': 2000, 'text': 'no id'},
        ],
      }),
    );
    expect(CaptionStateStore.load(project.path), isNull);
  });

  test('a cue missing its times fails the whole file', () {
    file().writeAsStringSync(
      jsonEncode({
        'version': 1,
        'captions': [
          {'id': 'c1', 'text': 'when?'},
        ],
      }),
    );
    expect(CaptionStateStore.load(project.path), isNull);
  });

  test('an empty cue id is treated as missing', () {
    // The edit path addresses cues by id; an empty one is uneditable.
    file().writeAsStringSync(
      jsonEncode({
        'version': 1,
        'captions': [
          {'id': '', 'startMs': 0, 'endMs': 1000, 'text': 'x'},
        ],
      }),
    );
    expect(CaptionStateStore.load(project.path), isNull);
  });

  test('a file from a newer build is refused rather than half-read', () {
    file().writeAsStringSync(
      jsonEncode({
        'version': CaptionPersistState.version + 1,
        'captions': [
          {'id': 'c1', 'startMs': 0, 'endMs': 1000, 'text': 'future'},
        ],
      }),
    );
    expect(CaptionStateStore.load(project.path), isNull);
  });

  test('a file with no version at all is refused', () {
    file().writeAsStringSync(
      jsonEncode({
        'captions': [
          {'id': 'c1', 'startMs': 0, 'endMs': 1000, 'text': 'x'},
        ],
      }),
    );
    expect(CaptionStateStore.load(project.path), isNull);
  });

  test('a non-list captions key is refused', () {
    file().writeAsStringSync(jsonEncode({'version': 1, 'captions': 'nope'}));
    expect(CaptionStateStore.load(project.path), isNull);
  });

  // ---- Concurrent writes -------------------------------------------------

  test(
    'overlapping saves leave valid json, not an interleaved fragment',
    () async {
      // A correction landing while a regeneration completes produces two writes
      // in the same turn. Without serialisation the shorter payload can be
      // followed by the tail of the longer one — unparseable, and the entire
      // transcript is discarded on load.
      final long = [
        for (var i = 0; i < 400; i++)
          cue(
            'c$i',
            'a rather long cue line number $i',
            startMs: i * 1000,
            endMs: i * 1000 + 900,
          ),
      ];
      final short = [cue('c1', 'tiny')];

      await Future.wait([
        CaptionStateStore.save(
          project.path,
          CaptionPersistState(captions: long),
        ),
        CaptionStateStore.save(
          project.path,
          CaptionPersistState(captions: short),
        ),
        CaptionStateStore.save(
          project.path,
          CaptionPersistState(captions: long),
        ),
      ]);

      final loaded = CaptionStateStore.load(project.path);
      expect(loaded, isNotNull, reason: 'the file must still parse');
      expect(
        loaded!.captions.length,
        anyOf(long.length, short.length),
        reason: 'one whole write must win, not a splice of two',
      );
    },
  );

  test('two spellings of the same bundle share one write queue', () async {
    // Same file, two path strings. Racing them through separate chains would
    // reintroduce exactly the interleaving the queue exists to prevent.
    final trailing = '${project.path}${Platform.pathSeparator}';
    final long = [
      for (var i = 0; i < 300; i++)
        cue(
          'c$i',
          'padding padding padding $i',
          startMs: i * 100,
          endMs: i * 100 + 90,
        ),
    ];

    await Future.wait([
      CaptionStateStore.save(project.path, CaptionPersistState(captions: long)),
      CaptionStateStore.save(
        trailing,
        CaptionPersistState(captions: [cue('c1', 'tiny')]),
      ),
    ]);

    expect(CaptionStateStore.load(project.path), isNotNull);
  });
}
