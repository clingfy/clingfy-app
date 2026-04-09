// lib/settings/keyboard_shortcuts_settings.dart
import 'package:clingfy/app/settings/sections/section_helpers.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/settings/shortcuts/shortcut_config.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:macos_ui/macos_ui.dart' as macos;

class KeyboardShortcutsSettings extends StatefulWidget {
  const KeyboardShortcutsSettings({super.key, required this.controller});

  final SettingsController controller;

  @override
  State<KeyboardShortcutsSettings> createState() =>
      _KeyboardShortcutsSettingsState();
}

class _KeyboardShortcutsSettingsState extends State<KeyboardShortcutsSettings> {
  AppShortcutAction? _capturingAction;
  final FocusNode _focusNode = FocusNode();
  String? _noticeText;
  AppInlineNoticeVariant _noticeVariant = AppInlineNoticeVariant.info;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  static const _keyLabels = <int, String>{
    0x00000000020: '␣', // space
    0x00100000301: '←', // arrowLeft
    0x00100000302: '→', // arrowRight
    0x00100000304: '↑', // arrowUp
    0x00100000303: '↓', // arrowDown
    0x0010000000d: '↩', // enter
    0x00100000009: '⇥', // tab
    0x0010000007f: '⌫', // backspace / delete
  };

  String _getShortcutText(ShortcutActivator activator) {
    if (activator is SingleActivator) {
      final parts = <String>[];
      if (activator.meta) parts.add('⌘');
      if (activator.control) parts.add('⌃');
      if (activator.alt) parts.add('⌥');
      if (activator.shift) parts.add('⇧');

      // Use a readable label for keys whose keyLabel is empty
      final label = activator.trigger.keyLabel;
      if (label.isNotEmpty) {
        parts.add(label);
      } else {
        parts.add(_keyLabels[activator.trigger.keyId] ?? '?');
      }
      return parts.join('');
    }
    return AppLocalizations.of(context)!.unknown;
  }

  String _getActionLabel(BuildContext context, AppShortcutAction action) {
    final l10n = AppLocalizations.of(context)!;
    switch (action) {
      case AppShortcutAction.toggleRecording:
        return l10n.toggleRecording;
      case AppShortcutAction.refreshDevices:
        return l10n.refreshDevices;
      case AppShortcutAction.toggleActionBar:
        return l10n.toggleActionBar;
      case AppShortcutAction.cycleOverlayMode:
        return l10n.cycleOverlayMode;
      case AppShortcutAction.exportVideo:
        return l10n.exportVideo;
      case AppShortcutAction.openSettings:
        return l10n.openSettings;
    }
  }

  void _startCapture(AppShortcutAction action) {
    setState(() {
      _capturingAction = action;
    });
    _focusNode.requestFocus();
  }

  void _stopCapture() {
    setState(() {
      _capturingAction = null;
    });
  }

  void _handleKeyEvent(KeyEvent event) {
    if (_capturingAction == null) return;
    if (event is! KeyDownEvent) return;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _stopCapture();
      return;
    }

    // Ignore modifier-only presses
    if (event.logicalKey == LogicalKeyboardKey.meta ||
        event.logicalKey == LogicalKeyboardKey.control ||
        event.logicalKey == LogicalKeyboardKey.alt ||
        event.logicalKey == LogicalKeyboardKey.shift ||
        event.logicalKey == LogicalKeyboardKey.metaLeft ||
        event.logicalKey == LogicalKeyboardKey.metaRight ||
        event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight ||
        event.logicalKey == LogicalKeyboardKey.altLeft ||
        event.logicalKey == LogicalKeyboardKey.altRight ||
        event.logicalKey == LogicalKeyboardKey.shiftLeft ||
        event.logicalKey == LogicalKeyboardKey.shiftRight) {
      return;
    }

    final isMeta = HardwareKeyboard.instance.isMetaPressed;
    final isControl = HardwareKeyboard.instance.isControlPressed;
    final isAlt = HardwareKeyboard.instance.isAltPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;

    final activator = SingleActivator(
      event.logicalKey,
      meta: isMeta,
      control: isControl,
      alt: isAlt,
      shift: isShift,
    );

    // Check collision
    final bindings = widget.controller.shortcuts.shortcutConfig.bindings;
    AppShortcutAction? collision;
    for (final entry in bindings.entries) {
      if (entry.key == _capturingAction) continue;
      final existing = entry.value;
      if (existing is SingleActivator &&
          existing.trigger == activator.trigger &&
          existing.meta == activator.meta &&
          existing.control == activator.control &&
          existing.alt == activator.alt &&
          existing.shift == activator.shift) {
        collision = entry.key;
        break;
      }
    }

    final collidedAction = collision;
    if (collidedAction != null) {
      setState(() {
        _noticeText = AppLocalizations.of(
          context,
        )!.shortcutCollision(_getActionLabel(context, collidedAction));
        _noticeVariant = AppInlineNoticeVariant.error;
      });
      _stopCapture();
      return;
    }

    if (_noticeText != null) {
      setState(() {
        _noticeText = null;
      });
    }

    widget.controller.shortcuts.updateShortcut(_capturingAction!, activator);
    _stopCapture();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bindings = widget.controller.shortcuts.shortcutConfig.bindings;

    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: buildSectionPage(
        context,
        children: [
          if (_noticeText != null) ...[
            AppInlineNotice(message: _noticeText!, variant: _noticeVariant),
            const SizedBox(height: 12),
          ],
          if (_capturingAction != null)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    CupertinoIcons.keyboard,
                    size: 16,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    AppLocalizations.of(context)!.pressKeyToCapture,
                    style: TextStyle(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          SettingsCard(
            title: '',
            child: Column(
              children: AppShortcutAction.values.asMap().entries.map((entry) {
                final index = entry.key;
                final action = entry.value;
                final activator = bindings[action];
                final isCapturing = _capturingAction == action;

                return Column(
                  children: [
                    if (index > 0)
                      Divider(
                        height: 1,
                        color: theme.dividerColor.withValues(alpha: 0.15),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _getActionLabel(context, action),
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          const SizedBox(width: 12),
                          if (isCapturing)
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: isMac()
                                  ? const macos.ProgressCircle(radius: 8)
                                  : const CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                            )
                          else
                            _KeyCapChip(
                              label: activator != null
                                  ? _getShortcutText(activator)
                                  : AppLocalizations.of(context)!.none,
                              onTap: () => _startCapture(action),
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: AppButton(
              label: AppLocalizations.of(context)!.resetShortcuts,
              onPressed: () async {
                for (final entry in ShortcutConfig.defaults.bindings.entries) {
                  await widget.controller.shortcuts.updateShortcut(
                    entry.key,
                    entry.value,
                  );
                }
                if (!mounted) return;
                setState(() {
                  _noticeText = null;
                });
              },
              variant: AppButtonVariant.secondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// A macOS-style keyboard shortcut chip (looks like a keycap badge).
class _KeyCapChip extends StatelessWidget {
  const _KeyCapChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF3A3A3C) : const Color(0xFFF0F0F0),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isDark ? const Color(0xFF555557) : const Color(0xFFD1D1D6),
            ),
            boxShadow: isDark
                ? null
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      offset: const Offset(0, 1),
                      blurRadius: 1,
                    ),
                  ],
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              fontFamily: '.AppleSystemUIFont',
              color: isDark ? const Color(0xFFE5E5EA) : const Color(0xFF1C1C1E),
              letterSpacing: 0.5,
            ),
          ),
        ),
      ),
    );
  }
}
