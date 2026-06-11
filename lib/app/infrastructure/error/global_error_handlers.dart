import 'dart:developer' as developer;
import 'dart:ui';

import 'package:clingfy/app/infrastructure/error/error_widget_builder.dart';
import 'package:clingfy/app/infrastructure/logging/logger_service.dart';
import 'package:flutter/material.dart';

class GlobalErrorHandlers {
  static void install() {
    FlutterError.onError = (FlutterErrorDetails details) {
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
