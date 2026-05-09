import 'dart:ui';

import 'package:clingfy/core/zoom/fitted_content_rect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fittedContentRect', () {
    test('matching aspect fills viewport', () {
      final rect = fittedContentRect(
        const Size(1920, 1080),
        const Size(960, 540),
      );
      expect(rect.left, 0);
      expect(rect.top, 0);
      expect(rect.width, 960);
      expect(rect.height, 540);
    });

    test('wider source than viewport letterboxes top/bottom', () {
      final rect = fittedContentRect(
        const Size(1920, 1080), // 16:9
        const Size(800, 600), // 4:3
      );
      expect(rect.width, 800);
      expect(rect.height, 450);
      expect(rect.left, 0);
      expect(rect.top, 75);
    });

    test('taller source than viewport pillarboxes left/right', () {
      final rect = fittedContentRect(
        const Size(1080, 1920), // 9:16
        const Size(800, 600), // 4:3
      );
      // viewport.height (600) drives content height; width = 600 * 9/16 = 337.5
      expect(rect.height, 600);
      expect(rect.width, closeTo(337.5, 0.001));
      expect(rect.top, 0);
      expect(rect.left, closeTo((800 - 337.5) / 2, 0.001));
    });

    test('zero source size returns Rect.zero', () {
      expect(fittedContentRect(Size.zero, const Size(800, 600)), Rect.zero);
    });

    test('zero viewport returns Rect.zero', () {
      expect(fittedContentRect(const Size(1920, 1080), Size.zero), Rect.zero);
    });
  });

  group('fittedPointToViewport', () {
    final content = Rect.fromLTWH(100, 50, 800, 450);

    test('center maps to content rect center', () {
      final p = fittedPointToViewport(0.5, 0.5, content);
      expect(p, Offset(100 + 400, 50 + 225));
    });

    test('top-left maps to content rect top-left', () {
      final p = fittedPointToViewport(0, 0, content);
      expect(p, const Offset(100, 50));
    });

    test('bottom-right maps to content rect bottom-right', () {
      final p = fittedPointToViewport(1, 1, content);
      expect(p, const Offset(900, 500));
    });
  });

  group('viewportPointToNormalized', () {
    final content = Rect.fromLTWH(100, 50, 800, 450);

    test('center of content maps to (0.5, 0.5)', () {
      final n = viewportPointToNormalized(const Offset(500, 275), content);
      expect(n.dx, 0.5);
      expect(n.dy, 0.5);
    });

    test('top-left of content maps to (0, 0)', () {
      final n = viewportPointToNormalized(const Offset(100, 50), content);
      expect(n.dx, 0);
      expect(n.dy, 0);
    });

    test('bottom-right of content maps to (1, 1)', () {
      final n = viewportPointToNormalized(const Offset(900, 500), content);
      expect(n.dx, 1);
      expect(n.dy, 1);
    });

    test('point above content clamps to dy=0', () {
      final n = viewportPointToNormalized(const Offset(500, 0), content);
      expect(n.dy, 0);
    });

    test('point right of content clamps to dx=1', () {
      final n = viewportPointToNormalized(const Offset(2000, 275), content);
      expect(n.dx, 1);
    });

    test('point left of content clamps to dx=0', () {
      final n = viewportPointToNormalized(const Offset(-50, 275), content);
      expect(n.dx, 0);
    });

    test('zero content rect returns center fallback', () {
      final n = viewportPointToNormalized(const Offset(10, 10), Rect.zero);
      expect(n.dx, 0.5);
      expect(n.dy, 0.5);
    });
  });
}
