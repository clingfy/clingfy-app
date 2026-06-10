import 'package:clingfy/app/home/overlay/overlay_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../test_helpers/native_test_setup.dart';

/// Phase 10.3: the Windows native area crop region is process-memory only.
/// Restoring the Dart half after a restart made the sidebar claim a
/// selection that RecordingEngine::Start rejects with TARGET_ERROR — so on
/// Windows the persisted area selection is cleared at startup; macOS (which
/// persists the region natively) keeps restoring.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const areaPrefs = <String, Object>{
    'pref.areaDisplayId': 1,
    'pref.areaRect.x': 10.0,
    'pref.areaRect.y': 20.0,
    'pref.areaRect.width': 300.0,
    'pref.areaRect.height': 200.0,
  };

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    debugPlatformKindOverride = null;
    await clearCommonNativeMocks();
  });

  Future<OverlayController> pumpController() async {
    final controller = OverlayController(bridge: NativeBridge.instance);
    // _init is fire-and-forget from the constructor; let it settle.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return controller;
  }

  test('Windows: stale area selection is cleared at startup', () async {
    debugPlatformKindOverride = PlatformKind.windows;
    SharedPreferences.setMockInitialValues(Map.of(areaPrefs));

    final controller = await pumpController();
    addTearDown(controller.dispose);

    expect(controller.areaRect, isNull);
    expect(controller.areaDisplayId, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('pref.areaDisplayId'), isNull);
    expect(prefs.getDouble('pref.areaRect.x'), isNull);
  });

  test(
    'macOS: persisted area selection is restored (native half is real)',
    () async {
      debugPlatformKindOverride = PlatformKind.macos;
      SharedPreferences.setMockInitialValues(Map.of(areaPrefs));

      final controller = await pumpController();
      addTearDown(controller.dispose);

      expect(controller.areaRect, isNotNull);
      expect(controller.areaRect!.width, 300.0);
      expect(controller.areaDisplayId, 1);
    },
  );
}
