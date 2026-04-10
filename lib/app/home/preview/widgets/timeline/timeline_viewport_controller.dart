import 'dart:math' as math;

import 'package:flutter/foundation.dart';

class TimelineViewportController extends ChangeNotifier {
  TimelineViewportController({
    required int durationMs,
    double zoomLevel = 1.0,
    this.minZoom = 1.0,
    this.maxZoom = 12.0,
  }) : _durationMs = durationMs > 0 ? durationMs : 1,
       _zoomLevel = zoomLevel.clamp(minZoom, maxZoom);

  final double minZoom;
  final double maxZoom;

  int _durationMs;
  double _zoomLevel;
  double _viewportWidth = 1.0;
  double _scrollOffset = 0.0;

  int get durationMs => _durationMs;
  double get zoomLevel => _zoomLevel;
  double get viewportWidth => _viewportWidth;
  double get scrollOffset => _scrollOffset;
  double get contentWidth =>
      math.max(_viewportWidth, _viewportWidth * _zoomLevel);
  double get maxScrollOffset => math.max(0.0, contentWidth - _viewportWidth);

  int get visibleStartMs => canvasXToMs(_scrollOffset);
  int get visibleEndMs => canvasXToMs(_scrollOffset + _viewportWidth);

  void setDurationMs(int durationMs) {
    if (!configure(durationMs: durationMs, viewportWidth: _viewportWidth)) {
      return;
    }
    notifyListeners();
  }

  void setViewportWidth(double viewportWidth) {
    if (!configure(durationMs: _durationMs, viewportWidth: viewportWidth)) {
      return;
    }
    notifyListeners();
  }

  bool configure({required int durationMs, required double viewportWidth}) {
    final nextDuration = durationMs > 0 ? durationMs : 1;
    final nextWidth = viewportWidth > 0 ? viewportWidth : 1.0;
    final durationChanged = _durationMs != nextDuration;
    final widthChanged = (_viewportWidth - nextWidth).abs() >= 0.01;
    if (!durationChanged && !widthChanged) return false;

    final visibleCenterMs = canvasXToMs(_scrollOffset + (_viewportWidth / 2));
    _durationMs = nextDuration;
    _viewportWidth = nextWidth;
    _scrollOffset = clampScrollOffset(
      msToCanvasX(visibleCenterMs) - (_viewportWidth / 2),
    );
    return true;
  }

  void setScrollOffset(double scrollOffset) {
    final clamped = clampScrollOffset(scrollOffset);
    if ((_scrollOffset - clamped).abs() < 0.01) return;
    _scrollOffset = clamped;
    notifyListeners();
  }

  void panByPixels(double delta) {
    setScrollOffset(_scrollOffset + delta);
  }

  double clampScrollOffset(double scrollOffset) {
    return scrollOffset.clamp(0.0, maxScrollOffset);
  }

  double msToCanvasX(int ms) {
    if (_durationMs <= 0) return 0.0;
    return (ms.clamp(0, _durationMs) / _durationMs) * contentWidth;
  }

  double msToViewportX(int ms) {
    return msToCanvasX(ms) - _scrollOffset;
  }

  int canvasXToMs(double x) {
    if (contentWidth <= 0 || _durationMs <= 0) return 0;
    final clamped = x.clamp(0.0, contentWidth);
    return ((clamped / contentWidth) * _durationMs).round().clamp(
      0,
      _durationMs,
    );
  }

  int viewportXToMs(double x) {
    return canvasXToMs(_scrollOffset + x);
  }

  void setZoomLevel(double zoomLevel, {double? anchorViewportDx}) {
    final clampedZoom = zoomLevel.clamp(minZoom, maxZoom);
    if ((_zoomLevel - clampedZoom).abs() < 0.0001) return;

    final anchorDx = anchorViewportDx ?? (_viewportWidth / 2);
    final anchorMs = viewportXToMs(anchorDx);

    _zoomLevel = clampedZoom;
    _scrollOffset = clampScrollOffset(msToCanvasX(anchorMs) - anchorDx);
    notifyListeners();
  }

  void zoomIn({double? anchorViewportDx}) {
    setZoomLevel(_zoomLevel * 1.25, anchorViewportDx: anchorViewportDx);
  }

  void zoomOut({double? anchorViewportDx}) {
    setZoomLevel(_zoomLevel / 1.25, anchorViewportDx: anchorViewportDx);
  }

  void fitToDuration({int? centerMs}) {
    _zoomLevel = minZoom;
    if (centerMs == null) {
      _scrollOffset = 0.0;
      notifyListeners();
      return;
    }
    centerOnMs(centerMs, notify: false);
    notifyListeners();
  }

  void centerOnMs(int ms, {bool notify = true}) {
    _scrollOffset = clampScrollOffset(msToCanvasX(ms) - (_viewportWidth / 2));
    if (notify) {
      notifyListeners();
    }
  }
}
