import 'package:clingfy/core/captions/subtitle_serializer.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sidecar subtitle output.
///
/// The failures these pin are all silent: a stray blank line, an out-of-order
/// cue, or a comma where a period belongs does not throw — the player just
/// shows fewer subtitles than the file contains, or none at all.
void main() {
  Caption cue(int startMs, int endMs, String text, {String id = 'c'}) =>
      Caption(id: id, startMs: startMs, endMs: endMs, text: text);

  // ---- SubRip ----------------------------------------------------------

  test('srt is numbered from one with comma decimals', () {
    final srt = SubtitleSerializer.toSrt([
      cue(0, 1500, 'hello there'),
      cue(1500, 3000, 'second line'),
    ]);

    expect(srt, '''
1
00:00:00,000 --> 00:00:01,500
hello there

2
00:00:01,500 --> 00:00:03,000
second line

''');
  });

  test('srt numbering counts written cues, not input cues', () {
    // A dropped cue must not leave a gap in the sequence — several parsers
    // treat a non-monotonic index as the end of the file.
    final srt = SubtitleSerializer.toSrt([
      cue(0, 1000, 'first'),
      cue(1000, 2000, '   '),
      cue(2000, 3000, 'third'),
    ]);

    expect(srt.split('\n').first, '1');
    expect(srt, contains('\n2\n'));
    expect(srt, isNot(contains('\n3\n')));
    expect(srt, contains('third'));
  });

  test('hours are carried, not wrapped', () {
    final srt = SubtitleSerializer.toSrt([cue(3661234, 3662000, 'an hour in')]);
    expect(srt, contains('01:01:01,234 --> 01:01:02,000'));
  });

  test('a recording longer than a day keeps its real hour count', () {
    // Not clamped to two digits: relocating a cue is worse than an odd-looking
    // timestamp, and this only ever appears from corrupt input anyway.
    final srt = SubtitleSerializer.toSrt([cue(360000000, 360001000, 'late')]);
    expect(srt, contains('100:00:00,000'));
  });

  // ---- WebVTT ----------------------------------------------------------

  test('vtt leads with the header and uses period decimals', () {
    final vtt = SubtitleSerializer.toWebVtt([cue(0, 1500, 'hello there')]);

    expect(vtt, '''
WEBVTT

00:00:00.000 --> 00:00:01.500
hello there

''');
  });

  test('vtt omits cue identifiers', () {
    // An identifier line containing "-->" is a parse error, and ids here come
    // from a transcription engine.
    final vtt = SubtitleSerializer.toWebVtt([
      cue(0, 1000, 'hello', id: 'seg-->1'),
    ]);
    expect(vtt, isNot(contains('seg')));
  });

  test('an empty track still produces a valid vtt file', () {
    expect(SubtitleSerializer.toWebVtt(const []), 'WEBVTT\n\n');
    expect(SubtitleSerializer.toSrt(const []), isEmpty);
  });

  // ---- Cue hygiene -----------------------------------------------------

  test('a blank line inside cue text is collapsed, not written', () {
    // This is the one that silently truncates the file: everything after the
    // stray blank line is read as a malformed cue and dropped.
    final srt = SubtitleSerializer.toSrt([
      cue(0, 1000, 'first half\n\nsecond half'),
      cue(1000, 2000, 'survivor'),
    ]);

    expect(srt, contains('first half\nsecond half'));
    expect(
      srt,
      contains('survivor'),
      reason: 'the cue after a multi-line one must still be written',
    );
    expect(srt.split('\n\n').where((b) => b.isNotEmpty), hasLength(2));
  });

  test('an arrow inside cue text cannot be read as a timing line', () {
    // Cue text is editable in the caption editor, so "a --> b" needs no unusual
    // transcription to reach. Left alone it reads as a timing line to SRT and
    // as a malformed cue to strict WebVTT parsers.
    final srt = SubtitleSerializer.toSrt([
      cue(0, 1000, 'press A --> B to continue'),
      cue(1000, 2000, 'survivor'),
    ]);

    expect(srt, isNot(contains('A --> B')));
    expect(srt, contains('press A → B to continue'));
    expect(
      '\n$srt'.split('\n').where((l) => l.contains('-->')),
      hasLength(2),
      reason: 'only the two real timing lines may contain the arrow',
    );
    expect(srt, contains('survivor'));

    final vtt = SubtitleSerializer.toWebVtt([
      cue(0, 1000, 'press A --> B to continue'),
    ]);
    expect('\n$vtt'.split('\n').where((l) => l.contains('-->')), hasLength(1));
  });

  test('windows and classic-mac newlines inside text are normalised', () {
    final srt = SubtitleSerializer.toSrt([cue(0, 1000, 'a\r\nb\rc')]);
    expect(srt, contains('a\nb\nc'));
    expect(srt, isNot(contains('\r')));
  });

  test('a whitespace-only cue is dropped rather than shown blank', () {
    // A blank cue is not harmless: while it is on screen it suppresses
    // whatever the player would otherwise display.
    for (final blank in ['', '   ', '\n', '\n\n', '\t']) {
      expect(
        SubtitleSerializer.toSrt([cue(0, 1000, blank)]),
        isEmpty,
        reason: 'blank: ${blank.codeUnits}',
      );
    }
  });

  test('cue text is trimmed per line', () {
    final vtt = SubtitleSerializer.toWebVtt([cue(0, 1000, '  padded  ')]);
    expect(vtt, contains('\npadded\n'));
  });

  test('interleaved cues from two audio sources come out in order', () {
    // Mic and system transcripts are merged, so the input arrives unsorted.
    // Both formats leave out-of-order cues undefined; some players stop at the
    // first backwards jump.
    final srt = SubtitleSerializer.toSrt([
      cue(4000, 5000, 'third'),
      cue(0, 1000, 'first'),
      cue(2000, 3000, 'second'),
    ]);

    expect(srt.indexOf('first'), lessThan(srt.indexOf('second')));
    expect(srt.indexOf('second'), lessThan(srt.indexOf('third')));
    expect(srt, startsWith('1\n00:00:00,000'));
  });

  test('cues starting together are ordered by end time', () {
    final srt = SubtitleSerializer.toSrt([
      cue(1000, 5000, 'longer'),
      cue(1000, 2000, 'shorter'),
    ]);
    expect(srt.indexOf('shorter'), lessThan(srt.indexOf('longer')));
  });

  test('a zero-length cue is given a frame rather than dropped', () {
    // The words were really transcribed there; a flash is more honest than
    // silence, and a zero-length cue displays for zero time.
    final srt = SubtitleSerializer.toSrt([cue(1000, 1000, 'blink')]);
    expect(srt, contains('00:00:01,000 --> 00:00:01,016'));
  });

  test('an inverted cue is repaired, not written backwards', () {
    final srt = SubtitleSerializer.toSrt([cue(2000, 1000, 'backwards')]);
    expect(srt, contains('00:00:02,000 --> 00:00:02,016'));
    expect(srt, isNot(contains('--> 00:00:01,000')));
  });

  test('a negative start time is dropped', () {
    expect(SubtitleSerializer.toSrt([cue(-500, 1000, 'impossible')]), isEmpty);
  });

  test('overlapping cues are both kept', () {
    // Overlap is legal in both formats and real in a two-speaker recording;
    // dropping one would silently lose a side of the conversation.
    final srt = SubtitleSerializer.toSrt([
      cue(0, 3000, 'speaker one'),
      cue(1000, 4000, 'speaker two'),
    ]);
    expect(srt, contains('speaker one'));
    expect(srt, contains('speaker two'));
  });

  test('non-latin text passes through unchanged', () {
    const arabic = 'مرحبا بالعالم';
    expect(SubtitleSerializer.toSrt([cue(0, 1000, arabic)]), contains(arabic));
    expect(
      SubtitleSerializer.toWebVtt([cue(0, 1000, arabic)]),
      contains(arabic),
    );
  });

  // ---- Mode ------------------------------------------------------------

  test('mode flags say what each destination does', () {
    expect(SubtitleMode.none.burnsIn, isFalse);
    expect(SubtitleMode.none.writesSidecar, isFalse);
    expect(SubtitleMode.burnIn.burnsIn, isTrue);
    expect(SubtitleMode.burnIn.writesSidecar, isFalse);
    expect(SubtitleMode.sidecar.burnsIn, isFalse);
    expect(SubtitleMode.sidecar.writesSidecar, isTrue);
    expect(SubtitleMode.both.burnsIn, isTrue);
    expect(SubtitleMode.both.writesSidecar, isTrue);
  });

  test('mode survives a wire round trip', () {
    for (final mode in SubtitleMode.values) {
      expect(SubtitleMode.fromWire(mode.wireValue), mode);
    }
  });

  test('an unknown stored mode falls back to burn-in', () {
    // Burn-in is the safe default: a subtitle that is part of the video cannot
    // be lost by a platform that strips sidecars.
    expect(SubtitleMode.fromWire('nonsense'), SubtitleMode.burnIn);
    expect(SubtitleMode.fromWire(null), SubtitleMode.burnIn);
  });
}
