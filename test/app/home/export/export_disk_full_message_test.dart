import 'package:clingfy/app/home/export/export_disk_full_message.dart';
import 'package:clingfy/core/bridges/native_error_codes.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<AppLocalizations> _en() async =>
    AppLocalizations.delegate.load(const Locale('en'));

void main() {
  group('ExportDiskFullMessage', () {
    test('returns null for non disk-full codes', () async {
      final l10n = await _en();
      final e = PlatformException(code: NativeErrorCode.exportError);
      expect(ExportDiskFullMessage.forException(e, l10n), isNull);
    });

    test('renders localized message from structured details', () async {
      final l10n = await _en();
      final e = PlatformException(
        code: NativeErrorCode.exportDiskFull,
        message: 'native fallback',
        details: <String, Object?>{
          'context': <String, Object?>{
            'availableTempFormatted': '59 GB',
            'estimatedRequiredTempFormatted': '96 GB',
            'shortfallTempFormatted': '37 GB',
          },
        },
      );
      final msg = ExportDiskFullMessage.forException(e, l10n);
      expect(msg, isNotNull);
      // Locale-independent: just assert the three formatted byte counts
      // appear verbatim in the rendered string.
      expect(msg, contains('59 GB'));
      expect(msg, contains('96 GB'));
      expect(msg, contains('37 GB'));
    });

    test('falls back to native message when details are missing', () async {
      final l10n = await _en();
      final e = PlatformException(
        code: NativeErrorCode.exportDiskFull,
        message: 'Not enough free disk space to render this export.',
      );
      final msg = ExportDiskFullMessage.forException(e, l10n);
      expect(msg, equals('Not enough free disk space to render this export.'));
    });

    test(
      'falls back to localized fallback when both details and message missing',
      () async {
        final l10n = await _en();
        final e = PlatformException(code: NativeErrorCode.exportDiskFull);
        final msg = ExportDiskFullMessage.forException(e, l10n);
        expect(msg, equals(l10n.errExportDiskFullFallback));
      },
    );

    test('falls back when details has malformed types', () async {
      final l10n = await _en();
      final e = PlatformException(
        code: NativeErrorCode.exportDiskFull,
        message: 'native fallback',
        details: <String, Object?>{
          'context': <String, Object?>{
            'availableTempFormatted': 12345, // wrong type
            'estimatedRequiredTempFormatted': '96 GB',
            'shortfallTempFormatted': '37 GB',
          },
        },
      );
      final msg = ExportDiskFullMessage.forException(e, l10n);
      expect(msg, equals('native fallback'));
    });
  });
}
