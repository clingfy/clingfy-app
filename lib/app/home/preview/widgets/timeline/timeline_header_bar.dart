import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_menu_button.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class TimelineHeaderBar extends StatelessWidget {
  const TimelineHeaderBar({
    super.key,
    required this.snappingEnabled,
    required this.canEditZoom,
    required this.canDelete,
    required this.canUndo,
    required this.showZoomLane,
    required this.showMarkersLane,
    required this.onToggleSnap,
    required this.onSelectAllVisible,
    required this.onSelectAfterPlayhead,
    required this.onDeleteSelected,
    required this.onUndo,
    required this.onToggleZoomLaneVisibility,
    required this.onToggleMarkersLaneVisibility,
    required this.onClose,
  });

  final bool snappingEnabled;
  final bool canEditZoom;
  final bool canDelete;
  final bool canUndo;
  final bool showZoomLane;
  final bool showMarkersLane;
  final VoidCallback? onToggleSnap;
  final VoidCallback? onSelectAllVisible;
  final VoidCallback? onSelectAfterPlayhead;
  final VoidCallback? onDeleteSelected;
  final VoidCallback? onUndo;
  final VoidCallback onToggleZoomLaneVisibility;
  final VoidCallback onToggleMarkersLaneVisibility;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final chrome = theme.appEditorChrome;
    final typography = theme.appTypography;
    final tokens = theme.appTokens;
    final metrics = context.shellMetricsOrNull;
    final padX = metrics?.timelineChromePaddingX ?? spacing.md;
    final padY = metrics?.timelineChromePaddingY ?? spacing.sm;
    final controlGap = metrics?.timelineControlGap ?? spacing.xs;
    final sectionGap = metrics?.timelineSectionGap ?? spacing.md;
    final minHeight = metrics?.timelineHeaderMinHeight ?? 40;
    final closeIconSize = metrics?.timelineCloseIconSize ?? 17;

    return Container(
      key: const Key('timeline_header_bar'),
      constraints: BoxConstraints(minHeight: minHeight),
      padding: EdgeInsets.symmetric(horizontal: padX, vertical: padY),
      decoration: BoxDecoration(
        color: tokens.timelineChromeSurface,
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Text(
                    l10n.timeline,
                    style: typography.button.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  SizedBox(width: sectionGap),
                  _TimelineToolbarButton(
                    key: const Key('timeline_snap_chip'),
                    label: l10n.snap,
                    icon: Icons.grid_4x4_rounded,
                    isActive: snappingEnabled,
                    onPressed: canEditZoom ? onToggleSnap : null,
                  ),
                  SizedBox(width: spacing.sm),
                  AppButton(
                    key: const Key('timeline_select_all_visible_button'),
                    label: l10n.zoomSelectAllVisible,
                    icon: Icons.select_all_rounded,
                    size: AppButtonSize.compact,
                    variant: AppButtonVariant.secondary,
                    onPressed: canEditZoom ? onSelectAllVisible : null,
                  ),
                  SizedBox(width: controlGap),
                  AppMenuButton<_TimelineOverflowAction>(
                    key: const Key('timeline_selection_overflow_menu'),
                    tooltip: l10n.zoomSelectionTools,
                    icon: Icons.more_horiz_rounded,
                    items: [
                      AppMenuItem(
                        value: _TimelineOverflowAction.selectAfterPlayhead,
                        label: l10n.zoomSelectAfterPlayhead,
                        icon: Icons.playlist_add_check_circle_outlined,
                      ),
                    ],
                    onSelected: (_) => onSelectAfterPlayhead?.call(),
                  ),
                  SizedBox(width: controlGap),
                  AppIconButton(
                    key: const Key('timeline_delete_button'),
                    icon: Icons.delete_outline_rounded,
                    tooltip: canDelete
                        ? l10n.zoomDeleteSelectedOne
                        : l10n.zoomDeleteSelectedMany(0),
                    onPressed: canDelete ? onDeleteSelected : null,
                    color: canDelete
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurface.withValues(alpha: 0.35),
                  ),
                  SizedBox(width: controlGap),
                  AppIconButton(
                    key: const Key('timeline_undo_button'),
                    icon: Icons.undo_rounded,
                    tooltip: l10n.zoomUndoLastAction,
                    onPressed: canUndo ? onUndo : null,
                    color: canUndo
                        ? theme.colorScheme.onSurface.withValues(alpha: 0.85)
                        : theme.colorScheme.onSurface.withValues(alpha: 0.35),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(width: controlGap),
          AppMenuButton<_TimelineLaneAction>(
            key: const Key('timeline_lane_visibility_menu'),
            tooltip: l10n.lanes,
            icon: Icons.view_stream_rounded,
            items: [
              AppMenuItem(
                value: _TimelineLaneAction.zoom,
                label: l10n.zoom,
                icon: showZoomLane
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_outlined,
              ),
              AppMenuItem(
                value: _TimelineLaneAction.markers,
                label: l10n.markers,
                icon: showMarkersLane
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_outlined,
              ),
            ],
            onSelected: (action) {
              switch (action) {
                case _TimelineLaneAction.zoom:
                  onToggleZoomLaneVisibility();
                  break;
                case _TimelineLaneAction.markers:
                  onToggleMarkersLaneVisibility();
                  break;
              }
            },
          ),
          SizedBox(width: controlGap),
          AppIconButton(
            key: const Key('timeline_close_button'),
            tooltip: l10n.closePreviewTooltip,
            icon: CupertinoIcons.xmark,
            onPressed: onClose,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            size: closeIconSize + 2,
          ),
        ],
      ),
    );
  }
}

enum _TimelineOverflowAction { selectAfterPlayhead }

enum _TimelineLaneAction { zoom, markers }

class _TimelineToolbarButton extends StatelessWidget {
  const _TimelineToolbarButton({
    super.key,
    required this.label,
    required this.icon,
    required this.isActive,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool isActive;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final chrome = theme.appEditorChrome;
    final accentColor = theme.colorScheme.primary;
    final metrics = context.shellMetricsOrNull;
    final chipMinHeight = metrics?.timelineToolbarChipMinHeight ?? 34;
    final chipPadX = metrics?.timelineToolbarChipPaddingX ?? spacing.sm;
    final chipPadY = metrics?.timelineToolbarChipPaddingY ?? spacing.xs;
    final chipIconSize = metrics?.timelineToolbarChipIconSize ?? 16;
    final chipTextScale = metrics?.timelineToolbarChipTextScale ?? 1.0;
    final chipIconTextGap = metrics?.timelineControlGap ?? spacing.xs;
    final chipTextStyle = typography.value.copyWith(
      color: onPressed == null
          ? theme.colorScheme.onSurface.withValues(alpha: 0.35)
          : isActive
          ? accentColor
          : theme.colorScheme.onSurface.withValues(alpha: 0.88),
      fontSize: (typography.value.fontSize ?? 12) * chipTextScale,
    );

    return Semantics(
      button: true,
      label: label,
      enabled: onPressed != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isActive
                ? accentColor.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(chrome.controlRadius),
            border: Border.all(
              color: isActive
                  ? accentColor.withValues(alpha: 0.28)
                  : theme.dividerColor.withValues(alpha: 0.12),
            ),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: chipMinHeight),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: chipPadX,
                vertical: chipPadY,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: chipIconSize,
                    color: onPressed == null
                        ? theme.colorScheme.onSurface.withValues(alpha: 0.35)
                        : isActive
                        ? accentColor
                        : theme.colorScheme.onSurface.withValues(alpha: 0.82),
                  ),
                  SizedBox(width: chipIconTextGap),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: chipTextStyle,
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
}
