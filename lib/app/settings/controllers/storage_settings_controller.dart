import 'package:flutter/foundation.dart';

import 'package:clingfy/core/bridges/native_bridge.dart';
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

  StorageSnapshot? get snapshot => _snapshot;
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
}
