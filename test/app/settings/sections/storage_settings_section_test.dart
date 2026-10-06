import 'dart:async';

import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/settings/sections/storage_settings_section.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';
import 'package:clingfy/ui/platform/widgets/app_button.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Pin the macOS branch (Phase 10.4): the Windows-only workflow watchdogs
  // arm a real Timer when a test parks the controller in a non-idle phase,
  // and flutter_test's pending-timer invariant fires BEFORE addTearDown
  // disposal can cancel it. This file tests platform-generic storage
  // gating, so the 10.3 pin pattern applies.
  setUp(() {
    debugPlatformKindOverride = PlatformKind.macos;
  });
  tearDown(() {
    debugPlatformKindOverride = null;
  });

  const channel = MethodChannel(NativeChannel.screenRecorder);

  Map<String, dynamic> storageSnapshotPayload({
    int systemAvailableBytes = 200 * 1024 * 1024 * 1024,
    int recordingsBytes = 4 * 1024 * 1024,
    int tempBytes = 2 * 1024 * 1024,
    int logsBytes = 512 * 1024,
  }) {
    return <String, dynamic>{
      'systemTotalBytes': 500 * 1024 * 1024 * 1024,
      'systemAvailableBytes': systemAvailableBytes,
      'recordingsBytes': recordingsBytes,
      'tempBytes': tempBytes,
      'logsBytes': logsBytes,
      'recordingsPath': '/tmp/recordings',
      'tempPath': '/tmp/temp',
      'logsPath': '/tmp/logs',
      'warningThresholdBytes': 20 * 1024 * 1024 * 1024,
      'criticalThresholdBytes': 10 * 1024 * 1024 * 1024,
    };
  }

  Widget buildTestApp(
    SettingsController settings, {
    bool showDeveloperTools = true,
    Duration autoRefreshInterval = const Duration(seconds: 30),
    RecordingController? recordingController,
    double? sectionWidth,
  }) {
    Widget section = StorageSettingsSection(
      controller: settings,
      showDeveloperTools: showDeveloperTools,
      autoRefreshInterval: autoRefreshInterval,
    );
    if (sectionWidth != null) {
      section = Align(
        alignment: Alignment.topCenter,
        child: SizedBox(width: sectionWidth, child: section),
      );
    }

    return MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MacosTheme(
        data: buildMacosTheme(Theme.of(context).brightness),
        child: child!,
      ),
      home: recordingController != null
          ? ChangeNotifierProvider<RecordingController>.value(
              value: recordingController,
              child: Scaffold(body: section),
            )
          : ChangeNotifierProvider<RecordingController>(
              create: (_) => RecordingController(
                nativeBridge: NativeBridge.instance,
                settings: settings,
              ),
              child: Scaffold(body: section),
            ),
    );
  }

  Map<String, dynamic> captionModelPayload({
    bool installed = true,
    int modelBytes = 629485189,
    int compiledCacheBytes = 271581184,
    bool busy = false,
    List<Map<String, dynamic>>? variants,
  }) => <String, dynamic>{
    'installed': installed,
    'modelBytes': modelBytes,
    'compiledCacheBytes': compiledCacheBytes,
    'modelPath': '/tmp/Models',
    'variant': 'openai_whisper-large-v3-v20240930_626MB',
    'busy': busy,
    'loaded': false,
    if (variants != null) 'variants': variants,
  };

  Future<void> pumpStorageSection(
    WidgetTester tester,
    SettingsController settings, {
    bool showDeveloperTools = true,
    Duration autoRefreshInterval = const Duration(seconds: 30),
    RecordingController? recordingController,
    double? sectionWidth,
  }) async {
    await tester.pumpWidget(
      buildTestApp(
        settings,
        showDeveloperTools: showDeveloperTools,
        autoRefreshInterval: autoRefreshInterval,
        recordingController: recordingController,
        sectionWidth: sectionWidth,
      ),
    );
  }

  Future<void> scrollToCaptionModelCard(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(const Key('storage_caption_model_card')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> scrollToClearButton(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(const Key('storage_clear_cached_recordings_button')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  Future<void> scrollToOpenStorageSettingsButton(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(const Key('storage_open_system_settings_button')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('shows loading while snapshot is in flight', (tester) async {
    final completer = Completer<Map<String, dynamic>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return completer.future;
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await tester.pumpWidget(buildTestApp(settings));
    await tester.pump();

    expect(find.text('Loading…'), findsOneWidget);

    completer.complete(<String, dynamic>{...storageSnapshotPayload()});
    await tester.pumpAndSettle();

    expect(find.text('Healthy'), findsWidgets);
  });

  testWidgets('renders warning status when free space is low', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return <String, dynamic>{
              ...storageSnapshotPayload(
                systemAvailableBytes: 15 * 1024 * 1024 * 1024,
              ),
            };
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    expect(find.text('Warning'), findsWidgets);
    expect(
      find.text('Free space is getting low. Long recordings may fail.'),
      findsOneWidget,
    );
  });

  testWidgets('renders storage charts above the related stats', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return <String, dynamic>{...storageSnapshotPayload()};
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('storage_system_chart')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('storage_system_chart')),
        matching: find.text('200 GB'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('storage_system_chart')),
        matching: find.text('Free'),
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('storage_system_chart'))).dy,
      lessThan(tester.getTopLeft(find.text('Status')).dy),
    );

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('storage_clingfy_chart')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('storage_clingfy_chart')),
        matching: find.text('6.5 MB'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('storage_clingfy_chart')),
        matching: find.text('Total Clingfy usage'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'renders system and clingfy storage cards side by side at wide widths',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 1200);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getStorageSnapshot') {
              return <String, dynamic>{...storageSnapshotPayload()};
            }
            return null;
          });

      final settings = SettingsController(nativeBridge: NativeBridge.instance);
      await pumpStorageSection(
        tester,
        settings,
        showDeveloperTools: false,
        sectionWidth: 980,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('storage_detail_cards_row')), findsOneWidget);
      expect(
        find.byKey(const Key('storage_detail_cards_column')),
        findsNothing,
      );

      final overviewRect = tester.getRect(
        find.byKey(const Key('storage_overview_card')),
      );
      final systemRect = tester.getRect(
        find.byKey(const Key('storage_system_card')),
      );
      final clingfyRect = tester.getRect(
        find.byKey(const Key('storage_clingfy_card')),
      );

      expect(systemRect.top, greaterThan(overviewRect.bottom));
      expect(systemRect.top, moreOrLessEquals(clingfyRect.top, epsilon: 0.1));
      expect(clingfyRect.left, greaterThan(systemRect.right));
      expect(
        find.descendant(
          of: find.byKey(const Key('storage_clingfy_card')),
          matching: find.byKey(
            const Key('storage_clear_cached_recordings_button'),
          ),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'renders system and clingfy storage cards stacked at narrow widths',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getStorageSnapshot') {
              return <String, dynamic>{...storageSnapshotPayload()};
            }
            return null;
          });

      final settings = SettingsController(nativeBridge: NativeBridge.instance);
      await pumpStorageSection(
        tester,
        settings,
        showDeveloperTools: false,
        sectionWidth: 760,
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('storage_detail_cards_column')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('storage_detail_cards_row')), findsNothing);

      final overviewRect = tester.getRect(
        find.byKey(const Key('storage_overview_card')),
      );
      final systemRect = tester.getRect(
        find.byKey(const Key('storage_system_card')),
      );
      final clingfyRect = tester.getRect(
        find.byKey(const Key('storage_clingfy_card')),
      );
      await scrollToClearButton(tester);
      final clingfyRectAfterScroll = tester.getRect(
        find.byKey(const Key('storage_clingfy_card')),
      );
      final clearButtonRect = tester.getRect(
        find.byKey(const Key('storage_clear_cached_recordings_button')),
      );

      expect(systemRect.top, greaterThan(overviewRect.bottom));
      expect(clingfyRect.top, greaterThan(systemRect.bottom));
      expect(clingfyRect.left, moreOrLessEquals(systemRect.left, epsilon: 0.1));
      expect(clearButtonRect.top, greaterThan(clingfyRectAfterScroll.bottom));
      expect(
        find.descendant(
          of: find.byKey(const Key('storage_clingfy_card')),
          matching: find.byKey(
            const Key('storage_clear_cached_recordings_button'),
          ),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('renders critical status when free space is below threshold', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return <String, dynamic>{
              ...storageSnapshotPayload(
                systemAvailableBytes: 5 * 1024 * 1024 * 1024,
              ),
            };
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    expect(find.text('Critical'), findsWidgets);
    expect(
      find.text('Recording is blocked until more disk space is available.'),
      findsOneWidget,
    );
  });

  testWidgets('renders error state when storage snapshot cannot be loaded', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'BROKEN');
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();

    expect(find.text('Storage action failed.'), findsOneWidget);
    expect(find.text('Refresh'), findsWidgets);
    await scrollToOpenStorageSettingsButton(tester);
    expect(find.text('Open Storage Settings'), findsOneWidget);
  });

  testWidgets('hides actions and paths in production mode', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return <String, dynamic>{...storageSnapshotPayload()};
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings, showDeveloperTools: false);
    await tester.pumpAndSettle();

    expect(find.text('Actions'), findsNothing);
    expect(find.text('Paths'), findsNothing);
    expect(find.text('Open recordings folder'), findsNothing);
    expect(find.text('Open temp folder'), findsNothing);
    await scrollToOpenStorageSettingsButton(tester);
    expect(find.text('Open Storage Settings'), findsOneWidget);
    await scrollToClearButton(tester);
    expect(find.text('Clear cached recordings'), findsOneWidget);
  });

  testWidgets('open storage settings delegates to native system settings', (
    tester,
  ) async {
    final calls = <MethodCall>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getStorageSnapshot') {
            return <String, dynamic>{...storageSnapshotPayload()};
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings, showDeveloperTools: false);
    await tester.pumpAndSettle();

    await scrollToOpenStorageSettingsButton(tester);
    await tester.tap(
      find.byKey(const Key('storage_open_system_settings_button')),
    );
    await tester.pumpAndSettle();

    final openCalls = calls
        .where((call) => call.method == 'openSystemSettings')
        .toList();
    expect(openCalls, hasLength(1));
    expect(
      Map<String, dynamic>.from(
        openCalls.single.arguments! as Map<dynamic, dynamic>,
      ),
      {'pane': 'storage'},
    );
  });

  testWidgets('open storage settings surfaces inline action errors', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'getStorageSnapshot':
              return <String, dynamic>{...storageSnapshotPayload()};
            case 'openSystemSettings':
              throw PlatformException(
                code: 'OPEN_FAILED',
                message: 'Unable to open system storage settings.',
              );
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings, showDeveloperTools: false);
    await tester.pumpAndSettle();

    await scrollToOpenStorageSettingsButton(tester);
    await tester.tap(
      find.byKey(const Key('storage_open_system_settings_button')),
    );
    await tester.pumpAndSettle();
    await tester.fling(find.byType(ListView), const Offset(0, 1000), 2000);
    await tester.pumpAndSettle();

    expect(
      find.text('Unable to open system storage settings.'),
      findsOneWidget,
    );
  });

  testWidgets('auto refreshes while the section stays visible', (tester) async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            calls += 1;
            return <String, dynamic>{...storageSnapshotPayload()};
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(
      tester,
      settings,
      autoRefreshInterval: const Duration(seconds: 1),
    );

    await tester.pump();
    await tester.pumpAndSettle();
    final initialCalls = calls;
    expect(initialCalls, greaterThanOrEqualTo(1));

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(calls, greaterThan(initialCalls));
  });

  testWidgets('clear cached recordings is disabled when no recordings exist', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return <String, dynamic>{
              ...storageSnapshotPayload(recordingsBytes: 0),
            };
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings, showDeveloperTools: false);
    await tester.pumpAndSettle();
    await scrollToClearButton(tester);

    final button = tester.widget<OutlinedButton>(
      find.descendant(
        of: find.byKey(const Key('storage_clear_cached_recordings_button')),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets(
    'clear cached recordings is disabled while workflow is not idle',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getStorageSnapshot') {
              return <String, dynamic>{...storageSnapshotPayload()};
            }
            return null;
          });

      final settings = SettingsController(nativeBridge: NativeBridge.instance);
      final recordingController = RecordingController(
        nativeBridge: NativeBridge.instance,
        settings: settings,
      )..beginRecordingStartIntent();
      addTearDown(recordingController.dispose);

      await pumpStorageSection(
        tester,
        settings,
        showDeveloperTools: false,
        recordingController: recordingController,
      );
      await tester.pumpAndSettle();
      await scrollToClearButton(tester);

      final button = tester.widget<OutlinedButton>(
        find.descendant(
          of: find.byKey(const Key('storage_clear_cached_recordings_button')),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets('confirming clear cached recordings deletes and refreshes', (
    tester,
  ) async {
    var getSnapshotCalls = 0;
    var clearCalls = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'getStorageSnapshot':
              getSnapshotCalls += 1;
              return <String, dynamic>{
                ...storageSnapshotPayload(
                  recordingsBytes: getSnapshotCalls == 1 ? 4 * 1024 * 1024 : 0,
                ),
              };
            case 'clearCachedRecordings':
              clearCalls += 1;
              return <String, dynamic>{'deletedCount': 2};
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings, showDeveloperTools: false);
    await tester.pumpAndSettle();
    await scrollToClearButton(tester);

    await tester.tap(
      find.byKey(const Key('storage_clear_cached_recordings_button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Clear cached recordings?'), findsOneWidget);
    await tester.tap(find.text('Clear recordings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(clearCalls, 1);
    expect(getSnapshotCalls, 2);
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pump();
    expect(find.text('Removed 2 cached recordings.'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Removed 2 cached recordings.'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Removed 2 cached recordings.'), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('canceling clear cached recordings performs no deletion', (
    tester,
  ) async {
    var clearCalls = 0;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return <String, dynamic>{...storageSnapshotPayload()};
          }
          if (call.method == 'clearCachedRecordings') {
            clearCalls += 1;
            return <String, dynamic>{'deletedCount': 1};
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings, showDeveloperTools: false);
    await tester.pumpAndSettle();
    await scrollToClearButton(tester);

    await tester.tap(
      find.byKey(const Key('storage_clear_cached_recordings_button')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(clearCalls, 0);
  });

  // ---- Speech model ------------------------------------------------------
  //
  // The model arrives on first transcription and nothing in the app had ever
  // shown it or offered to remove it: the better part of a gigabyte of weights,
  // invisible to the very page that charts disk usage. (An earlier version of
  // this comment put the compiled cache at a third of that. It is not — see
  // AppPaths.compiledModelCacheDirectoryURLIfPresent; the compiled bundles land
  // in a shared OS cache Clingfy neither counts nor deletes.)

  testWidgets('the speech model card reports both buckets, not just weights', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return storageSnapshotPayload();
          }
          if (call.method == 'getCaptionModelInfo') {
            return captionModelPayload();
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();
    await scrollToCaptionModelCard(tester);

    expect(find.byKey(const Key('storage_caption_model_card')), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Compiled cache'), findsOneWidget);
    expect(
      find.byKey(const Key('storage_delete_caption_model_button')),
      findsOneWidget,
    );
  });

  testWidgets(
    'a model that was never downloaded says so and offers no delete',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getStorageSnapshot') {
              return storageSnapshotPayload();
            }
            if (call.method == 'getCaptionModelInfo') {
              return captionModelPayload(
                installed: false,
                modelBytes: 0,
                compiledCacheBytes: 0,
              );
            }
            return null;
          });

      final settings = SettingsController(nativeBridge: NativeBridge.instance);
      await pumpStorageSection(tester, settings);

      expect(
        find.byKey(const Key('storage_caption_model_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('storage_delete_caption_model_button')),
        findsNothing,
        reason: 'nothing to delete',
      );
    },
  );

  testWidgets('delete is disabled while a transcription is using the model', (
    tester,
  ) async {
    // Advisory only — native re-checks and answers MODEL_IN_USE — but a live
    // button here invites the user to try, and deleting under a loaded model
    // frees nothing while reporting success.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return storageSnapshotPayload();
          }
          if (call.method == 'getCaptionModelInfo') {
            return captionModelPayload(busy: true);
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();
    await scrollToCaptionModelCard(tester);

    final button = tester.widget<AppButton>(
      find.byKey(const Key('storage_delete_caption_model_button')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a native failure to report the model does not break the page', (
    tester,
  ) async {
    // Windows and any older native build answer nothing here. The storage page
    // must still render everything else.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return storageSnapshotPayload();
          }
          if (call.method == 'getCaptionModelInfo') {
            throw PlatformException(code: 'WINDOWS_NOT_IMPLEMENTED');
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();

    expect(find.text('Healthy'), findsWidgets);
    expect(
      find.byKey(const Key('storage_delete_caption_model_button')),
      findsNothing,
    );
  });

  // ---- Deleting the speech model ----------------------------------------
  //
  // The whole delete path was untested: the confirm dialog, the freed-bytes
  // notice, the zero-bytes suppression and the MODEL_IN_USE refusal. That last
  // one matters most — native refuses the delete while Core ML still has the
  // weights mmapped, and the bridge deliberately lets that PlatformException
  // escape (unlike the read, which degrades to notInstalled) so the user is
  // told rather than left pressing a button that does nothing.
  //
  // Three rules for everything below, all three learned by getting them wrong.
  // `pumpAndSettle` must NOT be used after confirming: the success notice
  // cancels itself on a 5s Timer, and settling advances the clock past it, so
  // the assertion sees an empty screen and reads as a broken notice. A single
  // short pump is not enough either — the dialog's dismiss animation is still
  // running, so its buttons are still in the tree. And the notice has to be
  // scrolled back INTO the tree before it can be found; see [confirmDelete].

  Future<void> openDeleteDialog(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const Key('storage_delete_caption_model_button')),
    );
    await tester.pumpAndSettle();
  }

  /// Confirm, let the dialog finish closing, scroll back to where the notices
  /// live, and stop short of the 5s dismiss timer.
  ///
  /// The scroll back is not cosmetic. Both notices render near the TOP of the
  /// section, above the overview card, while these tests have scrolled all the
  /// way down to the speech-model card — and the section's scroll view is lazy,
  /// so the notice is not merely off screen, it is not in the widget tree at
  /// all. Asserting without coming back up reports "no notice" for a notice
  /// that was set correctly, which is exactly the false negative that cost an
  /// hour here.
  Future<void> confirmDelete(WidgetTester tester) async {
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Drain every timer the assertions left armed, so flutter_test's
  /// pending-timer invariant does not fire on teardown.
  ///
  /// `pumpAndSettle`, not a fixed pump: the notice's own 5s dismiss timer is
  /// the obvious one, but scrolling back up also rebuilds the usage doughnut,
  /// and the Syncfusion chart arms its own animation timer on attach. A
  /// 6-second pump cleared the notice and left the chart's timer pending,
  /// which fails the test AFTER its assertions have already passed.
  Future<void> drainTimers(WidgetTester tester) async {
    await tester.pumpAndSettle();
  }

  /// The size in the dialog comes off `modelBytes`, not out of the string.
  ///
  /// Deliberately NOT the default payload: 629485189 bytes renders as exactly
  /// "600 MB", which is the figure the three locales used to hardcode, so a
  /// test on the default would pass whether or not the plumbing works. The
  /// assertion matches the surrounding sentence rather than the bare size,
  /// because the card's own Model row renders the same number.
  testWidgets(
    'the delete dialog names the real model size, not a fixed 600 MB',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getStorageSnapshot') {
              return storageSnapshotPayload();
            }
            if (call.method == 'getCaptionModelInfo') {
              return captionModelPayload(modelBytes: 123 * 1024 * 1024);
            }
            return null;
          });

      final settings = SettingsController(nativeBridge: NativeBridge.instance);
      await pumpStorageSection(tester, settings);
      await tester.pumpAndSettle();
      await scrollToCaptionModelCard(tester);
      await openDeleteDialog(tester);

      expect(
        find.textContaining('internet connection and about 123 MB'),
        findsOneWidget,
        reason: 'the dialog must quote the size it actually measured',
      );
      expect(
        find.textContaining('and about 600 MB'),
        findsNothing,
        reason: 'the hardcoded figure must be gone from every locale',
      );
    },
  );

  testWidgets('cancelling the dialog deletes nothing', (tester) async {
    var deleteCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return storageSnapshotPayload();
          }
          if (call.method == 'getCaptionModelInfo') {
            return captionModelPayload();
          }
          if (call.method == 'deleteCaptionModel') {
            deleteCalls++;
            return <String, dynamic>{'freedBytes': 1};
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();
    await scrollToCaptionModelCard(tester);
    await openDeleteDialog(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(deleteCalls, 0);
  });

  testWidgets('confirming deletes and reports what was freed', (tester) async {
    var deleteCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return storageSnapshotPayload();
          }
          if (call.method == 'getCaptionModelInfo') {
            return captionModelPayload();
          }
          if (call.method == 'deleteCaptionModel') {
            deleteCalls++;
            return <String, dynamic>{'freedBytes': 123 * 1024 * 1024};
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();
    await scrollToCaptionModelCard(tester);
    await openDeleteDialog(tester);
    await confirmDelete(tester);

    expect(deleteCalls, 1);
    expect(find.textContaining('Freed 123 MB'), findsOneWidget);

    await drainTimers(tester);
  });

  /// Native returns 0 when it removed nothing. Announcing "Freed 0 B" reads as
  /// a successful delete that did nothing, so the notice is suppressed.
  testWidgets('freeing nothing announces nothing', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return storageSnapshotPayload();
          }
          if (call.method == 'getCaptionModelInfo') {
            return captionModelPayload();
          }
          if (call.method == 'deleteCaptionModel') {
            return <String, dynamic>{'freedBytes': 0};
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();
    await scrollToCaptionModelCard(tester);
    await openDeleteDialog(tester);
    await confirmDelete(tester);

    expect(find.textContaining('Freed'), findsNothing);
  });

  /// MODEL_IN_USE is the one error the user must see. Core ML keeps the weights
  /// mmapped while a transcription runs, so native refuses rather than deleting
  /// under a live pipeline — and `busy` on the card can be up to a refresh
  /// stale, so this refusal is reachable from a button that looked enabled.
  testWidgets('a refused delete tells the user why', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return storageSnapshotPayload();
          }
          if (call.method == 'getCaptionModelInfo') {
            return captionModelPayload();
          }
          if (call.method == 'deleteCaptionModel') {
            throw PlatformException(
              code: 'MODEL_IN_USE',
              message: 'The speech model is in use right now.',
            );
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();
    await scrollToCaptionModelCard(tester);
    await openDeleteDialog(tester);
    await confirmDelete(tester);

    expect(
      find.textContaining('is in use right now'),
      findsOneWidget,
      reason: "the native message must reach the user, not a generic failure",
    );
  });

  // ---- More than one model on disk ---------------------------------------
  //
  // Models are variant-scoped natively, so switching downloads the new one
  // BESIDE the old. Before this the card measured the whole tree as one number
  // and named neither model: a user carrying 1.2 GB saw one figure, no names,
  // and one button that removed both. These pin what they see instead.

  testWidgets('two models are listed by name, with the active one marked', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return storageSnapshotPayload();
          }
          if (call.method == 'getCaptionModelInfo') {
            return captionModelPayload(
              modelBytes: 700 * 1024 * 1024,
              compiledCacheBytes: 0,
              variants: [
                {
                  'variant': 'openai_whisper-large-v3-v20240930_626MB',
                  'bytes': 626 * 1024 * 1024,
                  'complete': true,
                },
                {
                  'variant': 'openai_whisper-tiny',
                  'bytes': 75 * 1024 * 1024,
                  'complete': true,
                },
              ],
            );
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();
    await scrollToCaptionModelCard(tester);

    // Each model named, vendor prefix trimmed, active one marked.
    expect(
      find.text('large-v3-v20240930_626MB (in use)'),
      findsOneWidget,
      reason: 'the user must be able to tell which model the engine uses',
    );
    expect(find.text('tiny'), findsOneWidget);
    // And each carries its OWN size, not the shared total. Note the formatter
    // keeps one decimal below 100 and drops it above, so these differ in shape.
    expect(find.text('626 MB'), findsOneWidget);
    expect(find.text('75.0 MB'), findsOneWidget);
    // The anonymous single-model row is gone in this state.
    expect(find.text('Model'), findsNothing);
  });

  testWidgets('an unfinished download is listed and labelled as such', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return storageSnapshotPayload();
          }
          if (call.method == 'getCaptionModelInfo') {
            return captionModelPayload(
              variants: [
                {
                  'variant': 'openai_whisper-large-v3-v20240930_626MB',
                  'bytes': 626 * 1024 * 1024,
                  'complete': true,
                },
                {
                  'variant': 'openai_whisper-medium',
                  'bytes': 120 * 1024 * 1024,
                  'complete': false,
                },
              ],
            );
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();
    await scrollToCaptionModelCard(tester);

    expect(
      find.text('medium (unfinished download)'),
      findsOneWidget,
      reason:
          'bytes that cannot be loaded still occupy disk, so they are shown '
          'rather than hidden',
    );
  });

  /// One model is every user today, and that case must look exactly as it did.
  testWidgets('a single model keeps the anonymous Model row', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return storageSnapshotPayload();
          }
          if (call.method == 'getCaptionModelInfo') {
            return captionModelPayload(
              variants: [
                {
                  'variant': 'openai_whisper-large-v3-v20240930_626MB',
                  'bytes': 626 * 1024 * 1024,
                  'complete': true,
                },
              ],
            );
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();
    await scrollToCaptionModelCard(tester);

    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Compiled cache'), findsOneWidget);
    expect(find.textContaining('(in use)'), findsNothing);
  });

  /// The dialog quotes what a re-download would FETCH, which is one model.
  /// Quoting the root total would promise roughly double.
  testWidgets('the delete dialog quotes the active model, not both', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getStorageSnapshot') {
            return storageSnapshotPayload();
          }
          if (call.method == 'getCaptionModelInfo') {
            return captionModelPayload(
              modelBytes: 701 * 1024 * 1024,
              variants: [
                {
                  'variant': 'openai_whisper-large-v3-v20240930_626MB',
                  'bytes': 626 * 1024 * 1024,
                  'complete': true,
                },
                {
                  'variant': 'openai_whisper-tiny',
                  'bytes': 75 * 1024 * 1024,
                  'complete': true,
                },
              ],
            );
          }
          return null;
        });

    final settings = SettingsController(nativeBridge: NativeBridge.instance);
    await pumpStorageSection(tester, settings);
    await tester.pumpAndSettle();
    await scrollToCaptionModelCard(tester);
    await openDeleteDialog(tester);

    expect(
      find.textContaining('and about 626 MB'),
      findsOneWidget,
      reason: 'one model is refetched, so one model is the figure to quote',
    );
    expect(
      find.textContaining('701 MB'),
      findsNothing,
      reason: 'the root total would overstate the download by both models',
    );
  });
}
