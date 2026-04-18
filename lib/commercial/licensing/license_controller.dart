// lib/controllers/license_controller.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:clingfy/commercial/licensing/license_error_codes.dart';
import 'package:clingfy/commercial/licensing/models/license_plan.dart';

import 'package:clingfy/commercial/licensing/license_service.dart';
import 'package:clingfy/app/infrastructure/observability/telemetry_service.dart';

enum LicensePrimaryAction {
  activateOrUpgrade,
  upgradeToPro,
  activateKeyOnly,
  extendUpdates,
  subscriptionActive,
  lifetimeActive,
}

class LicenseController extends ChangeNotifier {
  final LicenseService _service;
  final Uuid _uuid;

  LicenseController({LicenseService? service, Uuid? uuid})
    : _service = service ?? LicenseService(),
      _uuid = uuid ?? const Uuid();

  bool isLoading = true;
  String? currentKey;
  LicenseState state = LicenseState.error(LicenseErrorCodes.initializing);
  String? deactivationError;
  bool _initialized = false;

  bool get isEntitledPro => state.entitledPro;
  String get currentPlan => state.plan;
  LicensePlan get currentPlanType => state.planType;
  int get trialExportsRemaining => state.trialExportsRemaining;
  bool get isUpdateCovered => state.isUpdateCovered;
  String get message => state.message;

  bool get isTrialPlan => currentPlanType == LicensePlan.trial;

  bool get isPaidPlan => currentPlanType.isPaid;
  bool get hasLinkedKey => currentKey?.trim().isNotEmpty == true;
  DateTime? get memberSince => state.memberSince;
  DateTime? get activatedAt => state.activatedAt;
  DateTime? get activatedOnThisDeviceAt =>
      state.activatedAt ?? state.memberSince;

  bool get isUpdatesExpired => isPaidPlan && !state.isUpdateCovered;

  bool get isUpdatesExpiringSoon {
    if (currentPlanType != LicensePlan.lifetime) {
      return false;
    }
    final expiresAt = state.updatesExpiresAt;
    if (expiresAt == null || isUpdatesExpired) {
      return false;
    }
    final remainingDays = expiresAt.difference(DateTime.now()).inDays;
    return remainingDays >= 0 && remainingDays <= 30;
  }

  bool get canExtendUpdates =>
      currentPlanType == LicensePlan.lifetime &&
      (isUpdatesExpired || isUpdatesExpiringSoon);

  LicensePrimaryAction get primaryLicenseActionType {
    if (isTrialPlan) {
      return LicensePrimaryAction.upgradeToPro;
    }

    if (currentPlanType == LicensePlan.subscription &&
        state.entitledPro &&
        state.isUpdateCovered) {
      return LicensePrimaryAction.subscriptionActive;
    }

    if (currentPlanType == LicensePlan.lifetime) {
      if (canExtendUpdates) {
        return LicensePrimaryAction.extendUpdates;
      }
      if (state.entitledPro && state.isUpdateCovered) {
        return LicensePrimaryAction.lifetimeActive;
      }
    }

    if (!hasLinkedKey || currentPlanType == LicensePlan.starter) {
      return LicensePrimaryAction.activateOrUpgrade;
    }

    return LicensePrimaryAction.activateKeyOnly;
  }

  bool get shouldShowActivateOrUpgrade =>
      primaryLicenseActionType == LicensePrimaryAction.activateOrUpgrade;

  bool get shouldShowManageSubscription => false;

  bool get canExport {
    if (isPaidPlan) {
      return state.entitledPro && state.isUpdateCovered;
    }
    if (isTrialPlan) {
      return state.entitledPro && state.trialExportsRemaining > 0;
    }
    return false;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await refreshEntitlement();
  }

  Future<bool> activateKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      return false;
    }

    final previousKey = currentKey;
    final previousState = state;

    isLoading = true;
    deactivationError = null;
    notifyListeners();

    final validated = await _service.validateLicense(trimmed);

    final activated =
        validated.isValid &&
        validated.entitledPro &&
        (validated.planType.isPaid ||
            (validated.planType == LicensePlan.trial &&
                validated.trialExportsRemaining > 0));

    if (activated) {
      state = validated;
      currentKey = trimmed;
      unawaited(
        ClingfyTelemetry.addUiBreadcrumb(
          category: 'ui.license',
          message: 'license_key_activated',
          data: {'plan': validated.plan},
        ),
      );
    } else {
      if (previousKey != null && previousKey.isNotEmpty) {
        state = await _service.validateLicense(previousKey);
      } else {
        state = previousState.copyWith(message: validated.message);
      }
      currentKey = previousKey;
      unawaited(
        ClingfyTelemetry.addUiBreadcrumb(
          category: 'ui.license',
          message: 'license_key_activation_failed',
          data: {'reason': validated.message},
        ),
      );
    }

    isLoading = false;
    notifyListeners();
    return activated;
  }

  Future<void> refreshEntitlement() async {
    isLoading = true;
    deactivationError = null;
    notifyListeners();

    currentKey = await _service.readStoredLicenseKey();
    state = await _service.validateLicense(currentKey);

    isLoading = false;
    notifyListeners();
  }

  Future<bool> deactivateCurrentDevice() async {
    if (currentKey == null || currentKey!.trim().isEmpty) {
      return true;
    }

    isLoading = true;
    deactivationError = null;
    notifyListeners();
    unawaited(
      ClingfyTelemetry.addUiBreadcrumb(
        category: 'ui.license',
        message: 'license_deactivate_started',
        data: {'plan': currentPlan},
      ),
    );

    final result = await _service.deactivateLicense(currentKey!);

    if (result.ok) {
      currentKey = null;
      state = await _service.validateLicense(null);
      unawaited(
        ClingfyTelemetry.addUiBreadcrumb(
          category: 'ui.license',
          message: 'license_deactivate_succeeded',
          data: {'plan': state.plan},
        ),
      );
      isLoading = false;
      notifyListeners();
      return true;
    }

    deactivationError = result.reason?.isNotEmpty == true
        ? result.reason
        : (result.statusCode == 404
              ? LicenseErrorCodes.notFound
              : LicenseErrorCodes.deactivationFailed);
    unawaited(
      ClingfyTelemetry.addUiBreadcrumb(
        category: 'ui.license',
        message: 'license_deactivate_failed',
        data: {'statusCode': result.statusCode, 'reason': deactivationError},
      ),
    );
    isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> consumeExport() async {
    if (isPaidPlan) {
      return true;
    }

    if (!isTrialPlan || state.trialExportsRemaining <= 0) {
      return false;
    }

    final exportId = _uuid.v4();
    final consumeResult = await _service.consumeTrial(exportId);
    if (!consumeResult.ok) {
      await refreshEntitlement();
      return false;
    }

    if (consumeResult.trialExportsRemaining != null) {
      final remaining = consumeResult.trialExportsRemaining!;
      state = state.copyWith(
        trialExportsRemaining: remaining,
        entitledPro: remaining > 0,
        message: consumeResult.reason ?? state.message,
      );
      notifyListeners();
    } else {
      // Optimistic local update then background revalidation.
      final remaining = (state.trialExportsRemaining - 1).clamp(0, 999999);
      state = state.copyWith(
        trialExportsRemaining: remaining,
        entitledPro: remaining > 0,
      );
      notifyListeners();
      unawaited(refreshEntitlement());
    }

    unawaited(
      ClingfyTelemetry.addUiBreadcrumb(
        category: 'ui.license',
        message: 'license_trial_consumed',
        data: {
          'trialExportsRemaining': state.trialExportsRemaining,
          'exportId': exportId,
        },
      ),
    );

    return true;
  }
}
