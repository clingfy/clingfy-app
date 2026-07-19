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

  test('scene info audio presence keys are tri-state (absent = unknown)', () {
    // macOS shape today: no keys at all — the sidebar must keep its legacy
    // device-selection gate, so "unknown", never false.
    final legacy = RecordingSceneInfo.fromMap({'screenPath': '/tmp/r.mov'});
    expect(legacy.hasMicAudio, isNull);
    expect(legacy.hasSystemAudio, isNull);
    expect(legacy.hasRecordedAudio, isNull);

    // Windows audio separation (D10): explicit keys ride the native decode
    // probe. Any decodable track means the recording has audio.
    final micOnly = RecordingSceneInfo.fromMap({
      'screenPath': '/tmp/r.mov',
      'hasMicAudio': true,
      'hasSystemAudio': false,
    });
    expect(micOnly.hasRecordedAudio, isTrue);

    final silent = RecordingSceneInfo.fromMap({
      'screenPath': '/tmp/r.mov',
      'hasMicAudio': false,
      'hasSystemAudio': false,
    });
    expect(silent.hasRecordedAudio, isFalse);

    // A malformed (non-bool) value degrades to unknown, not a crash.
    final malformed = RecordingSceneInfo.fromMap({
      'screenPath': '/tmp/r.mov',
      'hasMicAudio': 'yes',
    });
    expect(malformed.hasMicAudio, isNull);
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
