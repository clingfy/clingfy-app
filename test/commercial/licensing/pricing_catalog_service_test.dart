import 'dart:convert';

import 'package:clingfy/commercial/licensing/pricing_catalog_service.dart';
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
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  Map<String, Object> catalogJson({int lifetimeAmount = 5999}) => {
    'version': 1,
    'currency': 'USD',
    'trial': {'days': 7, 'exportLimit': 3},
    'plans': [
      {'key': 'free', 'formattedAmount': r'$0'},
      {'key': 'pro_monthly', 'formattedAmount': r'$9.99'},
      {
        'key': 'lifetime_pro',
        'formattedAmount': lifetimeAmount == 5999 ? r'$59.99' : r'$39',
      },
      {'key': 'updates_extension', 'formattedAmount': r'$19.99'},
    ],
    'updatedAt': '2026-07-16T00:00:00.000Z',
  };

  test('parses the live catalog and caches the raw payload', () async {
    // NOTE: BuildConfig.apiBaseURL is '' in tests (no dart-defines), so load() skips the
    // network unless we exercise fromJson directly — parse coverage first:
    final catalog = PricingCatalog.fromJson(catalogJson());
    expect(catalog, isNotNull);
    expect(catalog!.plan('lifetime_pro')!.formattedAmount, r'$59.99');
    expect(catalog.plan('pro_monthly')!.formattedAmount, r'$9.99');
    expect(catalog.plan('nope'), isNull);
  });

  test('fromJson rejects payloads without usable plans', () {
    expect(PricingCatalog.fromJson(null), isNull);
    expect(PricingCatalog.fromJson(<String, dynamic>{}), isNull);
    expect(PricingCatalog.fromJson({'plans': <Object>[]}), isNull);
    expect(
      PricingCatalog.fromJson({
        'plans': [
          {'key': '', 'formattedAmount': ''},
        ],
      }),
      isNull,
    );
  });

  test('load() falls back to the cached copy when the request fails', () async {
    secureStorageValues['pricing_catalog_cache_v1'] = jsonEncode(
      catalogJson(lifetimeAmount: 3900),
    );
    final client = MockClient((request) async {
      throw http.ClientException('offline');
    });
    final service = PricingCatalogService(httpClient: client);

    final catalog = await service.load();
    expect(catalog, isNotNull);
    expect(catalog!.plan('lifetime_pro')!.formattedAmount, r'$39');
  });

  test(
    'load() returns null with no network and no cache (bundled fallback territory)',
    () async {
      final client = MockClient((request) async {
        throw http.ClientException('offline');
      });
      final service = PricingCatalogService(httpClient: client);
      expect(await service.load(), isNull);
    },
  );

  test('load() survives a corrupt cache', () async {
    secureStorageValues['pricing_catalog_cache_v1'] = 'not-json{{{';
    final client = MockClient((request) async {
      throw http.ClientException('offline');
    });
    final service = PricingCatalogService(httpClient: client);
    expect(await service.load(), isNull);
  });

  test('bundled fallbacks cover every paywall plan key', () {
    expect(
      kBundledFallbackPrices.keys,
      containsAll(['pro_monthly', 'lifetime_pro', 'updates_extension']),
    );
    expect(kBundledFallbackPrices['lifetime_pro'], r'$39.99');
  });
}
