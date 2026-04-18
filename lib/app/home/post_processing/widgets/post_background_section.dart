import 'dart:io';

import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_dialog.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

class PostBackgroundSection extends StatelessWidget {
  const PostBackgroundSection({
    super.key,
    required this.isProcessing,
    required this.backgroundColor,
    required this.backgroundImagePath,
    required this.onBackgroundColorChanged,
    required this.onBackgroundImageChanged,
    required this.onPickImage,
  });

  final bool isProcessing;
  final int? backgroundColor;
  final String? backgroundImagePath;
  final ValueChanged<int?> onBackgroundColorChanged;
  final ValueChanged<String?> onBackgroundImageChanged;
  final Future<String?> Function() onPickImage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final subsectionStyle = AppSidebarTokens.rowTitleStyle(theme);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSettingsGroup(
          title: l10n.background,
          showHeader: false,
          children: [
            Text(l10n.backgroundImage, style: subsectionStyle),
            const SizedBox(height: AppSidebarTokens.rowGap),
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
            const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
            Text(l10n.backgroundColor, style: subsectionStyle),
            const SizedBox(height: AppSidebarTokens.rowGap),
            Wrap(
              spacing: AppSidebarTokens.rowGap,
              runSpacing: AppSidebarTokens.rowGap,
              children: [
                _ColorCircle(
                  colorValue: null,
                  isSelected:
                      backgroundColor == null && backgroundImagePath == null,
                  onTap: onBackgroundColorChanged,
                ),
                _ColorCircle(
                  colorValue: 0xFFF44336,
                  isSelected: backgroundColor == 0xFFF44336,
                  onTap: onBackgroundColorChanged,
                ),
                _ColorCircle(
                  colorValue: 0xFF8957E5,
                  isSelected: backgroundColor == 0xFF8957E5,
                  onTap: onBackgroundColorChanged,
                ),
                _ColorCircle(
                  colorValue: 0xFF4CAF50,
                  isSelected: backgroundColor == 0xFF4CAF50,
                  onTap: onBackgroundColorChanged,
                ),
                _ColorCircle(
                  colorValue: 0xFFFFC107,
                  isSelected: backgroundColor == 0xFFFFC107,
                  onTap: onBackgroundColorChanged,
                ),
                _ColorCircle(
                  colorValue: 0xFF9C27B0,
                  isSelected: backgroundColor == 0xFF9C27B0,
                  onTap: onBackgroundColorChanged,
                ),
                _ColorCircle(
                  colorValue: 0xFFFFFFFF,
                  isSelected: backgroundColor == 0xFFFFFFFF,
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
          ],
        ),
      ],
    );
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
