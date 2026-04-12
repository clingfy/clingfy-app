import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/settings/sections/keyboard_shortcuts_settings.dart';
import 'package:clingfy/app/settings/sections/about_settings_section.dart';
import 'package:clingfy/app/settings/sections/diagnostics_settings_section.dart';
import 'package:clingfy/app/settings/sections/storage_settings_section.dart';
import 'package:clingfy/commercial/licensing/settings/license_settings_section.dart';
import 'package:clingfy/app/settings/sections/permissions_settings_section.dart';
import 'package:clingfy/app/settings/sections/workspace_settings_section.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

enum SettingsSection {
  workspace,
  storage,
  shortcuts,
  license,
  permissions,
  diagnostics,
  about,
}

class AppSettingsView extends StatefulWidget {
  const AppSettingsView({
    super.key,
    required this.controller,
    this.initialSection = SettingsSection.workspace,
  });

  final SettingsController controller;
  final SettingsSection initialSection;

  static const routeName = '/settings';
  static const storageRouteName = '/settings/storage';

  @override
  State<AppSettingsView> createState() => _AppSettingsViewState();
}

class _AppSettingsViewState extends State<AppSettingsView> {
  static const double _navItemRadius = 8;
  static const double _navItemOuterInset = 8;

  late SettingsSection _selectedSection;

  @override
  void initState() {
    super.initState();
    _selectedSection = widget.initialSection;
  }

  @override
  void didUpdateWidget(covariant AppSettingsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSection != widget.initialSection) {
      _selectedSection = widget.initialSection;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final tokens = theme.appTokens;
    final scaffoldColor = isDark
        ? tokens.outerBackground
        : theme.scaffoldBackgroundColor;
    final chromeSurface = isDark
        ? tokens.editorChromeBackground
        : tokens.panelBackground;
    final headerSurface = isDark
        ? tokens.editorChromeBackground
        : tokens.toolbarOverlay;
    final navPalette = _SettingsNavPalette.resolve(theme);
    final l10n = AppLocalizations.of(context)!;

    final items = [
      _SettingsNavItem(
        section: SettingsSection.workspace,
        icon: CupertinoIcons.square_grid_2x2,
        label: l10n.settingsWorkspace,
        description: l10n.settingsWorkspaceDescription,
      ),
      _SettingsNavItem(
        section: SettingsSection.storage,
        icon: CupertinoIcons.archivebox,
        label: l10n.settingsStorage,
        description: l10n.settingsStorageDescription,
      ),
      _SettingsNavItem(
        section: SettingsSection.shortcuts,
        icon: CupertinoIcons.keyboard,
        label: l10n.keyboardShortcuts,
        description: l10n.settingsShortcutsDescription,
      ),
      _SettingsNavItem(
        section: SettingsSection.license,
        icon: CupertinoIcons.rosette,
        label: l10n.settingsLicense,
        description: l10n.settingsLicenseDescription,
      ),
      _SettingsNavItem(
        section: SettingsSection.permissions,
        icon: CupertinoIcons.lock_shield,
        label: l10n.settingsPermissions,
        description: l10n.settingsPermissionsDescription,
      ),
      _SettingsNavItem(
        section: SettingsSection.diagnostics,
        icon: CupertinoIcons.wrench,
        label: l10n.settingsDiagnostics,
        description: l10n.settingsDiagnosticsDescription,
      ),
      _SettingsNavItem(
        section: SettingsSection.about,
        icon: CupertinoIcons.info_circle,
        label: l10n.settingsAbout,
        description: l10n.settingsAboutDescription,
      ),
    ];
    final currentItem = items.firstWhere(
      (item) => item.section == _selectedSection,
    );

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: scaffoldColor,
          body: Row(
            children: [
              Container(
                key: const Key('settings_nav_rail'),
                width: 220,
                color: chromeSurface,
                child: ListView(
                  padding: EdgeInsets.symmetric(vertical: spacing.lg),
                  children: items.map((item) {
                    return _buildSidebarItem(
                      item: item,
                      selected: item.section == _selectedSection,
                      palette: navPalette,
                      onTap: () {
                        setState(() {
                          _selectedSection = item.section;
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: tokens.panelBorder,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      key: const Key('settings_header'),
                      padding: EdgeInsets.all(spacing.lg),
                      color: headerSurface,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  currentItem.label,
                                  style: typography.pageTitle,
                                ),
                                if (currentItem.description != null) ...[
                                  SizedBox(height: spacing.sm - 2),
                                  Text(
                                    currentItem.description!,
                                    style: typography.body.copyWith(
                                      color: theme.textTheme.bodySmall?.color,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          SizedBox(width: spacing.lg),
                          AppButton(
                            label: l10n.close,
                            icon: CupertinoIcons.xmark,
                            variant: AppButtonVariant.secondary,
                            size: AppButtonSize.regular,
                            onPressed: () {
                              final navigator = Navigator.of(context);
                              if (navigator.canPop()) {
                                navigator.pop();
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: spacing.sm),
                    Expanded(
                      child: Container(
                        key: const Key('settings_content_surface'),
                        color: isDark
                            ? tokens.editorChromeBackground
                            : Colors.transparent,
                        child: _buildSectionContent(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSidebarItem({
    required _SettingsNavItem item,
    required bool selected,
    required _SettingsNavPalette palette,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final foreground = selected
        ? palette.selectedForeground
        : palette.unselectedForeground;
    final borderRadius = BorderRadius.circular(_navItemRadius);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: _navItemOuterInset,
        vertical: 2,
      ),
      child: Material(
        color: Colors.transparent,
        child: Ink(
          key: Key('settings_nav_item_${item.section.name}'),
          decoration: BoxDecoration(
            color: selected ? palette.selectedFill : Colors.transparent,
            borderRadius: borderRadius,
          ),
          child: InkWell(
            borderRadius: borderRadius,
            hoverColor: palette.hoverFill,
            splashColor: palette.hoverFill,
            highlightColor: palette.hoverFill,
            mouseCursor: SystemMouseCursors.click,
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: spacing.lg,
                vertical: spacing.md,
              ),
              child: Row(
                children: [
                  Icon(
                    item.icon,
                    key: Key('settings_nav_item_${item.section.name}_icon'),
                    size: 20,
                    color: foreground,
                  ),
                  SizedBox(width: spacing.md),
                  Expanded(
                    child: Text(
                      item.label,
                      key: Key('settings_nav_item_${item.section.name}_label'),
                      style: typography.body.copyWith(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionContent() {
    switch (_selectedSection) {
      case SettingsSection.workspace:
        return WorkspaceSettingsSection(controller: widget.controller);
      case SettingsSection.storage:
        return StorageSettingsSection(controller: widget.controller);
      case SettingsSection.shortcuts:
        return KeyboardShortcutsSettings(controller: widget.controller);
      case SettingsSection.license:
        return const LicenseSettingsSection();
      case SettingsSection.permissions:
        return const PermissionsSettingsSection();
      case SettingsSection.diagnostics:
        return DiagnosticsSettingsSection(controller: widget.controller);
      case SettingsSection.about:
        return const AboutSettingsSection();
    }
  }
}

class _SettingsNavItem {
  const _SettingsNavItem({
    required this.section,
    required this.icon,
    required this.label,
    this.description,
  });

  final SettingsSection section;
  final IconData icon;
  final String label;
  final String? description;
}

class _SettingsNavPalette {
  const _SettingsNavPalette({
    required this.selectedFill,
    required this.hoverFill,
    required this.selectedForeground,
    required this.unselectedForeground,
  });

  final Color selectedFill;
  final Color hoverFill;
  final Color selectedForeground;
  final Color unselectedForeground;

  factory _SettingsNavPalette.resolve(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final foreground = theme.colorScheme.onSurface;

    return _SettingsNavPalette(
      selectedFill: foreground.withValues(alpha: isDark ? 0.10 : 0.06),
      hoverFill: foreground.withValues(alpha: isDark ? 0.05 : 0.04),
      selectedForeground: foreground,
      unselectedForeground: theme.colorScheme.onSurfaceVariant,
    );
  }
}
