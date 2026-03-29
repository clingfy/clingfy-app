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
    required this.cameraExportCapabilities,
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
    required this.onZoomBehaviorChanged,
    required this.onZoomScaleMultiplierChanged,
    required this.onZoomScaleMultiplierChangeEnd,
    required this.onIntroPresetChanged,
    required this.onOutroPresetChanged,
    required this.onZoomEmphasisPresetChanged,
    required this.onIntroDurationChanged,
    required this.onIntroDurationChangeEnd,
    required this.onOutroDurationChanged,
    required this.onOutroDurationChangeEnd,
    required this.onZoomEmphasisStrengthChanged,
    required this.onZoomEmphasisStrengthChangeEnd,
    required this.onManualCenterXChanged,
    required this.onManualCenterXChangeEnd,
    required this.onManualCenterYChanged,
    required this.onManualCenterYChangeEnd,
    required this.onResetManualPosition,
  });

  final bool hasCameraAsset;
  final CameraExportCapabilities cameraExportCapabilities;
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
  final ValueChanged<CameraZoomBehavior> onZoomBehaviorChanged;
  final ValueChanged<double> onZoomScaleMultiplierChanged;
  final ValueChanged<double> onZoomScaleMultiplierChangeEnd;
  final ValueChanged<CameraIntroPreset> onIntroPresetChanged;
  final ValueChanged<CameraOutroPreset> onOutroPresetChanged;
  final ValueChanged<CameraZoomEmphasisPreset> onZoomEmphasisPresetChanged;
  final ValueChanged<double> onIntroDurationChanged;
  final ValueChanged<double> onIntroDurationChangeEnd;
  final ValueChanged<double> onOutroDurationChanged;
  final ValueChanged<double> onOutroDurationChangeEnd;
  final ValueChanged<double> onZoomEmphasisStrengthChanged;
  final ValueChanged<double> onZoomEmphasisStrengthChangeEnd;
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
                PlatformMenuItem(value: CameraContentMode.fit, label: l10n.fit),
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
          AppFormRow(
            label: 'Zoom Response',
            control: PlatformDropdown<CameraZoomBehavior>(
              value: camera.zoomBehavior,
              items: const [
                PlatformMenuItem(
                  value: CameraZoomBehavior.fixed,
                  label: 'Fixed',
                ),
                PlatformMenuItem(
                  value: CameraZoomBehavior.scaleWithScreenZoom,
                  label: 'Scale with Zoom',
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  onZoomBehaviorChanged(value);
                }
              },
            ),
          ),
          if (camera.zoomBehavior ==
              CameraZoomBehavior.scaleWithScreenZoom) ...[
            const SizedBox(height: AppSidebarTokens.sectionGap),
            AppSliderRow(
              label: 'Zoom Scale',
              valueText: '${(camera.zoomScaleMultiplier * 100).round()}%',
              slider: _buildSidebarSlider(
                context,
                value: camera.zoomScaleMultiplier,
                min: 0.0,
                max: 1.0,
                divisions: 100,
                onChanged: onZoomScaleMultiplierChanged,
                onChangeEnd: onZoomScaleMultiplierChangeEnd,
                accentColor: accentColor,
              ),
            ),
          ],
          const SizedBox(height: AppSidebarTokens.sectionGap),
          AppFormRow(
            label: 'Intro',
            control: PlatformDropdown<CameraIntroPreset>(
              value: camera.introPreset,
              items: const [
                PlatformMenuItem(value: CameraIntroPreset.none, label: 'None'),
                PlatformMenuItem(value: CameraIntroPreset.fade, label: 'Fade'),
                PlatformMenuItem(value: CameraIntroPreset.pop, label: 'Pop'),
                PlatformMenuItem(
                  value: CameraIntroPreset.slide,
                  label: 'Slide',
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  onIntroPresetChanged(value);
                }
              },
            ),
          ),
          if (camera.introPreset != CameraIntroPreset.none) ...[
            const SizedBox(height: AppSidebarTokens.sectionGap),
            AppSliderRow(
              label: 'Intro Duration',
              valueText: '${camera.introDurationMs} ms',
              slider: _buildSidebarSlider(
                context,
                value: camera.introDurationMs.toDouble(),
                min: 80.0,
                max: 600.0,
                divisions: 26,
                onChanged: onIntroDurationChanged,
                onChangeEnd: onIntroDurationChangeEnd,
                accentColor: accentColor,
              ),
            ),
          ],
          const SizedBox(height: AppSidebarTokens.sectionGap),
          AppFormRow(
            label: 'Outro',
            control: PlatformDropdown<CameraOutroPreset>(
              value: camera.outroPreset,
              items: const [
                PlatformMenuItem(value: CameraOutroPreset.none, label: 'None'),
                PlatformMenuItem(value: CameraOutroPreset.fade, label: 'Fade'),
                PlatformMenuItem(
                  value: CameraOutroPreset.shrink,
                  label: 'Shrink',
                ),
                PlatformMenuItem(
                  value: CameraOutroPreset.slide,
                  label: 'Slide',
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  onOutroPresetChanged(value);
                }
              },
            ),
          ),
          if (camera.outroPreset != CameraOutroPreset.none) ...[
            const SizedBox(height: AppSidebarTokens.sectionGap),
            AppSliderRow(
              label: 'Outro Duration',
              valueText: '${camera.outroDurationMs} ms',
              slider: _buildSidebarSlider(
                context,
                value: camera.outroDurationMs.toDouble(),
                min: 80.0,
                max: 600.0,
                divisions: 26,
                onChanged: onOutroDurationChanged,
                onChangeEnd: onOutroDurationChangeEnd,
                accentColor: accentColor,
              ),
            ),
          ],
          const SizedBox(height: AppSidebarTokens.sectionGap),
          AppFormRow(
            label: 'Zoom Emphasis',
            control: PlatformDropdown<CameraZoomEmphasisPreset>(
              value: camera.zoomEmphasisPreset,
              items: const [
                PlatformMenuItem(
                  value: CameraZoomEmphasisPreset.none,
                  label: 'None',
                ),
                PlatformMenuItem(
                  value: CameraZoomEmphasisPreset.pulse,
                  label: 'Pulse',
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  onZoomEmphasisPresetChanged(value);
                }
              },
            ),
          ),
          if (camera.zoomEmphasisPreset == CameraZoomEmphasisPreset.pulse) ...[
            const SizedBox(height: AppSidebarTokens.sectionGap),
            AppSliderRow(
              label: 'Pulse Strength',
              valueText: '${(camera.zoomEmphasisStrength * 100).round()}%',
              slider: _buildSidebarSlider(
                context,
                value: camera.zoomEmphasisStrength,
                min: 0.0,
                max: 0.2,
                divisions: 20,
                onChanged: onZoomEmphasisStrengthChanged,
                onChangeEnd: onZoomEmphasisStrengthChangeEnd,
                accentColor: accentColor,
              ),
            ),
          ],
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
