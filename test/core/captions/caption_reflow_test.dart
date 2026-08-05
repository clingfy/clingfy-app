import 'package:clingfy/core/captions/caption_reflow.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mapping a source-timed transcript onto an edited recording.
///
/// Every failure here is silent: a subtitle at the wrong moment, a line the
/// video never says, or a caption present in the sidecar and missing from the
/// picture. Nothing throws.
void main() {
  Caption cue(String id, int startMs, int endMs, [String text = 'line']) =>
      Caption(id: id, startMs: startMs, endMs: endMs, text: text);

  Clip clip(
    String id,
    int sourceInMs,
    int sourceOutMs, {
    int? timelineStartMs,
    bool enabled = true,
  }) => Clip(
    id: id,
    sourceInMs: sourceInMs,
    sourceOutMs: sourceOutMs,
    timelineStartMs: timelineStartMs ?? sourceInMs,
    enabled: enabled,
  );

  ReflowedCaptions reflow(List<Caption> captions, List<Clip> clips) =>
      CaptionReflow.reflow(captions: captions, clips: clips);

  // ---- Passthrough ------------------------------------------------------

  test('an empty clip list is passthrough, not "everything was cut"', () {
    // The controller sends `const []` whenever no clip editor is attached, and
    // native reads empty keptRanges as "write every frame at its source time".
    // Treating it as a total cut would delete the transcript on the most
    // common export there is.
    final out = reflow([cue('c1', 1000, 2000, 'Hello')], const []);

    expect(out.sidecar, hasLength(1));
    expect(out.sidecar.single.outputStartMs, 1000);
    expect(out.sidecar.single.outputEndMs, 2000);
    expect(out.burnIn.single.sourceStartMs, 1000);
    expect(out.sidecar.single.id, 'c1', reason: 'ids must not change');
  });

  test('a disabled clip occupies no room on the output timeline', () {
    // Keeping it would push every later caption forward by its length. The
    // all-disabled case below cannot catch this — there, either reading gives
    // the same answer.
    final out = reflow(
      [cue('c1', 7000, 8000)],
      [
        clip('cut', 0, 3000, enabled: false),
        clip('a', 3000, 5000),
        clip('b', 6000, 10000),
      ],
    );

    expect(
      out.sidecar.single.outputStartMs,
      3000,
      reason: '2000 + (7000-6000)',
    );
  });

  test('an all-disabled clip list is also passthrough', () {
    // Native drops disabled clips in fromFlutter, leaving keptRanges empty —
    // which it then treats as no edit at all and exports the whole recording.
    // Captions must agree with the frames, however surprising that rule is.
    final out = reflow(
      [cue('c1', 1000, 2000)],
      [
        clip('a', 0, 5000, enabled: false),
        clip('b', 5000, 9000, enabled: false),
      ],
    );

    expect(out.sidecar, hasLength(1));
    expect(out.sidecar.single.outputStartMs, 1000);
  });

  test('one clip covering the whole recording changes nothing', () {
    final out = reflow(
      [cue('c1', 1000, 2000), cue('c2', 5000, 6000)],
      [clip('a', 0, 10000)],
    );

    expect(out.sidecar.map((s) => s.outputStartMs), [1000, 5000]);
    expect(out.sidecar.map((s) => s.id), ['c1', 'c2']);
  });

  test('no captions produces nothing at all', () {
    expect(reflow(const [], [clip('a', 0, 10000)]).isEmpty, isTrue);
  });

  // ---- Cuts -------------------------------------------------------------

  test('a cut before a cue pulls it earlier by the removed amount', () {
    // Removes source [0,3000). A cue at 5000 must land at 2000 in the file.
    final out = reflow([cue('c1', 5000, 6000)], [clip('a', 3000, 10000)]);

    expect(out.sidecar.single.outputStartMs, 2000);
    expect(out.sidecar.single.outputEndMs, 3000);
    expect(
      out.burnIn.single.sourceStartMs,
      5000,
      reason: 'burn-in stays in source time — native looks cues up by it',
    );
  });

  test('a cue inside cut-away footage disappears entirely', () {
    final out = reflow(
      [cue('gone', 4000, 4900), cue('kept', 7000, 8000)],
      [clip('a', 0, 3000), clip('b', 6000, 10000)],
    );

    expect(out.sidecar.map((s) => s.cueId), ['kept']);
    expect(
      out.burnIn.map((s) => s.cueId),
      ['kept'],
      reason: 'a removed cue must not be rasterised either',
    );
  });

  test('a cut between two cues compacts the gap', () {
    // Keep [0,2000) and [8000,10000): output length 4000.
    final out = reflow(
      [cue('c1', 500, 1500), cue('c2', 8500, 9500)],
      [clip('a', 0, 2000), clip('b', 8000, 10000)],
    );

    expect(out.sidecar.map((s) => s.outputStartMs), [500, 2500]);
    expect(out.sidecar.map((s) => s.outputEndMs), [1500, 3500]);
  });

  // ---- Splits that delete nothing ---------------------------------------

  test('bare splits do not multiply a cue across seams that do not exist', () {
    // Splitting produces source-ADJACENT clips and removes nothing, so the
    // exported file is identical to the unedited recording. Native coalesces
    // them; without doing the same here, a cue spanning both split points
    // would be written to the sidecar three times over uncut footage.
    final out = reflow(
      [cue('c1', 1000, 9000, 'One long sentence.')],
      [clip('a', 0, 3000), clip('b', 3000, 6000), clip('c', 6000, 10000)],
    );

    expect(out.sidecar, hasLength(1));
    expect(out.sidecar.single.outputStartMs, 1000);
    expect(out.sidecar.single.outputEndMs, 9000);
    expect(out.burnIn, hasLength(1));
    expect(out.sidecar.single.id, 'c1', reason: 'no suffix when unsplit');
  });

  test('a cue sliced by a real cut is one continuous subtitle in the file', () {
    // Removes source [5000,5500). The two surviving pieces are adjacent in the
    // output, so writing them as two identical cues back to back would repeat
    // the line for no visible reason.
    final out = reflow(
      [cue('c1', 4000, 6000, 'Thanks for watching')],
      [clip('a', 0, 5000), clip('b', 5500, 10000)],
    );

    expect(out.sidecar, hasLength(1));
    expect(out.sidecar.single.outputStartMs, 4000);
    expect(out.sidecar.single.outputEndMs, 5500);
  });

  test('the burn-in keeps both source pieces of a sliced cue', () {
    // They are NOT contiguous in source — the cut footage sits between them —
    // so native needs both to composite the caption on both sides.
    final out = reflow(
      [cue('c1', 4000, 6000)],
      [clip('a', 0, 5000), clip('b', 5500, 10000)],
    );

    expect(out.burnIn, hasLength(2));
    expect(out.burnIn.map((s) => (s.sourceStartMs, s.sourceEndMs)), [
      (4000, 5000),
      (5500, 6000),
    ]);
    expect(
      out.burnIn.map((s) => s.id).toSet(),
      hasLength(2),
      reason: 'distinct ids or the two bitmaps overwrite each other',
    );
    expect(out.burnIn.every((s) => s.cueId == 'c1'), isTrue);
  });

  // ---- Reorder ----------------------------------------------------------

  test('reorder places cues by list order, not by source order', () {
    // The tail plays first. Output base is the running sum of preceding clip
    // durations in LIST order — timelineStartMs is not consulted.
    final out = reflow(
      [
        cue('early', 1000, 2000, 'first in source'),
        cue('late', 7000, 8000, 'last in source'),
      ],
      [clip('b', 6000, 10000), clip('a', 0, 4000)],
    );

    final byCue = {for (final s in out.sidecar) s.cueId: s};
    expect(byCue['late']!.outputStartMs, 1000, reason: '7000 - 6000');
    expect(byCue['early']!.outputStartMs, 5000, reason: '4000 + 1000');
    expect(
      out.sidecar.map((s) => s.cueId),
      ['late', 'early'],
      reason: 'sorted by output time so the SRT reads forwards',
    );
  });

  test('a stale timelineStartMs does not move a caption', () {
    // Native ignores the field entirely and derives the base from the running
    // sum. Reading it here would drift from the frames whenever the clip list
    // is not normalised.
    final out = reflow(
      [cue('c1', 7000, 8000)],
      [
        clip('a', 0, 2000, timelineStartMs: 99999),
        clip('b', 6000, 10000, timelineStartMs: 12345),
      ],
    );

    expect(
      out.sidecar.single.outputStartMs,
      3000,
      reason: '2000 + (7000-6000)',
    );
  });

  // ---- Overlapping source windows ---------------------------------------

  test('overlapping clips never yield overlapping burn-in spans', () {
    // Trimming a clip's start edge past a split point leaves two clips over the
    // same source moment. Two spans of one cue would then overlap in source,
    // and Swift's CaptionCueTrack drops the second — losing it from the video
    // while the sidecar still lists it.
    final out = reflow(
      [cue('c1', 2000, 5000)],
      [clip('b', 3000, 10000), clip('a', 0, 4000)],
    );

    for (var i = 1; i < out.burnIn.length; i++) {
      expect(
        out.burnIn[i].sourceStartMs,
        greaterThanOrEqualTo(out.burnIn[i - 1].sourceEndMs),
        reason: 'CaptionCueTrack silently rejects an overlapping cue',
      );
    }
    expect(out.burnIn, isNotEmpty);
  });

  test('an overlapping pair merges to the union of its source range', () {
    final out = reflow(
      [cue('c1', 2000, 5000)],
      [clip('b', 3000, 10000), clip('a', 0, 4000)],
    );

    expect(out.burnIn, hasLength(1));
    expect(out.burnIn.single.sourceStartMs, 2000);
    expect(out.burnIn.single.sourceEndMs, 5000);
  });

  test('two different cues never overlap in the burn-in track', () {
    final out = reflow(
      [cue('c1', 0, 2000), cue('c2', 2000, 4000), cue('c3', 4000, 6000)],
      [clip('a', 1000, 5000)],
    );

    for (var i = 1; i < out.burnIn.length; i++) {
      expect(
        out.burnIn[i].sourceStartMs,
        greaterThanOrEqualTo(out.burnIn[i - 1].sourceEndMs),
      );
    }
  });

  // ---- Text -------------------------------------------------------------

  test('text is never rebuilt from word timings', () {
    // Word lists carry no punctuation or casing, their timings are not clamped
    // to the parent cue, and a merged two-speaker cue holds two concatenated
    // word lists — joining a filtered subset of that can produce a sentence
    // neither person said. Trimming text is a separate change.
    final withWords = Caption(
      id: 'c1',
      startMs: 4000,
      endMs: 6000,
      text: "Hello, world — it's me.",
      words: const [
        CaptionWord(startMs: 4000, endMs: 4500, text: 'Hello'),
        CaptionWord(startMs: 4500, endMs: 5000, text: 'world'),
        CaptionWord(startMs: 5000, endMs: 5400, text: "it's"),
        CaptionWord(startMs: 5400, endMs: 5800, text: 'me'),
      ],
    );

    final unedited = reflow([withWords], [clip('a', 0, 10000)]);
    expect(unedited.sidecar.single.text, "Hello, world — it's me.");

    final cutInHalf = reflow(
      [withWords],
      [clip('a', 0, 5000), clip('b', 5500, 10000)],
    );
    expect(
      cutInHalf.sidecar.single.text,
      "Hello, world — it's me.",
      reason: 'the full line, not a word-joined fragment',
    );
  });

  test('a two-speaker cue keeps its line break', () {
    final merged = cue('c1', 4000, 6000, 'can we ship it Friday\nyeah sure');
    final out = reflow([merged], [clip('a', 0, 5000), clip('b', 5500, 10000)]);
    expect(out.sidecar.single.text, contains('\n'));
  });

  test('burn-in and sidecar always agree on the text', () {
    final out = reflow(
      [cue('c1', 4000, 6000, 'the same words')],
      [clip('a', 0, 5000), clip('b', 5500, 10000)],
    );
    expect(
      out.burnIn.map((s) => s.text).toSet(),
      out.sidecar.map((s) => s.text).toSet(),
    );
  });

  // ---- Slivers ----------------------------------------------------------

  test('a one-frame sliver left by a cut is dropped from both outputs', () {
    // Too brief to read a character, long enough to pull the eye off the
    // picture. The transcription engine already refuses segments this short.
    final out = reflow([cue('c1', 4980, 6000)], [clip('a', 0, 5000)]);

    expect(out.sidecar, isEmpty, reason: '20ms survives');
    expect(out.burnIn, isEmpty, reason: 'and it must not be rasterised either');
  });

  test('the floor is measured across all of a cue, not per piece', () {
    // A cut through the middle leaves 200ms + 200ms. Neither piece clears the
    // floor alone, but 400ms of readable caption survives.
    final out = reflow(
      [cue('c1', 4000, 4500)],
      [clip('a', 0, 4200), clip('b', 4300, 10000)],
    );

    expect(out.sidecar, isNotEmpty);
    expect(out.sidecar.fold<int>(0, (n, s) => n + s.outputDurationMs), 400);
  });

  test('a whole cue is never dropped for being short', () {
    // The engine floor is 200ms, below this one — an untouched cue must not be
    // deleted by an edit that did not touch it.
    final out = reflow([cue('c1', 1000, 1250)], const []);
    expect(out.sidecar, hasLength(1));
  });

  // ---- Boundaries -------------------------------------------------------

  test('a cue ending exactly at a clip end survives whole', () {
    final out = reflow([cue('c1', 4000, 5000)], [clip('a', 0, 5000)]);
    expect(out.sidecar, hasLength(1));
    expect(out.sidecar.single.outputEndMs, 5000);
  });

  test('no span is ever emitted with zero duration', () {
    // Asserted directly rather than left to the sliver floor to absorb: a
    // degenerate span that merges into a real one would survive the floor and
    // reach the rasterizer as a bitmap nothing can display.
    for (final clips in [
      [clip('a', 0, 5000)],
      [clip('a', 0, 5000), clip('b', 5000, 10000)],
      [clip('a', 0, 5000), clip('b', 7000, 10000)],
      [clip('b', 5000, 10000), clip('a', 0, 5000)],
    ]) {
      final out = reflow([
        cue('c1', 4000, 6000),
        cue('c2', 5000, 5000),
        cue('c3', 9000, 9800),
      ], clips);
      for (final span in [...out.burnIn, ...out.sidecar]) {
        expect(span.sourceDurationMs, greaterThan(0), reason: '$span');
        expect(span.outputDurationMs, greaterThan(0), reason: '$span');
      }
    }
  });

  test('a cue starting exactly at a clip end is outside it', () {
    // Range ends are exclusive, matching editedMsForKeptSourceMs's
    // `sourceMs < r.sourceOutMs`.
    final out = reflow([cue('c1', 5000, 6000)], [clip('a', 0, 5000)]);
    expect(out.sidecar, isEmpty);
  });

  test('a zero-length clip contributes nothing and shifts nothing', () {
    final out = reflow(
      [cue('c1', 6000, 7000)],
      [clip('a', 0, 3000), clip('empty', 4000, 4000), clip('b', 5000, 10000)],
    );
    expect(
      out.sidecar.single.outputStartMs,
      4000,
      reason: '3000 + (6000-5000)',
    );
  });

  test('an inverted clip is ignored, matching fromFlutter', () {
    final out = reflow(
      [cue('c1', 6000, 7000)],
      [clip('a', 0, 3000), clip('bad', 8000, 2000), clip('b', 5000, 10000)],
    );
    expect(out.sidecar.single.outputStartMs, 4000);
  });

  test('a cue spanning three kept ranges is one subtitle, not three', () {
    final out = reflow(
      [cue('c1', 500, 9500, 'a very long line')],
      [clip('a', 0, 3000), clip('b', 4000, 6000), clip('c', 7000, 10000)],
    );

    expect(out.sidecar, hasLength(1), reason: 'contiguous in the output');
    expect(out.sidecar.single.outputStartMs, 500);
    expect(out.burnIn, hasLength(3), reason: 'three separate source spans');
  });

  // ---- Ordering and identity --------------------------------------------

  test('the sidecar is sorted by output time', () {
    final out = reflow(
      [cue('a', 8000, 9000), cue('b', 1000, 2000)],
      [clip('x', 7000, 10000), clip('y', 0, 3000)],
    );

    for (var i = 1; i < out.sidecar.length; i++) {
      expect(
        out.sidecar[i].outputStartMs,
        greaterThanOrEqualTo(out.sidecar[i - 1].outputStartMs),
      );
    }
  });

  test('the burn-in is sorted by source time', () {
    final out = reflow(
      [cue('a', 8000, 9000), cue('b', 1000, 2000)],
      [clip('x', 7000, 10000), clip('y', 0, 3000)],
    );

    for (var i = 1; i < out.burnIn.length; i++) {
      expect(
        out.burnIn[i].sourceStartMs,
        greaterThanOrEqualTo(out.burnIn[i - 1].sourceStartMs),
      );
    }
  });

  test('every span traces back to its cue for the panel', () {
    final out = reflow(
      [cue('c1', 4000, 6000)],
      [clip('a', 0, 5000), clip('b', 5500, 10000)],
    );
    expect(out.burnIn.every((s) => s.cueId == 'c1'), isTrue);
  });

  test('span ids are unique within each list', () {
    final out = reflow(
      [cue('c1', 2000, 8000), cue('c2', 3000, 3500)],
      [clip('a', 0, 4000), clip('b', 5000, 10000)],
    );

    for (final list in [out.burnIn, out.sidecar]) {
      expect(list.map((s) => s.id).toSet(), hasLength(list.length));
    }
  });
}
