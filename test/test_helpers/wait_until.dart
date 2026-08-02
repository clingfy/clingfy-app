import 'dart:async';

/// Polls until [condition] holds, or throws once [timeout] elapses.
///
/// Use this whenever a test asserts on the result of a **fire-and-forget** file
/// write — the `unawaited(SomeStore.save(...))` pattern the editor controllers
/// use so a save never blocks an edit.
///
/// The trap this replaces: `await pumpEventQueue()` (or a fixed
/// `Future.delayed`) followed by a synchronous read. `pumpEventQueue` drains the
/// microtask queue a bounded number of times; it does **not** wait for
/// `dart:io` thread-pool work to finish. Locally the write wins the race and the
/// test passes forever; on a loaded CI runner the read wins and the assertion
/// sees null. That produced exactly one intermittent CI failure in
/// `clip_editor_controller_test.dart` while passing 3/3 locally.
///
/// Polling is the right shape here rather than a longer sleep: it returns as
/// soon as the write lands (so the fast path stays fast) and it fails loudly
/// with a real message instead of silently reading stale state.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  Duration interval = const Duration(milliseconds: 5),
  String? reason,
}) async {
  if (condition()) return;
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(interval);
    if (condition()) return;
  }
  throw StateError(
    'waitUntil timed out after ${timeout.inMilliseconds}ms'
    '${reason == null ? '' : ': $reason'}',
  );
}

/// [waitUntil] for a value that is null until it exists, returning it.
///
/// Saves the `waitUntil(...)` + re-read dance when the thing being awaited is
/// the loaded state itself.
Future<T> waitForValue<T>(
  T? Function() read, {
  Duration timeout = const Duration(seconds: 5),
  Duration interval = const Duration(milliseconds: 5),
  String? reason,
}) async {
  await waitUntil(
    () => read() != null,
    timeout: timeout,
    interval: interval,
    reason: reason,
  );
  final value = read();
  if (value == null) {
    throw StateError('waitForValue: value vanished after it appeared');
  }
  return value;
}
