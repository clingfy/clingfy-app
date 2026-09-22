// lib/controllers/license_controller.dart
import 'dart:async';

import 'package:flutter/widgets.dart';
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

class LicenseController extends ChangeNotifier with WidgetsBindingObserver {
  /// How long to wait before a second unverified-state retry is allowed.
  ///
  /// Every resume is a retry opportunity, and a desktop recorder gets resumed
  /// constantly — alt-tab, moving between the editor and another app. Without
  /// a floor, a user sitting through a backend outage would post a validate
  /// call on every window focus. Long enough to be quiet, short enough that a
  /// recovered backend is noticed within about a minute of the user coming
  /// back to the app.
  static const Duration revalidateCooldown = Duration(seconds: 60);

  final LicenseService _service;
  final Uuid _uuid;
  final DateTime Function() _now;

  LicenseController({
    LicenseService? service,
    Uuid? uuid,
    DateTime Function()? now, // Fake clock in tests; see revalidateCooldown
  }) : _service = service ?? LicenseService(),
       _uuid = uuid ?? const Uuid(),
       _now = now ?? DateTime.now;

  bool isLoading = true;
  String? currentKey;
  LicenseState state = LicenseState.error(LicenseErrorCodes.initializing);
  String? deactivationError;
  bool _initialized = false;
  DateTime? _lastRevalidateAt;
  Future<void>? _inFlight;

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

  /// True when the last answer came from the grace path rather than the
  /// server. See [LicenseState.isUnverified].
  bool get isUnverified => state.isUnverified;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    // Registered before the first check so a resume that lands while the
    // initial validate is still in flight is not lost. Guarded because a
    // binding is not guaranteed in every host (plain `flutter test` without
    // a widget binding, for one) and a throw here would otherwise leave the
    // controller permanently `isLoading` with `_initialized` already set.
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {
      // No binding: the resume hook simply does not exist. Every other
      // revalidation trigger still works.
    }
    await refreshEntitlement();
  }

  // The parameter must keep the overridden name, so it shadows this class's
  // own `state` field for the length of this method. Nothing here reads the
  // field, so the shadowing is contained.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(revalidateIfUnverified());
    }
  }

  @override
  void dispose() {
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {
      // Never registered; nothing to undo.
    }
    super.dispose();
  }

  /// Re-asks the server, but only when the last answer was not the server's.
  ///
  /// Fixes the shape where one bad response outlived the thing that caused it:
  /// `refreshEntitlement()` ran once at launch and assigned `state`
  /// unconditionally, so a user who opened the app during an outage stayed
  /// downgraded for the whole session even after the backend came back. They
  /// had to quit and relaunch to get their licence recognised. With Clingfy's
  /// dev API parked at zero tasks by design, that was the ordinary dev
  /// experience rather than a rare one.
  ///
  /// Does nothing when the state is a real verdict, when a check is already in
  /// flight, or inside [revalidateCooldown] of the last attempt. Unlike
  /// [refreshEntitlement] it does NOT touch [isLoading]: that flag means "a
  /// user-initiated licence operation is running" and several widgets render
  /// spinners off it, so a background retry must not make the settings panel
  /// and the paywall flicker on every window focus.
  Future<void> revalidateIfUnverified({bool force = false}) async {
    if (!state.isUnverified) return;
    final pending = _inFlight;
    if (pending != null) return pending;

    final last = _lastRevalidateAt;
    if (!force &&
        last != null &&
        _now().difference(last) < revalidateCooldown) {
      return;
    }

    final run = _runRevalidation();
    _inFlight = run;
    try {
      await run;
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _runRevalidation() async {
    _lastRevalidateAt = _now();
    final key = await _service.readStoredLicenseKey();
    final refreshed = await _service.validateLicense(key);

    // Only adopt an answer that is better than the one we have. A retry that
    // hits the same outage returns another cached/no-internet state, and
    // replacing one unverified state with another would just churn listeners.
    if (refreshed.isUnverified && state.isUnverified) return;

    currentKey = key;
    state = refreshed;
    notifyListeners();
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
