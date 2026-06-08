import 'dart:async';

import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:clingfy/core/overlay/overlay_mode.dart';

import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/core/models/app_models.dart';

import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/infrastructure/observability/telemetry_service.dart';

const _prefOverlayShapeId = 'pref.overlayShapeId';
const _legacyPrefOverlayShape = 'overlayShape';
const _prefOverlayUseCustomPosition = 'overlayUseCustomPosition';
const _prefOverlayCustomNormalizedX = 'overlayCustomNormalizedX';
const _prefOverlayCustomNormalizedY = 'overlayCustomNormalizedY';

class OverlayController extends ChangeNotifier {
  final NativeBridge _nativeBridge;

  int? _areaDisplayId;
  Rect? _areaRect;

  OverlayController({required NativeBridge bridge}) : _nativeBridge = bridge {
    _nativeBridge.setOnCameraOverlayMoved(_onCameraOverlayMovedFromNative);
    _nativeBridge.setOnAreaSelectionCleared(_onAreaSelectionClearedFromNative);
    _init();
  }

  // --- State Fields ---
  bool _cameraOverlayEnabled = false;
  bool _linkOverlayToRecording = true;
  OverlayShape _overlayShape = OverlayShape.defaultValue;
  double _overlaySize = 220.0;
  OverlayShadow _overlayShadow = OverlayShadow.none;
  OverlayBorder _overlayBorder = OverlayBorder.none;
  OverlayPosition _overlayPosition = OverlayPosition.bottomRight;
  double _overlayRoundness = 0.0; // 0.0 to 0.4 (0% to 40%)
  double _overlayOpacity = 1.0; // 0.3 to 1.0
  bool _overlayMirror = true;
  bool _overlayRecordingHighlightEnabled = true;
  double _overlayRecordingHighlightStrength = 0.70; // 0.10 .. 1.00
  bool _overlayUseCustomPosition = false;
  double? _overlayCustomNormalizedX;
  double? _overlayCustomNormalizedY;
  double _overlayBorderWidth = 4.0;
  int _overlayBorderColor = 0xFFFFFFFF; // White

  bool _isRecording = false; // Transient state from main app

  // Phase 9.3.2 live preview mode. true = floating draggable bubble (macOS-like);
  // false = in-app Flutter texture preview. Phase 9.3.3: in-app is the Windows
  // DEFAULT because a capture-excluded floating window is invisible on hybrid
  // GPUs (WDA reports success but never composites to the display — see #153).
  // Floating is opt-in via the recording-panel toggle. Persisted.
  bool _cameraFloatingPreview = false;

  bool _chromaKeyEnabled = false;
  double _chromaKeyStrength = 0.4;
  int _chromaKeyColor = 0xFF00FF00; // Green
  DateTime? _lastCustomPositionBreadcrumbAt;

  bool _cursorEnabled = false;
  bool _cursorLinkedToRecording = true;

  String? _errorMessage;
  bool _isHydrated = false;

  // --- Getters ---
  bool get cameraOverlayEnabled => _cameraOverlayEnabled;
  bool get cameraFloatingPreview => _cameraFloatingPreview;
  bool get linkOverlayToRecording => _linkOverlayToRecording;
  OverlayShape get overlayShape => _overlayShape;
  double get overlaySize => _overlaySize;
  OverlayShadow get overlayShadow => _overlayShadow;
  OverlayBorder get overlayBorder => _overlayBorder;
  OverlayPosition get overlayPosition => _overlayPosition;
  double get overlayRoundness => _overlayRoundness;
  double get overlayOpacity => _overlayOpacity;
  bool get overlayMirror => _overlayMirror;
  bool get overlayRecordingHighlightEnabled =>
      _overlayRecordingHighlightEnabled;
  double get overlayRecordingHighlightStrength =>
      _overlayRecordingHighlightStrength;
  bool get overlayUseCustomPosition => _overlayUseCustomPosition;
  double? get overlayCustomNormalizedX => _overlayCustomNormalizedX;
  double? get overlayCustomNormalizedY => _overlayCustomNormalizedY;
  double get overlayBorderWidth => _overlayBorderWidth;
  int get overlayBorderColor => _overlayBorderColor;
  bool get chromaKeyEnabled => _chromaKeyEnabled;
  double get chromaKeyStrength => _chromaKeyStrength;
  int get chromaKeyColor => _chromaKeyColor;

  bool get cursorEnabled => _cursorEnabled;
  bool get cursorLinkedToRecording => _cursorLinkedToRecording;
  String? get errorMessage => _errorMessage;
  bool get isHydrated => _isHydrated;

  OverlayMode get overlayMode {
    if (!_cameraOverlayEnabled) return OverlayMode.off;
    return _linkOverlayToRecording
        ? OverlayMode.whileRecording
        : OverlayMode.alwaysOn;
  }

  OverlayMode get cursorMode {
    if (!_cursorEnabled) return OverlayMode.off;
    return _cursorLinkedToRecording
        ? OverlayMode.whileRecording
        : OverlayMode.alwaysOn;
  }

  // --- Actions ---

  void clearError() {
    if (_errorMessage != null) {
      _errorMessage = null;
      notifyListeners();
    }
  }

  int? get areaDisplayId => _areaDisplayId;
  Rect? get areaRect => _areaRect;

  Future<void> _init() async {
    try {
      final sp = await SharedPreferences.getInstance();

      _cameraOverlayEnabled = sp.getBool('overlayEnabled') ?? false;
      // Default to in-app preview (see _cameraFloatingPreview docs); only the
      // explicit 'floating' opt-in turns on the native bubble.
      _cameraFloatingPreview = sp.getString('cameraPreviewMode') == 'floating';
      _linkOverlayToRecording = sp.getBool('overlayLinked') ?? true;
      _overlayShape = await _loadOverlayShape(sp);
      _overlaySize = sp.getDouble('overlaySize') ?? 220.0;
      _overlayShadow = OverlayShadow.values[sp.getInt('overlayShadow') ?? 0];
      _overlayBorder = OverlayBorder.values[sp.getInt('overlayBorder') ?? 0];
      _overlayPosition =
          OverlayPosition.values[sp.getInt('overlayPosition') ?? 3];
      _overlayRoundness = sp.getDouble('overlayRoundness') ?? 0.0;
      _overlayOpacity = sp.getDouble('overlayOpacity') ?? 1.0;
      _overlayMirror = sp.getBool('overlayMirror') ?? true;
      _overlayBorderWidth = sp.getDouble('overlayBorderWidth') ?? 4.0;
      _overlayRecordingHighlightEnabled =
          sp.getBool('overlayRecordingHighlightEnabled') ?? true;
      _overlayRecordingHighlightStrength = _clampHighlightStrength(
        sp.getDouble('overlayRecordingHighlightStrength') ?? 0.70,
      );
      _overlayUseCustomPosition =
          sp.getBool(_prefOverlayUseCustomPosition) ?? false;
      _overlayCustomNormalizedX = _normalizeStoredCoordinate(
        sp.getDouble(_prefOverlayCustomNormalizedX),
      );
      _overlayCustomNormalizedY = _normalizeStoredCoordinate(
        sp.getDouble(_prefOverlayCustomNormalizedY),
      );
      if (_overlayUseCustomPosition &&
          (_overlayCustomNormalizedX == null ||
              _overlayCustomNormalizedY == null)) {
        await _clearStoredCustomPosition(sp);
      }

      final savedBorderIndex = sp.getInt('overlayBorder') ?? 0;
      _overlayBorder = OverlayBorder.values[savedBorderIndex];

      _overlayBorderColor = sp.getInt('overlayBorderColor') ?? 0xFFFFFFFF;
      // If it's a preset (and not 'none' or 'custom'), ensure color matches the preset
      if (_overlayBorder != OverlayBorder.none &&
          _overlayBorder != OverlayBorder.custom) {
        _overlayBorderColor = _borderPresetToColor(_overlayBorder).toARGB32();
      }

      _chromaKeyEnabled = sp.getBool('chromaKeyEnabled') ?? false;
      _chromaKeyStrength = sp.getDouble('chromaKeyStrength') ?? 0.4;
      _chromaKeyColor = sp.getInt('chromaKeyColor') ?? 0xFF00FF00;

      _cursorEnabled = sp.getBool('cursorEnabled') ?? false;
      _cursorLinkedToRecording = sp.getBool('cursorLinked') ?? true;

      notifyListeners();

      await _nativeBridge.invokeMethod<void>('setCameraOverlayShape', {
        'shapeId': _overlayShape.wireValue,
      });
      await _nativeBridge.invokeMethod<void>('setCameraOverlaySize', {
        'size': _overlaySize,
      });
      await _nativeBridge.invokeMethod<void>('setCameraOverlayShadow', {
        'shadow': _overlayShadow.index,
      });
      await _nativeBridge.invokeMethod<void>('setCameraOverlayBorder', {
        'border': _overlayBorder.index,
      });
      await _nativeBridge.invokeMethod<void>('setCameraOverlayBorderWidth', {
        'width': _overlayBorderWidth,
      });
      await _nativeBridge.invokeMethod<void>('setCameraOverlayBorderColor', {
        'color': _overlayBorderColor,
      });
      await _nativeBridge.invokeMethod<void>('setCameraOverlayRoundness', {
        'roundness': _overlayRoundness,
      });
      await _nativeBridge.invokeMethod<void>('setCameraOverlayOpacity', {
        'opacity': _overlayOpacity,
      });
      await _nativeBridge.invokeMethod<void>('setOverlayMirror', {
        'mirrored': _overlayMirror,
      });
      await _nativeBridge.invokeMethod<void>('setChromaKeyEnabled', {
        'enabled': _chromaKeyEnabled,
      });
      await _nativeBridge.invokeMethod<void>('setChromaKeyStrength', {
        'strength': _chromaKeyStrength,
      });
      await _nativeBridge.invokeMethod<void>('setChromaKeyColor', {
        'color': _chromaKeyColor,
      });
      await _nativeBridge.invokeMethod<void>(
        'setCameraOverlayHighlightStrength',
        {'strength': _overlayRecordingHighlightStrength},
      );

      await _syncOverlayPositionToNative();

      await _nativeBridge.setOverlayLinkedToRecording(_linkOverlayToRecording);
      try {
        await _nativeBridge.invokeMethod<void>('setOverlayEnabled', {
          'enabled': _cameraOverlayEnabled,
        });
      } on PlatformException catch (e) {
        if (e.code == 'CAMERA_PERMISSION_DENIED') {
          Log.w(
            'Overlay',
            'Camera permission denied during init, disabling overlay',
          );
          _cameraOverlayEnabled = false;
          final spFix = await SharedPreferences.getInstance();
          await spFix.setBool('overlayEnabled', false);
        } else {
          rethrow;
        }
      }
      await _updateNativeHighlight();

      await _nativeBridge.setCursorHighlightLinkedToRecording(
        _cursorLinkedToRecording,
      );
      try {
        await _nativeBridge.setCursorHighlightEnabled(_cursorEnabled);
      } catch (e) {
        Log.e('Overlay', 'Error setting cursor highlight enabled: $e');
      }

      final prefs = await SharedPreferences.getInstance();
      _areaDisplayId = prefs.getInt('pref.areaDisplayId');
      final areaX = prefs.getDouble('pref.areaRect.x');
      final areaY = prefs.getDouble('pref.areaRect.y');
      final areaW = prefs.getDouble('pref.areaRect.width');
      final areaH = prefs.getDouble('pref.areaRect.height');
      if (areaX != null && areaY != null && areaW != null && areaH != null) {
        _areaRect = Rect.fromLTWH(areaX, areaY, areaW, areaH);
      }
      notifyListeners();
    } catch (e, st) {
      _errorMessage = e.toString();
      Log.e('Overlay', 'Failed during initial overlay hydration', e, st);
    } finally {
      _isHydrated = true;
      notifyListeners();
    }
  }

  Future<void> setOverlayMode(OverlayMode mode) async {
    final sp = await SharedPreferences.getInstance();
    final wasEnabled = _cameraOverlayEnabled;
    switch (mode) {
      case OverlayMode.off:
        _cameraOverlayEnabled = false;
        _linkOverlayToRecording = true;
        break;
      case OverlayMode.whileRecording:
        _cameraOverlayEnabled = true;
        _linkOverlayToRecording = true;
        break;
      case OverlayMode.alwaysOn:
        _cameraOverlayEnabled = true;
        _linkOverlayToRecording = false;
        break;
    }

    await sp.setBool('overlayEnabled', _cameraOverlayEnabled);
    await sp.setBool('overlayLinked', _linkOverlayToRecording);
    await ClingfyTelemetry.addUiBreadcrumb(
      category: 'ui.facecam',
      message: 'User changed facecam mode',
      data: {
        'mode': mode.name,
        'enabled': _cameraOverlayEnabled,
        'linkedToRecording': _linkOverlayToRecording,
      },
    );

    notifyListeners();

    try {
      await _nativeBridge.setOverlayLinkedToRecording(_linkOverlayToRecording);
      if (!wasEnabled &&
          _cameraOverlayEnabled &&
          _overlayUseCustomPosition &&
          _overlayCustomNormalizedX != null &&
          _overlayCustomNormalizedY != null) {
        await _nativeBridge
            .invokeMethod<void>('setCameraOverlayCustomPosition', {
              'normalizedX': _overlayCustomNormalizedX,
              'normalizedY': _overlayCustomNormalizedY,
            });
      }
      await _nativeBridge.invokeMethod<void>('setOverlayEnabled', {
        'enabled': _cameraOverlayEnabled,
      });
      await _updateNativeHighlight();
    } on PlatformException catch (e) {
      Log.e("Overlay", "1 Error is $e");
      if (e.code != 'ACCESSIBILITY_PERMISSION_REQUIRED') {
        _errorMessage = e.code;
        notifyListeners();
      }
    }
  }

  Future<void> setOverlayShape(OverlayShape shape) async {
    _overlayShape = shape;

    // Preset roundness for specific shapes
    if (shape == OverlayShape.roundedRect) {
      await setOverlayRoundness(0.15);
    } else if (shape == OverlayShape.square) {
      await setOverlayRoundness(0.0);
    }

    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await _persistOverlayShape(sp, shape);
    await _nativeBridge.invokeMethod<void>('setCameraOverlayShape', {
      'shapeId': shape.wireValue,
    });
  }

  Future<void> setOverlaySize(double size) async {
    _overlaySize = size;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble('overlaySize', size);
    // setCameraOverlaySize updates size in-place without rebuild
    await _nativeBridge.invokeMethod<void>('setCameraOverlaySize', {
      'size': size,
    });
  }

  Future<void> setOverlayShadow(OverlayShadow shadow) async {
    _overlayShadow = shadow;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('overlayShadow', shadow.index);
    await _nativeBridge.invokeMethod<void>('setCameraOverlayShadow', {
      'shadow': shadow.index,
    });
  }

  Future<void> setOverlayBorder(OverlayBorder border) async {
    _overlayBorder = border;

    // If a preset is chosen, update the actual color to match
    if (border != OverlayBorder.none && border != OverlayBorder.custom) {
      _overlayBorderColor = _borderPresetToColor(border).toARGB32();
    }

    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('overlayBorder', border.index);
    await sp.setInt('overlayBorderColor', _overlayBorderColor);

    await _nativeBridge.invokeMethod<void>('setCameraOverlayBorder', {
      'border': border.index,
    });
    // Also push the color in case it was a preset change
    await _nativeBridge.invokeMethod<void>('setCameraOverlayBorderColor', {
      'color': _overlayBorderColor,
    });
  }

  Future<void> setOverlayPosition(OverlayPosition position) async {
    _overlayPosition = position;
    _overlayUseCustomPosition = false;
    _overlayCustomNormalizedX = null;
    _overlayCustomNormalizedY = null;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('overlayPosition', position.index);
    await _clearStoredCustomPosition(sp);
    await _nativeBridge.invokeMethod<void>('setCameraOverlayPosition', {
      'position': position.index,
    });
    await ClingfyTelemetry.addUiBreadcrumb(
      category: 'ui.facecam',
      message: 'facecam_position_preset_selected',
      data: {'preset': position.name},
    );
  }

  Future<void> setOverlayRoundness(double roundness) async {
    _overlayRoundness = roundness;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble('overlayRoundness', roundness);
    await _nativeBridge.invokeMethod<void>('setCameraOverlayRoundness', {
      'roundness': roundness,
    });
  }

  Future<void> setOverlayOpacity(double opacity) async {
    _overlayOpacity = opacity;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble('overlayOpacity', opacity);
    await _nativeBridge.invokeMethod<void>('setCameraOverlayOpacity', {
      'opacity': opacity,
    });
  }

  Future<void> setOverlayMirror(bool mirrored) async {
    _overlayMirror = mirrored;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('overlayMirror', mirrored);
    await ClingfyTelemetry.addUiBreadcrumb(
      category: 'ui.facecam',
      message: 'User toggled facecam mirror',
      data: {'mirrored': mirrored},
    );
    await _nativeBridge.invokeMethod<void>('setOverlayMirror', {
      'mirrored': mirrored,
    });
  }

  Future<void> setChromaKeyEnabled(bool enabled) async {
    _chromaKeyEnabled = enabled;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('chromaKeyEnabled', enabled);
    await _nativeBridge.invokeMethod<void>('setChromaKeyEnabled', {
      'enabled': enabled,
    });
  }

  Future<void> setChromaKeyStrength(double strength) async {
    _chromaKeyStrength = strength;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble('chromaKeyStrength', strength);
    await _nativeBridge.invokeMethod<void>('setChromaKeyStrength', {
      'strength': strength,
    });
  }

  Future<void> setChromaKeyColor(int color) async {
    _chromaKeyColor = color;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('chromaKeyColor', color);
    await _nativeBridge.invokeMethod<void>('setChromaKeyColor', {
      'color': color,
    });
  }

  Future<void> setOverlayBorderWidth(double width) async {
    _overlayBorderWidth = width;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble('overlayBorderWidth', width);
    await ClingfyTelemetry.addUiBreadcrumb(
      category: 'ui.facecam',
      message: 'User changed facecam border width',
      data: {'borderWidth': width},
    );
    await _nativeBridge.invokeMethod<void>('setCameraOverlayBorderWidth', {
      'width': width,
    });
  }

  Future<void> setOverlayBorderColor(int color) async {
    _overlayBorderColor = color;
    // When manually picking a color, switch mode to 'custom'
    _overlayBorder = OverlayBorder.custom;

    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('overlayBorderColor', color);
    await sp.setInt('overlayBorder', _overlayBorder.index);

    await _nativeBridge.invokeMethod<void>('setCameraOverlayBorderColor', {
      'color': color,
    });
    await _nativeBridge.invokeMethod<void>('setCameraOverlayBorder', {
      'border': _overlayBorder.index,
    });
  }

  Color _borderPresetToColor(OverlayBorder border) {
    switch (border) {
      case OverlayBorder.white:
        return const Color(0xFFFFFFFF);
      case OverlayBorder.black:
        return const Color(0xFF000000);
      case OverlayBorder.green:
        return const Color(0xFF00CC66);
      case OverlayBorder.cyan:
        return const Color(0xFF00E5FF);
      default:
        return Color(_overlayBorderColor);
    }
  }

  Future<void> setCursorMode(BuildContext context, OverlayMode mode) async {
    final sp = await SharedPreferences.getInstance();
    switch (mode) {
      case OverlayMode.off:
        _cursorEnabled = false;
        _cursorLinkedToRecording = true;
        break;
      case OverlayMode.whileRecording:
        _cursorEnabled = true;
        _cursorLinkedToRecording = true;
        break;
      case OverlayMode.alwaysOn:
        _cursorEnabled = true;
        _cursorLinkedToRecording = false;
        break;
    }

    await sp.setBool('cursorEnabled', _cursorEnabled);
    await sp.setBool('cursorLinked', _cursorLinkedToRecording);

    notifyListeners();

    try {
      await _nativeBridge.setCursorHighlightLinkedToRecording(
        _cursorLinkedToRecording,
      );
      await _nativeBridge.setCursorHighlightEnabled(_cursorEnabled);
    } on PlatformException catch (e) {
      Log.e("Overlay", "2 Error is $e");
      if (e.code == 'ACCESSIBILITY_PERMISSION_REQUIRED') {
        if (context.mounted) {
          context.read<HomeUiState>().setNotice(
            HomeUiNotice(
              message: AppLocalizations.of(
                context,
              )!.grantAccessibilityPermission,
              tone: HomeUiNoticeTone.warning,
              action: HomeUiNoticeAction(
                label: AppLocalizations.of(context)!.openSettings,
                onPressed: () {
                  _nativeBridge.invokeMethod('relaunchApp');
                },
              ),
            ),
          );
        }
      } else {
        _errorMessage = e.code;
        notifyListeners();
      }
    }
  }

  Future<void> cycleOverlayMode() async {
    final next = {
      OverlayMode.off: OverlayMode.whileRecording,
      OverlayMode.whileRecording: OverlayMode.alwaysOn,
      OverlayMode.alwaysOn: OverlayMode.off,
    }[overlayMode]!;
    await setOverlayMode(next);
  }

  Future<void> setOverlayRecordingHighlightEnabled(bool enabled) async {
    _overlayRecordingHighlightEnabled = enabled;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('overlayRecordingHighlightEnabled', enabled);
    _updateNativeHighlight();
  }

  Future<void> setOverlayRecordingHighlightStrength(double strength) async {
    final clamped = _clampHighlightStrength(strength);
    _overlayRecordingHighlightStrength = clamped;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble('overlayRecordingHighlightStrength', clamped);
    await _nativeBridge.invokeMethod<void>(
      'setCameraOverlayHighlightStrength',
      {'strength': clamped},
    );
    await ClingfyTelemetry.addUiBreadcrumb(
      category: 'ui.facecam',
      message: 'facecam_glow_strength_changed',
      data: {'strength': clamped},
    );
  }

  Future<void> setOverlayCustomPositionNormalized({
    required double x,
    required double y,
    bool pushToNative = true,
    bool emitBreadcrumb = true,
  }) async {
    final normalizedX = _clamp01(x);
    final normalizedY = _clamp01(y);
    _overlayUseCustomPosition = true;
    _overlayCustomNormalizedX = normalizedX;
    _overlayCustomNormalizedY = normalizedY;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await _persistCustomPosition(
      sp,
      enabled: true,
      normalizedX: normalizedX,
      normalizedY: normalizedY,
    );
    if (pushToNative) {
      await _nativeBridge.invokeMethod<void>('setCameraOverlayCustomPosition', {
        'normalizedX': normalizedX,
        'normalizedY': normalizedY,
      });
    }
    final now = DateTime.now();
    final shouldEmitBreadcrumb =
        emitBreadcrumb &&
        (_lastCustomPositionBreadcrumbAt == null ||
            now.difference(_lastCustomPositionBreadcrumbAt!).inMilliseconds >=
                900);
    if (shouldEmitBreadcrumb) {
      _lastCustomPositionBreadcrumbAt = now;
      await ClingfyTelemetry.addUiBreadcrumb(
        category: 'ui.facecam',
        message: 'facecam_position_custom_saved',
        data: {'normalizedX': normalizedX, 'normalizedY': normalizedY},
      );
    }
  }

  void updateRecordingState(bool isRecording) {
    if (_isRecording != isRecording) {
      _isRecording = isRecording;
      // notifyListeners(); // Not strictly needed if only used for internal logic
      _updateNativeHighlight();
      // Phase 9.3.2: when recording starts with the camera on, apply the saved
      // preview mode to native. If floating is requested but unavailable on this
      // GPU, native reports false and we fall back to the in-app texture.
      if (isRecording && _cameraOverlayEnabled) {
        unawaited(_applyCameraPreviewMode());
      }
    }
  }

  Future<void> _applyCameraPreviewMode() async {
    final requested = _cameraFloatingPreview;
    final resulting = await _nativeBridge.setCameraPreviewMode(
      floating: requested,
    );
    // Re-guard against the post-await state: the user may have toggled the mode
    // (setCameraFloatingPreview) while this call was in flight. Only fall back
    // if we asked for floating, native refused, and floating is still wanted.
    if (requested && !resulting && _cameraFloatingPreview) {
      // Floating requested but the bubble is unavailable (no exclusion) → use
      // the in-app texture instead, and remember it.
      _cameraFloatingPreview = false;
      final sp = await SharedPreferences.getInstance();
      await sp.setString('cameraPreviewMode', 'inApp');
      notifyListeners();
    }
  }

  /// Phase 9.3.2: switch the live preview between the floating bubble and the
  /// in-app texture (the "Can't see the camera? Use in-app preview" action and
  /// its inverse). Persists the choice and applies it immediately if recording.
  Future<void> setCameraFloatingPreview(bool floating) async {
    if (_cameraFloatingPreview == floating) return;
    _cameraFloatingPreview = floating;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setString('cameraPreviewMode', floating ? 'floating' : 'inApp');
    if (_isRecording && _cameraOverlayEnabled) {
      final resulting = await _nativeBridge.setCameraPreviewMode(
        floating: floating,
      );
      if (floating && !resulting && _cameraFloatingPreview) {
        // Asked for floating but it's unavailable on this GPU → revert to in-app.
        _cameraFloatingPreview = false;
        await sp.setString('cameraPreviewMode', 'inApp');
        notifyListeners();
      }
    }
  }

  Future<void> _updateNativeHighlight() async {
    // Logic: Highlight if enabled + recording + overlay is visible
    // Overlay is visible if !off.
    final shouldHighlight =
        _overlayRecordingHighlightEnabled &&
        _isRecording &&
        cameraOverlayEnabled;

    try {
      await _nativeBridge.invokeMethod<void>('setCameraOverlayHighlight', {
        'enabled': shouldHighlight,
      });
    } catch (e) {
      Log.e("Overlay", "Error setting highlight: $e");
    }
  }

  Future<void> _syncOverlayPositionToNative() async {
    if (_overlayUseCustomPosition &&
        _overlayCustomNormalizedX != null &&
        _overlayCustomNormalizedY != null) {
      await _nativeBridge.invokeMethod<void>('setCameraOverlayCustomPosition', {
        'normalizedX': _overlayCustomNormalizedX,
        'normalizedY': _overlayCustomNormalizedY,
      });
      return;
    }
    await _nativeBridge.invokeMethod<void>('setCameraOverlayPosition', {
      'position': _overlayPosition.index,
    });
  }

  void _onCameraOverlayMovedFromNative(double normalizedX, double normalizedY) {
    final x = _clamp01(normalizedX);
    final y = _clamp01(normalizedY);
    if (_overlayUseCustomPosition &&
        _overlayCustomNormalizedX != null &&
        _overlayCustomNormalizedY != null &&
        (_overlayCustomNormalizedX! - x).abs() < 0.0005 &&
        (_overlayCustomNormalizedY! - y).abs() < 0.0005) {
      return;
    }
    unawaited(
      setOverlayCustomPositionNormalized(
        x: x,
        y: y,
        pushToNative: false,
        emitBreadcrumb: true,
      ),
    );
  }

  double _clamp01(double value) => (value.clamp(0.0, 1.0) as num).toDouble();

  double? _normalizeStoredCoordinate(double? value) {
    if (value == null || !value.isFinite) {
      return null;
    }
    return _clamp01(value);
  }

  Future<OverlayShape> _loadOverlayShape(SharedPreferences prefs) async {
    final stableShapeId = prefs.getInt(_prefOverlayShapeId);
    if (stableShapeId != null) {
      final decodedShape = OverlayShape.fromWireValue(stableShapeId);
      if (decodedShape.wireValue != stableShapeId) {
        await _persistOverlayShape(prefs, decodedShape);
      }
      return decodedShape;
    }

    final legacyShapeIndex = prefs.getInt(_legacyPrefOverlayShape);
    final migratedShape =
        OverlayShape.fromLegacyOrdinal(legacyShapeIndex) ??
        OverlayShape.defaultValue;
    await _persistOverlayShape(prefs, migratedShape);
    return migratedShape;
  }

  Future<void> _persistOverlayShape(
    SharedPreferences prefs,
    OverlayShape shape,
  ) async {
    await prefs.setInt(_prefOverlayShapeId, shape.wireValue);
  }

  Future<void> _clearStoredCustomPosition(SharedPreferences prefs) async {
    _overlayUseCustomPosition = false;
    _overlayCustomNormalizedX = null;
    _overlayCustomNormalizedY = null;
    await _persistCustomPosition(
      prefs,
      enabled: false,
      normalizedX: null,
      normalizedY: null,
    );
  }

  Future<void> _persistCustomPosition(
    SharedPreferences prefs, {
    required bool enabled,
    required double? normalizedX,
    required double? normalizedY,
  }) async {
    await prefs.setBool(_prefOverlayUseCustomPosition, enabled);
    if (normalizedX == null) {
      await prefs.remove(_prefOverlayCustomNormalizedX);
    } else {
      await prefs.setDouble(_prefOverlayCustomNormalizedX, normalizedX);
    }
    if (normalizedY == null) {
      await prefs.remove(_prefOverlayCustomNormalizedY);
    } else {
      await prefs.setDouble(_prefOverlayCustomNormalizedY, normalizedY);
    }
  }

  double _clampHighlightStrength(double value) =>
      (value.clamp(0.10, 1.00) as num).toDouble();

  Future<void> pickAreaRecordingRegion() async {
    try {
      final Map<dynamic, dynamic>? result = await _nativeBridge.invokeMethod(
        'pickAreaRecordingRegion',
      );
      if (result != null) {
        _areaDisplayId = result['displayId'];
        final x = (result['x'] as num).toDouble();
        final y = (result['y'] as num).toDouble();
        final width = (result['width'] as num).toDouble();
        final height = (result['height'] as num).toDouble();
        _areaRect = Rect.fromLTWH(x, y, width, height);

        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt('pref.areaDisplayId', _areaDisplayId!);
        await prefs.setDouble('pref.areaRect.x', x);
        await prefs.setDouble('pref.areaRect.y', y);
        await prefs.setDouble('pref.areaRect.width', width);
        await prefs.setDouble('pref.areaRect.height', height);
        await ClingfyTelemetry.addUiBreadcrumb(
          category: 'ui.selection',
          message: 'Selection area changed',
          data: {
            'displayId': _areaDisplayId,
            'x': x,
            'y': y,
            'width': width,
            'height': height,
          },
        );

        notifyListeners();
      }
    } catch (e) {
      Log.e('Overlay', 'Error picking area region: $e');
    }
  }

  Future<void> revealAreaRecordingRegion() async {
    try {
      await _nativeBridge.revealAreaRecordingRegion();
      await ClingfyTelemetry.addUiBreadcrumb(
        category: 'ui.selection',
        message: 'Selection area revealed',
        data: {'displayId': _areaDisplayId, 'hasArea': _areaRect != null},
      );
    } catch (e) {
      Log.e('Overlay', 'Error revealing area region: $e');
    }
  }

  Future<void> clearAreaRecordingSelection() async {
    await _clearAreaSelectionLocal();
    try {
      await _nativeBridge.clearAreaRecordingSelection();
      await ClingfyTelemetry.addUiBreadcrumb(
        category: 'ui.selection',
        message: 'Selection area cleared',
      );
    } catch (e) {
      Log.e('Overlay', 'Error clearing area region: $e');
    }
  }

  Future<void> _clearAreaSelectionLocal() async {
    _areaDisplayId = null;
    _areaRect = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pref.areaDisplayId');
    await prefs.remove('pref.areaRect.x');
    await prefs.remove('pref.areaRect.y');
    await prefs.remove('pref.areaRect.width');
    await prefs.remove('pref.areaRect.height');
    notifyListeners();
  }

  void _onAreaSelectionClearedFromNative() {
    unawaited(_clearAreaSelectionLocal());
  }

  @override
  void dispose() {
    _nativeBridge.setOnCameraOverlayMoved(null);
    _nativeBridge.setOnAreaSelectionCleared(null);
    super.dispose();
  }
}
