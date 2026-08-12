import 'dart:async';
import 'dart:io';

import 'package:clingfy/app/home/home_actions.dart';
import 'package:clingfy/app/home/home_prefs_store.dart';
import 'package:clingfy/app/home/home_scope.dart';
import 'package:clingfy/app/home/home_ui_state.dart';
import 'package:clingfy/app/home/overlay/overlay_controller.dart';
import 'package:clingfy/app/home/post_processing/post_processing_controller.dart';
import 'package:clingfy/app/home/recording/countdown_controller.dart';
import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/infrastructure/observability/crash_reporting_consent.dart';
import 'package:clingfy/app/permissions/permissions_controller.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/app/shell/app_scope.dart';
import 'package:clingfy/commercial/licensing/license_controller.dart';
import 'package:clingfy/commercial/licensing/license_service.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/core/devices/device_controller.dart';
import 'package:clingfy/core/captions/subtitle_serializer.dart';
import 'package:clingfy/core/preview/player_controller.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/native_test_setup.dart';

/// What the user is TOLD after an export whose burn-in was skipped.
///
/// A skipped burn-in leaves an `exportVideo` payload byte-identical to one from
/// before captions existed: native renders happily, the method channel returns
/// a path, and every downstream check says the export succeeded. "Export
/// successful" on top of that is how someone publishes a video they believe is
/// subtitled — so the saved-file notice is the last place the truth can still
/// be told, and this pins that it is.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory project;
  late List<MethodCall> calls;

  /// Held open to keep a transcription in flight. Null lets `generateCaptions`
  /// answer immediately, which is what every test but the export-interlock one
  /// wants.
  Completer<List<Map<String, Object?>>>? generateGate;

  setUp(() async {
    await installCommonNativeMocks();
    // The crash-reporting disclosure fires after the FIRST successful export
    // and would put a modal over the notice this test reads.
    await CrashReportingConsent.markNoticeSeen();
    project = await Directory.systemTemp.createTemp('clingfy_burnin_notice');
    calls = [];
    generateGate = null;
  });

  tearDown(() async {
    await clearCommonNativeMocks();
    // No `PostStateStore.settled()` here: this is a widget test, and awaiting
    // the store's real-IO queue from inside the fake-async zone never returns.
    // Nothing in this file asserts on persisted state, so the writes are simply
    // left to land or fail on their own — they already handle both.
    try {
      if (project.existsSync()) project.deleteSync(recursive: true);
    } catch (_) {
      // A write that outlived the test can hold the directory; leaking a temp
      // dir is better than failing a green test on cleanup.
    }
  });

  /// Bounded pumps instead of `pumpAndSettle`, each paired with a real-time
  /// yield.
  ///
  /// Two reasons, and both bit: the home controllers keep periodic timers
  /// running (device polling, mic level) so `pumpAndSettle` never terminates
  /// here; and the export path does genuine file I/O — rasterising a caption
  /// PNG — which fake-async pumping alone will never let finish.
  Future<void> settle(WidgetTester tester, {int steps = 40}) async {
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
    }
  }

  /// Pumps until [done], so a test never asserts on a notice the export has not
  /// had the chance to publish yet.
  Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200; i++) {
      if (done()) return;
      await settle(tester, steps: 1);
    }
  }

  Future<void> emitWorkflowEvent(Map<String, Object?> event) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final completer = Completer<void>();
    messenger.handlePlatformMessage(
      NativeChannel.workflowEvents,
      const StandardMethodCodec().encodeSuccessEnvelope(event),
      (_) => completer.complete(),
    );
    await completer.future;
  }

  /// Builds the whole home scope and drives it to a ready preview of
  /// [project], with a burn-in transcript already generated.
  ///
  /// [exportSizeReturns] is the lever: null is native declining to say what
  /// size the frames will be, which is the honest reason to skip a burn-in.
  Future<(HomeActions, HomeUiState, BuildContext)> openReadyPreview(
    WidgetTester tester, {
    required Object? exportSizeReturns,
  }) async {
    SharedPreferences.setMockInitialValues({
      'postSubtitleMode': SubtitleMode.burnIn.wireValue,
      'crashReportingNoticeSeen': true,
    });

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(screenRecorderChannel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'captionsCapability':
          return {
            'available': true,
            'hasMicAudio': true,
            'hasSystemAudio': true,
          };
        case 'generateCaptions':
          final gate = generateGate;
          if (gate != null) return gate.future;
          return [
            {'id': 'c1', 'startMs': 0, 'endMs': 1500, 'text': 'hello there'},
          ];
        case 'resolveExportSize':
          return exportSizeReturns;
        case 'exportVideo':
          return '${project.path}/My Recording.mp4';
        case 'processVideo':
          return '/tmp/preview.mov';
        case 'getExcludeRecorderApp':
          return false;
        case 'getExcludeMicFromSystemAudio':
          return true;
        default:
          return null;
      }
    });

    final nativeBridge = NativeBridge.instance;
    final settings = SettingsController(nativeBridge: nativeBridge);
    await settings.loadPreferences();
    final recording = RecordingController(
      nativeBridge: nativeBridge,
      settings: settings,
    );
    final player = PlayerController(nativeBridge: nativeBridge);
    final devices = DeviceController(nativeBridge: nativeBridge);
    final overlay = OverlayController(bridge: nativeBridge);
    final permissions = PermissionsController(bridge: nativeBridge);
    final post = PostProcessingController(
      settings: settings,
      player: player,
      channel: nativeBridge,
    );
    final license = LicenseController();
    final countdown = CountdownController();
    final uiState = HomeUiState();
    addTearDown(() {
      countdown.dispose();
      recording.dispose();
      devices.dispose();
      overlay.dispose();
      permissions.dispose();
      settings.dispose();
      player.dispose();
      post.dispose();
      license.dispose();
      uiState.dispose();
    });

    // A settled paid entitlement, so the export is not gated behind the
    // paywall and `consumeExport` needs no network.
    license
      ..isLoading = false
      ..state = const LicenseState(
        isValid: true,
        entitledPro: true,
        plan: 'lifetime',
        isUpdateCovered: true,
        trialExportsRemaining: 0,
        memberSince: null,
        activatedAt: null,
        updatesExpiresAt: null,
        message: 'ok',
      );

    final actions = HomeActions(
      scope: HomeScope(
        app: AppScope(nativeBridge: nativeBridge, settings: settings),
        recording: recording,
        player: player,
        devices: devices,
        overlay: overlay,
        permissions: permissions,
        post: post,
        license: license,
        countdown: countdown,
        uiState: uiState,
        prefsStore: HomePrefsStore(),
      ),
    );

    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildDarkTheme(),
        builder: (context, child) =>
            MacosTheme(data: buildMacosTheme(Brightness.dark), child: child!),
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );
    await tester.pump();

    // Through the real workflow, so `exportFromUi`'s preview-ready preconditions
    // are satisfied the way the app satisfies them.
    recording.beginRecordingStartIntent();
    final sessionId = recording.sessionId!;
    await emitWorkflowEvent({
      'type': 'recordingStarted',
      'sessionId': sessionId,
    });
    await recording.stopRecording();
    await emitWorkflowEvent({
      'type': 'recordingFinalized',
      'sessionId': sessionId,
      'projectPath': project.path,
    });
    await emitWorkflowEvent({
      'type': 'previewReady',
      'sessionId': sessionId,
      'path': '${project.path}/preview.mov',
      'token': 'preview_token',
    });
    await settle(tester);

    post.attachToRecording(sessionId: sessionId, projectPath: project.path);
    await settle(tester);
    await post.generateCaptions();
    await settle(tester);
    expect(post.exportSubtitleMode, SubtitleMode.burnIn);

    return (actions, uiState, context);
  }

  /// Runs the export the way the toolbar does, submitting the save dialog, and
  /// returns once the export has published its notice.
  Future<HomeUiNotice> exportThroughUi(
    WidgetTester tester,
    HomeActions actions,
    HomeUiState uiState,
    BuildContext context,
  ) async {
    unawaited(actions.exportFromUi(context));
    await settleUntil(tester, () => find.text('Export').evaluate().isNotEmpty);
    expect(find.text('Export'), findsOneWidget);
    await tester.tap(find.text('Export'));
    await settleUntil(tester, () => uiState.notice != null);
    final notice = uiState.notice;
    expect(
      notice,
      isNotNull,
      reason: 'the export ran to completion and has to say something',
    );
    return notice!;
  }

  testWidgets('a skipped burn-in is not reported as a plain success', (
    tester,
  ) async {
    final (actions, uiState, context) = await openReadyPreview(
      tester,
      exportSizeReturns: null,
    );

    final notice = await exportThroughUi(tester, actions, uiState, context);

    final l10n = AppLocalizations.of(context)!;
    expect(
      notice.message,
      startsWith(l10n.exportSavedWithoutSubtitles),
      reason:
          'the file is on disk without the subtitles the user asked to burn '
          'in; "Export successful" is a lie the payload cannot reveal',
    );
    expect(notice.message, isNot(startsWith(l10n.exportSuccess)));
    expect(notice.tone, HomeUiNoticeTone.warning);

    // The notice schedules its own auto-dismiss; leaving it armed trips the
    // binding's pending-timer check before teardown ever runs.
    uiState.clearNotice();
  });

  testWidgets('an export that did burn in still reads as a success', (
    tester,
  ) async {
    final (actions, uiState, context) = await openReadyPreview(
      tester,
      exportSizeReturns: const {'width': 1920, 'height': 1080},
    );

    final notice = await exportThroughUi(tester, actions, uiState, context);

    final l10n = AppLocalizations.of(context)!;
    expect(notice.message, startsWith(l10n.exportSuccess));
    expect(notice.tone, HomeUiNoticeTone.success);

    uiState.clearNotice();
  });

  testWidgets('a running transcription blocks the export outright', (
    tester,
  ) async {
    // The interlock, at the only place that can enforce it: a transcription
    // landing mid-render re-rasterizes the NEW transcript for the preview, and
    // the export must not be startable into that. The controller has two locks
    // for this — the narrow one keeps the captions panel (and its Stop button)
    // live, so ONLY the export action carries the wide one. Reading the narrow
    // getter here compiles perfectly and silently reopens the race.
    final (actions, uiState, context) = await openReadyPreview(
      tester,
      exportSizeReturns: const {'width': 1920, 'height': 1080},
    );

    generateGate = Completer<List<Map<String, Object?>>>();
    final regenerating = actions.postProcessingController.generateCaptions();
    await settle(tester, steps: 3);
    expect(actions.postProcessingController.isGeneratingCaptions, isTrue);

    calls.clear();
    unawaited(actions.exportFromUi(context));
    await settle(tester, steps: 10);

    expect(
      find.text('Export'),
      findsNothing,
      reason: 'the export dialog must not even open while cues are in flight',
    );
    expect(
      calls.where((c) => c.method == 'exportVideo'),
      isEmpty,
      reason: 'and nothing may reach native',
    );

    generateGate!.complete(const [
      {'id': 'c1', 'startMs': 0, 'endMs': 1500, 'text': 'hello there'},
    ]);
    await regenerating;
    await settle(tester, steps: 3);
  });
}
