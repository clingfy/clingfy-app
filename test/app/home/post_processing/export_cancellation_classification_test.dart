import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 10.4: EXPORT_CANCELLED classification.
///
/// The structured code is the primary signal; the legacy message sniffing
/// stays for macOS. The CRITICAL audit fix is what is NOT classified
/// anymore: after the user pressed Cancel, an unrelated failure used to be
/// swallowed as a clean cancel via the `_isExportCancelRequested`
/// short-circuit — classification no longer consults that flag at all, so
/// cancel-then-real-failure now surfaces (rethrow + Sentry) like any other
/// export error.
void main() {
  test('EXPORT_CANCELLED code is classified as cancellation', () {
    expect(
      PostProcessingController.isExportCancellationError(
        PlatformException(code: 'EXPORT_CANCELLED'),
      ),
      isTrue,
    );
  });

  test('legacy macOS message sniffing still classifies cancellations', () {
    expect(
      PostProcessingController.isExportCancellationError(
        PlatformException(
          code: 'EXPORT_ERROR',
          message: 'Export was cancelled by the user',
        ),
      ),
      isTrue,
    );
    expect(
      PostProcessingController.isExportCancellationError(
        PlatformException(
          code: 'EXPORT_ERROR',
          message: null,
          details: 'operation aborted',
        ),
      ),
      isTrue,
    );
    // Cancel-ish code spelling (legacy).
    expect(
      PostProcessingController.isExportCancellationError(
        PlatformException(code: 'ExportCancelledError'),
      ),
      isTrue,
    );
  });

  test('a real failure is NOT classified as cancellation — the '
      'cancel-then-real-failure case must surface', () {
    // This exact exception used to be eaten silently when
    // _isExportCancelRequested was true. Classification is now
    // signal-based, so it must come back false regardless of whether the
    // user pressed Cancel.
    expect(
      PostProcessingController.isExportCancellationError(
        PlatformException(
          code: 'EXPORT_ERROR',
          message: 'Sink writer failed: 0xC00D4A44',
        ),
      ),
      isFalse,
    );
    expect(
      PostProcessingController.isExportCancellationError(
        PlatformException(code: 'EXPORT_DISK_FULL', message: 'disk full'),
      ),
      isFalse,
    );
  });

  test('non-PlatformException errors use message sniffing only', () {
    expect(
      PostProcessingController.isExportCancellationError(
        StateError('pipeline interrupted'),
      ),
      isTrue,
    );
    expect(
      PostProcessingController.isExportCancellationError(
        StateError('null texture handle'),
      ),
      isFalse,
    );
  });
}
