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
/// `azure-pipelines/flutter-version.yml` is the single source for the Azure
/// lanes. GitHub Actions cannot consume an Azure template, so its workflows
/// still carry the literal — which is precisely why this test exists rather
/// than trusting the template alone.
void main() {
  // Tests run from the repo root.
  final repoRoot = Directory.current;

  File repoFile(String relative) => File('${repoRoot.path}/$relative');

  /// The canonical pin, from the Azure variables template.
  String canonicalVersion() {
    final f = repoFile('azure-pipelines/flutter-version.yml');
    expect(
      f.existsSync(),
      isTrue,
      reason: 'the single source of truth for the Flutter pin is missing',
    );
    final m = RegExp(
      r'value:\s*"([0-9]+\.[0-9]+\.[0-9]+)"',
    ).firstMatch(f.readAsStringSync());
    expect(m, isNotNull, reason: 'no version found in flutter-version.yml');
    return m!.group(1)!;
  }

  /// Every `flutter-version: X` in the GitHub workflows, with its file.
  List<({String file, String version, int line})> githubPins() {
    final dir = Directory('${repoRoot.path}/.github/workflows');
    if (!dir.existsSync()) return const [];
    final out = <({String file, String version, int line})>[];
    final pattern = RegExp(r'flutter-version:\s*([0-9]+\.[0-9]+\.[0-9]+)');
    for (final entry in dir.listSync().whereType<File>()) {
      if (!entry.path.endsWith('.yml') && !entry.path.endsWith('.yaml')) {
        continue;
      }
      final lines = entry.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
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
    return out;
  }

  /// Any literal `customVersion:` left in an Azure lane — i.e. a lane that
  /// bypassed the shared template.
  List<({String file, String version, int line})> azureLiteralPins() {
    final dir = Directory('${repoRoot.path}/azure-pipelines');
    if (!dir.existsSync()) return const [];
    final out = <({String file, String version, int line})>[];
    final pattern = RegExp(r'customVersion:\s*"([0-9]+\.[0-9]+\.[0-9]+)"');
    for (final entry in dir.listSync().whereType<File>()) {
      if (!entry.path.endsWith('.yml')) continue;
      final lines = entry.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
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
    return out;
  }

  test('the Azure template declares a canonical version', () {
    expect(canonicalVersion(), matches(RegExp(r'^\d+\.\d+\.\d+$')));
  });

  // The regression. Four lanes, four literals, two different values, and no
  // signal until a build behaved differently from another build.
  test('every Azure lane resolves its pin from the shared template', () {
    final strays = azureLiteralPins();
    expect(
      strays,
      isEmpty,
      reason:
          'these Azure lanes hardcode a Flutter version instead of using '
          '\$(flutterVersion) from flutter-version.yml:\n'
          '${strays.map((s) => '  ${s.file}:${s.line} -> ${s.version}').join('\n')}',
    );
  });

  // GitHub Actions cannot read the Azure template, so its literals are checked
  // against it instead. This is the half a template alone cannot fix.
  test('GitHub workflow pins match the canonical version', () {
    final canonical = canonicalVersion();
    final pins = githubPins();
    expect(
      pins,
      isNotEmpty,
      reason:
          'no flutter-version found in .github/workflows — if the pin moved, '
          'this test needs to learn where',
    );
    final mismatched = pins.where((p) => p.version != canonical).toList();
    expect(
      mismatched,
      isEmpty,
      reason:
          'canonical is $canonical (azure-pipelines/flutter-version.yml) but '
          'these disagree:\n'
          '${mismatched.map((p) => '  ${p.file}:${p.line} -> ${p.version}').join('\n')}',
    );
  });

  // A guard on the guard: if every pin were somehow removed, the two tests
  // above would pass vacuously and report agreement about nothing.
  test('at least one pin exists to compare', () {
    expect(githubPins().length + 1, greaterThan(1));
  });
}
