import 'dart:async';

import 'package:clingfy/app/home/recording/recording_controller.dart';
import 'package:clingfy/app/settings/sections/storage_settings_section.dart';
import 'package:clingfy/app/settings/settings_controller.dart';
import 'package:clingfy/core/bridges/native_bridge.dart';
import 'package:clingfy/core/bridges/native_method_channel.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  Future<void> scrollToClearButton(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(const Key('storage_clear_cached_recordings_button')),
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
      await tester.pumpAndSettle();

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
        systemRect.height,
        moreOrLessEquals(clingfyRect.height, epsilon: 1),
      );
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

    expect(find.text('Storage action failed.'), findsOneWidget);
    expect(find.text('Refresh'), findsWidgets);
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
    await scrollToClearButton(tester);
    expect(find.text('Clear cached recordings'), findsOneWidget);
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
    expect(calls, 1);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(calls, greaterThanOrEqualTo(2));
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
    await tester.pumpAndSettle();

    expect(clearCalls, 1);
    expect(getSnapshotCalls, 2);
    await tester.fling(find.byType(ListView), const Offset(0, 1000), 2000);
    await tester.pumpAndSettle();
    expect(find.text('Removed 2 cached recordings.'), findsOneWidget);
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
}
