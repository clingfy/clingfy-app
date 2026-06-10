import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/app/permissions/widgets/permissions_gate.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    debugPlatformKindOverride = PlatformKind.macos;
  });
  tearDown(() {
    debugPlatformKindOverride = null;
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(NativeChannel.screenRecorder);

  Future<void> mockPermissionStatus({
    bool screenRecording = false,
    bool microphone = false,
    bool camera = false,
    bool accessibility = false,
  }) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'getPermissionStatus':
              return <String, bool>{
                'screenRecording': screenRecording,
                'microphone': microphone,
                'camera': camera,
                'accessibility': accessibility,
              };
            default:
              return null;
          }
        });
  }

  Widget buildGate() {
    return MaterialApp(
      home: MacosTheme(
        data: MacosThemeData.light(),
        child: PermissionsGate(
          nativeBridge: NativeBridge.instance,
          child: const Scaffold(body: Text('Home child')),
        ),
      ),
    );
  }

  Future<void> pumpGate(WidgetTester tester) async {
    await tester.pumpWidget(buildGate());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('incomplete onboarding resumes at the saved step', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'onboarding_seen_v1': false,
      'onboarding_step_v1': 1,
    });
    await mockPermissionStatus(screenRecording: true);

    await pumpGate(tester);

    expect(find.text('Screen Recording (Required)'), findsOneWidget);
    expect(find.text('Home child'), findsNothing);
  });

  testWidgets(
    'saved accessibility step is restored even without screen recording',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'onboarding_seen_v1': false,
        'onboarding_step_v1': 3,
      });
      await mockPermissionStatus(screenRecording: false);

      await pumpGate(tester);

      expect(find.text('Cursor Magic (Optional)'), findsOneWidget);
      expect(find.text('Home child'), findsNothing);
    },
  );

  testWidgets(
    'completed onboarding skips the gate even when screen recording is missing',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'onboarding_seen_v1': true,
        'onboarding_step_v1': 2,
      });
      await mockPermissionStatus(screenRecording: false);

      await pumpGate(tester);

      expect(find.text('Home child'), findsOneWidget);
      expect(find.text('Welcome to Clingfy'), findsNothing);
    },
  );
}
