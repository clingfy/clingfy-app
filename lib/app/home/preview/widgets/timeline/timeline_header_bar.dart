import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_menu_button.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

class TimelineHeaderBar extends StatelessWidget {
  const TimelineHeaderBar({
    super.key,
    required this.snappingEnabled,
    required this.canEditZoom,
    required this.canDelete,
    required this.canUndo,
    required this.canRedo,
    required this.showZoomLane,
    required this.showMarkersLane,
    required this.onToggleSnap,
    required this.onSelectAllVisible,
    required this.onSelectAfterPlayhead,
    required this.onDeleteSelected,
    required this.onUndo,
    required this.onRedo,
    required this.onToggleZoomLaneVisibility,
    required this.onToggleMarkersLaneVisibility,
    this.showClipsControls = false,
    this.canSplitClip = false,
    this.canDeleteClip = false,
    this.canUndoClips = false,
    this.canRedoClips = false,
    this.onSplitClip,
    this.onDeleteClip,
    this.onUndoClips,
    this.onRedoClips,
    this.showColorControls = false,
    this.canUndoColor = false,
    this.canRedoColor = false,
    this.onUndoColor,
    this.onRedoColor,
  });

  final bool snappingEnabled;
  final bool canEditZoom;
  final bool canDelete;
  final bool canUndo;
  final bool canRedo;
  final bool showZoomLane;
  final bool showMarkersLane;
  final VoidCallback? onToggleSnap;
  final VoidCallback? onSelectAllVisible;
  final VoidCallback? onSelectAfterPlayhead;
  final VoidCallback? onDeleteSelected;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final VoidCallback onToggleZoomLaneVisibility;
  final VoidCallback onToggleMarkersLaneVisibility;

  // Clip (split/cut) controls — a distinct trailing group, shown only when the
  // clip lane is live so zoom-only users see no change.
  final bool showClipsControls;
  final bool canSplitClip;
  final bool canDeleteClip;
  final bool canUndoClips;
  final bool canRedoClips;
  final VoidCallback? onSplitClip;
  final VoidCallback? onDeleteClip;
  final VoidCallback? onUndoClips;
  final VoidCallback? onRedoClips;

  // Color-grade undo/redo. The sliders live in the Effects sidebar, but every
  // undo in this app lives in this bar, so the color pair joins the zoom and
  // clip pairs here as its own trailing group.
  final bool showColorControls;
  final bool canUndoColor;
  final bool canRedoColor;
  final VoidCallback? onUndoColor;
  final VoidCallback? onRedoColor;

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
                  _HistoryButtonPair(
                    label: l10n.zoom,
                    undoKey: const Key('timeline_undo_button'),
                    redoKey: const Key('timeline_redo_button'),
                    undoTooltip: l10n.zoomUndoLastAction,
                    redoTooltip: l10n.zoomRedoLastAction,
                    canUndo: canUndo,
                    canRedo: canRedo,
                    onUndo: onUndo,
                    onRedo: onRedo,
                  ),
                  if (showClipsControls) ...[
                    SizedBox(width: sectionGap),
                    _sectionDivider(
                      theme,
                      const Key('timeline_clip_controls_divider'),
                    ),
                    SizedBox(width: sectionGap),
                    Tooltip(
                      message: l10n.clipSplitTooltip,
                      child: AppButton(
                        key: const Key('timeline_clip_split_button'),
                        label: l10n.clipSplit,
                        icon: Icons.content_cut_rounded,
                        size: AppButtonSize.compact,
                        variant: AppButtonVariant.secondary,
                        onPressed: canSplitClip ? onSplitClip : null,
                      ),
                    ),
                    SizedBox(width: controlGap),
                    AppIconButton(
                      key: const Key('timeline_clip_delete_button'),
                      icon: Icons.backspace_outlined,
                      tooltip: l10n.clipRemoveSelected,
                      onPressed: canDeleteClip ? onDeleteClip : null,
                      color: canDeleteClip
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurface.withValues(alpha: 0.35),
                    ),
                    SizedBox(width: controlGap),
                    _HistoryButtonPair(
                      label: l10n.clips,
                      undoKey: const Key('timeline_clip_undo_button'),
                      redoKey: const Key('timeline_clip_redo_button'),
                      undoTooltip: l10n.clipUndo,
                      redoTooltip: l10n.clipRedo,
                      canUndo: canUndoClips,
                      canRedo: canRedoClips,
                      onUndo: onUndoClips,
                      onRedo: onRedoClips,
                    ),
                  ],
                  if (showColorControls) ...[
                    SizedBox(width: sectionGap),
                    _sectionDivider(
                      theme,
                      const Key('timeline_color_controls_divider'),
                    ),
                    SizedBox(width: sectionGap),
                    _HistoryButtonPair(
                      label: l10n.color,
                      undoKey: const Key('timeline_color_undo_button'),
                      redoKey: const Key('timeline_color_redo_button'),
                      undoTooltip: l10n.colorUndo,
                      redoTooltip: l10n.colorRedo,
                      canUndo: canUndoColor,
                      canRedo: canRedoColor,
                      onUndo: onUndoColor,
                      onRedo: onRedoColor,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _TimelineOverflowAction { selectAfterPlayhead }

/// The thin rule that separates one edit-track group from the next.
Widget _sectionDivider(ThemeData theme, Key key) {
  return Container(
    key: key,
    width: 1,
    height: 22,
    color: theme.dividerColor.withValues(alpha: 0.2),
  );
}

/// One edit track's undo/redo controls, with the track named next to them.
///
/// Extracted because the bar carries three of these — zoom, clips, colour — and
/// they were verbatim copies: the same two icons, the same enabled/disabled
/// `onSurface` alpha ternary spelled out six times, the same gap. A fourth
/// undoable track used to mean another copy-pasted block.
///
/// [label] is the part that matters to the user, not the deduplication. Driving
/// the running app showed three visually identical arrow pairs sitting in one
/// row, separated only by a 1px divider and distinguishable only by hovering for
/// a tooltip — you could not tell which pair undid which edit at a glance.
/// Naming each group is what makes the row scannable.
class _HistoryButtonPair extends StatelessWidget {
  const _HistoryButtonPair({
    required this.label,
    required this.undoKey,
    required this.redoKey,
    required this.undoTooltip,
    required this.redoTooltip,
    required this.canUndo,
    required this.canRedo,
    this.onUndo,
    this.onRedo,
  });

  final String label;
  final Key undoKey;
  final Key redoKey;
  final String undoTooltip;
  final String redoTooltip;
  final bool canUndo;
  final bool canRedo;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final metrics = context.shellMetricsOrNull;
    final controlGap = metrics?.timelineControlGap ?? spacing.xs;

    // The label dims with the pair: a track with nothing to undo should not
    // advertise itself as loudly as one that does.
    final anyEnabled = canUndo || canRedo;
    Color iconColor(bool enabled) =>
        theme.colorScheme.onSurface.withValues(alpha: enabled ? 0.85 : 0.35);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: typography.value.copyWith(
            color: theme.colorScheme.onSurface.withValues(
              alpha: anyEnabled ? 0.62 : 0.32,
            ),
          ),
        ),
        SizedBox(width: controlGap),
        AppIconButton(
          key: undoKey,
          icon: Icons.undo_rounded,
          tooltip: undoTooltip,
          onPressed: canUndo ? onUndo : null,
          color: iconColor(canUndo),
        ),
        SizedBox(width: controlGap),
        AppIconButton(
          key: redoKey,
          icon: Icons.redo_rounded,
          tooltip: redoTooltip,
          onPressed: canRedo ? onRedo : null,
          color: iconColor(canRedo),
        ),
      ],
    );
  }
}

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
