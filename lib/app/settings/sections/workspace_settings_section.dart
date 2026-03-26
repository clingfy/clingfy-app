import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/settings/sections/section_helpers.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' hide PlatformMenuItem;

class WorkspaceSettingsSection extends StatelessWidget {
  const WorkspaceSettingsSection({super.key, required this.controller});

  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return buildSectionPage(
      context,
      children: [
        SettingsCard(
          title: l10n.appTheme,
          infoTooltip: l10n.appThemeDescription,
          child: SizedBox(
            width: 320,
            child: PlatformDropdown<ThemeMode>(
              value: controller.app.themeMode,
              items: [
                PlatformMenuItem(
                  value: ThemeMode.system,
                  label: l10n.systemDefault,
                ),
                PlatformMenuItem(value: ThemeMode.light, label: l10n.light),
                PlatformMenuItem(value: ThemeMode.dark, label: l10n.dark),
              ],
              onChanged: controller.app.updateThemeMode,
            ),
          ),
        ),
        const SizedBox(height: 16),
        SettingsCard(
          title: l10n.appLanguage,
          infoTooltip: l10n.appLanguageDescription,
          child: SizedBox(
            width: 320,
            child: PlatformDropdown<AppLocaleSetting>(
              value: controller.app.localeSetting,
              items: [
                PlatformMenuItem(
                  value: AppLocaleSetting.system,
                  label: l10n.systemDefault,
                ),
                PlatformMenuItem(
                  value: AppLocaleSetting.en,
                  label: l10n.english,
                ),
                PlatformMenuItem(
                  value: AppLocaleSetting.ar,
                  label: l10n.arabic,
                ),
                PlatformMenuItem(
                  value: AppLocaleSetting.ro,
                  label: l10n.romanian,
                ),
              ],
              onChanged: (val) {
                if (val != null) {
                  controller.app.updateLocale(val);
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
        SettingsCard(
          title: l10n.recordingFolderBehavior,
          child: Column(
            children: [
              AppToggleRow(
                title: l10n.openFolderAfterStop,
                value: controller.workspace.openFolderAfterStop,
                onChanged: controller.workspace.updateOpenFolderAfterStop,
              ),
              const SizedBox(height: 8),
              AppToggleRow(
                title: l10n.openFolderAfterExport,
                value: controller.workspace.openFolderAfterExport,
                onChanged: controller.workspace.updateOpenFolderAfterExport,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SettingsCard(
          title: l10n.confirmations,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              AppToggleRow(
                title: l10n.showActionBar,
                value: controller.workspace.showPreRecordingActionBar,
                onChanged: controller.workspace.updateShowPreRecordingActionBar,
              ),
              const SizedBox(height: 8),
              AppToggleRow(
                title: l10n.warnBeforeClosingUnexportedRecording,
                infoTooltip:
                    l10n.warnBeforeClosingUnexportedRecordingDescription,
                value:
                    controller.workspace.warnBeforeClosingUnexportedRecording,
                onChanged: controller
                    .workspace
                    .updateWarnBeforeClosingUnexportedRecording,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SettingsCard(
          title: l10n.saveLocation,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                controller.workspace.saveFolderPath ?? l10n.loading,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  AppButton(
                    label: l10n.chooseSaveFolder,
                    icon: CupertinoIcons.folder_badge_plus,
                    onPressed: controller.workspace.chooseSaveFolder,
                  ),
                  AppButton(
                    label: l10n.resetToDefault,
                    onPressed: controller.workspace.resetSaveFolder,
                    variant: AppButtonVariant.secondary,
                  ),
                  AppIconButton(
                    tooltip: l10n.openFolder,
                    onPressed: controller.workspace.openSaveFolder,
                    icon: CupertinoIcons.folder,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
