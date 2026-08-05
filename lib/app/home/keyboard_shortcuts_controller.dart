import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/settings/shortcuts/shortcut_config.dart';
import 'package:clingfy/app/settings/settings_controller.dart';

class KeyboardShortcutsController {
  final SettingsController settings;

  final VoidCallback onToggleRecording;
  final VoidCallback onRefreshDevices;
  final Future<void> Function() onToggleActionBar;
  final Future<void> Function() onCycleOverlayMode;
  final Future<void> Function() onExportVideo;
  final Future<void> Function() onShowActionBar;
  final VoidCallback onOpenSettings;

  /// Extra state written alongside every shortcut log line — recording phase,
  /// whether a take is in flight, and so on. Without it a "shortcut did
  /// nothing" report is undiagnosable after the fact: the only way to tell a
  /// swallowed key from a key that never arrived is a log that records both.
  final Map<String, dynamic> Function()? diagnostics;

  KeyboardShortcutsController({
    required this.settings,
    required this.onToggleRecording,
    required this.onRefreshDevices,
    required this.onToggleActionBar,
    required this.onCycleOverlayMode,
    required this.onExportVideo,
    required this.onShowActionBar,
    required this.onOpenSettings,
    this.diagnostics,
  });

  Map<String, dynamic> _logContext(Map<String, dynamic> extra) => {
    ...extra,
    ...?diagnostics?.call(),
  };

  /// True when an unmodified keystroke belongs to a focused text field rather
  /// than to the app.
  ///
  /// This `Shortcuts` layer sits above every text field in the app, so a
  /// BARE-key binding steals the key before the field can insert it. Space is
  /// bound to toggleRecording, which made the space bar unusable in the caption
  /// editor: each press toggled playback instead of typing a space, eight times
  /// in three seconds in the logs.
  ///
  /// Only bare keys are suppressed. A modified combo is unambiguously the
  /// app's — Cmd+E should still export while the caret is in a field — and that
  /// is the macOS convention: the text field owns unmodified keys, the app owns
  /// the combos.
  static bool _belongsToFocusedTextField() {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed) {
      return false;
    }
    // Walk up rather than testing the focused widget directly: a TextField's
    // focus node lives on a `Focus` INSIDE `EditableText`, so the focused
    // context's own widget is that `Focus`, never the `EditableText`.
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.findAncestorStateOfType<EditableTextState>() != null;
  }

  /// Wraps a shortcut callback so every invocation is recorded.
  Object? _invoke(String action, VoidCallback run) {
    if (_belongsToFocusedTextField()) return null;
    Log.i(
      'Shortcuts',
      'Shortcut invoked',
      null,
      null,
      _logContext({'action': action}),
    );
    run();
    return null;
  }

  Future<Object?> _invokeAsync(
    String action,
    Future<void> Function() run,
  ) async {
    if (_belongsToFocusedTextField()) return null;
    Log.i(
      'Shortcuts',
      'Shortcut invoked',
      null,
      null,
      _logContext({'action': action}),
    );
    await run();
    return null;
  }

  /// Records modifier combos that reached the app but matched no binding.
  ///
  /// Only combos are logged, never bare keys: this sits above every text
  /// field in the app, and logging unmodified keystrokes would write whatever
  /// the user types — including passwords — into the log file.
  ///
  /// Always returns [KeyEventResult.ignored]; this observes, it never
  /// consumes.
  KeyEventResult logUnhandledCombo(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final keyboard = HardwareKeyboard.instance;
    final hasModifier =
        keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed;
    if (!hasModifier) return KeyEventResult.ignored;

    // A combo that matches a binding is logged by the action that runs it;
    // logging it here too would double-count and hide the interesting case.
    final matchesBinding = shortcuts.keys.any(
      (activator) => activator.accepts(event, keyboard),
    );
    if (matchesBinding) return KeyEventResult.ignored;

    Log.i(
      'Shortcuts',
      'Shortcut combo not bound',
      null,
      null,
      _logContext({
        'key': event.logicalKey.keyLabel,
        'meta': keyboard.isMetaPressed,
        'control': keyboard.isControlPressed,
        'alt': keyboard.isAltPressed,
        'shift': keyboard.isShiftPressed,
      }),
    );
    return KeyEventResult.ignored;
  }

  Map<ShortcutActivator, Intent> get shortcuts {
    final bindings = settings.shortcuts.shortcutConfig.bindings;
    return {
      bindings[AppShortcutAction.toggleRecording]!: const ActivateIntent(),
      bindings[AppShortcutAction.refreshDevices]!: const RefreshIntent(),
      bindings[AppShortcutAction.toggleActionBar]!:
          const ToggleActionBarIntent(),
      bindings[AppShortcutAction.cycleOverlayMode]!: const CycleOverlayIntent(),
      bindings[AppShortcutAction.exportVideo]!: const ExportIntent(),
      bindings[AppShortcutAction.openSettings]!: const OpenSettingsIntent(),
    };
  }

  Map<Type, Action<Intent>> buildActions(BuildContext context) {
    return {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) => _invoke('toggleRecording', onToggleRecording),
      ),
      RefreshIntent: CallbackAction<RefreshIntent>(
        onInvoke: (_) => _invoke('refreshDevices', onRefreshDevices),
      ),
      ToggleActionBarIntent: CallbackAction<ToggleActionBarIntent>(
        onInvoke: (_) => _invokeAsync('toggleActionBar', onToggleActionBar),
      ),
      CycleOverlayIntent: CallbackAction<CycleOverlayIntent>(
        onInvoke: (_) => _invokeAsync('cycleOverlayMode', onCycleOverlayMode),
      ),
      ExportIntent: CallbackAction<ExportIntent>(
        onInvoke: (_) => _invokeAsync('exportVideo', onExportVideo),
      ),
      OpenSettingsIntent: CallbackAction<OpenSettingsIntent>(
        onInvoke: (_) => _invoke('openSettings', onOpenSettings),
      ),
    };
  }

  List<PlatformMenu> buildMenus(BuildContext context) {
    final bindings = settings.shortcuts.shortcutConfig.bindings;
    final appMenuGroups = <PlatformMenuItem>[
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: AppLocalizations.of(context)!.aboutClingfy,
            onSelected: () {
              showAboutDialog(
                context: context,
                applicationName: AppLocalizations.of(context)!.appTitle,
                applicationVersion: '1.0.0',
              );
            },
          ),
        ],
      ),
    ];

    if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.quit)) {
      appMenuGroups.add(
        const PlatformMenuItemGroup(
          members: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
          ],
        ),
      );
    }

    return [
      PlatformMenu(
        label: AppLocalizations.of(context)!.appTitle,
        menus: appMenuGroups,
      ),
      PlatformMenu(
        label: AppLocalizations.of(context)!.menuFile,
        menus: [
          PlatformMenuItem(
            label: AppLocalizations.of(context)!.exportVideo,
            shortcut: bindings[AppShortcutAction.exportVideo] is SingleActivator
                ? bindings[AppShortcutAction.exportVideo] as SingleActivator
                : null,
            onSelected: () {
              onExportVideo();
            },
          ),
          PlatformMenuItem(
            label: AppLocalizations.of(context)!.openSettings,
            shortcut:
                bindings[AppShortcutAction.openSettings] is SingleActivator
                ? bindings[AppShortcutAction.openSettings] as SingleActivator
                : null,
            onSelected: () {
              onOpenSettings();
            },
          ),
        ],
      ),
      PlatformMenu(
        label: AppLocalizations.of(context)!.menuView,
        menus: [
          PlatformMenuItem(
            label: AppLocalizations.of(context)!.refreshDevices,
            shortcut:
                bindings[AppShortcutAction.refreshDevices] is SingleActivator
                ? bindings[AppShortcutAction.refreshDevices] as SingleActivator
                : null,
            onSelected: () {
              onRefreshDevices();
            },
          ),
          PlatformMenuItem(
            label: AppLocalizations.of(context)!.showActionBar,
            onSelected: () {
              onShowActionBar();
            },
          ),
          PlatformMenuItem(
            label: AppLocalizations.of(context)!.cycleOverlayMode,
            shortcut:
                bindings[AppShortcutAction.cycleOverlayMode] is SingleActivator
                ? bindings[AppShortcutAction.cycleOverlayMode]
                      as SingleActivator
                : null,
            onSelected: () {
              onCycleOverlayMode();
            },
          ),
        ],
      ),
      PlatformMenu(
        label: AppLocalizations.of(context)!.menuRecord,
        menus: [
          PlatformMenuItem(
            label: AppLocalizations.of(context)!.toggleRecording,
            shortcut:
                bindings[AppShortcutAction.toggleRecording] is SingleActivator
                ? bindings[AppShortcutAction.toggleRecording] as SingleActivator
                : null,
            onSelected: () {
              onToggleRecording();
            },
          ),
        ],
      ),
    ];
  }
}

class RefreshIntent extends Intent {
  const RefreshIntent();
}

class ToggleActionBarIntent extends Intent {
  const ToggleActionBarIntent();
}

class CycleOverlayIntent extends Intent {
  const CycleOverlayIntent();
}

class ExportIntent extends Intent {
  const ExportIntent();
}

class OpenSettingsIntent extends Intent {
  const OpenSettingsIntent();
}
