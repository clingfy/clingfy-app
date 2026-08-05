import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter/foundation.dart';

/// One contiguous surviving piece of a cue, carrying both timebases.
///
/// A cue that a cut slices in two produces two spans. A cue removed entirely
/// produces none.
@immutable
class CaptionSpan {
  const CaptionSpan({
    required this.id,
    required this.cueId,
    required this.sourceStartMs,
    required this.sourceEndMs,
    required this.outputStartMs,
    required this.outputEndMs,
    required this.text,
  });

  /// Unique per span. Equal to [cueId] when the cue survived in one piece, so
  /// an unedited export produces exactly the ids it produced before reflow
  /// existed — the burn-in bitmap file names are derived from this.
  final String id;

  /// The cue this came from. Several spans can share one, and the captions
  /// panel keys its rows on it.
  final String cueId;

  /// Position in the ORIGINAL recording. What the native burn-in looks cues up
  /// by, because the export composition stays in source time.
  final int sourceStartMs;
  final int sourceEndMs;

  /// Position in the EXPORTED file. What .srt/.vtt timestamps must be.
  final int outputStartMs;
  final int outputEndMs;

  final String text;

  int get sourceDurationMs => sourceEndMs - sourceStartMs;
  int get outputDurationMs => outputEndMs - outputStartMs;

  /// This span as a cue on the source timeline, for the burn-in payload.
  Caption asSourceCue() =>
      Caption(id: id, startMs: sourceStartMs, endMs: sourceEndMs, text: text);

  /// This span as a cue on the exported timeline, for the sidecar.
  Caption asOutputCue() =>
      Caption(id: id, startMs: outputStartMs, endMs: outputEndMs, text: text);

  @override
  bool operator ==(Object other) =>
      other is CaptionSpan &&
      other.id == id &&
      other.cueId == cueId &&
      other.sourceStartMs == sourceStartMs &&
      other.sourceEndMs == sourceEndMs &&
      other.outputStartMs == outputStartMs &&
      other.outputEndMs == outputEndMs &&
      other.text == text;

  @override
  int get hashCode => Object.hash(
    id,
    cueId,
    sourceStartMs,
    sourceEndMs,
    outputStartMs,
    outputEndMs,
    text,
  );

  @override
  String toString() =>
      'CaptionSpan($id src[$sourceStartMs,$sourceEndMs) '
      'out[$outputStartMs,$outputEndMs) "$text")';
}

/// The two views the two subtitle destinations need.
@immutable
class ReflowedCaptions {
  const ReflowedCaptions({required this.burnIn, required this.sidecar});

  static const ReflowedCaptions empty = ReflowedCaptions(
    burnIn: [],
    sidecar: [],
  );

  /// Source-timed, sorted by source start, and pairwise NON-OVERLAPPING.
  ///
  /// The disjointness is load-bearing rather than tidy: `CaptionCueTrack` on
  /// the Swift side drops any cue that starts before the previous one ends,
  /// so an overlapping pair would silently lose a caption from the video that
  /// the sidecar still lists.
  final List<CaptionSpan> burnIn;

  /// Output-timed, sorted by output start. What the `.srt`/`.vtt` writer uses.
  final List<CaptionSpan> sidecar;

  bool get isEmpty => burnIn.isEmpty && sidecar.isEmpty;
}

/// Maps a source-timed transcript onto an edited recording.
///
/// Captions are transcribed against the ORIGINAL audio, so every cue time is a
/// source time. Cuts, splits, trims and reordering change where — and whether —
/// each of those moments appears in the exported file. Without this, a `.srt`
/// beside an edited export puts every subtitle at the wrong moment, and cues
/// inside cut-away footage are still rasterised and written.
///
/// This deliberately mirrors the native export path rather than the Dart clip
/// model, because native is what actually places the frames:
///
/// * `ClipKeptRange.fromFlutter` keeps enabled clips with a positive span, in
///   LIST order, and ignores `timelineStartMs` entirely.
/// * `ClipPlaybackPlanner.coalesce` merges ranges that touch in source.
/// * `ClipPlaybackPlanner.editedMsForKeptSourceMs` places a source moment at
///   the running sum of preceding range durations plus its offset.
///
/// `timelineStartMs` happens to agree with that running sum while the clip list
/// is normalised, which `ClipOperations` and the restore path both guarantee —
/// but deriving the sum here means the mapping matches the exporter by
/// construction rather than by a shared invariant maintained somewhere else.
abstract final class CaptionReflow {
  /// Shortest surviving cue worth showing, measured on the OUTPUT timeline.
  ///
  /// A cut can leave a few milliseconds of a cue. That is not a short subtitle,
  /// it is a one-frame flash: too brief to read a single character, yet still
  /// enough to pull the eye off the picture. The engine already refuses to emit
  /// segments this short — `TranscriptionOptions.strict.minimumDurationMs` is
  /// 400 for the same reason — so a span below it can only be cut debris.
  ///
  /// Applied to a cue's TOTAL surviving output time, not to each piece, so a
  /// cue sliced into two readable halves is not thrown away for having no
  /// single long piece.
  static const int minimumOutputDurationMs = 400;

  /// Reflows [captions] onto the timeline described by [clips].
  ///
  /// An empty [clips] list means passthrough, NOT "nothing survives" — and so
  /// does a list whose clips are all disabled. Both cases leave native's
  /// `keptRanges` empty, and the exporter then writes every frame at its source
  /// timestamp. Treating either as "everything was cut" would delete the whole
  /// transcript on the most common export there is: an unedited recording.
  static ReflowedCaptions reflow({
    required List<Caption> captions,
    required List<Clip> clips,
  }) {
    if (captions.isEmpty) return ReflowedCaptions.empty;

    final ranges = _keptRanges(clips);
    if (ranges.isEmpty) return _identity(captions);

    // Source order, so both output lists come out sorted without a later sort
    // that could disagree about which timebase it is ordering.
    final ordered = [...captions]
      ..sort((a, b) {
        final byStart = a.startMs.compareTo(b.startMs);
        return byStart != 0 ? byStart : a.endMs.compareTo(b.endMs);
      });

    final byCue = <String, List<CaptionSpan>>{};
    final cueOrder = <String>[];
    var base = 0;
    for (final range in ranges) {
      for (final cue in ordered) {
        final startMs = cue.startMs > range.startMs
            ? cue.startMs
            : range.startMs;
        final endMs = cue.endMs < range.endMs ? cue.endMs : range.endMs;
        if (endMs <= startMs) continue;

        var spans = byCue[cue.id];
        if (spans == null) {
          spans = <CaptionSpan>[];
          byCue[cue.id] = spans;
          // First sighting decides output order for this cue: ranges are walked
          // in timeline order, so the earliest range a cue appears in is the
          // earliest place it appears in the file.
          cueOrder.add(cue.id);
        }
        spans.add(
          CaptionSpan(
            id: cue.id,
            cueId: cue.id,
            sourceStartMs: startMs,
            sourceEndMs: endMs,
            outputStartMs: base + (startMs - range.startMs),
            outputEndMs: base + (endMs - range.startMs),
            // The full cue text, never a subset rebuilt from word timings.
            // See the library docs on why word-level trimming is deferred.
            text: cue.text,
          ),
        );
      }
      base += range.durationMs;
    }

    final burnIn = <CaptionSpan>[];
    final sidecar = <CaptionSpan>[];
    for (final cueId in cueOrder) {
      final spans = byCue[cueId]!;
      final total = spans.fold<int>(0, (sum, s) => sum + s.outputDurationMs);
      if (total < minimumOutputDurationMs) continue;

      burnIn.addAll(_mergeBySource(spans));
      sidecar.addAll(_mergeByOutput(spans));
    }

    burnIn.sort((a, b) => a.sourceStartMs.compareTo(b.sourceStartMs));
    sidecar.sort((a, b) => a.outputStartMs.compareTo(b.outputStartMs));
    return ReflowedCaptions(
      burnIn: _numbered(burnIn),
      sidecar: _numbered(sidecar),
    );
  }

  /// Every cue unchanged, both timebases equal — the passthrough export.
  static ReflowedCaptions _identity(List<Caption> captions) {
    final spans = [
      for (final cue in captions)
        if (cue.endMs > cue.startMs)
          CaptionSpan(
            id: cue.id,
            cueId: cue.id,
            sourceStartMs: cue.startMs,
            sourceEndMs: cue.endMs,
            outputStartMs: cue.startMs,
            outputEndMs: cue.endMs,
            text: cue.text,
          ),
    ]..sort((a, b) => a.sourceStartMs.compareTo(b.sourceStartMs));
    return ReflowedCaptions(burnIn: spans, sidecar: spans);
  }

  /// Mirrors `ClipKeptRange.fromFlutter`: enabled clips with a positive span,
  /// in list order. `timelineStartMs` is not read — see the class docs.
  static List<_Range> _keptRanges(List<Clip> clips) => [
    for (final clip in clips)
      if (clip.enabled && clip.sourceOutMs > clip.sourceInMs)
        _Range(clip.sourceInMs, clip.sourceOutMs),
  ];

  /// Merges spans of one cue whose SOURCE ranges touch or overlap.
  ///
  /// Touching is what absorbs a bare split: splitting produces two
  /// source-adjacent clips and deletes nothing, so a cue spanning the seam must
  /// come back out as one piece over footage that was never cut. Native gets
  /// there by coalescing the ranges first; merging the spans reaches the same
  /// place, so there is no separate coalesce step here.
  ///
  /// Overlap is reachable: trimming a clip's start edge past a split point
  /// leaves two clips covering the same source moment, and nothing rejects
  /// that. Two spans of one cue would then overlap in source, and the Swift
  /// `CaptionCueTrack` would drop the second — losing it from the video while
  /// the sidecar still lists it.
  static List<CaptionSpan> _mergeBySource(List<CaptionSpan> spans) {
    final sorted = [...spans]
      ..sort((a, b) => a.sourceStartMs.compareTo(b.sourceStartMs));
    final out = <CaptionSpan>[];
    for (final span in sorted) {
      final last = out.isEmpty ? null : out.last;
      if (last != null && span.sourceStartMs <= last.sourceEndMs) {
        out[out.length - 1] = CaptionSpan(
          id: last.id,
          cueId: last.cueId,
          sourceStartMs: last.sourceStartMs,
          sourceEndMs: span.sourceEndMs > last.sourceEndMs
              ? span.sourceEndMs
              : last.sourceEndMs,
          // The output range of a merged burn-in span is not meaningful — the
          // two pieces sit in different places in the file. Kept as the first
          // piece's so the field is never garbage; the sidecar list is what
          // carries output timing.
          outputStartMs: last.outputStartMs,
          outputEndMs: last.outputEndMs,
          text: last.text,
        );
      } else {
        out.add(span);
      }
    }
    return out;
  }

  /// Merges spans of one cue that are CONTIGUOUS in the output.
  ///
  /// A cut through a cue leaves two pieces with a source gap but no output gap:
  /// the removed footage is not in the file. Writing them as two subtitles
  /// would repeat the same line back-to-back for no visible reason.
  static List<CaptionSpan> _mergeByOutput(List<CaptionSpan> spans) {
    final sorted = [...spans]
      ..sort((a, b) => a.outputStartMs.compareTo(b.outputStartMs));
    final out = <CaptionSpan>[];
    for (final span in sorted) {
      final last = out.isEmpty ? null : out.last;
      if (last != null && span.outputStartMs <= last.outputEndMs) {
        out[out.length - 1] = CaptionSpan(
          id: last.id,
          cueId: last.cueId,
          sourceStartMs: last.sourceStartMs,
          sourceEndMs: last.sourceEndMs,
          outputStartMs: last.outputStartMs,
          outputEndMs: span.outputEndMs > last.outputEndMs
              ? span.outputEndMs
              : last.outputEndMs,
          text: last.text,
        );
      } else {
        out.add(span);
      }
    }
    return out;
  }

  /// Gives a cue's pieces distinct ids, leaving a cue that survived whole with
  /// its original id — so an unedited export produces byte-identical bitmap
  /// names to one from before reflow existed.
  static List<CaptionSpan> _numbered(List<CaptionSpan> spans) {
    final counts = <String, int>{};
    for (final span in spans) {
      counts[span.cueId] = (counts[span.cueId] ?? 0) + 1;
    }
    final seen = <String, int>{};
    return [
      for (final span in spans)
        if ((counts[span.cueId] ?? 0) <= 1)
          span
        else
          CaptionSpan(
            id: '${span.cueId}#${seen[span.cueId] = (seen[span.cueId] ?? 0) + 1}',
            cueId: span.cueId,
            sourceStartMs: span.sourceStartMs,
            sourceEndMs: span.sourceEndMs,
            outputStartMs: span.outputStartMs,
            outputEndMs: span.outputEndMs,
            text: span.text,
          ),
    ];
  }
}

/// A kept source window. The Dart mirror of Swift's `ClipKeptRange`.
@immutable
class _Range {
  const _Range(this.startMs, this.endMs);

  final int startMs;
  final int endMs;

  int get durationMs => endMs > startMs ? endMs - startMs : 0;
}
