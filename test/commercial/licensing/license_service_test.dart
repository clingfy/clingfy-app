import 'dart:convert';

import 'package:clingfy/commercial/licensing/license_error_codes.dart';
import 'package:clingfy/commercial/licensing/license_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  late Map<String, String> secureStorageValues;

  setUp(() {
    secureStorageValues = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
          final arguments =
              (call.arguments as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{};
          final key = arguments['key']?.toString();
          switch (call.method) {
            case 'write':
              if (key != null) {
                secureStorageValues[key] = arguments['value']?.toString() ?? '';
              }
              return null;
            case 'read':
              if (key == null) {
                return null;
              }
              return secureStorageValues[key];
            case 'delete':
              if (key != null) {
                secureStorageValues.remove(key);
              }
              return null;
            case 'deleteAll':
              secureStorageValues.clear();
              return null;
            case 'readAll':
              return Map<String, String>.from(secureStorageValues);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  test('parses member_since and activated_at when present', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/validate-license');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'valid': true,
          'entitled_pro': true,
          'plan': 'lifetime',
          'is_update_covered': true,
          'trial_exports_remaining': 0,
          'member_since': '2026-02-14T00:00:00Z',
          'activated_at': '2026-02-15T00:00:00Z',
          'updates_expires_at': '2027-02-14T00:00:00Z',
        }),
        200,
      );
    });
    final service = LicenseService(
      httpClient: client,
      hardwareIdProvider: () async => 'hw-test',
    );

    final state = await service.validateLicense('CLINGFY-AAAA-BBBB-CC99');

    expect(state.memberSince, DateTime.parse('2026-02-14T00:00:00Z'));
    expect(state.activatedAt, DateTime.parse('2026-02-15T00:00:00Z'));
    expect(state.updatesExpiresAt, DateTime.parse('2027-02-14T00:00:00Z'));
  });

  test(
    'persists first_activated_at and exposes fallback activated date',
    () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'valid': true,
            'entitled_pro': true,
            'plan': 'lifetime',
            'is_update_covered': true,
            'trial_exports_remaining': 0,
          }),
          200,
        );
      });
      final service = LicenseService(
        httpClient: client,
        hardwareIdProvider: () async => 'hw-test',
      );

      final state = await service.validateLicense('CLINGFY-AAAA-BBBB-CC99');

      expect(secureStorageValues['first_activated_at'], isNotNull);
      expect(state.activatedAt, isNotNull);
    },
  );

  test('first_activated_at fallback is not overwritten once set', () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount += 1;
      if (requestCount == 1) {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'valid': true,
            'entitled_pro': true,
            'plan': 'lifetime',
            'is_update_covered': true,
            'trial_exports_remaining': 0,
            'member_since': '2026-01-10T00:00:00Z',
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode(<String, dynamic>{
          'valid': true,
          'entitled_pro': true,
          'plan': 'lifetime',
          'is_update_covered': true,
          'trial_exports_remaining': 0,
          'member_since': '2026-03-01T00:00:00Z',
        }),
        200,
      );
    });
    final service = LicenseService(
      httpClient: client,
      hardwareIdProvider: () async => 'hw-test',
    );

    await service.validateLicense('CLINGFY-AAAA-BBBB-CC99');
    final firstValue = secureStorageValues['first_activated_at'];
    expect(firstValue, isNotNull);

    await service.validateLicense('CLINGFY-AAAA-BBBB-CC99');
    final secondValue = secureStorageValues['first_activated_at'];

    expect(secondValue, firstValue);
  });

  // --- Server-error grace (the 5xx / 408 / 429 path) -------------------------
  //
  // The asymmetry these cover: a dead socket throws and has always reached the
  // 7-day offline grace, while a 503 returns normally and used to fall through
  // to LICENSE_VALIDATION_FAILED - revoking Pro instantly. An outage was
  // punished harder than having no internet at all.

  /// Seeds a healthy lifetime licence checked [checkedDaysAgo] days ago, so the
  /// offline grace has something real to hand back.
  void seedCachedLifetimeLicence({int checkedDaysAgo = 1}) {
    secureStorageValues['license_key'] = 'CLINGFY-AAAA-BBBB-CC99';
    secureStorageValues['license_data'] = jsonEncode(<String, dynamic>{
      'valid': true,
      'entitled_pro': true,
      'plan': 'lifetime',
      'is_update_covered': true,
      'trial_exports_remaining': 0,
      'updates_expires_at': '2099-01-01T00:00:00Z',
    });
    secureStorageValues['last_check'] = DateTime.now()
        .subtract(Duration(days: checkedDaysAgo))
        .toIso8601String();
  }

  test('a 503 behind an HTML error page keeps a cached licence entitled', () async {
    seedCachedLifetimeLicence();

    // A real ALB with no healthy targets answers exactly this: HTML, not JSON.
    // Asserting it here pins WHY no reason field can be read off a 5xx, so the
    // fix cannot regress into parsing a `reason` that was never sent.
    const albBody =
        '<html><head><title>503 Service Temporarily Unavailable</title></head>'
        '<body><center><h1>503 Service Temporarily Unavailable</h1></center></body></html>';
    expect(
      () => jsonDecode(albBody),
      throwsFormatException,
      reason: 'an ALB 503 body is not JSON, so it carries no reason field',
    );

    final client = MockClient((request) async => http.Response(albBody, 503));
    final service = LicenseService(
      httpClient: client,
      hardwareIdProvider: () async => 'hw-test',
    );

    final state = await service.validateLicense('CLINGFY-AAAA-BBBB-CC99');

    expect(
      state.entitledPro,
      isTrue,
      reason: 'our outage must not revoke a paying customer mid-session',
    );
    expect(state.plan, 'lifetime');
    expect(state.message, 'LICENSE_OFFLINE_CACHED');
  });

  test('a 503 does not overwrite or age the cached licence', () async {
    seedCachedLifetimeLicence();
    final cachedBefore = secureStorageValues['license_data'];
    final lastCheckBefore = secureStorageValues['last_check'];

    final client = MockClient((request) async => http.Response('<html/>', 503));
    final service = LicenseService(
      httpClient: client,
      hardwareIdProvider: () async => 'hw-test',
    );

    await service.validateLicense('CLINGFY-AAAA-BBBB-CC99');

    expect(secureStorageValues['license_data'], cachedBefore);
    expect(
      secureStorageValues['last_check'],
      lastCheckBefore,
      reason:
          'grace must expire 7 days after the last real success, so a stream '
          'of 503s cannot extend the window',
    );
  });

  test('a 503 past the 7-day window stops granting entitlement', () async {
    seedCachedLifetimeLicence(checkedDaysAgo: 8);

    final client = MockClient((request) async => http.Response('<html/>', 503));
    final service = LicenseService(
      httpClient: client,
      hardwareIdProvider: () async => 'hw-test',
    );

    final state = await service.validateLicense('CLINGFY-AAAA-BBBB-CC99');

    expect(state.entitledPro, isFalse);
    expect(state.message, 'LICENSE_INTERNET_REQUIRED');
  });

  test(
    'a 503 with nothing cached asks for internet, not a licence failure',
    () async {
      final client = MockClient(
        (request) async => http.Response('<html/>', 503),
      );
      final service = LicenseService(
        httpClient: client,
        hardwareIdProvider: () async => 'hw-test',
      );

      final state = await service.validateLicense('CLINGFY-AAAA-BBBB-CC99');

      expect(state.entitledPro, isFalse);
      expect(
        state.message,
        'LICENSE_INTERNET_REQUIRED',
        reason:
            'the server never answered, so we cannot claim the licence failed',
      );
    },
  );

  test('a 401 is a verdict and revokes even with a fresh cache', () async {
    seedCachedLifetimeLicence();

    final client = MockClient(
      (request) async => http.Response(
        jsonEncode(<String, dynamic>{'reason': 'LICENSE_REVOKED'}),
        401,
      ),
    );
    final service = LicenseService(
      httpClient: client,
      hardwareIdProvider: () async => 'hw-test',
    );

    final state = await service.validateLicense('CLINGFY-AAAA-BBBB-CC99');

    expect(
      state.entitledPro,
      isFalse,
      reason:
          'a 4xx is the server answering about this licence - a refund or '
          'chargeback must still take effect',
    );
    expect(state.message, 'LICENSE_REVOKED');
  });

  test('408 and 429 are treated as unanswered, not as a verdict', () async {
    for (final status in <int>[408, 429]) {
      secureStorageValues.clear();
      seedCachedLifetimeLicence();

      final client = MockClient((request) async => http.Response('', status));
      final service = LicenseService(
        httpClient: client,
        hardwareIdProvider: () async => 'hw-test',
      );

      final state = await service.validateLicense('CLINGFY-AAAA-BBBB-CC99');

      expect(state.entitledPro, isTrue, reason: 'status $status');
      expect(state.message, 'LICENSE_OFFLINE_CACHED', reason: 'status $status');
    }
  });

  test(
    'a hung backend times out into the grace instead of pending forever',
    () async {
      seedCachedLifetimeLicence();

      // A half-open socket: accepted, never answered. Without a timeout this
      // future never completes and entitlement stays unresolved for the session.
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        return http.Response('{}', 200);
      });
      final service = LicenseService(
        httpClient: client,
        hardwareIdProvider: () async => 'hw-test',
        validateTimeout: const Duration(milliseconds: 50),
      );

      final state = await service.validateLicense('CLINGFY-AAAA-BBBB-CC99');

      expect(state.entitledPro, isTrue);
      expect(state.message, 'LICENSE_OFFLINE_CACHED');
    },
  );

  // --- Whose verdict is it? (#560, and revocation durability) ---------------
  //
  // A 200 or a 4xx is the server answering. Whether it may touch storage
  // depends on WHOSE licence it answered about. Getting this wrong in one
  // direction burns a paying customer's cache; in the other it lets a revoked
  // licence outlive its revocation.

  test('a rejected foreign key leaves the stored licence untouched', () async {
    seedCachedLifetimeLicence();
    final goodData = secureStorageValues['license_data'];
    final lastCheckBefore = secureStorageValues['last_check'];

    final client = MockClient(
      (request) async => http.Response(
        jsonEncode(<String, dynamic>{
          'valid': false,
          'reason': 'LICENSE_NOT_FOUND',
        }),
        200,
      ),
    );
    final service = LicenseService(
      httpClient: client,
      hardwareIdProvider: () async => 'hw-test',
    );

    final state = await service.validateLicense('TYPO-WRONG-KEY-9999');

    expect(
      state.message,
      'LICENSE_NOT_FOUND',
      reason: 'the caller still needs to be told the typed key was rejected',
    );
    expect(
      secureStorageValues['license_key'],
      'CLINGFY-AAAA-BBBB-CC99',
      reason: 'a typo in the paywall must not replace a working licence',
    );
    expect(secureStorageValues['license_data'], goodData);
    expect(
      secureStorageValues['last_check'],
      lastCheckBefore,
      reason:
          'a question about a key we do not hold teaches us nothing about '
          'ours, so it must not advance the grace clock',
    );
  });

  test('a rejected foreign key cannot extend the offline window', () async {
    // Already OUTSIDE the 7-day window. If a rejected foreign key were
    // persisted it would stamp `last_check` with now, pulling the user back
    // inside the window and handing them a fresh grace period for free.
    seedCachedLifetimeLicence(checkedDaysAgo: 8);

    final reject = MockClient(
      (request) async => http.Response(
        jsonEncode(<String, dynamic>{'valid': false, 'reason': 'NOPE'}),
        200,
      ),
    );
    await LicenseService(
      httpClient: reject,
      hardwareIdProvider: () async => 'hw-test',
    ).validateLicense('SOME-OTHER-KEY-0000');

    final down = MockClient((request) async => http.Response('<html/>', 503));
    final state = await LicenseService(
      httpClient: down,
      hardwareIdProvider: () async => 'hw-test',
    ).validateLicense('CLINGFY-AAAA-BBBB-CC99');

    expect(
      state.message,
      'LICENSE_INTERNET_REQUIRED',
      reason:
          'typing nonsense into the paywall must not reset the grace '
          'clock and buy another 7 days offline',
    );
  });

  test(
    'revoking the stored key via 200 lands and survives a later outage',
    () async {
      seedCachedLifetimeLicence();

      final revoke = MockClient(
        (request) async => http.Response(
          jsonEncode(<String, dynamic>{
            'valid': false,
            'reason': 'LICENSE_REVOKED',
          }),
          200,
        ),
      );
      await LicenseService(
        httpClient: revoke,
        hardwareIdProvider: () async => 'hw-test',
      ).validateLicense('CLINGFY-AAAA-BBBB-CC99');

      final down = MockClient((request) async => http.Response('<html/>', 503));
      final state = await LicenseService(
        httpClient: down,
        hardwareIdProvider: () async => 'hw-test',
      ).validateLicense('CLINGFY-AAAA-BBBB-CC99');

      expect(
        state.entitledPro,
        isFalse,
        reason: 'the cache must not resurrect a licence the server revoked',
      );
    },
  );

  test('revoking the stored key via 401 also lands', () async {
    seedCachedLifetimeLicence();

    final revoke = MockClient(
      (request) async => http.Response(
        jsonEncode(<String, dynamic>{'reason': 'LICENSE_REVOKED'}),
        401,
      ),
    );
    final revoked = await LicenseService(
      httpClient: revoke,
      hardwareIdProvider: () async => 'hw-test',
    ).validateLicense('CLINGFY-AAAA-BBBB-CC99');
    expect(revoked.message, 'LICENSE_REVOKED');

    final down = MockClient((request) async => http.Response('<html/>', 503));
    final afterOutage = await LicenseService(
      httpClient: down,
      hardwareIdProvider: () async => 'hw-test',
    ).validateLicense('CLINGFY-AAAA-BBBB-CC99');

    expect(
      afterOutage.entitledPro,
      isFalse,
      reason:
          'a 4xx revocation used to leave the cache saying valid lifetime, '
          'so the next 503 handed Pro back for up to 7 more days',
    );

    final offline = MockClient((request) async => throw Exception('no net'));
    final whollyOffline = await LicenseService(
      httpClient: offline,
      hardwareIdProvider: () async => 'hw-test',
    ).validateLicense('CLINGFY-AAAA-BBBB-CC99');

    expect(
      whollyOffline.entitledPro,
      isFalse,
      reason: 'same hole via the throw path, which predates the 5xx one',
    );
  });

  test('a 401 about a foreign key does not revoke ours', () async {
    seedCachedLifetimeLicence();

    final reject = MockClient(
      (request) async => http.Response(
        jsonEncode(<String, dynamic>{'reason': 'LICENSE_NOT_FOUND'}),
        401,
      ),
    );
    await LicenseService(
      httpClient: reject,
      hardwareIdProvider: () async => 'hw-test',
    ).validateLicense('NOT-OUR-KEY-1234');

    final down = MockClient((request) async => http.Response('<html/>', 503));
    final state = await LicenseService(
      httpClient: down,
      hardwareIdProvider: () async => 'hw-test',
    ).validateLicense('CLINGFY-AAAA-BBBB-CC99');

    expect(
      state.entitledPro,
      isTrue,
      reason: 'a 4xx about a key we do not hold says nothing about ours',
    );
  });

  test('key matching ignores case and surrounding whitespace', () async {
    seedCachedLifetimeLicence();

    final revoke = MockClient(
      (request) async => http.Response(
        jsonEncode(<String, dynamic>{
          'valid': false,
          'reason': 'LICENSE_REVOKED',
        }),
        200,
      ),
    );
    await LicenseService(
      httpClient: revoke,
      hardwareIdProvider: () async => 'hw-test',
    ).validateLicense('  clingfy-aaaa-bbbb-cc99  ');

    final down = MockClient((request) async => http.Response('<html/>', 503));
    final state = await LicenseService(
      httpClient: down,
      hardwareIdProvider: () async => 'hw-test',
    ).validateLicense('CLINGFY-AAAA-BBBB-CC99');

    expect(
      state.entitledPro,
      isFalse,
      reason:
          'retyping your own key in different case is the same licence, '
          'so its revocation still has to land',
    );
  });

  test('a valid answer for a different key is a deliberate swap', () async {
    seedCachedLifetimeLicence();

    final client = MockClient(
      (request) async => http.Response(
        jsonEncode(<String, dynamic>{
          'valid': true,
          'entitled_pro': true,
          'plan': 'subscription',
          'is_update_covered': true,
          'trial_exports_remaining': 0,
        }),
        200,
      ),
    );
    final state = await LicenseService(
      httpClient: client,
      hardwareIdProvider: () async => 'hw-test',
    ).validateLicense('CLINGFY-NEW-KEY-7777');

    expect(state.entitledPro, isTrue);
    expect(secureStorageValues['license_key'], 'CLINGFY-NEW-KEY-7777');
  });

  test('a real key whose updates lapsed is still stored', () async {
    // The load-bearing half of the accept rule: gate on `valid`, NOT on
    // `entitled_pro`. A genuine lifetime key past its update window answers
    // valid-but-not-entitled. If that were unstorable the owner could never
    // reach the "Extend updates" action without retyping their key on every
    // single launch, because `hasLinkedKey` reads the stored key.
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode(<String, dynamic>{
          'valid': true,
          'entitled_pro': false,
          'plan': 'lifetime',
          'is_update_covered': false,
          'trial_exports_remaining': 0,
          'updates_expires_at': '2020-01-01T00:00:00Z',
        }),
        200,
      ),
    );
    final state = await LicenseService(
      httpClient: client,
      hardwareIdProvider: () async => 'hw-test',
    ).validateLicense('CLINGFY-LAPSED-KEY-01');

    expect(state.entitledPro, isFalse);
    expect(
      secureStorageValues['license_key'],
      'CLINGFY-LAPSED-KEY-01',
      reason: 'the key is real; only its update coverage lapsed',
    );
  });

  test('a device-level answer is cached when no key is stored', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode(<String, dynamic>{
          'valid': false,
          'plan': 'trial',
          'trial_exports_remaining': 3,
        }),
        200,
      ),
    );
    final state = await LicenseService(
      httpClient: client,
      hardwareIdProvider: () async => 'hw-test',
    ).validateLicense(null);

    expect(state.trialExportsRemaining, 3);
    expect(
      secureStorageValues['license_data'],
      isNotNull,
      reason:
          'the trial answer is keyed on hardware_id and is the only '
          'answer there is, so it has to be cacheable',
    );
  });

  test('a device-level answer never overwrites a stored licence', () async {
    seedCachedLifetimeLicence();
    final goodData = secureStorageValues['license_data'];

    final client = MockClient(
      (request) async => http.Response(
        jsonEncode(<String, dynamic>{
          'valid': false,
          'plan': 'starter',
          'trial_exports_remaining': 0,
        }),
        200,
      ),
    );
    await LicenseService(
      httpClient: client,
      hardwareIdProvider: () async => 'hw-test',
    ).validateLicense(null);

    expect(secureStorageValues['license_data'], goodData);
    expect(secureStorageValues['license_key'], 'CLINGFY-AAAA-BBBB-CC99');
  });

  group('isUnverified', () {
    test('is true only for the two grace-path outcomes', () {
      expect(
        LicenseState.error(LicenseErrorCodes.offlineCached).isUnverified,
        isTrue,
      );
      expect(
        LicenseState.error(LicenseErrorCodes.internetRequired).isUnverified,
        isTrue,
      );
      for (final verdict in <String>[
        LicenseErrorCodes.validationFailed,
        LicenseErrorCodes.notEntitled,
        LicenseErrorCodes.notFound,
        'LICENSE_REVOKED',
      ]) {
        expect(
          LicenseState.error(verdict).isUnverified,
          isFalse,
          reason: verdict,
        );
      }
    });
  });

  group('isTransientStatus', () {
    test('5xx, 408 and 429 mean ask again later', () {
      for (final status in <int>[500, 502, 503, 504, 408, 429]) {
        expect(
          LicenseService.isTransientStatus(status),
          isTrue,
          reason: 'status $status',
        );
      }
    });

    test('a verdict about the licence is not transient', () {
      for (final status in <int>[400, 401, 403, 404, 409, 410, 422]) {
        expect(
          LicenseService.isTransientStatus(status),
          isFalse,
          reason: 'status $status',
        );
      }
    });
  });

  group('normalizeHardwareGuid', () {
    test('strips braces and lower-cases a SQMClient-style GUID', () {
      expect(
        LicenseService.normalizeHardwareGuid(
          '{372DD4A8-3A4A-4ED3-8CCD-6CDD5DE3F589}',
        ),
        '372dd4a8-3a4a-4ed3-8ccd-6cdd5de3f589',
      );
    });

    test('passes through an already-canonical MachineGuid unchanged', () {
      expect(
        LicenseService.normalizeHardwareGuid(
          'd13bbf9b-c256-4520-9613-d705beb21ec4',
        ),
        'd13bbf9b-c256-4520-9613-d705beb21ec4',
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        LicenseService.normalizeHardwareGuid('  ABCD-1234  '),
        'abcd-1234',
      );
    });

    test('returns null for null input', () {
      expect(LicenseService.normalizeHardwareGuid(null), isNull);
    });

    test('returns null for empty or whitespace-only input', () {
      expect(LicenseService.normalizeHardwareGuid(''), isNull);
      expect(LicenseService.normalizeHardwareGuid('   '), isNull);
      expect(LicenseService.normalizeHardwareGuid('{}'), isNull);
    });
  });
}
