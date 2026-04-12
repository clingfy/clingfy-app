import 'package:clingfy/app/home/guide/home_guide_step.dart';
import 'package:clingfy/app/home/home_prefs_store.dart';
import 'package:flutter/foundation.dart';

class HomeGuideController extends ChangeNotifier {
  HomeGuideController({required HomePrefsStore prefsStore})
    : _prefsStore = prefsStore;

  final HomePrefsStore _prefsStore;

  bool _autoStartChecked = false;
  bool _isVisible = false;
  HomeGuideStep _currentStep = HomeGuideStep.sidebar;
  int _spotlightRequestToken = 0;

  bool get isVisible => _isVisible;
  HomeGuideStep get currentStep => _currentStep;
  int get spotlightRequestToken => _spotlightRequestToken;

  Future<void> maybeStartAutomatically({required bool canShow}) async {
    if (_autoStartChecked) {
      return;
    }
    _autoStartChecked = true;

    if (!canShow) {
      return;
    }

    final seen = await _prefsStore.getGuideSeen();
    if (seen) {
      return;
    }

    start();
  }

  void start({HomeGuideStep step = HomeGuideStep.sidebar}) {
    final shouldNotify = !_isVisible || _currentStep != step;
    _isVisible = true;
    _currentStep = step;
    if (shouldNotify) {
      notifyListeners();
    }
  }

  void back() {
    if (!_isVisible || _currentStep.isFirst) {
      return;
    }

    _currentStep = HomeGuideStep.values[_currentStep.index - 1];
    notifyListeners();
  }

  void next() {
    if (!_isVisible || _currentStep.isLast) {
      return;
    }

    _currentStep = HomeGuideStep.values[_currentStep.index + 1];
    notifyListeners();
  }

  Future<void> skip() => _close(markSeen: true);

  Future<void> finish() => _close(markSeen: true);

  void requestSpotlightRefresh() {
    if (!_isVisible) {
      return;
    }

    _spotlightRequestToken += 1;
    notifyListeners();
  }

  Future<void> _close({required bool markSeen}) async {
    if (markSeen) {
      await _prefsStore.setGuideSeen(true);
    }

    final wasVisible = _isVisible;
    _isVisible = false;
    _currentStep = HomeGuideStep.sidebar;
    _spotlightRequestToken = 0;
    if (wasVisible) {
      notifyListeners();
    }
  }
}
