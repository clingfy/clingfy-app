import 'package:clingfy/app/home/keyboard_shortcuts_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../test_helpers/native_test_setup.dart';

/// Shortcuts versus text entry.
///
/// This `Shortcuts` layer sits above every text field in the app, and Space is
/// bound to toggleRecording — so typing a space in the caption editor toggled
/// playback instead of inserting a character. The logs caught it as eight
/// `Shortcut invoked {action: toggleRecording}` lines in three seconds while
/// the user was trying to type.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  late List<String> fired;
  late TextEditingController textController;
  late FocusNode elsewhere;

  /// Set when a key event travels PAST the Shortcuts layer.
  ///
  /// This is the assertion that matters and the one the first version of these
  /// tests was missing. Suppressing the callback is not enough:
  /// `ShortcutManager.handleKeypress` reports the key as handled as soon as the
  /// activator matches an ENABLED action — `invoke`'s return value is never
  /// read — and the engine only forwards a key to macOS text input when nothing
  /// handled it. So a test that only checks `fired` passes while the space bar
  /// is still being eaten, which is exactly what happened.
  late bool reachedPastShortcuts;

  Future<Widget> harness() async {
    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await settings.loadPreferences();
    addTearDown(settings.dispose);

    final shortcuts = KeyboardShortcutsController(
      settings: settings,
      onToggleRecording: () => fired.add('toggleRecording'),
      onRefreshDevices: () => fired.add('refreshDevices'),
      onToggleActionBar: () async => fired.add('toggleActionBar'),
      onCycleOverlayMode: () async => fired.add('cycleOverlayMode'),
      onExportVideo: () async => fired.add('exportVideo'),
      onShowActionBar: () async => fired.add('showActionBar'),
      onOpenSettings: () async => fired.add('openSettings'),
    );

    return MaterialApp(
      home: Builder(
        builder: (context) => Focus(
          // ABOVE Shortcuts: key events bubble up from the focused node, so
          // this only runs if Shortcuts let the key through.
          onKeyEvent: (_, event) {
            // KeyDown only: a shortcut consumes the DOWN, and the UP always
            // propagates — counting it would make this always true.
            if (event is KeyDownEvent) reachedPastShortcuts = true;
            return KeyEventResult.ignored;
          },
          child: Shortcuts(
            shortcuts: shortcuts.shortcuts,
            child: Actions(
              actions: shortcuts.buildActions(context),
              child: Scaffold(
                body: Column(
                  children: [
                    TextField(
                      key: const Key('field'),
                      controller: textController,
                      autofocus: false,
                    ),
                    Focus(
                      focusNode: elsewhere,
                      autofocus: true,
                      child: const SizedBox(
                        key: Key('elsewhere'),
                        width: 10,
                        height: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    fired = [];
    reachedPastShortcuts = false;
    textController = TextEditingController();
    elsewhere = FocusNode();
  });

  tearDown(() {
    textController.dispose();
    elsewhere.dispose();
  });

  testWidgets('space in a text field types instead of toggling recording', (
    tester,
  ) async {
    await tester.pumpWidget(await harness());
    await tester.tap(find.byKey(const Key('field')));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(
      fired,
      isEmpty,
      reason: 'the space bar belongs to the focused field, not to the app',
    );
    expect(
      reachedPastShortcuts,
      isTrue,
      reason:
          'and the key must travel ON — a consumed key never reaches macOS '
          'text input, so the space is never typed even though nothing fired',
    );
  });

  testWidgets('space still toggles recording when no field has focus', (
    tester,
  ) async {
    await tester.pumpWidget(await harness());
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(fired, [
      'toggleRecording',
    ], reason: 'the shortcut must survive — this guard is not a removal');
    expect(
      reachedPastShortcuts,
      isFalse,
      reason: 'and outside a text field it SHOULD consume the key',
    );
  });

  testWidgets('a modified combo still fires while editing text', (
    tester,
  ) async {
    // Cmd+E is unambiguously the app's. Suppressing every shortcut while a
    // caret is somewhere would break export from the editor for no reason.
    await tester.pumpWidget(await harness());
    await tester.tap(find.byKey(const Key('field')));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(fired, contains('exportVideo'));
  });

  testWidgets('the guard lifts as soon as the field loses focus', (
    tester,
  ) async {
    await tester.pumpWidget(await harness());
    await tester.tap(find.byKey(const Key('field')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(fired, isEmpty);

    // Moved rather than cleared: with nothing focused the key event never
    // reaches the Shortcuts layer at all, which would pass this test for the
    // wrong reason.
    elsewhere.requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(fired, ['toggleRecording']);
  });
}
