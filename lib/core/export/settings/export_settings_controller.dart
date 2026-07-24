import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clingfy/core/logging/logger_service.dart';
import 'package:clingfy/core/export/models/export_settings_types.dart';

class ExportSettingsController extends ChangeNotifier {
  String _exportFormat = ExportFormat.mov.wireValue;
  String _exportCodec = ExportCodec.hevc.wireValue;
  String _exportBitrate = ExportBitratePreset.auto.wireValue;
  String _gifSize = GifSizePreset.large.wireValue;

  String get exportFormat => _exportFormat;
  String get exportCodec => _exportCodec;
  String get exportBitrate => _exportBitrate;
  String get gifSize => _gifSize;
  ExportFormat get exportFormatType => exportFormatFromWire(_exportFormat);
  ExportCodec get exportCodecType => exportCodecFromWire(_exportCodec);
  ExportBitratePreset get exportBitrateType =>
      exportBitratePresetFromWire(_exportBitrate);
  GifSizePreset get gifSizeType => gifSizePresetFromWire(_gifSize);

  Future<void> loadPreferences(SharedPreferences prefs) async {
    _exportFormat = exportFormatFromWire(
      prefs.getString('exportFormat'),
    ).wireValue;
    _exportCodec = exportCodecFromWire(
      prefs.getString('exportCodec'),
    ).wireValue;
    _exportBitrate = exportBitratePresetFromWire(
      prefs.getString('exportBitrate'),
    ).wireValue;
    _gifSize = gifSizePresetFromWire(prefs.getString('gifSize')).wireValue;
    notifyListeners();
  }

  Future<void> updateExportFormat(String value) async {
    final next = exportFormatFromWire(
      value,
      fallback: exportFormatType,
    ).wireValue;
    if (next == _exportFormat) return;
    _exportFormat = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString('exportFormat', next);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist export format', e, st);
    }
  }

  Future<void> updateExportFormatType(ExportFormat value) async {
    await updateExportFormat(value.wireValue);
  }

  Future<void> updateExportCodec(String value) async {
    final next = exportCodecFromWire(
      value,
      fallback: exportCodecType,
    ).wireValue;
    if (next == _exportCodec) return;
    _exportCodec = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString('exportCodec', next);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist export codec', e, st);
    }
  }

  Future<void> updateExportCodecType(ExportCodec value) async {
    await updateExportCodec(value.wireValue);
  }

  Future<void> updateExportBitrate(String value) async {
    final next = exportBitratePresetFromWire(
      value,
      fallback: exportBitrateType,
    ).wireValue;
    if (next == _exportBitrate) return;
    _exportBitrate = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString('exportBitrate', next);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist export bitrate', e, st);
    }
  }

  Future<void> updateExportBitrateType(ExportBitratePreset value) async {
    await updateExportBitrate(value.wireValue);
  }

  Future<void> updateGifSize(String value) async {
    final next = gifSizePresetFromWire(value, fallback: gifSizeType).wireValue;
    if (next == _gifSize) return;
    _gifSize = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString('gifSize', next);
    } catch (e, st) {
      Log.e('Settings', 'Failed to persist GIF size', e, st);
    }
  }

  Future<void> updateGifSizeType(GifSizePreset value) async {
    await updateGifSize(value.wireValue);
  }
}
