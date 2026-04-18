import 'dart:convert';
import 'dart:io';

import 'package:clingfy/app/config/build_config.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/commercial/licensing/license_error_codes.dart';
import 'package:clingfy/commercial/licensing/models/license_plan.dart';

class LicenseService {
  static const String _baseUrl = BuildConfig.apiBaseURL;
  static const String _validateUrl = '$_baseUrl/v1/validate-license';
  static const String _consumeTrialUrl = '$_baseUrl/v1/consume-trial';
  static const String _deactivateUrl = '$_baseUrl/v1/deactivate-license';

  static const String _licenseKeyStorageKey = 'license_key';
  static const String _licenseDataStorageKey = 'license_data';
  static const String _lastCheckStorageKey = 'last_check';
  static const String _firstActivatedAtStorageKey = 'first_activated_at';

  final FlutterSecureStorage _storage;
  final DateTime _appBuildDate = BuildConfig.buildDate;

  final http.Client _httpClient;
  final Future<String> Function()? _hardwareIdProvider;

  LicenseService({
    FlutterSecureStorage? storage,
    http.Client? httpClient, // Allow injecting a client for testing
    Future<String> Function()? hardwareIdProvider,
  }) : _storage = storage ?? const FlutterSecureStorage(),
       _httpClient = httpClient ?? HttpLoggerClient(http.Client()),
       _hardwareIdProvider = hardwareIdProvider;

  Future<String?> readStoredLicenseKey() {
    return _storage.read(key: _licenseKeyStorageKey);
  }

  Future<void> clearStoredLicenseKey() {
    return _storage.delete(key: _licenseKeyStorageKey);
  }

  Future<LicenseState> validateLicense([String? key]) async {
    try {
      final hardwareId =
          await (_hardwareIdProvider?.call() ?? _getHardwareId());
      final trimmedKey = key?.trim();

      final body = <String, dynamic>{
        'hardware_id': hardwareId,
        'app_build_date': _appBuildDate.toIso8601String(),
      };
      if (trimmedKey != null && trimmedKey.isNotEmpty) {
        body['license_key'] = trimmedKey;
      }

      final response = await _httpClient.post(
        Uri.parse(_validateUrl),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      final data = _decodeMap(response.body);

      if (response.statusCode == 200) {
        var state = LicenseState.fromJson(data);
        await _saveLicenseLocally(trimmedKey, data);
        if (trimmedKey != null && trimmedKey.isNotEmpty && state.entitledPro) {
          await _persistFirstActivatedAtIfMissing(
            candidate: state.memberSince ?? state.activatedAt,
          );
        }
        state = await _applyFirstActivatedFallback(state);
        return state;
      }

      return LicenseState.error(
        data['reason']?.toString() ??
            data['message']?.toString() ??
            LicenseErrorCodes.validationFailed,
      );
    } catch (_) {
      return _checkOfflineLicense();
    }
  }

  Future<ConsumeTrialResult> consumeTrial(String exportId) async {
    try {
      final hardwareId =
          await (_hardwareIdProvider?.call() ?? _getHardwareId());
      final response = await _httpClient.post(
        Uri.parse(_consumeTrialUrl),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'hardware_id': hardwareId, 'export_id': exportId}),
      );

      final data = _decodeMap(response.body);
      if (response.statusCode != 200) {
        return ConsumeTrialResult(
          ok: false,
          reason:
              data['reason']?.toString() ??
              data['message']?.toString() ??
              LicenseErrorCodes.trialConsumptionFailed,
        );
      }

      final ok = _asBool(data['ok']) ?? false;
      final remaining = _asInt(data['trial_exports_remaining']);

      if (ok && remaining != null) {
        await _updateCachedTrialRemaining(remaining);
      }

      return ConsumeTrialResult(
        ok: ok,
        trialExportsRemaining: remaining,
        reason: data['reason']?.toString() ?? data['message']?.toString(),
      );
    } catch (_) {
      return const ConsumeTrialResult(
        ok: false,
        reason: LicenseErrorCodes.networkUnavailableWhileConsumingTrial,
      );
    }
  }

  Future<DeactivateLicenseResult> deactivateLicense(String key) async {
    try {
      final trimmedKey = key.trim();
      if (trimmedKey.isEmpty) {
        return const DeactivateLicenseResult(
          ok: false,
          reason: LicenseErrorCodes.keyRequired,
        );
      }

      final hardwareId =
          await (_hardwareIdProvider?.call() ?? _getHardwareId());
      final response = await _httpClient.post(
        Uri.parse(_deactivateUrl),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'license_key': trimmedKey,
          'hardware_id': hardwareId,
        }),
      );

      if (response.statusCode == 200) {
        await _wipeLocalData();
        return const DeactivateLicenseResult(ok: true);
      }

      final data = _decodeMap(response.body);
      return DeactivateLicenseResult(
        ok: false,
        statusCode: response.statusCode,
        reason:
            data['reason']?.toString() ??
            data['error']?.toString() ??
            data['message']?.toString() ??
            LicenseErrorCodes.deactivationFailed,
      );
    } catch (_) {
      return const DeactivateLicenseResult(
        ok: false,
        reason: LicenseErrorCodes.networkUnavailableWhileDeactivatingDevice,
      );
    }
  }

  Future<String> _getHardwareId() async {
    if (!Platform.isMacOS) {
      return 'unknown_device';
    }

    final deviceInfo = DeviceInfoPlugin();
    final macInfo = await deviceInfo.macOsInfo;
    return macInfo.systemGUID ?? 'unavailable_guid';
  }

  Future<void> _saveLicenseLocally(
    String? key,
    Map<String, dynamic> data,
  ) async {
    if (key != null && key.isNotEmpty) {
      await _storage.write(key: _licenseKeyStorageKey, value: key);
    }
    await _storage.write(key: _licenseDataStorageKey, value: jsonEncode(data));
    await _storage.write(
      key: _lastCheckStorageKey,
      value: DateTime.now().toIso8601String(),
    );
  }

  Future<void> _updateCachedTrialRemaining(int remaining) async {
    final stored = await _storage.read(key: _licenseDataStorageKey);
    if (stored == null || stored.isEmpty) {
      return;
    }

    final cached = _decodeMap(stored);
    cached['trial_exports_remaining'] = remaining;
    if (cached['plan'] == null) {
      cached['plan'] = 'trial';
    }
    if (licensePlanFromWire(cached['plan']?.toString()) == LicensePlan.trial) {
      cached['entitled_pro'] = remaining > 0;
    }

    await _storage.write(
      key: _licenseDataStorageKey,
      value: jsonEncode(cached),
    );
    await _storage.write(
      key: _lastCheckStorageKey,
      value: DateTime.now().toIso8601String(),
    );
  }

  Future<void> _wipeLocalData() async {
    await _storage.delete(key: _licenseKeyStorageKey);
    await _storage.delete(key: _licenseDataStorageKey);
    await _storage.delete(key: _lastCheckStorageKey);
    await _storage.delete(key: _firstActivatedAtStorageKey);
  }

  Future<LicenseState> _checkOfflineLicense() async {
    try {
      final storedData = await _storage.read(key: _licenseDataStorageKey);
      final lastCheckStr = await _storage.read(key: _lastCheckStorageKey);

      if (storedData == null || lastCheckStr == null) {
        return LicenseState.error(LicenseErrorCodes.internetRequired);
      }

      final lastCheck = DateTime.tryParse(lastCheckStr);
      if (lastCheck == null ||
          DateTime.now().difference(lastCheck).inDays >= 7) {
        return LicenseState.error(LicenseErrorCodes.internetRequired);
      }

      final cachedMap = _decodeMap(storedData);
      final cachedState = LicenseState.fromJson(cachedMap);

      var isCovered = cachedState.isUpdateCovered;
      if (cachedState.updatesExpiresAt != null) {
        isCovered = !_appBuildDate.isAfter(cachedState.updatesExpiresAt!);
      }

      var entitledPro = cachedState.entitledPro;
      if (cachedState.planType == LicensePlan.trial) {
        entitledPro = cachedState.trialExportsRemaining > 0;
      } else if (cachedState.planType.isPaid) {
        entitledPro = entitledPro && isCovered;
      }

      final stateWithCoverage = cachedState.copyWith(
        isUpdateCovered: isCovered,
        entitledPro: entitledPro,
        message: LicenseErrorCodes.offlineCached,
      );
      return _applyFirstActivatedFallback(stateWithCoverage);
    } catch (_) {
      return LicenseState.error(LicenseErrorCodes.internetRequired);
    }
  }

  Future<DateTime?> _readFirstActivatedAt() async {
    final raw = await _storage.read(key: _firstActivatedAtStorageKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw);
  }

  Future<void> _persistFirstActivatedAtIfMissing({DateTime? candidate}) async {
    final existing = await _readFirstActivatedAt();
    if (existing != null) {
      return;
    }
    final value = (candidate ?? DateTime.now()).toUtc().toIso8601String();
    await _storage.write(key: _firstActivatedAtStorageKey, value: value);
  }

  Future<LicenseState> _applyFirstActivatedFallback(LicenseState state) async {
    if (state.activatedAt != null) {
      return state;
    }
    final firstActivatedAt = await _readFirstActivatedAt();
    if (firstActivatedAt == null) {
      return state;
    }
    return state.copyWith(activatedAt: firstActivatedAt);
  }

  static Map<String, dynamic> _decodeMap(String raw) {
    if (raw.isEmpty) {
      return const <String, dynamic>{};
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
      return const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  static bool? _asBool(dynamic value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') {
        return true;
      }
      if (normalized == 'false' || normalized == '0') {
        return false;
      }
    }
    return null;
  }

  static int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  static DateTime? _asDate(dynamic value) {
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  static String _normalizePlan(dynamic value) {
    final parsed = licensePlanFromWire(value?.toString());
    return parsed == LicensePlan.unknown
        ? LicensePlan.starter.wireValue
        : parsed.wireValue;
  }
}

class ConsumeTrialResult {
  final bool ok;
  final int? trialExportsRemaining;
  final String? reason;

  const ConsumeTrialResult({
    required this.ok,
    this.trialExportsRemaining,
    this.reason,
  });
}

class DeactivateLicenseResult {
  final bool ok;
  final String? reason;
  final int? statusCode;

  const DeactivateLicenseResult({
    required this.ok,
    this.reason,
    this.statusCode,
  });
}

class LicenseState {
  final bool isValid;
  final bool entitledPro;
  final String plan;
  final bool isUpdateCovered;
  final int trialExportsRemaining;
  final DateTime? memberSince;
  final DateTime? activatedAt;
  final DateTime? updatesExpiresAt;
  final String message;

  const LicenseState({
    required this.isValid,
    required this.entitledPro,
    required this.plan,
    required this.isUpdateCovered,
    required this.trialExportsRemaining,
    required this.memberSince,
    required this.activatedAt,
    required this.updatesExpiresAt,
    required this.message,
  });

  LicensePlan get planType => licensePlanFromWire(plan);

  factory LicenseState.fromJson(Map<String, dynamic> json) {
    final valid = LicenseService._asBool(json['valid']) ?? false;
    final trialRemaining =
        (LicenseService._asInt(json['trial_exports_remaining']) ?? 0).clamp(
          0,
          999999,
        );
    final memberSince =
        LicenseService._asDate(json['member_since']) ??
        LicenseService._asDate(json['memberSince']);
    final activatedAt =
        LicenseService._asDate(json['activated_at']) ??
        LicenseService._asDate(json['activatedAt']);
    final updatesExpiresAt = LicenseService._asDate(json['updates_expires_at']);

    var isUpdateCovered =
        LicenseService._asBool(json['is_update_covered']) ?? true;
    var entitledPro = LicenseService._asBool(json['entitled_pro']) ?? false;
    var plan = licensePlanFromWire(LicenseService._normalizePlan(json['plan']));

    if (!json.containsKey('entitled_pro')) {
      entitledPro = valid && isUpdateCovered;
    }

    if (!json.containsKey('plan')) {
      if (trialRemaining > 0) {
        plan = LicensePlan.trial;
      } else if (entitledPro) {
        plan = LicensePlan.lifetime;
      } else {
        plan = LicensePlan.starter;
      }
    }

    if (plan == LicensePlan.trial) {
      entitledPro = entitledPro || trialRemaining > 0 || valid;
      isUpdateCovered = true;
    }

    if (plan.isPaid && !isUpdateCovered) {
      entitledPro = false;
    }

    if (plan == LicensePlan.starter && trialRemaining <= 0) {
      entitledPro = false;
    }

    return LicenseState(
      isValid: valid,
      entitledPro: entitledPro,
      plan: plan.wireValue,
      isUpdateCovered: isUpdateCovered,
      trialExportsRemaining: trialRemaining,
      memberSince: memberSince,
      activatedAt: activatedAt,
      updatesExpiresAt: updatesExpiresAt,
      message:
          json['message']?.toString() ??
          json['reason']?.toString() ??
          (entitledPro
              ? LicenseErrorCodes.validated
              : LicenseErrorCodes.notEntitled),
    );
  }

  factory LicenseState.error(String message) {
    return LicenseState(
      isValid: false,
      entitledPro: false,
      plan: 'starter',
      isUpdateCovered: false,
      trialExportsRemaining: 0,
      memberSince: null,
      activatedAt: null,
      updatesExpiresAt: null,
      message: message,
    );
  }

  LicenseState copyWith({
    bool? isValid,
    bool? entitledPro,
    String? plan,
    bool? isUpdateCovered,
    int? trialExportsRemaining,
    DateTime? memberSince,
    DateTime? activatedAt,
    DateTime? updatesExpiresAt,
    String? message,
  }) {
    return LicenseState(
      isValid: isValid ?? this.isValid,
      entitledPro: entitledPro ?? this.entitledPro,
      plan: plan ?? this.plan,
      isUpdateCovered: isUpdateCovered ?? this.isUpdateCovered,
      trialExportsRemaining:
          trialExportsRemaining ?? this.trialExportsRemaining,
      memberSince: memberSince ?? this.memberSince,
      activatedAt: activatedAt ?? this.activatedAt,
      updatesExpiresAt: updatesExpiresAt ?? this.updatesExpiresAt,
      message: message ?? this.message,
    );
  }
}

class HttpLoggerClient extends http.BaseClient {
  final http.Client _inner;

  HttpLoggerClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final startTime = DateTime.now();

    // 1. Log the Outgoing Request
    Log.d('Network', '--> ${request.method} ${request.url}');
    if (request is http.Request && request.body.isNotEmpty) {
      Log.d('Network', '--> Body: ${request.body}');
    }

    try {
      // 2. Execute the Request
      final response = await _inner.send(request);
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;

      // 3. Intercept and read the Response Stream
      final responseBytes = await response.stream.toBytes();
      final responseString = utf8.decode(responseBytes, allowMalformed: true);

      // 4. Log the Response
      if (response.statusCode >= 200 && response.statusCode < 300) {
        Log.d(
          'Network',
          '<-- ${response.statusCode} ${request.url} (${elapsed}ms)\nBody: $responseString',
        );
      } else {
        Log.e(
          'Network',
          '<-- ${response.statusCode} ERROR ${request.url} (${elapsed}ms)\nBody: $responseString',
        );
      }

      // 5. Rebuild and return the StreamedResponse (since we consumed the original stream)
      return http.StreamedResponse(
        Stream.fromIterable([responseBytes]),
        response.statusCode,
        contentLength: response.contentLength,
        request: request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (e) {
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      Log.e('Network', '<-- EXCEPTION ${request.url} (${elapsed}ms): $e');
      // ClingfyTelemetry.captureError(e, stackTrace: st, method: 'http.send');

      rethrow;
    }
  }
}
