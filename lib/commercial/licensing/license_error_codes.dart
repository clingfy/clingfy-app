abstract class LicenseErrorCodes {
  LicenseErrorCodes._();

  static const String initializing = 'LICENSE_INITIALIZING';
  static const String internetRequired = 'LICENSE_INTERNET_REQUIRED';
  static const String offlineCached = 'LICENSE_OFFLINE_CACHED';
  static const String validationFailed = 'LICENSE_VALIDATION_FAILED';
  static const String trialConsumptionFailed =
      'LICENSE_TRIAL_CONSUMPTION_FAILED';
  static const String networkUnavailableWhileConsumingTrial =
      'LICENSE_NETWORK_UNAVAILABLE_WHILE_CONSUMING_TRIAL';
  static const String keyRequired = 'LICENSE_KEY_REQUIRED';
  static const String deactivationFailed = 'LICENSE_DEACTIVATION_FAILED';
  static const String networkUnavailableWhileDeactivatingDevice =
      'LICENSE_NETWORK_UNAVAILABLE_WHILE_DEACTIVATING_DEVICE';
  static const String validated = 'LICENSE_VALIDATED';
  static const String notEntitled = 'LICENSE_NOT_ENTITLED';
  static const String notFound = 'LICENSE_NOT_FOUND';
}
