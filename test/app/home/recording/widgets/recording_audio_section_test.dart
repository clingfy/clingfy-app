import 'package:clingfy/app/home/recording/widgets/recording_audio_section.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_inset_group.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/platform_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

Widget _buildSection({
  required String selectedAudioSourceId,
  Brightness brightness = Brightness.light,
  bool isRecording = false,
  bool loadingAudio = false,
  bool systemAudioEnabled = false,
  bool excludeMicFromSystemAudio = false,
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
              excludeMicFromSystemAudio: excludeMicFromSystemAudio,
              micInputLevelLinear: micInputLevelLinear,
              micInputLevelDbfs: micInputLevelDbfs,
              micInputTooLow: micInputTooLow,
              onAudioSourceChanged: (_) {},
              onRefreshAudio: () {},
              onSystemAudioEnabledChanged: (_) {},
              onExcludeMicFromSystemAudioChanged: (_) {},
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
      micInputLevelLinear: micInputLevelLinear,
      micInputLevelDbfs: micInputLevelDbfs,
      micInputTooLow: micInputTooLow,
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

AppLocalizations _l10n(WidgetTester tester) {
  return AppLocalizations.of(
    tester.element(find.byType(RecordingAudioSection)),
  )!;
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
  testWidgets('audio controls render inside a settings group', (tester) async {
    await _pumpSection(tester, selectedAudioSourceId: '__none__');

    expect(find.byType(AppSettingsGroup), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);
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
}
