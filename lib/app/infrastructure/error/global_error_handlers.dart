import 'dart:developer' as developer;
import 'dart:ui';

import 'package:clingfy/app/infrastructure/error/error_widget_builder.dart';
import 'package:clingfy/core/logging/logger_service.dart';
import 'package:flutter/material.dart';

class GlobalErrorHandlers {
  /// A known, benign Flutter *framework* assertion that only exists in debug
  /// builds: on macOS, key auto-repeat can deliver a `KeyDownEvent` while
  /// `HardwareKeyboard` still has that physical key marked pressed (a missed
  /// key-up), tripping `HardwareKeyboard._assertEventIsRegular`. It is stripped
  /// from release builds and does not affect the app, so drop it instead of
  /// flooding the JSONL log / Sentry. (Holding Backspace over the editor is the
  /// usual trigger.) See flutter/flutter hardware_keyboard.dart.
  static bool _isBenignKeyRepeatAssertion(FlutterErrorDetails details) {
    final text = details.exceptionAsString();
    return text.contains('hardware_keyboard.dart') &&
        (text.contains('_pressedKeys.containsKey') ||
            text.contains('KeyDownEvent is dispatched'));
  }

  static void install() {
    FlutterError.onError = (FlutterErrorDetails details) {
      // Drop the known debug-only keyboard-repeat framework assertion silently —
      // it is not an app error and would otherwise spam the log on a held key.
      if (_isBenignKeyRepeatAssertion(details)) {
        return;
      }
      FlutterError.presentError(details);
      developer.log(
        'Flutter framework error',
        name: 'clingfy.flutter',
        error: details.exception,
        stackTrace: details.stack,
      );
      // Phase 10.4: uncaught framework errors previously stopped at
      // dart:developer and never reached the JSONL log/diagnostics
      // package. Guard against the logger itself failing — an exception
      // here would recurse straight back into FlutterError.onError.
      try {
        Log.e(
          'FlutterError',
          'Uncaught Flutter framework error',
          details.exception,
          details.stack,
        );
      } catch (_) {
        // Swallow: never let logging recurse into the error handler.
      }
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      developer.log(
        'Uncaught root isolate error',
        name: 'clingfy.platform',
        error: error,
        stackTrace: stack,
      );
      try {
        Log.e(
          'PlatformDispatcher',
          'Uncaught root isolate error',
          error,
          stack,
        );
      } catch (_) {
        // Swallow: never let logging take down the error handler.
      }
      return true;
    };

    ErrorWidget.builder = AppErrorWidgetBuilder.build;
  }
}
