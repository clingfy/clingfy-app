import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs once for every test file under `test/`, before `main()`.
///
/// Its only job today is loading the bundled caption font.
///
/// **`flutter test` does not honour `pubspec.yaml`'s `fonts:` block.** Declaring
/// a family there makes it available to the running app, but the test harness
/// still renders with a stub font that draws every glyph as a filled rectangle.
/// A `TextStyle(fontFamily: 'ClingfyCaption')` in a test resolves to boxes
/// unless the bytes are handed to a [FontLoader] explicitly, which is what this
/// does.
///
/// That gap is not academic. Caption rasterization tests were green for a whole
/// implementation cycle while every bitmap they produced was tofu, because
/// assertions like `width > 0` are satisfied by a row of boxes. The regression
/// was found by burning captions into a real recording and looking at the
/// frames, not by any test.
///
/// The bytes come from `rootBundle`, which `flutter_tools` populates into
/// `build/unit_test_assets/` from the pubspec declaration — so the asset path
/// here must stay in step with `pubspec.yaml`.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final loader = FontLoader('ClingfyCaption')
    ..addFont(
      rootBundle.load('assets/fonts/NotoSansArabic-SemiBold-caption.ttf'),
    );
  await loader.load();

  await testMain();
}
