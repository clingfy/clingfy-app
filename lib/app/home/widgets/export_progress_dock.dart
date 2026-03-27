import 'dart:async';

import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/infrastructure/observability/telemetry_service.dart';
import 'package:clingfy/app/home/export/widgets/export_cancel_dialog.dart';
import 'package:clingfy/app/home/export/widgets/export_progress_modal.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

class ExportProgressDock extends StatelessWidget {
  const ExportProgressDock({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<
      PostProcessingController,
      ({
        bool exporting,
        bool inBackground,
        bool cancelRequested,
        double? progress,
      })
    >(
      selector: (_, p) => (
        exporting: p.isExporting,
        inBackground: p.isExportInBackground,
        cancelRequested: p.isExportCancelRequested,
        progress: p.exportProgress,
      ),
      builder: (context, data, _) {
        if (!data.exporting || data.inBackground) {
          return const SizedBox.shrink();
        }

        final post = context.read<PostProcessingController>();
        return ExportProgressModal(
          progress: data.progress,
          cancelRequested: data.cancelRequested,
          onRunInBackground: () {
            unawaited(
              ClingfyTelemetry.addUiBreadcrumb(
                category: 'ui.export',
                message: 'export_run_in_background',
              ),
            );
            post.sendExportToBackground();
          },
          onCancel: () async {
            final confirmed = await ExportCancelDialog.show(
              context,
              controller: post,
            );
            if (confirmed) {
              post.cancelExport();
            }
          },
        );
      },
    );
  }
}
