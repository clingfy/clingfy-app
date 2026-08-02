import 'dart:async';
import 'dart:io' show Platform;

import 'package:clingfy/app/infrastructure/observability/crash_reporting_consent.dart';
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

  // Mirrors CrashReportingConsent, which is static rather than a
  // ChangeNotifier because Sentry reads it before any controller exists.
  bool _crashReportingEnabled = CrashReportingConsent.enabled;

  /// Phase 10.4: the crash-test button only exists on Windows AND when the
  /// tester explicitly opted in via CLINGFY_CRASH_TEST=1 — the same env var
  /// native checks before actually crashing the process.
  bool get _showForceCrashButton =>
      isWindows() && Platform.environment['CLINGFY_CRASH_TEST'] == '1';

  /// Hidden owner affordance: tapping the Diagnostics card [_revealTapTarget] times reveals the
  /// internal/test analytics controls on a shipped RELEASE build where no env var is set (e.g. a
  /// macOS app launched from Finder). Undiscoverable to normal users; the controls simply
  /// appearing is the confirmation. Taps on the toggles/buttons are consumed by them, so only
  /// taps on the card's title/empty area count.
  static const int _revealTapTarget = 7;
  int _revealTapCount = 0;

  void _onDiagnosticsTap() {
    if (widget.controller.workspace.showAnalyticsOwnerControls) return;
    _revealTapCount++;
    if (_revealTapCount >= _revealTapTarget) {
      _revealTapCount = 0;
      widget.controller.workspace.revealAnalyticsOwnerControls();
    }
  }

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
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _onDiagnosticsTap,
          child: SettingsCard(
            title: l10n.diagnosticsTitle,
            infoTooltip: l10n.diagnosticsHelpText,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_noticeText != null) ...[
                  AppInlineNotice(
                    message: _noticeText!,
                    variant: _noticeVariant,
                  ),
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
                ListenableBuilder(
                  listenable: widget.controller.workspace,
                  builder: (context, _) => AppToggleRow(
                    key: const Key('diagnostics_share_analytics_toggle'),
                    title: l10n.diagnosticsShareAnalytics,
                    helperText: l10n.diagnosticsShareAnalyticsHelp,
                    value: widget.controller.workspace.shareUsageAnalytics,
                    onChanged: (value) => unawaited(
                      widget.controller.workspace.setShareUsageAnalytics(value),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // Crash reporting is a SEPARATE consent from usage analytics
                // above: that toggle gates PostHog product analytics only,
                // while Sentry has been running unconditionally whenever a DSN
                // is compiled in. Sits next to it so the two questions a user
                // might have about data leaving their machine are answered in
                // one place.
                AppToggleRow(
                  key: const Key('diagnostics_crash_reporting_toggle'),
                  title: l10n.crashReportingToggle,
                  helperText: l10n.crashReportingDescription,
                  value: _crashReportingEnabled,
                  onChanged: (value) async {
                    setState(() => _crashReportingEnabled = value);
                    await CrashReportingConsent.setEnabled(value);
                  },
                ),
                // Says plainly that "off" is not fully off until restart. The
                // native crash handler is installed at startup and cannot be
                // uninstalled, so claiming otherwise would be a lie the user
                // could not detect.
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  child: Text(
                    l10n.crashReportingRestartNote,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                // Owner/dev-only: mark this install internal (excluded from real numbers) or enter
                // the manual test channel. Hidden from normal users — revealed only in debug builds
                // or when CLINGFY_INTERNAL / CLINGFY_ANALYTICS_TEST is set (mirrors the web
                // ?clingfy_internal / ?clingfy_test device flags).
                ListenableBuilder(
                  listenable: widget.controller.workspace,
                  builder: (context, _) {
                    if (!widget
                        .controller
                        .workspace
                        .showAnalyticsOwnerControls) {
                      return const SizedBox.shrink();
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppToggleRow(
                          key: const Key(
                            'diagnostics_analytics_internal_toggle',
                          ),
                          title: l10n.diagnosticsAnalyticsInternal,
                          helperText: l10n.diagnosticsAnalyticsInternalHelp,
                          value:
                              widget.controller.workspace.analyticsMarkInternal,
                          onChanged: (value) => unawaited(
                            widget.controller.workspace
                                .setAnalyticsMarkInternal(value),
                          ),
                        ),
                        const SizedBox(height: 12),
                        AppToggleRow(
                          key: const Key('diagnostics_analytics_test_toggle'),
                          title: l10n.diagnosticsAnalyticsTest,
                          helperText: l10n.diagnosticsAnalyticsTestHelp,
                          value: widget.controller.workspace.analyticsTestMode,
                          onChanged: (value) => unawaited(
                            widget.controller.workspace.setAnalyticsTestMode(
                              value,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                    );
                  },
                ),
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
                          await widget.controller.workspace
                              .revealTodayLogFile();
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
        ),
      ],
    );
  }
}
