import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_dialog.dart';
import 'package:clingfy/ui/platform/widgets/platform_checkbox.dart';
import 'package:flutter/material.dart';

class CloseUnexportedRecordingDialogResult {
  const CloseUnexportedRecordingDialogResult({
    required this.shouldCloseWithoutExporting,
    required this.doNotShowAgain,
  });

  final bool shouldCloseWithoutExporting;
  final bool doNotShowAgain;
}

class CloseUnexportedRecordingDialog {
  static Future<CloseUnexportedRecordingDialogResult?> show(
    BuildContext context,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    var doNotShowAgain = false;

    return AppDialog.show<CloseUnexportedRecordingDialogResult>(
      context,
      title: l10n.closeUnexportedRecordingTitle,
      barrierDismissible: false,
      primaryLabel: l10n.keepEditing,
      primaryBuilder: () => CloseUnexportedRecordingDialogResult(
        shouldCloseWithoutExporting: false,
        doNotShowAgain: doNotShowAgain,
      ),
      secondaryLabel: l10n.closeWithoutExporting,
      secondaryBuilder: () => CloseUnexportedRecordingDialogResult(
        shouldCloseWithoutExporting: true,
        doNotShowAgain: doNotShowAgain,
      ),
      content: StatefulBuilder(
        builder: (context, setState) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.closeUnexportedRecordingMessage),
              const SizedBox(height: 16),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () {
                    setState(() => doNotShowAgain = !doNotShowAgain);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PlatformCheckbox(
                          value: doNotShowAgain,
                          onChanged: (value) {
                            setState(() => doNotShowAgain = value ?? false);
                          },
                        ),
                        const SizedBox(width: 8),
                        Flexible(child: Text(l10n.doNotShowAgain)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

Future<bool> confirmCloseUnexportedRecordingIfNeeded(
  BuildContext context, {
  required bool warningEnabled,
  required bool hasExportedCurrentRecording,
  required Future<void> Function() disableFutureWarnings,
}) async {
  if (!warningEnabled || hasExportedCurrentRecording) {
    return true;
  }

  final result = await CloseUnexportedRecordingDialog.show(context);
  if (result == null || !result.shouldCloseWithoutExporting) {
    return false;
  }

  if (result.doNotShowAgain) {
    await disableFutureWarnings();
  }
  return true;
}
