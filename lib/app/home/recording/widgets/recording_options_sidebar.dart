import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_rail_button.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:flutter/material.dart' hide PlatformMenuItem;
import 'package:clingfy/core/models/app_models.dart';
import 'package:clingfy/core/overlay/overlay_mode.dart';
import 'package:clingfy/app/home/recording/widgets/recording_audio_section.dart';
import 'package:clingfy/app/home/recording/widgets/recording_camera_section.dart';
import 'package:clingfy/app/home/recording/widgets/recording_capture_settings_section.dart';
import 'package:clingfy/app/home/recording/widgets/recording_output_section.dart';
import 'package:clingfy/app/home/recording/widgets/recording_overlay_section.dart';
import 'package:clingfy/app/home/recording/widgets/recording_source_section.dart';
import 'package:clingfy/app/home/recording/widgets/overlay_segmented.dart';
import 'package:clingfy/l10n/app_localizations.dart';

class RecordingSidebarRail extends StatelessWidget {
  const RecordingSidebarRail({
    super.key,
    required this.selectedIndex,
    required this.onSelectedIndexChanged,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelectedIndexChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: AppSidebarTokens.sectionGap),
        _RecordingRailItem(
          icon: Icons.monitor,
          label: AppLocalizations.of(context)!.tabScreenAudio,
          index: 0,
          isSelected: selectedIndex == 0,
          onTap: onSelectedIndexChanged,
        ),
        const SizedBox(height: AppSidebarTokens.sectionGap),
        _RecordingRailItem(
          icon: Icons.face,
          label: AppLocalizations.of(context)!.tabFaceCam,
          index: 1,
          isSelected: selectedIndex == 1,
          onTap: onSelectedIndexChanged,
        ),
        const SizedBox(height: AppSidebarTokens.sectionGap),
        _RecordingRailItem(
          icon: Icons.tune,
          label: AppLocalizations.of(context)!.output,
          index: 2,
          isSelected: selectedIndex == 2,
          onTap: onSelectedIndexChanged,
        ),
      ],
    );
  }
}

class _RecordingRailItem extends StatelessWidget {
  const _RecordingRailItem({
    required this.icon,
    required this.label,
    required this.index,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int index;
  final bool isSelected;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: AppSidebarTokens.railItemVerticalPadding,
      ),
      child: AppSidebarRailButton(
        buttonKey: ValueKey('recording_sidebar_rail_tile_$index'),
        icon: icon,
        tooltip: label,
        semanticsLabel: label,
        selected: isSelected,
        onTap: () => onTap(index),
        iconSize: 28,
        buttonSize: 40,
      ),
    );
  }
}

class RecordingOptionsSidebar extends StatelessWidget {
  final bool isRecording;
  final int selectedIndex;

  // Record Tab
  final DisplayTargetMode targetMode;
  final List<DisplayInfo> displays;
  final int? selectedDisplayId;
  final List<AppWindowInfo> appWindows;
  final int? selectedAppWindowId;
  final bool loadingAppWindows;
  final List<AudioSource> audioSources;
  final String selectedAudioSourceId;
  final bool loadingAudio;
  final bool systemAudioEnabled;
  final double micInputLevelLinear;
  final double micInputLevelDbfs;
  final bool micInputTooLow;
  final List<CamSource> cams;
  final String? selectedCamId;
  final bool loadingCams;

  final int? areaDisplayId;
  final Rect? areaRect;

  final Function(DisplayTargetMode) onTargetModeChanged;
  final Function(int?) onDisplayChanged;
  final VoidCallback onRefreshDisplays;
  final Function(int?) onAppWindowChanged;
  final VoidCallback onRefreshAppWindows;
  final Function(String?) onAudioSourceChanged;
  final VoidCallback onRefreshAudio;
  final Function(bool) onSystemAudioEnabledChanged;
  final bool excludeMicFromSystemAudio;
  final Function(bool) onExcludeMicFromSystemAudioChanged;
  final Function(String?) onCamSourceChanged;
  final VoidCallback onRefreshCams;
  final VoidCallback onPickArea;
  final VoidCallback onRevealArea;
  final VoidCallback onClearArea;

  // Output Tab
  final int captureFrameRate;
  final bool autoStopEnabled;
  final Duration autoStopAfter;

  final bool countdownEnabled;
  final int countdownDuration;

  final Function(int) onFrameRateChanged;
  final Function(bool) onAutoStopEnabledChanged;
  final Function(Duration) onAutoStopAfterChanged;

  final Function(bool) onCountdownEnabledChanged;
  final Function(int) onCountdownDurationChanged;

  // Capture Settings
  final bool excludeRecorderAppFromCapture;
  final Function(bool) onExcludeRecorderAppFromCaptureChanged;

  // Settings Tab
  final OverlayMode overlayMode;
  final OverlayShape overlayShape;
  final double overlaySize;
  final OverlayShadow overlayShadow;
  final OverlayBorder overlayBorder;
  final OverlayPosition overlayPosition;
  final bool overlayUseCustomPosition;
  final double overlayRoundness;

  final bool indicatorPinned;
  final bool cursorEnabled;
  final bool cursorLinkedToRecording;

  final Function(OverlayMode) onOverlayModeChanged;
  final Function(OverlayShape) onOverlayShapeChanged;
  final Function(double) onOverlaySizeChanged;
  final Function(OverlayShadow) onOverlayShadowChanged;
  final Function(OverlayBorder) onOverlayBorderChanged;
  final Function(OverlayPosition) onOverlayPositionChanged;
  final Function(double) onOverlayRoundnessChanged;
  final double overlayOpacity;
  final Function(double) onOverlayOpacityChanged;
  final bool overlayMirror;
  final Function(bool) onOverlayMirrorChanged;
  final bool overlayRecordingHighlightEnabled;
  final double overlayRecordingHighlightStrength;
  final Function(bool) onOverlayRecordingHighlightEnabledChanged;
  final Function(double) onOverlayRecordingHighlightStrengthChanged;
  final double overlayBorderWidth;
  final int overlayBorderColor;
  final Function(double) onOverlayBorderWidthChanged;
  final Function(int) onOverlayBorderColorChanged;

  final bool chromaKeyEnabled;
  final double chromaKeyStrength;
  final int chromaKeyColor;
  final Function(bool) onChromaKeyEnabledChanged;
  final Function(double) onChromaKeyStrengthChanged;
  final Function(int) onChromaKeyColorChanged;

  final Function(bool) onIndicatorPinnedChanged;
  final Function(OverlayMode) onCursorModeChanged;

  const RecordingOptionsSidebar({
    super.key,
    required this.isRecording,
    required this.selectedIndex,
    this.availableWidth = double.infinity,
    this.isCompact = false,
    // Record Tab
    required this.targetMode,
    required this.displays,
    required this.selectedDisplayId,
    required this.appWindows,
    required this.selectedAppWindowId,
    required this.loadingAppWindows,
    required this.audioSources,
    required this.selectedAudioSourceId,
    required this.loadingAudio,
    required this.systemAudioEnabled,
    this.micInputLevelLinear = 0.0,
    this.micInputLevelDbfs = -160.0,
    this.micInputTooLow = false,
    required this.cams,
    required this.selectedCamId,
    required this.loadingCams,
    this.areaDisplayId,
    this.areaRect,
    required this.onPickArea,
    required this.onRevealArea,
    required this.onClearArea,
    required this.onTargetModeChanged,
    required this.onDisplayChanged,
    required this.onRefreshDisplays,
    required this.onAppWindowChanged,
    required this.onRefreshAppWindows,
    required this.onAudioSourceChanged,
    required this.onRefreshAudio,
    required this.onSystemAudioEnabledChanged,
    required this.excludeMicFromSystemAudio,
    required this.onExcludeMicFromSystemAudioChanged,
    required this.onCamSourceChanged,
    required this.onRefreshCams,
    // Output Tab
    required this.captureFrameRate,
    required this.autoStopEnabled,
    required this.autoStopAfter,

    required this.onFrameRateChanged,
    required this.onAutoStopEnabledChanged,
    required this.onAutoStopAfterChanged,

    required this.countdownEnabled,
    required this.countdownDuration,
    required this.onCountdownEnabledChanged,
    required this.onCountdownDurationChanged,
    // Capture Settings
    required this.excludeRecorderAppFromCapture,
    required this.onExcludeRecorderAppFromCaptureChanged,
    // Settings Tab
    required this.overlayMode,
    required this.overlayShape,
    required this.overlaySize,
    required this.overlayShadow,
    required this.overlayBorder,
    required this.overlayPosition,
    required this.overlayUseCustomPosition,
    required this.overlayRoundness,

    required this.indicatorPinned,
    required this.cursorEnabled,
    required this.cursorLinkedToRecording,
    required this.onOverlayModeChanged,
    required this.onOverlayShapeChanged,
    required this.onOverlaySizeChanged,
    required this.onOverlayShadowChanged,
    required this.onOverlayBorderChanged,
    required this.onOverlayPositionChanged,
    required this.onOverlayRoundnessChanged,
    required this.overlayOpacity,
    required this.onOverlayOpacityChanged,
    required this.overlayMirror,
    required this.onOverlayMirrorChanged,
    required this.overlayRecordingHighlightEnabled,
    required this.overlayRecordingHighlightStrength,
    required this.onOverlayRecordingHighlightEnabledChanged,
    required this.onOverlayRecordingHighlightStrengthChanged,
    required this.overlayBorderWidth,
    required this.overlayBorderColor,
    required this.onOverlayBorderWidthChanged,
    required this.onOverlayBorderColorChanged,
    required this.chromaKeyEnabled,
    required this.chromaKeyStrength,
    required this.chromaKeyColor,
    required this.onChromaKeyEnabledChanged,
    required this.onChromaKeyStrengthChanged,
    required this.onChromaKeyColorChanged,

    required this.onIndicatorPinnedChanged,
    required this.onCursorModeChanged,
  });

  final double availableWidth;
  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final useCompactSpacing = isCompact || availableWidth <= 320;
    final horizontalPadding = useCompactSpacing
        ? 10.0
        : AppSidebarTokens.contentHorizontalPadding;
    final headerTopPadding = useCompactSpacing
        ? 10.0
        : AppSidebarTokens.headerTopPadding;
    final headerBottomPadding = useCompactSpacing
        ? 8.0
        : AppSidebarTokens.headerBottomPadding;
    final headerStyle = (theme.textTheme.titleMedium ?? const TextStyle())
        .copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: 16,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const Key('recording_sidebar_header'),
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            headerTopPadding,
            horizontalPadding,
            headerBottomPadding,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: theme.dividerColor.withValues(alpha: 0.08),
              ),
            ),
          ),
          child: Text(_getHeaderTitle(context), style: headerStyle),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            children: [
              const SizedBox(
                key: Key('recording_sidebar_top_spacer'),
                height: AppSidebarTokens.headerContentGap,
              ),
              if (selectedIndex == 0) ..._buildScreenTab(context),
              if (selectedIndex == 1) ..._buildCameraTab(context),
              if (selectedIndex == 2) ..._buildOutputTab(context),
              const SizedBox(
                key: Key('recording_sidebar_bottom_spacer'),
                height: AppSidebarTokens.rowGap,
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _getHeaderTitle(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    switch (selectedIndex) {
      case 0:
        return l10n.tabScreenAudio;
      case 1:
        return l10n.tabFaceCam;
      case 2:
        return l10n.output;
      default:
        return '';
    }
  }

  List<Widget> _buildScreenTab(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return [
      RecordingSourceSection(
        isRecording: isRecording,
        targetMode: targetMode,
        displays: displays,
        selectedDisplayId: selectedDisplayId,
        appWindows: appWindows,
        selectedAppWindowId: selectedAppWindowId,
        areaDisplayId: areaDisplayId,
        areaRect: areaRect,
        onTargetModeChanged: onTargetModeChanged,
        onDisplayChanged: onDisplayChanged,
        onRefreshDisplays: onRefreshDisplays,
        onAppWindowChanged: onAppWindowChanged,
        onRefreshAppWindows: onRefreshAppWindows,
        onPickArea: onPickArea,
        onRevealArea: onRevealArea,
        onClearArea: onClearArea,
      ),
      const SizedBox(height: AppSidebarTokens.rowGap),
      Divider(color: theme.dividerColor.withValues(alpha: 0.1)),
      const SizedBox(height: AppSidebarTokens.rowGap),
      RecordingAudioSection(
        isRecording: isRecording,
        audioSources: audioSources,
        selectedAudioSourceId: selectedAudioSourceId,
        loadingAudio: loadingAudio,
        systemAudioEnabled: systemAudioEnabled,
        excludeMicFromSystemAudio: excludeMicFromSystemAudio,
        micInputLevelLinear: micInputLevelLinear,
        micInputLevelDbfs: micInputLevelDbfs,
        micInputTooLow: micInputTooLow,
        onAudioSourceChanged: onAudioSourceChanged,
        onRefreshAudio: onRefreshAudio,
        onSystemAudioEnabledChanged: onSystemAudioEnabledChanged,
        onExcludeMicFromSystemAudioChanged: onExcludeMicFromSystemAudioChanged,
      ),
      const SizedBox(height: AppSidebarTokens.rowGap),
      Divider(color: theme.dividerColor.withValues(alpha: 0.1)),
      const SizedBox(height: AppSidebarTokens.rowGap),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppFormRow(
            label: l10n.cursorHighlightVisibility,
            infoTooltip:
                cursorEnabled && cursorLinkedToRecording && !isRecording
                ? l10n.cursorHint
                : null,
            control: _buildSegmentedControl(
              mode: cursorEnabled
                  ? (cursorLinkedToRecording
                        ? OverlayMode.whileRecording
                        : OverlayMode.alwaysOn)
                  : OverlayMode.off,
              onChanged: onCursorModeChanged,
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _buildCameraTab(BuildContext context) {
    return [
      RecordingCameraSection(
        isRecording: isRecording,
        cams: cams,
        selectedCamId: selectedCamId,
        loadingCams: loadingCams,
        onRefreshCams: onRefreshCams,
        onCamSourceChanged: onCamSourceChanged,
      ),
      if (selectedCamId != null) ...[
        const SizedBox(
          key: Key('recording_camera_overlay_gap'),
          height: AppSidebarTokens.rowGap,
        ),
        RecordingOverlaySection(
          isRecording: isRecording,
          overlayMode: overlayMode,
          overlayShape: overlayShape,
          overlaySize: overlaySize,
          overlayShadow: overlayShadow,
          overlayBorder: overlayBorder,
          overlayPosition: overlayPosition,
          overlayUseCustomPosition: overlayUseCustomPosition,
          overlayRoundness: overlayRoundness,
          overlayOpacity: overlayOpacity,
          overlayMirror: overlayMirror,
          overlayRecordingHighlightEnabled: overlayRecordingHighlightEnabled,
          overlayRecordingHighlightStrength: overlayRecordingHighlightStrength,
          overlayBorderWidth: overlayBorderWidth,
          overlayBorderColor: overlayBorderColor,
          chromaKeyEnabled: chromaKeyEnabled,
          chromaKeyStrength: chromaKeyStrength,
          chromaKeyColor: chromaKeyColor,
          onOverlayModeChanged: onOverlayModeChanged,
          onOverlayShapeChanged: onOverlayShapeChanged,
          onOverlaySizeChanged: onOverlaySizeChanged,
          onOverlayShadowChanged: onOverlayShadowChanged,
          onOverlayBorderChanged: onOverlayBorderChanged,
          onOverlayPositionChanged: onOverlayPositionChanged,
          onOverlayRoundnessChanged: onOverlayRoundnessChanged,
          onOverlayOpacityChanged: onOverlayOpacityChanged,
          onOverlayMirrorChanged: onOverlayMirrorChanged,
          onOverlayRecordingHighlightEnabledChanged:
              onOverlayRecordingHighlightEnabledChanged,
          onOverlayRecordingHighlightStrengthChanged:
              onOverlayRecordingHighlightStrengthChanged,
          onOverlayBorderWidthChanged: onOverlayBorderWidthChanged,
          onOverlayBorderColorChanged: onOverlayBorderColorChanged,
          onChromaKeyEnabledChanged: onChromaKeyEnabledChanged,
          onChromaKeyStrengthChanged: onChromaKeyStrengthChanged,
          onChromaKeyColorChanged: onChromaKeyColorChanged,
        ),
      ],
    ];
  }

  List<Widget> _buildOutputTab(BuildContext context) {
    final theme = Theme.of(context);

    return [
      RecordingOutputSection(
        isRecording: isRecording,
        captureFrameRate: captureFrameRate,
        autoStopEnabled: autoStopEnabled,
        autoStopAfter: autoStopAfter,
        countdownEnabled: countdownEnabled,
        countdownDuration: countdownDuration,
        onFrameRateChanged: onFrameRateChanged,
        onAutoStopEnabledChanged: onAutoStopEnabledChanged,
        onAutoStopAfterChanged: onAutoStopAfterChanged,
        onCountdownEnabledChanged: onCountdownEnabledChanged,
        onCountdownDurationChanged: onCountdownDurationChanged,
      ),
      if (targetMode != DisplayTargetMode.singleAppWindow) ...[
        const SizedBox(
          key: Key('recording_output_capture_settings_gap_before_divider'),
          height: AppSidebarTokens.rowGap,
        ),
        Divider(color: theme.dividerColor.withValues(alpha: 0.1)),
        const SizedBox(
          key: Key('recording_output_capture_settings_gap_after_divider'),
          height: AppSidebarTokens.rowGap,
        ),
        RecordingCaptureSettingsSection(
          isRecording: isRecording,
          excludeRecorderAppFromCapture: excludeRecorderAppFromCapture,
          onExcludeRecorderAppFromCaptureChanged:
              onExcludeRecorderAppFromCaptureChanged,
        ),
      ],
    ];
  }

  Widget _buildSegmentedControl({
    required OverlayMode mode,
    required ValueChanged<OverlayMode> onChanged,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: AppSidebarTokens.controlMinWidth,
        maxWidth: AppSidebarTokens.controlMaxWidth,
      ),
      child: OverlaySegmented(mode: mode, onChanged: onChanged),
    );
  }
}
