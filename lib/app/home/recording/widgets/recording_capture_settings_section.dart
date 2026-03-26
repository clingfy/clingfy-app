import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:flutter/material.dart';

class RecordingCaptureSettingsSection extends StatelessWidget {
  const RecordingCaptureSettingsSection({
    super.key,
    required this.isRecording,
    required this.excludeRecorderAppFromCapture,
    required this.onExcludeRecorderAppFromCaptureChanged,
  });

  final bool isRecording;
  final bool excludeRecorderAppFromCapture;
  final ValueChanged<bool> onExcludeRecorderAppFromCaptureChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AppToggleRow(
      title: l10n.excludeRecorderAppFromCapture,
      // subtitle: l10n.excludeRecorderAppFromCaptureDescription,
      value: excludeRecorderAppFromCapture,
      onChanged: isRecording ? null : onExcludeRecorderAppFromCaptureChanged,
    );
  }
}
