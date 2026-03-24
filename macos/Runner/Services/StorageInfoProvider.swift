import Foundation

struct StorageSnapshotPayload {
  let systemTotalBytes: Int64
  let systemAvailableBytes: Int64
  let recordingsBytes: Int64
  let tempBytes: Int64
  let logsBytes: Int64
  let recordingsPath: String
  let tempPath: String
  let logsPath: String
  let warningThresholdBytes: Int64
  let criticalThresholdBytes: Int64

  func asMap() -> [String: Any] {
    [
      "systemTotalBytes": Int(systemTotalBytes),
      "systemAvailableBytes": Int(systemAvailableBytes),
      "recordingsBytes": Int(recordingsBytes),
      "tempBytes": Int(tempBytes),
      "logsBytes": Int(logsBytes),
      "recordingsPath": recordingsPath,
      "tempPath": tempPath,
      "logsPath": logsPath,
      "warningThresholdBytes": Int(warningThresholdBytes),
      "criticalThresholdBytes": Int(criticalThresholdBytes),
    ]
  }
}

enum StorageInfoProvider {
  static let warningThresholdBytes: Int64 = 20 * 1024 * 1024 * 1024
  static let criticalThresholdBytes: Int64 = 10 * 1024 * 1024 * 1024

  static func buildSnapshot(
    captureDestinationURL: URL,
    recordingsURL: URL,
    tempURL: URL,
    logsURL: URL,
    fileManager: FileManager = .default
  ) -> StorageSnapshotPayload {
    let (systemTotalBytes, systemAvailableBytes) = volumeCapacity(for: captureDestinationURL, fileManager: fileManager)

    return StorageSnapshotPayload(
      systemTotalBytes: systemTotalBytes,
      systemAvailableBytes: systemAvailableBytes,
      recordingsBytes: directorySize(recordingsURL, fileManager: fileManager),
      tempBytes: directorySize(tempURL, fileManager: fileManager),
      logsBytes: directorySize(logsURL, fileManager: fileManager),
      recordingsPath: recordingsURL.path,
      tempPath: tempURL.path,
      logsPath: logsURL.path,
      warningThresholdBytes: warningThresholdBytes,
      criticalThresholdBytes: criticalThresholdBytes
    )
  }

  static func availableCapacity(for url: URL, fileManager: FileManager = .default) -> Int64? {
    let targetURL = lookupURL(for: url, fileManager: fileManager)
    do {
      let values = try targetURL.resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
      ])
      if let value = values.volumeAvailableCapacityForImportantUsage {
        return Int64(value)
      }
      if let value = values.volumeAvailableCapacity {
        return Int64(value)
      }
    } catch {
      NativeLogger.w(
        "StorageInfo", "Failed reading volume capacity",
        context: ["path": targetURL.path, "error": error.localizedDescription])
    }

    do {
      let attrs = try fileManager.attributesOfFileSystem(forPath: targetURL.path)
      if let value = attrs[.systemFreeSize] as? NSNumber {
        return value.int64Value
      }
      if let value = attrs[.systemFreeSize] as? Int64 {
        return value
      }
      if let value = attrs[.systemFreeSize] as? UInt64 {
        return value > UInt64(Int64.max) ? Int64.max : Int64(value)
      }
    } catch {
      NativeLogger.w(
        "StorageInfo", "Failed reading filesystem free size",
        context: ["path": targetURL.path, "error": error.localizedDescription])
    }

    return nil
  }

  static func volumeCapacity(for url: URL, fileManager: FileManager = .default) -> (Int64, Int64) {
    let targetURL = lookupURL(for: url, fileManager: fileManager)

    var totalBytes: Int64 = 0
    var availableBytes: Int64 = 0

    do {
      let values = try targetURL.resourceValues(forKeys: [
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
      ])
      if let total = values.volumeTotalCapacity {
        totalBytes = Int64(total)
      }
      if let available = values.volumeAvailableCapacityForImportantUsage {
        availableBytes = Int64(available)
      } else if let available = values.volumeAvailableCapacity {
        availableBytes = Int64(available)
      }
    } catch {
      NativeLogger.w(
        "StorageInfo", "Failed reading volume totals",
        context: ["path": targetURL.path, "error": error.localizedDescription])
    }

    if totalBytes == 0 || availableBytes == 0 {
      do {
        let attrs = try fileManager.attributesOfFileSystem(forPath: targetURL.path)
        if totalBytes == 0 {
          if let value = attrs[.systemSize] as? NSNumber {
            totalBytes = value.int64Value
          } else if let value = attrs[.systemSize] as? Int64 {
            totalBytes = value
          } else if let value = attrs[.systemSize] as? UInt64 {
            totalBytes = value > UInt64(Int64.max) ? Int64.max : Int64(value)
          }
        }
        if availableBytes == 0 {
          if let value = attrs[.systemFreeSize] as? NSNumber {
            availableBytes = value.int64Value
          } else if let value = attrs[.systemFreeSize] as? Int64 {
            availableBytes = value
          } else if let value = attrs[.systemFreeSize] as? UInt64 {
            availableBytes = value > UInt64(Int64.max) ? Int64.max : Int64(value)
          }
        }
      } catch {
        NativeLogger.w(
          "StorageInfo", "Failed reading filesystem totals",
          context: ["path": targetURL.path, "error": error.localizedDescription])
      }
    }

    return (max(totalBytes, 0), max(availableBytes, 0))
  }

  static func directorySize(_ url: URL, fileManager: FileManager = .default) -> Int64 {
    guard fileManager.fileExists(atPath: url.path) else { return 0 }

    let keys: [URLResourceKey] = [
      .isRegularFileKey,
      .fileAllocatedSizeKey,
      .totalFileAllocatedSizeKey,
    ]

    guard let enumerator = fileManager.enumerator(
      at: url,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles]
    ) else {
      return 0
    }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      let values = try? fileURL.resourceValues(forKeys: Set(keys))
      guard values?.isRegularFile == true else { continue }
      let allocatedSize = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
      total += Int64(allocatedSize)
    }
    return total
  }

  private static func lookupURL(for url: URL, fileManager: FileManager = .default) -> URL {
    let normalized = url.standardizedFileURL
    if fileManager.fileExists(atPath: normalized.path) {
      return normalized
    }
    return normalized.deletingLastPathComponent()
  }
}
