import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:clingfy/app/infrastructure/diagnostics/diagnostics_package_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late Directory dartLogs;
  late Directory nativeLogs;
  late Directory recordings;
  late Directory temp;
  late Directory output;

  setUp(() {
    root = Directory.systemTemp.createTempSync('clingfy_diag_test');
    dartLogs = Directory('${root.path}/DartLogs')..createSync();
    nativeLogs = Directory('${root.path}/NativeLogs')..createSync();
    recordings = Directory('${root.path}/recordings')..createSync();
    temp = Directory('${root.path}/Temp')..createSync();
    output = Directory('${root.path}/out')..createSync();
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  DiagnosticsPackageService buildService({
    Future<Map<String, dynamic>?> Function()? captureDiagnostics,
  }) {
    return DiagnosticsPackageService(
      captureDiagnostics:
          captureDiagnostics ?? () async => {'backend': 'windows_mf'},
      permissionStatus: () async => {'microphone': true, 'camera': false},
      deviceInventory: () async => {
        'displays': ['d1'],
        'cameras': ['c1'],
      },
      appInfo: () async => {'version': '1.0.4', 'buildNumber': '5'},
      dartLogsDir: dartLogs,
      nativeLogsDir: nativeLogs,
      recordingsRoot: recordings,
      tempDir: temp,
      outputDir: output,
    );
  }

  Archive readZip(File zip) => ZipDecoder().decodeBytes(zip.readAsBytesSync());

  String entryText(Archive archive, String name) {
    final file = archive.findFile(name);
    expect(file, isNotNull, reason: 'missing zip entry $name');
    return utf8.decode(file!.readBytes()!);
  }

  test('packages logs, diagnostics sections, and the orphan count', () async {
    File('${dartLogs.path}/logs_2026-06-09.jsonl').writeAsStringSync('{"a":1}');
    File('${dartLogs.path}/logs_2026-06-10.jsonl').writeAsStringSync('{"b":2}');
    File('${nativeLogs.path}/device_probe.log').writeAsStringSync('probe');
    File('${temp.path}/clingfy_abc.mp4').writeAsStringSync('0123456789');
    File('${temp.path}/unrelated.txt').writeAsStringSync('x');

    final zip = await buildService().buildPackage(
      now: DateTime.utc(2026, 6, 10, 12),
    );
    expect(zip.existsSync(), isTrue);
    // The diagnostics zip must NOT collide with the clingfy_* in-flight
    // recording namespace that the orphan scan watches.
    expect(zip.path, contains('clingfy-diagnostics-'));

    final archive = readZip(zip);
    expect(entryText(archive, 'logs/dart/logs_2026-06-10.jsonl'), '{"b":2}');
    expect(entryText(archive, 'logs/dart/logs_2026-06-09.jsonl'), '{"a":1}');
    expect(entryText(archive, 'logs/native/device_probe.log'), 'probe');
    expect(
      jsonDecode(entryText(archive, 'diagnostics/capture_diagnostics.json')),
      {'backend': 'windows_mf'},
    );
    expect(jsonDecode(entryText(archive, 'diagnostics/permissions.json')), {
      'microphone': true,
      'camera': false,
    });
    expect(jsonDecode(entryText(archive, 'diagnostics/temp_orphans.json')), {
      'fileCount': 1,
      'totalBytes': 10,
    });
    expect(jsonDecode(entryText(archive, 'diagnostics/app_info.json')), {
      'version': '1.0.4',
      'buildNumber': '5',
    });

    final manifest =
        jsonDecode(entryText(archive, 'package_manifest.json'))
            as Map<String, dynamic>;
    expect(manifest['included'], contains('logs/native/device_probe.log'));
    // The other two native logs don't exist — skipped, and the manifest
    // says so instead of pretending.
    final skipped = manifest['skipped'] as Map<String, dynamic>;
    expect(skipped, contains('logs/native/stage2a_2_native.log'));
    expect(skipped, contains('logs/native/phase5_cycles.log'));
  });

  test(
    'missing dirs and failing collectors are skipped, never thrown',
    () async {
      dartLogs.deleteSync(recursive: true);
      nativeLogs.deleteSync(recursive: true);
      recordings.deleteSync(recursive: true);

      final zip = await buildService(
        captureDiagnostics: () async => throw StateError('bridge down'),
      ).buildPackage();

      final archive = readZip(zip);
      final manifest =
          jsonDecode(entryText(archive, 'package_manifest.json'))
              as Map<String, dynamic>;
      final skipped = manifest['skipped'] as Map<String, dynamic>;
      expect(
        skipped['diagnostics/capture_diagnostics.json'],
        contains('bridge down'),
      );
      expect(skipped, contains('logs/dart/'));
      expect(skipped, contains('project/manifest.sanitized.json'));
      // Healthy sections still made it.
      expect(
        jsonDecode(entryText(archive, 'diagnostics/permissions.json')),
        isNotEmpty,
      );
    },
  );

  test('caps dart logs at the newest three files', () async {
    for (final day in ['06', '07', '08', '09', '10']) {
      File(
        '${dartLogs.path}/logs_2026-06-$day.jsonl',
      ).writeAsStringSync('{"d":"$day"}');
    }
    final archive = readZip(await buildService().buildPackage());
    final dartEntries = archive.files
        .where((f) => f.name.startsWith('logs/dart/'))
        .map((f) => f.name)
        .toList();
    expect(dartEntries, hasLength(3));
    expect(dartEntries, contains('logs/dart/logs_2026-06-10.jsonl'));
    expect(dartEntries, contains('logs/dart/logs_2026-06-09.jsonl'));
    expect(dartEntries, contains('logs/dart/logs_2026-06-08.jsonl'));
  });

  test(
    'includes the newest project manifest with paths and ids redacted',
    () async {
      final older = Directory('${recordings.path}/proj_old')..createSync();
      File(
        '${older.path}/project.json',
      ).writeAsStringSync(jsonEncode({'name': 'old'}));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final newer = Directory('${recordings.path}/proj_new')..createSync();
      File('${newer.path}/project.json').writeAsStringSync(
        jsonEncode({
          'name': 'new',
          'videoPath': r'C:\Users\u\rec\screen.mov',
          'camera': {'deviceId': r'\\?\usb#vid_1234', 'frames': 337},
        }),
      );

      final archive = readZip(await buildService().buildPackage());
      final manifest =
          jsonDecode(entryText(archive, 'project/manifest.sanitized.json'))
              as Map<String, dynamic>;
      expect(manifest['name'], 'new');
      expect(manifest['videoPath'], '<redacted>');
      expect((manifest['camera'] as Map)['deviceId'], '<redacted>');
      expect((manifest['camera'] as Map)['frames'], 337);
    },
  );

  test('sanitizer redacts by key, preserves structure', () {
    final out =
        DiagnosticsPackageService.sanitizeProjectMetadata({
              'outputPath': 'x',
              'nested': [
                {'device_id': 'y', 'keep': 1},
              ],
              'durationMs': 1200,
            })
            as Map<String, Object?>;
    expect(out['outputPath'], '<redacted>');
    expect(((out['nested'] as List).first as Map)['device_id'], '<redacted>');
    expect(((out['nested'] as List).first as Map)['keep'], 1);
    expect(out['durationMs'], 1200);
  });
}
