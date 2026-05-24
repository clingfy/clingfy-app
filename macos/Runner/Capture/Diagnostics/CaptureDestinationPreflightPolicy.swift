import Foundation

/// Disk-space preflight policy for the capture destination, plus build-environment
/// detection. Pure policy (engine-domain; the free-space query is FS-portable —
/// see windows-port-inventory §7).

enum BuildEnvironment {
  static var isDebugBuild: Bool {
    #if DEBUG
      return true
    #else
      return false
    #endif
  }
}

enum CaptureDestinationPreflightDecision {
  case proceed
  case noAvailableSpace
  case belowCriticalThreshold
}

enum CaptureDestinationPreflightPolicy {
  static func isNonProductionBuild(
    bundleIdentifier: String?,
    isDebugBuild: Bool = BuildEnvironment.isDebugBuild
  ) -> Bool {
    if isDebugBuild {
      return true
    }
    return bundleIdentifier?.lowercased().hasSuffix(".dev") == true
  }

  static func shouldBypassLowStorageCheck(
    requested: Bool,
    bundleIdentifier: String?,
    isDebugBuild: Bool = BuildEnvironment.isDebugBuild
  ) -> Bool {
    guard requested else { return false }
    return isNonProductionBuild(
      bundleIdentifier: bundleIdentifier,
      isDebugBuild: isDebugBuild
    )
  }

  static func decision(
    availableBytes: Int64?,
    requestedBypass: Bool,
    bundleIdentifier: String?,
    isDebugBuild: Bool = BuildEnvironment.isDebugBuild
  ) -> CaptureDestinationPreflightDecision {
    if shouldBypassLowStorageCheck(
      requested: requestedBypass,
      bundleIdentifier: bundleIdentifier,
      isDebugBuild: isDebugBuild
    ) {
      return .proceed
    }

    guard let availableBytes else {
      return .proceed
    }

    if availableBytes <= 0 {
      return .noAvailableSpace
    }

    if availableBytes < StorageInfoProvider.criticalThresholdBytes {
      return .belowCriticalThreshold
    }

    return .proceed
  }
}
