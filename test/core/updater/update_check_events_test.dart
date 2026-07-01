import 'package:clingfy/core/updater/update_check_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UpdateCheckEvent.fromMap', () {
    test('parses checking', () {
      final event = UpdateCheckEvent.fromMap(const {'type': 'checking'});
      expect(event, isNotNull);
      expect(event!.status, UpdateCheckStatus.checking);
    });

    test('parses the Windows updateAvailable payload', () {
      final event = UpdateCheckEvent.fromMap(const {
        'type': 'updateAvailable',
        'version': '1.0.5',
        'build': '7',
        'url': 'https://dl.example/Clingfy_Dev_Setup_1.0.5+7.exe',
        'versionFull': '1.0.5+7',
      });
      expect(event, isNotNull);
      expect(event!.status, UpdateCheckStatus.updateAvailable);
      expect(event.version, '1.0.5');
      expect(event.build, '7');
      expect(event.url, 'https://dl.example/Clingfy_Dev_Setup_1.0.5+7.exe');
      expect(event.versionFull, '1.0.5+7');
    });

    test('parses the macOS Sparkle updateAvailable payload (no url)', () {
      final event = UpdateCheckEvent.fromMap(const {
        'type': 'updateAvailable',
        'version': '1.2.0',
        'build': '120',
      });
      expect(event, isNotNull);
      expect(event!.status, UpdateCheckStatus.updateAvailable);
      expect(event.version, '1.2.0');
      expect(event.url, isNull);
      expect(event.versionFull, isNull);
    });

    test('parses noUpdateAvailable', () {
      final event = UpdateCheckEvent.fromMap(const {
        'type': 'noUpdateAvailable',
        'version': '1.0.4',
      });
      expect(event, isNotNull);
      expect(event!.status, UpdateCheckStatus.noUpdateAvailable);
      expect(event.version, '1.0.4');
    });

    test('parses updateError', () {
      final event = UpdateCheckEvent.fromMap(const {
        'type': 'updateError',
        'code': UpdateCheckErrorCodes.feedUnreachable,
        'message': 'feed returned HTTP 503',
      });
      expect(event, isNotNull);
      expect(event!.status, UpdateCheckStatus.error);
      expect(event.code, UpdateCheckErrorCodes.feedUnreachable);
      expect(event.message, 'feed returned HTTP 503');
    });

    test('unknown types parse to null (future native additions)', () {
      expect(UpdateCheckEvent.fromMap(const {'type': 'somethingNew'}), isNull);
      expect(UpdateCheckEvent.fromMap(const {}), isNull);
    });

    test('missing or empty fields become null, never throw', () {
      final event = UpdateCheckEvent.fromMap(const {
        'type': 'updateAvailable',
        'version': '',
        'build': 7, // wrong type — tolerated as null
      });
      expect(event, isNotNull);
      expect(event!.version, isNull);
      expect(event.build, isNull);
      expect(event.url, isNull);
    });
  });
}
