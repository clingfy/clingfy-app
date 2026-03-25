import 'dart:async';

import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/preview/widgets/inline_preview.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

typedef InlinePreviewHostBuilder =
    Widget Function(PlatformViewCreatedCallback onPlatformViewCreated);

class InlinePreviewPanel extends StatefulWidget {
  const InlinePreviewPanel({
    super.key,
    required this.path,
    required this.onToggleRecord,
    required this.onPreviewHostMounted,
    required this.showLoadingOverlay,
    required this.showSurface,
    this.onClose,
    this.previewHostBuilder,
  });

  final String path;
  final VoidCallback onToggleRecord;
  final Future<void> Function() onPreviewHostMounted;
  final bool showLoadingOverlay;
  final bool showSurface;
  final VoidCallback? onClose;
  final InlinePreviewHostBuilder? previewHostBuilder;

  @override
  State<InlinePreviewPanel> createState() => _InlinePreviewPanelState();
}

class _InlinePreviewPanelState extends State<InlinePreviewPanel> {
  static const _hiddenPreviewCoverKey = Key('inline_preview_hidden_cover');
  StreamSubscription? _playerSub;

  @override
  void initState() {
    super.initState();
    final player = context.read<PlayerController>();
    _playerSub = player.warningStream.listen((msg) {
      if (!mounted) return;
      context.read<HomeUiState>().setNotice(
        HomeUiNotice(message: msg, tone: HomeUiNoticeTone.warning),
      );
    });
  }

  @override
  void dispose() {
    _playerSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = theme.appSpacing;
    final chrome = theme.appEditorChrome;
    final tokens = theme.appTokens;
    final typography = theme.appTypography;
    final player = context.watch<PlayerController>();

    if (!widget.showLoadingOverlay && player.blockingError != null) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            SizedBox(height: spacing.lg),
            Text(
              player.blockingError!,
              style: typography.panelTitle.copyWith(color: Colors.white),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: spacing.xxl),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onClose != null)
                  AppButton(
                    onPressed: widget.onClose,
                    label: AppLocalizations.of(context)!.closePreview,
                    variant: AppButtonVariant.secondary,
                    size: AppButtonSize.compact,
                  ),
                if (widget.path.isNotEmpty &&
                    (player.blockingErrorCode == 'VIDEO_FILE_MISSING' ||
                        player.blockingErrorCode == 'ASSET_INVALID')) ...[
                  SizedBox(width: spacing.lg),
                  AppButton(
                    onPressed: () {
                      context
                          .read<SettingsController>()
                          .workspace
                          .openSaveFolder();
                    },
                    label: AppLocalizations.of(context)!.openFolder,
                    variant: AppButtonVariant.secondary,
                    size: AppButtonSize.compact,
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      key: const Key('inline_preview_frame'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(chrome.panelRadius),
        border: Border.all(color: tokens.panelBorder),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: (widget.previewHostBuilder ?? _defaultPreviewHostBuilder)((
              _,
            ) {
              unawaited(widget.onPreviewHostMounted());
            }),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                key: _hiddenPreviewCoverKey,
                opacity: widget.showSurface ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 180),
                child: Container(color: Colors.black),
              ),
            ),
          ),
          if (widget.showLoadingOverlay)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.78),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                    SizedBox(height: spacing.lg),
                    Text(
                      AppLocalizations.of(context)!.preparingPreview,
                      style: typography.body.copyWith(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _defaultPreviewHostBuilder(PlatformViewCreatedCallback onCreated) {
    return InlinePreview(onPlatformViewCreated: onCreated);
  }
}
