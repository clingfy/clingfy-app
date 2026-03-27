import 'package:flutter/material.dart';

enum RecordingQuality { sd, hd720, fhd, qhd2k, uhd4k, k8k, native }

enum LayoutPreset { auto, classic43, square11, youtube169, reel916 }

enum ResolutionPreset { auto, p1080, p1440, p2160, p4320, custom }

enum FitMode { fit, fill }

enum WorkflowPhase {
  idle(0),
  startingRecording(1),
  recording(2),
  pausedRecording(3),
  stoppingRecording(4),
  finalizingRecording(5),
  openingPreview(6),
  previewLoading(7),
  previewReady(8),
  closingPreview(9),
  exporting(10);

  const WorkflowPhase(this.wireValue);

  final int wireValue;

  static WorkflowPhase fromWireValue(int? raw) {
    for (final phase in WorkflowPhase.values) {
      if (phase.wireValue == raw) {
        return phase;
      }
    }
    return WorkflowPhase.idle;
  }
}

class RecordingPauseResumeCapabilities {
  const RecordingPauseResumeCapabilities({
    required this.canPauseResume,
    required this.backend,
    required this.strategy,
  });

  const RecordingPauseResumeCapabilities.unsupported()
    : canPauseResume = false,
      backend = 'unsupported',
      strategy = 'unsupported';

  final bool canPauseResume;
  final String backend;
  final String strategy;

  factory RecordingPauseResumeCapabilities.fromMap(Map<dynamic, dynamic>? raw) {
    if (raw == null) {
      return const RecordingPauseResumeCapabilities.unsupported();
    }
    return RecordingPauseResumeCapabilities(
      canPauseResume: raw['canPauseResume'] == true,
      backend: raw['backend']?.toString() ?? 'unknown',
      strategy: raw['strategy']?.toString() ?? 'unknown',
    );
  }
}

class RecordingWorkflowState {
  const RecordingWorkflowState({
    required this.phase,
    this.sessionId,
    this.finalizedRecordingPath,
    this.previewPath,
    this.previewToken,
    this.errorCode,
    this.errorMessage,
  });

  const RecordingWorkflowState.idle()
    : phase = WorkflowPhase.idle,
      sessionId = null,
      finalizedRecordingPath = null,
      previewPath = null,
      previewToken = null,
      errorCode = null,
      errorMessage = null;

  final WorkflowPhase phase;
  final String? sessionId;
  final String? finalizedRecordingPath;
  final String? previewPath;
  final String? previewToken;
  final String? errorCode;
  final String? errorMessage;

  bool get hasError =>
      (errorCode != null && errorCode!.isNotEmpty) ||
      (errorMessage != null && errorMessage!.isNotEmpty);

  RecordingWorkflowState copyWith({
    WorkflowPhase? phase,
    String? sessionId,
    bool clearSessionId = false,
    String? finalizedRecordingPath,
    bool clearFinalizedRecordingPath = false,
    String? previewPath,
    bool clearPreviewPath = false,
    String? previewToken,
    bool clearPreviewToken = false,
    String? errorCode,
    bool clearErrorCode = false,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    return RecordingWorkflowState(
      phase: phase ?? this.phase,
      sessionId: clearSessionId ? null : (sessionId ?? this.sessionId),
      finalizedRecordingPath: clearFinalizedRecordingPath
          ? null
          : (finalizedRecordingPath ?? this.finalizedRecordingPath),
      previewPath: clearPreviewPath ? null : (previewPath ?? this.previewPath),
      previewToken: clearPreviewToken
          ? null
          : (previewToken ?? this.previewToken),
      errorCode: clearErrorCode ? null : (errorCode ?? this.errorCode),
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
    );
  }
}

enum DisplayTargetMode {
  explicitId, // 0
  appWindow, // 1
  singleAppWindow, // 2
  areaRecording, // 3
  ////
  mouseAtStart, // 4
  followMouse, // 5
}

enum SettingsTab { record, output, settings }

enum OverlayShape {
  circle(0),
  roundedRect(1),
  square(2),
  hexagon(3),
  star(4),
  squircle(5);

  const OverlayShape(this.wireValue);

  final int wireValue;

  static const OverlayShape defaultValue = OverlayShape.squircle;

  static const List<OverlayShape> uiChoices = <OverlayShape>[
    OverlayShape.squircle,
    OverlayShape.circle,
    OverlayShape.roundedRect,
    OverlayShape.square,
    OverlayShape.hexagon,
    OverlayShape.star,
  ];

  static OverlayShape fromWireValue(int? raw) {
    for (final shape in OverlayShape.values) {
      if (shape.wireValue == raw) {
        return shape;
      }
    }
    return defaultValue;
  }

  static OverlayShape? fromLegacyOrdinal(int? raw) {
    switch (raw) {
      case 0:
        return OverlayShape.circle;
      case 1:
        return OverlayShape.roundedRect;
      case 2:
        return OverlayShape.square;
      case 3:
        return OverlayShape.hexagon;
      case 4:
        return OverlayShape.star;
      default:
        return null;
    }
  }
}

enum OverlayShadow { none, light, medium, strong }

enum OverlayBorder { none, white, black, green, cyan, custom }

enum OverlayPosition { topLeft, topRight, bottomLeft, bottomRight }

class DisplayInfo {
  final int id; // UInt32 from native
  final String name;
  final double x, y, width, height, scale;
  DisplayInfo({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.scale,
  });
  factory DisplayInfo.fromMap(Map m) => DisplayInfo(
    id: (m['id'] as num).toInt(),
    name: m['name'] as String,
    x: (m['x'] as num).toDouble(),
    y: (m['y'] as num).toDouble(),
    width: (m['width'] as num).toDouble(),
    height: (m['height'] as num).toDouble(),
    scale: (m['scale'] as num).toDouble(),
  );
}

class AppWindowInfo {
  final int id;
  final String appName;
  final String title;
  final Rect? bounds;
  final int? displayId;

  const AppWindowInfo({
    required this.id,
    required this.appName,
    required this.title,
    this.bounds,
    this.displayId,
  });

  factory AppWindowInfo.fromMap(Map<dynamic, dynamic> m) {
    Rect? rect;
    final rawBounds = m['bounds'];
    if (rawBounds is Map) {
      rect = Rect.fromLTWH(
        (rawBounds['x'] as num?)?.toDouble() ?? 0,
        (rawBounds['y'] as num?)?.toDouble() ?? 0,
        (rawBounds['width'] as num?)?.toDouble() ?? 0,
        (rawBounds['height'] as num?)?.toDouble() ?? 0,
      );
    }
    return AppWindowInfo(
      id: (m['windowId'] as num).toInt(),
      appName: (m['appName'] as String?)?.trim().isNotEmpty == true
          ? (m['appName'] as String)
          : 'App',
      title: (m['title'] as String?) ?? '',
      bounds: rect,
      displayId: (m['displayId'] as num?)?.toInt(),
    );
  }

  String get label =>
      title.trim().isEmpty ? appName : '$appName — ${title.trim()}';
}

class AudioSource {
  const AudioSource({required this.id, required this.name});
  final String id;
  final String name;
  factory AudioSource.fromMap(Map<dynamic, dynamic> m) => AudioSource(
    id: m['id'] as String? ?? '',
    name: m['name'] as String? ?? 'Unknown',
  );
}

class CamSource {
  const CamSource({required this.id, required this.name});
  final String id;
  final String name;
  factory CamSource.fromMap(Map<dynamic, dynamic> m) => CamSource(
    id: m['id'] as String? ?? '',
    name: m['name'] as String? ?? 'Camera',
  );
}

class ZoomSegment {
  final String id;
  final int startMs;
  final int endMs;
  final String source; // "auto" or "manual"
  final String?
  baseId; // if non-null, this manual segment overrides an auto segment

  const ZoomSegment({
    required this.id,
    required this.startMs,
    required this.endMs,
    this.source = 'auto',
    this.baseId,
  });

  factory ZoomSegment.fromMap(Map m) => ZoomSegment(
    id:
        m['id']?.toString() ??
        '${m['startMs']}_${m['endMs']}', // fallback for old data
    startMs: (m['startMs'] as num).toInt(),
    endMs: (m['endMs'] as num).toInt(),
    source: m['source']?.toString() ?? 'auto',
    baseId: m['baseId']?.toString(),
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'startMs': startMs,
    'endMs': endMs,
    'source': source,
    if (baseId != null) 'baseId': baseId,
  };

  ZoomSegment copyWith({
    String? id,
    int? startMs,
    int? endMs,
    String? source,
    String? baseId,
    bool clearBaseId = false,
  }) => ZoomSegment(
    id: id ?? this.id,
    startMs: startMs ?? this.startMs,
    endMs: endMs ?? this.endMs,
    source: source ?? this.source,
    baseId: clearBaseId ? null : (baseId ?? this.baseId),
  );

  @override
  String toString() =>
      'ZoomSegment(id: $id, startMs: $startMs, endMs: $endMs, source: $source, baseId: $baseId)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZoomSegment &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          startMs == other.startMs &&
          endMs == other.endMs &&
          source == other.source &&
          baseId == other.baseId;

  @override
  int get hashCode =>
      id.hashCode ^
      startMs.hashCode ^
      endMs.hashCode ^
      source.hashCode ^
      baseId.hashCode;
}
