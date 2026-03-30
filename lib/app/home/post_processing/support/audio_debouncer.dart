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

typedef AudioDebouncer = ActionDebouncer;
