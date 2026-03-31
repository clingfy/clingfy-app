import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
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
    required this.onManualCenterChanged,
    required this.onManualCenterChangeEnd,
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
  final ValueChanged<Offset> onManualCenterChanged;
  final ValueChanged<Offset> onManualCenterChangeEnd;

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
            helperText: 'Adjust or move camera position on screen',
            control: _CameraPositionPanel(
              camera: camera,
              onPresetSelected: onLayoutPresetChanged,
              onManualCenterChanged: onManualCenterChanged,
              onManualCenterChangeEnd: onManualCenterChangeEnd,
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
        ],
      ],
    );
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

class _CameraPositionPanel extends StatefulWidget {
  const _CameraPositionPanel({
    required this.camera,
    required this.onPresetSelected,
    required this.onManualCenterChanged,
    required this.onManualCenterChangeEnd,
  });

  final CameraCompositionState camera;
  final ValueChanged<CameraLayoutPreset> onPresetSelected;
  final ValueChanged<Offset> onManualCenterChanged;
  final ValueChanged<Offset> onManualCenterChangeEnd;

  @override
  State<_CameraPositionPanel> createState() => _CameraPositionPanelState();
}

class _CameraPositionPanelState extends State<_CameraPositionPanel> {
  static const double _panelHeight = 176;
  static const double _handleSize = 30;
  static const double _presetDotSize = 12;
  static const double _presetTapTargetSize = 28;
  static const double _presetInsetX = 0.07;
  static const double _presetInsetY = 0.14;
  static const double _presetBottomInsetY = 0.86;
  static const double _handleShadowBlur = 18;
  static const List<_CameraPositionPreset> _presets = [
    _CameraPositionPreset(
      preset: CameraLayoutPreset.overlayTopLeft,
      normalizedPosition: Offset(_presetInsetX, _presetInsetY),
      label: 'Top left',
    ),
    _CameraPositionPreset(
      preset: CameraLayoutPreset.stackedTop,
      normalizedPosition: Offset(0.5, _presetInsetY),
      label: 'Top center',
    ),
    _CameraPositionPreset(
      preset: CameraLayoutPreset.overlayTopRight,
      normalizedPosition: Offset(1 - _presetInsetX, _presetInsetY),
      label: 'Top right',
    ),
    _CameraPositionPreset(
      preset: CameraLayoutPreset.sideBySideLeft,
      normalizedPosition: Offset(_presetInsetX, 0.5),
      label: 'Center left',
    ),
    _CameraPositionPreset(
      preset: CameraLayoutPreset.sideBySideRight,
      normalizedPosition: Offset(1 - _presetInsetX, 0.5),
      label: 'Center right',
    ),
    _CameraPositionPreset(
      preset: CameraLayoutPreset.overlayBottomLeft,
      normalizedPosition: Offset(_presetInsetX, _presetBottomInsetY),
      label: 'Bottom left',
    ),
    _CameraPositionPreset(
      preset: CameraLayoutPreset.stackedBottom,
      normalizedPosition: Offset(0.5, _presetBottomInsetY),
      label: 'Bottom center',
    ),
    _CameraPositionPreset(
      preset: CameraLayoutPreset.overlayBottomRight,
      normalizedPosition: Offset(1 - _presetInsetX, _presetBottomInsetY),
      label: 'Bottom right',
    ),
  ];

  final GlobalKey _panelKey = GlobalKey();
  Offset? _dragNormalizedCenter;

  Offset get _resolvedHandlePosition {
    final normalizedCenter = widget.camera.normalizedCanvasCenter;
    if (normalizedCenter != null) {
      return Offset(
        normalizedCenter.dx.clamp(0.0, 1.0),
        (1.0 - normalizedCenter.dy).clamp(0.0, 1.0), // Invert: native bottom-up -> Flutter top-down for display
      );
    }

    return _presetPositionForLayout(widget.camera.layoutPreset) ??
        const Offset(0.5, 0.5);
  }

  bool get _showsBackgroundBehindHint =>
      widget.camera.layoutPreset == CameraLayoutPreset.backgroundBehind &&
      widget.camera.normalizedCanvasCenter == null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary;
    final surfaceColor = theme.colorScheme.surfaceContainerHighest.withValues(
      alpha: 0.72,
    );
    final handlePosition = _dragNormalizedCenter ?? _resolvedHandlePosition;

    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: AppSidebarTokens.controlMinWidth,
        maxWidth: AppSidebarTokens.controlMaxWidth,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_showsBackgroundBehindHint)
            Padding(
              padding: const EdgeInsets.only(
                bottom: AppSidebarTokens.sectionGap,
              ),
              child: Text(
                'Background layout fills the full canvas. Choose a point or drag the handle to switch back to an overlay position.',
                style: AppSidebarTokens.helperStyle(theme),
              ),
            ),
          SizedBox(
            key: const ValueKey('camera_position_panel'),
            height: _panelHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: surfaceColor,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.28,
                  ),
                ),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final height = constraints.maxHeight;

                  return Stack(
                    key: _panelKey,
                    children: [
                      for (final preset in _presets)
                        _buildPresetDot(
                          context,
                          preset: preset,
                          width: width,
                          height: height,
                        ),
                      _buildHandle(
                        context,
                        handlePosition: handlePosition,
                        width: width,
                        height: height,
                        accentColor: accentColor,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetDot(
    BuildContext context, {
    required _CameraPositionPreset preset,
    required double width,
    required double height,
  }) {
    final theme = Theme.of(context);
    final center = _positionToPanelOffset(
      preset.normalizedPosition,
      width: width,
      height: height,
      itemSize: _presetDotSize,
    );
    final isSelected =
        widget.camera.normalizedCanvasCenter == null &&
        widget.camera.layoutPreset == preset.preset;

    return Positioned(
      left: center.dx - (_presetTapTargetSize / 2),
      top: center.dy - (_presetTapTargetSize / 2),
      child: Semantics(
        button: true,
        label: 'Camera position ${preset.label}',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: ValueKey('camera_position_preset_${preset.preset.name}'),
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() {
                _dragNormalizedCenter = null;
              });
              widget.onPresetSelected(preset.preset);
            },
            child: SizedBox(
              width: _presetTapTargetSize,
              height: _presetTapTargetSize,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: _presetDotSize,
                  height: _presetDotSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isSelected
                        ? theme.colorScheme.primary.withValues(alpha: 0.5)
                        : theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.22,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHandle(
    BuildContext context, {
    required Offset handlePosition,
    required double width,
    required double height,
    required Color accentColor,
  }) {
    final center = _positionToPanelOffset(
      handlePosition,
      width: width,
      height: height,
      itemSize: _handleSize,
    );

    return Positioned(
      left: center.dx - (_handleSize / 2),
      top: center.dy - (_handleSize / 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const ValueKey('camera_position_handle'),
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) => _updateDrag(details.globalPosition),
          onPanUpdate: (details) => _updateDrag(details.globalPosition),
          onPanEnd: (_) => _commitDrag(),
          onPanCancel: _cancelDrag,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: _handleSize,
            height: _handleSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accentColor,
              border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
              boxShadow: [
                BoxShadow(
                  color: accentColor.withValues(alpha: 0.42),
                  blurRadius: _handleShadowBlur,
                  spreadRadius: 1.5,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _updateDrag(Offset globalPosition) {
    final renderObject = _panelKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) {
      return;
    }

    final local = renderObject.globalToLocal(globalPosition);
    final size = renderObject.size;
    final nextCenter = Offset(
      (local.dx / size.width).clamp(0.0, 1.0),
      (local.dy / size.height).clamp(0.0, 1.0),
    );

    setState(() {
      _dragNormalizedCenter = nextCenter;
    });
    widget.onManualCenterChanged(nextCenter);
  }

  void _commitDrag() {
    final dragCenter = _dragNormalizedCenter;
    if (dragCenter == null) {
      return;
    }

    widget.onManualCenterChangeEnd(dragCenter);
    setState(() {
      _dragNormalizedCenter = null;
    });
  }

  void _cancelDrag() {
    setState(() {
      _dragNormalizedCenter = null;
    });
  }

  Offset _positionToPanelOffset(
    Offset normalizedPosition, {
    required double width,
    required double height,
    required double itemSize,
  }) {
    final horizontalTravel = width - itemSize;
    final verticalTravel = height - itemSize;
    return Offset(
      (normalizedPosition.dx.clamp(0.0, 1.0) * horizontalTravel) +
          (itemSize / 2),
      (normalizedPosition.dy.clamp(0.0, 1.0) * verticalTravel) + (itemSize / 2),
    );
  }

  Offset? _presetPositionForLayout(CameraLayoutPreset preset) {
    for (final item in _presets) {
      if (item.preset == preset) {
        return item.normalizedPosition;
      }
    }

    return null;
  }
}

class _CameraPositionPreset {
  const _CameraPositionPreset({
    required this.preset,
    required this.normalizedPosition,
    required this.label,
  });

  final CameraLayoutPreset preset;
  final Offset normalizedPosition;
  final String label;
}
