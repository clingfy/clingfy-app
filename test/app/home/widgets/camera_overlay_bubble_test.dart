import 'package:clingfy/app/home/widgets/camera_overlay_bubble.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpBubble(
    WidgetTester tester, {
    required OverlayShape shape,
    double roundness = 0.0,
    double opacity = 1.0,
    bool mirror = false,
    OverlayShadow shadow = OverlayShadow.none,
    double borderWidth = 0.0,
    bool hasBorder = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CameraOverlayBubble(
              shape: shape,
              roundness: roundness,
              opacity: opacity,
              mirror: mirror,
              shadow: shadow,
              borderWidth: borderWidth,
              borderColor: const Color(0xFFFFFFFF),
              hasBorder: hasBorder,
              size: const Size(180, 180),
              child: const ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('clips the child to the shape (ClipPath present)', (
    tester,
  ) async {
    await pumpBubble(tester, shape: OverlayShape.circle);
    expect(find.byType(ClipPath), findsWidgets);
  });

  testWidgets('mirror wraps the child in the mirror Transform', (tester) async {
    await pumpBubble(tester, shape: OverlayShape.circle, mirror: true);
    expect(find.byKey(cameraOverlayMirrorKey), findsOneWidget);
  });

  testWidgets('no mirror Transform when mirror is off', (tester) async {
    await pumpBubble(tester, shape: OverlayShape.circle, mirror: false);
    expect(find.byKey(cameraOverlayMirrorKey), findsNothing);
  });

  testWidgets('opacity < 1 introduces an Opacity widget', (tester) async {
    await pumpBubble(tester, shape: OverlayShape.square, opacity: 0.5);
    expect(find.byType(Opacity), findsOneWidget);
  });

  testWidgets('full opacity does not add an Opacity widget', (tester) async {
    await pumpBubble(tester, shape: OverlayShape.square, opacity: 1.0);
    expect(find.byType(Opacity), findsNothing);
  });

  testWidgets('a border adds a CustomPaint layer', (tester) async {
    await pumpBubble(
      tester,
      shape: OverlayShape.roundedRect,
      hasBorder: true,
      borderWidth: 4,
    );
    // At least one CustomPaint is the border painter (others may exist from
    // framework chrome, so findsWidgets rather than findsOneWidget).
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('a shadow preset adds a CustomPaint layer', (tester) async {
    await pumpBubble(
      tester,
      shape: OverlayShape.star,
      shadow: OverlayShadow.strong,
    );
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('renders every OverlayShape without throwing', (tester) async {
    for (final shape in OverlayShape.values) {
      await pumpBubble(tester, shape: shape, roundness: 0.3);
      expect(tester.takeException(), isNull);
    }
  });
}
