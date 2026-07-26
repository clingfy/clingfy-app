import 'package:clingfy/app/home/recording/widgets/recording_audio_section.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_inset_group.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:clingfy/ui/platform/platform_kind.dart';

Widget _buildSection({
  required String selectedAudioSourceId,
  Brightness brightness = Brightness.light,
  bool isRecording = false,
  bool loadingAudio = false,
  bool systemAudioEnabled = false,
  bool systemAudioBleedRisk = false,
  bool excludeMicFromSystemAudio = false,
  bool micEchoCancellationEnabled = false,
  ValueChanged<bool>? onMicEchoCancellationEnabledChanged,
  double micInputLevelLinear = 0.0,
  double micInputLevelDbfs = -160.0,
  bool micInputTooLow = false,
}) {
  return MaterialApp(
    theme: ThemeData(brightness: brightness, useMaterial3: true),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MacosTheme(
      data: brightness == Brightness.dark
          ? MacosThemeData.dark()
          : MacosThemeData.light(),
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: 720,
            child: RecordingAudioSection(
              isRecording: isRecording,
              audioSources: const [
                AudioSource(id: 'mic-1', name: 'Built-in Microphone'),
              ],
              selectedAudioSourceId: selectedAudioSourceId,
              loadingAudio: loadingAudio,
              systemAudioEnabled: systemAudioEnabled,
              systemAudioBleedRisk: systemAudioBleedRisk,
              excludeMicFromSystemAudio: excludeMicFromSystemAudio,
              micEchoCancellationEnabled: micEchoCancellationEnabled,
              micInputLevelLinear: micInputLevelLinear,
              micInputLevelDbfs: micInputLevelDbfs,
              micInputTooLow: micInputTooLow,
              onAudioSourceChanged: (_) {},
              onRefreshAudio: () {},
              onSystemAudioEnabledChanged: (_) {},
              onExcludeMicFromSystemAudioChanged: (_) {},
              onMicEchoCancellationEnabledChanged:
                  onMicEchoCancellationEnabledChanged ?? (_) {},
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpSection(
  WidgetTester tester, {
  required String selectedAudioSourceId,
  Brightness brightness = Brightness.light,
  bool isRecording = false,
  bool loadingAudio = false,
  bool systemAudioEnabled = false,
  bool excludeMicFromSystemAudio = false,
  bool micEchoCancellationEnabled = false,
  ValueChanged<bool>? onMicEchoCancellationEnabledChanged,
  double micInputLevelLinear = 0.0,
  double micInputLevelDbfs = -160.0,
  bool micInputTooLow = false,
}) async {
  await tester.pumpWidget(
    _buildSection(
      selectedAudioSourceId: selectedAudioSourceId,
      brightness: brightness,
      isRecording: isRecording,
      loadingAudio: loadingAudio,
      systemAudioEnabled: systemAudioEnabled,
      excludeMicFromSystemAudio: excludeMicFromSystemAudio,
      micEchoCancellationEnabled: micEchoCancellationEnabled,
      onMicEchoCancellationEnabledChanged: onMicEchoCancellationEnabledChanged,
      micInputLevelLinear: micInputLevelLinear,
      micInputLevelDbfs: micInputLevelDbfs,
      micInputTooLow: micInputTooLow,
    ),
  );
  await tester.pump();
  if (!loadingAudio) {
    await tester.pumpAndSettle();
  }
}

AppLocalizations _l10n(WidgetTester tester) {
  return AppLocalizations.of(
    tester.element(find.byType(RecordingAudioSection)),
  )!;
}

Finder _macosTooltip(String message) {
  return find.byWidgetPredicate(
    (widget) => widget is MacosTooltip && widget.message == message,
  );
}

ThemeData _theme(WidgetTester tester) {
  return Theme.of(tester.element(find.byType(RecordingAudioSection)));
}

double _expectedVisualLevel(double dbfs) {
  if (dbfs.isFinite) {
    final clampedDbfs = dbfs.clamp(-60.0, 0.0).toDouble();
    final normalized = ((clampedDbfs + 60.0) / 60.0).clamp(0.0, 1.0).toDouble();
    if (normalized <= 0.0) {
      return 0.0;
    }
    return Curves.easeOutCubic.transform(normalized);
  }

  return 0.0;
}

Color _expectedBaseGlyphColor(
  ThemeData theme, {
  required bool hasSelectedMicrophone,
}) {
  final isDark = theme.brightness == Brightness.dark;
  return theme.colorScheme.onSurfaceVariant.withValues(
    alpha: hasSelectedMicrophone
        ? (isDark ? 0.26 : 0.18)
        : (isDark ? 0.22 : 0.14),
  );
}

Color _expectedActiveFillColor(Brightness brightness) {
  return brightness == Brightness.dark
      ? const Color(0xFF30D158)
      : const Color(0xFF34C759);
}

dynamic _meterFill(WidgetTester tester) {
  return tester.widget(find.byKey(const Key('mic_input_meter_fill')));
}

double _meterFillLevel(WidgetTester tester) {
  return _meterFill(tester).level as double;
}

Color _meterFillColor(WidgetTester tester) {
  return _meterFill(tester).color as Color;
}

double _meterFillIconSize(WidgetTester tester) {
  return _meterFill(tester).iconSize as double;
}

Icon _meterIcon(WidgetTester tester) {
  return tester.widget<Icon>(find.byKey(const Key('mic_input_meter_icon')));
}

Tooltip _meterTooltip(WidgetTester tester) {
  return tester.widget<Tooltip>(
    find.byKey(const Key('mic_input_meter_tooltip')),
  );
}

double _audioDropdownFieldWidth(WidgetTester tester) {
  final field = find.descendant(
    of: find.byWidgetPredicate((widget) => widget is PlatformDropdown<String>),
    matching: find.byKey(PlatformDropdown.fieldKey),
  );

  return tester.getSize(field).width;
}

double _audioDropdownMenuRowWidth(WidgetTester tester, int index) {
  return tester
      .getSize(find.byKey(ValueKey('platform_dropdown_menu_row_$index')))
      .width;
}

void main() {
  // Phase 10.3 forked this surface's widget tree by platform (no-op
  // controls hidden / zoom editing disabled on Windows). These legacy
  // assertions pin the macOS branch regardless of the host OS. Windows
  // hide-coverage: windows_control_hides_test.dart covers the standalone
  // sections; sidebar-level hides are pinned by the isWindows() gates.
  setUp(() {
    debugPlatformKindOverride = PlatformKind.macos;
  });
  tearDown(() {
    debugPlatformKindOverride = null;
  });

  testWidgets('audio controls render inside a headerless settings group', (
    tester,
  ) async {
    await _pumpSection(tester, selectedAudioSourceId: '__none__');

    final l10n = _l10n(tester);

    expect(find.byType(AppSettingsGroup), findsOneWidget);
    expect(find.text(l10n.audio), findsNothing);
    expect(find.text(l10n.inputDevice), findsOneWidget);
  });

  testWidgets('refresh button renders beside input device', (tester) async {
    await _pumpSection(tester, selectedAudioSourceId: 'mic-1');

    final l10n = _l10n(tester);
    final labelRect = tester.getRect(find.text(l10n.inputDevice));
    final refreshRect = tester.getRect(_macosTooltip(l10n.refreshAudio));

    expect(_macosTooltip(l10n.refreshAudio), findsOneWidget);
    expect((refreshRect.center.dy - labelRect.center.dy).abs(), lessThan(4));
    expect(refreshRect.left, greaterThan(labelRect.right));
  });

  testWidgets('loading audio hides inline refresh button with spinner state', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      loadingAudio: true,
    );

    final l10n = _l10n(tester);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(l10n.inputDevice), findsNothing);
    expect(_macosTooltip(l10n.refreshAudio), findsNothing);
  });

  testWidgets('system audio details are nested inside an inset group', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      systemAudioEnabled: true,
    );

    final l10n = _l10n(tester);

    expect(find.text(l10n.recordingExcludeMicFromSystemAudio), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text(l10n.recordingExcludeMicFromSystemAudio),
        matching: find.byType(AppInsetGroup),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'echo cancellation toggle renders off by default with help text',
    (tester) async {
      await _pumpSection(
        tester,
        selectedAudioSourceId: 'mic-1',
        systemAudioEnabled: true,
      );

      final l10n = _l10n(tester);

      expect(find.text(l10n.recordingMicEchoCancellation), findsOneWidget);
      expect(find.text(l10n.recordingMicEchoCancellationHelp), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text(l10n.recordingMicEchoCancellation),
          matching: find.byType(AppInsetGroup),
        ),
        findsOneWidget,
      );

      final row = tester.widget<AppToggleRow>(
        find.byKey(const Key('recording_mic_echo_cancellation_toggle')),
      );
      expect(row.value, isFalse);
    },
  );

  testWidgets('echo cancellation toggle reports changes and locks while '
      'recording', (tester) async {
    bool? received;
    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      systemAudioEnabled: true,
      onMicEchoCancellationEnabledChanged: (value) => received = value,
    );

    final row = tester.widget<AppToggleRow>(
      find.byKey(const Key('recording_mic_echo_cancellation_toggle')),
    );
    row.onChanged!(true);
    expect(received, isTrue);

    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      systemAudioEnabled: true,
      isRecording: true,
    );
    final lockedRow = tester.widget<AppToggleRow>(
      find.byKey(const Key('recording_mic_echo_cancellation_toggle')),
    );
    expect(lockedRow.onChanged, isNull);
  });

  testWidgets(
    'echo cancellation toggle stays visible regardless of capture config',
    (tester) async {
      // The pref acts at preview/export time on EXISTING projects, so hiding
      // it behind the capture toggles would strand an enabled canceller with
      // no reachable off switch.
      await _pumpSection(tester, selectedAudioSourceId: 'mic-1');
      expect(
        find.byKey(const Key('recording_mic_echo_cancellation_toggle')),
        findsOneWidget,
      );

      await _pumpSection(
        tester,
        selectedAudioSourceId: '__none__',
        systemAudioEnabled: true,
      );
      expect(
        find.byKey(const Key('recording_mic_echo_cancellation_toggle')),
        findsOneWidget,
      );
    },
  );

  testWidgets('replaces the old monitor panel with a compact mic indicator', (
    tester,
  ) async {
    await _pumpSection(tester, selectedAudioSourceId: '__none__');

    final l10n = _l10n(tester);

    expect(find.byKey(const Key('mic_input_monitor_compact')), findsNothing);
    expect(find.byKey(const Key('mic_input_monitor_expanded')), findsNothing);
    expect(find.byKey(const Key('mic_input_meter')), findsOneWidget);
    expect(find.text(l10n.inputDevice), findsOneWidget);
    expect(find.text(l10n.recordingSystemAudio), findsOneWidget);
  });

  testWidgets('no mic selected keeps the meter inactive and gray', (
    tester,
  ) async {
    await _pumpSection(tester, selectedAudioSourceId: '__none__');

    final theme = _theme(tester);
    final l10n = _l10n(tester);

    expect(_meterIcon(tester).icon, Icons.mic_rounded);
    expect(_meterIcon(tester).size, 18.0);
    expect(
      _meterIcon(tester).color,
      _expectedBaseGlyphColor(theme, hasSelectedMicrophone: false),
    );
    expect(find.byKey(const Key('mic_input_meter_fill')), findsNothing);
    expect(
      _meterTooltip(tester).message,
      l10n.micInputIndicatorDisabledTooltip,
    );
    expect(_meterTooltip(tester).excludeFromSemantics, isTrue);
  });

  testWidgets('selected mic shows an active meter and live level tooltip', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      micInputLevelLinear: 0.42,
      micInputLevelDbfs: -23.1,
    );

    final theme = _theme(tester);
    final l10n = _l10n(tester);

    expect(_meterIcon(tester).icon, Icons.mic_rounded);
    expect(_meterIcon(tester).size, 18.0);
    expect(
      _meterIcon(tester).color,
      _expectedBaseGlyphColor(theme, hasSelectedMicrophone: true),
    );
    expect(find.byKey(const Key('mic_input_meter_fill')), findsOneWidget);
    expect(
      _meterFillLevel(tester),
      closeTo(_expectedVisualLevel(-23.1), 0.001),
    );
    expect(_meterFillColor(tester), _expectedActiveFillColor(theme.brightness));
    expect(_meterFillIconSize(tester), 18.0);
    expect(
      _meterTooltip(tester).message,
      l10n.micInputIndicatorLiveTooltip('-23.1'),
    );
  });

  testWidgets('meter fill uses eased dBFS normalization', (tester) async {
    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      micInputLevelLinear: 0.08,
      micInputLevelDbfs: -42.0,
    );

    expect(
      _meterFillLevel(tester),
      closeTo(_expectedVisualLevel(-42.0), 0.001),
    );
    expect(_meterFillLevel(tester), greaterThan(0.30));
  });

  testWidgets(
    'audio source popup matches the rendered full-width dropdown field',
    (tester) async {
      await _pumpSection(tester, selectedAudioSourceId: 'mic-1');

      final fieldWidth = _audioDropdownFieldWidth(tester);

      await tester.tap(find.byKey(PlatformDropdown.fieldKey));
      await tester.pumpAndSettle();

      expect(
        _audioDropdownMenuRowWidth(tester, 0),
        moreOrLessEquals(fieldWidth),
      );
      expect(
        _audioDropdownMenuRowWidth(tester, 1),
        moreOrLessEquals(fieldWidth),
      );
    },
  );

  testWidgets('meter fill increases with stronger dBFS levels', (tester) async {
    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      micInputLevelLinear: 0.10,
      micInputLevelDbfs: -40.0,
    );
    final quietLevel = _meterFillLevel(tester);

    await tester.pumpWidget(
      _buildSection(
        selectedAudioSourceId: 'mic-1',
        micInputLevelLinear: 0.46,
        micInputLevelDbfs: -18.0,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    final mediumLevel = _meterFillLevel(tester);

    await tester.pumpWidget(
      _buildSection(
        selectedAudioSourceId: 'mic-1',
        micInputLevelLinear: 0.84,
        micInputLevelDbfs: -6.0,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    final loudLevel = _meterFillLevel(tester);

    expect(quietLevel, closeTo(_expectedVisualLevel(-40.0), 0.001));
    expect(mediumLevel, closeTo(_expectedVisualLevel(-18.0), 0.001));
    expect(loudLevel, closeTo(_expectedVisualLevel(-6.0), 0.001));
    expect(quietLevel, lessThan(mediumLevel));
    expect(mediumLevel, lessThan(loudLevel));
  });

  testWidgets('meter fill animates to the latest audio level', (tester) async {
    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      micInputLevelLinear: 0.18,
      micInputLevelDbfs: -30.0,
    );

    expect(
      _meterFillLevel(tester),
      closeTo(_expectedVisualLevel(-30.0), 0.001),
    );

    await tester.pumpWidget(
      _buildSection(
        selectedAudioSourceId: 'mic-1',
        micInputLevelLinear: 0.76,
        micInputLevelDbfs: -8.4,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(_meterFillLevel(tester), closeTo(_expectedVisualLevel(-8.4), 0.001));
  });

  testWidgets('meter fill decreases when audio input decreases', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      micInputLevelLinear: 0.72,
      micInputLevelDbfs: -9.0,
    );

    expect(_meterFillLevel(tester), closeTo(_expectedVisualLevel(-9.0), 0.001));

    await tester.pumpWidget(
      _buildSection(
        selectedAudioSourceId: 'mic-1',
        micInputLevelLinear: 0.16,
        micInputLevelDbfs: -33.0,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      _meterFillLevel(tester),
      closeTo(_expectedVisualLevel(-33.0), 0.001),
    );
  });

  testWidgets('meter fill fades to empty when audio input reaches silence', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      micInputLevelLinear: 0.36,
      micInputLevelDbfs: -20.0,
    );

    expect(
      _meterFillLevel(tester),
      closeTo(_expectedVisualLevel(-20.0), 0.001),
    );

    await tester.pumpWidget(
      _buildSection(
        selectedAudioSourceId: 'mic-1',
        micInputLevelLinear: 0.0,
        micInputLevelDbfs: -160.0,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mic_input_meter_fill')), findsNothing);
  });

  testWidgets('meter still updates while recording is active', (tester) async {
    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      isRecording: true,
      micInputLevelLinear: 0.14,
      micInputLevelDbfs: -35.0,
    );

    expect(
      _meterFillLevel(tester),
      closeTo(_expectedVisualLevel(-35.0), 0.001),
    );

    await tester.pumpWidget(
      _buildSection(
        selectedAudioSourceId: 'mic-1',
        isRecording: true,
        micInputLevelLinear: 0.52,
        micInputLevelDbfs: -18.0,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      _meterFillLevel(tester),
      closeTo(_expectedVisualLevel(-18.0), 0.001),
    );
  });

  testWidgets(
    'low input keeps the active fill green and changes tooltip only',
    (tester) async {
      await _pumpSection(
        tester,
        selectedAudioSourceId: 'mic-1',
        micInputLevelLinear: 0.08,
        micInputLevelDbfs: -45.2,
        micInputTooLow: true,
      );

      final theme = _theme(tester);
      final l10n = _l10n(tester);

      expect(_meterTooltip(tester).message, l10n.micInputIndicatorLowTooltip);
      expect(
        _meterFillLevel(tester),
        closeTo(_expectedVisualLevel(-45.2), 0.001),
      );
      expect(
        _meterFillColor(tester),
        _expectedActiveFillColor(theme.brightness),
      );
    },
  );

  testWidgets('active fill uses the dark-theme green accent', (tester) async {
    await _pumpSection(
      tester,
      brightness: Brightness.dark,
      selectedAudioSourceId: 'mic-1',
      micInputLevelLinear: 0.42,
      micInputLevelDbfs: -23.1,
    );

    final theme = _theme(tester);

    expect(_meterIcon(tester).size, 18.0);
    expect(
      _meterIcon(tester).color,
      _expectedBaseGlyphColor(theme, hasSelectedMicrophone: true),
    );
    expect(_meterFillColor(tester), const Color(0xFF30D158));
    expect(_meterFillIconSize(tester), 18.0);
  });

  testWidgets('existing system audio rules still render correctly', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      selectedAudioSourceId: '__none__',
      systemAudioEnabled: true,
    );

    final l10n = _l10n(tester);

    expect(find.text(l10n.inputDevice), findsOneWidget);
    expect(find.text(l10n.recordingSystemAudio), findsOneWidget);
    expect(find.text(l10n.recordingExcludeMicFromSystemAudio), findsNothing);

    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      systemAudioEnabled: true,
    );

    expect(find.text(l10n.recordingExcludeMicFromSystemAudio), findsOneWidget);
  });

  group('mic input too low warning', () {
    const warningKey = Key('mic_input_too_low_warning');

    testWidgets('shows prominently, not only as a meter tooltip', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildSection(selectedAudioSourceId: 'mic-1', micInputTooLow: true),
      );
      await tester.pump();

      expect(find.byKey(warningKey), findsOneWidget);
      final notice = tester.widget<AppInlineNotice>(find.byKey(warningKey));
      expect(notice.variant, AppInlineNoticeVariant.warning);
      // The copy has to name the fix, not just the symptom — an unusable take
      // is recoverable only before it is recorded.
      expect(notice.message, contains('Input'));
    });

    testWidgets('absent when the level is healthy', (tester) async {
      await tester.pumpWidget(_buildSection(selectedAudioSourceId: 'mic-1'));
      await tester.pump();

      expect(find.byKey(warningKey), findsNothing);
    });

    testWidgets('absent with no microphone selected', (tester) async {
      // A too-low reading with no mic selected is meaningless, and
      // "No microphone" is the first-run default.
      await tester.pumpWidget(
        _buildSection(selectedAudioSourceId: '__none__', micInputTooLow: true),
      );
      await tester.pump();

      expect(find.byKey(warningKey), findsNothing);
    });

    testWidgets('still shown while recording, so a bad take can be cut short', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildSection(
          selectedAudioSourceId: 'mic-1',
          micInputTooLow: true,
          isRecording: true,
        ),
      );
      await tester.pump();

      expect(find.byKey(warningKey), findsOneWidget);
    });

    testWidgets('coexists with the bleed warning', (tester) async {
      // Both conditions are independent and can hold at once; neither may
      // suppress the other.
      await tester.pumpWidget(
        _buildSection(
          selectedAudioSourceId: 'mic-1',
          systemAudioEnabled: true,
          systemAudioBleedRisk: true,
          micInputTooLow: true,
        ),
      );
      await tester.pump();

      expect(find.byKey(warningKey), findsOneWidget);
      expect(
        find.byKey(const Key('system_audio_bleed_warning')),
        findsOneWidget,
      );
    });
  });

  group('speaker bleed warning', () {
    const warningKey = Key('system_audio_bleed_warning');

    testWidgets('shows under the system-audio toggle when at risk', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildSection(
          selectedAudioSourceId: 'mic-1',
          systemAudioEnabled: true,
          systemAudioBleedRisk: true,
        ),
      );
      await tester.pump();

      expect(find.byKey(warningKey), findsOneWidget);
      final notice = tester.widget<AppInlineNotice>(find.byKey(warningKey));
      expect(notice.variant, AppInlineNoticeVariant.warning);
      expect(notice.message, contains('headphones'));
    });

    testWidgets('absent when the output route is safe', (tester) async {
      await tester.pumpWidget(
        _buildSection(selectedAudioSourceId: 'mic-1', systemAudioEnabled: true),
      );
      await tester.pump();

      expect(find.byKey(warningKey), findsNothing);
    });

    testWidgets('absent when the caller reports no risk', (tester) async {
      // systemAudioBleedRisk is computed upstream from (system audio on AND the
      // route bleeds); the section just renders it. Prove the false branch.
      await tester.pumpWidget(
        _buildSection(selectedAudioSourceId: 'mic-1', systemAudioEnabled: true),
      );
      await tester.pump();

      expect(find.byKey(warningKey), findsNothing);
    });

    testWidgets('absent with no microphone selected, even at risk', (
      tester,
    ) async {
      // With no mic there is nothing for the system audio to bleed INTO, and
      // "No microphone" is the first-run default — warning there would be a
      // false alarm on a brand-new install.
      await tester.pumpWidget(
        _buildSection(
          selectedAudioSourceId: '__none__',
          systemAudioEnabled: true,
          systemAudioBleedRisk: true,
        ),
      );
      await tester.pump();

      expect(find.byKey(warningKey), findsNothing);
    });
  });
}
