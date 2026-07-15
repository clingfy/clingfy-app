// lib/commercial/licensing/pricing_catalog_service.dart
//
// Public pricing catalog (`GET /v1/pricing` on the Clingfy API): amounts come from the SAME
// Stripe Prices the website checkout charges, so the paywall can never advertise a price that
// drifts from the charge. Load order: live catalog -> last-known cached copy (secure storage,
// works offline) -> null, in which case callers fall back to the bundled prices below. Prices
// deliberately live here and NOT in the l10n files — a price is not a translation, and shipping
// it in .arb meant a full app release (x3 locales) per price change.

import 'dart:async';
import 'dart:convert';

import 'package:clingfy/app/config/build_config.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Bundled fallback prices — the resilience floor when the API is unreachable AND nothing is
/// cached (first offline run). The website's Stripe checkout page stays authoritative.
const Map<String, String> kBundledFallbackPrices = {
  'pro_monthly': r'$9.99',
  'lifetime_pro': r'$59.99',
  'updates_extension': r'$19.99',
};

/// One plan from the catalog. Only what the paywall renders; unknown fields are ignored so the
/// API can evolve without breaking shipped builds.
class PricingPlanInfo {
  const PricingPlanInfo({required this.key, required this.formattedAmount});

  final String key;
  final String formattedAmount;
}

class PricingCatalog {
  const PricingCatalog(this._plans);

  final Map<String, PricingPlanInfo> _plans;

  PricingPlanInfo? plan(String key) => _plans[key];

  /// Tolerant parse: returns null when the payload has no usable plans (caller falls back).
  static PricingCatalog? fromJson(Object? decoded) {
    if (decoded is! Map<String, dynamic>) return null;
    final plans = decoded['plans'];
    if (plans is! List) return null;
    final map = <String, PricingPlanInfo>{};
    for (final entry in plans) {
      if (entry is! Map<String, dynamic>) continue;
      final key = entry['key']?.toString();
      final formatted = entry['formattedAmount']?.toString();
      if (key == null ||
          key.isEmpty ||
          formatted == null ||
          formatted.isEmpty) {
        continue;
      }
      map[key] = PricingPlanInfo(key: key, formattedAmount: formatted);
    }
    if (map.isEmpty) return null;
    return PricingCatalog(map);
  }
}

class PricingCatalogService {
  PricingCatalogService({
    FlutterSecureStorage? storage,
    http.Client? httpClient,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _httpClient = httpClient ?? http.Client();

  static const String _cacheStorageKey = 'pricing_catalog_cache_v1';
  static const Duration _requestTimeout = Duration(seconds: 5);

  final FlutterSecureStorage _storage;
  final http.Client _httpClient;

  /// Live catalog -> last-known cached copy -> null (caller uses [kBundledFallbackPrices]).
  Future<PricingCatalog?> load() async {
    final base = BuildConfig.apiBaseURL;
    if (base.isNotEmpty) {
      try {
        final res = await _httpClient
            .get(Uri.parse('$base/v1/pricing'))
            .timeout(_requestTimeout);
        if (res.statusCode == 200) {
          final catalog = PricingCatalog.fromJson(jsonDecode(res.body));
          if (catalog != null) {
            await _storage.write(key: _cacheStorageKey, value: res.body);
            return catalog;
          }
        }
      } catch (_) {
        // Offline / API down / bad payload — fall through to the cached copy.
      }
    }
    try {
      final cached = await _storage.read(key: _cacheStorageKey);
      if (cached != null && cached.isNotEmpty) {
        return PricingCatalog.fromJson(jsonDecode(cached));
      }
    } catch (_) {
      // Corrupt cache — behave as if empty.
    }
    return null;
  }
}
