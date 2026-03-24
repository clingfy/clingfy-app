import 'dart:async';

import 'package:flutter/services.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/settings/settings_controller.dart';

class CaptureDiagnostics {
  const CaptureDiagnostics({
    this.backend,
    this.captureFps,
    this.captureDestinationFreeBytes,
    this.recordingsFreeBytes,
    this.saveFolderFreeBytes,
  });

  final String? backend;
  final int? captureFps;
  final int? captureDestinationFreeBytes;
  final int? recordingsFreeBytes;
  final int? saveFolderFreeBytes;

  int? get bestFreeBytes =>
      captureDestinationFreeBytes ?? saveFolderFreeBytes ?? recordingsFreeBytes;

  bool get isEmpty =>
      (backend == null || backend!.trim().isEmpty) &&
      captureFps == null &&
      captureDestinationFreeBytes == null &&
      recordingsFreeBytes == null &&
      saveFolderFreeBytes == null;

  Map<String, dynamic> toMap() {
    return {
      if (backend != null) 'backend': backend,
      if (captureFps != null) 'captureFps': captureFps,
      if (captureDestinationFreeBytes != null)
        'captureDestinationFreeBytes': captureDestinationFreeBytes,
      if (recordingsFreeBytes != null)
        'recordingsFreeBytes': recordingsFreeBytes,
      if (saveFolderFreeBytes != null)
        'saveFolderFreeBytes': saveFolderFreeBytes,
      if (bestFreeBytes != null) 'bestFreeBytes': bestFreeBytes,
    };
  }

  factory CaptureDiagnostics.fromMap(Map<dynamic, dynamic>? raw) {
    if (raw == null) return const CaptureDiagnostics();
    return CaptureDiagnostics(
      backend: raw['backend']?.toString(),
      captureFps: _asInt(raw['captureFps']),
      captureDestinationFreeBytes: _asInt(raw['captureDestinationFreeBytes']),
      recordingsFreeBytes: _asInt(raw['recordingsFreeBytes']),
      saveFolderFreeBytes: _asInt(raw['saveFolderFreeBytes']),
    );
  }

  static int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }
}

class ClingfyTelemetry implements RemoteLogSink {
  ClingfyTelemetry._();

  static final ClingfyTelemetry _instance = ClingfyTelemetry._();
  static const Duration _defaultDiagnosticsTimeout = Duration(milliseconds: 80);

  CaptureDiagnostics _lastDiagnostics = const CaptureDiagnostics();
  WorkflowPhase? _lastPhase;
  String? _activeRecordingId;
  bool _recordingSessionActive = false;

  static RemoteLogSink get logSink => _instance;

  static Future<CaptureDiagnostics> loadCaptureDiagnostics(
    NativeBridge bridge, {
    Duration timeout = _defaultDiagnosticsTimeout,
  }) {
    return _instance._loadCaptureDiagnostics(bridge, timeout: timeout);
  }

  static Future<void> startSession({
    required NativeBridge bridge,
    required String recordingId,
    required SettingsController settings,
    WorkflowPhase phase = WorkflowPhase.startingRecording,
  }) async {
    _instance._activeRecordingId = recordingId;
    _instance._recordingSessionActive = true;
    final diagnostics = await loadCaptureDiagnostics(bridge);
    await syncRecordingScope(
      phase: phase,
      diagnostics: diagnostics,
      settings: settings,
      recordingId: recordingId,
    );
  }

  static Future<void> stopSession({bool clearScope = true}) {
    return _instance._stopSession(clearScope: clearScope);
  }

  static Future<void> syncRecordingScope({
    WorkflowPhase? phase,
    CaptureDiagnostics? diagnostics,
    SettingsController? settings,
    String? recordingId,
  }) {
    return _instance._syncRecordingScope(
      phase: phase,
      diagnostics: diagnostics,
      settings: settings,
      recordingId: recordingId,
    );
  }

  static Future<void> captureError(
    Object error, {
    StackTrace? stackTrace,
    String? method,
    Map<String, dynamic>? context,
    CaptureDiagnostics? diagnostics,
  }) {
    return _instance._captureError(
      error,
      stackTrace: stackTrace,
      method: method,
      context: context,
      diagnostics: diagnostics,
    );
  }

  // Compatibility wrapper for current callsites.
  static Future<void> captureNativeMethodChannelError({
    required String method,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) {
    return captureError(
      error,
      stackTrace: stackTrace,
      method: method,
      context: context,
    );
  }

  // Compatibility wrapper for current callsites.
  static Future<void> clearRecordingSessionScope() => stopSession();

  // Compatibility wrapper for current callsites.
  static Future<void> applyRecordingSessionScope({
    required String phase,
    required int fps,
    required String resolutionPreset,
    String? backend,
    int? diskFreeBytes,
    String? recordingId,
  }) async {
    final normalizedBackend = _normalizeBackend(backend);
    final diskFreeMiBTag = _toMiBTag(diskFreeBytes);
    _instance._activeRecordingId = recordingId ?? _instance._activeRecordingId;
    await Sentry.configureScope((scope) async {
      await scope.setTag('recording.phase', phase);
      await scope.setTag('recording.fps', '$fps');
      await scope.setTag('recording.resolution', resolutionPreset);
      await scope.setTag('recording.backend', normalizedBackend);
      if (_instance._activeRecordingId != null &&
          _instance._activeRecordingId!.isNotEmpty) {
        await scope.setTag('recording.id', _instance._activeRecordingId!);
      } else {
        await scope.removeTag('recording.id');
      }
      if (diskFreeMiBTag != null) {
        await scope.setTag('recording.disk_free_mib', diskFreeMiBTag);
      } else {
        await scope.removeTag('recording.disk_free_mib');
      }
      await scope.setContexts('recording_session', {
        'active': phase != WorkflowPhase.idle.name,
        'phase': phase,
        'fps': fps,
        'resolutionPreset': resolutionPreset,
        'backend': normalizedBackend,
        'recordingId': _instance._activeRecordingId,
        'diskFreeBytes': diskFreeBytes,
      });
    });
  }

  static Future<void> addBreadcrumb({
    required String category,
    required String message,
    SentryLevel level = SentryLevel.info,
    String type = 'default',
    Map<String, dynamic>? data,
    CaptureDiagnostics? diagnostics,
  }) {
    return _instance._addBreadcrumb(
      category: category,
      message: message,
      level: level,
      type: type,
      data: data,
      diagnostics: diagnostics,
    );
  }

  static Future<void> addUiBreadcrumb({
    required String category,
    required String message,
    SentryLevel level = SentryLevel.info,
    Map<String, dynamic>? data,
    CaptureDiagnostics? diagnostics,
  }) {
    return addBreadcrumb(
      category: category,
      message: message,
      level: level,
      type: 'user',
      data: data,
      diagnostics: diagnostics,
    );
  }

  Future<CaptureDiagnostics> _loadCaptureDiagnostics(
    NativeBridge bridge, {
    required Duration timeout,
  }) async {
    try {
      final raw = await bridge
          .invokeMethod<Map<dynamic, dynamic>>('getCaptureDiagnostics')
          .timeout(timeout);
      final diagnostics = CaptureDiagnostics.fromMap(raw);
      if (!diagnostics.isEmpty) {
        _lastDiagnostics = diagnostics;
      }
      return diagnostics.isEmpty ? _lastDiagnostics : diagnostics;
    } on TimeoutException {
      // Best-effort enrichment only.
      return _lastDiagnostics;
    } catch (_) {
      // Best-effort enrichment only.
      return _lastDiagnostics;
    }
  }

  Future<void> _syncRecordingScope({
    WorkflowPhase? phase,
    CaptureDiagnostics? diagnostics,
    SettingsController? settings,
    String? recordingId,
  }) async {
    if (diagnostics != null && !diagnostics.isEmpty) {
      _lastDiagnostics = diagnostics;
    }
    if (phase != null) {
      _lastPhase = phase;
      _recordingSessionActive = switch (phase) {
        WorkflowPhase.idle ||
        WorkflowPhase.openingPreview ||
        WorkflowPhase.previewLoading ||
        WorkflowPhase.previewReady ||
        WorkflowPhase.closingPreview ||
        WorkflowPhase.exporting => false,
        _ => true,
      };
    }
    if (recordingId != null) {
      _activeRecordingId = recordingId;
    }

    final effectiveDiagnostics = diagnostics ?? _lastDiagnostics;
    final effectivePhase = phase ?? _lastPhase;
    final effectiveFps =
        effectiveDiagnostics.captureFps ?? settings?.recording.captureFrameRate;
    final effectiveResolution = settings?.post.resolutionPreset.name;
    final normalizedBackend = _normalizeBackend(effectiveDiagnostics.backend);
    final diskFreeBytes = effectiveDiagnostics.bestFreeBytes;
    final diskFreeMiBTag = _toMiBTag(diskFreeBytes);

    await Sentry.configureScope((scope) async {
      if (effectivePhase != null) {
        await scope.setTag('recording.phase', effectivePhase.name);
      } else {
        await scope.removeTag('recording.phase');
      }

      if (effectiveFps != null) {
        await scope.setTag('recording.fps', '$effectiveFps');
      } else {
        await scope.removeTag('recording.fps');
      }

      if (effectiveResolution != null && effectiveResolution.isNotEmpty) {
        await scope.setTag('recording.resolution', effectiveResolution);
      } else {
        await scope.removeTag('recording.resolution');
      }

      await scope.setTag('recording.backend', normalizedBackend);

      if (_activeRecordingId != null && _activeRecordingId!.isNotEmpty) {
        await scope.setTag('recording.id', _activeRecordingId!);
      } else {
        await scope.removeTag('recording.id');
      }

      if (diskFreeMiBTag != null) {
        await scope.setTag('recording.disk_free_mib', diskFreeMiBTag);
      } else {
        await scope.removeTag('recording.disk_free_mib');
      }

      await scope.setContexts('recording_session', {
        'active': _recordingSessionActive,
        if (effectivePhase != null) 'phase': effectivePhase.name,
        if (effectiveFps != null) 'fps': effectiveFps,
        if (effectiveResolution != null)
          'resolutionPreset': effectiveResolution,
        if (_activeRecordingId != null) 'recordingId': _activeRecordingId,
        ...effectiveDiagnostics.toMap(),
        'backend': normalizedBackend,
      });
    });
  }

  Future<void> _stopSession({required bool clearScope}) async {
    _recordingSessionActive = false;
    _lastPhase = null;
    _activeRecordingId = null;

    if (!clearScope) return;

    await Sentry.configureScope((scope) async {
      await scope.removeTag('recording.phase');
      await scope.removeTag('recording.fps');
      await scope.removeTag('recording.resolution');
      await scope.removeTag('recording.backend');
      await scope.removeTag('recording.id');
      await scope.removeTag('recording.disk_free_mib');
      await scope.setContexts('recording_session', {'active': false});
    });
  }

  Future<void> _captureError(
    Object error, {
    StackTrace? stackTrace,
    String? method,
    Map<String, dynamic>? context,
    CaptureDiagnostics? diagnostics,
  }) async {
    final effectiveDiagnostics = _effectiveDiagnostics(diagnostics);
    final payload = <String, dynamic>{
      if (method != null) 'method': method,
      if (error is PlatformException) ...{
        'code': error.code,
        'message': error.message,
        'details': _safeValue(error.details),
      },
      ..._safeMap(context),
    };

    await Sentry.captureException(
      error,
      stackTrace: stackTrace,
      withScope: (scope) async {
        if (method != null) {
          await scope.setTag('error.surface', 'method_channel');
          await scope.setTag('error.method', method);
        }
        if (error is PlatformException) {
          await scope.setTag('error.native_code', error.code);
        }

        await _decorateScope(
          scope,
          diagnostics: effectiveDiagnostics,
          contextKey: method != null ? 'method_channel_error' : 'clingfy_error',
          payload: payload,
        );
      },
    );
  }

  Future<void> _addBreadcrumb({
    required String category,
    required String message,
    required SentryLevel level,
    required String type,
    Map<String, dynamic>? data,
    CaptureDiagnostics? diagnostics,
  }) async {
    final effectiveDiagnostics = _effectiveDiagnostics(diagnostics);
    final payload = <String, dynamic>{
      ..._safeMap(data),
      'backend': _normalizeBackend(effectiveDiagnostics.backend),
      if (effectiveDiagnostics.captureFps != null)
        'captureFps': effectiveDiagnostics.captureFps,
      if (effectiveDiagnostics.bestFreeBytes != null)
        'diskFreeBytes': effectiveDiagnostics.bestFreeBytes,
      if (_activeRecordingId != null) 'recordingId': _activeRecordingId,
    };

    await Sentry.addBreadcrumb(
      Breadcrumb(
        category: category,
        message: message,
        type: type,
        level: level,
        data: payload,
      ),
    );
  }

  CaptureDiagnostics _effectiveDiagnostics(CaptureDiagnostics? diagnostics) {
    if (diagnostics != null && !diagnostics.isEmpty) {
      _lastDiagnostics = diagnostics;
    }
    return diagnostics ?? _lastDiagnostics;
  }

  Future<void> _decorateScope(
    Scope scope, {
    required CaptureDiagnostics diagnostics,
    required String contextKey,
    required Map<String, dynamic> payload,
  }) async {
    final backend = _normalizeBackend(diagnostics.backend);
    final diskMiB = _toMiBTag(diagnostics.bestFreeBytes);

    await scope.setTag('recording.backend', backend);
    if (diagnostics.captureFps != null) {
      await scope.setTag('recording.fps', '${diagnostics.captureFps}');
    }
    if (diskMiB != null) {
      await scope.setTag('recording.disk_free_mib', diskMiB);
    }
    if (_activeRecordingId != null && _activeRecordingId!.isNotEmpty) {
      await scope.setTag('recording.id', _activeRecordingId!);
    }

    await scope.setContexts('capture_diagnostics', {
      ...diagnostics.toMap(),
      'backend': backend,
    });
    await scope.setContexts(contextKey, payload);
  }

  @override
  void send(LogEvent event) {
    final level = _toSentryLevel(event.level);
    final payload = <String, dynamic>{
      'category': event.category,
      'origin': event.origin,
      'sessionId': event.sessionId,
      if (event.recordingId != null) 'recordingId': event.recordingId,
      if (event.file != null) 'file': event.file,
      if (event.line != null) 'line': event.line,
      ..._safeMap(event.context),
    };

    unawaited(
      _addBreadcrumb(
        category: 'log.${event.origin}.${event.category}',
        message: event.message,
        level: level,
        type: 'debug',
        data: payload,
      ),
    );

    final isNativeError =
        event.origin == 'native' && event.level.toUpperCase() == 'ERROR';
    if (!isNativeError) return;

    final stackTrace = (event.stack != null && event.stack!.isNotEmpty)
        ? StackTrace.fromString(event.stack!)
        : null;
    final details = <String, dynamic>{
      'log': payload,
      'message': event.message,
      if (event.error != null) 'error': event.error,
    };

    final error = (event.error != null && event.error!.isNotEmpty)
        ? _NativeLogException('${event.category}: ${event.error}')
        : _NativeLogException('[${event.category}] ${event.message}');

    unawaited(
      _captureError(
        error,
        stackTrace: stackTrace,
        method: 'native.log',
        context: details,
      ),
    );
  }

  static SentryLevel _toSentryLevel(String level) {
    switch (level.toUpperCase()) {
      case 'DEBUG':
        return SentryLevel.debug;
      case 'INFO':
        return SentryLevel.info;
      case 'WARNING':
        return SentryLevel.warning;
      case 'ERROR':
        return SentryLevel.error;
      default:
        return SentryLevel.info;
    }
  }

  static String _normalizeBackend(String? backend) {
    final value = (backend ?? '').trim().toLowerCase();
    if (value.isEmpty) return 'unknown';
    if (value.contains('screencapturekit') || value.contains('sck')) {
      return 'screencapturekit';
    }
    if (value.contains('avfoundation')) {
      return 'avfoundation';
    }
    return backend!.trim();
  }

  static String? _toMiBTag(int? bytes) {
    if (bytes == null || bytes < 0) return null;
    final mib = bytes / (1024 * 1024);
    return mib.toStringAsFixed(0);
  }

  static Map<String, dynamic> _safeMap(Map<String, dynamic>? value) {
    if (value == null || value.isEmpty) return const {};
    return value.map((key, item) => MapEntry(key, _safeValue(item)));
  }

  static dynamic _safeValue(dynamic value) {
    if (value == null ||
        value is num ||
        value is bool ||
        value is String ||
        value is List ||
        value is Map) {
      return value;
    }
    return value.toString();
  }
}

class _NativeLogException implements Exception {
  const _NativeLogException(this.message);

  final String message;

  @override
  String toString() => message;
}
