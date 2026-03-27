import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/widgets/export_progress_dock.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../../test_helpers/native_test_setup.dart';

class TestPostProcessingController extends PostProcessingController {
  TestPostProcessingController._({required this.settings, required this.player})
    : super(settings: settings, player: player, channel: NativeBridge.instance);

  factory TestPostProcessingController() {
    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    final player = PlayerController(nativeBridge: NativeBridge.instance);
    final controller = TestPostProcessingController._(
      settings: settings,
      player: player,
    );
    controller.attachToRecording(
      sessionId: 'rec_test_session',
      sourcePath: '/tmp/original.mov',
    );
    return controller;
  }

  final SettingsController settings;
  final PlayerController player;

  bool exporting = false;
  bool inBackground = false;
  bool cancelRequested = false;
  double? progress;
  int cancelCalls = 0;

  @override
  bool get isExporting => exporting;

  @override
  bool get isExportInBackground => inBackground;

  @override
  bool get isExportCancelRequested => cancelRequested;

  @override
  double? get exportProgress => progress;

  void setExportState({
    required bool exporting,
    required bool inBackground,
    required bool cancelRequested,
    double? progress,
  }) {
    this.exporting = exporting;
    this.inBackground = inBackground;
    this.cancelRequested = cancelRequested;
    this.progress = progress;
    notifyListeners();
  }

  @override
  Future<void> cancelExport() async {
    cancelCalls += 1;
    cancelRequested = true;
    notifyListeners();
  }

  @override
  void dispose() {
    super.dispose();
    player.dispose();
    settings.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await installCommonNativeMocks();
  });

  tearDown(() async {
    await clearCommonNativeMocks();
  });

  Widget buildApp(PostProcessingController controller) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ChangeNotifierProvider<PostProcessingController>.value(
          value: controller,
          child: const Stack(children: [ExportProgressDock()]),
        ),
      ),
    );
  }

  testWidgets('renders only while export is active and foregrounded', (
    tester,
  ) async {
    final controller = TestPostProcessingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(buildApp(controller));
    expect(find.byType(LinearProgressIndicator), findsNothing);

    controller.setExportState(
      exporting: true,
      inBackground: false,
      cancelRequested: false,
      progress: 0.5,
    );
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    controller.setExportState(
      exporting: true,
      inBackground: true,
      cancelRequested: false,
      progress: 0.5,
    );
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('cancel dialog closes itself when export ends', (tester) async {
    final controller = TestPostProcessingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(buildApp(controller));

    controller.setExportState(
      exporting: true,
      inBackground: false,
      cancelRequested: false,
      progress: 0.5,
    );
    await tester.pump();

    await tester.tap(find.text('Stop Export'));
    await tester.pumpAndSettle();

    expect(find.text('Cancel Export'), findsOneWidget);
    expect(
      find.text('Are you sure you want to stop the export process?'),
      findsOneWidget,
    );

    controller.setExportState(
      exporting: false,
      inBackground: false,
      cancelRequested: false,
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Cancel Export'), findsNothing);
    expect(
      find.text('Are you sure you want to stop the export process?'),
      findsNothing,
    );
    expect(controller.cancelCalls, 0);
    expect(controller.cancelRequested, isFalse);
  });
}
