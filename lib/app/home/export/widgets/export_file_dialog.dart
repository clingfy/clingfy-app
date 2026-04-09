import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart' hide PlatformMenuItem;

import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/export/models/export_settings_types.dart';
import 'package:clingfy/ui/platform/widgets/resolution_preset_menu_items.dart';

class ExportFileDialogResult {
  const ExportFileDialogResult({
    required this.fileName,
    required this.directoryOverride,
    required this.resolutionPreset,
    required this.exportFormat,
    required this.exportCodec,
    required this.exportBitrate,
  });

  final String fileName;
  final String? directoryOverride;
  final ResolutionPreset resolutionPreset;
  final ExportFormat exportFormat;
  final ExportCodec exportCodec;
  final ExportBitratePreset exportBitrate;
}

class ExportFileDialog extends StatefulWidget {
  const ExportFileDialog({
    super.key,
    required this.initialFileName,
    required this.initialDirectory,
    required this.initialResolutionPreset,
    required this.initialExportFormat,
    required this.initialExportCodec,
    required this.initialExportBitrate,
    required this.onPickFolder,
  });

  final String initialFileName;
  final String initialDirectory;
  final ResolutionPreset initialResolutionPreset;
  final ExportFormat initialExportFormat;
  final ExportCodec initialExportCodec;
  final ExportBitratePreset initialExportBitrate;
  final Future<String?> Function() onPickFolder;

  static Future<ExportFileDialogResult?> show(
    BuildContext context, {
    required String initialFileName,
    required String initialDirectory,
    required ResolutionPreset initialResolutionPreset,
    required ExportFormat initialExportFormat,
    required ExportCodec initialExportCodec,
    required ExportBitratePreset initialExportBitrate,
    required Future<String?> Function() onPickFolder,
  }) {
    return showDialog<ExportFileDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ExportFileDialog(
        initialFileName: initialFileName,
        initialDirectory: initialDirectory,
        initialResolutionPreset: initialResolutionPreset,
        initialExportFormat: initialExportFormat,
        initialExportCodec: initialExportCodec,
        initialExportBitrate: initialExportBitrate,
        onPickFolder: onPickFolder,
      ),
    );
  }

  @override
  State<ExportFileDialog> createState() => _ExportFileDialogState();
}

class _ExportFileDialogState extends State<ExportFileDialog> {
  static const _closeButtonKey = Key('export_file_dialog_close_button');

  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialFileName,
  );

  String? _directoryOverride;
  late ResolutionPreset _resolutionPreset = widget.initialResolutionPreset;
  late ExportFormat _exportFormat = widget.initialExportFormat;
  late ExportCodec _exportCodec = widget.initialExportCodec;
  late ExportBitratePreset _exportBitrate = widget.initialExportBitrate;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final picked = await widget.onPickFolder();
    if (!mounted || picked == null || picked.isEmpty) return;
    setState(() {
      _directoryOverride = picked;
    });
  }

  void _submit() {
    final trimmed = _nameController.text.trim();
    if (trimmed.isEmpty) return;
    Navigator.of(context).pop(
      ExportFileDialogResult(
        fileName: trimmed,
        directoryOverride: _directoryOverride,
        resolutionPreset: _resolutionPreset,
        exportFormat: _exportFormat,
        exportCodec: _exportCodec,
        exportBitrate: _exportBitrate,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final location = _directoryOverride ?? widget.initialDirectory;
    final supportsVideoEncoding = _exportFormat != ExportFormat.gif;

    return Dialog(
      insetPadding: EdgeInsets.all(spacing.dialog),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            spacing.dialog,
            spacing.panel + 2,
            spacing.dialog,
            spacing.panel,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(l10n.exportVideo, style: typography.pageTitle),
                  ),
                  SizedBox(width: spacing.md),
                  AppIconButton(
                    key: _closeButtonKey,
                    tooltip: l10n.cancel,
                    icon: CupertinoIcons.xmark,
                    onPressed: () => Navigator.of(context).pop(),
                    size: 16,
                  ),
                ],
              ),
              SizedBox(height: spacing.xxl),

              // ── Filename + format picker ──
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameController,
                      autofocus: true,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: l10n.filename,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: spacing.md),
                  SizedBox(
                    width: 100,
                    child: PlatformDropdown<ExportFormat>(
                      value: _exportFormat,
                      items: const [
                        PlatformMenuItem(
                          value: ExportFormat.mov,
                          label: '.mov',
                        ),
                        PlatformMenuItem(
                          value: ExportFormat.gif,
                          label: '.gif',
                        ),
                        PlatformMenuItem(
                          value: ExportFormat.mp4,
                          label: '.mp4',
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _exportFormat = v);
                        }
                      },
                    ),
                  ),
                ],
              ),
              SizedBox(height: spacing.panel - 2),

              // ── Resolution / Codec / Bitrate ──
              _SectionLabel(label: l10n.resolution),
              SizedBox(height: spacing.sm),
              PlatformDropdown<ResolutionPreset>(
                value: _resolutionPreset,
                expand: true,
                items: buildResolutionPresetMenuItems(l10n),
                onChanged: (v) {
                  if (v != null) setState(() => _resolutionPreset = v);
                },
              ),

              if (supportsVideoEncoding) ...[
                SizedBox(height: spacing.md),
                _SectionLabel(label: l10n.codec),
                SizedBox(height: spacing.sm),
                PlatformDropdown<ExportCodec>(
                  value: _exportCodec,
                  expand: true,
                  items: [
                    PlatformMenuItem(value: ExportCodec.hevc, label: l10n.hevc),
                    PlatformMenuItem(value: ExportCodec.h264, label: l10n.h264),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _exportCodec = v);
                  },
                ),

                SizedBox(height: spacing.md),
                _SectionLabel(label: l10n.bitrate),
                SizedBox(height: spacing.sm),
                PlatformDropdown<ExportBitratePreset>(
                  value: _exportBitrate,
                  expand: true,
                  items: [
                    PlatformMenuItem(
                      value: ExportBitratePreset.auto,
                      label: l10n.auto,
                    ),
                    PlatformMenuItem(
                      value: ExportBitratePreset.low,
                      label: l10n.low,
                    ),
                    PlatformMenuItem(
                      value: ExportBitratePreset.medium,
                      label: l10n.medium,
                    ),
                    PlatformMenuItem(
                      value: ExportBitratePreset.high,
                      label: l10n.high,
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _exportBitrate = v);
                  },
                ),
              ],

              SizedBox(height: spacing.panel - 2),

              // ── Location ──
              _SectionLabel(label: l10n.locationLabel),
              SizedBox(height: spacing.sm),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: spacing.md,
                        vertical: spacing.sm + 2,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: theme.colorScheme.outline.withValues(
                            alpha: 0.45,
                          ),
                        ),
                        color: theme.colorScheme.surface,
                      ),
                      child: Text(
                        location,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typography.mono,
                      ),
                    ),
                  ),
                  SizedBox(width: spacing.md),
                  AppButton(
                    label: l10n.changeButtonLabel,
                    icon: CupertinoIcons.folder,
                    variant: AppButtonVariant.secondary,
                    size: AppButtonSize.regular,
                    onPressed: _pickFolder,
                  ),
                ],
              ),

              SizedBox(height: spacing.panel + 2),

              // ── Actions ──
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [AppButton(label: l10n.export, onPressed: _submit)],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small reusable section label for the export dialog.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(
        context,
      ).appTypography.button.copyWith(fontWeight: FontWeight.w700),
    );
  }
}
