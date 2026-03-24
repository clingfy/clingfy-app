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
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final tokens = theme.appTokens;
    final railColor = tokens.panelBackground;
    final selectedColor = tokens.selectionFill;
    final textColor = theme.colorScheme.onSurface;
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
          backgroundColor: theme.scaffoldBackgroundColor,
          body: Row(
            children: [
              Container(
                key: const Key('settings_nav_rail'),
                width: 220,
                color: railColor,
                child: ListView(
                  padding: EdgeInsets.symmetric(vertical: spacing.lg),
                  children: items.map((item) {
                    return _buildSidebarItem(
                      icon: item.icon,
                      label: Text(item.label),
                      selected: item.section == _selectedSection,
                      selectedColor: selectedColor,
                      textColor: textColor,
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
                      color: tokens.toolbarOverlay,
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
                    Expanded(child: _buildSectionContent()),
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
    required IconData icon,
    required Widget label,
    required bool selected,
    required Color selectedColor,
    required Color textColor,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final foreground = selected ? theme.colorScheme.primary : textColor;

    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          color: selected ? selectedColor : Colors.transparent,
          padding: EdgeInsets.symmetric(
            horizontal: spacing.lg,
            vertical: spacing.md,
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: foreground),
              SizedBox(width: spacing.md),
              Expanded(
                child: DefaultTextStyle.merge(
                  style: typography.body.copyWith(
                    color: foreground,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                  child: label,
                ),
              ),
            ],
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
