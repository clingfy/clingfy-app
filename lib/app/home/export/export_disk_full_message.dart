import 'package:clingfy/core/bridges/native_error_codes.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:flutter/services.dart';

/// Renders a friendly, user-actionable message for the `EXPORT_DISK_FULL`
/// PlatformException returned by the native screen pre-pass when it estimates
/// the intermediate render won't fit on disk.
///
/// The native side already builds a self-contained human string in
/// `e.message` (covers logs, Sentry, and any fallback dialog). This helper
/// re-renders that message in the user's locale using the structured byte
/// counts in `e.details.context.{estimatedRequiredTempFormatted,
/// availableTempFormatted, shortfallTempFormatted}`, and falls back
/// gracefully when those fields are missing or malformed.
class ExportDiskFullMessage {
  /// Returns the localized message for an `EXPORT_DISK_FULL` exception, or
  /// `null` if `e` is not an `EXPORT_DISK_FULL` exception.
  static String? forException(PlatformException e, AppLocalizations l10n) {
    if (e.code != NativeErrorCode.exportDiskFull) return null;

    final parts = _extractFormattedBytes(e.details);
    if (parts == null) {
      // Native always sends details for disk-full, but fall back to the
      // already-friendly native message rather than the generic key — that
      // string is also user-readable and includes the numbers.
      final msg = e.message;
      if (msg != null && msg.trim().isNotEmpty) return msg;
      return l10n.errExportDiskFullFallback;
    }

    return l10n.errExportDiskFull(
      parts.required,
      parts.available,
      parts.shortfall,
    );
  }
}

class _DiskFullParts {
  const _DiskFullParts({
    required this.required,
    required this.available,
    required this.shortfall,
  });

  final String required;
  final String available;
  final String shortfall;
}

_DiskFullParts? _extractFormattedBytes(Object? details) {
  if (details is! Map) return null;
  final context = details['context'];
  if (context is! Map) return null;

  final required = context['estimatedRequiredTempFormatted'];
  final available = context['availableTempFormatted'];
  final shortfall = context['shortfallTempFormatted'];

  if (required is! String || available is! String || shortfall is! String) {
    return null;
  }
  if (required.isEmpty || available.isEmpty || shortfall.isEmpty) {
    return null;
  }
  return _DiskFullParts(
    required: required,
    available: available,
    shortfall: shortfall,
  );
}
