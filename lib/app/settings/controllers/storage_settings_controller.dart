import 'package:flutter/foundation.dart';

import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/models/caption_model_info.dart';
import 'package:clingfy/core/models/storage_snapshot.dart';

class StorageSettingsController extends ChangeNotifier {
  StorageSettingsController({required NativeBridge nativeBridge})
    : _nativeBridge = nativeBridge;

  final NativeBridge _nativeBridge;

  StorageSnapshot? _snapshot;
  bool _isLoading = false;
  String? _error;
  bool _hasLoadedOnce = false;
  Future<void>? _refreshFuture;

  CaptionModelInfo _captionModel = CaptionModelInfo.notInstalled;

  StorageSnapshot? get snapshot => _snapshot;

  /// The speech model's footprint. Fetched alongside the snapshot rather than
  /// inside it: the snapshot is a fixed payload on the record-start preflight
  /// and a timer, and this only matters on the page that shows it.
  CaptionModelInfo get captionModel => _captionModel;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> ensureLoaded() async {
    if (_hasLoadedOnce || _isLoading) return;
    await refresh();
  }

  Future<void> refresh() async {
    if (_refreshFuture != null) {
      return _refreshFuture!;
    }

    _isLoading = true;
    _error = null;
    final refreshFuture = _runRefresh();
    _refreshFuture = refreshFuture;
    notifyListeners();
    await refreshFuture;
  }

  Future<void> _runRefresh() async {
    try {
      _snapshot = await _nativeBridge.getStorageSnapshot();
      // Never throws — it degrades to "nothing installed" — so it cannot take
      // the storage page down with it.
      _captionModel = await _nativeBridge.getCaptionModelInfo();
      _hasLoadedOnce = true;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      _refreshFuture = null;
      notifyListeners();
    }
  }

  Future<void> revealRecordingsFolder() async {
    await _nativeBridge.revealRecordingsFolder();
  }

  Future<void> revealTempFolder() async {
    await _nativeBridge.revealTempFolder();
  }

  Future<void> openSystemStorageSettings() async {
    await _nativeBridge.openSystemSettings('storage');
  }

  Future<int> clearCachedRecordings() async {
    final deletedCount = await _nativeBridge.clearCachedRecordings();
    await refresh();
    return deletedCount;
  }

  /// Unloads and removes the speech model, then re-reads the page.
  ///
  /// Lets a `MODEL_IN_USE` PlatformException escape so the section can show its
  /// message: the button's own enablement is based on a value that may be half
  /// a minute stale, and native is the one that actually decides.
  Future<int> deleteCaptionModel() async {
    final freedBytes = await _nativeBridge.deleteCaptionModel();
    await refresh();
    return freedBytes;
  }
}
