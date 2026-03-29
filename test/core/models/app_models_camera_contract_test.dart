import 'package:clingfy/core/models/app_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recording scene info ignores deprecated advanced styling flag', () {
    final scene = RecordingSceneInfo.fromMap({
      'screenPath': '/tmp/recording.mov',
      'supportsAdvancedCameraExportStyling': false,
    });

    expect(scene.cameraExportCapabilities.shapeMask, isTrue);
    expect(scene.cameraExportCapabilities.cornerRadius, isTrue);
    expect(scene.cameraExportCapabilities.border, isTrue);
    expect(scene.cameraExportCapabilities.shadow, isTrue);
    expect(scene.cameraExportCapabilities.chromaKey, isTrue);
  });
}
