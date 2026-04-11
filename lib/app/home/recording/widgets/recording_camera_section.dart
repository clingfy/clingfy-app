import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/platform/widgets/app_inset_group.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
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
    this.guideAnchorKey,
  });

  final bool isRecording;
  final List<CamSource> cams;
  final String? selectedCamId;
  final bool loadingCams;
  final VoidCallback onRefreshCams;
  final ValueChanged<String?> onCamSourceChanged;
  final Key? guideAnchorKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final helperStyle = AppSidebarTokens.helperStyle(theme);

    final validCamId =
        selectedCamId == null || cams.any((cam) => cam.id == selectedCamId)
        ? selectedCamId
        : null;

    return AppSettingsGroup(
      anchorKey: guideAnchorKey,
      sectionKey: const Key('recording_camera_group'),
      title: l10n.camera,
      trailing: AppIconButton(
        tooltip: l10n.refreshCameras,
        onPressed: (loadingCams || isRecording) ? null : onRefreshCams,
        icon: Icons.refresh,
      ),
      children: [
        if (loadingCams)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          AppFormRow(
            label: l10n.cameraDevice,
            control: PlatformDropdown<String>(
              value: validCamId,
              minWidth: 0,
              maxWidth: double.infinity,
              expand: true,
              items: cams
                  .map(
                    (cam) => PlatformMenuItem(value: cam.id, label: cam.name),
                  )
                  .toList(),
              onChanged: isRecording ? null : onCamSourceChanged,
            ),
          ),
        if (!loadingCams && validCamId == null) ...[
          const SizedBox(height: AppSidebarTokens.optionsSubgroupGap),
          AppInsetGroup(
            children: [
              Center(
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
          ),
        ],
      ],
    );
  }
}
