class RecordedDurationTracker {
  DateTime? _wallClockSessionStart;
  DateTime? _activeSegmentStart;
  Duration _accumulated = Duration.zero;

  bool get hasStarted => _wallClockSessionStart != null;
  bool get isPaused => hasStarted && _activeSegmentStart == null;

  void start([DateTime? now]) {
    final startedAt = now ?? DateTime.now();
    _wallClockSessionStart = startedAt;
    _activeSegmentStart = startedAt;
    _accumulated = Duration.zero;
  }

  void pause([DateTime? now]) {
    final activeSegmentStart = _activeSegmentStart;
    if (activeSegmentStart == null) return;
    final pausedAt = now ?? DateTime.now();
    _accumulated += pausedAt.difference(activeSegmentStart);
    _activeSegmentStart = null;
  }

  void resume([DateTime? now]) {
    if (_wallClockSessionStart == null || _activeSegmentStart != null) return;
    _activeSegmentStart = now ?? DateTime.now();
  }

  Duration current([DateTime? now]) {
    final activeSegmentStart = _activeSegmentStart;
    if (activeSegmentStart == null) return _accumulated;
    return _accumulated +
        (now ?? DateTime.now()).difference(activeSegmentStart);
  }

  void reset() {
    _wallClockSessionStart = null;
    _activeSegmentStart = null;
    _accumulated = Duration.zero;
  }
}
