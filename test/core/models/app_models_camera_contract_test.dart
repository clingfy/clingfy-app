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

  test('camera composition hidden defaults include new motion presets', () {
    const camera = CameraCompositionState.hidden();

    expect(camera.zoomBehavior, CameraCompositionState.defaultZoomBehavior);
    expect(
      camera.zoomScaleMultiplier,
      CameraCompositionState.defaultZoomScaleMultiplier,
    );
    expect(camera.introPreset, CameraCompositionState.defaultIntroPreset);
    expect(camera.outroPreset, CameraCompositionState.defaultOutroPreset);
    expect(
      camera.introDurationMs,
      CameraCompositionState.defaultIntroDurationMs,
    );
    expect(
      camera.outroDurationMs,
      CameraCompositionState.defaultOutroDurationMs,
    );
  });

  test('camera composition fromMap uses new motion defaults when missing', () {
    final camera = CameraCompositionState.fromMap({
      'visible': true,
      'layoutPreset': CameraLayoutPreset.overlayBottomRight.name,
    });

    expect(camera.zoomBehavior, CameraCompositionState.defaultZoomBehavior);
    expect(
      camera.zoomScaleMultiplier,
      CameraCompositionState.defaultZoomScaleMultiplier,
    );
    expect(camera.introPreset, CameraCompositionState.defaultIntroPreset);
    expect(camera.outroPreset, CameraCompositionState.defaultOutroPreset);
    expect(
      camera.introDurationMs,
      CameraCompositionState.defaultIntroDurationMs,
    );
    expect(
      camera.outroDurationMs,
      CameraCompositionState.defaultOutroDurationMs,
    );
  });

  test('camera composition fromMap keeps explicit motion values', () {
    final camera = CameraCompositionState.fromMap({
      'visible': true,
      'layoutPreset': CameraLayoutPreset.overlayBottomRight.name,
      'zoomBehavior': CameraZoomBehavior.fixed.name,
      'zoomScaleMultiplier': 0.6,
      'introPreset': CameraIntroPreset.none.name,
      'outroPreset': CameraOutroPreset.fade.name,
      'introDurationMs': 300,
      'outroDurationMs': 260,
    });

    expect(camera.zoomBehavior, CameraZoomBehavior.fixed);
    expect(camera.zoomScaleMultiplier, 0.6);
    expect(camera.introPreset, CameraIntroPreset.none);
    expect(camera.outroPreset, CameraOutroPreset.fade);
    expect(camera.introDurationMs, 300);
    expect(camera.outroDurationMs, 260);
  });
}
