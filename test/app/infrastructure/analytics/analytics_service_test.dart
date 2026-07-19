import 'dart:convert';

import 'package:clingfy/app/infrastructure/analytics/analytics_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The suite runs in two modes: plain `flutter test` exercises the no-token no-op guards;
/// `flutter test --dart-define=POSTHOG_TOKEN=phc_test` exercises the live payload path. Each
/// test skips in the mode it can't assert in (BuildConfig defines are compile-time).
const bool _hasToken = String.fromEnvironment('POSTHOG_TOKEN') != '';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> sent;
  late http.Client client;

  setUp(() {
    sent = [];
    client = MockClient((request) async {
      sent.add(request);
      return http.Response('{"status": 1}', 200);
    });
    SharedPreferences.setMockInitialValues({});
    ClingfyAnalytics.resetForTest();
  });

  tearDown(ClingfyAnalytics.resetForTest);

  test('without a POSTHOG_TOKEN define the service is inert', () async {
    final prefs = await SharedPreferences.getInstance();
    await ClingfyAnalytics.init(
      enabled: true,
      client: client,
      debugOverride: false,
      prefs: prefs,
    );
    expect(ClingfyAnalytics.isActive, isFalse);
    ClingfyAnalytics.capture('recording:session_start');
    await Future<void>.delayed(Duration.zero);
    expect(sent, isEmpty);
  }, skip: _hasToken ? 'no-token guard — run without --dart-define' : false);

  test('debug mode hard-disables capture even when enabled', () async {
    final prefs = await SharedPreferences.getInstance();
    await ClingfyAnalytics.init(
      enabled: true,
      client: client,
      // ignore: avoid_redundant_argument_values — the guard under test.
      debugOverride: true,
      prefs: prefs,
    );
    expect(ClingfyAnalytics.isActive, isFalse);
    ClingfyAnalytics.capture('desktop:app_launch');
    await Future<void>.delayed(Duration.zero);
    expect(sent, isEmpty);
  });

  test('the user setting turns capture off at runtime', () async {
    final prefs = await SharedPreferences.getInstance();
    await ClingfyAnalytics.init(
      enabled: true,
      client: client,
      debugOverride: false,
      prefs: prefs,
    );
    ClingfyAnalytics.setEnabled(false);
    expect(ClingfyAnalytics.isActive, isFalse);
  });

  test('install id persists across inits (stable anonymous distinct id)', () async {
    final prefs = await SharedPreferences.getInstance();
    await ClingfyAnalytics.init(
      enabled: true,
      client: client,
      debugOverride: false,
      prefs: prefs,
    );
    final first = prefs.getString('analyticsInstallId');
    ClingfyAnalytics.resetForTest();
    await ClingfyAnalytics.init(
      enabled: true,
      client: client,
      debugOverride: false,
      prefs: prefs,
    );
    final second = prefs.getString('analyticsInstallId');
    // Without a token the id is not minted at all (both null); with one it must be stable.
    expect(second, equals(first));
    if (_hasToken) {
      expect(second, isNotNull);
    }
  });

  group('with an injected token (run: flutter test --dart-define=POSTHOG_TOKEN=phc_test)', () {
    const hasToken = _hasToken;

    test('capture posts a sanitized, context-stamped payload', () async {
      final prefs = await SharedPreferences.getInstance();
      await ClingfyAnalytics.init(
        enabled: true,
        client: client,
        debugOverride: false,
        prefs: prefs,
      );
      ClingfyAnalytics.capture(
        'export:job_complete',
        properties: {
          'format': 'mp4',
          'file_path': 'C:/secret/video.mp4', // must be stripped
          'license_key': 'CLFY-SECRET', // must be stripped
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(sent, hasLength(1));
      final body = jsonDecode(sent.single.body) as Map<String, dynamic>;
      expect(body['event'], 'export:job_complete');
      expect(body['distinct_id'], isNotEmpty);
      final props = body['properties'] as Map<String, dynamic>;
      expect(props['format'], 'mp4');
      expect(props.containsKey('file_path'), isFalse);
      expect(props.containsKey('license_key'), isFalse);
      expect(props['product'], 'clingfy_desktop');
      expect(props['source'], 'desktop_client');
      expect(props['analytics_schema_version'], 1);
      expect(props[r'$process_person_profile'], isFalse);
      expect(props['environment'], anyOf('development', 'production'));
    }, skip: hasToken ? false : 'needs --dart-define=POSTHOG_TOKEN=phc_test');
  });
}
