import 'package:flutter/foundation.dart';

/// Declares which native zoom features the current macOS backend
/// supports. Older binaries that predate Phase 1 fixed-target support
/// return [ZoomNativeCapabilities.legacy] (all `false`), letting Dart
/// suppress UX that would otherwise be silently broken.
@immutable
class ZoomNativeCapabilities {
  final bool cursorSamples;
  final bool fixedTargetPreview;
  final bool fixedTargetExport;

  const ZoomNativeCapabilities({
    required this.cursorSamples,
    required this.fixedTargetPreview,
    required this.fixedTargetExport,
  });

  static const ZoomNativeCapabilities legacy = ZoomNativeCapabilities(
    cursorSamples: false,
    fixedTargetPreview: false,
    fixedTargetExport: false,
  );

  /// True when both the cursor-samples query and fixed-target preview
  /// rendering are available — the minimum needed to drive the
  /// smart-add heuristic without producing a no-op preview.
  bool get supportsSmartFixedTarget =>
      cursorSamples && fixedTargetPreview;

  static ZoomNativeCapabilities fromMap(Object? raw) {
    if (raw is! Map) return legacy;
    return ZoomNativeCapabilities(
      cursorSamples: raw['cursorSamples'] == true,
      fixedTargetPreview: raw['fixedTargetPreview'] == true,
      fixedTargetExport: raw['fixedTargetExport'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZoomNativeCapabilities &&
          other.cursorSamples == cursorSamples &&
          other.fixedTargetPreview == fixedTargetPreview &&
          other.fixedTargetExport == fixedTargetExport;

  @override
  int get hashCode => Object.hash(
    cursorSamples,
    fixedTargetPreview,
    fixedTargetExport,
  );

  @override
  String toString() =>
      'ZoomNativeCapabilities(cursorSamples: $cursorSamples, '
      'fixedTargetPreview: $fixedTargetPreview, '
      'fixedTargetExport: $fixedTargetExport)';
}

/// Thrown by [previewGetCursorSamples] when the native backend has not
/// implemented the channel method (i.e. `MissingPluginException`).
/// Distinguishes "native capability missing" from "cursor data missing"
/// — the latter still returns a valid (empty) [CursorSamplesResult].
class ZoomNativeCapabilityMissing implements Exception {
  final String method;
  final String? details;

  const ZoomNativeCapabilityMissing(this.method, [this.details]);

  @override
  String toString() =>
      'ZoomNativeCapabilityMissing(method: $method'
      '${details == null ? '' : ', details: $details'})';
}

/// Focus mode for a zoom segment. `followCursor` keeps the existing
/// behavior where the zoom transform tracks the recorded cursor path.
/// `fixedTarget` zooms around a fixed normalized point on the source
/// recording, used when cursor data is missing or static during the
/// segment.
enum ZoomFocusMode {
  followCursor,
  fixedTarget;

  String get wireValue => switch (this) {
    ZoomFocusMode.followCursor => 'followCursor',
    ZoomFocusMode.fixedTarget => 'fixedTarget',
  };

  static ZoomFocusMode fromWire(Object? raw) {
    if (raw is String && raw == 'fixedTarget') {
      return ZoomFocusMode.fixedTarget;
    }
    return ZoomFocusMode.followCursor;
  }
}

/// Normalized 2D coordinate inside the source recording. `dx` and `dy`
/// are in `[0, 1]`. `(0, 0)` is top-left, `(1, 1)` is bottom-right.
@immutable
class NormalizedPoint {
  final double dx;
  final double dy;

  const NormalizedPoint(this.dx, this.dy);

  static const NormalizedPoint center = NormalizedPoint(0.5, 0.5);

  NormalizedPoint clamped() {
    return NormalizedPoint(dx.clamp(0.0, 1.0), dy.clamp(0.0, 1.0));
  }

  Map<String, dynamic> toMap() => {'dx': dx, 'dy': dy};

  static NormalizedPoint? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final dx = raw['dx'];
    final dy = raw['dy'];
    if (dx is! num || dy is! num) return null;
    return NormalizedPoint(dx.toDouble(), dy.toDouble()).clamped();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NormalizedPoint && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(dx, dy);

  @override
  String toString() => 'NormalizedPoint($dx, $dy)';
}

/// A single recorded cursor sample. Coordinates are in source-recording
/// pixel space. `visible` is `false` when the cursor was hidden or off
/// the recorded surface at that instant.
@immutable
class CursorSample {
  final int tMs;
  final double x;
  final double y;
  final bool visible;

  const CursorSample({
    required this.tMs,
    required this.x,
    required this.y,
    required this.visible,
  });

  static CursorSample? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final tMs = raw['tMs'];
    final x = raw['x'];
    final y = raw['y'];
    if (tMs is! num || x is! num || y is! num) return null;
    final visible = raw['visible'];
    return CursorSample(
      tMs: tMs.toInt(),
      x: x.toDouble(),
      y: y.toDouble(),
      visible: visible is bool ? visible : true,
    );
  }
}

/// Result of [NativeBridge.previewGetCursorSamples]. `samples` are the
/// cursor samples that fall in the requested `[startMs, endMs]` range.
/// `playheadSample` is the closest sample to the requested `playheadMs`,
/// when available. `width` and `height` are the source recording
/// dimensions in pixels — used by the heuristic to normalize a fixed
/// target to `[0, 1]`.
@immutable
class CursorSamplesResult {
  final List<CursorSample> samples;
  final CursorSample? playheadSample;
  final double width;
  final double height;

  const CursorSamplesResult({
    required this.samples,
    required this.playheadSample,
    required this.width,
    required this.height,
  });

  static const CursorSamplesResult empty = CursorSamplesResult(
    samples: <CursorSample>[],
    playheadSample: null,
    width: 0,
    height: 0,
  );

  static CursorSamplesResult fromMap(Object? raw) {
    if (raw is! Map) return empty;
    final rawSamples = raw['samples'];
    final samples = <CursorSample>[];
    if (rawSamples is List) {
      for (final entry in rawSamples) {
        final sample = CursorSample.fromMap(entry);
        if (sample != null) samples.add(sample);
      }
    }
    final width = raw['width'];
    final height = raw['height'];
    return CursorSamplesResult(
      samples: samples,
      playheadSample: CursorSample.fromMap(raw['playheadSample']),
      width: width is num ? width.toDouble() : 0.0,
      height: height is num ? height.toDouble() : 0.0,
    );
  }
}
