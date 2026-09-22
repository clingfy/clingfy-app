import 'dart:convert';

import 'package:clingfy/commercial/licensing/license_controller.dart';
import 'package:clingfy/commercial/licensing/models/license_plan.dart';
import 'package:clingfy/commercial/licensing/license_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LicenseState buildState({
    required LicensePlan plan,
    required bool entitledPro,
    required bool isUpdateCovered,
    int trialExportsRemaining = 0,
    DateTime? updatesExpiresAt,
  }) {
    return LicenseState(
      isValid: true,
      entitledPro: entitledPro,
      plan: plan.wireValue,
      isUpdateCovered: isUpdateCovered,
      trialExportsRemaining: trialExportsRemaining,
      memberSince: null,
      activatedAt: null,
      updatesExpiresAt: updatesExpiresAt,
      message: 'ok',
    );
  }

  test('isUpdatesExpiringSoon uses 30-day threshold for lifetime only', () {
    final now = DateTime.now();
    final controller = LicenseController();

    controller.state = buildState(
      plan: LicensePlan.lifetime,
      entitledPro: true,
      isUpdateCovered: true,
      updatesExpiresAt: now.add(const Duration(days: 30)),
    );
    expect(controller.isUpdatesExpiringSoon, isTrue);

    controller.state = buildState(
      plan: LicensePlan.lifetime,
      entitledPro: true,
      isUpdateCovered: true,
      updatesExpiresAt: now.add(const Duration(days: 32)),
    );
    expect(controller.isUpdatesExpiringSoon, isFalse);

    controller.state = buildState(
      plan: LicensePlan.subscription,
      entitledPro: true,
      isUpdateCovered: true,
      updatesExpiresAt: now.add(const Duration(days: 10)),
    );
    expect(controller.isUpdatesExpiringSoon, isFalse);
  });

  test('primaryLicenseActionType maps correctly by plan and coverage', () {
    final now = DateTime.now();
    final controller = LicenseController();

    controller.state = buildState(
      plan: LicensePlan.starter,
      entitledPro: false,
      isUpdateCovered: false,
    );
    controller.currentKey = null;
    expect(
      controller.primaryLicenseActionType,
      LicensePrimaryAction.activateOrUpgrade,
    );

    controller.state = buildState(
      plan: LicensePlan.trial,
      entitledPro: true,
      isUpdateCovered: true,
      trialExportsRemaining: 2,
    );
    expect(
      controller.primaryLicenseActionType,
      LicensePrimaryAction.upgradeToPro,
    );

    controller.state = buildState(
      plan: LicensePlan.subscription,
      entitledPro: true,
      isUpdateCovered: true,
    );
    controller.currentKey = 'CLINGFY-AAAA-BBBB-CC99';
    expect(
      controller.primaryLicenseActionType,
      LicensePrimaryAction.subscriptionActive,
    );

    controller.state = buildState(
      plan: LicensePlan.lifetime,
      entitledPro: true,
      isUpdateCovered: true,
      updatesExpiresAt: now.add(const Duration(days: 60)),
    );
    expect(
      controller.primaryLicenseActionType,
      LicensePrimaryAction.lifetimeActive,
    );

    controller.state = buildState(
      plan: LicensePlan.lifetime,
      entitledPro: true,
      isUpdateCovered: true,
      updatesExpiresAt: now.add(const Duration(days: 8)),
    );
    expect(
      controller.primaryLicenseActionType,
      LicensePrimaryAction.extendUpdates,
    );

    controller.state = buildState(
      plan: LicensePlan.lifetime,
      entitledPro: false,
      isUpdateCovered: false,
      updatesExpiresAt: now.subtract(const Duration(days: 2)),
    );
    expect(
      controller.primaryLicenseActionType,
      LicensePrimaryAction.extendUpdates,
    );
  });

  test('hasLinkedKey and canExtendUpdates helpers are correct', () {
    final now = DateTime.now();
    final controller = LicenseController();

    controller.state = buildState(
      plan: LicensePlan.lifetime,
      entitledPro: true,
      isUpdateCovered: true,
      updatesExpiresAt: now.add(const Duration(days: 20)),
    );
    controller.currentKey = '';
    expect(controller.hasLinkedKey, isFalse);
    expect(controller.canExtendUpdates, isTrue);

    controller.currentKey = 'CLINGFY-KEY1-KEY2-KEY3';
    expect(controller.hasLinkedKey, isTrue);

    controller.state = buildState(
      plan: LicensePlan.lifetime,
      entitledPro: true,
      isUpdateCovered: true,
      updatesExpiresAt: now.add(const Duration(days: 60)),
    );
    expect(controller.canExtendUpdates, isFalse);
  });

  // --- Re-validation after an unanswered check (#559) -----------------------
  //
  // refreshEntitlement() ran once at launch and assigned state unconditionally,
  // so one unanswered check outlived the outage that caused it: the user stayed
  // downgraded for the whole session even after the backend came back, and had
  // to quit and relaunch. With the dev API parked at zero tasks by design, that
  // was the ordinary dev experience rather than a rare one.

  group('revalidateIfUnverified', () {
    const storageChannel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    late Map<String, String> storage;
    late int requestCount;
    late http.Response Function() respond;

    setUp(() {
      storage = <String, String>{
        'license_key': 'CLINGFY-AAAA-BBBB-CC99',
        'license_data': jsonEncode(<String, dynamic>{
          'valid': true,
          'entitled_pro': true,
          'plan': 'lifetime',
          'is_update_covered': true,
          'trial_exports_remaining': 0,
          'updates_expires_at': '2099-01-01T00:00:00Z',
        }),
        'last_check': DateTime.now()
            .subtract(const Duration(days: 1))
            .toIso8601String(),
      };
      requestCount = 0;
      respond = () => http.Response('<html/>', 503);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async {
            final arguments =
                (call.arguments as Map?)?.cast<String, dynamic>() ??
                <String, dynamic>{};
            final key = arguments['key']?.toString();
            switch (call.method) {
              case 'write':
                if (key != null) {
                  storage[key] = arguments['value']?.toString() ?? '';
                }
                return null;
              case 'read':
                return key == null ? null : storage[key];
              case 'delete':
                if (key != null) storage.remove(key);
                return null;
              case 'deleteAll':
                storage.clear();
                return null;
              case 'readAll':
                return Map<String, String>.from(storage);
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, null);
    });

    http.Response healthy() => http.Response(
      jsonEncode(<String, dynamic>{
        'valid': true,
        'entitled_pro': true,
        'plan': 'lifetime',
        'is_update_covered': true,
        'trial_exports_remaining': 0,
      }),
      200,
    );

    LicenseController build({DateTime Function()? now, Duration? slowBy}) {
      final client = MockClient((request) async {
        requestCount += 1;
        if (slowBy != null) await Future<void>.delayed(slowBy);
        return respond();
      });
      return LicenseController(
        service: LicenseService(
          httpClient: client,
          hardwareIdProvider: () async => 'hw-test',
        ),
        now: now,
      );
    }

    test('adopts entitlement once the backend answers again', () async {
      final controller = build();
      await controller.refreshEntitlement();

      expect(controller.isUnverified, isTrue);
      expect(controller.message, 'LICENSE_OFFLINE_CACHED');

      respond = healthy;
      await controller.revalidateIfUnverified();

      expect(controller.isUnverified, isFalse);
      expect(controller.isEntitledPro, isTrue);
      expect(
        controller.message,
        isNot('LICENSE_OFFLINE_CACHED'),
        reason: 'a recovered backend must be noticed without a relaunch',
      );
    });

    test('does not re-ask when the server already gave a verdict', () async {
      final controller = build();
      respond = () => http.Response(
        jsonEncode(<String, dynamic>{'reason': 'LICENSE_REVOKED'}),
        401,
      );
      await controller.refreshEntitlement();
      final afterFirst = requestCount;

      expect(controller.isUnverified, isFalse);
      await controller.revalidateIfUnverified();

      expect(
        requestCount,
        afterFirst,
        reason:
            'retrying a verdict would hammer the API on behalf of users '
            'who genuinely are not licensed',
      );
    });

    test('holds off inside the cooldown, and force overrides it', () async {
      var clock = DateTime(2026, 9, 22, 12);
      final controller = build(now: () => clock);
      await controller.refreshEntitlement();
      final afterFirst = requestCount;

      await controller.revalidateIfUnverified();
      final afterRetry = requestCount;
      expect(afterRetry, greaterThan(afterFirst));

      clock = clock.add(const Duration(seconds: 30));
      await controller.revalidateIfUnverified();
      expect(
        requestCount,
        afterRetry,
        reason:
            'every window focus is a resume; without a floor an outage '
            'would post a validate call on each one',
      );

      await controller.revalidateIfUnverified(force: true);
      expect(
        requestCount,
        greaterThan(afterRetry),
        reason: 'pressing Export is a deliberate act and skips the cooldown',
      );

      clock = clock.add(LicenseController.revalidateCooldown);
      final beforeElapsed = requestCount;
      await controller.revalidateIfUnverified();
      expect(requestCount, greaterThan(beforeElapsed));
    });

    test(
      'a background retry never flips the user-facing loading flag',
      () async {
        final controller = build();
        await controller.refreshEntitlement();
        expect(controller.isLoading, isFalse);

        var sawLoading = false;
        controller.addListener(() {
          if (controller.isLoading) sawLoading = true;
        });

        respond = healthy;
        await controller.revalidateIfUnverified();

        expect(
          sawLoading,
          isFalse,
          reason:
              'isLoading means a user-initiated operation is running, and '
              'widgets render spinners off it — a retry on every window focus '
              'must not make the settings panel flicker',
        );
      },
    );

    test('a retry that also fails does not churn listeners', () async {
      final controller = build();
      await controller.refreshEntitlement();
      expect(controller.isUnverified, isTrue);

      var notifications = 0;
      controller.addListener(() => notifications += 1);

      // Still down. Swapping one cached-state for an identical cached-state
      // would rebuild every listening widget for no visible change.
      await controller.revalidateIfUnverified(force: true);

      expect(notifications, 0);
      expect(controller.isEntitledPro, isTrue);
    });

    test('concurrent calls collapse into one request', () async {
      final controller = build(slowBy: const Duration(milliseconds: 60));
      await controller.refreshEntitlement();
      final afterFirst = requestCount;

      respond = healthy;
      // force: true on all three, so the cooldown cannot be what collapses
      // them — only the in-flight guard can. The request is deliberately slow
      // enough that the three genuinely overlap.
      await Future.wait(<Future<void>>[
        controller.revalidateIfUnverified(force: true),
        controller.revalidateIfUnverified(force: true),
        controller.revalidateIfUnverified(force: true),
      ]);

      expect(
        requestCount,
        afterFirst + 1,
        reason: 'a resume storm must not post three validate calls',
      );
    });
  });
}
