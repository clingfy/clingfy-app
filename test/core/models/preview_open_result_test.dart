import 'package:clingfy/core/models/app_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PreviewOpenResult', () {
    test('none() represents the macOS / no-texture reply', () {
      const result = PreviewOpenResult.none();
      expect(result.textureId, isNull);
      expect(result.hasTexture, isFalse);
      expect(result.width, 0);
      expect(result.videoWidth, 0);
      expect(result.sharedHandleOk, isFalse);
    });

    test('fromMap parses a fully-populated Windows reply', () {
      final result = PreviewOpenResult.fromMap(<dynamic, dynamic>{
        'textureId': 42,
        'width': 1920,
        'height': 1080,
        'videoWidth': 1280,
        'videoHeight': 720,
        'sharedHandleOk': true,
      });
      expect(result.textureId, 42);
      expect(result.hasTexture, isTrue);
      expect(result.width, 1920);
      expect(result.height, 1080);
      expect(result.videoWidth, 1280);
      expect(result.videoHeight, 720);
      expect(result.sharedHandleOk, isTrue);
    });

    test('fromMap treats negative textureId as no-texture', () {
      final result = PreviewOpenResult.fromMap(<dynamic, dynamic>{
        'textureId': -1,
        'width': 0,
        'height': 0,
        'videoWidth': 0,
        'videoHeight': 0,
        'sharedHandleOk': false,
      });
      expect(result.textureId, isNull);
      expect(result.hasTexture, isFalse);
    });

    test('fromMap accepts numeric (num) values from the platform codec', () {
      final result = PreviewOpenResult.fromMap(<dynamic, dynamic>{
        'textureId': 12.0,
        'width': 1920.0,
        'height': 1080.0,
        'videoWidth': 1280.0,
        'videoHeight': 720.0,
        'sharedHandleOk': true,
      });
      expect(result.textureId, 12);
      expect(result.width, 1920);
      expect(result.height, 1080);
    });

    test(
      'fromMap defaults missing or wrong-type fields to safe zero values',
      () {
        final result = PreviewOpenResult.fromMap(<dynamic, dynamic>{
          'textureId': 'not-a-number',
          // width/height/videoWidth/videoHeight/sharedHandleOk all missing
        });
        expect(result.textureId, isNull);
        expect(result.hasTexture, isFalse);
        expect(result.width, 0);
        expect(result.height, 0);
        expect(result.videoWidth, 0);
        expect(result.videoHeight, 0);
        expect(result.sharedHandleOk, isFalse);
      },
    );
  });
}
