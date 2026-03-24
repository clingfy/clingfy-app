import 'package:clingfy/app/config/build_config.dart';
import 'package:clingfy/core/permissions/models/recording_start_preflight.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_dialog.dart';
import 'package:flutter/material.dart';

enum StartRecordingStorageDecision {
  openStorageSettings,
  recordAnyway,
  bypassAndRecord,
  cancel,
}

class StartRecordingStorageDialog {
  static Future<StartRecordingStorageDecision?> show(
    BuildContext context, {
    required RecordingStoragePreflight storage,
    bool? showLowStorageBypass,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final isBlocking = storage.isBlocking;
    final shouldShowLowStorageBypass =
        isBlocking && (showLowStorageBypass ?? BuildConfig.isDev());

    return AppDialog.show<StartRecordingStorageDecision>(
      context,
      title: l10n.storagePreflightTitle,
      barrierDismissible: false,
      showCloseButton: true,
      closeResult: StartRecordingStorageDecision.cancel,
      closeButtonKey: const Key('storage_dialog_close'),
      primaryLabel: isBlocking ? l10n.openStorageSettings : l10n.recordAnyway,
      secondaryLabel: isBlocking ? null : l10n.openStorageSettings,
      primaryResult: isBlocking
          ? StartRecordingStorageDecision.openStorageSettings
          : StartRecordingStorageDecision.recordAnyway,
      secondaryResult: StartRecordingStorageDecision.openStorageSettings,
      content: Builder(
        builder: (dialogContext) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              Text(
                isBlocking
                    ? l10n.storagePreflightCriticalIntro
                    : l10n.storagePreflightWarningIntro,
              ),
              const SizedBox(height: 12),
              const SizedBox(height: 12),
              _StorageBullet(
                label: l10n.storageAvailableNow,
                value: _formatBytes(storage.availableBytes),
              ),
              const SizedBox(height: 6),
              _StorageBullet(
                label: l10n.storageRecordingBlockedBelow,
                value: _formatBytes(storage.criticalThresholdBytes),
              ),
              const SizedBox(height: 6),
              _StorageBullet(
                label: l10n.storageRecommendedFreeSpace,
                value: _formatBytes(storage.warningThresholdBytes),
              ),
              if (shouldShowLowStorageBypass) ...[
                const SizedBox(height: 12),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: AppButton(
                        expand: true,
                        onPressed: () {
                          Navigator.of(
                            dialogContext,
                          ).pop(StartRecordingStorageDecision.bypassAndRecord);
                        },
                        label: l10n.storageBypassAndRecord,
                        variant: AppButtonVariant.secondary,
                        size: AppButtonSize.compact,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 6),
            ],
          );
        },
      ),
    );
  }
}

class _StorageBullet extends StatelessWidget {
  const _StorageBullet({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('• '),
        Expanded(child: Text('$label: $value', textAlign: TextAlign.start)),
      ],
    );
  }
}

String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = 0;

  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }

  final precision = value >= 100 || unitIndex == 0 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unitIndex]}';
}
