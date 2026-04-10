import 'package:clingfy/app/home/preview/widgets/timeline/timeline_viewport_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fitToDuration resets zoom and scroll offset', () {
    final controller = TimelineViewportController(durationMs: 60000);

    controller.setViewportWidth(400);
    controller.setZoomLevel(4);
    controller.setScrollOffset(200);
    controller.fitToDuration();

    expect(controller.zoomLevel, 1.0);
    expect(controller.scrollOffset, 0.0);
    expect(controller.visibleStartMs, 0);
    expect(controller.visibleEndMs, 60000);
  });

  test('zoom is clamped between min and max', () {
    final controller = TimelineViewportController(durationMs: 60000);

    controller.setViewportWidth(400);
    controller.setZoomLevel(100);
    expect(controller.zoomLevel, controller.maxZoom);

    controller.setZoomLevel(0.25);
    expect(controller.zoomLevel, controller.minZoom);
  });

  test('derived visible range follows scroll offset and zoom', () {
    final controller = TimelineViewportController(durationMs: 60000);

    controller.setViewportWidth(400);
    controller.setZoomLevel(2);
    controller.setScrollOffset(200);

    expect(controller.visibleStartMs, 15000);
    expect(controller.visibleEndMs, 45000);
  });

  test('scroll offset is clamped to content bounds', () {
    final controller = TimelineViewportController(durationMs: 60000);

    controller.setViewportWidth(400);
    controller.setZoomLevel(3);
    controller.setScrollOffset(5000);

    expect(controller.scrollOffset, controller.maxScrollOffset);
  });

  test('panByPixels adjusts scroll offset and respects bounds', () {
    final controller = TimelineViewportController(durationMs: 60000);

    controller.setViewportWidth(400);
    controller.setZoomLevel(3);
    controller.setScrollOffset(120);
    controller.panByPixels(90);

    expect(controller.scrollOffset, 210);

    controller.panByPixels(-500);
    expect(controller.scrollOffset, 0);
  });

  test('msToX and xToMs stay inverse within rounding tolerance', () {
    final controller = TimelineViewportController(durationMs: 60000);

    controller.setViewportWidth(500);
    controller.setZoomLevel(2.5);

    final canvasX = controller.msToCanvasX(18000);
    final restoredMs = controller.canvasXToMs(canvasX);

    expect(restoredMs, closeTo(18000, 1));
  });
}
