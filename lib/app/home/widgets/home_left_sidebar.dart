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

enum _HomeHelpMenuAction { quickTour, about }

class HomeLeftSidebar extends StatelessWidget {
  const HomeLeftSidebar({
    super.key,
    required this.uiState,
    required this.panePresentation,
    required this.onRecordingSectionSelected,
    required this.onPostProcessingSectionSelected,
    required this.onOpenSettings,
    required this.onStartQuickTour,
    required this.onOpenAbout,
    required this.onResetPreferences,
    required this.onToggleRailMode,
    this.guideShellKey,
    this.helpButtonAnchorKey,
  });

  final HomeUiState uiState;
  final DesktopPanePresentation panePresentation;
  final ValueChanged<int> onRecordingSectionSelected;
  final ValueChanged<int> onPostProcessingSectionSelected;
  final VoidCallback onOpenSettings;
  final VoidCallback onStartQuickTour;
  final VoidCallback onOpenAbout;
  final VoidCallback onResetPreferences;
  final VoidCallback onToggleRailMode;
  final Key? guideShellKey;
  final Key? helpButtonAnchorKey;

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
    final content = Container(
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
              onStartQuickTour: onStartQuickTour,
              onOpenAbout: onOpenAbout,
              onResetPreferences: onResetPreferences,
              onRecordingSectionSelected: onRecordingSectionSelected,
              onPostProcessingSectionSelected: onPostProcessingSectionSelected,
              uiState: uiState,
              helpButtonAnchorKey: helpButtonAnchorKey,
            )
          : _ExpandedSidebarContent(
              sectionLabel: showPreviewShell
                  ? l10n.postProcessing
                  : l10n.recording,
              compactTooltip: l10n.compactNavigationRail,
              onToggleRailMode: onToggleRailMode,
              navigationItems: navigationItems,
              onStartQuickTour: onStartQuickTour,
              onOpenAbout: onOpenAbout,
              onOpenSettings: onOpenSettings,
              onResetPreferences: onResetPreferences,
              helpButtonAnchorKey: helpButtonAnchorKey,
            ),
    );

    if (guideShellKey == null) {
      return content;
    }

    return SizedBox(key: guideShellKey, child: content);
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
          label: l10n.canvas,
          selected: uiState.postProcessingSidebarIndex == 0,
          onTap: () => onPostProcessingSectionSelected(0),
        ),
        _SidebarActionItem(
          buttonKey: const ValueKey('post_sidebar_rail_tile_1'),
          icon: Icons.face,
          label: l10n.camera,
          selected: uiState.postProcessingSidebarIndex == 1,
          onTap: () => onPostProcessingSectionSelected(1),
        ),
        _SidebarActionItem(
          buttonKey: const ValueKey('post_sidebar_rail_tile_2'),
          icon: Icons.auto_fix_high,
          label: l10n.effects,
          selected: uiState.postProcessingSidebarIndex == 2,
          onTap: () => onPostProcessingSectionSelected(2),
        ),
        _SidebarActionItem(
          buttonKey: const ValueKey('post_sidebar_rail_tile_3'),
          icon: Icons.ios_share,
          label: l10n.export,
          selected: uiState.postProcessingSidebarIndex == 3,
          onTap: () => onPostProcessingSectionSelected(3),
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
}

class _CompactSidebarContent extends StatelessWidget {
  const _CompactSidebarContent({
    required this.showPreviewShell,
    required this.expandTooltip,
    required this.onToggleRailMode,
    required this.onOpenSettings,
    required this.onStartQuickTour,
    required this.onOpenAbout,
    required this.onResetPreferences,
    required this.onRecordingSectionSelected,
    required this.onPostProcessingSectionSelected,
    required this.uiState,
    required this.helpButtonAnchorKey,
  });

  final bool showPreviewShell;
  final String expandTooltip;
  final VoidCallback onToggleRailMode;
  final VoidCallback onOpenSettings;
  final VoidCallback onStartQuickTour;
  final VoidCallback onOpenAbout;
  final VoidCallback onResetPreferences;
  final ValueChanged<int> onRecordingSectionSelected;
  final ValueChanged<int> onPostProcessingSectionSelected;
  final HomeUiState uiState;
  final Key? helpButtonAnchorKey;

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
              _CompactHelpMenuButton(
                guideAnchorKey: helpButtonAnchorKey,
                onStartQuickTour: onStartQuickTour,
                onOpenAbout: onOpenAbout,
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
    required this.onStartQuickTour,
    required this.onOpenAbout,
    required this.onOpenSettings,
    required this.onResetPreferences,
    required this.helpButtonAnchorKey,
  });

  final String sectionLabel;
  final String compactTooltip;
  final VoidCallback onToggleRailMode;
  final List<_SidebarActionItem> navigationItems;
  final VoidCallback onStartQuickTour;
  final VoidCallback onOpenAbout;
  final VoidCallback onOpenSettings;
  final VoidCallback onResetPreferences;
  final Key? helpButtonAnchorKey;

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
              if (kDebugMode) ...[
                _ExpandedSidebarButton(
                  item: _SidebarActionItem(
                    buttonKey: const Key('home_sidebar_reset_button'),
                    icon: Icons.restart_alt_rounded,
                    label: AppLocalizations.of(
                      context,
                    )!.debugResetPreferencesConfirm,
                    tooltip: AppLocalizations.of(
                      context,
                    )!.debugResetPreferencesSemanticLabel,
                    onTap: onResetPreferences,
                  ),
                ),
                const SizedBox(height: AppSidebarTokens.railItemGap),
              ],
              _ExpandedHelpMenuButton(
                guideAnchorKey: helpButtonAnchorKey,
                onStartQuickTour: onStartQuickTour,
                onOpenAbout: onOpenAbout,
              ),
              const SizedBox(height: AppSidebarTokens.railItemGap),
              _ExpandedSidebarButton(
                item: _SidebarActionItem(
                  buttonKey: const Key('home_sidebar_settings_button'),
                  icon: Icons.settings_rounded,
                  label: AppLocalizations.of(context)!.appSettings,
                  tooltip: AppLocalizations.of(context)!.openAppSettings,
                  onTap: onOpenSettings,
                ),
              ),
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

class _CompactHelpMenuButton extends StatelessWidget {
  const _CompactHelpMenuButton({
    required this.onStartQuickTour,
    required this.onOpenAbout,
    this.guideAnchorKey,
  });

  final VoidCallback onStartQuickTour;
  final VoidCallback onOpenAbout;
  final Key? guideAnchorKey;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const Key('home_sidebar_help_button'),
      child: AppSidebarRailButton(
        buttonKey: guideAnchorKey,
        onTap: () => _showHomeHelpMenu(
          context,
          anchorKey: guideAnchorKey,
          onStartQuickTour: onStartQuickTour,
          onOpenAbout: onOpenAbout,
        ),
        tooltip: AppLocalizations.of(context)!.settingsAbout,
        icon: Icons.help_outline_rounded,
        iconSize: 28,
        buttonSize: 40,
      ),
    );
  }
}

class _ExpandedHelpMenuButton extends StatelessWidget {
  const _ExpandedHelpMenuButton({
    required this.onStartQuickTour,
    required this.onOpenAbout,
    this.guideAnchorKey,
  });

  final VoidCallback onStartQuickTour;
  final VoidCallback onOpenAbout;
  final Key? guideAnchorKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = theme.colorScheme.onSurfaceVariant.withValues(
      alpha: 0.88,
    );
    final hoverBackground = theme.colorScheme.onSurface.withValues(alpha: 0.04);
    final labelStyle = (theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(color: foreground, fontWeight: FontWeight.w600);

    return KeyedSubtree(
      key: const Key('home_sidebar_help_button'),
      child: Tooltip(
        message: AppLocalizations.of(context)!.settingsAbout,
        child: Semantics(
          button: true,
          label: AppLocalizations.of(context)!.settingsAbout,
          child: TextButton(
            key: guideAnchorKey,
            onPressed: () => _showHomeHelpMenu(
              context,
              anchorKey: guideAnchorKey,
              onStartQuickTour: onStartQuickTour,
              onOpenAbout: onOpenAbout,
            ),
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
                const Icon(Icons.help_outline_rounded, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    AppLocalizations.of(context)!.settingsAbout,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _showHomeHelpMenu(
  BuildContext context, {
  required Key? anchorKey,
  required VoidCallback onStartQuickTour,
  required VoidCallback onOpenAbout,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final anchorContext = switch (anchorKey) {
    final GlobalKey key => key.currentContext,
    _ => null,
  };
  final menuSelection = await showMenu<_HomeHelpMenuAction>(
    context: context,
    position: _resolveHelpMenuPosition(context, anchorContext),
    items: [
      PopupMenuItem<_HomeHelpMenuAction>(
        value: _HomeHelpMenuAction.quickTour,
        child: Row(
          children: [
            const Icon(Icons.play_circle_outline_rounded, size: 18),
            const SizedBox(width: 10),
            Text(l10n.quickTour),
          ],
        ),
      ),
      PopupMenuItem<_HomeHelpMenuAction>(
        value: _HomeHelpMenuAction.about,
        child: Row(
          children: [
            const Icon(Icons.info_outline_rounded, size: 18),
            const SizedBox(width: 10),
            Text(l10n.aboutThisApp),
          ],
        ),
      ),
    ],
  );

  switch (menuSelection) {
    case _HomeHelpMenuAction.quickTour:
      onStartQuickTour();
      break;
    case _HomeHelpMenuAction.about:
      onOpenAbout();
      break;
    case null:
      break;
  }
}

RelativeRect _resolveHelpMenuPosition(
  BuildContext context,
  BuildContext? anchorContext,
) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final fallbackRect = Rect.fromLTWH(
    overlay.size.width - 72,
    overlay.size.height - 72,
    40,
    40,
  );

  if (anchorContext == null) {
    return RelativeRect.fromRect(fallbackRect, Offset.zero & overlay.size);
  }

  final anchorBox = anchorContext.findRenderObject();
  if (anchorBox is! RenderBox || !anchorBox.hasSize) {
    return RelativeRect.fromRect(fallbackRect, Offset.zero & overlay.size);
  }

  final rect = Rect.fromPoints(
    anchorBox.localToGlobal(Offset.zero, ancestor: overlay),
    anchorBox.localToGlobal(
      anchorBox.size.bottomRight(Offset.zero),
      ancestor: overlay,
    ),
  );
  return RelativeRect.fromRect(rect, Offset.zero & overlay.size);
}
