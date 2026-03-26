import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_section.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:flutter/material.dart' hide PlatformMenuItem;

class RecordingCameraSection extends StatelessWidget {
  const RecordingCameraSection({
    super.key,
    required this.isRecording,
    required this.cams,
    required this.selectedCamId,
    required this.loadingCams,
    required this.onRefreshCams,
    required this.onCamSourceChanged,
  });

  final bool isRecording;
  final List<CamSource> cams;
  final String? selectedCamId;
  final bool loadingCams;
  final VoidCallback onRefreshCams;
  final ValueChanged<String?> onCamSourceChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final helperStyle = AppSidebarTokens.helperStyle(theme);

    final validCamId =
        selectedCamId == null || cams.any((cam) => cam.id == selectedCamId)
        ? selectedCamId
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSection(
          title: l10n.camera,
          titleSpacing: AppSidebarTokens.dropdownSectionTitleGap,
          trailing: AppIconButton(
            tooltip: l10n.refreshCameras,
            onPressed: (loadingCams || isRecording) ? null : onRefreshCams,
            icon: Icons.refresh,
          ),
          child: loadingCams
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                )
              : AppFormRow(
                  label: l10n.cameraDevice,
                  control: PlatformDropdown<String>(
                    value: validCamId,
                    items: cams
                        .map(
                          (cam) =>
                              PlatformMenuItem(value: cam.id, label: cam.name),
                        )
                        .toList(),
                    onChanged: isRecording ? null : onCamSourceChanged,
                  ),
                ),
        ),
        const SizedBox(height: AppSidebarTokens.railItemVerticalPadding),
        if (selectedCamId == null)
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: AppSidebarTokens.sectionGap,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.videocam_off_outlined,
                  size: 48,
                  color: theme.disabledColor,
                ),
                const SizedBox(height: AppSidebarTokens.rowGap),
                Text(
                  l10n.selectCameraHint,
                  textAlign: TextAlign.center,
                  style: helperStyle,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
