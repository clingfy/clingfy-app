import 'package:clingfy/app/home/keyboard_shortcuts_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/native_test_setup.dart';

final List<LogEvent> _logged = <LogEvent>[];

/// Captures what the app would ship to a remote sink — the same events the
/// on-disk log receives.
class _CapturingSink implements RemoteLogSink {
  @override
  void send(LogEvent event) => _logged.add(event);
}

KeyboardShortcutsController _controller(SettingsController settings) {
  return KeyboardShortcutsController(
    settings: settings,
    onToggleRecording: () {},
    onRefreshDevices: () {},
    onToggleActionBar: () async {},
    onCycleOverlayMode: () async {},
    onExportVideo: () async {},
    onShowActionBar: () async {},
    onOpenSettings: () {},
    diagnostics: () => {'isRecording': true, 'phase': 'recording'},
  );
}

KeyDownEvent _keyDown(LogicalKeyboardKey key) {
  return KeyDownEvent(
    physicalKey: PhysicalKeyboardKey.keyA,
    logicalKey: key,
    timeStamp: Duration.zero,
  );
}

Future<void> _withModifier(
  LogicalKeyboardKey modifier,
  Future<void> Function() body,
) async {
  await simulateKeyDownEvent(modifier);
  try {
    await body();
  } finally {
    await simulateKeyUpEvent(modifier);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsController settings;

  setUp(() async {
    await installCommonNativeMocks();
    SharedPreferences.setMockInitialValues({});
    settings = SettingsController(nativeBridge: NativeBridge.instance);
    await settings.loadPreferences();
    _logged.clear();
    await Log.init(remoteSink: _CapturingSink());
  });

  tearDown(() async {
    settings.dispose();
    await clearCommonNativeMocks();
  });

  Iterable<LogEvent> shortcutLogs() =>
      _logged.where((e) => e.category == 'Shortcuts');

  testWidgets('an unbound modifier combo is recorded with diagnostics', (
    tester,
  ) async {
    final controller = _controller(settings);

    await _withModifier(LogicalKeyboardKey.meta, () async {
      // A combo nothing binds.
      controller.logUnhandledCombo(_keyDown(LogicalKeyboardKey.keyJ));
    });

    final entry = shortcutLogs().where(
      (e) => e.message == 'Shortcut combo not bound',
    );
    expect(entry, hasLength(1));
    // The diagnostics rider is the point: it distinguishes a swallowed key
    // from one that never arrived.
    expect(entry.first.context?['isRecording'], true);
    expect(entry.first.context?['phase'], 'recording');
    expect(entry.first.context?['meta'], true);
  });

  testWidgets('bare keystrokes are never logged', (tester) async {
    // This observer sits above every text field in the app. Logging
    // unmodified keys would write whatever the user types — passwords
    // included — into the log file.
    final controller = _controller(settings);

    for (final key in [
      LogicalKeyboardKey.keyA,
      LogicalKeyboardKey.keyS,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.space,
    ]) {
      controller.logUnhandledCombo(_keyDown(key));
    }

    expect(shortcutLogs(), isEmpty);
  });

  testWidgets('key-up events are ignored, so a combo logs once', (
    tester,
  ) async {
    final controller = _controller(settings);

    await _withModifier(LogicalKeyboardKey.meta, () async {
      controller.logUnhandledCombo(_keyDown(LogicalKeyboardKey.keyJ));
      controller.logUnhandledCombo(
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.keyJ,
          logicalKey: LogicalKeyboardKey.keyJ,
          timeStamp: Duration.zero,
        ),
      );
    });

    expect(shortcutLogs(), hasLength(1));
  });

  testWidgets('the observer never consumes the event', (tester) async {
    // It is mounted above the whole app; consuming would break the very
    // shortcuts it exists to diagnose.
    final controller = _controller(settings);

    await _withModifier(LogicalKeyboardKey.meta, () async {
      expect(
        controller.logUnhandledCombo(_keyDown(LogicalKeyboardKey.keyJ)),
        KeyEventResult.ignored,
      );
    });
    expect(
      controller.logUnhandledCombo(_keyDown(LogicalKeyboardKey.keyA)),
      KeyEventResult.ignored,
    );
  });

  testWidgets('invoking a bound action records it', (tester) async {
    final controller = _controller(settings);
    late BuildContext capturedContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Actions(
          actions: controller.buildActions(
            // buildActions does not read the context it is handed.
            tester.binding.rootElement!,
          ),
          child: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    final actions = controller.buildActions(capturedContext);
    // Actions.invoke is the public entry point; Action.invoke itself is
    // protected and meant to be reached through it.
    Actions.invoke(capturedContext, const ActivateIntent());
    await tester.pump();
    expect(actions[ActivateIntent], isNotNull);

    final invoked = shortcutLogs().where(
      (e) => e.message == 'Shortcut invoked',
    );
    expect(invoked, hasLength(1));
    expect(invoked.first.context?['action'], 'toggleRecording');
    expect(invoked.first.context?['isRecording'], true);
  });
}
