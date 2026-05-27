import 'package:clingfy/app/home/preview/widgets/inline_preview.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../../test_helpers/native_test_setup.dart';

class _FakeRecordingController extends ChangeNotifier
    implements RecordingController {
  int? _textureId;

  @override
  int? get inlinePreviewTextureId => _textureId;

  set inlinePreviewTextureId(int? value) {
    if (_textureId == value) return;
    _textureId = value;
    notifyListeners();
  }

  // Only this getter is read by InlinePreview; the rest of the
  // RecordingController surface is unused by the widget under test.
  // ignore: no_runtimetype_tostring
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _wrap(Widget child, RecordingController recording) {
  return ChangeNotifierProvider<RecordingController>.value(
    value: recording,
    child: MaterialApp(
      home: Scaffold(body: SizedBox(width: 400, height: 300, child: child)),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    InlinePreview.debugIsWindowsOverride = true;
    await installCommonNativeMocks();
  });

  tearDown(() async {
    InlinePreview.debugIsWindowsOverride = null;
    await clearCommonNativeMocks();
  });

  group('InlinePreview Windows branch', () {
    testWidgets(
      'renders Texture widget when RecordingController exposes a textureId',
      (tester) async {
        final fake = _FakeRecordingController();
        fake.inlinePreviewTextureId = 99;

        await tester.pumpWidget(
          _wrap(const InlinePreview(cornerRadius: 12), fake),
        );
        // Allow the post-frame onPlatformViewCreated callback to fire.
        await tester.pump();

        expect(find.byType(Texture), findsOneWidget);
        final tex = tester.widget<Texture>(find.byType(Texture));
        expect(tex.textureId, 99);
      },
    );

    testWidgets(
      'renders black ColoredBox while textureId is null and updates to Texture once set',
      (tester) async {
        final fake = _FakeRecordingController();

        await tester.pumpWidget(
          _wrap(const InlinePreview(cornerRadius: 12), fake),
        );
        await tester.pump();

        expect(find.byType(Texture), findsNothing);
        expect(find.byType(ColoredBox), findsWidgets);

        fake.inlinePreviewTextureId = 7;
        await tester.pump();

        expect(find.byType(Texture), findsOneWidget);
        final tex = tester.widget<Texture>(find.byType(Texture));
        expect(tex.textureId, 7);
      },
    );

    testWidgets(
      'fires onPlatformViewCreated exactly once with the no-platform-view sentinel',
      (tester) async {
        final fake = _FakeRecordingController();
        fake.inlinePreviewTextureId = 11;
        final ids = <int>[];

        await tester.pumpWidget(
          _wrap(
            InlinePreview(cornerRadius: 12, onPlatformViewCreated: ids.add),
            fake,
          ),
        );
        // Drive the post-frame callback.
        await tester.pump();
        await tester.pump();

        // Sentinel -1 indicates "no platform view created" — Windows has
        // no AppKit view; the panel just needs to know the host is in
        // the tree so it can fire its `onPreviewHostMounted` chain.
        expect(ids, hasLength(1));
        expect(ids.single, -1);
      },
    );
  });
}
