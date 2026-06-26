import 'dart:async';
import 'dart:io' show Platform;

import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/settings/controllers/workspace_settings_controller.dart';
import 'package:clingfy/app/settings/sections/section_helpers.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

class DiagnosticsSettingsSection extends StatefulWidget {
  const DiagnosticsSettingsSection({super.key, required this.controller});

  final SettingsController controller;

  @override
  State<DiagnosticsSettingsSection> createState() =>
      _DiagnosticsSettingsSectionState();
}

class _DiagnosticsSettingsSectionState
    extends State<DiagnosticsSettingsSection> {
  String? _noticeText;
  AppInlineNoticeVariant _noticeVariant = AppInlineNoticeVariant.info;

  /// Phase 10.4: the crash-test button only exists on Windows AND when the
  /// tester explicitly opted in via CLINGFY_CRASH_TEST=1 — the same env var
  /// native checks before actually crashing the process.
  bool get _showForceCrashButton =>
      isWindows() && Platform.environment['CLINGFY_CRASH_TEST'] == '1';

  void _setNotice(String message, AppInlineNoticeVariant variant) {
    setState(() {
      _noticeText = message;
      _noticeVariant = variant;
    });
  }

  String _messageForError(AppLocalizations l10n, Object error) {
    final raw = error is StateError ? error.message : error.toString();
    switch (raw) {
      case WorkspaceSettingsController.logFileNotFoundErrorCode:
        return l10n.diagnosticsLogFileNotFound;
      case WorkspaceSettingsController.logFileUnavailableErrorCode:
        return l10n.diagnosticsLogFileUnavailable;
      default:
        return l10n.diagnosticsActionFailed;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return buildSectionPage(
      context,
      children: [
        SettingsCard(
          title: l10n.diagnosticsTitle,
          infoTooltip: l10n.diagnosticsHelpText,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_noticeText != null) ...[
                AppInlineNotice(message: _noticeText!, variant: _noticeVariant),
                const SizedBox(height: 12),
              ],
              ListenableBuilder(
                listenable: widget.controller.workspace,
                builder: (context, _) => AppToggleRow(
                  key: const Key('diagnostics_verbose_logging_toggle'),
                  title: l10n.diagnosticsVerboseLogging,
                  helperText: l10n.diagnosticsVerboseLoggingHelp,
                  value: widget.controller.workspace.verboseLogging,
                  onChanged: (value) => unawaited(
                    widget.controller.workspace.setVerboseLogging(value),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  AppButton(
                    label: l10n.openLogsFolder,
                    icon: CupertinoIcons.folder,
                    onPressed: widget.controller.workspace.revealLogsFolder,
                  ),
                  AppButton(
                    label: l10n.revealTodayLog,
                    icon: CupertinoIcons.doc_text,
                    variant: AppButtonVariant.secondary,
                    onPressed: () async {
                      try {
                        await widget.controller.workspace.revealTodayLogFile();
                        _setNotice(
                          l10n.diagnosticsLogRevealed,
                          AppInlineNoticeVariant.success,
                        );
                      } catch (e) {
                        _setNotice(
                          _messageForError(l10n, e),
                          AppInlineNoticeVariant.error,
                        );
                      }
                    },
                  ),
                  AppButton(
                    label: l10n.copyLogPath,
                    icon: CupertinoIcons.doc_on_clipboard,
                    variant: AppButtonVariant.secondary,
                    onPressed: () async {
                      try {
                        await widget.controller.workspace
                            .copyTodayLogFilePathToClipboard();
                        _setNotice(
                          l10n.recordingPathCopied,
                          AppInlineNoticeVariant.success,
                        );
                      } catch (e) {
                        _setNotice(
                          _messageForError(l10n, e),
                          AppInlineNoticeVariant.error,
                        );
                      }
                    },
                  ),
                  AppButton(
                    label: l10n.exportDiagnostics,
                    icon: CupertinoIcons.archivebox,
                    variant: AppButtonVariant.secondary,
                    onPressed: () async {
                      final path = await widget.controller.workspace
                          .exportDiagnosticsPackage();
                      if (!mounted) return;
                      _setNotice(
                        path != null
                            ? l10n.diagnosticsExported
                            : l10n.diagnosticsActionFailed,
                        path != null
                            ? AppInlineNoticeVariant.success
                            : AppInlineNoticeVariant.error,
                      );
                    },
                  ),
                  if (_showForceCrashButton)
                    AppButton(
                      label: l10n.forceNativeCrashLabel,
                      icon: CupertinoIcons.exclamationmark_triangle,
                      variant: AppButtonVariant.secondary,
                      onPressed: () {
                        NativeBridge.instance.debugForceNativeCrash();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
