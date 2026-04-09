import 'dart:async';

import 'package:clingfy/app/home/models/home_ui_prefs.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/ui/platform/widgets/desktop_pane_layout.dart';
import 'package:flutter/foundation.dart';

enum HomeUiNoticeTone { info, success, warning, error }

class HomeUiNoticeAction {
  const HomeUiNoticeAction({
    required this.label,
    required this.onPressed,
    this.semanticLabel,
  });

  final String label;
  final String? semanticLabel;
  final VoidCallback onPressed;
}

class HomeUiNotice {
  const HomeUiNotice({
    this.message,
    this.rawErrorCode,
    this.tone = HomeUiNoticeTone.info,
    this.action,
    this.autoDismissAfter,
  }) : assert(message != null || rawErrorCode != null);

  const HomeUiNotice.errorCode(this.rawErrorCode)
    : message = null,
      tone = HomeUiNoticeTone.error,
      action = null,
      autoDismissAfter = null;

  final String? message;
  final String? rawErrorCode;
  final HomeUiNoticeTone tone;
  final HomeUiNoticeAction? action;
  final Duration? autoDismissAfter;
}

class HomeUiState extends ChangeNotifier {
  HomeUiNotice? _notice;
  Timer? _noticeTimer;
  int _noticeVersion = 0;
  DisplayTargetMode _targetMode = DisplayTargetMode.explicitId;
  bool _indicatorPinned = false;
  bool _isSettingsOpen = false;
  bool _uiPrefsHydrated = false;
  int _recordingSidebarIndex = 0;
  int _postProcessingSidebarIndex = 0;
  DesktopPaneLayoutPrefs _paneLayout = kDefaultHomePaneLayoutPrefs;

  HomeUiNotice? get notice => _notice;
  String? get errorMessage => _notice?.rawErrorCode;
  DisplayTargetMode get targetMode => _targetMode;
  bool get indicatorPinned => _indicatorPinned;
  bool get isSettingsOpen => _isSettingsOpen;
  bool get uiPrefsHydrated => _uiPrefsHydrated;
  int get recordingSidebarIndex => _recordingSidebarIndex;
  int get postProcessingSidebarIndex => _postProcessingSidebarIndex;
  DesktopPaneLayoutPrefs get paneLayout => _paneLayout;

  DesktopPaneState paneStateFor(DesktopPaneId id) => _paneLayout.stateFor(id);

  void setError(String? value) {
    if (value == null) {
      clearNotice();
      return;
    }
    setNotice(HomeUiNotice.errorCode(value));
  }

  void setNotice(HomeUiNotice? value) {
    final current = _notice;
    if (_sameNotice(current, value)) {
      return;
    }

    _noticeTimer?.cancel();
    _noticeTimer = null;
    _noticeVersion += 1;
    _notice = value;
    notifyListeners();

    if (value == null) {
      return;
    }

    final dismissAfter = _resolvedDismissDuration(value);
    if (dismissAfter == null) {
      return;
    }

    final noticeVersion = _noticeVersion;
    _noticeTimer = Timer(dismissAfter, () {
      if (_noticeVersion != noticeVersion) {
        return;
      }
      final activeNotice = _notice;
      if (activeNotice == null ||
          _resolvedDismissDuration(activeNotice) == null) {
        return;
      }
      _notice = null;
      notifyListeners();
    });
  }

  void clearNotice() => setNotice(null);
  void clearError() => clearNotice();

  void clearTransientNotice() {
    final current = _notice;
    if (current == null) {
      return;
    }
    if (_resolvedDismissDuration(current) == null) {
      return;
    }
    clearNotice();
  }

  void setTargetMode(DisplayTargetMode value) {
    if (_targetMode == value) return;
    _targetMode = value;
    notifyListeners();
  }

  void setIndicatorPinned(bool value) {
    if (_indicatorPinned == value) return;
    _indicatorPinned = value;
    notifyListeners();
  }

  void setSettingsOpen(bool value) {
    if (_isSettingsOpen == value) return;
    _isSettingsOpen = value;
    notifyListeners();
  }

  void markHydrated() {
    if (_uiPrefsHydrated) return;
    _uiPrefsHydrated = true;
    notifyListeners();
  }

  void setRecordingSidebarIndex(int value) {
    if (_recordingSidebarIndex == value) return;
    _recordingSidebarIndex = value;
    notifyListeners();
  }

  void setPostProcessingSidebarIndex(int value) {
    if (_postProcessingSidebarIndex == value) return;
    _postProcessingSidebarIndex = value;
    notifyListeners();
  }

  void applyPaneLayoutPrefs(DesktopPaneLayoutPrefs value) {
    if (_paneLayout == value) return;
    _paneLayout = value;
    notifyListeners();
  }

  bool _sameNotice(HomeUiNotice? current, HomeUiNotice? next) {
    return current?.message == next?.message &&
        current?.rawErrorCode == next?.rawErrorCode &&
        current?.tone == next?.tone &&
        current?.action?.label == next?.action?.label &&
        current?.action?.semanticLabel == next?.action?.semanticLabel &&
        current?.autoDismissAfter == next?.autoDismissAfter;
  }

  Duration? _resolvedDismissDuration(HomeUiNotice notice) {
    return notice.autoDismissAfter ?? _defaultDismissDuration(notice);
  }

  Duration? _defaultDismissDuration(HomeUiNotice notice) {
    final hasAction = notice.action != null;
    return switch (notice.tone) {
      HomeUiNoticeTone.success =>
        hasAction ? const Duration(seconds: 6) : const Duration(seconds: 5),
      HomeUiNoticeTone.info =>
        hasAction ? const Duration(seconds: 6) : const Duration(seconds: 4),
      HomeUiNoticeTone.warning => null,
      HomeUiNoticeTone.error => null,
    };
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    super.dispose();
  }
}
