import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:clingfy/core/models/app_models.dart';

class PostProcessingSettingsController extends ChangeNotifier {
  static const String _prefPostAudioGainDb = 'postAudioGainDb';
  static const String _prefPostAudioVolumePercent = 'postAudioVolumePercent';
  static const String _prefPostAutoNormalizeEnabled =
      'postAutoNormalizeEnabled';
  static const String _prefPostTargetLoudnessDbfs = 'postTargetLoudnessDbfs';
  static const String _prefPostZoomEffectEnabled = 'postZoomEffectEnabled';
  static const String _prefPostZoomFactor = 'postZoomFactor';

  LayoutPreset _layoutPreset = LayoutPreset.auto;
  ResolutionPreset _resolutionPreset = ResolutionPreset.auto;
  FitMode _fitMode = FitMode.fit;
  double _postAudioGainDb = 0.0;
  double _postAudioVolumePercent = 100.0;
  bool _postAutoNormalizeEnabled = false;
  double _postTargetLoudnessDbfs = -16.0;
  bool _postZoomEffectEnabled = true;
  double _postZoomFactor = 1.5;

  LayoutPreset get layoutPreset => _layoutPreset;
  ResolutionPreset get resolutionPreset => _resolutionPreset;
  FitMode get fitMode => _fitMode;
  double get postAudioGainDb => _postAudioGainDb;
  double get postAudioVolumePercent => _postAudioVolumePercent;
  bool get postAutoNormalizeEnabled => _postAutoNormalizeEnabled;
  double get postTargetLoudnessDbfs => _postTargetLoudnessDbfs;
  bool get postZoomEffectEnabled => _postZoomEffectEnabled;
  double get postZoomFactor => _postZoomFactor;

  static double _clampPostAudioGainDb(double value) => value.clamp(0.0, 24.0);
  static double _clampPostAudioVolumePercent(double value) =>
      value.clamp(0.0, 100.0);
  static double _clampPostTargetLoudnessDbfs(double value) =>
      value.clamp(-24.0, -6.0);
  static double _clampPostZoomFactor(double value) =>
      value.isFinite ? value.clamp(1.0, 3.0).toDouble() : 1.0;

  Future<void> loadPreferences(SharedPreferences prefs) async {
    final layoutName = prefs.getString('layoutPreset');
    if (layoutName != null) {
      _layoutPreset = LayoutPreset.values.firstWhere(
        (e) => e.name == layoutName,
        orElse: () => LayoutPreset.auto,
      );
    }
    final resName = prefs.getString('resolutionPreset');
    if (resName != null) {
      _resolutionPreset = ResolutionPreset.values.firstWhere(
        (e) => e.name == resName,
        orElse: () => ResolutionPreset.auto,
      );
    }
    final fitName = prefs.getString('fitMode');
    if (fitName != null) {
      _fitMode = FitMode.values.firstWhere(
        (e) => e.name == fitName,
        orElse: () => FitMode.fit,
      );
    }

    _postAudioGainDb = _clampPostAudioGainDb(
      prefs.getDouble(_prefPostAudioGainDb) ?? 0.0,
    );
    _postAudioVolumePercent = _clampPostAudioVolumePercent(
      prefs.getDouble(_prefPostAudioVolumePercent) ?? 100.0,
    );
    _postAutoNormalizeEnabled =
        prefs.getBool(_prefPostAutoNormalizeEnabled) ?? false;
    _postTargetLoudnessDbfs = _clampPostTargetLoudnessDbfs(
      prefs.getDouble(_prefPostTargetLoudnessDbfs) ?? -16.0,
    );
    _postZoomEffectEnabled = prefs.getBool(_prefPostZoomEffectEnabled) ?? true;
    _postZoomFactor = _clampPostZoomFactor(
      prefs.getDouble(_prefPostZoomFactor) ?? 1.5,
    );
    notifyListeners();
  }

  Future<void> updateLayoutPreset(LayoutPreset value) async {
    if (value == _layoutPreset) return;
    _layoutPreset = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString('layoutPreset', value.name);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist layout preset', e, st);
    }
  }

  Future<void> updateResolutionPreset(ResolutionPreset value) async {
    if (value == _resolutionPreset) return;
    _resolutionPreset = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString('resolutionPreset', value.name);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist resolution preset', e, st);
    }
  }

  Future<void> updateFitMode(FitMode value) async {
    if (value == _fitMode) return;
    _fitMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString('fitMode', value.name);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist fit mode', e, st);
    }
  }

  Future<void> updatePostAudioGainDb(double value) async {
    final clamped = _clampPostAudioGainDb(value);
    if ((clamped - _postAudioGainDb).abs() < 0.001) return;
    _postAudioGainDb = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setDouble(_prefPostAudioGainDb, clamped);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist post audio gain', e, st);
    }
  }

  Future<void> updatePostAudioVolumePercent(double value) async {
    final clamped = _clampPostAudioVolumePercent(value);
    if ((clamped - _postAudioVolumePercent).abs() < 0.001) return;
    _postAudioVolumePercent = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setDouble(_prefPostAudioVolumePercent, clamped);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist post audio volume', e, st);
    }
  }

  Future<void> updatePostAutoNormalizeEnabled(bool value) async {
    if (value == _postAutoNormalizeEnabled) return;
    _postAutoNormalizeEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool(_prefPostAutoNormalizeEnabled, value);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist post auto-normalize setting', e, st);
    }
  }

  Future<void> updatePostTargetLoudnessDbfs(double value) async {
    final clamped = _clampPostTargetLoudnessDbfs(value);
    if ((clamped - _postTargetLoudnessDbfs).abs() < 0.001) return;
    _postTargetLoudnessDbfs = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setDouble(_prefPostTargetLoudnessDbfs, clamped);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist post target loudness', e, st);
    }
  }

  Future<void> updatePostZoomEffectEnabled(bool value) async {
    if (value == _postZoomEffectEnabled) return;
    _postZoomEffectEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool(_prefPostZoomEffectEnabled, value);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist post zoom effect enabled', e, st);
    }
  }

  Future<void> updatePostZoomFactor(double value) async {
    final clamped = _clampPostZoomFactor(value);
    if ((clamped - _postZoomFactor).abs() < 0.001) return;
    _postZoomFactor = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setDouble(_prefPostZoomFactor, clamped);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist post zoom factor', e, st);
    }
  }
}
