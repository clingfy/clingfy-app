import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_section.dart';
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppFormRow(
          label: l10n.recordTarget,
          control: PlatformDropdown<DisplayTargetMode>(
            value: targetMode,
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
          visible: isDisplayTarget,
          child: Padding(
            padding: const EdgeInsets.only(top: AppSidebarTokens.sectionGap),
            child: AppSection(
              title: l10n.display,
              titleSpacing: AppSidebarTokens.dropdownSectionTitleGap,
              trailing: AppIconButton(
                tooltip: l10n.refreshDisplays,
                onPressed: isRecording ? null : onRefreshDisplays,
                icon: Icons.refresh,
              ),
              child: Opacity(
                opacity: isDisplayTarget ? 1.0 : 0.5,
                child: AppFormRow(
                  label: l10n.screenToRecord,
                  control: PlatformDropdown<int?>(
                    value: validDisplayId,
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
              ),
            ),
          ),
        ),
        _AnimatedSection(
          visible: isAppWindowTarget,
          child: Padding(
            padding: const EdgeInsets.only(top: AppSidebarTokens.sectionGap),
            child: AppSection(
              title: l10n.appWindow,
              titleSpacing: AppSidebarTokens.dropdownSectionTitleGap,
              trailing: AppIconButton(
                tooltip: l10n.refreshWindows,
                onPressed: isRecording ? null : onRefreshAppWindows,
                icon: Icons.refresh,
              ),
              child: Opacity(
                opacity: isAppWindowTarget ? 1.0 : 0.5,
                child: AppFormRow(
                  control: PlatformDropdown<int?>(
                    value: validAppWindowId,
                    items: [
                      PlatformMenuItem(
                        value: null,
                        label: l10n.selectAppWindow,
                      ),
                      ...appWindows.map(
                        (window) => PlatformMenuItem(
                          value: window.id,
                          label: window.label,
                        ),
                      ),
                    ],
                    onChanged: isAppWindowTarget && !isRecording
                        ? onAppWindowChanged
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ),
        _AnimatedSection(
          visible: isAreaTarget,
          child: Padding(
            padding: const EdgeInsets.only(top: AppSidebarTokens.sectionGap),
            child: AppSection(
              title: l10n.areaRecording,
              infoTooltip: l10n.areaRecordingHelper,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                  if (areaRect != null)
                    Text(
                      l10n.selectedAreaAt(
                        areaDisplayId?.toString() ?? '?',
                        areaRect!.width.toInt().toString(),
                        areaRect!.height.toInt().toString(),
                        areaRect!.left.toInt().toString(),
                        areaRect!.top.toInt().toString(),
                      ),
                      style: AppSidebarTokens.helperStyle(theme).copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  else
                    Text(
                      l10n.noAreaSelected,
                      style: AppSidebarTokens.helperStyle(theme),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
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
