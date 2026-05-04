import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_inset_group.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
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
    required this.onManualCenterSnapped,
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
  final ValueChanged<Offset> onManualCenterSnapped;

  @override
  Widget build(BuildContext context) {
    final camera = cameraState ?? const CameraCompositionState.hidden();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildVisibilityGroup(context, camera),
        if (hasCameraAsset && camera.visible) ...[
          _buildPlacementGroup(context, camera),
          _buildAppearanceGroup(context, camera),
          _buildMotionGroup(context, camera),
        ],
      ],
    );
  }

  Widget _buildVisibilityGroup(
    BuildContext context,
    CameraCompositionState camera,
  ) {
    final l10n = AppLocalizations.of(context)!;

    final cameraToggle = AppToggleRow(
      title: l10n.camera,
      value: hasCameraAsset && camera.visible,
      onChanged: hasCameraAsset ? onVisibleChanged : null,
    );

    return AppSettingsGroup(
      title: l10n.visibility,
      showHeader: false,
      children: [
        if (hasCameraAsset)
          cameraToggle
        else
          Opacity(opacity: 0.45, child: cameraToggle),
        if (!hasCameraAsset) ...[
          const SizedBox(height: AppSidebarTokens.compactGap),
          AppInlineNotice(
            message: l10n.cameraNoAssetNotice,
            variant: AppInlineNoticeVariant.info,
          ),
        ],
      ],
    );
  }

  Widget _buildPlacementGroup(
    BuildContext context,
    CameraCompositionState camera,
  ) {
    final l10n = AppLocalizations.of(context)!;

    return AppSettingsGroup(
      title: l10n.placement,
      showHeader: false,
      children: [
        AppFormRow(
          label: l10n.position,
          helperText: l10n.cameraPlacementHelper,
          control: _CameraPositionPanel(
            camera: camera,
            onPresetSelected: onLayoutPresetChanged,
            onManualCenterChanged: onManualCenterChanged,
            onManualCenterChangeEnd: onManualCenterChangeEnd,
            onManualCenterSnapped: onManualCenterSnapped,
          ),
        ),
      ],
    );
  }

  Widget _buildAppearanceGroup(
    BuildContext context,
    CameraCompositionState camera,
  ) {
    final l10n = AppLocalizations.of(context)!;

    return AppSettingsGroup(
      title: l10n.appearance,
      showHeader: false,
      children: [
        AppSliderRow(
          label: l10n.size,
          slider: _buildSidebarSlider(
            value: camera.sizeFactor,
            min: 0.08,
            max: 0.45,
            divisions: 37,
            valueLabel: '${(camera.sizeFactor * 100).round()}%',
            semanticLabel: l10n.size,
            onChanged: onSizeFactorChanged,
            onChangeEnd: onSizeFactorChangeEnd,
          ),
        ),
        const SizedBox(height: AppSidebarTokens.rowGap),
        AppFormRow(
          label: l10n.shape,
          control: PlatformDropdown<CameraShape>(
            value: camera.shape,
            minWidth: 0,
            maxWidth: double.infinity,
            expand: true,
            items: CameraShape.values
                .map(
                  (shape) => PlatformMenuItem(
                    value: shape,
                    label: _shapeLabel(context, shape),
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
        const SizedBox(height: AppSidebarTokens.rowGap),
        AppSliderRow(
          label: l10n.roundedCorners,
          slider: _buildSidebarSlider(
            value: camera.cornerRadius,
            min: 0.0,
            max: 0.5,
            divisions: 50,
            valueLabel: '${(camera.cornerRadius * 100).round()}%',
            semanticLabel: l10n.roundedCorners,
            onChanged: onCornerRadiusChanged,
            onChangeEnd: onCornerRadiusChangeEnd,
          ),
        ),
        const SizedBox(height: AppSidebarTokens.rowGap),
        AppFormRow(
          label: l10n.fitMode,
          control: PlatformDropdown<CameraContentMode>(
            value: camera.contentMode,
            minWidth: 0,
            maxWidth: double.infinity,
            expand: true,
            items: [
              PlatformMenuItem(value: CameraContentMode.fit, label: l10n.fit),
              PlatformMenuItem(value: CameraContentMode.fill, label: l10n.fill),
            ],
            onChanged: (value) {
              if (value != null) {
                onContentModeChanged(value);
              }
            },
          ),
        ),
        const SizedBox(height: AppSidebarTokens.rowGap),
        AppToggleRow(
          title: l10n.mirrorSelfView,
          value: camera.mirror,
          onChanged: onMirrorChanged,
        ),
      ],
    );
  }

  Widget _buildMotionGroup(
    BuildContext context,
    CameraCompositionState camera,
  ) {
    final l10n = AppLocalizations.of(context)!;

    final children = <Widget>[
      AppFormRow(
        label: l10n.zoomResponse,
        control: PlatformDropdown<CameraZoomBehavior>(
          value: camera.zoomBehavior,
          minWidth: 0,
          maxWidth: double.infinity,
          expand: true,
          items: [
            PlatformMenuItem(
              value: CameraZoomBehavior.fixed,
              label: l10n.fixed,
            ),
            PlatformMenuItem(
              value: CameraZoomBehavior.scaleWithScreenZoom,
              label: l10n.scaleWithZoom,
            ),
          ],
          onChanged: (value) {
            if (value != null) {
              onZoomBehaviorChanged(value);
            }
          },
        ),
      ),
    ];

    if (camera.zoomBehavior == CameraZoomBehavior.scaleWithScreenZoom) {
      children.addAll([
        const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
        AppInsetGroup(
          children: [
            AppSliderRow(
              label: l10n.zoomScale,
              slider: _buildSidebarSlider(
                value: camera.zoomScaleMultiplier,
                min: 0.0,
                max: 1.0,
                divisions: 100,
                valueLabel: '${(camera.zoomScaleMultiplier * 100).round()}%',
                semanticLabel: l10n.zoomScale,
                onChanged: onZoomScaleMultiplierChanged,
                onChangeEnd: onZoomScaleMultiplierChangeEnd,
              ),
            ),
          ],
        ),
      ]);
    }

    children.add(const SizedBox(height: AppSidebarTokens.rowGap));
    children.add(
      AppFormRow(
        label: l10n.intro,
        control: PlatformDropdown<CameraIntroPreset>(
          value: camera.introPreset,
          minWidth: 0,
          maxWidth: double.infinity,
          expand: true,
          items: [
            PlatformMenuItem(value: CameraIntroPreset.none, label: l10n.none),
            PlatformMenuItem(value: CameraIntroPreset.fade, label: l10n.fade),
            PlatformMenuItem(value: CameraIntroPreset.pop, label: l10n.pop),
            PlatformMenuItem(value: CameraIntroPreset.slide, label: l10n.slide),
          ],
          onChanged: (value) {
            if (value != null) {
              onIntroPresetChanged(value);
            }
          },
        ),
      ),
    );

    if (camera.introPreset != CameraIntroPreset.none) {
      children.addAll([
        const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
        AppInsetGroup(
          children: [
            AppSliderRow(
              label: l10n.introDuration,
              slider: _buildSidebarSlider(
                value: camera.introDurationMs.toDouble(),
                min: 80.0,
                max: 600.0,
                divisions: 26,
                valueLabel: '${camera.introDurationMs} ms',
                semanticLabel: l10n.introDuration,
                onChanged: onIntroDurationChanged,
                onChangeEnd: onIntroDurationChangeEnd,
              ),
            ),
          ],
        ),
      ]);
    }

    children.add(const SizedBox(height: AppSidebarTokens.rowGap));
    children.add(
      AppFormRow(
        label: l10n.outro,
        control: PlatformDropdown<CameraOutroPreset>(
          value: camera.outroPreset,
          minWidth: 0,
          maxWidth: double.infinity,
          expand: true,
          items: [
            PlatformMenuItem(value: CameraOutroPreset.none, label: l10n.none),
            PlatformMenuItem(value: CameraOutroPreset.fade, label: l10n.fade),
            PlatformMenuItem(
              value: CameraOutroPreset.shrink,
              label: l10n.shrink,
            ),
            PlatformMenuItem(value: CameraOutroPreset.slide, label: l10n.slide),
          ],
          onChanged: (value) {
            if (value != null) {
              onOutroPresetChanged(value);
            }
          },
        ),
      ),
    );

    if (camera.outroPreset != CameraOutroPreset.none) {
      children.addAll([
        const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
        AppInsetGroup(
          children: [
            AppSliderRow(
              label: l10n.outroDuration,
              slider: _buildSidebarSlider(
                value: camera.outroDurationMs.toDouble(),
                min: 80.0,
                max: 600.0,
                divisions: 26,
                valueLabel: '${camera.outroDurationMs} ms',
                semanticLabel: l10n.outroDuration,
                onChanged: onOutroDurationChanged,
                onChangeEnd: onOutroDurationChangeEnd,
              ),
            ),
          ],
        ),
      ]);
    }

    children.add(const SizedBox(height: AppSidebarTokens.rowGap));
    children.add(
      AppFormRow(
        label: l10n.zoomEmphasis,
        control: PlatformDropdown<CameraZoomEmphasisPreset>(
          value: camera.zoomEmphasisPreset,
          minWidth: 0,
          maxWidth: double.infinity,
          expand: true,
          items: [
            PlatformMenuItem(
              value: CameraZoomEmphasisPreset.none,
              label: l10n.none,
            ),
            PlatformMenuItem(
              value: CameraZoomEmphasisPreset.pulse,
              label: l10n.pulse,
            ),
          ],
          onChanged: (value) {
            if (value != null) {
              onZoomEmphasisPresetChanged(value);
            }
          },
        ),
      ),
    );

    if (camera.zoomEmphasisPreset == CameraZoomEmphasisPreset.pulse) {
      children.addAll([
        const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
        AppInsetGroup(
          children: [
            AppSliderRow(
              label: l10n.pulseStrength,
              slider: _buildSidebarSlider(
                value: camera.zoomEmphasisStrength,
                min: 0.0,
                max: 0.2,
                divisions: 20,
                valueLabel: '${(camera.zoomEmphasisStrength * 100).round()}%',
                semanticLabel: l10n.pulseStrength,
                onChanged: onZoomEmphasisStrengthChanged,
                onChangeEnd: onZoomEmphasisStrengthChangeEnd,
              ),
            ),
          ],
        ),
      ]);
    }

    return AppSettingsGroup(
      title: l10n.motion,
      showHeader: false,
      children: children,
    );
  }

  String _shapeLabel(BuildContext context, CameraShape shape) {
    final l10n = AppLocalizations.of(context)!;

    switch (shape) {
      case CameraShape.circle:
        return l10n.circle;
      case CameraShape.roundedRect:
        return l10n.roundedRect;
      case CameraShape.square:
        return l10n.square;
      case CameraShape.squircle:
        return l10n.squircle;
    }
  }

  Widget _buildSidebarSlider({
    required double value,
    required double min,
    required double max,
    required String valueLabel,
    required String semanticLabel,
    required ValueChanged<double>? onChanged,
    required ValueChanged<double> onChangeEnd,
    int? divisions,
  }) {
    return AppSlider(
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      valueLabel: valueLabel,
      semanticLabel: semanticLabel,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );
  }
}

class _CameraPositionPanel extends StatefulWidget {
  const _CameraPositionPanel({
    required this.camera,
    required this.onPresetSelected,
    required this.onManualCenterChanged,
    required this.onManualCenterChangeEnd,
    required this.onManualCenterSnapped,
  });

  final CameraCompositionState camera;
  final ValueChanged<CameraLayoutPreset> onPresetSelected;
  final ValueChanged<Offset> onManualCenterChanged;
  final ValueChanged<Offset> onManualCenterChangeEnd;
  final ValueChanged<Offset> onManualCenterSnapped;

  @override
  State<_CameraPositionPanel> createState() => _CameraPositionPanelState();
}

enum _CameraPositionSelectionKind { layoutPreset, snappedManualCenter }

enum _CameraPositionLabel {
  topLeft,
  topCenter,
  topRight,
  centerLeft,
  centerRight,
  bottomLeft,
  bottomCenter,
  bottomRight,
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
  static const double _selectionEpsilon = 0.035;
  static const List<_CameraPositionPreset> _presets = [
    _CameraPositionPreset(
      kind: _CameraPositionSelectionKind.layoutPreset,
      label: _CameraPositionLabel.topLeft,
      preset: CameraLayoutPreset.overlayTopLeft,
      normalizedPosition: Offset(_presetInsetX, _presetInsetY),
    ),
    _CameraPositionPreset(
      kind: _CameraPositionSelectionKind.snappedManualCenter,
      label: _CameraPositionLabel.topCenter,
      normalizedPosition: Offset(0.5, _presetInsetY),
    ),
    _CameraPositionPreset(
      kind: _CameraPositionSelectionKind.layoutPreset,
      label: _CameraPositionLabel.topRight,
      preset: CameraLayoutPreset.overlayTopRight,
      normalizedPosition: Offset(1 - _presetInsetX, _presetInsetY),
    ),
    _CameraPositionPreset(
      kind: _CameraPositionSelectionKind.snappedManualCenter,
      label: _CameraPositionLabel.centerLeft,
      normalizedPosition: Offset(_presetInsetX, 0.5),
    ),
    _CameraPositionPreset(
      kind: _CameraPositionSelectionKind.snappedManualCenter,
      label: _CameraPositionLabel.centerRight,
      normalizedPosition: Offset(1 - _presetInsetX, 0.5),
    ),
    _CameraPositionPreset(
      kind: _CameraPositionSelectionKind.layoutPreset,
      label: _CameraPositionLabel.bottomLeft,
      preset: CameraLayoutPreset.overlayBottomLeft,
      normalizedPosition: Offset(_presetInsetX, _presetBottomInsetY),
    ),
    _CameraPositionPreset(
      kind: _CameraPositionSelectionKind.snappedManualCenter,
      label: _CameraPositionLabel.bottomCenter,
      normalizedPosition: Offset(0.5, _presetBottomInsetY),
    ),
    _CameraPositionPreset(
      kind: _CameraPositionSelectionKind.layoutPreset,
      label: _CameraPositionLabel.bottomRight,
      preset: CameraLayoutPreset.overlayBottomRight,
      normalizedPosition: Offset(1 - _presetInsetX, _presetBottomInsetY),
    ),
  ];

  final GlobalKey _panelKey = GlobalKey();
  Offset? _dragNormalizedCenter;

  Offset get _resolvedHandlePosition {
    final normalizedCenter = widget.camera.normalizedCanvasCenter;
    if (normalizedCenter != null) {
      return Offset(
        normalizedCenter.dx.clamp(0.0, 1.0),
        (1.0 - normalizedCenter.dy).clamp(0.0, 1.0),
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
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary;
    final surfaceColor = theme.colorScheme.surfaceContainerHighest.withValues(
      alpha: 0.72,
    );
    final handlePosition = _dragNormalizedCenter ?? _resolvedHandlePosition;
    final metrics = context.shellMetricsOrNull;
    final controlMinWidth =
        metrics?.sidebarControlMinWidth ?? AppSidebarTokens.controlMinWidth;

    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: controlMinWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_showsBackgroundBehindHint)
            Padding(
              padding: const EdgeInsets.only(
                bottom: AppSidebarTokens.sectionGap,
              ),
              child: Text(
                l10n.cameraBackgroundBehindHint,
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
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final center = _positionToPanelOffset(
      preset.normalizedPosition,
      width: width,
      height: height,
      itemSize: _presetDotSize,
    );
    final isSelected = _isPresetSelected(preset);

    return Positioned(
      left: center.dx - (_presetTapTargetSize / 2),
      top: center.dy - (_presetTapTargetSize / 2),
      child: Semantics(
        button: true,
        label:
            '${l10n.camera} ${l10n.position}: ${_positionLabel(l10n, preset.label)}',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: ValueKey('camera_position_preset_${preset.label.name}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => _handlePresetTap(preset),
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

  void _handlePresetTap(_CameraPositionPreset preset) {
    if (preset.kind == _CameraPositionSelectionKind.layoutPreset) {
      setState(() {
        _dragNormalizedCenter = null;
      });
      widget.onPresetSelected(preset.preset!);
      return;
    }

    final snappedCenter = preset.normalizedPosition;

    setState(() {
      _dragNormalizedCenter = snappedCenter;
    });

    widget.onManualCenterSnapped(snappedCenter);
  }

  bool _isPresetSelected(_CameraPositionPreset preset) {
    if (preset.kind == _CameraPositionSelectionKind.layoutPreset) {
      return widget.camera.normalizedCanvasCenter == null &&
          widget.camera.layoutPreset == preset.preset;
    }

    if (widget.camera.normalizedCanvasCenter == null) {
      return false;
    }

    final handlePosition = _resolvedHandlePosition;
    return (handlePosition.dx - preset.normalizedPosition.dx).abs() <=
            _selectionEpsilon &&
        (handlePosition.dy - preset.normalizedPosition.dy).abs() <=
            _selectionEpsilon;
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
      if (item.kind == _CameraPositionSelectionKind.layoutPreset &&
          item.preset == preset) {
        return item.normalizedPosition;
      }
    }

    return null;
  }

  String _positionLabel(AppLocalizations l10n, _CameraPositionLabel label) {
    switch (label) {
      case _CameraPositionLabel.topLeft:
        return l10n.topLeft;
      case _CameraPositionLabel.topCenter:
        return l10n.topCenter;
      case _CameraPositionLabel.topRight:
        return l10n.topRight;
      case _CameraPositionLabel.centerLeft:
        return l10n.centerLeft;
      case _CameraPositionLabel.centerRight:
        return l10n.centerRight;
      case _CameraPositionLabel.bottomLeft:
        return l10n.bottomLeft;
      case _CameraPositionLabel.bottomCenter:
        return l10n.bottomCenter;
      case _CameraPositionLabel.bottomRight:
        return l10n.bottomRight;
    }
  }
}

class _CameraPositionPreset {
  const _CameraPositionPreset({
    required this.kind,
    required this.label,
    required this.normalizedPosition,
    this.preset,
  });

  final _CameraPositionSelectionKind kind;
  final _CameraPositionLabel label;
  final CameraLayoutPreset? preset;
  final Offset normalizedPosition;
}
