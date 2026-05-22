import 'dart:io';
import 'dart:math' as math;

import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/models/background_preset_catalog.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_dialog.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_segmented.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_slider.dart';
import 'package:clingfy/ui/platform/widgets/app_slider_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

/// Localized display name for a procedural preset id.
String _presetDisplayName(AppLocalizations l10n, String presetId) {
  switch (presetId) {
    case 'abstractWaves':
      return l10n.presetAbstractWaves;
    default:
      return presetId;
  }
}

class PostBackgroundSection extends StatelessWidget {
  const PostBackgroundSection({
    super.key,
    required this.isProcessing,
    required this.backgroundColor,
    required this.backgroundImagePath,
    required this.backgroundKind,
    required this.backgroundPreset,
    required this.onBackgroundColorChanged,
    required this.onBackgroundImageChanged,
    required this.onBackgroundKindChanged,
    required this.onBackgroundPresetChanged,
    required this.onBackgroundPresetPreview,
    required this.onPickImage,
  });

  final bool isProcessing;
  final int? backgroundColor;
  final String? backgroundImagePath;
  final BackgroundKind backgroundKind;
  final CanvasBackgroundPreset? backgroundPreset;
  final ValueChanged<int?> onBackgroundColorChanged;
  final ValueChanged<String?> onBackgroundImageChanged;
  final ValueChanged<BackgroundKind> onBackgroundKindChanged;

  /// Commit a preset change (palette / card / randomize / slider release).
  final ValueChanged<CanvasBackgroundPreset> onBackgroundPresetChanged;

  /// Live, UI-only preset update while a slider is being dragged.
  final ValueChanged<CanvasBackgroundPreset> onBackgroundPresetPreview;

  final Future<String?> Function() onPickImage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSettingsGroup(
          title: l10n.background,
          showHeader: false,
          children: [
            AppSegmented<BackgroundKind>(
              value: backgroundKind,
              onChanged: isProcessing ? null : onBackgroundKindChanged,
              compact: true,
              items: [
                AppSegmentedItem(
                  value: BackgroundKind.color,
                  label: l10n.backgroundModeColor,
                  icon: Icons.format_color_fill_outlined,
                ),
                AppSegmentedItem(
                  value: BackgroundKind.image,
                  label: l10n.backgroundModeImage,
                  icon: Icons.image_outlined,
                ),
                AppSegmentedItem(
                  value: BackgroundKind.preset,
                  label: l10n.backgroundModePreset,
                  icon: Icons.auto_awesome_outlined,
                ),
              ],
            ),
            const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
            ..._modeChildren(context, l10n),
          ],
        ),
      ],
    );
  }

  List<Widget> _modeChildren(BuildContext context, AppLocalizations l10n) {
    switch (backgroundKind) {
      case BackgroundKind.color:
        return _colorChildren(context, l10n);
      case BackgroundKind.image:
        return _imageChildren(l10n);
      case BackgroundKind.preset:
        return [
          _PresetControls(
            isProcessing: isProcessing,
            preset: backgroundPreset ?? BackgroundPresetCatalog.defaultPreset(),
            onChanged: onBackgroundPresetChanged,
            onPreview: onBackgroundPresetPreview,
          ),
        ];
    }
  }

  List<Widget> _colorChildren(BuildContext context, AppLocalizations l10n) {
    const presetColors = [
      null,
      0xFFF44336,
      0xFF8957E5,
      0xFF4CAF50,
      0xFFFFC107,
      0xFF9C27B0,
      0xFFFFFFFF,
    ];
    return [
      Wrap(
        spacing: AppSidebarTokens.rowGap,
        runSpacing: AppSidebarTokens.rowGap,
        children: [
          for (final value in presetColors)
            _ColorCircle(
              colorValue: value,
              isSelected: backgroundColor == value,
              onTap: onBackgroundColorChanged,
            ),
        ],
      ),
      const SizedBox(height: AppSidebarTokens.rowGap),
      AppButton(
        label: l10n.moreColors,
        icon: Icons.palette_outlined,
        variant: AppButtonVariant.secondary,
        size: AppButtonSize.regular,
        expand: true,
        onPressed: isProcessing
            ? null
            : () => _openColorPickerDialog(
                context,
                title: l10n.pickColor,
                initialColor: backgroundColor ?? 0xFFFFFFFF,
                onPicked: onBackgroundColorChanged,
              ),
      ),
    ];
  }

  List<Widget> _imageChildren(AppLocalizations l10n) {
    return [
      if (backgroundImagePath != null) ...[
        _ImagePreviewRow(
          backgroundImagePath: backgroundImagePath!,
          onClear: () => onBackgroundImageChanged(null),
        ),
        const SizedBox(height: AppSidebarTokens.rowGap),
      ],
      AppButton(
        label: l10n.pickAnImage,
        icon: Icons.image_outlined,
        variant: AppButtonVariant.secondary,
        size: AppButtonSize.regular,
        expand: true,
        onPressed: isProcessing
            ? null
            : () async {
                final path = await onPickImage();
                if (path != null) {
                  onBackgroundImageChanged(path);
                }
              },
      ),
    ];
  }

  static Future<void> _openColorPickerDialog(
    BuildContext context, {
    required String title,
    required int initialColor,
    required ValueChanged<int?> onPicked,
  }) async {
    Color pickerColor = Color(initialColor);
    final l10n = AppLocalizations.of(context)!;

    final picked = await AppDialog.show<int>(
      context,
      title: title,
      maxWidth: 360,
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
      primaryLabel: l10n.gotIt,
      secondaryLabel: l10n.cancel,
      primaryBuilder: () => pickerColor.toARGB32(),
      secondaryResult: -1,
      barrierDismissible: true,
    );

    if (picked == null || picked == -1) return;
    onPicked(picked);
  }
}

/// Preset-mode controls: preset cards, palette swatches, intensity /
/// softness sliders, and a Randomize button.
class _PresetControls extends StatelessWidget {
  const _PresetControls({
    required this.isProcessing,
    required this.preset,
    required this.onChanged,
    required this.onPreview,
  });

  final bool isProcessing;
  final CanvasBackgroundPreset preset;
  final ValueChanged<CanvasBackgroundPreset> onChanged;
  final ValueChanged<CanvasBackgroundPreset> onPreview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final subsectionStyle = AppSidebarTokens.rowTitleStyle(theme);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSidebarTokens.rowGap,
          runSpacing: AppSidebarTokens.rowGap,
          children: [
            for (final presetId in BackgroundPresetCatalog.presetIds)
              _PresetCard(
                label: _presetDisplayName(l10n, presetId),
                paletteColors: BackgroundPresetCatalog.palette(
                  preset.palette,
                ).colors,
                isSelected: preset.id == presetId,
                onTap: isProcessing
                    ? null
                    : () => onChanged(preset.copyWith(id: presetId)),
              ),
          ],
        ),
        const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
        Text(l10n.backgroundPalette, style: subsectionStyle),
        const SizedBox(height: AppSidebarTokens.rowGap),
        Wrap(
          spacing: AppSidebarTokens.rowGap,
          runSpacing: AppSidebarTokens.rowGap,
          children: [
            for (final palette in BackgroundPresetCatalog.palettes)
              _PaletteSwatch(
                colors: palette.colors,
                isSelected: preset.palette == palette.id,
                onTap: isProcessing
                    ? null
                    : () => onChanged(preset.copyWith(palette: palette.id)),
              ),
          ],
        ),
        const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
        AppSliderRow(
          label: l10n.backgroundIntensity,
          valueText: '${(preset.intensity * 100).round()}%',
          slider: AppSlider(
            value: preset.intensity.clamp(0.0, 1.0),
            min: 0.0,
            max: 1.0,
            divisions: 20,
            valueLabel: '${(preset.intensity * 100).round()}%',
            semanticLabel: l10n.backgroundIntensity,
            onChanged: isProcessing
                ? null
                : (v) => onPreview(preset.copyWith(intensity: v)),
            onChangeEnd: (v) => onChanged(preset.copyWith(intensity: v)),
          ),
        ),
        const SizedBox(height: AppSidebarTokens.rowGap),
        AppSliderRow(
          label: l10n.backgroundSoftness,
          valueText: '${(preset.blur * 100).round()}%',
          slider: AppSlider(
            value: preset.blur.clamp(0.0, 1.0),
            min: 0.0,
            max: 1.0,
            divisions: 20,
            valueLabel: '${(preset.blur * 100).round()}%',
            semanticLabel: l10n.backgroundSoftness,
            onChanged: isProcessing
                ? null
                : (v) => onPreview(preset.copyWith(blur: v)),
            onChangeEnd: (v) => onChanged(preset.copyWith(blur: v)),
          ),
        ),
        const SizedBox(height: AppSidebarTokens.rowGap),
        AppButton(
          label: l10n.randomize,
          icon: Icons.casino_outlined,
          variant: AppButtonVariant.secondary,
          size: AppButtonSize.regular,
          expand: true,
          onPressed: isProcessing
              ? null
              : () => onChanged(
                  preset.copyWith(seed: math.Random().nextInt(1 << 31)),
                ),
        ),
      ],
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.label,
    required this.paletteColors,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final List<int> paletteColors;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final helperStyle = AppSidebarTokens.helperStyle(Theme.of(context));

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [for (final c in paletteColors) Color(c)],
              ),
              border: Border.all(
                color: isSelected ? colorScheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: helperStyle),
        ],
      ),
    );
  }
}

class _PaletteSwatch extends StatelessWidget {
  const _PaletteSwatch({
    required this.colors,
    required this.isSelected,
    required this.onTap,
  });

  final List<int> colors;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [for (final c in colors) Color(c)],
          ),
          border: Border.all(
            color: isSelected ? colorScheme.onSurface : Colors.transparent,
            width: 2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: colorScheme.primary.withValues(alpha: 0.45),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
      ),
    );
  }
}

class _ImagePreviewRow extends StatelessWidget {
  const _ImagePreviewRow({
    required this.backgroundImagePath,
    required this.onClear,
  });

  final String backgroundImagePath;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final helperStyle = AppSidebarTokens.helperStyle(Theme.of(context));
    final accentColor = Theme.of(context).colorScheme.primary;

    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: accentColor.withValues(alpha: 0.6)),
            image: DecorationImage(
              image: FileImage(File(backgroundImagePath)),
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(width: AppSidebarTokens.rowGap),
        Expanded(
          child: Text(
            backgroundImagePath.split('/').last,
            overflow: TextOverflow.ellipsis,
            style: helperStyle,
          ),
        ),
        AppIconButton(
          tooltip: l10n.clearArea,
          onPressed: onClear,
          icon: Icons.close,
        ),
      ],
    );
  }
}

class _ColorCircle extends StatelessWidget {
  const _ColorCircle({
    required this.colorValue,
    required this.isSelected,
    required this.onTap,
  });

  final int? colorValue;
  final bool isSelected;
  final ValueChanged<int?> onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final ring = colorScheme.onSurface;

    return GestureDetector(
      onTap: () => onTap(colorValue),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: colorValue != null
              ? Color(colorValue!)
              : colorScheme.surfaceContainerHighest,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? ring : Colors.transparent,
            width: 2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: colorScheme.primary.withValues(alpha: 0.45),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: colorValue == null
            ? Icon(Icons.block, color: colorScheme.onSurfaceVariant, size: 16)
            : null,
      ),
    );
  }
}
