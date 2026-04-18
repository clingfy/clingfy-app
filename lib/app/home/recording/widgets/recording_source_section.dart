import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_inset_group.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:flutter/material.dart' hide PlatformMenuItem;

class RecordingSourceSection extends StatelessWidget {
  const RecordingSourceSection({
    super.key,
    required this.isRecording,
    required this.targetMode,
    required this.displays,
    required this.selectedDisplayId,
    required this.appWindows,
    required this.selectedAppWindowId,
    required this.areaDisplayId,
    required this.areaRect,
    required this.onTargetModeChanged,
    required this.onDisplayChanged,
    required this.onRefreshDisplays,
    required this.onAppWindowChanged,
    required this.onRefreshAppWindows,
    required this.onPickArea,
    required this.onRevealArea,
    required this.onClearArea,
    this.guideAnchorKey,
  });

  final bool isRecording;
  final DisplayTargetMode targetMode;
  final List<DisplayInfo> displays;
  final int? selectedDisplayId;
  final List<AppWindowInfo> appWindows;
  final int? selectedAppWindowId;
  final int? areaDisplayId;
  final Rect? areaRect;
  final ValueChanged<DisplayTargetMode> onTargetModeChanged;
  final ValueChanged<int?> onDisplayChanged;
  final VoidCallback onRefreshDisplays;
  final ValueChanged<int?> onAppWindowChanged;
  final VoidCallback onRefreshAppWindows;
  final VoidCallback onPickArea;
  final VoidCallback onRevealArea;
  final VoidCallback onClearArea;
  final Key? guideAnchorKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final colors = theme.colorScheme;

    final validDisplayId =
        selectedDisplayId == null ||
            displays.any((d) => d.id == selectedDisplayId)
        ? selectedDisplayId
        : null;

    final validAppWindowId =
        selectedAppWindowId == null ||
            appWindows.any((w) => w.id == selectedAppWindowId)
        ? selectedAppWindowId
        : null;

    final isDisplayTarget = targetMode == DisplayTargetMode.explicitId;
    final isAppWindowTarget = targetMode == DisplayTargetMode.singleAppWindow;
    final isAreaTarget = targetMode == DisplayTargetMode.areaRecording;
    final targetDetails = _buildTargetDetails(
      context,
      validDisplayId: validDisplayId,
      validAppWindowId: validAppWindowId,
      isDisplayTarget: isDisplayTarget,
      isAppWindowTarget: isAppWindowTarget,
      isAreaTarget: isAreaTarget,
      colors: colors,
    );

    return AppSettingsGroup(
      anchorKey: guideAnchorKey,
      sectionKey: const Key('recording_capture_source_group'),
      title: l10n.captureSource,
      showHeader: false,
      children: [
        AppFormRow(
          label: l10n.recordTarget,
          infoTooltip: isAreaTarget ? l10n.areaRecordingHelper : null,
          control: PlatformDropdown<DisplayTargetMode>(
            value: targetMode,
            minWidth: 0,
            maxWidth: double.infinity,
            expand: true,
            onChanged: isRecording
                ? null
                : (mode) {
                    if (mode != null) onTargetModeChanged(mode);
                  },
            items: [
              PlatformMenuItem(
                value: DisplayTargetMode.explicitId,
                label: l10n.chosenScreen,
              ),
              PlatformMenuItem(
                value: DisplayTargetMode.singleAppWindow,
                label: l10n.specificAppWindow,
              ),
              PlatformMenuItem(
                value: DisplayTargetMode.areaRecording,
                label: l10n.areaRecording,
              ),
              PlatformMenuItem(
                value: DisplayTargetMode.mouseAtStart,
                label: l10n.screenUnderMouse,
              ),
            ],
          ),
        ),
        _AnimatedSection(
          visible: targetDetails != null,
          child: targetDetails == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(
                    top: AppSidebarTokens.optionsSubgroupGap,
                  ),

                  child: AppInsetGroup(padding: 0, children: targetDetails),
                ),
        ),
      ],
    );
  }

  List<Widget>? _buildTargetDetails(
    BuildContext context, {
    required int? validDisplayId,
    required int? validAppWindowId,
    required bool isDisplayTarget,
    required bool isAppWindowTarget,
    required bool isAreaTarget,
    required ColorScheme colors,
  }) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    if (isDisplayTarget) {
      return [
        AppFormRow(
          label: l10n.screenToRecord,
          labelTrailing: AppIconButton(
            tooltip: l10n.refreshDisplays,
            onPressed: isRecording ? null : onRefreshDisplays,
            icon: Icons.refresh,
          ),
          control: PlatformDropdown<int?>(
            value: validDisplayId,
            minWidth: 0,
            maxWidth: double.infinity,
            expand: true,
            items: [
              PlatformMenuItem(value: null, label: l10n.mainDisplay),
              ...displays.map(
                (display) => PlatformMenuItem(
                  value: display.id,
                  label:
                      '${display.name}  (${display.width.toInt()}×${display.height.toInt()} @${display.scale}x)',
                ),
              ),
            ],
            onChanged: isDisplayTarget && !isRecording
                ? onDisplayChanged
                : null,
          ),
        ),
      ];
    }

    if (isAppWindowTarget) {
      return [
        AppFormRow(
          label: l10n.windowToRecord,
          labelTrailing: AppIconButton(
            tooltip: l10n.refreshWindows,
            onPressed: isRecording ? null : onRefreshAppWindows,
            icon: Icons.refresh,
          ),
          control: PlatformDropdown<int?>(
            value: validAppWindowId,
            minWidth: 0,
            maxWidth: double.infinity,
            expand: true,
            items: [
              PlatformMenuItem(value: null, label: l10n.selectAppWindow),
              ...appWindows.map(
                (window) =>
                    PlatformMenuItem(value: window.id, label: window.label),
              ),
            ],
            onChanged: isAppWindowTarget && !isRecording
                ? onAppWindowChanged
                : null,
          ),
        ),
      ];
    }

    if (isAreaTarget) {
      return [
        if (areaRect == null)
          AppButton(
            expand: true,
            size: AppButtonSize.regular,
            icon: Icons.crop_free,
            label: l10n.pickArea,
            onPressed: isRecording ? null : onPickArea,
          )
        else
          Wrap(
            spacing: AppSidebarTokens.compactGap,
            runSpacing: AppSidebarTokens.compactGap,
            children: [
              AppButton(
                size: AppButtonSize.regular,
                icon: Icons.crop_free,
                label: l10n.changeArea,
                onPressed: isRecording ? null : onPickArea,
              ),
              AppButton(
                size: AppButtonSize.regular,
                variant: AppButtonVariant.secondary,
                icon: Icons.visibility_outlined,
                label: l10n.revealArea,
                onPressed: onRevealArea,
              ),
              AppButton(
                size: AppButtonSize.regular,
                variant: AppButtonVariant.secondary,
                icon: Icons.clear,
                label: l10n.clearArea,
                onPressed: isRecording ? null : onClearArea,
              ),
            ],
          ),
        const SizedBox(height: AppSidebarTokens.rowGap),
        Text(
          areaRect != null
              ? l10n.selectedAreaAt(
                  areaDisplayId?.toString() ?? '?',
                  areaRect!.width.toInt().toString(),
                  areaRect!.height.toInt().toString(),
                  areaRect!.left.toInt().toString(),
                  areaRect!.top.toInt().toString(),
                )
              : l10n.noAreaSelected,
          style: areaRect != null
              ? AppSidebarTokens.helperStyle(
                  theme,
                ).copyWith(color: colors.primary, fontWeight: FontWeight.w600)
              : AppSidebarTokens.helperStyle(theme),
        ),
      ];
    }

    return null;
  }
}

class _AnimatedSection extends StatelessWidget {
  const _AnimatedSection({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: visible ? 1.0 : 0.0,
        child: visible ? child : const SizedBox.shrink(),
      ),
    );
  }
}
