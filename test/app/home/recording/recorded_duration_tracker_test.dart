import 'package:clingfy/app/home/recording/recorded_duration_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recorded duration excludes paused wall-clock gaps', () {
    final tracker = RecordedDurationTracker();
    final start = DateTime(2026, 3, 27, 10, 0, 0);

    tracker.start(start);

    expect(
      tracker.current(start.add(const Duration(seconds: 5))),
      const Duration(seconds: 5),
    );

    tracker.pause(start.add(const Duration(seconds: 5)));

    expect(tracker.isPaused, isTrue);
    expect(
      tracker.current(start.add(const Duration(seconds: 20))),
      const Duration(seconds: 5),
    );

    tracker.resume(start.add(const Duration(seconds: 20)));

    expect(
      tracker.current(start.add(const Duration(seconds: 27))),
      const Duration(seconds: 12),
    );
  });

  test('reset clears accumulated state', () {
    final tracker = RecordedDurationTracker();
    final start = DateTime(2026, 3, 27, 10, 0, 0);

    tracker.start(start);
    tracker.pause(start.add(const Duration(seconds: 3)));
    tracker.reset();

    expect(tracker.hasStarted, isFalse);
    expect(tracker.isPaused, isFalse);
    expect(
      tracker.current(start.add(const Duration(seconds: 10))),
      Duration.zero,
    );
  });
}
