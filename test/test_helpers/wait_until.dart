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
///
/// [diagnose] is called ONLY on timeout, and whatever it returns is appended to
/// the failure. Use it to say what the world actually looked like when the
/// condition did not hold.
///
/// That distinction is the whole point of having it. A bare timeout on a file
/// write cannot tell a stall from a lost write, and those need opposite fixes —
/// one is a slow disk, the other is a bug. Reporting the file's real contents at
/// the moment of failure separates them: an older value means the write is
/// pending or was overwritten, no file at all means it never started. See #534,
/// where five seconds of silence on a small write went undiagnosed either way
/// for weeks. Raising the timeout would have hidden the symptom instead of
/// explaining it.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  Duration interval = const Duration(milliseconds: 5),
  String? reason,
  String Function()? diagnose,
}) async {
  if (condition()) return;
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(interval);
    if (condition()) return;
  }
  throw StateError(
    'waitUntil timed out after ${timeout.inMilliseconds}ms'
    '${reason == null ? '' : ': $reason'}'
    '${runTimeoutDiagnosis(diagnose)}',
  );
}

/// Runs [diagnose] defensively and formats it for a failure message.
///
/// A diagnosis that throws must not replace the timeout with its own error —
/// that would lose the very finding it exists to explain. Reading a file
/// another process is holding open is exactly the kind of thing that throws on
/// Windows, which is the platform these timeouts show up on.
///
/// Visible for testing; call sites use the `diagnose:` parameter.
String runTimeoutDiagnosis(String Function()? diagnose) {
  if (diagnose == null) return '';
  try {
    final detail = diagnose();
    return detail.isEmpty ? '' : '\n  on disk: $detail';
  } catch (e) {
    return '\n  on disk: <diagnosis threw: $e>';
  }
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
  String Function()? diagnose,
}) async {
  await waitUntil(
    () => read() != null,
    timeout: timeout,
    interval: interval,
    reason: reason,
    diagnose: diagnose,
  );
  final value = read();
  if (value == null) {
    throw StateError('waitForValue: value vanished after it appeared');
  }
  return value;
}
