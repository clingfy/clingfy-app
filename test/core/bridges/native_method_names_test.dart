import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// PR-0d: the Flutter -> native method surface is named in ONE place.
///
/// These names used to be inline string literals at 120 call sites across nine
/// files. That is the one kind of bridge mistake nothing catches at runtime: a
/// renamed or mistyped method name falls through Swift's `switch` to
/// `FlutterMethodNotImplemented` and through Windows' handler table to the
/// default arm, and most Dart call sites either ignore the reply or swallow
/// `MissingPluginException` — so the feature just quietly stops working, with
/// no error anywhere.
///
/// Compared as source text, in the same spirit as
/// `native_error_codes_sync_test.dart`, because const classes cannot be
/// enumerated by reflection in a Flutter test.
void main() {
  // `\s*` after the `=`, not a space. dart format wraps a declaration whose
  // line would run long:
  //
  //     static const String setCameraOverlayHighlightStrength =
  //         'setCameraOverlayHighlightStrength';
  //
  // The first version of this regex required the value on the same line, so
  // fifteen constants — every one with a name long enough to wrap — were
  // invisible to all four assertions below. The test reported on 100 of 115
  // and passed.
  final constDecl = RegExp(r"static const String (\w+) =\s*'([^']+)';");

  String read(String path) {
    final file = File(path);
    expect(
      file.existsSync(),
      isTrue,
      reason: '$path not found — flutter test runs from the repo root.',
    );
    return file.readAsStringSync();
  }

  /// The `NativeMethod` class body only, so the other constant classes in the
  /// same file (channels, event types, callback names) are not swept up.
  Map<String, String> nativeMethodConstants() {
    final src = read('lib/core/bridges/native_method_channel.dart');
    final start = src.indexOf('abstract class NativeMethod {');
    expect(start, isNot(-1), reason: 'NativeMethod class not found');
    final body = src.substring(start, src.indexOf('\n}', start));
    return {
      for (final m in constDecl.allMatches(body)) m.group(1)!: m.group(2)!,
    };
  }

  test('every constant\'s value is identical to its name', () {
    final constants = nativeMethodConstants();
    expect(constants, isNotEmpty);

    final mismatched = {
      for (final e in constants.entries)
        if (e.key != e.value) e.key: e.value,
    };
    expect(
      mismatched,
      isEmpty,
      reason:
          'A NativeMethod constant whose VALUE differs from its NAME is how '
          'the promotion to constants could have gone silently wrong — the '
          'Dart code reads correctly while a different string crosses the '
          'bridge. Offenders (name: value): $mismatched',
    );
  });

  test('no two constants send the same wire name', () {
    final constants = nativeMethodConstants();
    final seen = <String, String>{};
    final duplicates = <String>[];
    for (final e in constants.entries) {
      final first = seen[e.value];
      if (first != null) {
        duplicates.add('${e.value} declared as both $first and ${e.key}');
      }
      seen[e.value] = e.key;
    }
    expect(duplicates, isEmpty, reason: duplicates.join('; '));
  });

  /// THE RATCHET. PR-0d exists because the debt kept regrowing: four
  /// `previewSet*` literals were added AFTER `NativeMethod` already existed,
  /// one per feature phase. Promoting the backlog once fixes nothing on its
  /// own — this is what stops the next one.
  test('no invokeMethod call in lib/ passes an inline string literal', () {
    // `invokeMethod`, an optional generic, the paren, optional whitespace or a
    // line break, then a quote.
    //
    // The generic is bounded on `(` rather than `>`, and that is the whole
    // point: the first version of this test used `<[^>]*>`, which cannot cross
    // a `>` and therefore could not see a NESTED generic. Sixteen call sites
    // escaped through that hole — every `invokeMethod<Map<dynamic, dynamic>>`
    // and `invokeMethod<List<dynamic>>` in the codebase, including
    // `generateCaptions`, `previewOpen` and `getDisplays` — and the test passed
    // anyway, which is worse than not having had it. A Dart type argument list
    // cannot contain `(`, so `[^(]*?` matches any depth of nesting and stops at
    // the call's own paren.
    final literalCall = RegExp(
      '''invokeMethod\\s*(<[^(]*?>)?\\s*\\(\\s*['"]''',
      multiLine: true,
    );

    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      for (final m in literalCall.allMatches(src)) {
        final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
        offenders.add('${entity.path}:$line');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These call sites name a native method with a bare string instead of '
          'a NativeMethod constant. Add the constant to '
          'lib/core/bridges/native_method_channel.dart and use it, so the '
          'name has exactly one spelling in the Dart codebase: $offenders',
    );
  });

  /// A Dart method with no handler on either platform is dead on arrival: it
  /// cannot do anything on any machine the app ships to. Platform-specific is
  /// fine and common (the bridge maps `MissingPluginException` to a fallback);
  /// nowhere at all is not.
  test('every constant is handled by macOS or Windows', () {
    final constants = nativeMethodConstants();

    final buffer = StringBuffer();
    for (final dir in const ['macos/Runner', 'windows/runner']) {
      for (final entity in Directory(dir).listSync(recursive: true)) {
        if (entity is! File) continue;
        if (!const [
          '.swift',
          '.cpp',
          '.h',
        ].any((e) => entity.path.endsWith(e))) {
          continue;
        }
        buffer.writeln(entity.readAsStringSync());
      }
    }
    final native = buffer.toString();

    final orphaned = constants.values
        .where((name) => !native.contains('"$name"'))
        .toList();
    expect(
      orphaned,
      isEmpty,
      reason:
          'Declared in NativeMethod but quoted in no Swift or C++ source, so '
          'calling it reaches no handler on any platform: $orphaned',
    );
  });
}
