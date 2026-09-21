import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every `XCTestCase` in `macos/RunnerTests/` runs in CI unless it is skipped
/// on purpose, and every skip is named here with a reason.
///
/// The macOS fast lane used to select tests with an explicit `-only-testing:`
/// allowlist, and `ci.yml` named the trade-off itself:
///
/// > An allowlist has the same failure mode as the selector it replaced, one
/// > class at a time: a NEW class is dead in CI until someone adds it here,
/// > and nothing fails to say so.
///
/// That lane now runs the whole bundle and skips by exception, so the default
/// is coverage and a class added tomorrow runs tomorrow. This file enforces the
/// shape that keeps it honest, from the other side:
///
///  * a skip in `ci.yml` must name a class that exists, and
///  * a class may only be skipped if [skippedInCi] says why.
///
/// It runs no Swift — it compares two text files — so it rides the Flutter lane
/// on any platform, including a Windows dev box where the native suite cannot
/// be built at all.
///
/// Adding a `-skip-testing:` line and forgetting the entry here now fails, with
/// the class named. That is the point: a skip should be a decision, not a
/// default.
void main() {
  test('every class skipped in CI is listed here with a reason', () {
    final skipped = _classesSkippedInCi();
    final unexplained = skipped.difference(skippedInCi).toList()..sort();

    expect(
      unexplained,
      isEmpty,
      reason:
          'These classes carry a `-skip-testing:` line in '
          '.github/workflows/ci.yml but are not in skippedInCi, so they do not '
          'run and nothing says why. Add them there with the reason, or drop '
          'the skip.',
    );
  });

  test('nothing listed here is skipped without ci.yml agreeing', () {
    // Honest in the other direction: an entry that no longer matches a real
    // `-skip-testing:` line is claiming an exclusion that is not happening.
    final skipped = _classesSkippedInCi();
    final stale = skippedInCi.difference(skipped).toList()..sort();

    expect(
      stale,
      isEmpty,
      reason:
          'Listed as skipped but ci.yml no longer skips them. They run now — '
          'remove them from skippedInCi.',
    );
  });

  test('nothing listed here has been deleted', () {
    final classes = _testClassNames();
    final ghosts = skippedInCi.difference(classes).toList()..sort();

    expect(
      ghosts,
      isEmpty,
      reason:
          'Listed as skipped but no longer present in macos/RunnerTests/. '
          'Remove them from skippedInCi.',
    );
  });

  test('the fast lane still selects the whole bundle', () {
    // The skips above only mean anything while the lane runs everything else.
    // Re-introducing an `-only-testing:RunnerTests/<class>` allowlist in this
    // lane would silently restore the failure mode the flip removed, and every
    // assertion here would keep passing.
    final file = File('.github/workflows/ci.yml');
    final fastLane = file
        .readAsStringSync()
        .split('Run fast native tests')
        .last
        .split('Upload fast native test artifacts')
        .first;

    expect(
      fastLane.contains('-only-testing:RunnerTests \\'),
      isTrue,
      reason:
          'the fast lane no longer runs the whole RunnerTests bundle, so a new '
          'class is dead in CI again',
    );
    expect(
      RegExp(r'-only-testing:RunnerTests/\w').hasMatch(fastLane),
      isFalse,
      reason:
          'the fast lane selects individual classes again — that is the '
          'allowlist whose failure mode this flip removed',
    );
  });
}

/// Classes the macOS fast lane skips, and why.
///
/// Not a debt ledger any more. It held 38 entries because the lane ran an
/// allowlist and everything outside it was simply unrun; all 37 of the
/// untriaged ones were run before the flip and passed -- 292 tests, no
/// failures -- so they are covered now and gone from here.
///
/// A line here is a claim that a class SHOULD NOT run, and it must match a real
/// `-skip-testing:` line in `ci.yml`. Both directions are asserted above, so
/// this cannot drift into fiction in either.
const Set<String> skippedInCi = <String>{
  /// Not excluded, relocated: the export lane owns it, deliberately split so
  /// the large fixture runs only on schedule/workflow_dispatch. Running it in
  /// the fast lane too would duplicate the slowest suite in the repo.
  'LetterboxExporterTests',

  /// Composites a burned-in `.mov` for a human to look at, from bitmaps that
  /// `flutter test test/core/captions/caption_proof_bitmaps.dart` writes to
  /// `/tmp`. Absent on a runner, so it skips there and can never fail. Removing
  /// this means checking those bitmaps in as a fixture.
  'CaptionBurnInProofTests',
};

Set<String> _testClassNames() {
  final dir = Directory('macos/RunnerTests');
  if (!dir.existsSync()) return <String>{};
  final pattern = RegExp(r'class\s+([A-Za-z0-9_]+)\s*:\s*XCTestCase');
  final names = <String>{};
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.swift')) continue;
    for (final match in pattern.allMatches(entity.readAsStringSync())) {
      names.add(match.group(1)!);
    }
  }
  return names;
}

Set<String> _classesSkippedInCi() {
  final file = File('.github/workflows/ci.yml');
  if (!file.existsSync()) return <String>{};
  // Capture the whole selector and filter afterwards, rather than trying to
  // exclude method skips with a lookahead: `([A-Za-z0-9_]+)(?!/)` backtracks
  // one character to satisfy itself and yields `LetterboxExporterTest`, losing
  // the trailing `s`.
  //
  // Class-level skips only. The export lane also skips a single METHOD
  // (`LetterboxExporterTests/testInline...largeFixture`), which is a split
  // inside a class that DOES run, not an excluded class.
  final pattern = RegExp(r'-skip-testing:RunnerTests/([A-Za-z0-9_/]+)');
  return <String>{
    for (final line in file.readAsLinesSync())
      // Skip commented-out selectors so a disabled line does not read as
      // coverage.
      if (!line.trimLeft().startsWith('#'))
        for (final match in pattern.allMatches(line))
          if (!match.group(1)!.contains('/')) match.group(1)!,
  };
}
