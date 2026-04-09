import 'dart:async';

import 'package:flutter/foundation.dart';

class ActionDebouncer {
  final Duration delay;
  Timer? _timer;

  ActionDebouncer({this.delay = const Duration(milliseconds: 150)});

  /// Cancels the previous timer and starts a new one.
  /// The action only runs if [delay] passes without this being called again.
  void run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Always clean up timers when the screen closes.
  void dispose() {
    cancel();
  }
}

class ActionThrottler {
  final Duration interval;

  Timer? _timer;
  VoidCallback? _pendingAction;
  DateTime? _lastRunAt;

  ActionThrottler({this.interval = const Duration(milliseconds: 16)});

  void run(VoidCallback action) {
    final now = DateTime.now();
    final lastRunAt = _lastRunAt;
    if (lastRunAt == null || now.difference(lastRunAt) >= interval) {
      _timer?.cancel();
      _timer = null;
      _pendingAction = null;
      _lastRunAt = now;
      action();
      return;
    }

    _pendingAction = action;
    if (_timer != null) {
      return;
    }

    final remaining = interval - now.difference(lastRunAt);
    _timer = Timer(remaining, _flushPending);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pendingAction = null;
  }

  void dispose() {
    cancel();
  }

  void _flushPending() {
    _timer = null;
    final action = _pendingAction;
    _pendingAction = null;
    if (action == null) {
      return;
    }

    _lastRunAt = DateTime.now();
    action();
  }
}

typedef AudioDebouncer = ActionDebouncer;
