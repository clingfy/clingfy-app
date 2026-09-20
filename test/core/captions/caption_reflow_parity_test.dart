import 'dart:convert';
import 'dart:io';

import 'package:clingfy/core/captions/caption_reflow.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart half of the caption-reflow parity contract.
///
/// [CaptionReflow] re-implements the native clip-placement maths so cue times
/// survive cuts, splits, trims and reorders. Its own docstring names the three
/// Swift behaviours it mirrors, but until this pair nothing compared the two
/// implementations: each was checked against its own author's belief, so a
/// change to one side moved burned-in caption timings in the exported video
/// while the `.srt`/`.vtt` beside it stayed correct, with every test on both
/// sides green.
///
/// This reads the same fixture `macos/RunnerTests/CaptionReflowParityTests.swift`
/// reads. The expected numbers live in the fixture and nowhere else -- that
/// single authorship is the whole mechanism. Restating them here would just be
/// a second opinion that could drift.
///
/// WHAT THIS DOES AND DOES NOT DISCRIMINATE. Of the three mirrored behaviours,
/// the fixture pins two: `ClipKeptRange.fromFlutter` (which clips are kept, in
/// what order, and that `timelineStartMs` is ignored) and
/// `editedMsForKeptSourceMs` (where a kept source moment lands). `coalesce` is
/// exercised but cannot be discriminated by this table, and saying so is more
/// use than implying coverage: merging two touching ranges [a,b) and [b,c) is
/// mapping-invariant, because unmerged gives (b-a) + (s-b) and merged gives
/// (s-a) -- the same number. Coalescing matters elsewhere, for reader windows
/// and `isSourceMonotonic`, and needs its own pin if that is wanted.
///
/// Each probe is asserted by reflowing a 500 ms cue at the source moment and
/// reading where it landed, because the mapping is what both sides share:
/// Swift has no reflow, it has `editedMsForKeptSourceMs`.
///
/// 500 ms rather than the 1 ms that would be tidiest, because
/// [CaptionReflow.minimumOutputDurationMs] drops any cue with under 400 ms
/// surviving. That rule has no counterpart on the Swift side, so a shorter
/// probe would be comparing the minimum instead of the mapping. Every probe in
/// the fixture has that much clearance inside one range, or inside one gap.
void main() {
  final fixture = File('test/fixtures/caption_reflow_cases.json');

  test('the fixture the Swift side reads is actually here', () {
    expect(
      fixture.existsSync(),
      isTrue,
      reason:
          'missing ${fixture.path} -- if it moved, move it in '
          'CaptionReflowParityTests.swift too or the two suites stop '
          'comparing anything',
    );
  });

  /// Long enough to clear [CaptionReflow.minimumOutputDurationMs]; see the
  /// library docs above.
  const probeMs = 500;

  test('the source-to-output mapping matches the shared fixture', () {
    final root =
        json.decode(fixture.readAsStringSync()) as Map<String, dynamic>;
    final cases = (root['cases'] as List).cast<Map<String, dynamic>>();
    expect(
      cases,
      isNotEmpty,
      reason: 'the fixture parsed to no cases, so this asserts nothing',
    );

    var checked = 0;
    for (final testCase in cases) {
      final name = testCase['name'] as String;
      final clips = [
        for (final (index, raw)
            in (testCase['clips'] as List).cast<Map<String, dynamic>>().indexed)
          Clip(
            id: 'c$index',
            sourceInMs: raw['sourceInMs'] as int,
            sourceOutMs: raw['sourceOutMs'] as int,
            timelineStartMs: raw['timelineStartMs'] as int,
            enabled: raw['enabled'] as bool,
          ),
      ];

      for (final probe
          in (testCase['probes'] as List).cast<Map<String, dynamic>>()) {
        final sourceMs = probe['sourceMs'] as int;
        final expectedOut = probe['outputMs'] as int?;

        final result = CaptionReflow.reflow(
          captions: [
            Caption(id: 'probe', startMs: sourceMs, endMs: sourceMs + probeMs),
          ],
          clips: clips,
        );
        // `sidecar` is the output-timed list; `burnIn` stays in source time.
        // A cue that was cut away produces neither.
        final actualOut = result.sidecar.isEmpty
            ? null
            : result.sidecar.first.outputStartMs;

        expect(
          actualOut,
          expectedOut,
          reason:
              '$name: source ${sourceMs}ms should land at '
              '${expectedOut ?? "nowhere (cut away)"} but Dart places it at '
              '${actualOut ?? "nowhere"}. If Swift still agrees with the '
              'fixture, this side has diverged.',
        );
        checked++;
      }
    }

    // Guards the fixture's own shape: cases with no probes would pass every
    // assertion above by running none.
    expect(
      checked,
      greaterThan(20),
      reason:
          'far fewer probes than the fixture carries -- the parse dropped some',
    );
  });
}
