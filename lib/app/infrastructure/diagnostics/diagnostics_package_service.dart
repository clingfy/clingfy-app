import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

/// Phase 10.1: one-click diagnostics package.
///
/// Bundles everything a support ticket needs into a single zip: the Dart
/// JSONL logs (the unified log file — native device-probe/preview lines land
/// there too, see docs/logging.md), the stress-harness artifacts from
/// `%LOCALAPPDATA%\Clingfy\Logs`, live capture diagnostics, permission
/// status, the device inventory, app version/build info, a count of
/// recording files stranded in the temp folder, and the most recent project
/// manifest (sanitized). Every section is best-effort: a missing file or a
/// failing collector is skipped and recorded in the zip's own
/// `package_manifest.json`, never thrown.
class DiagnosticsPackageService {
  DiagnosticsPackageService({
    required this.captureDiagnostics,
    required this.permissionStatus,
    required this.deviceInventory,
    required this.appInfo,
    this.dartLogsDir,
    this.nativeLogsDir,
    this.recordingsRoot,
    this.tempDir,
    required this.outputDir,
  });

  /// Native `getCaptureDiagnostics` reply (null when unavailable).
  final Future<Map<String, dynamic>?> Function() captureDiagnostics;

  /// Native `getPermissionStatus` reply.
  final Future<Map<String, dynamic>?> Function() permissionStatus;

  /// Display + camera + audio device inventory.
  final Future<Map<String, dynamic>?> Function() deviceInventory;

  /// App name / version / build / OS info.
  final Future<Map<String, dynamic>?> Function() appInfo;

  final Directory? dartLogsDir;
  final Directory? nativeLogsDir;
  final Directory? recordingsRoot;
  final Directory? tempDir;
  final Directory outputDir;

  /// How many of the newest Dart JSONL logs to include.
  static const int maxDartLogFiles = 3;

  /// Per-file cap — only the newest bytes of an oversized log travel.
  static const int maxLogFileBytes = 2 * 1024 * 1024;

  /// Only the stress-harness measurement artifact survives here — the old
  /// `device_probe.log` / `stage2a_2_native.log` side files are retired
  /// (their lines flow through the unified JSONL log now), and bundling
  /// them would ship stale pre-upgrade content that misleads support.
  static const List<String> nativeLogFileNames = ['phase5_cycles.log'];

  /// Redact values whose key suggests a filesystem path or a device
  /// identifier. Device ids embed user-identifying hardware strings and
  /// paths embed the username; neither helps a support ticket.
  static Object? sanitizeMetadataValue(String key, Object? value) {
    final lower = key.toLowerCase();
    final sensitive =
        lower.contains('path') ||
        lower.contains('deviceid') ||
        lower.contains('device_id');
    if (!sensitive) return value;
    return value == null ? null : '<redacted>';
  }

  /// Deep-copy [node] with [sanitizeMetadataValue] applied to every map
  /// entry (lists and nested maps included).
  static Object? sanitizeProjectMetadata(Object? node) {
    if (node is Map) {
      final out = <String, Object?>{};
      node.forEach((key, value) {
        final k = key.toString();
        if (value is Map || value is List) {
          out[k] = sanitizeProjectMetadata(value);
        } else {
          out[k] = sanitizeMetadataValue(k, value);
        }
      });
      return out;
    }
    if (node is List) {
      return node.map(sanitizeProjectMetadata).toList();
    }
    return node;
  }

  /// Build the zip. Returns the written file. Only throws when the output
  /// zip itself cannot be written — content sections never throw.
  Future<File> buildPackage({DateTime? now}) async {
    final stamp = now ?? DateTime.now();
    final archive = Archive();
    final included = <String>[];
    final skipped = <String, String>{};

    Future<void> addJsonSection(
      String entryName,
      Future<Map<String, dynamic>?> Function() collect,
    ) async {
      try {
        final data = await collect();
        if (data == null) {
          skipped[entryName] = 'collector returned null';
          return;
        }
        archive.addFile(
          ArchiveFile.string(
            entryName,
            const JsonEncoder.withIndent('  ').convert(data),
          ),
        );
        included.add(entryName);
      } catch (e) {
        skipped[entryName] = e.toString();
      }
    }

    void addFileTail(String entryName, File file) {
      try {
        if (!file.existsSync()) {
          skipped[entryName] = 'file does not exist';
          return;
        }
        final length = file.lengthSync();
        List<int> bytes;
        if (length > maxLogFileBytes) {
          final raf = file.openSync();
          try {
            raf.setPositionSync(length - maxLogFileBytes);
            bytes = raf.readSync(maxLogFileBytes);
          } finally {
            raf.closeSync();
          }
        } else {
          bytes = file.readAsBytesSync();
        }
        archive.addFile(ArchiveFile.bytes(entryName, bytes));
        included.add(entryName);
      } catch (e) {
        skipped[entryName] = e.toString();
      }
    }

    // Dart JSONL logs — newest first, capped.
    final dartLogs = _newestDartLogs();
    if (dartLogs.isEmpty) {
      skipped['logs/dart/'] = 'no log files found';
    }
    for (final file in dartLogs) {
      addFileTail('logs/dart/${_baseName(file.path)}', file);
    }

    // Native logs.
    final nativeDir = nativeLogsDir;
    if (nativeDir == null) {
      skipped['logs/native/'] = 'no native logs directory on this platform';
    } else {
      for (final name in nativeLogFileNames) {
        addFileTail(
          'logs/native/$name',
          File('${nativeDir.path}${Platform.pathSeparator}$name'),
        );
      }
    }

    await addJsonSection(
      'diagnostics/capture_diagnostics.json',
      captureDiagnostics,
    );
    await addJsonSection('diagnostics/permissions.json', permissionStatus);
    await addJsonSection('diagnostics/devices.json', deviceInventory);
    await addJsonSection('diagnostics/app_info.json', appInfo);
    await addJsonSection(
      'diagnostics/temp_orphans.json',
      () async => _scanTempOrphans(),
    );

    // Most recent project manifest, sanitized.
    try {
      final manifest = _newestProjectManifest();
      if (manifest == null) {
        skipped['project/manifest.sanitized.json'] = 'no project found';
      } else {
        final decoded = jsonDecode(manifest.readAsStringSync());
        archive.addFile(
          ArchiveFile.string(
            'project/manifest.sanitized.json',
            const JsonEncoder.withIndent(
              '  ',
            ).convert(sanitizeProjectMetadata(decoded)),
          ),
        );
        included.add('project/manifest.sanitized.json');
      }
    } catch (e) {
      skipped['project/manifest.sanitized.json'] = e.toString();
    }

    // The zip's own table of contents: what made it in and what didn't —
    // so an incomplete bundle is self-describing instead of mysterious.
    archive.addFile(
      ArchiveFile.string(
        'package_manifest.json',
        const JsonEncoder.withIndent('  ').convert({
          'generatedAt': stamp.toUtc().toIso8601String(),
          'included': included,
          'skipped': skipped,
        }),
      ),
    );

    // NOTE the dash: %TEMP%\clingfy_* is the in-flight recording namespace
    // that the orphan scan watches — the diagnostics zip must not match it.
    final name = 'clingfy-diagnostics-${_fileStamp(stamp)}.zip';
    final out = File('${outputDir.path}${Platform.pathSeparator}$name');
    out.writeAsBytesSync(ZipEncoder().encode(archive));
    return out;
  }

  List<File> _newestDartLogs() {
    final dir = dartLogsDir;
    if (dir == null || !dir.existsSync()) return const [];
    try {
      final files =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => _baseName(f.path).startsWith('logs_'))
              .toList()
            ..sort((a, b) => _baseName(b.path).compareTo(_baseName(a.path)));
      return files.take(maxDartLogFiles).toList();
    } catch (_) {
      return const [];
    }
  }

  Map<String, dynamic> _scanTempOrphans() {
    final dir = tempDir;
    if (dir == null || !dir.existsSync()) {
      return {'fileCount': 0, 'totalBytes': 0};
    }
    var count = 0;
    var bytes = 0;
    try {
      for (final entry in dir.listSync()) {
        if (entry is! File) continue;
        if (!_baseName(entry.path).startsWith('clingfy_')) continue;
        count++;
        try {
          bytes += entry.lengthSync();
        } catch (_) {}
      }
    } catch (_) {}
    return {'fileCount': count, 'totalBytes': bytes};
  }

  File? _newestProjectManifest() {
    final root = recordingsRoot;
    if (root == null || !root.existsSync()) return null;
    File? newest;
    DateTime newestTime = DateTime.fromMillisecondsSinceEpoch(0);
    for (final entry in root.listSync()) {
      if (entry is! Directory) continue;
      // The on-disk manifest is `project.json` on both platforms
      // (recording_project_writer.cpp / RecordingProjectPaths.swift).
      final manifest = File(
        '${entry.path}${Platform.pathSeparator}project.json',
      );
      if (!manifest.existsSync()) continue;
      final modified = manifest.lastModifiedSync();
      if (modified.isAfter(newestTime)) {
        newestTime = modified;
        newest = manifest;
      }
    }
    return newest;
  }

  static String _baseName(String path) {
    final cut = path.lastIndexOf(Platform.pathSeparator);
    return cut < 0 ? path : path.substring(cut + 1);
  }

  static String _fileStamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}
