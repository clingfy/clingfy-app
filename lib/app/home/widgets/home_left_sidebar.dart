import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_processing_sidebar.dart';
import 'package:clingfy/app/home/recording/widgets/recording_options_sidebar.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_rail_button.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class HomeLeftSidebar extends StatelessWidget {
  const HomeLeftSidebar({
    super.key,
    required this.uiState,
    required this.onOpenSettings,
    required this.onOpenHelp,
    required this.onResetPreferences,
  });

  final HomeUiState uiState;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenHelp;
  final VoidCallback onResetPreferences;

  static const _sidebarLogoAsset = 'assets/icons/app-logo-512.png';

  @override
  Widget build(BuildContext context) {
    final tokens = context.appTokens;
    final chrome = context.appEditorChrome;
    final spacing = context.appSpacing;
    final l10n = AppLocalizations.of(context)!;
    final showPreviewShell = context.select<RecordingController, bool>(
      (r) => r.showPreviewShell,
    );
    final rail = showPreviewShell
        ? PostProcessingSidebarRail(
            selectedIndex: uiState.postProcessingSidebarIndex,
            onSelectedIndexChanged: uiState.setPostProcessingSidebarIndex,
          )
        : RecordingSidebarRail(
            selectedIndex: uiState.recordingSidebarIndex,
            onSelectedIndexChanged: uiState.setRecordingSidebarIndex,
          );

    return Container(
      key: const Key('home_left_sidebar_shell'),
      width: chrome.editorRailWidth,
      decoration: BoxDecoration(
        color: tokens.editorChromeBackground,
        borderRadius: BorderRadius.circular(chrome.panelRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: spacing.xs / 2,
          vertical: AppSidebarTokens.sectionGap,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const _SidebarLogoBadge(assetPath: _sidebarLogoAsset),
            SizedBox(height: AppSidebarTokens.sectionGap),
            Align(alignment: Alignment.topCenter, child: rail),
            const Spacer(),
            Column(
              key: const Key('home_sidebar_utility_cluster'),
              children: [
                if (kDebugMode) ...[
                  _RailUtilityButton(
                    buttonKey: const Key('home_sidebar_reset_button'),
                    icon: Icons.restart_alt_rounded,
                    tooltip: l10n.debugResetPreferencesSemanticLabel,
                    onTap: onResetPreferences,
                  ),
                  SizedBox(height: AppSidebarTokens.railItemGap),
                ],
                _RailUtilityButton(
                  buttonKey: const Key('home_sidebar_help_button'),
                  icon: Icons.help_outline_rounded,
                  tooltip: l10n.settingsAbout,
                  onTap: onOpenHelp,
                ),
                SizedBox(height: AppSidebarTokens.railItemGap),
                _RailUtilityButton(
                  buttonKey: const Key('home_sidebar_settings_button'),
                  icon: Icons.settings_rounded,
                  tooltip: l10n.openAppSettings,
                  onTap: onOpenSettings,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarLogoBadge extends StatelessWidget {
  const _SidebarLogoBadge({required this.assetPath});

  final String assetPath;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('home_sidebar_logo'),
      width: 36,
      height: 36,
      child: Image.asset(
        assetPath,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}

class _RailUtilityButton extends StatelessWidget {
  const _RailUtilityButton({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppSidebarRailButton(
      buttonKey: buttonKey,
      onTap: onTap,
      tooltip: tooltip,
      icon: icon,
      iconSize: 28,
      buttonSize: 40,
    );
  }
}
