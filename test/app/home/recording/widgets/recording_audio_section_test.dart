import 'dart:math' as math;

import 'package:clingfy/app/home/recording/widgets/recording_audio_section.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

Widget _buildSection({
  required String selectedAudioSourceId,
  bool isRecording = false,
  bool loadingAudio = false,
  bool systemAudioEnabled = false,
  bool excludeMicFromSystemAudio = false,
  double micInputLevelLinear = 0.0,
  double micInputLevelDbfs = -160.0,
  bool micInputTooLow = false,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MacosTheme(
      data: MacosThemeData.light(),
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

double _expectedVisualLevel(double linear) {
  if (linear <= 0) return 0.0;
  return math.pow(linear, 0.5).toDouble().clamp(0.0, 1.0);
}

Align _meterFill(WidgetTester tester) {
  return tester.widget<Align>(find.byKey(const Key('mic_input_meter_fill')));
}

Icon _meterOutline(WidgetTester tester) {
  return tester.widget<Icon>(find.byKey(const Key('mic_input_meter_outline')));
}

Tooltip _meterTooltip(WidgetTester tester) {
  return tester.widget<Tooltip>(
    find.byKey(const Key('mic_input_meter_tooltip')),
  );
}

void main() {
  testWidgets('replaces the old monitor panel with a trailing mic meter', (
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

    expect(
      _meterOutline(tester).color,
      theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.62),
    );
    expect(_meterFill(tester).heightFactor, 0.0);
    expect(
      _meterTooltip(tester).message,
      l10n.micInputIndicatorDisabledTooltip,
    );
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

    expect(
      _meterOutline(tester).color,
      theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.86),
    );
    expect(
      _meterFill(tester).heightFactor,
      closeTo(_expectedVisualLevel(0.42), 0.001),
    );
    expect(
      _meterTooltip(tester).message,
      l10n.micInputIndicatorLiveTooltip('-23.1'),
    );
  });

  testWidgets('meter fill uses a more sensitive response curve', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      micInputLevelLinear: 0.08,
      micInputLevelDbfs: -42.0,
    );

    expect(
      _meterFill(tester).heightFactor,
      closeTo(_expectedVisualLevel(0.08), 0.001),
    );
    expect(_meterFill(tester).heightFactor!, greaterThan(0.08));
  });

  testWidgets('meter fill animates to the latest audio level', (tester) async {
    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      micInputLevelLinear: 0.18,
      micInputLevelDbfs: -30.0,
    );

    expect(
      _meterFill(tester).heightFactor,
      closeTo(_expectedVisualLevel(0.18), 0.001),
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

    expect(
      _meterFill(tester).heightFactor,
      closeTo(_expectedVisualLevel(0.76), 0.001),
    );
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

    expect(
      _meterFill(tester).heightFactor,
      closeTo(_expectedVisualLevel(0.72), 0.001),
    );

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
      _meterFill(tester).heightFactor,
      closeTo(_expectedVisualLevel(0.16), 0.001),
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
      _meterFill(tester).heightFactor,
      closeTo(_expectedVisualLevel(0.36), 0.001),
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

    expect(_meterFill(tester).heightFactor, 0.0);
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
      _meterFill(tester).heightFactor,
      closeTo(_expectedVisualLevel(0.14), 0.001),
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
      _meterFill(tester).heightFactor,
      closeTo(_expectedVisualLevel(0.52), 0.001),
    );
  });

  testWidgets('low input swaps the meter tooltip to the warning copy', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      selectedAudioSourceId: 'mic-1',
      micInputLevelLinear: 0.08,
      micInputLevelDbfs: -45.2,
      micInputTooLow: true,
    );

    final l10n = _l10n(tester);

    expect(_meterTooltip(tester).message, l10n.micInputIndicatorLowTooltip);
    expect(
      _meterFill(tester).heightFactor,
      closeTo(_expectedVisualLevel(0.08), 0.001),
    );
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
