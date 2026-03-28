import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:flutter/material.dart' hide PlatformMenuItem;

class PostCameraSection extends StatelessWidget {
  const PostCameraSection({
    super.key,
    required this.hasCameraAsset,
    required this.cameraState,
    required this.onVisibleChanged,
    required this.onLayoutPresetChanged,
    required this.onSizeFactorChanged,
    required this.onSizeFactorChangeEnd,
    required this.onShapeChanged,
    required this.onCornerRadiusChanged,
    required this.onCornerRadiusChangeEnd,
    required this.onMirrorChanged,
    required this.onContentModeChanged,
    required this.onManualCenterXChanged,
    required this.onManualCenterXChangeEnd,
    required this.onManualCenterYChanged,
    required this.onManualCenterYChangeEnd,
    required this.onResetManualPosition,
  });

  final bool hasCameraAsset;
  final CameraCompositionState? cameraState;
  final ValueChanged<bool> onVisibleChanged;
  final ValueChanged<CameraLayoutPreset> onLayoutPresetChanged;
  final ValueChanged<double> onSizeFactorChanged;
  final ValueChanged<double> onSizeFactorChangeEnd;
  final ValueChanged<CameraShape> onShapeChanged;
  final ValueChanged<double> onCornerRadiusChanged;
  final ValueChanged<double> onCornerRadiusChangeEnd;
  final ValueChanged<bool> onMirrorChanged;
  final ValueChanged<CameraContentMode> onContentModeChanged;
  final ValueChanged<double> onManualCenterXChanged;
  final ValueChanged<double> onManualCenterXChangeEnd;
  final ValueChanged<double> onManualCenterYChanged;
  final ValueChanged<double> onManualCenterYChangeEnd;
  final VoidCallback onResetManualPosition;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final accentColor = Theme.of(context).colorScheme.primary;
    final camera = cameraState ?? const CameraCompositionState.hidden();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppToggleRow(
          title: l10n.camera,
          value: hasCameraAsset && camera.visible,
          onChanged: hasCameraAsset ? onVisibleChanged : null,
        ),
        if (!hasCameraAsset) ...[
          const SizedBox(height: AppSidebarTokens.compactGap),
          const AppInlineNotice(
            message: 'No separate camera asset was recorded for this clip.',
            variant: AppInlineNoticeVariant.info,
          ),
        ] else ...[
          const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
          AppFormRow(
            label: l10n.position,
            control: PlatformDropdown<CameraLayoutPreset>(
              value: camera.layoutPreset,
              items: CameraLayoutPreset.values
                  .map(
                    (preset) => PlatformMenuItem(
                      value: preset,
                      label: _layoutLabel(preset),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  onLayoutPresetChanged(value);
                }
              },
            ),
          ),
          const SizedBox(height: AppSidebarTokens.sectionGap),
          AppSliderRow(
            label: l10n.size,
            valueText: '${(camera.sizeFactor * 100).round()}%',
            slider: _buildSidebarSlider(
              context,
              value: camera.sizeFactor,
              min: 0.08,
              max: 0.45,
              divisions: 37,
              onChanged: onSizeFactorChanged,
              onChangeEnd: onSizeFactorChangeEnd,
              accentColor: accentColor,
            ),
          ),
          const SizedBox(height: AppSidebarTokens.sectionGap),
          AppFormRow(
            label: l10n.shape,
            control: PlatformDropdown<CameraShape>(
              value: camera.shape,
              items: CameraShape.values
                  .map(
                    (shape) => PlatformMenuItem(
                      value: shape,
                      label: _shapeLabel(shape),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  onShapeChanged(value);
                }
              },
            ),
          ),
          const SizedBox(height: AppSidebarTokens.sectionGap),
          AppSliderRow(
            label: l10n.roundedCorners,
            valueText: '${(camera.cornerRadius * 100).round()}%',
            slider: _buildSidebarSlider(
              context,
              value: camera.cornerRadius,
              min: 0.0,
              max: 0.5,
              divisions: 50,
              onChanged: onCornerRadiusChanged,
              onChangeEnd: onCornerRadiusChangeEnd,
              accentColor: accentColor,
            ),
          ),
          const SizedBox(height: AppSidebarTokens.sectionGap),
          AppFormRow(
            label: l10n.fitMode,
            control: PlatformDropdown<CameraContentMode>(
              value: camera.contentMode,
              items: [
                PlatformMenuItem(
                  value: CameraContentMode.fit,
                  label: l10n.fit,
                ),
                PlatformMenuItem(
                  value: CameraContentMode.fill,
                  label: l10n.fill,
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  onContentModeChanged(value);
                }
              },
            ),
          ),
          const SizedBox(height: AppSidebarTokens.sectionGap),
          AppToggleRow(
            title: l10n.mirrorSelfView,
            value: camera.mirror,
            onChanged: onMirrorChanged,
          ),
          const SizedBox(height: AppSidebarTokens.sectionGap),
          AppSliderRow(
            label: '${l10n.customPosition} X',
            valueText:
                '${(((camera.normalizedCanvasCenter?.dx ?? 0.5) * 100).round())}%',
            slider: _buildSidebarSlider(
              context,
              value: camera.normalizedCanvasCenter?.dx ?? 0.5,
              min: 0.0,
              max: 1.0,
              divisions: 100,
              onChanged: onManualCenterXChanged,
              onChangeEnd: onManualCenterXChangeEnd,
              accentColor: accentColor,
            ),
          ),
          const SizedBox(height: AppSidebarTokens.sectionGap),
          AppSliderRow(
            label: '${l10n.customPosition} Y',
            valueText:
                '${(((camera.normalizedCanvasCenter?.dy ?? 0.5) * 100).round())}%',
            slider: _buildSidebarSlider(
              context,
              value: camera.normalizedCanvasCenter?.dy ?? 0.5,
              min: 0.0,
              max: 1.0,
              divisions: 100,
              onChanged: onManualCenterYChanged,
              onChangeEnd: onManualCenterYChangeEnd,
              accentColor: accentColor,
            ),
          ),
          const SizedBox(height: AppSidebarTokens.sectionGap),
          AppButton(
            label: 'Reset manual position',
            onPressed: onResetManualPosition,
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.compact,
          ),
        ],
      ],
    );
  }

  String _layoutLabel(CameraLayoutPreset preset) {
    switch (preset) {
      case CameraLayoutPreset.overlayTopLeft:
        return 'Overlay Top Left';
      case CameraLayoutPreset.overlayTopRight:
        return 'Overlay Top Right';
      case CameraLayoutPreset.overlayBottomLeft:
        return 'Overlay Bottom Left';
      case CameraLayoutPreset.overlayBottomRight:
        return 'Overlay Bottom Right';
      case CameraLayoutPreset.sideBySideLeft:
        return 'Side by Side Left';
      case CameraLayoutPreset.sideBySideRight:
        return 'Side by Side Right';
      case CameraLayoutPreset.stackedTop:
        return 'Stacked Top';
      case CameraLayoutPreset.stackedBottom:
        return 'Stacked Bottom';
      case CameraLayoutPreset.backgroundBehind:
        return 'Background Behind';
      case CameraLayoutPreset.hidden:
        return 'Hidden';
    }
  }

  String _shapeLabel(CameraShape shape) {
    switch (shape) {
      case CameraShape.circle:
        return 'Circle';
      case CameraShape.roundedRect:
        return 'Rounded Rectangle';
      case CameraShape.square:
        return 'Square';
      case CameraShape.squircle:
        return 'Squircle';
    }
  }

  Widget _buildSidebarSlider(
    BuildContext context, {
    required double value,
    required double min,
    required double max,
    required ValueChanged<double>? onChanged,
    required ValueChanged<double> onChangeEnd,
    required Color accentColor,
    int? divisions,
  }) {
    final slider = AppSlider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );

    if (isMac()) return slider;

    return SliderTheme(
      data: Theme.of(
        context,
      ).sliderTheme.copyWith(activeTrackColor: accentColor),
      child: slider,
    );
  }
}
