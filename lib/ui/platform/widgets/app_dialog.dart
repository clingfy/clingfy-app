import 'dart:math' as math;

import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/platform/widgets/app_icon_button.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:macos_ui/macos_ui.dart';

class AppDialog {
  static Future<void> alert(
    BuildContext context, {
    required String title,
    required String message,
    String? okLabel,
  }) async {
    await show<void>(
      context,
      title: title,
      content: Text(message),
      primaryLabel: okLabel,
      secondaryLabel: null,
    );
  }

  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String? confirmLabel,
    String? cancelLabel,
    bool? primaryResult,
    bool? secondaryResult,
  }) async {
    final r = await show<bool>(
      context,
      title: title,
      content: Text(message),
      primaryLabel: confirmLabel,
      secondaryLabel: cancelLabel,
      primaryResult: primaryResult ?? true,
      secondaryResult: secondaryResult ?? false,
    );
    return r ?? false;
  }

  static Future<T?> show<T>(
    BuildContext context, {
    required String title,
    Widget? content,
    String? primaryLabel,
    String? secondaryLabel,
    T? primaryResult,
    T? secondaryResult,
    T Function()? primaryBuilder,
    T Function()? secondaryBuilder,
    bool barrierDismissible = true,
    double? maxWidth,
    bool showCloseButton = false,
    T? closeResult,
    Key? closeButtonKey,
  }) async {
    final body = content ?? const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final resolvedPrimaryLabel = primaryLabel ?? l10n.ok;
    final resolvedSecondaryLabel = secondaryLabel;

    T? readPrimary() =>
        primaryBuilder != null ? primaryBuilder() : primaryResult;
    T? readSecondary() =>
        secondaryBuilder != null ? secondaryBuilder() : secondaryResult;

    if (isMac()) {
      return showMacosAlertDialog<T>(
        context: context,
        barrierDismissible: barrierDismissible,
        builder: (ctx) => _MacosDialogShell(
          title: title,
          body: body,
          primaryLabel: resolvedPrimaryLabel,
          secondaryLabel: resolvedSecondaryLabel,
          onPrimaryPressed: () => Navigator.of(ctx).pop(readPrimary()),
          onSecondaryPressed: resolvedSecondaryLabel == null
              ? null
              : () => Navigator.of(ctx).pop(readSecondary()),
          onClosePressed: showCloseButton
              ? () => Navigator.of(ctx).pop(closeResult)
              : null,
          closeButtonKey: closeButtonKey,
          maxWidth: maxWidth ?? 420,
        ),
      );
    }

    if (isWindows()) {
      return fluent.showDialog<T>(
        context: context,
        barrierDismissible: barrierDismissible,
        builder: (ctx) => fluent.ContentDialog(
          title: Row(
            children: [
              Expanded(child: Text(title)),
              if (showCloseButton)
                AppIconButton(
                  key: closeButtonKey,
                  tooltip: l10n.cancel,
                  icon: CupertinoIcons.xmark,
                  onPressed: () => Navigator.of(ctx).pop(closeResult),
                ),
            ],
          ),
          content: body,
          actions: [
            if (resolvedSecondaryLabel != null)
              fluent.Button(
                onPressed: () => Navigator.of(ctx).pop(readSecondary()),
                child: _DialogActionLabel(
                  label: resolvedSecondaryLabel,
                  minWidth: _measureDialogActionMinWidth(
                    ctx,
                    resolvedSecondaryLabel,
                  ),
                ),
              ),
            fluent.FilledButton(
              onPressed: () => Navigator.of(ctx).pop(readPrimary()),
              child: _DialogActionLabel(
                label: resolvedPrimaryLabel,
                minWidth: _measureDialogActionMinWidth(
                  ctx,
                  resolvedPrimaryLabel,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Expanded(child: Text(title)),
            if (showCloseButton)
              AppIconButton(
                key: closeButtonKey,
                tooltip: l10n.cancel,
                icon: CupertinoIcons.xmark,
                onPressed: () => Navigator.of(ctx).pop(closeResult),
              ),
          ],
        ),
        content: body,
        actions: [
          if (resolvedSecondaryLabel != null)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(readSecondary()),
              child: _DialogActionLabel(
                label: resolvedSecondaryLabel,
                minWidth: _measureDialogActionMinWidth(
                  ctx,
                  resolvedSecondaryLabel,
                ),
              ),
            ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(readPrimary()),
            child: _DialogActionLabel(
              label: resolvedPrimaryLabel,
              minWidth: _measureDialogActionMinWidth(ctx, resolvedPrimaryLabel),
            ),
          ),
        ],
      ),
    );
  }

  static double _measureDialogActionMinWidth(
    BuildContext context,
    String label,
  ) {
    final defaultStyle = DefaultTextStyle.of(context).style;
    final textScaler =
        MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;

    final painter = TextPainter(
      text: TextSpan(text: label, style: defaultStyle),
      textDirection: Directionality.of(context),
      textScaler: textScaler,
      maxLines: 1,
    )..layout();

    // Add horizontal breathing room for button padding.
    return math.max(88, painter.width + 28);
  }
}

class _MacosDialogShell extends StatelessWidget {
  const _MacosDialogShell({
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimaryPressed,
    required this.maxWidth,
    this.secondaryLabel,
    this.onSecondaryPressed,
    this.onClosePressed,
    this.closeButtonKey,
  });

  final String title;
  final Widget body;
  final String primaryLabel;
  final String? secondaryLabel;
  final VoidCallback onPrimaryPressed;
  final VoidCallback? onSecondaryPressed;
  final VoidCallback? onClosePressed;
  final double maxWidth;
  final Key? closeButtonKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = context.appSpacing;
    final typography = context.appTypography;
    final brightness = MacosTheme.brightnessOf(context);

    final outerBorderColor = brightness.resolve(
      Colors.black.withValues(alpha: 0.23),
      Colors.black.withValues(alpha: 0.76),
    );
    final innerBorderColor = brightness.resolve(
      Colors.white.withValues(alpha: 0.45),
      Colors.white.withValues(alpha: 0.15),
    );

    final backgroundColor = theme.appTokens.editorChromeBackground;

    final contentPadding = EdgeInsets.fromLTRB(
      spacing.lg,
      spacing.lg,
      spacing.lg,
      16,
    );

    return Dialog(
      backgroundColor: backgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(width: 2, color: innerBorderColor),
          borderRadius: const BorderRadius.all(Radius.circular(12)),
        ),
        foregroundDecoration: BoxDecoration(
          border: Border.all(width: 1, color: outerBorderColor),
          borderRadius: const BorderRadius.all(Radius.circular(12)),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: maxWidth,
            maxWidth: maxWidth,
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: Stack(
            children: [
              Padding(
                padding: contentPadding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: 64,
                        maxWidth: 64,
                      ),
                      child: const MacosIcon(
                        CupertinoIcons.exclamationmark_bubble,
                      ),
                    ),
                    SizedBox(height: spacing.lg),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: typography.panelTitle,
                    ),
                    SizedBox(height: spacing.md - 2),
                    Flexible(
                      child: SingleChildScrollView(
                        child: DefaultTextStyle(
                          style: typography.body,
                          textAlign: TextAlign.center,
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: body,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: spacing.lg),
                    Row(
                      children: [
                        if (secondaryLabel != null &&
                            onSecondaryPressed != null) ...[
                          Expanded(
                            child: AppButton(
                              label: secondaryLabel!,
                              variant: AppButtonVariant.secondary,
                              onPressed: onSecondaryPressed,
                              expand: true,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: AppButton(
                            label: primaryLabel,
                            onPressed: onPrimaryPressed,
                            expand: true,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (onClosePressed != null)
                Positioned(
                  top: 10,
                  right: 10,
                  child: AppIconButton(
                    key: closeButtonKey ?? const Key('dialog_close'),
                    tooltip: AppLocalizations.of(context)!.cancel,
                    icon: CupertinoIcons.xmark,
                    onPressed: onClosePressed,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogActionLabel extends StatelessWidget {
  const _DialogActionLabel({required this.label, required this.minWidth});

  final String label;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth),
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.fade,
        textAlign: TextAlign.center,
      ),
    );
  }
}
