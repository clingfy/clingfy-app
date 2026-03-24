import 'dart:async';
import 'dart:math' as math;

import 'package:clingfy/app/config/build_config.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/settings/sections/section_helpers.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/models/storage_snapshot.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_dialog.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class StorageSettingsSection extends StatefulWidget {
  const StorageSettingsSection({
    super.key,
    required this.controller,
    this.showDeveloperTools,
    this.autoRefreshInterval = const Duration(seconds: 30),
  });

  final SettingsController controller;
  final bool? showDeveloperTools;
  final Duration autoRefreshInterval;

  @override
  State<StorageSettingsSection> createState() => _StorageSettingsSectionState();
}

class _StorageSettingsSectionState extends State<StorageSettingsSection> {
  static const _systemUsedColor = Color(0xFF3F6DF6);
  static const _systemFreeColor = Color(0xFF24B47E);
  static const _recordingsColor = Color(0xFF3F6DF6);
  static const _tempColor = Color(0xFFF2A93B);
  static const _logsColor = Color(0xFF58B6C0);

  String? _actionError;
  String? _actionSuccess;
  Timer? _autoRefreshTimer;
  bool _isRunningAction = false;

  bool get _showDeveloperTools =>
      widget.showDeveloperTools ?? BuildConfig.isDev();

  @override
  void initState() {
    super.initState();
    _scheduleInitialLoad();
    _startAutoRefresh();
  }

  @override
  void didUpdateWidget(covariant StorageSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller.storage != widget.controller.storage) {
      _scheduleInitialLoad();
    }
    if (oldWidget.controller.storage != widget.controller.storage ||
        oldWidget.autoRefreshInterval != widget.autoRefreshInterval) {
      _restartAutoRefresh();
    }
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  void _scheduleInitialLoad() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(widget.controller.storage.refresh());
    });
  }

  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    if (widget.autoRefreshInterval <= Duration.zero) {
      return;
    }
    _autoRefreshTimer = Timer.periodic(widget.autoRefreshInterval, (_) {
      if (!mounted) return;
      unawaited(widget.controller.storage.refresh());
    });
  }

  void _restartAutoRefresh() {
    _startAutoRefresh();
  }

  Future<T?> _runAction<T>(
    Future<T> Function() action, {
    required String fallbackError,
  }) async {
    if (_isRunningAction) {
      return null;
    }

    try {
      setState(() {
        _actionError = null;
        _actionSuccess = null;
        _isRunningAction = true;
      });

      final result = await action();
      return result;
    } catch (e) {
      if (!mounted) return null;
      setState(() {
        _actionError = _formatActionError(e, fallbackError);
      });
      return null;
    } finally {
      if (mounted) {
        setState(() {
          _isRunningAction = false;
        });
      }
    }
  }

  Future<void> _confirmAndClearCachedRecordings(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await AppDialog.confirm(
      context,
      title: l10n.storageClearCachedRecordingsConfirmTitle,
      message: l10n.storageClearCachedRecordingsConfirmMessage,
      confirmLabel: l10n.storageClearCachedRecordingsConfirmAction,
      cancelLabel: l10n.cancel,
    );
    if (!confirmed || !mounted) {
      return;
    }

    final deletedCount = await _runAction<int>(
      widget.controller.storage.clearCachedRecordings,
      fallbackError: l10n.storageActionFailed,
    );
    if (!mounted || deletedCount == null || deletedCount <= 0) {
      return;
    }

    setState(() {
      _actionSuccess = l10n.storageClearCachedRecordingsSuccess(deletedCount);
    });
  }

  String _formatActionError(Object error, String fallbackError) {
    if (error is PlatformException) {
      final message = error.message?.trim();
      if (message != null && message.isNotEmpty) {
        return message;
      }
    }

    final message = error.toString().trim();
    if (message.isNotEmpty) {
      return message;
    }

    return fallbackError;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final workflowPhase = context.select<RecordingController?, WorkflowPhase>(
      (controller) => controller?.phase ?? WorkflowPhase.idle,
    );

    return AnimatedBuilder(
      animation: widget.controller.storage,
      builder: (context, _) {
        final storage = widget.controller.storage;
        final snapshot = storage.snapshot;
        final canClearCachedRecordings =
            snapshot != null &&
            snapshot.recordingsBytes > 0 &&
            workflowPhase == WorkflowPhase.idle &&
            !_isRunningAction;

        return buildSectionPage(
          context,
          children: [
            if (storage.error != null) ...[
              AppInlineNotice(
                message: l10n.storageActionFailed,
                variant: AppInlineNoticeVariant.error,
                actionLabel: _showDeveloperTools ? l10n.storageRefresh : null,
                onActionPressed: _showDeveloperTools
                    ? () {
                        unawaited(storage.refresh());
                      }
                    : null,
              ),
              const SizedBox(height: 16),
            ],
            if (_actionError != null) ...[
              AppInlineNotice(
                message: _actionError!,
                variant: AppInlineNoticeVariant.error,
              ),
              const SizedBox(height: 16),
            ],
            if (_actionSuccess != null) ...[
              AppInlineNotice(
                message: _actionSuccess!,
                variant: AppInlineNoticeVariant.success,
              ),
              const SizedBox(height: 16),
            ],
            if (snapshot != null) ...[
              AppInlineNotice(
                message: _statusMessage(l10n, snapshot.status),
                variant: _noticeVariant(snapshot.status),
              ),
              const SizedBox(height: 16),
            ],
            SettingsCard(
              title: l10n.storageOverviewTitle,
              subtitle: l10n.storageOverviewDescription,
              child: _buildOverview(context, snapshot, storage.isLoading),
            ),
            if (snapshot != null) ...[
              const SizedBox(height: 16),
              SettingsCard(
                title: l10n.storageSystemTitle,
                subtitle: l10n.storageSystemDescription,
                child: _SystemStorageCard(
                  snapshot: snapshot,
                  usedColor: _systemUsedColor,
                  freeColor: _systemFreeColor,
                ),
              ),
              const SizedBox(height: 16),
              SettingsCard(
                title: l10n.storageClingfyTitle,
                subtitle: l10n.storageClingfyDescription,
                child: _ClingfyStorageCard(
                  snapshot: snapshot,
                  recordingsColor: _recordingsColor,
                  tempColor: _tempColor,
                  logsColor: _logsColor,
                  footer: Align(
                    alignment: Alignment.centerLeft,
                    child: AppButton(
                      key: const Key('storage_clear_cached_recordings_button'),
                      label: l10n.storageClearCachedRecordings,
                      icon: CupertinoIcons.delete,
                      variant: AppButtonVariant.secondary,
                      onPressed: canClearCachedRecordings
                          ? () {
                              unawaited(
                                _confirmAndClearCachedRecordings(context),
                              );
                            }
                          : null,
                    ),
                  ),
                ),
              ),
              if (_showDeveloperTools) ...[
                const SizedBox(height: 16),
                SettingsCard(
                  title: l10n.storageActionsTitle,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      AppButton(
                        label: l10n.storageRefresh,
                        icon: CupertinoIcons.refresh,
                        onPressed: () {
                          unawaited(storage.refresh());
                        },
                      ),
                      AppButton(
                        label: l10n.storageOpenRecordingsFolder,
                        icon: CupertinoIcons.folder,
                        variant: AppButtonVariant.secondary,
                        onPressed: () => _runAction(
                          storage.revealRecordingsFolder,
                          fallbackError: l10n.storageActionFailed,
                        ),
                      ),
                      AppButton(
                        label: l10n.storageOpenTempFolder,
                        icon: CupertinoIcons.tray,
                        variant: AppButtonVariant.secondary,
                        onPressed: () => _runAction(
                          storage.revealTempFolder,
                          fallbackError: l10n.storageActionFailed,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SettingsCard(
                  title: l10n.storagePathsTitle,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _StoragePathRow(
                        label: l10n.storageRecordingsPath,
                        path: snapshot.recordingsPath,
                      ),
                      const SizedBox(height: 12),
                      _StoragePathRow(
                        label: l10n.storageTempPath,
                        path: snapshot.tempPath,
                      ),
                      const SizedBox(height: 12),
                      _StoragePathRow(
                        label: l10n.storageLogsPath,
                        path: snapshot.logsPath,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ],
        );
      },
    );
  }

  Widget _buildOverview(
    BuildContext context,
    StorageSnapshot? snapshot,
    bool isLoading,
  ) {
    final l10n = AppLocalizations.of(context)!;
    if (snapshot != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _statusLabel(l10n, snapshot.status),
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.storageFreeNow(_formatBytes(snapshot.systemAvailableBytes)),
          ),
        ],
      );
    }

    if (isLoading) {
      return Row(
        children: [
          const SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(l10n.loading)),
        ],
      );
    }

    return Text(l10n.storageOverviewDescription);
  }

  String _statusLabel(AppLocalizations l10n, StorageHealthStatus status) {
    return switch (status) {
      StorageHealthStatus.healthy => l10n.storageHealthy,
      StorageHealthStatus.warning => l10n.storageWarning,
      StorageHealthStatus.critical => l10n.storageCritical,
    };
  }

  String _statusMessage(AppLocalizations l10n, StorageHealthStatus status) {
    return switch (status) {
      StorageHealthStatus.healthy => l10n.storageHealthyMessage,
      StorageHealthStatus.warning => l10n.storageWarningMessage,
      StorageHealthStatus.critical => l10n.storageCriticalMessage,
    };
  }

  AppInlineNoticeVariant _noticeVariant(StorageHealthStatus status) {
    return switch (status) {
      StorageHealthStatus.healthy => AppInlineNoticeVariant.success,
      StorageHealthStatus.warning => AppInlineNoticeVariant.warning,
      StorageHealthStatus.critical => AppInlineNoticeVariant.error,
    };
  }
}

class _SystemStorageCard extends StatelessWidget {
  const _SystemStorageCard({
    required this.snapshot,
    required this.usedColor,
    required this.freeColor,
  });

  final StorageSnapshot snapshot;
  final Color usedColor;
  final Color freeColor;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final segments = [
      _StorageChartSegment(value: snapshot.systemUsedBytes, color: usedColor),
      _StorageChartSegment(
        value: snapshot.systemAvailableBytes,
        color: freeColor,
      ),
    ];

    return _StorageDonutCard(
      chartKey: const Key('storage_system_chart'),
      segments: segments,
      centerValue: _formatBytes(snapshot.systemAvailableBytes),
      centerLabel: l10n.storageFreeSpace,
      rows: [
        _StorageStatRow(
          label: l10n.storageStatusLabel,
          value: switch (snapshot.status) {
            StorageHealthStatus.healthy => l10n.storageHealthy,
            StorageHealthStatus.warning => l10n.storageWarning,
            StorageHealthStatus.critical => l10n.storageCritical,
          },
        ),
        _StorageStatRow(
          label: l10n.storageTotalSpace,
          value: _formatBytes(snapshot.systemTotalBytes),
        ),
        _StorageStatRow(
          label: l10n.storageUsedSpace,
          value: _formatBytes(snapshot.systemUsedBytes),
          accentColor: usedColor,
        ),
        _StorageStatRow(
          label: l10n.storageFreeSpace,
          value: _formatBytes(snapshot.systemAvailableBytes),
          accentColor: freeColor,
        ),
      ],
    );
  }
}

class _ClingfyStorageCard extends StatelessWidget {
  const _ClingfyStorageCard({
    required this.snapshot,
    required this.recordingsColor,
    required this.tempColor,
    required this.logsColor,
    this.footer,
  });

  final StorageSnapshot snapshot;
  final Color recordingsColor;
  final Color tempColor;
  final Color logsColor;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _StorageDonutCard(
      chartKey: const Key('storage_clingfy_chart'),
      segments: [
        _StorageChartSegment(
          value: snapshot.recordingsBytes,
          color: recordingsColor,
        ),
        _StorageChartSegment(value: snapshot.tempBytes, color: tempColor),
        _StorageChartSegment(value: snapshot.logsBytes, color: logsColor),
      ],
      centerValue: _formatBytes(snapshot.clingfyTotalBytes),
      centerLabel: l10n.storageClingfyTotal,
      rows: [
        _StorageStatRow(
          label: l10n.storageRecordings,
          value: _formatBytes(snapshot.recordingsBytes),
          accentColor: recordingsColor,
        ),
        _StorageStatRow(
          label: l10n.storageTemp,
          value: _formatBytes(snapshot.tempBytes),
          accentColor: tempColor,
        ),
        _StorageStatRow(
          label: l10n.storageLogs,
          value: _formatBytes(snapshot.logsBytes),
          accentColor: logsColor,
        ),
        _StorageStatRow(
          label: l10n.storageClingfyTotal,
          value: _formatBytes(snapshot.clingfyTotalBytes),
        ),
      ],
      footer: footer,
    );
  }
}

class _StorageDonutCard extends StatelessWidget {
  const _StorageDonutCard({
    required this.chartKey,
    required this.segments,
    required this.centerValue,
    required this.centerLabel,
    required this.rows,
    this.footer,
  });

  final Key chartKey;
  final List<_StorageChartSegment> segments;
  final String centerValue;
  final String centerLabel;
  final List<Widget> rows;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: _StorageDonutChart(
            chartKey: chartKey,
            segments: segments,
            centerValue: centerValue,
            centerLabel: centerLabel,
          ),
        ),
        const SizedBox(height: 20),
        for (var index = 0; index < rows.length; index++) ...[
          if (index > 0) const SizedBox(height: 10),
          rows[index],
        ],
        if (footer != null) ...[const SizedBox(height: 20), footer!],
      ],
    );
  }
}

class _StorageDonutChart extends StatelessWidget {
  const _StorageDonutChart({
    this.chartKey,
    required this.segments,
    required this.centerValue,
    required this.centerLabel,
  });

  final Key? chartKey;
  final List<_StorageChartSegment> segments;
  final String centerValue;
  final String centerLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chartBackgroundColor = theme.colorScheme.onSurface.withValues(
      alpha: 0.08,
    );
    final labelColor = theme.textTheme.bodySmall?.color;

    return SizedBox(
      key: chartKey,
      height: 204,
      width: 204,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size.square(204),
            painter: _StorageDonutChartPainter(
              segments: segments,
              backgroundColor: chartBackgroundColor,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  centerValue,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  centerLabel,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: labelColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageDonutChartPainter extends CustomPainter {
  const _StorageDonutChartPainter({
    required this.segments,
    required this.backgroundColor,
  });

  final List<_StorageChartSegment> segments;
  final Color backgroundColor;

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = size.shortestSide * 0.14;
    final radius = (size.shortestSide - strokeWidth) / 2;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: radius,
    );
    final basePaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, 0, math.pi * 2, false, basePaint);

    final visibleSegments = segments
        .where((segment) => segment.value > 0)
        .toList();
    if (visibleSegments.isEmpty) {
      return;
    }

    final total = visibleSegments.fold<int>(
      0,
      (sum, segment) => sum + segment.value,
    );
    final gapAngle = visibleSegments.length > 1 ? 0.045 : 0.0;
    final drawableSweep = (math.pi * 2) - (gapAngle * visibleSegments.length);
    var startAngle = -math.pi / 2;

    for (final segment in visibleSegments) {
      final sweep = drawableSweep * (segment.value / total);
      final paint = Paint()
        ..color = segment.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(rect, startAngle, math.max(sweep, 0.001), false, paint);
      startAngle += sweep + gapAngle;
    }
  }

  @override
  bool shouldRepaint(covariant _StorageDonutChartPainter oldDelegate) {
    return oldDelegate.segments != segments ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}

class _StorageChartSegment {
  const _StorageChartSegment({required this.value, required this.color});

  final int value;
  final Color color;
}

class _StorageStatRow extends StatelessWidget {
  const _StorageStatRow({
    required this.label,
    required this.value,
    this.accentColor,
  });

  final String label;
  final String value;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (accentColor != null) ...[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: accentColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _StoragePathRow extends StatelessWidget {
  const _StoragePathRow({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        SelectableText(
          path,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
        ),
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
