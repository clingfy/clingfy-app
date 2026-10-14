import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every Flutter SDK pin in the repo must name the same version.
///
/// They had drifted: the macOS Azure lanes sat on 3.41.0 while the Windows
/// lanes and GitHub CI were on 3.41.1. Nothing detected it, because nothing
/// compared them — four files each hardcoded their own number.
///
/// Drift is not cosmetic. Info-level lints are SDK-version dependent, so a
/// deprecation that does not exist on one pin appears on another. That is
/// exactly how a fix for the Windows release lane came to compile locally on
/// 3.44.0 and fail CI on 3.41.1, where the replacement API did not exist yet:
/// two toolchains disagreeing about whether the code was even valid.
///
/// The canonical pin used to be `azure-pipelines/flutter-version.yml`. Those
/// lanes were removed with the rest of the Azure setup, and GitHub Actions
/// cannot share a variable across workflows, so every workflow carries its own
/// literal. There is no single file to trust, so this test makes them agree
/// with each other: to upgrade, change every pin and let this confirm none was
/// missed.
void main() {
  // Tests run from the repo root.
  final repoRoot = Directory.current;

  /// Every Flutter version literal in the GitHub workflows, with its file:
  /// the `flutter-action` input, and the CMake defines the Windows native-test
  /// configure passes by hand (it is not driven by `flutter build`, so nothing
  /// else keeps it in step).
  List<({String file, String version, int line})> workflowPins() {
    final dir = Directory('${repoRoot.path}/.github/workflows');
    if (!dir.existsSync()) return const [];
    final out = <({String file, String version, int line})>[];
    final patterns = [
      RegExp(r'flutter-version:\s*([0-9]+\.[0-9]+\.[0-9]+)'),
      RegExp(r'-DFLUTTER_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"'),
    ];
    for (final entry in dir.listSync().whereType<File>()) {
      if (!entry.path.endsWith('.yml') && !entry.path.endsWith('.yaml')) {
        continue;
      }
      final lines = entry.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final pattern in patterns) {
          final m = pattern.firstMatch(lines[i]);
          if (m != null) {
            out.add((
              file: entry.uri.pathSegments.last,
              version: m.group(1)!,
              line: i + 1,
            ));
          }
        }
      }
    }
    return out;
  }

  /// The split CMake defines (`-DFLUTTER_VERSION_MAJOR=3 ...`), reassembled.
  /// They feed the runner's version resource and can drift from the quoted
  /// string next to them, so they are checked as a version of their own.
  List<({String file, String version})> splitCmakePins() {
    final dir = Directory('${repoRoot.path}/.github/workflows');
    if (!dir.existsSync()) return const [];
    final out = <({String file, String version})>[];
    int? part(String text, String name) {
      final m = RegExp('-DFLUTTER_VERSION_$name=([0-9]+)').firstMatch(text);
      return m == null ? null : int.parse(m.group(1)!);
    }

    for (final entry in dir.listSync().whereType<File>()) {
      if (!entry.path.endsWith('.yml') && !entry.path.endsWith('.yaml')) {
        continue;
      }
      final text = entry.readAsStringSync();
      final major = part(text, 'MAJOR');
      if (major == null) continue;
      out.add((
        file: entry.uri.pathSegments.last,
        version: '$major.${part(text, 'MINOR')}.${part(text, 'PATCH')}',
      ));
    }
    return out;
  }

  test('the GitHub workflows pin Flutter somewhere', () {
    // A guard on the guard: with no pins, the agreement test below would pass
    // vacuously and report agreement about nothing.
    expect(
      workflowPins(),
      isNotEmpty,
      reason:
          'no flutter-version found in .github/workflows — if the pin moved, '
          'this test needs to learn where',
    );
  });

  // The regression. Four lanes, four literals, two different values, and no
  // signal until a build behaved differently from another build.
  test('every Flutter pin names the same version', () {
    final pins = workflowPins();
    final split = splitCmakePins();
    final versions = {
      ...pins.map((p) => p.version),
      ...split.map((p) => p.version),
    };
    expect(
      versions,
      hasLength(1),
      reason:
          'the Flutter pins disagree:\n'
          '${pins.map((p) => '  ${p.file}:${p.line} -> ${p.version}').join('\n')}\n'
          '${split.map((p) => '  ${p.file} (split CMake defines) -> ${p.version}').join('\n')}',
    );
  });

  test('the Azure lanes are gone, so nothing can pin from them', () {
    // The old canonical file lived there. If the directory comes back, the
    // pin it carries would be one this test no longer compares.
    expect(Directory('${repoRoot.path}/azure-pipelines').existsSync(), isFalse);
  });
}
