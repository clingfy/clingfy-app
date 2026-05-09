import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/overlay/overlay_mode.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_info_tooltip.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_inset_group.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:clingfy/ui/platform/widgets/app_dialog.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:clingfy/app/home/recording/widgets/overlay_segmented.dart';
import 'package:flutter/material.dart' hide PlatformMenuItem;
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

const _overlayCustomPositionBadgeKey = Key('overlay_custom_position_badge');

class RecordingOverlaySection extends StatelessWidget {
  const RecordingOverlaySection({
    super.key,
    required this.isRecording,
    required this.overlayMode,
    required this.overlayShape,
    required this.overlaySize,
    required this.overlayShadow,
    required this.overlayBorder,
    required this.overlayPosition,
    required this.overlayUseCustomPosition,
    required this.overlayRoundness,
    required this.overlayOpacity,
    required this.overlayMirror,
    required this.overlayRecordingHighlightEnabled,
    required this.overlayRecordingHighlightStrength,
    required this.overlayBorderWidth,
    required this.overlayBorderColor,
    required this.chromaKeyEnabled,
    required this.chromaKeyStrength,
    required this.chromaKeyColor,
    required this.onOverlayModeChanged,
    required this.onOverlayShapeChanged,
    required this.onOverlaySizeChanged,
    required this.onOverlayShadowChanged,
    required this.onOverlayBorderChanged,
    required this.onOverlayPositionChanged,
    required this.onOverlayRoundnessChanged,
    required this.onOverlayOpacityChanged,
    required this.onOverlayMirrorChanged,
    required this.onOverlayRecordingHighlightEnabledChanged,
    required this.onOverlayRecordingHighlightStrengthChanged,
    required this.onOverlayBorderWidthChanged,
    required this.onOverlayBorderColorChanged,
    required this.onChromaKeyEnabledChanged,
    required this.onChromaKeyStrengthChanged,
    required this.onChromaKeyColorChanged,
  });

  final bool isRecording;
  final OverlayMode overlayMode;
  final OverlayShape overlayShape;
  final double overlaySize;
  final OverlayShadow overlayShadow;
  final OverlayBorder overlayBorder;
  final OverlayPosition overlayPosition;
  final bool overlayUseCustomPosition;
  final double overlayRoundness;
  final double overlayOpacity;
  final bool overlayMirror;
  final bool overlayRecordingHighlightEnabled;
  final double overlayRecordingHighlightStrength;
  final double overlayBorderWidth;
  final int overlayBorderColor;
  final bool chromaKeyEnabled;
  final double chromaKeyStrength;
  final int chromaKeyColor;
  final ValueChanged<OverlayMode> onOverlayModeChanged;
  final ValueChanged<OverlayShape> onOverlayShapeChanged;
  final ValueChanged<double> onOverlaySizeChanged;
  final ValueChanged<OverlayShadow> onOverlayShadowChanged;
  final ValueChanged<OverlayBorder> onOverlayBorderChanged;
  final ValueChanged<OverlayPosition> onOverlayPositionChanged;
  final ValueChanged<double> onOverlayRoundnessChanged;
  final ValueChanged<double> onOverlayOpacityChanged;
  final ValueChanged<bool> onOverlayMirrorChanged;
  final ValueChanged<bool> onOverlayRecordingHighlightEnabledChanged;
  final ValueChanged<double> onOverlayRecordingHighlightStrengthChanged;
  final ValueChanged<double> onOverlayBorderWidthChanged;
  final ValueChanged<int> onOverlayBorderColorChanged;
  final ValueChanged<bool> onChromaKeyEnabledChanged;
  final ValueChanged<double> onChromaKeyStrengthChanged;
  final ValueChanged<int> onChromaKeyColorChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildVisibilityAndPlacementGroup(context),
        if (overlayMode != OverlayMode.off) ...[
          _buildAppearanceGroup(context),
          _buildStyleGroup(context),
          _buildEffectsGroup(context),
        ],
      ],
    );
  }

  Widget _buildVisibilityAndPlacementGroup(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AppSettingsGroup(
      title: l10n.visibilityAndPlacement,
      showHeader: false,
      children: [
        AppFormRow(
          label: l10n.overlayFaceCamVisibility,
          infoTooltip: overlayMode == OverlayMode.whileRecording && !isRecording
              ? l10n.overlayHint
              : null,
          control: Builder(
            builder: (context) {
              final metrics = context.shellMetricsOrNull;
              return ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth:
                      metrics?.sidebarControlMinWidth ??
                      AppSidebarTokens.controlMinWidth,
                  maxWidth:
                      metrics?.sidebarControlMaxWidth ??
                      AppSidebarTokens.controlMaxWidth,
                ),
                child: OverlaySegmented(
                  mode: overlayMode,
                  onChanged: onOverlayModeChanged,
                ),
              );
            },
          ),
        ),
        if (overlayMode != OverlayMode.off) ...[
          const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
          AppInsetGroup(
            children: [
              AppFormRow(
                label: l10n.position,
                control: _buildPositionControl(context),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildAppearanceGroup(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AppSettingsGroup(
      title: l10n.appearance,
      showHeader: false,
      children: [
        AppFormRow(
          label: l10n.shape,
          control: PlatformDropdown<OverlayShape>(
            value: overlayShape,
            minWidth: 0,
            maxWidth: double.infinity,
            expand: true,
            items: OverlayShape.uiChoices
                .map(
                  (shape) => PlatformMenuItem(
                    value: shape,
                    label: _localizedShapeName(context, shape),
                  ),
                )
                .toList(),
            onChanged: (shape) {
              if (shape != null) onOverlayShapeChanged(shape);
            },
          ),
        ),
        if (_canShowRoundness(overlayShape)) ...[
          const SizedBox(height: AppSidebarTokens.rowGap),
          AppSliderRow(
            label: l10n.roundedCorners,
            slider: AppSlider(
              value: overlayRoundness.clamp(0.0, 0.4),
              min: 0.0,
              max: 0.4,
              divisions: 20,
              valueLabel: '${(overlayRoundness * 100).toInt()}%',
              semanticLabel: l10n.roundedCorners,
              onChanged: onOverlayRoundnessChanged,
            ),
          ),
        ],
        const SizedBox(height: AppSidebarTokens.rowGap),
        AppSliderRow(
          label: l10n.size,
          slider: AppSlider(
            value: overlaySize,
            min: 120,
            max: 400,
            divisions: 28,
            valueLabel: '${overlaySize.toInt()}px',
            semanticLabel: l10n.size,
            onChanged: onOverlaySizeChanged,
          ),
        ),
        const SizedBox(height: AppSidebarTokens.rowGap),
        AppSliderRow(
          label: l10n.opacity,
          slider: AppSlider(
            value: overlayOpacity.clamp(0.3, 1.0),
            min: 0.3,
            max: 1.0,
            divisions: 14,
            valueLabel: '${(overlayOpacity * 100).round()}%',
            semanticLabel: l10n.opacity,
            onChanged: onOverlayOpacityChanged,
          ),
        ),
        const SizedBox(height: AppSidebarTokens.rowGap),
        AppToggleRow(
          title: l10n.mirrorSelfView,
          value: overlayMirror,
          onChanged: onOverlayMirrorChanged,
        ),
      ],
    );
  }

  Widget _buildStyleGroup(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AppSettingsGroup(
      title: l10n.style,
      showHeader: false,
      children: [
        AppFormRow(
          label: l10n.shadow,
          control: PlatformDropdown<OverlayShadow>(
            value: overlayShadow,
            minWidth: 0,
            maxWidth: double.infinity,
            expand: true,
            items: OverlayShadow.values
                .map(
                  (shadow) => PlatformMenuItem(
                    value: shadow,
                    label: shadow.name.toUpperCase(),
                  ),
                )
                .toList(),
            onChanged: (shadow) {
              if (shadow != null) onOverlayShadowChanged(shadow);
            },
          ),
        ),
        const SizedBox(height: AppSidebarTokens.rowGap),
        AppFormRow(label: l10n.border, control: _buildBorderControl(context)),
        ...[
          const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
          AppInsetGroup(
            children: [
              AppButton(
                label: l10n.moreColors,
                onPressed: () {
                  _showColorPickerDialog(
                    context,
                    title: l10n.pickBorderColor,
                    initialColor: Color(overlayBorderColor),
                    onColorSelected: (color) =>
                        onOverlayBorderColorChanged(color.toARGB32()),
                  );
                },
                variant: AppButtonVariant.secondary,
                size: AppButtonSize.regular,
              ),
              const SizedBox(height: AppSidebarTokens.sectionGap),
              if (overlayBorder != OverlayBorder.none)
                AppSliderRow(
                  label: l10n.borderWidthLabel,
                  slider: AppSlider(
                    value: overlayBorderWidth,
                    min: 0.0,
                    max: 12.0,
                    divisions: 24,
                    valueLabel: '${overlayBorderWidth.toStringAsFixed(1)}px',
                    semanticLabel: l10n.borderWidthLabel,
                    onChanged: onOverlayBorderWidthChanged,
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildEffectsGroup(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AppSettingsGroup(
      title: l10n.effects,
      showHeader: false,
      children: [
        AppToggleRow(
          title: l10n.recordingHighlight,
          value: overlayRecordingHighlightEnabled,
          onChanged: onOverlayRecordingHighlightEnabledChanged,
        ),
        if (overlayRecordingHighlightEnabled) ...[
          const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
          AppInsetGroup(
            children: [
              AppSliderRow(
                label: l10n.recordingGlowStrength,
                slider: AppSlider(
                  value: (overlayRecordingHighlightStrength * 100).clamp(
                    10.0,
                    100.0,
                  ),
                  min: 10,
                  max: 100,
                  divisions: 90,
                  valueLabel:
                      '${(overlayRecordingHighlightStrength * 100).round()}%',
                  semanticLabel: l10n.recordingGlowStrength,
                  onChanged: (value) =>
                      onOverlayRecordingHighlightStrengthChanged(value / 100),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: AppSidebarTokens.rowGap),
        AppToggleRow(
          title: l10n.chromaKey,
          value: chromaKeyEnabled,
          onChanged: onChromaKeyEnabledChanged,
        ),
        if (chromaKeyEnabled) ...[
          const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
          AppInsetGroup(
            children: [
              AppSliderRow(
                label: l10n.keyToleranceLabel,
                slider: AppSlider(
                  value: chromaKeyStrength.clamp(0.0, 1.0),
                  min: 0.0,
                  max: 1.0,
                  divisions: 20,
                  valueLabel: '${(chromaKeyStrength * 100).toInt()}%',
                  semanticLabel: l10n.keyToleranceLabel,
                  onChanged: onChromaKeyStrengthChanged,
                ),
              ),
              const SizedBox(height: AppSidebarTokens.rowGap),
              AppFormRow(
                label: l10n.chromaKeyColor,
                infoTooltip: l10n.targetColorToRemove,
                control: _buildChromaKeyColorControl(context),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildPositionControl(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final metrics = context.shellMetricsOrNull;

    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth:
            metrics?.sidebarControlMinWidth ?? AppSidebarTokens.controlMinWidth,
        maxWidth:
            metrics?.sidebarControlMaxWidth ?? AppSidebarTokens.controlMaxWidth,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 24,
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: overlayUseCustomPosition
                    ? _CustomPositionBadge(
                        key: const ValueKey('custom_position_badge'),
                        label: l10n.customPosition,
                        infoTooltip: l10n.customPositionHint,
                      )
                    : const SizedBox.shrink(
                        key: ValueKey('no_custom_position_badge'),
                      ),
              ),
            ),
          ),
          const SizedBox(height: AppSidebarTokens.compactGap),
          SizedBox(
            height: 120,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      _PositionButton(
                        position: OverlayPosition.topLeft,
                        icon: Icons.north_west,
                        isSelected:
                            !overlayUseCustomPosition &&
                            overlayPosition == OverlayPosition.topLeft,
                        onTap: onOverlayPositionChanged,
                      ),
                      const SizedBox(height: AppSidebarTokens.compactGap),
                      _PositionButton(
                        position: OverlayPosition.bottomLeft,
                        icon: Icons.south_west,
                        isSelected:
                            !overlayUseCustomPosition &&
                            overlayPosition == OverlayPosition.bottomLeft,
                        onTap: onOverlayPositionChanged,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSidebarTokens.compactGap),
                Expanded(
                  child: Column(
                    children: [
                      _PositionButton(
                        position: OverlayPosition.topRight,
                        icon: Icons.north_east,
                        isSelected:
                            !overlayUseCustomPosition &&
                            overlayPosition == OverlayPosition.topRight,
                        onTap: onOverlayPositionChanged,
                      ),
                      const SizedBox(height: AppSidebarTokens.compactGap),
                      _PositionButton(
                        position: OverlayPosition.bottomRight,
                        icon: Icons.south_east,
                        isSelected:
                            !overlayUseCustomPosition &&
                            overlayPosition == OverlayPosition.bottomRight,
                        onTap: onOverlayPositionChanged,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBorderControl(BuildContext context) {
    final metrics = context.shellMetricsOrNull;
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth:
            metrics?.sidebarControlMinWidth ?? AppSidebarTokens.controlMinWidth,
        maxWidth:
            metrics?.sidebarControlMaxWidth ?? AppSidebarTokens.controlMaxWidth,
      ),
      child: Wrap(
        spacing: AppSidebarTokens.rowGap,
        runSpacing: AppSidebarTokens.rowGap,
        children: [
          _BorderCircle(
            border: OverlayBorder.none,
            isSelected: overlayBorder == OverlayBorder.none,
            onTap: onOverlayBorderChanged,
          ),
          _BorderCircle(
            border: OverlayBorder.white,
            colorValue: 0xFFFFFFFF,
            isSelected: overlayBorder == OverlayBorder.white,
            onTap: onOverlayBorderChanged,
          ),
          _BorderCircle(
            border: OverlayBorder.black,
            colorValue: 0xFF000000,
            isSelected: overlayBorder == OverlayBorder.black,
            onTap: onOverlayBorderChanged,
          ),
          _BorderCircle(
            border: OverlayBorder.green,
            colorValue: 0xFF00CC66,
            isSelected: overlayBorder == OverlayBorder.green,
            onTap: onOverlayBorderChanged,
          ),
          _BorderCircle(
            border: OverlayBorder.cyan,
            colorValue: 0xFF00E5FF,
            isSelected: overlayBorder == OverlayBorder.cyan,
            onTap: onOverlayBorderChanged,
          ),
          if (overlayBorder == OverlayBorder.custom)
            _BorderCircle(
              border: OverlayBorder.custom,
              colorValue: overlayBorderColor,
              isSelected: true,
              onTap: onOverlayBorderChanged,
            ),
        ],
      ),
    );
  }

  Widget _buildChromaKeyColorControl(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final metrics = context.shellMetricsOrNull;

    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth:
            metrics?.sidebarControlMinWidth ?? AppSidebarTokens.controlMinWidth,
        maxWidth:
            metrics?.sidebarControlMaxWidth ?? AppSidebarTokens.controlMaxWidth,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () {
              _showColorPickerDialog(
                context,
                title: l10n.pickChromaKeyColor,
                initialColor: Color(chromaKeyColor),
                onColorSelected: (color) =>
                    onChromaKeyColorChanged(color.toARGB32()),
              );
            },
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color(chromaKeyColor),
                border: Border.all(color: theme.dividerColor, width: 1),
              ),
            ),
          ),
          const SizedBox(width: AppSidebarTokens.compactGap),
          AppButton(
            label: l10n.pickChromaKeyColor,
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.regular,
            onPressed: () {
              _showColorPickerDialog(
                context,
                title: l10n.pickChromaKeyColor,
                initialColor: Color(chromaKeyColor),
                onColorSelected: (color) =>
                    onChromaKeyColorChanged(color.toARGB32()),
              );
            },
          ),
        ],
      ),
    );
  }

  static bool _canShowRoundness(OverlayShape shape) {
    return shape == OverlayShape.roundedRect ||
        shape == OverlayShape.square ||
        shape == OverlayShape.hexagon ||
        shape == OverlayShape.star;
  }

  static String _localizedShapeName(BuildContext context, OverlayShape shape) {
    final l10n = AppLocalizations.of(context)!;
    switch (shape) {
      case OverlayShape.circle:
        return l10n.circle;
      case OverlayShape.roundedRect:
        return l10n.roundedRect;
      case OverlayShape.square:
        return l10n.square;
      case OverlayShape.hexagon:
        return l10n.hexagon;
      case OverlayShape.star:
        return l10n.star;
      case OverlayShape.squircle:
        return l10n.squircle;
    }
  }

  static Future<void> _showColorPickerDialog(
    BuildContext context, {
    required String title,
    required Color initialColor,
    required ValueChanged<Color> onColorSelected,
  }) {
    Color pickerColor = initialColor;
    final l10n = AppLocalizations.of(context)!;
    return AppDialog.show<bool>(
      context,
      title: title,
      maxWidth: 360,
      primaryLabel: l10n.gotIt,
      primaryBuilder: () {
        onColorSelected(pickerColor);
        return true;
      },
      content: SingleChildScrollView(
        child: SizedBox(
          width: 280,
          child: ColorPicker(
            pickerColor: pickerColor,
            onColorChanged: (color) => pickerColor = color,
            labelTypes: const [],
            pickerAreaHeightPercent: 0.78,
            portraitOnly: true,
            colorPickerWidth: 280,
          ),
        ),
      ),
    );
  }
}

class _CustomPositionBadge extends StatelessWidget {
  const _CustomPositionBadge({
    super.key,
    required this.label,
    required this.infoTooltip,
  });

  final String label;
  final String infoTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: _overlayCustomPositionBadgeKey,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            label,
            style: AppSidebarTokens.valueStyle(theme).copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: theme.primaryColor,
            ),
          ),
        ),
        const SizedBox(width: AppSidebarTokens.compactGap),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: AppInlineInfoTooltip(
            key: const ValueKey('overlay_custom_position_info'),
            message: infoTooltip,
            size: 14,
          ),
        ),
      ],
    );
  }
}

class _PositionButton extends StatelessWidget {
  const _PositionButton({
    required this.position,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  final OverlayPosition position;
  final IconData icon;
  final bool isSelected;
  final ValueChanged<OverlayPosition> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onTap(position),
        child: Container(
          key: ValueKey('overlay_position_${position.name}'),
          height: 56,
          decoration: BoxDecoration(
            color: isSelected
                ? theme.primaryColor.withValues(alpha: 0.2)
                : theme.colorScheme.surfaceContainerHighest,
            border: Border.all(
              color: isSelected
                  ? theme.primaryColor
                  : theme.primaryColor.withValues(alpha: 0.15),
              width: 2,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Icon(
              icon,
              color: isSelected
                  ? theme.primaryColor
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _BorderCircle extends StatelessWidget {
  const _BorderCircle({
    required this.border,
    required this.isSelected,
    required this.onTap,
    this.colorValue,
  });

  final OverlayBorder border;
  final bool isSelected;
  final ValueChanged<OverlayBorder> onTap;
  final int? colorValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = theme.primaryColor;
    final isNone = border == OverlayBorder.none;

    return GestureDetector(
      onTap: () => onTap(border),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: colorValue != null
              ? Color(colorValue!)
              : theme.colorScheme.surfaceContainerHighest,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.onSurface
                : Colors.transparent,
            width: 2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: accentColor.withValues(alpha: 0.5),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: isSelected
            ? Icon(
                Icons.check,
                size: 16,
                color: isNone ? theme.colorScheme.onSurface : Colors.white,
              )
            : (isNone
                  ? Icon(
                      Icons.block,
                      color: theme.textTheme.bodySmall?.color,
                      size: 16,
                    )
                  : null),
      ),
    );
  }
}
