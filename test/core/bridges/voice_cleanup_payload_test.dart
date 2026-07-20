import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_helpers/native_test_setup.dart';

/// Pins the `previewSetVoiceCleanup` wire contract.
///
/// Nothing else in the test suite pins it, and a mismatch is silent on both
/// sides: Swift's method switch would fall through to
/// `FlutterMethodNotImplemented` and Dart swallows that, so the preview would
/// just keep playing the un-cleaned mic with no error anywhere.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  /// The logger flushes on this same channel, so only the calls under test are
  /// interesting.
  List<MethodCall> cleanupCalls() =>
      calls.where((c) => c.method == 'previewSetVoiceCleanup').toList();

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenRecorderChannel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenRecorderChannel, null);
  });

  test('sends the method name and payload the Swift handler parses', () async {
    await NativeBridge.instance.previewSetVoiceCleanup(
      voiceCleanup: const VoiceCleanup(enabled: true, mode: CleanupMode.light),
      sessionId: 'rec_1',
    );

    expect(cleanupCalls(), hasLength(1));
    final args = Map<String, dynamic>.from(
      cleanupCalls().single.arguments as Map<dynamic, dynamic>,
    );
    expect(args['sessionId'], 'rec_1');
    expect(args['voiceCleanup'], {'enabled': true, 'mode': 'light'});
  });

  test('omits sessionId when there is none', () async {
    await NativeBridge.instance.previewSetVoiceCleanup(
      voiceCleanup: const VoiceCleanup(),
      sessionId: null,
    );

    final args = Map<String, dynamic>.from(
      cleanupCalls().single.arguments as Map<dynamic, dynamic>,
    );
    expect(args.containsKey('sessionId'), isFalse);
    expect(args['voiceCleanup'], {'enabled': false, 'mode': 'balanced'});
  });

  test('a native build without the method is not an error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenRecorderChannel, (call) async {
          throw MissingPluginException('no such method');
        });

    await expectLater(
      NativeBridge.instance.previewSetVoiceCleanup(
        voiceCleanup: const VoiceCleanup(enabled: true),
        sessionId: 'rec_1',
      ),
      completes,
    );
  });
}
