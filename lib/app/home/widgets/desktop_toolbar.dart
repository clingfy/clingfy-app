import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/theme/app_shell_tokens.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Icons, Theme;
import 'package:macos_ui/macos_ui.dart';

const _toolbarRowKey = Key('desktop_toolbar_row');
const _toolbarSurfaceKey = Key('desktop_toolbar_surface');
const _toolbarStatusStripKey = Key('toolbar_status_strip');
const _toolbarNoticeLaneKey = Key('toolbar_notice_lane');
const _toolbarExportLaneKey = Key('toolbar_export_lane');

enum ToolbarMessageTone { info, success, warning, error }

class ToolbarMessageAction {
  const ToolbarMessageAction({
    required this.label,
    required this.onPressed,
    this.semanticLabel,
  });

  final String label;
  final String? semanticLabel;
  final VoidCallback onPressed;
}

class ToolbarNoticePresentation {
  const ToolbarNoticePresentation({
    required this.message,
    required this.tone,
    this.action,
    this.onDismiss,
  });

  final String message;
  final ToolbarMessageTone tone;
  final ToolbarMessageAction? action;
  final VoidCallback? onDismiss;
}

class ToolbarExportStatusPresentation {
  const ToolbarExportStatusPresentation({
    required this.progress,
    required this.cancelRequested,
    this.onShowDetails,
    this.onCancel,
  });

  final double? progress;
  final bool cancelRequested;
  final VoidCallback? onShowDetails;
  final VoidCallback? onCancel;
}

class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.35,
        end: 1,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: Icon(
        CupertinoIcons.circle_filled,
        size: widget.size,
        color: widget.color,
      ),
    );
  }
}

class DesktopToolbar extends StatelessWidget {
  const DesktopToolbar({
    super.key,
    required this.title,
    required this.isRecording,
    this.elapsedText,
    this.notice,
    this.countdownText,
    this.onExport,
    this.exportStatus,
    this.isProcessing = false,
  });

  final String title;
  final bool isRecording;
  final String? elapsedText;
  final ToolbarNoticePresentation? notice;
  final String? countdownText;
  final VoidCallback? onExport;
  final ToolbarExportStatusPresentation? exportStatus;
  final bool isProcessing;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final normalizedNotice = _normalizedNotice(notice);
    final effectiveExportStatus = exportStatus;

    final stripChild = normalizedNotice == null && effectiveExportStatus == null
        ? null
        : KeyedSubtree(
            key: ValueKey(
              Object.hash(
                normalizedNotice?.message,
                normalizedNotice?.tone,
                normalizedNotice?.action?.label,
                effectiveExportStatus?.progress,
                effectiveExportStatus?.cancelRequested,
              ),
            ),
            child: ToolbarStatusStrip(
              key: _toolbarStatusStripKey,
              notice: normalizedNotice,
              exportStatus: effectiveExportStatus,
              l10n: l10n,
            ),
          );

    if (isMac()) {
      return _ToolbarShell(
        row: _MacToolbarRow(
          key: _toolbarRowKey,
          title: title,
          isRecording: isRecording,
          elapsedText: elapsedText,
          countdownText: countdownText,
          onExport: onExport,
          isProcessing: isProcessing,
          l10n: l10n,
        ),
        statusStrip: stripChild,
      );
    }

    if (isWindows()) {
      return _ToolbarShell(
        row: _WinToolbarRow(
          key: _toolbarRowKey,
          title: title,
          isRecording: isRecording,
          elapsedText: elapsedText,
          countdownText: countdownText,
          onExport: onExport,
          isProcessing: isProcessing,
          l10n: l10n,
        ),
        statusStrip: stripChild,
      );
    }

    return _ToolbarShell(
      row: _FallbackToolbarRow(
        key: _toolbarRowKey,
        title: title,
        isRecording: isRecording,
        elapsedText: elapsedText,
        countdownText: countdownText,
        onExport: onExport,
        isProcessing: isProcessing,
        l10n: l10n,
      ),
      statusStrip: stripChild,
    );
  }

  ToolbarNoticePresentation? _normalizedNotice(
    ToolbarNoticePresentation? value,
  ) {
    if (value == null) {
      return null;
    }
    final trimmed = value.message.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return ToolbarNoticePresentation(
      message: trimmed,
      tone: value.tone,
      action: value.action,
      onDismiss: value.onDismiss,
    );
  }
}

class ToolbarStatusStrip extends StatelessWidget {
  const ToolbarStatusStrip({
    super.key,
    required this.notice,
    required this.exportStatus,
    required this.l10n,
  });

  final ToolbarNoticePresentation? notice;
  final ToolbarExportStatusPresentation? exportStatus;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    if (isMac()) {
      return _MacStatusStrip(
        notice: notice,
        exportStatus: exportStatus,
        l10n: l10n,
      );
    }

    if (isWindows()) {
      return _WinStatusStrip(
        notice: notice,
        exportStatus: exportStatus,
        l10n: l10n,
      );
    }

    return _FallbackStatusStrip(
      notice: notice,
      exportStatus: exportStatus,
      l10n: l10n,
    );
  }
}

class _ToolbarShell extends StatelessWidget {
  const _ToolbarShell({required this.row, this.statusStrip});

  final Widget row;
  final Widget? statusStrip;

  @override
  Widget build(BuildContext context) {
    final spacing = context.appSpacing;
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row,
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) {
              final curved = CurvedAnimation(
                parent: animation,
                curve: Curves.easeOut,
                reverseCurve: Curves.easeIn,
              );
              return FadeTransition(
                opacity: curved,
                child: SizeTransition(
                  sizeFactor: curved,
                  axisAlignment: -1,
                  child: child,
                ),
              );
            },
            child: statusStrip == null
                ? const SizedBox.shrink(key: ValueKey('toolbar-status-empty'))
                : Padding(
                    key: const ValueKey('toolbar-status-visible'),
                    padding: EdgeInsets.only(top: spacing.xs - 1),
                    child: statusStrip!,
                  ),
          ),
        ],
      ),
    );
  }
}

class _MacToolbarRow extends StatelessWidget {
  const _MacToolbarRow({
    super.key,
    required this.title,
    required this.isRecording,
    required this.elapsedText,
    required this.countdownText,
    required this.onExport,
    required this.isProcessing,
    required this.l10n,
  });

  final String title;
  final bool isRecording;
  final String? elapsedText;
  final String? countdownText;
  final VoidCallback? onExport;
  final bool isProcessing;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = context.appSpacing;
    final typography = context.appTypography;
    final chrome = theme.appEditorChrome;
    final tokens = theme.appTokens;
    final bg = tokens.editorChromeBackground;

    return Container(
      key: _toolbarSurfaceKey,
      height: chrome.toolbarHeight,
      padding: EdgeInsets.symmetric(horizontal: spacing.sm),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(chrome.panelRadius),
      ),
      child: Row(
        children: [
          Text(title, style: typography.button),
          SizedBox(width: spacing.xs + 2),
          if (isRecording) ...[
            _pill(
              context,
              icon: CupertinoIcons.recordingtape,
              text: elapsedText ?? l10n.recording,
              pulsingDot: true,
            ),
            SizedBox(width: spacing.xs + 2),
          ],
          const Spacer(),
          if (countdownText != null) ...[
            _pill(
              context,
              icon: CupertinoIcons.timer,
              text: l10n.stopIn(countdownText!),
              pulsingDot: true,
            ),
            SizedBox(width: spacing.xs + 2),
          ],
          if (onExport != null) ...[
            AppButton(
              onPressed: isProcessing ? null : onExport,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isProcessing) ...[
                    const CupertinoActivityIndicator(radius: 8),
                    SizedBox(width: spacing.xs + 2),
                    Text('${l10n.export}…'),
                  ] else ...[
                    MacosIcon(
                      CupertinoIcons.arrow_down_to_line,
                      size: 16,
                      color: theme.colorScheme.onPrimary,
                    ),
                    SizedBox(width: spacing.xs + 2),
                    Text(l10n.export),
                  ],
                ],
              ),
            ),
            SizedBox(width: spacing.xs),
          ],
        ],
      ),
    );
  }
}

class _WinToolbarRow extends StatelessWidget {
  const _WinToolbarRow({
    super.key,
    required this.title,
    required this.isRecording,
    required this.elapsedText,
    required this.countdownText,
    required this.onExport,
    required this.isProcessing,
    required this.l10n,
  });

  final String title;
  final bool isRecording;
  final String? elapsedText;
  final String? countdownText;
  final VoidCallback? onExport;
  final bool isProcessing;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = fluent.FluentTheme.of(context);
    final materialTheme = Theme.of(context);
    final spacing = materialTheme.appSpacing;
    final tokens = materialTheme.appTokens;
    final chrome = materialTheme.appEditorChrome;

    return fluent.Container(
      key: _toolbarSurfaceKey,
      height: chrome.toolbarHeight,
      padding: EdgeInsets.symmetric(horizontal: spacing.sm),
      decoration: fluent.BoxDecoration(
        color: tokens.editorChromeBackground,
        borderRadius: BorderRadius.circular(chrome.panelRadius),
      ),
      child: Row(
        children: [
          Text(title, style: theme.typography.bodyStrong),
          SizedBox(width: spacing.xs + 2),
          if (isRecording) ...[
            _pillWin(
              context,
              theme,
              icon: fluent.FluentIcons.circle_fill,
              text: elapsedText ?? l10n.recording,
              danger: true,
            ),
            SizedBox(width: spacing.xs + 2),
          ],
          const Spacer(),
          if (countdownText != null) ...[
            _pillWin(
              context,
              theme,
              icon: fluent.FluentIcons.timer,
              text: l10n.stopIn(countdownText!),
              danger: false,
            ),
            SizedBox(width: spacing.xs + 2),
          ],
          if (onExport != null) ...[
            fluent.FilledButton(
              onPressed: isProcessing ? null : onExport,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(fluent.FluentIcons.download, size: 16),
                  SizedBox(width: spacing.xs + 2),
                  Text(l10n.export),
                ],
              ),
            ),
            SizedBox(width: spacing.xs),
          ],
        ],
      ),
    );
  }
}

class _FallbackToolbarRow extends StatelessWidget {
  const _FallbackToolbarRow({
    super.key,
    required this.title,
    required this.isRecording,
    required this.elapsedText,
    required this.countdownText,
    required this.onExport,
    required this.isProcessing,
    required this.l10n,
  });

  final String title;
  final bool isRecording;
  final String? elapsedText;
  final String? countdownText;
  final VoidCallback? onExport;
  final bool isProcessing;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.appTokens;
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final chrome = theme.appEditorChrome;
    return Container(
      key: _toolbarSurfaceKey,
      height: chrome.toolbarHeight,
      padding: EdgeInsets.symmetric(horizontal: spacing.sm),
      decoration: BoxDecoration(
        color: tokens.editorChromeBackground,
        borderRadius: BorderRadius.circular(chrome.panelRadius),
      ),
      child: Row(
        children: [
          Text(title, style: typography.button),
          SizedBox(width: spacing.xs + 2),
          if (isRecording) ...[
            _pillFallback(
              context,
              icon: Icons.fiber_manual_record,
              text: elapsedText ?? l10n.recording,
            ),
            SizedBox(width: spacing.xs + 2),
          ],
          const Spacer(),
          if (countdownText != null) ...[
            _pillFallback(
              context,
              icon: Icons.timer,
              text: l10n.stopIn(countdownText!),
            ),
            SizedBox(width: spacing.xs + 2),
          ],
          if (onExport != null) ...[
            _simpleButton(
              context: context,
              label: l10n.export,
              icon: Icons.download,
              onPressed: isProcessing ? null : onExport,
            ),
            SizedBox(width: spacing.xs),
          ],
        ],
      ),
    );
  }
}

class _MacStatusStrip extends StatelessWidget {
  const _MacStatusStrip({
    required this.notice,
    required this.exportStatus,
    required this.l10n,
  });

  final ToolbarNoticePresentation? notice;
  final ToolbarExportStatusPresentation? exportStatus;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final spacing = context.appSpacing;
    final lanes = <Widget>[
      if (notice != null)
        _MacNoticeLane(key: _toolbarNoticeLaneKey, notice: notice!),
      if (notice != null && exportStatus != null) SizedBox(height: spacing.xs),
      if (exportStatus != null)
        _MacExportLane(
          key: _toolbarExportLaneKey,
          exportStatus: exportStatus!,
          l10n: l10n,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: lanes,
    );
  }
}

class _WinStatusStrip extends StatelessWidget {
  const _WinStatusStrip({
    required this.notice,
    required this.exportStatus,
    required this.l10n,
  });

  final ToolbarNoticePresentation? notice;
  final ToolbarExportStatusPresentation? exportStatus;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final spacing = context.appSpacing;
    final lanes = <Widget>[
      if (notice != null)
        _WinNoticeLane(key: _toolbarNoticeLaneKey, notice: notice!),
      if (notice != null && exportStatus != null) SizedBox(height: spacing.xs),
      if (exportStatus != null)
        _WinExportLane(
          key: _toolbarExportLaneKey,
          exportStatus: exportStatus!,
          l10n: l10n,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: lanes,
    );
  }
}

class _FallbackStatusStrip extends StatelessWidget {
  const _FallbackStatusStrip({
    required this.notice,
    required this.exportStatus,
    required this.l10n,
  });

  final ToolbarNoticePresentation? notice;
  final ToolbarExportStatusPresentation? exportStatus;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final spacing = context.appSpacing;
    final lanes = <Widget>[
      if (notice != null)
        _FallbackNoticeLane(key: _toolbarNoticeLaneKey, notice: notice!),
      if (notice != null && exportStatus != null) SizedBox(height: spacing.xs),
      if (exportStatus != null)
        _FallbackExportLane(
          key: _toolbarExportLaneKey,
          exportStatus: exportStatus!,
          l10n: l10n,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: lanes,
    );
  }
}

class _MacNoticeLane extends StatelessWidget {
  const _MacNoticeLane({super.key, required this.notice});

  final ToolbarNoticePresentation notice;

  @override
  Widget build(BuildContext context) {
    final spacing = context.appSpacing;
    final typography = context.appTypography;
    final chrome = context.appEditorChrome;
    final colors = _noticeColors(context, notice.tone);
    final icon = _macNoticeIcon(notice.tone);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.md,
        vertical: spacing.sm - 2,
      ),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: colors.border == null
            ? null
            : Border.all(color: colors.border!),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          MacosIcon(icon, size: 14, color: colors.foreground),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Text(
              notice.message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: typography.bodyMuted.copyWith(
                color: colors.foreground,
                fontWeight:
                    notice.tone == ToolbarMessageTone.warning ||
                        notice.tone == ToolbarMessageTone.error
                    ? FontWeight.w600
                    : FontWeight.w500,
              ),
            ),
          ),
          if (notice.action != null || notice.onDismiss != null) ...[
            SizedBox(width: spacing.md),
            _MacLaneActions(
              action: notice.action,
              onDismiss: notice.onDismiss,
              dismissColor: colors.foreground,
            ),
          ],
        ],
      ),
    );
  }
}

class _MacExportLane extends StatelessWidget {
  const _MacExportLane({
    super.key,
    required this.exportStatus,
    required this.l10n,
  });

  final ToolbarExportStatusPresentation exportStatus;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final spacing = context.appSpacing;
    final typography = context.appTypography;
    final macTheme = MacosTheme.of(context);
    final tokens = Theme.of(context).appTokens;
    final chrome = context.appEditorChrome;
    final isDark = macTheme.brightness == Brightness.dark;
    final fg = macTheme.typography.body.color;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.md,
        vertical: spacing.sm - 2,
      ),
      decoration: BoxDecoration(
        color: tokens.editorChromeBackground.withValues(
          alpha: isDark ? 0.88 : 0.92,
        ),
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: Border.all(color: tokens.panelBorder),
      ),
      child: Row(
        children: [
          _statusProgressIndicator(exportStatus.progress),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Text(
              _exportProgressText(l10n, exportStatus.progress),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typography.value.copyWith(color: fg),
            ),
          ),
          if (exportStatus.onShowDetails != null ||
              exportStatus.onCancel != null) ...[
            SizedBox(width: spacing.md),
            Wrap(
              spacing: spacing.md,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (exportStatus.onShowDetails != null)
                  _MacTextAction(
                    label: l10n.showProgress,
                    onPressed: exportStatus.onShowDetails!,
                    color: tokens.brand,
                  ),
                if (exportStatus.onCancel != null &&
                    !exportStatus.cancelRequested)
                  _MacTextAction(
                    label: l10n.cancel,
                    onPressed: exportStatus.onCancel!,
                    color: tokens.noticeError.foreground,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _WinNoticeLane extends StatelessWidget {
  const _WinNoticeLane({super.key, required this.notice});

  final ToolbarNoticePresentation notice;

  @override
  Widget build(BuildContext context) {
    final theme = fluent.FluentTheme.of(context);
    final materialTheme = Theme.of(context);
    final spacing = materialTheme.appSpacing;
    final chrome = materialTheme.appEditorChrome;
    final colors = _noticeColors(context, notice.tone);
    final icon = _winNoticeIcon(notice.tone);

    return fluent.Container(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.md,
        vertical: spacing.sm - 2,
      ),
      decoration: fluent.BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: colors.border == null
            ? null
            : fluent.Border.all(color: colors.border!),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: colors.foreground),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Text(
              notice.message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.caption?.copyWith(
                color: colors.foreground,
                fontWeight:
                    notice.tone == ToolbarMessageTone.warning ||
                        notice.tone == ToolbarMessageTone.error
                    ? FontWeight.w600
                    : FontWeight.w500,
              ),
            ),
          ),
          if (notice.action != null || notice.onDismiss != null) ...[
            SizedBox(width: spacing.md),
            _WinLaneActions(
              action: notice.action,
              onDismiss: notice.onDismiss,
              dismissColor: colors.foreground,
            ),
          ],
        ],
      ),
    );
  }
}

class _WinExportLane extends StatelessWidget {
  const _WinExportLane({
    super.key,
    required this.exportStatus,
    required this.l10n,
  });

  final ToolbarExportStatusPresentation exportStatus;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = fluent.FluentTheme.of(context);
    final materialTheme = Theme.of(context);
    final spacing = materialTheme.appSpacing;
    final tokens = materialTheme.appTokens;
    final chrome = materialTheme.appEditorChrome;

    return fluent.Container(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.md,
        vertical: spacing.sm - 2,
      ),
      decoration: fluent.BoxDecoration(
        color: tokens.editorChromeBackground.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: fluent.Border.all(color: tokens.panelBorder),
      ),
      child: Row(
        children: [
          _statusProgressIndicator(exportStatus.progress),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Text(
              _exportProgressText(l10n, exportStatus.progress),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.caption?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (exportStatus.onShowDetails != null ||
              exportStatus.onCancel != null) ...[
            SizedBox(width: spacing.md),
            Wrap(
              spacing: spacing.md,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (exportStatus.onShowDetails != null)
                  _WinTextAction(
                    label: l10n.showProgress,
                    onPressed: exportStatus.onShowDetails!,
                    color: tokens.brand,
                  ),
                if (exportStatus.onCancel != null &&
                    !exportStatus.cancelRequested)
                  _WinTextAction(
                    label: l10n.cancel,
                    onPressed: exportStatus.onCancel!,
                    color: tokens.noticeError.foreground,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FallbackNoticeLane extends StatelessWidget {
  const _FallbackNoticeLane({super.key, required this.notice});

  final ToolbarNoticePresentation notice;

  @override
  Widget build(BuildContext context) {
    final spacing = context.appSpacing;
    final typography = context.appTypography;
    final chrome = context.appEditorChrome;
    final colors = _noticeColors(context, notice.tone);
    final icon = _fallbackNoticeIcon(notice.tone);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.md,
        vertical: spacing.sm - 2,
      ),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: colors.border == null
            ? null
            : Border.all(color: colors.border!),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: colors.foreground),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Text(
              notice.message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: typography.bodyMuted.copyWith(
                color: colors.foreground,
                fontWeight:
                    notice.tone == ToolbarMessageTone.warning ||
                        notice.tone == ToolbarMessageTone.error
                    ? FontWeight.w600
                    : FontWeight.w500,
              ),
            ),
          ),
          if (notice.action != null || notice.onDismiss != null) ...[
            SizedBox(width: spacing.md),
            _FallbackLaneActions(
              action: notice.action,
              onDismiss: notice.onDismiss,
              dismissColor: colors.foreground,
            ),
          ],
        ],
      ),
    );
  }
}

class _FallbackExportLane extends StatelessWidget {
  const _FallbackExportLane({
    super.key,
    required this.exportStatus,
    required this.l10n,
  });

  final ToolbarExportStatusPresentation exportStatus;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final typography = theme.appTypography;
    final tokens = theme.appTokens;
    final chrome = theme.appEditorChrome;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: spacing.md,
        vertical: spacing.sm - 2,
      ),
      decoration: BoxDecoration(
        color: tokens.editorChromeBackground,
        borderRadius: BorderRadius.circular(chrome.controlRadius),
        border: Border.all(color: tokens.panelBorder),
      ),
      child: Row(
        children: [
          _statusProgressIndicator(exportStatus.progress),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Text(
              _exportProgressText(l10n, exportStatus.progress),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: typography.value,
            ),
          ),
          if (exportStatus.onShowDetails != null ||
              exportStatus.onCancel != null) ...[
            SizedBox(width: spacing.md),
            Wrap(
              spacing: spacing.md,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (exportStatus.onShowDetails != null)
                  _FallbackTextAction(
                    label: l10n.showProgress,
                    onPressed: exportStatus.onShowDetails!,
                    color: tokens.brand,
                  ),
                if (exportStatus.onCancel != null &&
                    !exportStatus.cancelRequested)
                  _FallbackTextAction(
                    label: l10n.cancel,
                    onPressed: exportStatus.onCancel!,
                    color: theme.colorScheme.error,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MacLaneActions extends StatelessWidget {
  const _MacLaneActions({
    required this.action,
    required this.onDismiss,
    required this.dismissColor,
  });

  final ToolbarMessageAction? action;
  final VoidCallback? onDismiss;
  final Color dismissColor;

  @override
  Widget build(BuildContext context) {
    final macTheme = MacosTheme.of(context);
    final spacing = context.appSpacing;
    return Wrap(
      spacing: spacing.md,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (action != null)
          _MacTextAction(
            label: action!.label,
            onPressed: action!.onPressed,
            color: macTheme.primaryColor,
          ),
        if (onDismiss != null)
          MacosIconButton(
            icon: MacosIcon(
              CupertinoIcons.xmark,
              size: 13,
              color: dismissColor,
            ),
            onPressed: onDismiss,
            boxConstraints: const BoxConstraints.tightFor(
              width: 24,
              height: 24,
            ),
          ),
      ],
    );
  }
}

class _WinLaneActions extends StatelessWidget {
  const _WinLaneActions({
    required this.action,
    required this.onDismiss,
    required this.dismissColor,
  });

  final ToolbarMessageAction? action;
  final VoidCallback? onDismiss;
  final Color dismissColor;

  @override
  Widget build(BuildContext context) {
    final theme = fluent.FluentTheme.of(context);
    final spacing = Theme.of(context).appSpacing;
    return Wrap(
      spacing: spacing.md,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (action != null)
          _WinTextAction(
            label: action!.label,
            onPressed: action!.onPressed,
            color: theme.accentColor,
          ),
        if (onDismiss != null)
          fluent.IconButton(
            icon: Icon(fluent.FluentIcons.clear, size: 13, color: dismissColor),
            onPressed: onDismiss,
          ),
      ],
    );
  }
}

class _FallbackLaneActions extends StatelessWidget {
  const _FallbackLaneActions({
    required this.action,
    required this.onDismiss,
    required this.dismissColor,
  });

  final ToolbarMessageAction? action;
  final VoidCallback? onDismiss;
  final Color dismissColor;

  @override
  Widget build(BuildContext context) {
    final spacing = context.appSpacing;
    final brand = context.appTokens.brand;
    return Wrap(
      spacing: spacing.md,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (action != null)
          _FallbackTextAction(
            label: action!.label,
            onPressed: action!.onPressed,
            color: brand,
          ),
        if (onDismiss != null)
          GestureDetector(
            onTap: onDismiss,
            child: Icon(Icons.close, size: 14, color: dismissColor),
          ),
      ],
    );
  }
}

class _MacTextAction extends StatelessWidget {
  const _MacTextAction({
    required this.label,
    required this.onPressed,
    required this.color,
  });

  final String label;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final typography = context.appTypography;
    return GestureDetector(
      onTap: onPressed,
      child: Text(label, style: typography.value.copyWith(color: color)),
    );
  }
}

class _WinTextAction extends StatelessWidget {
  const _WinTextAction({
    required this.label,
    required this.onPressed,
    required this.color,
  });

  final String label;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = fluent.FluentTheme.of(context);
    final typography = Theme.of(context).appTypography;
    return GestureDetector(
      onTap: onPressed,
      child: Text(
        label,
        style: (theme.typography.caption ?? typography.caption).copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _FallbackTextAction extends StatelessWidget {
  const _FallbackTextAction({
    required this.label,
    required this.onPressed,
    required this.color,
  });

  final String label;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final typography = context.appTypography;
    return GestureDetector(
      onTap: onPressed,
      child: Text(
        label,
        style: typography.value.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

AppToneColors _noticeColors(BuildContext context, ToolbarMessageTone tone) {
  final tokens = Theme.of(context).appTokens;
  return switch (tone) {
    ToolbarMessageTone.info => tokens.noticeInfo,
    ToolbarMessageTone.success => tokens.noticeSuccess,
    ToolbarMessageTone.warning => tokens.noticeWarning,
    ToolbarMessageTone.error => tokens.noticeError,
  };
}

IconData _macNoticeIcon(ToolbarMessageTone tone) {
  return switch (tone) {
    ToolbarMessageTone.info => CupertinoIcons.info_circle,
    ToolbarMessageTone.success => CupertinoIcons.check_mark_circled_solid,
    ToolbarMessageTone.warning => CupertinoIcons.exclamationmark_triangle,
    ToolbarMessageTone.error => CupertinoIcons.exclamationmark_triangle,
  };
}

IconData _winNoticeIcon(ToolbarMessageTone tone) {
  return switch (tone) {
    ToolbarMessageTone.info => fluent.FluentIcons.info,
    ToolbarMessageTone.success => fluent.FluentIcons.accept,
    ToolbarMessageTone.warning => fluent.FluentIcons.warning,
    ToolbarMessageTone.error => fluent.FluentIcons.error,
  };
}

IconData _fallbackNoticeIcon(ToolbarMessageTone tone) {
  return switch (tone) {
    ToolbarMessageTone.info => Icons.info_outline,
    ToolbarMessageTone.success => Icons.check_circle_outline,
    ToolbarMessageTone.warning => Icons.warning_amber_rounded,
    ToolbarMessageTone.error => Icons.error_outline,
  };
}

Widget _statusProgressIndicator(double? progress) {
  final clamped = progress?.clamp(0.0, 1.0);
  if (clamped == null) {
    return const CupertinoActivityIndicator(radius: 6);
  }
  return CupertinoActivityIndicator.partiallyRevealed(
    progress: clamped,
    radius: 6,
  );
}

String _exportProgressText(AppLocalizations l10n, double? progress) {
  if (progress == null) return l10n.exporting;
  final clamped = progress.clamp(0.0, 1.0);
  final pct = (clamped * 100).round();
  return '${l10n.exporting} $pct%';
}

Widget _pill(
  BuildContext context, {
  required IconData icon,
  required String text,
  bool pulsingDot = false,
}) {
  final theme = Theme.of(context);
  final spacing = context.appSpacing;
  final typography = context.appTypography;
  final chrome = theme.appEditorChrome;
  final controlFill =
      theme.inputDecorationTheme.fillColor ??
      theme.colorScheme.secondaryContainer;
  return Container(
    padding: EdgeInsets.symmetric(horizontal: spacing.sm, vertical: spacing.xs),
    decoration: BoxDecoration(
      color: pulsingDot
          ? theme.colorScheme.primary.withValues(alpha: 0.14)
          : controlFill,
      borderRadius: BorderRadius.circular(chrome.pillRadius),
      border: Border.all(
        color: pulsingDot
            ? theme.colorScheme.primary.withValues(alpha: 0.24)
            : theme.dividerColor.withValues(alpha: 0.1),
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pulsingDot
            ? _PulseDot(color: theme.colorScheme.primary, size: 8)
            : Icon(icon, size: 12, color: theme.colorScheme.primary),
        SizedBox(width: spacing.xs + 1),
        Text(
          text,
          style: typography.value.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

Widget _pillWin(
  BuildContext context,
  fluent.FluentThemeData theme, {
  required IconData icon,
  required String text,
  required bool danger,
}) {
  final colors = danger
      ? context.appTokens.noticeError
      : context.appTokens.noticeInfo;
  final spacing = context.appSpacing;
  final typography = context.appTypography;
  final chrome = context.appEditorChrome;

  return fluent.Container(
    padding: EdgeInsets.symmetric(horizontal: spacing.sm, vertical: spacing.xs),
    decoration: fluent.BoxDecoration(
      color: colors.background,
      borderRadius: BorderRadius.circular(chrome.pillRadius),
      border: fluent.Border.all(
        color: colors.border ?? colors.foreground.withValues(alpha: 0.16),
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: colors.foreground),
        SizedBox(width: spacing.xs + 1),
        Text(
          text,
          style: (theme.typography.caption ?? typography.caption).copyWith(
            color: colors.foreground,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

Widget _pillFallback(
  BuildContext context, {
  required IconData icon,
  required String text,
}) {
  final spacing = context.appSpacing;
  final typography = context.appTypography;
  final colors = icon == Icons.fiber_manual_record
      ? context.appTokens.noticeError
      : context.appTokens.noticeInfo;
  final chrome = context.appEditorChrome;

  return Container(
    padding: EdgeInsets.symmetric(horizontal: spacing.sm, vertical: spacing.xs),
    decoration: BoxDecoration(
      color: colors.background,
      borderRadius: BorderRadius.circular(chrome.pillRadius),
      border: Border.all(
        color: colors.border ?? colors.foreground.withValues(alpha: 0.16),
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: colors.foreground),
        SizedBox(width: spacing.xs + 1),
        Text(
          text,
          style: typography.value.copyWith(
            fontWeight: FontWeight.w700,
            color: colors.foreground,
          ),
        ),
      ],
    ),
  );
}

Widget _simpleButton({
  required BuildContext context,
  required String label,
  required IconData icon,
  required VoidCallback? onPressed,
}) {
  final theme = Theme.of(context);
  final chrome = theme.appEditorChrome;
  final controlFill =
      theme.inputDecorationTheme.fillColor ??
      theme.colorScheme.secondaryContainer;
  return GestureDetector(
    onTap: onPressed,
    child: Opacity(
      opacity: onPressed == null ? 0.5 : 1,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: controlFill,
          borderRadius: BorderRadius.circular(chrome.controlRadius),
          border: Border.all(color: theme.dividerColor.withValues(alpha: 0.1)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 6),
            Text(label, style: theme.appTypography.button),
          ],
        ),
      ),
    ),
  );
}
