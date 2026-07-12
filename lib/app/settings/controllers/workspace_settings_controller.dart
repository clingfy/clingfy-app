import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clingfy/app/infrastructure/diagnostics/diagnostics_package_service.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';

class WorkspaceSettingsController extends ChangeNotifier {
  WorkspaceSettingsController({required NativeBridge nativeBridge})
    : _nativeBridge = nativeBridge;

  static const String logFileNotFoundErrorCode = 'LOG_FILE_NOT_FOUND';
  static const String logFileUnavailableErrorCode = 'LOG_FILE_UNAVAILABLE';

  final NativeBridge _nativeBridge;
  static const String _prefSaveFolderPath = 'saveFolderPath';
  static const String _prefWarnBeforeClosingUnexportedRecording =
      'warnBeforeClosingUnexportedRecording';
  static const String _prefShowPreRecordingActionBar =
      'showPreRecordingActionBar';
  static const String _prefVerboseLogging = 'verboseLogging';

  bool _openFolderAfterStop = false;
  bool _openFolderAfterExport = true;
  bool _warnBeforeClosingUnexportedRecording = true;
  bool _showPreRecordingActionBar = true;
  bool _verboseLogging = false;
  String? _saveFolderPath;
  bool _didAutoOpenSaveFolderThisSession = false;

  bool get openFolderAfterStop => _openFolderAfterStop;
  bool get openFolderAfterExport => _openFolderAfterExport;
  bool get warnBeforeClosingUnexportedRecording =>
      _warnBeforeClosingUnexportedRecording;
  bool get showPreRecordingActionBar => _showPreRecordingActionBar;

  /// When on, logging drops to DEBUG verbosity on both the Dart and native
  /// sides — for capturing a hard-to-reproduce issue on a release build without
  /// a custom build. Persisted; the env var [Log.logLevelEnvVar] is the other
  /// way to enable it.
  bool get verboseLogging => _verboseLogging;
  String? get saveFolderPath => _saveFolderPath;

  Future<void> loadPreferences(SharedPreferences prefs) async {
    _openFolderAfterStop = prefs.getBool('openFolderAfterStop') ?? false;
    _openFolderAfterExport = prefs.getBool('openFolderAfterExport') ?? true;
    _warnBeforeClosingUnexportedRecording =
        prefs.getBool(_prefWarnBeforeClosingUnexportedRecording) ?? true;
    _showPreRecordingActionBar =
        prefs.getBool(_prefShowPreRecordingActionBar) ?? true;
    _verboseLogging = prefs.getBool(_prefVerboseLogging) ?? false;
    // Only force verbose here: when off we leave the level resolved at startup
    // (which already honors the env var / build default) untouched.
    if (_verboseLogging) {
      await _applyLogVerbosity(true);
    }
    _saveFolderPath = prefs.getString(_prefSaveFolderPath);
    if (_saveFolderPath == null || _saveFolderPath!.isEmpty) {
      await _loadSaveFolder(prefs);
    }
    notifyListeners();
  }

  /// Sets the Dart log threshold and mirrors it to the native logger so both
  /// sides agree.
  Future<void> _applyLogVerbosity(bool enabled) async {
    final level = Log.setVerbose(enabled);
    try {
      await _nativeBridge.setNativeLogLevel(level.name);
    } catch (e, st) {
      Log.e('Settings', 'Failed to push native log level', e, st);
    }
  }

  Future<void> setVerboseLogging(bool value) async {
    if (value == _verboseLogging) return;
    _verboseLogging = value;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool(_prefVerboseLogging, value);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist verbose logging preference', e, st);
    }

    await _applyLogVerbosity(value);
  }

  Future<void> _cacheSaveFolderPath(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null || path.isEmpty) {
      await prefs.remove(_prefSaveFolderPath);
    } else {
      await prefs.setString(_prefSaveFolderPath, path);
    }
  }

  Future<void> _loadSaveFolder(SharedPreferences prefs) async {
    try {
      final path = await _nativeBridge.invokeMethod<String>('getSaveFolder');
      _saveFolderPath = path;
      if (path == null || path.isEmpty) {
        await prefs.remove(_prefSaveFolderPath);
      } else {
        await prefs.setString(_prefSaveFolderPath, path);
      }
    } catch (e, st) {
      Log.e('Settings', 'Error loading save folder', e, st);
    }
  }

  Future<void> updateOpenFolderAfterStop(bool value) async {
    if (value == _openFolderAfterStop) return;
    _openFolderAfterStop = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool('openFolderAfterStop', value);
    } catch (e, st) {
      Log.e(
        'Settings',
        'Failed to persist open folder after stop setting',
        e,
        st,
      );
    }
  }

  Future<void> updateOpenFolderAfterExport(bool value) async {
    if (value == _openFolderAfterExport) return;
    _openFolderAfterExport = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool('openFolderAfterExport', value);
    } catch (e, st) {
      Log.e(
        'Settings',
        'Failed to persist open folder after export setting',
        e,
        st,
      );
    }
  }

  Future<void> updateWarnBeforeClosingUnexportedRecording(bool value) async {
    if (value == _warnBeforeClosingUnexportedRecording) return;
    _warnBeforeClosingUnexportedRecording = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool(_prefWarnBeforeClosingUnexportedRecording, value);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist close warning preference', e, st);
    }
  }

  Future<void> updateShowPreRecordingActionBar(bool value) async {
    if (value == _showPreRecordingActionBar) return;
    _showPreRecordingActionBar = value;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool(_prefShowPreRecordingActionBar, value);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist action bar preference', e, st);
    }

    try {
      await _nativeBridge.setPreRecordingBarEnabled(value);
    } catch (e, st) {
      Log.e('Settings', 'Failed to update native action bar preference', e, st);
    }
  }

  Future<String?> chooseSaveFolderPath() async {
    try {
      final path = await _nativeBridge.invokeMethod<String>('chooseSaveFolder');
      if (path != null) {
        _saveFolderPath = path;
        await _cacheSaveFolderPath(path);
        notifyListeners();
      }
      return path;
    } catch (e, st) {
      Log.e('Settings', 'Error choosing save folder', e, st);
      return null;
    }
  }

  Future<void> chooseSaveFolder() async {
    await chooseSaveFolderPath();
  }

  Future<void> resetSaveFolder() async {
    try {
      final path = await _nativeBridge.invokeMethod<String>('resetSaveFolder');
      _saveFolderPath = path;
      await _cacheSaveFolderPath(path);
      notifyListeners();
    } catch (e, st) {
      Log.e('Settings', 'Error resetting save folder', e, st);
    }
  }

  Future<bool> _openSaveFolderNative() async {
    try {
      // The chosen folder is persisted Dart-side, so pass it along: Windows
      // opens exactly this path (falling back to its default when absent);
      // macOS persists the folder natively and ignores the argument.
      await _nativeBridge.invokeMethod<void>('openSaveFolder', {
        if (_saveFolderPath != null) 'path': _saveFolderPath,
      });
      return true;
    } catch (e, st) {
      Log.e('Settings', 'Error opening save folder', e, st);
      return false;
    }
  }

  Future<bool> openSaveFolderOncePerSession() async {
    if (_didAutoOpenSaveFolderThisSession) {
      return false;
    }

    final didOpen = await _openSaveFolderNative();
    if (didOpen) {
      _didAutoOpenSaveFolderThisSession = true;
    }
    return didOpen;
  }

  Future<void> openSaveFolder() async {
    await _openSaveFolderNative();
  }

  Future<void> revealFile(String path) async {
    try {
      await _nativeBridge.invokeMethod<void>('revealFile', {'path': path});
    } catch (e, st) {
      Log.e('Settings', 'Error revealing file', e, st);
    }
  }

  Future<String?> getTodayLogFilePath() async {
    try {
      return await _nativeBridge.invokeMethod<String>('getTodayLogFilePath');
    } catch (e) {
      Log.w('Settings', 'Error getting today log path: $e');
      return null;
    }
  }

  Future<void> revealTodayLogFile() async {
    try {
      await _nativeBridge.invokeMethod<void>('revealTodayLogFile');
    } on PlatformException catch (e) {
      // Rethrow the CODE, not the human message — the diagnostics section
      // matches StateError.message against the LOG_FILE_* code constants to
      // pick the specific localized string. (Previously this threw
      // e.message, so the specific messages were unreachable on both
      // platforms and every error rendered the generic fallback.)
      throw StateError(e.code);
    } catch (e, st) {
      Log.e('Settings', 'Error revealing today log file', e, st);
      rethrow;
    }
  }

  Future<void> revealLogsFolder() async {
    try {
      await _nativeBridge.invokeMethod<void>('revealLogsFolder');
    } catch (e, st) {
      Log.e('Settings', 'Error revealing logs folder', e, st);
    }
  }

  Future<void> copyTodayLogFilePathToClipboard() async {
    final path = await getTodayLogFilePath();
    if (path != null) {
      await Clipboard.setData(ClipboardData(text: path));
    } else {
      throw StateError(logFileUnavailableErrorCode);
    }
  }

  /// Phase 10.1: build the one-click diagnostics zip and reveal it.
  /// Returns the zip path, or null on failure (logged).
  Future<String?> exportDiagnosticsPackage() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dartLogs = Directory(
        '${support.path}${Platform.pathSeparator}Logs',
      );
      Directory? nativeLogs;
      Directory? recordingsRoot;
      if (Platform.isWindows) {
        // Mirrors the native Services/log_locations.cpp resolution
        // (CLINGFY_NATIVE_LOG_DIR override → %LOCALAPPDATA%\Clingfy\Logs).
        final overrideDir = Platform.environment['CLINGFY_NATIVE_LOG_DIR'];
        final localAppData = Platform.environment['LOCALAPPDATA'];
        if (overrideDir != null && overrideDir.isNotEmpty) {
          nativeLogs = Directory(overrideDir);
        } else if (localAppData != null && localAppData.isNotEmpty) {
          nativeLogs = Directory('$localAppData\\Clingfy\\Logs');
        }
        if (localAppData != null && localAppData.isNotEmpty) {
          recordingsRoot = Directory('$localAppData\\Clingfy\\recordings');
        }
      }

      Future<Object?> tryInvokeList(String method) async {
        try {
          return await _nativeBridge.invokeMethod<List<dynamic>>(method);
        } catch (e) {
          return 'unavailable: $e';
        }
      }

      final service = DiagnosticsPackageService(
        captureDiagnostics: () async =>
            (await _nativeBridge.invokeMethod<Map<dynamic, dynamic>>(
              'getCaptureDiagnostics',
            ))?.map<String, dynamic>((k, v) => MapEntry(k.toString(), v)),
        permissionStatus: () async => _nativeBridge.getPermissionStatus(),
        deviceInventory: () async => <String, dynamic>{
          'displays': await tryInvokeList('getDisplays'),
          'cameras': await tryInvokeList('getVideoSources'),
          'audioInputs': await tryInvokeList('getAudioSources'),
        },
        appInfo: () async {
          final info = await PackageInfo.fromPlatform();
          return <String, dynamic>{
            'appName': info.appName,
            'version': info.version,
            'buildNumber': info.buildNumber,
            'os': Platform.operatingSystem,
            'osVersion': Platform.operatingSystemVersion,
          };
        },
        dartLogsDir: dartLogs,
        nativeLogsDir: nativeLogs,
        recordingsRoot: recordingsRoot,
        tempDir: Directory.systemTemp,
        outputDir: Directory.systemTemp,
      );
      final zip = await service.buildPackage();
      await revealFile(zip.path);
      return zip.path;
    } catch (e, st) {
      Log.e('Settings', 'Error exporting diagnostics package', e, st);
      return null;
    }
  }
}
