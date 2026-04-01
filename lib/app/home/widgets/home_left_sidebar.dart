import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/post_processing/widgets/post_processing_sidebar.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/home/recording/widgets/recording_options_sidebar.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_rail_button.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/desktop_pane_layout.dart';
import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class HomeLeftSidebar extends StatelessWidget {
  const HomeLeftSidebar({
    super.key,
    required this.uiState,
    required this.panePresentation,
    required this.onRecordingSectionSelected,
    required this.onPostProcessingSectionSelected,
    required this.onOpenSettings,
    required this.onOpenHelp,
    required this.onResetPreferences,
    required this.onToggleRailMode,
  });

  final HomeUiState uiState;
  final DesktopPanePresentation panePresentation;
  final ValueChanged<int> onRecordingSectionSelected;
  final ValueChanged<int> onPostProcessingSectionSelected;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenHelp;
  final VoidCallback onResetPreferences;
  final VoidCallback onToggleRailMode;

  static const _sidebarLogoAsset = 'assets/icons/app-logo-512.png';

  @override
  Widget build(BuildContext context) {
    final tokens = context.appTokens;
    final chrome = context.appEditorChrome;
    final l10n = AppLocalizations.of(context)!;
    final isCompact = panePresentation.isCompact;
    final showPreviewShell = context.select<RecordingController, bool>(
      (r) => r.showPreviewShell,
    );
    final navigationItems = _buildNavigationItems(
      l10n,
      showPreviewShell,
      onRecordingSectionSelected,
      onPostProcessingSectionSelected,
    );
    final utilityItems = _buildUtilityItems(l10n);

    return Container(
      key: const Key('home_left_sidebar_shell'),
      decoration: BoxDecoration(
        color: tokens.editorChromeBackground,
        borderRadius: BorderRadius.circular(chrome.panelRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: isCompact
          ? _CompactSidebarContent(
              showPreviewShell: showPreviewShell,
              expandTooltip: l10n.expandNavigationRail,
              onToggleRailMode: onToggleRailMode,
              onOpenSettings: onOpenSettings,
              onOpenHelp: onOpenHelp,
              onResetPreferences: onResetPreferences,
              onRecordingSectionSelected: onRecordingSectionSelected,
              onPostProcessingSectionSelected: onPostProcessingSectionSelected,
              uiState: uiState,
            )
          : _ExpandedSidebarContent(
              sectionLabel: showPreviewShell
                  ? l10n.postProcessing
                  : l10n.recording,
              compactTooltip: l10n.compactNavigationRail,
              onToggleRailMode: onToggleRailMode,
              navigationItems: navigationItems,
              utilityItems: utilityItems,
            ),
    );
  }

  List<_SidebarActionItem> _buildNavigationItems(
    AppLocalizations l10n,
    bool showPreviewShell,
    ValueChanged<int> onRecordingSectionSelected,
    ValueChanged<int> onPostProcessingSectionSelected,
  ) {
    if (showPreviewShell) {
      return [
        _SidebarActionItem(
          buttonKey: const ValueKey('post_sidebar_rail_tile_0'),
          icon: Icons.dashboard_customize,
          label: l10n.layout,
          selected: uiState.postProcessingSidebarIndex == 0,
          onTap: () => onPostProcessingSectionSelected(0),
        ),
        _SidebarActionItem(
          buttonKey: const ValueKey('post_sidebar_rail_tile_1'),
          icon: Icons.auto_fix_high,
          label: l10n.effects,
          selected: uiState.postProcessingSidebarIndex == 1,
          onTap: () => onPostProcessingSectionSelected(1),
        ),
        _SidebarActionItem(
          buttonKey: const ValueKey('post_sidebar_rail_tile_2'),
          icon: Icons.ios_share,
          label: l10n.export,
          selected: uiState.postProcessingSidebarIndex == 2,
          onTap: () => onPostProcessingSectionSelected(2),
        ),
      ];
    }

    return [
      _SidebarActionItem(
        buttonKey: const ValueKey('recording_sidebar_rail_tile_0'),
        icon: Icons.monitor,
        label: l10n.tabScreenAudio,
        selected: uiState.recordingSidebarIndex == 0,
        onTap: () => onRecordingSectionSelected(0),
      ),
      _SidebarActionItem(
        buttonKey: const ValueKey('recording_sidebar_rail_tile_1'),
        icon: Icons.face,
        label: l10n.tabFaceCam,
        selected: uiState.recordingSidebarIndex == 1,
        onTap: () => onRecordingSectionSelected(1),
      ),
      _SidebarActionItem(
        buttonKey: const ValueKey('recording_sidebar_rail_tile_2'),
        icon: Icons.tune,
        label: l10n.output,
        selected: uiState.recordingSidebarIndex == 2,
        onTap: () => onRecordingSectionSelected(2),
      ),
    ];
  }

  List<_SidebarActionItem> _buildUtilityItems(AppLocalizations l10n) {
    return [
      if (kDebugMode)
        _SidebarActionItem(
          buttonKey: const Key('home_sidebar_reset_button'),
          icon: Icons.restart_alt_rounded,
          label: l10n.debugResetPreferencesConfirm,
          tooltip: l10n.debugResetPreferencesSemanticLabel,
          onTap: onResetPreferences,
        ),
      _SidebarActionItem(
        buttonKey: const Key('home_sidebar_help_button'),
        icon: Icons.help_outline_rounded,
        label: l10n.settingsAbout,
        onTap: onOpenHelp,
      ),
      _SidebarActionItem(
        buttonKey: const Key('home_sidebar_settings_button'),
        icon: Icons.settings_rounded,
        label: l10n.appSettings,
        tooltip: l10n.openAppSettings,
        onTap: onOpenSettings,
      ),
    ];
  }
}

class _CompactSidebarContent extends StatelessWidget {
  const _CompactSidebarContent({
    required this.showPreviewShell,
    required this.expandTooltip,
    required this.onToggleRailMode,
    required this.onOpenSettings,
    required this.onOpenHelp,
    required this.onResetPreferences,
    required this.onRecordingSectionSelected,
    required this.onPostProcessingSectionSelected,
    required this.uiState,
  });

  final bool showPreviewShell;
  final String expandTooltip;
  final VoidCallback onToggleRailMode;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenHelp;
  final VoidCallback onResetPreferences;
  final ValueChanged<int> onRecordingSectionSelected;
  final ValueChanged<int> onPostProcessingSectionSelected;
  final HomeUiState uiState;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.appSpacing.xs / 4,
        vertical: AppSidebarTokens.sectionGap - 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const _SidebarLogoBadge(
            assetPath: HomeLeftSidebar._sidebarLogoAsset,
            size: 30,
          ),
          const SizedBox(height: AppSidebarTokens.compactGap),
          _RailUtilityButton(
            buttonKey: const Key('home_sidebar_collapse_button'),
            icon: Icons.chevron_right_rounded,
            tooltip: expandTooltip,
            onTap: onToggleRailMode,
          ),
          const SizedBox(height: AppSidebarTokens.sectionGap),
          Align(
            alignment: Alignment.topCenter,
            child: showPreviewShell
                ? PostProcessingSidebarRail(
                    selectedIndex: uiState.postProcessingSidebarIndex,
                    onSelectedIndexChanged: onPostProcessingSectionSelected,
                  )
                : RecordingSidebarRail(
                    selectedIndex: uiState.recordingSidebarIndex,
                    onSelectedIndexChanged: onRecordingSectionSelected,
                  ),
          ),
          const Spacer(),
          Column(
            key: const Key('home_sidebar_utility_cluster'),
            children: [
              if (kDebugMode) ...[
                _RailUtilityButton(
                  buttonKey: const Key('home_sidebar_reset_button'),
                  icon: Icons.restart_alt_rounded,
                  tooltip: AppLocalizations.of(
                    context,
                  )!.debugResetPreferencesSemanticLabel,
                  onTap: onResetPreferences,
                ),
                const SizedBox(height: AppSidebarTokens.railItemGap),
              ],
              _RailUtilityButton(
                buttonKey: const Key('home_sidebar_help_button'),
                icon: Icons.help_outline_rounded,
                tooltip: AppLocalizations.of(context)!.settingsAbout,
                onTap: onOpenHelp,
              ),
              const SizedBox(height: AppSidebarTokens.railItemGap),
              _RailUtilityButton(
                buttonKey: const Key('home_sidebar_settings_button'),
                icon: Icons.settings_rounded,
                tooltip: AppLocalizations.of(context)!.openAppSettings,
                onTap: onOpenSettings,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExpandedSidebarContent extends StatelessWidget {
  const _ExpandedSidebarContent({
    required this.sectionLabel,
    required this.compactTooltip,
    required this.onToggleRailMode,
    required this.navigationItems,
    required this.utilityItems,
  });

  final String sectionLabel;
  final String compactTooltip;
  final VoidCallback onToggleRailMode;
  final List<_SidebarActionItem> navigationItems;
  final List<_SidebarActionItem> utilityItems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = (theme.textTheme.titleMedium ?? const TextStyle())
        .copyWith(fontWeight: FontWeight.w700);
    final sectionStyle = (theme.textTheme.bodySmall ?? const TextStyle())
        .copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        );

    return Padding(
      padding: const EdgeInsets.all(AppSidebarTokens.sectionGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SidebarLogoBadge(
                assetPath: HomeLeftSidebar._sidebarLogoAsset,
                size: 36,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Clingfy', style: titleStyle),
                    const SizedBox(height: 2),
                    Text(sectionLabel, style: sectionStyle),
                  ],
                ),
              ),
              IconButton(
                key: const Key('home_sidebar_collapse_button'),
                onPressed: onToggleRailMode,
                tooltip: compactTooltip,
                visualDensity: VisualDensity.compact,
                splashRadius: 18,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
            ],
          ),
          const SizedBox(height: 18),
          for (var index = 0; index < navigationItems.length; index++) ...[
            _ExpandedSidebarButton(item: navigationItems[index]),
            if (index < navigationItems.length - 1)
              const SizedBox(height: AppSidebarTokens.compactGap),
          ],
          const Spacer(),
          Column(
            key: const Key('home_sidebar_utility_cluster'),
            children: [
              for (var index = 0; index < utilityItems.length; index++) ...[
                _ExpandedSidebarButton(item: utilityItems[index]),
                if (index < utilityItems.length - 1)
                  const SizedBox(height: AppSidebarTokens.railItemGap),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _SidebarActionItem {
  const _SidebarActionItem({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.tooltip,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final String? tooltip;
}

class _ExpandedSidebarButton extends StatelessWidget {
  const _ExpandedSidebarButton({required this.item});

  final _SidebarActionItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedBackground = theme.colorScheme.onSurface.withValues(
      alpha: 0.08,
    );
    final hoverBackground = theme.colorScheme.onSurface.withValues(alpha: 0.04);
    final foreground = item.selected
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.88);
    final labelStyle = (theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(
          color: foreground,
          fontWeight: item.selected ? FontWeight.w700 : FontWeight.w600,
        );

    return Tooltip(
      message: item.tooltip ?? item.label,
      child: Semantics(
        button: true,
        label: item.tooltip ?? item.label,
        selected: item.selected,
        child: TextButton(
          key: item.buttonKey,
          onPressed: item.onTap,
          style: ButtonStyle(
            alignment: Alignment.centerLeft,
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            minimumSize: const WidgetStatePropertyAll(Size.fromHeight(44)),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(
                  theme.appEditorChrome.controlRadius,
                ),
              ),
            ),
            foregroundColor: WidgetStatePropertyAll(foreground),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (item.selected) {
                return selectedBackground;
              }
              if (states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused) ||
                  states.contains(WidgetState.pressed)) {
                return hoverBackground;
              }
              return Colors.transparent;
            }),
            overlayColor: WidgetStatePropertyAll(
              theme.colorScheme.onSurface.withValues(alpha: 0.06),
            ),
          ),
          child: Row(
            children: [
              Icon(item.icon, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarLogoBadge extends StatelessWidget {
  const _SidebarLogoBadge({required this.assetPath, required this.size});

  final String assetPath;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('home_sidebar_logo'),
      width: size,
      height: size,
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
