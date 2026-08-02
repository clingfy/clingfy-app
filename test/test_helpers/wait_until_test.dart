import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'wait_until.dart';

/// The helper exists to replace `await pumpEventQueue()` before a synchronous
/// read of a fire-and-forget file write. Its value is entirely in two
/// properties, so both are pinned here: it returns as soon as the condition
/// holds (so it does not slow the happy path), and it FAILS LOUDLY on timeout
/// rather than letting the caller read stale state and assert on it.
void main() {
  test('returns immediately when the condition already holds', () async {
    var polls = 0;
    final sw = Stopwatch()..start();
    await waitUntil(() {
      polls++;
      return true;
    });
    sw.stop();

    expect(polls, 1, reason: 'no sleep on the fast path');
    expect(sw.elapsedMilliseconds, lessThan(50));
  });

  test('returns as soon as the condition flips', () async {
    var value = 0;
    Future<void>.delayed(const Duration(milliseconds: 30), () => value = 1);

    await waitUntil(() => value == 1);
    expect(value, 1);
  });

  test('throws with the reason when the condition never holds', () async {
    // This is the property that makes the helper better than a longer sleep:
    // the caller gets a real failure instead of an assertion on stale state.
    await expectLater(
      waitUntil(
        () => false,
        timeout: const Duration(milliseconds: 60),
        reason: 'clips_state.json never appeared',
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('timed out'), contains('clips_state.json')),
        ),
      ),
    );
  });

  test('waitForValue surfaces the value once it exists', () async {
    final dir = await Directory.systemTemp.createTemp('clingfy_waituntil_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final file = File('${dir.path}/late.txt');

    // Exactly the production shape: a write nobody awaited.
    Future<void>.delayed(
      const Duration(milliseconds: 25),
      () => file.writeAsStringSync('landed'),
    );

    final contents = await waitForValue(
      () => file.existsSync() ? file.readAsStringSync() : null,
    );
    expect(contents, 'landed');
  });

  test('waitForValue throws when the value never arrives', () async {
    await expectLater(
      waitForValue<String>(
        () => null,
        timeout: const Duration(milliseconds: 60),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
