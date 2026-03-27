import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_dialog.dart';
import 'package:flutter/material.dart';

class ExportCancelDialog {
  static Future<bool> show(
    BuildContext context, {
    required PostProcessingController controller,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final result = await AppDialog.show<bool>(
      context,
      title: l10n.cancelExport,
      content: _ExportCancelDialogBody(
        controller: controller,
        message: l10n.cancelExportConfirm,
      ),
      secondaryLabel: l10n.stopExport,
      primaryLabel: l10n.keepExporting,
      primaryResult: false,
      secondaryResult: true,
    );
    return result ?? false;
  }
}

class _ExportCancelDialogBody extends StatefulWidget {
  const _ExportCancelDialogBody({
    required this.controller,
    required this.message,
  });

  final PostProcessingController controller;
  final String message;

  @override
  State<_ExportCancelDialogBody> createState() =>
      _ExportCancelDialogBodyState();
}

class _ExportCancelDialogBodyState extends State<_ExportCancelDialogBody> {
  bool _didRequestClose = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleExportStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleExportStateChanged();
    });
  }

  @override
  void didUpdateWidget(covariant _ExportCancelDialogBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;

    oldWidget.controller.removeListener(_handleExportStateChanged);
    widget.controller.addListener(_handleExportStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleExportStateChanged();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleExportStateChanged);
    super.dispose();
  }

  void _handleExportStateChanged() {
    if (!mounted || _didRequestClose || widget.controller.isExporting) return;

    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent || !route.isActive) return;

    _didRequestClose = true;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return Text(widget.message);
  }
}
