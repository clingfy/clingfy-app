/// Shared frame-grid math for the editing timeline.
///
/// This is the single source of truth for how editable timestamps are snapped
/// and clamped, extracted verbatim from `ZoomEditorController` so every future
/// track (clips, captions, audio) agrees on the same frame boundaries. Keeping
/// one timebase prevents silent cross-track disagreement once more than one
/// track edits the same recording.
///
/// Pure value type — no Flutter, no native, no I/O — so it is fully unit
/// testable and identical on macOS and Windows.
class TimelineTimebase {
  const TimelineTimebase(this.durationMs);

  /// Authoritative length of the recording in milliseconds. All snapped /
  /// normalized results are clamped to `[0, durationMs]`.
  final int durationMs;

  /// One frame at 60 fps, in milliseconds. Editable timestamps snap to this
  /// grid when snapping is enabled.
  static const double frameMs = 1000 / 60;

  /// Smallest editable span (two frames). A segment shorter than this is
  /// rejected by the editor.
  static int get minDurationMs => (frameMs * 2).round();

  /// Snaps [ms] to the nearest 60 fps frame boundary and clamps it to the
  /// timeline bounds.
  int snapToGrid(int ms) {
    final snapped = (ms / frameMs).round() * frameMs;
    return snapped.round().clamp(0, durationMs);
  }

  /// Clamps [ms] to `[0, durationMs]` and, when [snapping] is true, aligns it
  /// to the frame grid. Snap-off returns the raw clamped value.
  int normalizeEditableMs(int ms, {bool snapping = true}) {
    final clamped = ms.clamp(0, durationMs);
    if (!snapping) return clamped;
    return snapToGrid(clamped);
  }
}
