enum StorageHealthStatus { healthy, warning, critical }

class StorageSnapshot {
  const StorageSnapshot({
    required this.systemTotalBytes,
    required this.systemAvailableBytes,
    required this.recordingsBytes,
    required this.tempBytes,
    required this.logsBytes,
    required this.recordingsPath,
    required this.tempPath,
    required this.logsPath,
    required this.warningThresholdBytes,
    required this.criticalThresholdBytes,
  });

  final int systemTotalBytes;
  final int systemAvailableBytes;
  final int recordingsBytes;
  final int tempBytes;
  final int logsBytes;
  final String recordingsPath;
  final String tempPath;
  final String logsPath;
  final int warningThresholdBytes;
  final int criticalThresholdBytes;

  int get systemUsedBytes {
    final used = systemTotalBytes - systemAvailableBytes;
    if (used <= 0) return 0;
    if (used >= systemTotalBytes) return systemTotalBytes;
    return used;
  }

  int get clingfyTotalBytes => recordingsBytes + tempBytes + logsBytes;

  StorageHealthStatus get status {
    if (systemAvailableBytes < criticalThresholdBytes) {
      return StorageHealthStatus.critical;
    }
    if (systemAvailableBytes < warningThresholdBytes) {
      return StorageHealthStatus.warning;
    }
    return StorageHealthStatus.healthy;
  }

  bool get isWarning => status == StorageHealthStatus.warning;
  bool get isCritical => status == StorageHealthStatus.critical;

  Map<String, dynamic> toMap() {
    return {
      'systemTotalBytes': systemTotalBytes,
      'systemAvailableBytes': systemAvailableBytes,
      'recordingsBytes': recordingsBytes,
      'tempBytes': tempBytes,
      'logsBytes': logsBytes,
      'recordingsPath': recordingsPath,
      'tempPath': tempPath,
      'logsPath': logsPath,
      'warningThresholdBytes': warningThresholdBytes,
      'criticalThresholdBytes': criticalThresholdBytes,
    };
  }

  factory StorageSnapshot.fromMap(Map<dynamic, dynamic> raw) {
    return StorageSnapshot(
      systemTotalBytes: _asInt(raw['systemTotalBytes']),
      systemAvailableBytes: _asInt(raw['systemAvailableBytes']),
      recordingsBytes: _asInt(raw['recordingsBytes']),
      tempBytes: _asInt(raw['tempBytes']),
      logsBytes: _asInt(raw['logsBytes']),
      recordingsPath: raw['recordingsPath']?.toString() ?? '',
      tempPath: raw['tempPath']?.toString() ?? '',
      logsPath: raw['logsPath']?.toString() ?? '',
      warningThresholdBytes: _asInt(raw['warningThresholdBytes']),
      criticalThresholdBytes: _asInt(raw['criticalThresholdBytes']),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
