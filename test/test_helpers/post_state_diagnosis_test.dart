import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'post_state_diagnosis.dart';
import 'wait_until.dart';

// The diagnosis is only worth having if it separates the two causes a bare
// timeout cannot: a write that STALLED (older value still on disk, or a
// leftover `.tmp`) from a write that was LOST (no file, or no bundle). Those
// need opposite fixes, so each case is pinned by what the message must name.
//
// Context: #534. A five-second wait on a small write failed for weeks with
// nothing but "timed out after 5000ms", and the obvious move — raising the
// timeout — would have hidden the symptom rather than explaining it.
void main() {
  late Directory bundle;

  setUp(() {
    bundle = Directory.systemTemp.createTempSync('clingfy_diag_');
  });

  tearDown(() {
    if (bundle.existsSync()) {
      try {
        bundle.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows refuses to delete a directory with an open handle. Leaking
        // one temp dir is better than failing an unrelated test — which is
        // the exact class of flake this whole helper exists to diagnose.
      }
    }
  });

  Directory postDir() =>
      Directory('${bundle.path}${Platform.pathSeparator}post')
        ..createSync(recursive: true);

  File writeState(Map<String, dynamic> json) {
    final f = File('${postDir().path}${Platform.pathSeparator}state.json');
    f.writeAsStringSync(jsonEncode(json));
    return f;
  }

  test('a missing bundle reads as a lost write, not a slow one', () {
    bundle.deleteSync(recursive: true);

    final detail = describePostStateOnDisk(bundle.path);

    expect(detail, contains('GONE'));
    expect(
      detail,
      contains('nothing could have been written'),
      reason: 'the message has to say which of the two causes this is',
    );
  });

  test('no state.json at all reads as never started', () {
    postDir();

    expect(describePostStateOnDisk(bundle.path), contains('state.json ABSENT'));
  });

  test('an older grade on disk is reported with its values', () {
    // The stall case: the write is pending or was overwritten, and the value
    // sitting there is the previous one. Without this, a timeout waiting for
    // exposure 0.5 looks identical to no write at all.
    writeState({
      'grade': {'exposure': 0.2, 'contrast': 0.0},
    });

    final detail = describePostStateOnDisk(bundle.path);

    expect(detail, contains('exposure=0.2'));
    expect(detail, contains('contrast=0.0'));
    expect(detail, isNot(contains('ABSENT')));
  });

  test('a leftover .tmp names the rename as the step that did not finish', () {
    // The single most useful signal here, and invisible from the loaded value:
    // the content was written but never moved into place.
    final state = writeState({
      'grade': {'exposure': 0.2},
    });
    File('${state.path}.tmp').writeAsStringSync('{"grade":{"exposure":0.9}}');

    final detail = describePostStateOnDisk(bundle.path);

    expect(detail, contains('LEFTOVER'));
    expect(detail, contains('rename did not complete'));
  });

  test('an empty file is called out as flushed-but-not-written', () {
    final f = File('${postDir().path}${Platform.pathSeparator}state.json');
    f.writeAsStringSync('');

    expect(describePostStateOnDisk(bundle.path), contains('EMPTY'));
  });

  test('corrupt JSON is reported as corrupt, not as a wrong value', () {
    // A third cause, distinct from a stall and from a lost write.
    // PostStateStore.load never throws and falls back to defaults, which would
    // turn "the file is corrupt" into "the value is wrong". Reading the file
    // directly is what keeps those apart.
    final f = File('${postDir().path}${Platform.pathSeparator}state.json');
    f.writeAsStringSync('{not json');

    final detail = describePostStateOnDisk(bundle.path);

    expect(detail, contains('UNREADABLE'));
    // The size and mtime still have to survive the parse failure -- they are
    // what say how far the write got.
    expect(detail, contains('mtime='));
    expect(detail, contains('B '));
  });

  test('the reported age makes a stall measurable', () {
    writeState({
      'grade': {'exposure': 0.2},
    });

    expect(describePostStateOnDisk(bundle.path), contains('ms ago'));
  });

  // --- the wiring, not just the message ---

  test('waitUntil appends the diagnosis to a timeout', () async {
    writeState({
      'grade': {'exposure': 0.2},
    });

    await expectLater(
      waitUntil(
        () => false,
        timeout: const Duration(milliseconds: 40),
        reason: 'post/state.json after a color commit',
        diagnose: () => describePostStateOnDisk(bundle.path),
      ),
      throwsA(
        isA<StateError>()
            .having(
              (e) => e.message,
              'message',
              contains('after a color commit'),
            )
            .having((e) => e.message, 'message', contains('exposure=0.2')),
      ),
    );
  });

  test('a diagnosis that throws does not replace the timeout', () async {
    // Reading a file another process holds open throws on Windows — the very
    // platform these timeouts appear on. Losing the timeout to that would
    // discard the finding.
    await expectLater(
      waitUntil(
        () => false,
        timeout: const Duration(milliseconds: 40),
        reason: 'the real failure',
        diagnose: () => throw const FileSystemException('handle in use'),
      ),
      throwsA(
        isA<StateError>()
            .having((e) => e.message, 'message', contains('the real failure'))
            .having((e) => e.message, 'message', contains('diagnosis threw')),
      ),
    );
  });

  test('a passing wait never pays for the diagnosis', () async {
    var calls = 0;
    await waitUntil(
      () => true,
      diagnose: () {
        calls++;
        return 'should not run';
      },
    );

    expect(calls, 0, reason: 'diagnosis is a failure path, not a poll cost');
  });
}
