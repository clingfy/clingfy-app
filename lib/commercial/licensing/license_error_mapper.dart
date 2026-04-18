import 'package:clingfy/commercial/licensing/license_error_codes.dart';
import 'package:clingfy/l10n/app_localizations.dart';

String? localizeLicenseMessage(AppLocalizations l10n, String? message) {
  if (message == null || message.isEmpty) {
    return null;
  }

  switch (message) {
    case LicenseErrorCodes.initializing:
      return l10n.licenseInitializing;
    case LicenseErrorCodes.internetRequired:
      return l10n.licenseInternetRequired;
    case LicenseErrorCodes.offlineCached:
      return l10n.licenseOfflineCached;
    case LicenseErrorCodes.validationFailed:
      return l10n.licenseValidationFailed;
    case LicenseErrorCodes.trialConsumptionFailed:
      return l10n.licenseTrialConsumptionFailed;
    case LicenseErrorCodes.networkUnavailableWhileConsumingTrial:
      return l10n.licenseNetworkUnavailableWhileConsumingTrial;
    case LicenseErrorCodes.keyRequired:
      return l10n.paywallLicenseKeyRequired;
    case LicenseErrorCodes.deactivationFailed:
      return l10n.licenseDeactivateFailed;
    case LicenseErrorCodes.networkUnavailableWhileDeactivatingDevice:
      return l10n.licenseNetworkUnavailableWhileDeactivatingDevice;
    case LicenseErrorCodes.validated:
      return l10n.licenseValidated;
    case LicenseErrorCodes.notEntitled:
      return l10n.licenseNotEntitled;
    case LicenseErrorCodes.notFound:
      return l10n.licenseDeactivateUnavailable;
    default:
      return message;
  }
}
