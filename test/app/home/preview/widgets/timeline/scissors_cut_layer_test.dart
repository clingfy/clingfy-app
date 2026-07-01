import 'package:clingfy/app/home/preview/widgets/timeline/scissors_cut_layer.dart';
import 'package:clingfy/app/home/preview/widgets/timeline/timeline_viewport_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The cut layer is content-space: its local x maps straight to a timeline ms
  // via the shared viewport controller. At zoom 1 the controller's contentWidth
  // equals the viewport width (500 here), so x=250 → 500ms of a 1000ms clip.
  TimelineViewportController makeController() {
    final c = TimelineViewportController(durationMs: 1000);
    c.configure(durationMs: 1000, viewportWidth: 500);
    return c;
  }

  Widget host(
    TimelineViewportController controller,
    ValueChanged<int> onCutAt,
  ) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 500,
            height: 100,
            child: Stack(
              children: [
                ScissorsCutLayer(
                  viewportController: controller,
                  onCutAt: onCutAt,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('tapping the layer reports the pointer ms via canvasXToMs', (
    tester,
  ) async {
    final controller = makeController();
    addTearDown(controller.dispose);
    int? cutMs;

    await tester.pumpWidget(host(controller, (ms) => cutMs = ms));

    final layer = find.byKey(const Key('timeline_scissors_cut_layer'));
    final topLeft = tester.getTopLeft(layer);
    await tester.tapAt(topLeft + const Offset(250, 50));
    await tester.pump();

    expect(cutMs, controller.canvasXToMs(250));
    expect(cutMs, 500);
  });

  testWidgets('the scissors glyph appears only while the pointer hovers', (
    tester,
  ) async {
    final controller = makeController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(host(controller, (_) {}));

    // No pointer yet → no glyph.
    expect(find.byIcon(Icons.content_cut_rounded), findsNothing);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(
      tester.getCenter(find.byKey(const Key('timeline_scissors_cut_layer'))),
    );
    await tester.pump();

    expect(find.byIcon(Icons.content_cut_rounded), findsOneWidget);

    // Pointer leaves → glyph gone.
    await gesture.moveTo(const Offset(-50, -50));
    await tester.pump();
    expect(find.byIcon(Icons.content_cut_rounded), findsNothing);
  });
}
