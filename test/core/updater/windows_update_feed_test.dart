import 'package:clingfy/core/updater/windows_update_feed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('windowsUpdateFeedUrl', () {
    test('joins a bare Front Door domain', () {
      expect(
        windowsUpdateFeedUrl(
          cdnEndpoint: 'clingfy-downloads-dev-x.z02.azurefd.net',
        ),
        'https://clingfy-downloads-dev-x.z02.azurefd.net/downloads/windows/latest-windows.json',
      );
    });

    test('strips an existing scheme and trailing slashes', () {
      expect(
        windowsUpdateFeedUrl(cdnEndpoint: 'https://cdn.example.net/'),
        'https://cdn.example.net/downloads/windows/latest-windows.json',
      );
      expect(
        windowsUpdateFeedUrl(cdnEndpoint: 'http://cdn.example.net//'),
        'https://cdn.example.net/downloads/windows/latest-windows.json',
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        windowsUpdateFeedUrl(cdnEndpoint: '  cdn.example.net '),
        'https://cdn.example.net/downloads/windows/latest-windows.json',
      );
    });

    test('returns null for an empty endpoint (feed not configured)', () {
      expect(windowsUpdateFeedUrl(cdnEndpoint: ''), isNull);
      expect(windowsUpdateFeedUrl(cdnEndpoint: '   '), isNull);
      expect(windowsUpdateFeedUrl(cdnEndpoint: 'https:///'), isNull);
    });

    test('default helper is consistent with the build-time define', () {
      // Environment-agnostic: holds both on bare `flutter test` (define
      // empty -> null) and under --dart-define-from-file (define present
      // -> composed URL).
      expect(
        defaultWindowsUpdateFeedUrl(),
        windowsUpdateFeedUrl(cdnEndpoint: windowsUpdateCdnEndpointDefine),
      );
    });
  });
}
