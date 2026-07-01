import 'package:clingfy/app/home/widgets/live_camera_preview.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channel = const MethodChannel(NativeChannel.screenRecorder);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Mock getCameraPreviewTextureId to return [id] (or a null map when null).
  void mockTextureId(int? id) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getCameraPreviewTextureId') {
        return id == null ? null : <String, dynamic>{'textureId': id};
      }
      return null;
    });
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> pump(
    WidgetTester tester, {
    required bool isRecording,
    required bool cameraEnabled,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveCameraPreview(
            isRecording: isRecording,
            cameraEnabled: cameraEnabled,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('hidden when not recording', (tester) async {
    mockTextureId(7);
    await pump(tester, isRecording: false, cameraEnabled: true);
    expect(find.byType(Texture), findsNothing);
  });

  testWidgets('hidden when camera overlay disabled', (tester) async {
    mockTextureId(7);
    await pump(tester, isRecording: true, cameraEnabled: false);
    expect(find.byType(Texture), findsNothing);
  });

  testWidgets('shows Texture while recording with the camera enabled', (
    tester,
  ) async {
    mockTextureId(7);
    await pump(tester, isRecording: true, cameraEnabled: true);
    expect(find.byType(Texture), findsOneWidget);
  });

  testWidgets('no Texture and no crash when the id is unavailable (-1)', (
    tester,
  ) async {
    mockTextureId(-1);
    await pump(tester, isRecording: true, cameraEnabled: true);
    expect(find.byType(Texture), findsNothing);
  });

  testWidgets('no Texture and no crash when the native method is missing', (
    tester,
  ) async {
    // No handler → MissingPluginException (the macOS case). Must degrade to
    // no preview, not throw — this is the regression guard for the cross-
    // platform recording UI.
    messenger.setMockMethodCallHandler(channel, null);
    await pump(tester, isRecording: true, cameraEnabled: true);
    expect(find.byType(Texture), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
