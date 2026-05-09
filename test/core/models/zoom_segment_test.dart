import 'package:clingfy/core/models/app_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ZoomSegment serialization', () {
    test('legacy json without focusMode decodes as followCursor', () {
      final segment = ZoomSegment.fromMap({
        'id': 'seg-1',
        'startMs': 1000,
        'endMs': 2000,
        'source': 'manual',
      });

      expect(segment.focusMode, ZoomFocusMode.followCursor);
      expect(segment.fixedTarget, isNull);
    });

    test('legacy json with explicit followCursor decodes correctly', () {
      final segment = ZoomSegment.fromMap({
        'id': 'seg-1',
        'startMs': 1000,
        'endMs': 2000,
        'source': 'manual',
        'focusMode': 'followCursor',
      });

      expect(segment.focusMode, ZoomFocusMode.followCursor);
    });

    test('fixedTarget round-trip', () {
      final original = const ZoomSegment(
        id: 'seg-1',
        startMs: 1000,
        endMs: 2000,
        source: 'manual',
        focusMode: ZoomFocusMode.fixedTarget,
        fixedTarget: NormalizedPoint(0.25, 0.75),
      );

      final encoded = original.toMap();
      expect(encoded['focusMode'], 'fixedTarget');
      expect(encoded['fixedTarget'], isA<Map>());
      expect((encoded['fixedTarget'] as Map)['dx'], 0.25);
      expect((encoded['fixedTarget'] as Map)['dy'], 0.75);

      final decoded = ZoomSegment.fromMap(encoded);
      expect(decoded.focusMode, ZoomFocusMode.fixedTarget);
      expect(decoded.fixedTarget, const NormalizedPoint(0.25, 0.75));
    });

    test('followCursor encodes mode but omits fixedTarget', () {
      final seg = const ZoomSegment(
        id: 'seg-1',
        startMs: 1000,
        endMs: 2000,
        source: 'manual',
      );
      final encoded = seg.toMap();
      expect(encoded['focusMode'], 'followCursor');
      expect(encoded.containsKey('fixedTarget'), isFalse);
    });

    test('out-of-range fixedTarget clamps on decode', () {
      final segment = ZoomSegment.fromMap({
        'id': 'seg-1',
        'startMs': 1000,
        'endMs': 2000,
        'source': 'manual',
        'focusMode': 'fixedTarget',
        'fixedTarget': {'dx': 1.5, 'dy': -0.2},
      });

      expect(segment.fixedTarget, const NormalizedPoint(1.0, 0.0));
    });

    test('copyWith with clearFixedTarget drops the target', () {
      const seg = ZoomSegment(
        id: 'seg-1',
        startMs: 1000,
        endMs: 2000,
        source: 'manual',
        focusMode: ZoomFocusMode.fixedTarget,
        fixedTarget: NormalizedPoint(0.4, 0.6),
      );

      final cleared = seg.copyWith(
        focusMode: ZoomFocusMode.followCursor,
        clearFixedTarget: true,
      );
      expect(cleared.focusMode, ZoomFocusMode.followCursor);
      expect(cleared.fixedTarget, isNull);
    });
  });
}
