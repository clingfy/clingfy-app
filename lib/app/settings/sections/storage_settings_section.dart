import 'dart:async';

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
import 'package:syncfusion_flutter_charts/charts.dart';

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
  static const _storageDetailCardsBreakpoint = 860.0;
  static const _storageCardGap = 16.0;
  static const _systemUsedColor = Color(0xFF3F6DF6);
  static const _systemFreeColor = Color(0xFF24B47E);
  static const _recordingsColor = Color(0xFF3F6DF6);
  static const _tempColor = Color(0xFFF2A93B);
  static const _logsColor = Color(0xFF58B6C0);

  String? _actionError;
  String? _actionSuccess;
  Timer? _autoRefreshTimer;
  Timer? _successDismissTimer;
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
    _successDismissTimer?.cancel();
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
    _successDismissTimer?.cancel();
    _successDismissTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      setState(() {
        _actionSuccess = null;
      });
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

            Container(
              key: const Key('storage_overview_card'),
              child: SettingsCard(
                title: l10n.storageOverviewTitle,
                infoTooltip: l10n.storageOverviewDescription,
                child: _buildOverview(context, snapshot, storage.isLoading),
              ),
            ),
            if (snapshot != null) ...[
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, constraints) {
                  final systemCard = Container(
                    key: const Key('storage_system_card'),
                    child: SettingsCard(
                      title: l10n.storageSystemTitle,
                      infoTooltip: l10n.storageSystemDescription,
                      child: _SystemStorageCard(
                        snapshot: snapshot,
                        usedColor: _systemUsedColor,
                        freeColor: _systemFreeColor,
                      ),
                    ),
                  );
                  final clingfyCard = Container(
                    key: const Key('storage_clingfy_card'),
                    child: SettingsCard(
                      title: l10n.storageClingfyTitle,
                      infoTooltip: l10n.storageClingfyDescription,
                      child: _ClingfyStorageCard(
                        snapshot: snapshot,
                        recordingsColor: _recordingsColor,
                        tempColor: _tempColor,
                        logsColor: _logsColor,
                      ),
                    ),
                  );

                  if (constraints.maxWidth >= _storageDetailCardsBreakpoint) {
                    return Row(
                      key: const Key('storage_detail_cards_row'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: systemCard),
                        const SizedBox(width: _storageCardGap),
                        Expanded(child: clingfyCard),
                      ],
                    );
                  }

                  return Column(
                    key: const Key('storage_detail_cards_column'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      systemCard,
                      const SizedBox(height: _storageCardGap),
                      clingfyCard,
                    ],
                  );
                },
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
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.start,
              spacing: 8,
              runSpacing: 8,
              children: [
                AppButton(
                  key: const Key('storage_open_system_settings_button'),
                  label: l10n.openStorageSettings,
                  icon: CupertinoIcons.gear,
                  variant: AppButtonVariant.secondary,
                  onPressed: () => _runAction(
                    storage.openSystemStorageSettings,
                    fallbackError: l10n.storageActionFailed,
                  ),
                ),
                AppButton(
                  key: const Key('storage_clear_cached_recordings_button'),
                  label: l10n.storageClearCachedRecordings,
                  icon: CupertinoIcons.delete,
                  variant: AppButtonVariant.secondary,
                  onPressed: canClearCachedRecordings
                      ? () {
                          unawaited(_confirmAndClearCachedRecordings(context));
                        }
                      : null,
                ),
              ],
            ),
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

          const SizedBox(height: 16),
          AppInlineNotice(
            message: _statusMessage(l10n, snapshot.status),
            variant: _noticeVariant(snapshot.status),
          ),
          const SizedBox(height: 16),
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
      _StorageChartSegment(
        label: l10n.storageUsedSpace,
        value: snapshot.systemUsedBytes,
        color: usedColor,
      ),
      _StorageChartSegment(
        label: l10n.storageFreeSpace,
        value: snapshot.systemAvailableBytes,
        color: freeColor,
      ),
    ];

    return _StorageChartCard(
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
  });

  final StorageSnapshot snapshot;
  final Color recordingsColor;
  final Color tempColor;
  final Color logsColor;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _StorageChartCard(
      chartKey: const Key('storage_clingfy_chart'),
      segments: [
        _StorageChartSegment(
          label: l10n.storageRecordings,
          value: snapshot.recordingsBytes,
          color: recordingsColor,
        ),
        _StorageChartSegment(
          label: l10n.storageTemp,
          value: snapshot.tempBytes,
          color: tempColor,
        ),
        _StorageChartSegment(
          label: l10n.storageLogs,
          value: snapshot.logsBytes,
          color: logsColor,
        ),
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
    );
  }
}

class _StorageChartCard extends StatelessWidget {
  const _StorageChartCard({
    required this.chartKey,
    required this.segments,
    required this.centerValue,
    required this.centerLabel,
    required this.rows,
  });

  final Key chartKey;
  final List<_StorageChartSegment> segments;
  final String centerValue;
  final String centerLabel;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final totalValue = segments.fold<int>(
      0,
      (sum, segment) => sum + segment.value,
    );
    final visibleSegments = segments
        .where((segment) => segment.value > 0)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: _StorageDoughnutChart(
            chartKey: chartKey,
            segments: segments,
            centerValue: centerValue,
            centerLabel: centerLabel,
          ),
        ),
        if (visibleSegments.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: visibleSegments
                .map(
                  (segment) => _StorageLegendChip(
                    segment: segment,
                    totalValue: totalValue,
                  ),
                )
                .toList(),
          ),
        ],
        const SizedBox(height: 18),
        for (var index = 0; index < rows.length; index++) ...[
          if (index > 0) const SizedBox(height: 10),
          rows[index],
        ],
      ],
    );
  }
}

class _StorageDoughnutChart extends StatelessWidget {
  static const double size = 220;

  const _StorageDoughnutChart({
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
    final isDark = theme.brightness == Brightness.dark;

    final visibleSegments = segments
        .where((segment) => segment.value > 0)
        .toList();
    final hasData = visibleSegments.isNotEmpty;

    final fallbackColor = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.10 : 0.06,
    );

    final chartSegments = hasData
        ? visibleSegments
        : [
            _StorageChartSegment(
              label: centerLabel,
              value: 1,
              color: fallbackColor,
            ),
          ];

    final hubColor = isDark
        ? theme.colorScheme.surface.withValues(alpha: 0.98)
        : theme.colorScheme.surface;

    final hubBorderColor = theme.colorScheme.onSurface.withValues(
      alpha: isDark ? 0.08 : 0.06,
    );

    final centerLabelColor = theme.textTheme.bodySmall?.color?.withValues(
      alpha: 0.72,
    );

    return SizedBox(
      key: chartKey,
      width: size,
      height: size,
      child: SfCircularChart(
        margin: EdgeInsets.zero,
        backgroundColor: Colors.transparent,
        annotations: [
          CircularChartAnnotation(
            widget: Container(
              width: 118,
              height: 118,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: hubColor,
                shape: BoxShape.circle,
                border: Border.all(color: hubBorderColor),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    centerValue,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    centerLabel,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: centerLabelColor,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        series: <DoughnutSeries<_StorageChartSegment, String>>[
          DoughnutSeries<_StorageChartSegment, String>(
            dataSource: chartSegments,
            xValueMapper: (segment, _) => segment.label,
            yValueMapper: (segment, _) => segment.value,
            pointColorMapper: (segment, _) => segment.color,
            radius: '100%',
            innerRadius: '68%',
            cornerStyle: CornerStyle.bothFlat,
            strokeWidth: 0,
            enableTooltip: true,
            explode: true,
            explodeGesture: ActivationMode.singleTap,
            legendIconType: LegendIconType.pentagon,
            selectionBehavior: SelectionBehavior(enable: true),
            pointRenderMode: PointRenderMode.segment,
          ),
        ],
      ),
    );
  }
}

class _StorageLegendChip extends StatelessWidget {
  const _StorageLegendChip({required this.segment, required this.totalValue});

  final _StorageChartSegment segment;
  final int totalValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelColor = theme.textTheme.bodySmall?.color?.withValues(
      alpha: 0.72,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: segment.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            segment.label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatPercentage(segment.value, totalValue),
            style: theme.textTheme.bodySmall?.copyWith(color: labelColor),
          ),
        ],
      ),
    );
  }

  String _formatPercentage(int value, int total) {
    if (total <= 0) return '0%';
    final percent = (value / total) * 100;
    final precision = percent >= 10 ? 0 : 1;
    return '${percent.toStringAsFixed(precision)}%';
  }
}

// class _StorageRadialBarChart extends StatelessWidget {
//   static const double size = 220;
//   static const double hubSize = 84;

//   const _StorageRadialBarChart({
//     this.chartKey,
//     required this.segments,
//     required this.centerValue,
//     required this.centerLabel,
//   });

//   final Key? chartKey;
//   final List<_StorageChartSegment> segments;
//   final String centerValue;
//   final String centerLabel;

//   @override
//   Widget build(BuildContext context) {
//     final theme = Theme.of(context);
//     final isDark = theme.brightness == Brightness.dark;
//     final totalValue = segments.fold<int>(
//       0,
//       (sum, segment) => sum + segment.value,
//     );
//     final trackColor = theme.colorScheme.onSurface.withValues(
//       alpha: isDark ? 0.12 : 0.08,
//     );
//     final hubColor = isDark
//         ? theme.scaffoldBackgroundColor.withValues(alpha: 0.96)
//         : theme.colorScheme.surface;
//     final hubBorderColor = theme.colorScheme.onSurface.withValues(
//       alpha: isDark ? 0.07 : 0.05,
//     );
//     final labelColor = theme.textTheme.bodySmall?.color;

//     return SizedBox(
//       key: chartKey,
//       height: size,
//       width: size,
//       child: Stack(
//         alignment: Alignment.center,
//         children: [
//           SfCircularChart(
//             margin: EdgeInsets.zero,
//             backgroundColor: Colors.transparent,
//             title: ChartTitle(text: 'Sales by sales person'),
//             legend: Legend(isVisible: true),
//             series: <PieSeries<_StorageChartSegment, String>>[
//               PieSeries<_StorageChartSegment, String>(
//                 explode: false,
//                 legendIconType: LegendIconType.circle,
//                 // legend:  Legend(isVisible: true),
//                 // series: <RadialBarSeries<_StorageChartSegment, String>>[
//                 //   RadialBarSeries<_StorageChartSegment, String>(
//                 dataSource: segments,
//                 xValueMapper: (segment, _) => segment.label,
//                 yValueMapper: (segment, _) => segment.value,
//                 pointColorMapper: (segment, _) => segment.color,
//                 // maximumValue: totalValue > 0 ? totalValue.toDouble() : 1,
//                 radius: '100%',
//                 // innerRadius: '38%',
//                 // gap: '7%',
//                 // cornerStyle: CornerStyle.bothCurve,
//                 // trackColor: trackColor,
//                 // trackOpacity: 1,

//                 strokeWidth: 2,
//                 animationDuration: 4 * 1000,
//                 enableTooltip: false,
//               ),
//             ],
//           ),
//           SizedBox.square(
//             dimension: hubSize,
//             child: DecoratedBox(
//               decoration: BoxDecoration(
//                 color: hubColor,
//                 shape: BoxShape.circle,
//                 border: Border.all(color: hubBorderColor),
//               ),
//             ),
//           ),
//           Padding(
//             padding: const EdgeInsets.symmetric(horizontal: 42),
//             child: Column(
//               mainAxisSize: MainAxisSize.min,
//               children: [
//                 Text(
//                   centerValue,
//                   textAlign: TextAlign.center,
//                   style: theme.textTheme.titleMedium?.copyWith(
//                     fontSize: 18,
//                     fontWeight: FontWeight.w800,
//                   ),
//                 ),
//                 const SizedBox(height: 4),
//                 Text(
//                   centerLabel,
//                   textAlign: TextAlign.center,
//                   style: theme.textTheme.bodySmall?.copyWith(
//                     color: labelColor,
//                     height: 1.25,
//                   ),
//                 ),
//               ],
//             ),
//           ),
//         ],
//       ),
//     );
//   }
// }

class _StorageChartSegment {
  const _StorageChartSegment({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
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
    final theme = Theme.of(context);
    final mutedColor = theme.textTheme.bodyMedium?.color?.withValues(
      alpha: 0.72,
    );

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
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(color: mutedColor),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
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
