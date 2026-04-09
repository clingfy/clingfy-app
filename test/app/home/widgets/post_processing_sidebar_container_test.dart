import 'dart:ui' show Tristate;

import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/widgets/post_processing_sidebar_container.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:provider/provider.dart';

import '../../../test_helpers/native_test_setup.dart';

class _Harness {
  _Harness({
    required this.settings,
    required this.recording,
    required this.device,
    required this.player,
    required this.post,
  });

  final SettingsController settings;
  final RecordingController recording;
  final DeviceController device;
  final PlayerController player;
  final PostProcessingController post;

  void dispose() {
    post.dispose();
    player.dispose();
    settings.dispose();
  }
}

class _FakeRecordingController extends Fake implements RecordingController {
  @override
  bool get canInteractWithPreview => true;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  void dispose() {}
}

class _FakeDeviceController extends Fake implements DeviceController {
  @override
  String get selectedAudioSourceId => DeviceController.noAudioId;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  Future<_Harness> createHarness() async {
    final nativeBridge = NativeBridge.instance;
    final settings = SettingsController(nativeBridge: nativeBridge);
    await settings.loadPreferences();

    final recording = _FakeRecordingController();
    final device = _FakeDeviceController();
    final player = PlayerController(nativeBridge: nativeBridge);
    final post = PostProcessingController(
      settings: settings,
      player: player,
      channel: nativeBridge,
    );
    return _Harness(
      settings: settings,
      recording: recording,
      device: device,
      player: player,
      post: post,
    );
  }

  Widget buildTestApp(_Harness harness) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<RecordingController>.value(
          value: harness.recording,
        ),
        ChangeNotifierProvider<DeviceController>.value(value: harness.device),
        ChangeNotifierProvider<PostProcessingController>.value(
          value: harness.post,
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildDarkTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.dark,
        home: MacosTheme(
          data: buildMacosTheme(Brightness.dark),
          child: Scaffold(
            body: PostProcessingSidebarContainer(
              settingsController: harness.settings,
              isRecording: false,
              selectedIndex: 0,
              availableWidth: 360,
              isCompact: false,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'container rebuilds canvas aspect selection when post settings change',
    (tester) async {
      final semanticsHandle = tester.ensureSemantics();
      final harness = await createHarness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(buildTestApp(harness));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final autoFinder = find.byKey(
        const ValueKey('canvas_aspect_option_auto'),
      );
      final wideFinder = find.byKey(
        const ValueKey('canvas_aspect_option_youtube169'),
      );

      expect(
        tester.getSemantics(autoFinder).flagsCollection.isSelected ==
            Tristate.isTrue,
        isTrue,
      );
      expect(
        tester.getSemantics(wideFinder).flagsCollection.isSelected ==
            Tristate.isTrue,
        isFalse,
      );

      harness.settings.post.updateLayoutPreset(LayoutPreset.youtube169);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        tester.getSemantics(autoFinder).flagsCollection.isSelected ==
            Tristate.isTrue,
        isFalse,
      );
      expect(
        tester.getSemantics(wideFinder).flagsCollection.isSelected ==
            Tristate.isTrue,
        isTrue,
      );

      semanticsHandle.dispose();
    },
  );
}
