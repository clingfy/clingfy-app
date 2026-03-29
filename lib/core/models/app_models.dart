import 'package:flutter/material.dart';

enum RecordingQuality { sd, hd720, fhd, qhd2k, uhd4k, k8k, native }

enum LayoutPreset { auto, classic43, square11, youtube169, reel916 }

enum ResolutionPreset { auto, p1080, p1440, p2160, p4320, custom }

enum FitMode { fit, fill }

enum CameraLayoutPreset {
  overlayTopLeft,
  overlayTopRight,
  overlayBottomLeft,
  overlayBottomRight,
  sideBySideLeft,
  sideBySideRight,
  stackedTop,
  stackedBottom,
  backgroundBehind,
  hidden;

  static CameraLayoutPreset fromRaw(String? raw) {
    return CameraLayoutPreset.values.firstWhere(
      (value) => value.name == raw,
      orElse: () => CameraLayoutPreset.overlayBottomRight,
    );
  }
}

enum CameraZoomBehavior {
  fixed,
  scaleWithScreenZoom;

  static CameraZoomBehavior fromRaw(String? raw) {
    switch (raw) {
      case 'scaleWithScreenZoom':
        return CameraZoomBehavior.scaleWithScreenZoom;
      default:
        return CameraZoomBehavior.fixed;
    }
  }
}

enum CameraIntroPreset {
  none,
  fade,
  pop,
  slide;

  static CameraIntroPreset fromRaw(String? raw) {
    return CameraIntroPreset.values.firstWhere(
      (value) => value.name == raw,
      orElse: () => CameraIntroPreset.none,
    );
  }
}

enum CameraOutroPreset {
  none,
  fade,
  shrink,
  slide;

  static CameraOutroPreset fromRaw(String? raw) {
    return CameraOutroPreset.values.firstWhere(
      (value) => value.name == raw,
      orElse: () => CameraOutroPreset.none,
    );
  }
}

enum CameraZoomEmphasisPreset {
  none,
  pulse;

  static CameraZoomEmphasisPreset fromRaw(String? raw) {
    return CameraZoomEmphasisPreset.values.firstWhere(
      (value) => value.name == raw,
      orElse: () => CameraZoomEmphasisPreset.none,
    );
  }
}

enum CameraShape {
  circle,
  roundedRect,
  square,
  squircle;

  static CameraShape fromRaw(String? raw) {
    return CameraShape.values.firstWhere(
      (value) => value.name == raw,
      orElse: () => CameraShape.circle,
    );
  }
}

enum CameraContentMode {
  fit,
  fill;

  static CameraContentMode fromRaw(String? raw) {
    return CameraContentMode.values.firstWhere(
      (value) => value.name == raw,
      orElse: () => CameraContentMode.fill,
    );
  }
}

class CameraCompositionState {
  static const double defaultZoomScaleMultiplier = 0.35;
  static const int defaultIntroDurationMs = 220;
  static const int defaultOutroDurationMs = 180;
  static const double defaultZoomEmphasisStrength = 0.10;

  const CameraCompositionState({
    required this.visible,
    required this.layoutPreset,
    required this.normalizedCanvasCenter,
    required this.sizeFactor,
    required this.shape,
    required this.cornerRadius,
    required this.opacity,
    required this.mirror,
    required this.contentMode,
    required this.zoomBehavior,
    this.zoomScaleMultiplier = defaultZoomScaleMultiplier,
    this.introPreset = CameraIntroPreset.none,
    this.outroPreset = CameraOutroPreset.none,
    this.zoomEmphasisPreset = CameraZoomEmphasisPreset.none,
    this.introDurationMs = defaultIntroDurationMs,
    this.outroDurationMs = defaultOutroDurationMs,
    this.zoomEmphasisStrength = defaultZoomEmphasisStrength,
    required this.borderWidth,
    required this.borderColorArgb,
    required this.shadowPreset,
    required this.chromaKeyEnabled,
    required this.chromaKeyStrength,
    required this.chromaKeyColorArgb,
  });

  const CameraCompositionState.hidden()
    : visible = false,
      layoutPreset = CameraLayoutPreset.hidden,
      normalizedCanvasCenter = null,
      sizeFactor = 0.18,
      shape = CameraShape.circle,
      cornerRadius = 0.0,
      opacity = 1.0,
      mirror = true,
      contentMode = CameraContentMode.fill,
      zoomBehavior = CameraZoomBehavior.fixed,
      zoomScaleMultiplier = defaultZoomScaleMultiplier,
      introPreset = CameraIntroPreset.none,
      outroPreset = CameraOutroPreset.none,
      zoomEmphasisPreset = CameraZoomEmphasisPreset.none,
      introDurationMs = defaultIntroDurationMs,
      outroDurationMs = defaultOutroDurationMs,
      zoomEmphasisStrength = defaultZoomEmphasisStrength,
      borderWidth = 0.0,
      borderColorArgb = null,
      shadowPreset = 0,
      chromaKeyEnabled = false,
      chromaKeyStrength = 0.4,
      chromaKeyColorArgb = null;

  final bool visible;
  final CameraLayoutPreset layoutPreset;
  final Offset? normalizedCanvasCenter;
  final double sizeFactor;
  final CameraShape shape;
  final double cornerRadius;
  final double opacity;
  final bool mirror;
  final CameraContentMode contentMode;
  final CameraZoomBehavior zoomBehavior;
  final double zoomScaleMultiplier;
  final CameraIntroPreset introPreset;
  final CameraOutroPreset outroPreset;
  final CameraZoomEmphasisPreset zoomEmphasisPreset;
  final int introDurationMs;
  final int outroDurationMs;
  final double zoomEmphasisStrength;
  final double borderWidth;
  final int? borderColorArgb;
  final int shadowPreset;
  final bool chromaKeyEnabled;
  final double chromaKeyStrength;
  final int? chromaKeyColorArgb;

  bool get isManuallyPositioned => normalizedCanvasCenter != null;

  CameraCompositionState copyWith({
    bool? visible,
    CameraLayoutPreset? layoutPreset,
    Offset? normalizedCanvasCenter,
    bool clearNormalizedCanvasCenter = false,
    double? sizeFactor,
    CameraShape? shape,
    double? cornerRadius,
    double? opacity,
    bool? mirror,
    CameraContentMode? contentMode,
    CameraZoomBehavior? zoomBehavior,
    double? zoomScaleMultiplier,
    CameraIntroPreset? introPreset,
    CameraOutroPreset? outroPreset,
    CameraZoomEmphasisPreset? zoomEmphasisPreset,
    int? introDurationMs,
    int? outroDurationMs,
    double? zoomEmphasisStrength,
    double? borderWidth,
    int? borderColorArgb,
    bool clearBorderColor = false,
    int? shadowPreset,
    bool? chromaKeyEnabled,
    double? chromaKeyStrength,
    int? chromaKeyColorArgb,
    bool clearChromaKeyColor = false,
  }) {
    return CameraCompositionState(
      visible: visible ?? this.visible,
      layoutPreset: layoutPreset ?? this.layoutPreset,
      normalizedCanvasCenter: clearNormalizedCanvasCenter
          ? null
          : (normalizedCanvasCenter ?? this.normalizedCanvasCenter),
      sizeFactor: sizeFactor ?? this.sizeFactor,
      shape: shape ?? this.shape,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      opacity: opacity ?? this.opacity,
      mirror: mirror ?? this.mirror,
      contentMode: contentMode ?? this.contentMode,
      zoomBehavior: zoomBehavior ?? this.zoomBehavior,
      zoomScaleMultiplier: zoomScaleMultiplier ?? this.zoomScaleMultiplier,
      introPreset: introPreset ?? this.introPreset,
      outroPreset: outroPreset ?? this.outroPreset,
      zoomEmphasisPreset: zoomEmphasisPreset ?? this.zoomEmphasisPreset,
      introDurationMs: introDurationMs ?? this.introDurationMs,
      outroDurationMs: outroDurationMs ?? this.outroDurationMs,
      zoomEmphasisStrength: zoomEmphasisStrength ?? this.zoomEmphasisStrength,
      borderWidth: borderWidth ?? this.borderWidth,
      borderColorArgb: clearBorderColor
          ? null
          : (borderColorArgb ?? this.borderColorArgb),
      shadowPreset: shadowPreset ?? this.shadowPreset,
      chromaKeyEnabled: chromaKeyEnabled ?? this.chromaKeyEnabled,
      chromaKeyStrength: chromaKeyStrength ?? this.chromaKeyStrength,
      chromaKeyColorArgb: clearChromaKeyColor
          ? null
          : (chromaKeyColorArgb ?? this.chromaKeyColorArgb),
    );
  }

  factory CameraCompositionState.fromMap(Map<dynamic, dynamic> raw) {
    final center = raw['normalizedCanvasCenter'];
    return CameraCompositionState(
      visible: raw['visible'] == true,
      layoutPreset: CameraLayoutPreset.fromRaw(raw['layoutPreset']?.toString()),
      normalizedCanvasCenter: center is Map
          ? Offset(
              (center['x'] as num?)?.toDouble() ?? 0.0,
              (center['y'] as num?)?.toDouble() ?? 0.0,
            )
          : null,
      sizeFactor: (raw['sizeFactor'] as num?)?.toDouble() ?? 0.18,
      shape: CameraShape.fromRaw(raw['shape']?.toString()),
      cornerRadius: (raw['cornerRadius'] as num?)?.toDouble() ?? 0.0,
      opacity: (raw['opacity'] as num?)?.toDouble() ?? 1.0,
      mirror: raw['mirror'] as bool? ?? true,
      contentMode: CameraContentMode.fromRaw(raw['contentMode']?.toString()),
      zoomBehavior: CameraZoomBehavior.fromRaw(raw['zoomBehavior']?.toString()),
      zoomScaleMultiplier:
          (raw['zoomScaleMultiplier'] as num?)?.toDouble() ??
          defaultZoomScaleMultiplier,
      introPreset: CameraIntroPreset.fromRaw(raw['introPreset']?.toString()),
      outroPreset: CameraOutroPreset.fromRaw(raw['outroPreset']?.toString()),
      zoomEmphasisPreset: CameraZoomEmphasisPreset.fromRaw(
        raw['zoomEmphasisPreset']?.toString(),
      ),
      introDurationMs:
          (raw['introDurationMs'] as num?)?.toInt() ?? defaultIntroDurationMs,
      outroDurationMs:
          (raw['outroDurationMs'] as num?)?.toInt() ?? defaultOutroDurationMs,
      zoomEmphasisStrength:
          (raw['zoomEmphasisStrength'] as num?)?.toDouble() ??
          defaultZoomEmphasisStrength,
      borderWidth: (raw['borderWidth'] as num?)?.toDouble() ?? 0.0,
      borderColorArgb: (raw['borderColorArgb'] as num?)?.toInt(),
      shadowPreset: (raw['shadowPreset'] as num?)?.toInt() ?? 0,
      chromaKeyEnabled: raw['chromaKeyEnabled'] as bool? ?? false,
      chromaKeyStrength: (raw['chromaKeyStrength'] as num?)?.toDouble() ?? 0.4,
      chromaKeyColorArgb: (raw['chromaKeyColorArgb'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'cameraVisible': visible,
      'cameraLayoutPreset': layoutPreset.name,
      'cameraNormalizedCenter': normalizedCanvasCenter == null
          ? null
          : {'x': normalizedCanvasCenter!.dx, 'y': normalizedCanvasCenter!.dy},
      'cameraSizeFactor': sizeFactor,
      'cameraShape': shape.name,
      'cameraCornerRadius': cornerRadius,
      'cameraOpacity': opacity,
      'cameraMirror': mirror,
      'cameraContentMode': contentMode.name,
      'cameraZoomBehavior': zoomBehavior.name,
      'cameraZoomScaleMultiplier': zoomScaleMultiplier,
      'cameraIntroPreset': introPreset.name,
      'cameraOutroPreset': outroPreset.name,
      'cameraZoomEmphasisPreset': zoomEmphasisPreset.name,
      'cameraIntroDurationMs': introDurationMs,
      'cameraOutroDurationMs': outroDurationMs,
      'cameraZoomEmphasisStrength': zoomEmphasisStrength,
      'cameraBorderWidth': borderWidth,
      'cameraBorderColorArgb': borderColorArgb,
      'cameraShadowPreset': shadowPreset,
      'cameraChromaKeyEnabled': chromaKeyEnabled,
      'cameraChromaKeyStrength': chromaKeyStrength,
      'cameraChromaKeyColorArgb': chromaKeyColorArgb,
    };
  }
}

class CameraExportCapabilities {
  const CameraExportCapabilities({
    required this.shapeMask,
    required this.cornerRadius,
    required this.border,
    required this.shadow,
    required this.chromaKey,
  });

  const CameraExportCapabilities.allSupported()
    : shapeMask = true,
      cornerRadius = true,
      border = true,
      shadow = true,
      chromaKey = true;

  final bool shapeMask;
  final bool cornerRadius;
  final bool border;
  final bool shadow;
  final bool chromaKey;

  factory CameraExportCapabilities.fromMap(Map<dynamic, dynamic>? raw) {
    if (raw == null) {
      return const CameraExportCapabilities.allSupported();
    }
    return CameraExportCapabilities(
      shapeMask: raw['shapeMask'] as bool? ?? true,
      cornerRadius: raw['cornerRadius'] as bool? ?? true,
      border: raw['border'] as bool? ?? true,
      shadow: raw['shadow'] as bool? ?? true,
      chromaKey: raw['chromaKey'] as bool? ?? true,
    );
  }
}

class RecordingSceneInfo {
  const RecordingSceneInfo({
    required this.screenPath,
    this.cameraPath,
    this.metadataPath,
    this.camera,
    this.cameraExportCapabilities =
        const CameraExportCapabilities.allSupported(),
  });

  final String screenPath;
  final String? cameraPath;
  final String? metadataPath;
  final CameraCompositionState? camera;
  final CameraExportCapabilities cameraExportCapabilities;

  bool get hasCameraAsset => cameraPath != null && cameraPath!.isNotEmpty;

  factory RecordingSceneInfo.fromMap(Map<dynamic, dynamic> raw) {
    return RecordingSceneInfo(
      screenPath: raw['screenPath']?.toString() ?? '',
      cameraPath: raw['cameraPath']?.toString(),
      metadataPath: raw['metadataPath']?.toString(),
      camera: raw['camera'] is Map
          ? CameraCompositionState.fromMap(raw['camera'] as Map)
          : null,
      cameraExportCapabilities: raw['cameraExportCapabilities'] is Map
          ? CameraExportCapabilities.fromMap(
              raw['cameraExportCapabilities'] as Map,
            )
          : const CameraExportCapabilities.allSupported(),
    );
  }
}

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
