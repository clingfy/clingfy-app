import 'package:clingfy/ui/platform/widgets/app_form_row.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/theme/app_theme.dart';
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

class RecordingOptionsSidebar extends StatefulWidget {
  final bool isRecording;

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

  @override
  State<RecordingOptionsSidebar> createState() =>
      _RecordingOptionsSidebarState();
}

class _RecordingOptionsSidebarState extends State<RecordingOptionsSidebar> {
  int _selectedIndex = 0; // 0: Screen & Audio, 1: Face Cam, 2: Output

  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(covariant RecordingOptionsSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.autoStopAfter != widget.autoStopAfter) {}
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chrome = theme.appEditorChrome;
    final colorScheme = theme.colorScheme;
    final controlFill =
        theme.inputDecorationTheme.fillColor ?? colorScheme.surface;
    final headerStyle = (theme.textTheme.titleMedium ?? const TextStyle())
        .copyWith(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w700,
          fontSize: 16,
        );

    final railColor = Color.alphaBlend(
      controlFill.withValues(alpha: 0.18),
      colorScheme.surface,
    );
    final accentColor = theme.primaryColor;

    return Row(
      children: [
        // Level 1: Navigation Rail
        Container(
          key: const Key('recording_sidebar_rail'),
          width: chrome.editorRailWidth,
          color: railColor,
          child: Column(
            children: [
              const SizedBox(height: AppSidebarTokens.sectionGap),
              _buildRailItem(
                icon: Icons.monitor,
                label: AppLocalizations.of(context)!.tabScreenAudio,
                index: 0,
                isSelected: _selectedIndex == 0,
                accentColor: accentColor,
              ),
              const SizedBox(height: AppSidebarTokens.sectionGap),
              _buildRailItem(
                icon: Icons.face,
                label: AppLocalizations.of(context)!.tabFaceCam,
                index: 1,
                isSelected: _selectedIndex == 1,
                accentColor: accentColor,
              ),
              const SizedBox(height: AppSidebarTokens.sectionGap),
              _buildRailItem(
                icon: Icons.tune,
                label: AppLocalizations.of(context)!.output,
                index: 2,
                isSelected: _selectedIndex == 2,
                accentColor: accentColor,
              ),
            ],
          ),
        ),

        VerticalDivider(
          width: 1,
          thickness: 1,
          indent: AppSidebarTokens.headerTopPadding,
          endIndent: AppSidebarTokens.headerTopPadding,
          color: theme.dividerColor.withValues(alpha: 0.14),
        ),
        // Level 2: Content Area
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Container(
                key: const Key('recording_sidebar_header'),
                padding: const EdgeInsets.fromLTRB(
                  AppSidebarTokens.contentHorizontalPadding,
                  AppSidebarTokens.sectionGap,
                  AppSidebarTokens.contentHorizontalPadding,
                  AppSidebarTokens.rowGap,
                ),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.08),
                    ),
                  ),
                ),
                child: Text(_getHeaderTitle(), style: headerStyle),
              ),

              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSidebarTokens.contentHorizontalPadding,
                  ),
                  children: [
                    const SizedBox(height: AppSidebarTokens.rowGap),
                    if (_selectedIndex == 0) ..._buildScreenTab(context),
                    if (_selectedIndex == 1) ..._buildCameraTab(context),
                    if (_selectedIndex == 2) ..._buildOutputTab(context),
                    const SizedBox(
                      height:
                          AppSidebarTokens.sectionGap +
                          AppSidebarTokens.compactGap,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _getHeaderTitle() {
    final l10n = AppLocalizations.of(context)!;
    switch (_selectedIndex) {
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

  Widget _buildRailItem({
    required IconData icon,
    required String label,
    required int index,
    required bool isSelected,
    required Color accentColor,
  }) {
    final theme = Theme.of(context);
    final chrome = theme.appEditorChrome;
    final controlFill =
        theme.inputDecorationTheme.fillColor ?? theme.colorScheme.surface;
    final inactiveColor = theme.colorScheme.onSurfaceVariant;
    final labelStyle = (theme.textTheme.labelSmall ?? const TextStyle())
        .copyWith(
          color: isSelected ? accentColor : inactiveColor,
          fontWeight: FontWeight.w600,
          fontSize: 10,
          height: 1.2,
        );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _selectedIndex = index),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: AppSidebarTokens.railItemVerticalPadding,
          ),
          child: Column(
            children: [
              Container(
                key: ValueKey('recording_sidebar_rail_tile_$index'),
                width: chrome.inspectorTabHeight + 8,
                height: chrome.inspectorTabHeight + 8,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSelected
                      ? accentColor.withValues(alpha: 0.16)
                      : controlFill.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(chrome.controlRadius + 2),
                  border: Border.all(
                    color: isSelected
                        ? accentColor.withValues(alpha: 0.3)
                        : theme.dividerColor.withValues(alpha: 0.08),
                  ),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: accentColor.withValues(alpha: 0.14),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Icon(
                  icon,
                  color: isSelected ? accentColor : inactiveColor,
                  size: 20,
                ),
              ),
              const SizedBox(height: AppSidebarTokens.compactGap / 2),
              Text(label, style: labelStyle, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildScreenTab(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final helperStyle = AppSidebarTokens.helperStyle(theme);

    return [
      RecordingSourceSection(
        isRecording: widget.isRecording,
        targetMode: widget.targetMode,
        displays: widget.displays,
        selectedDisplayId: widget.selectedDisplayId,
        appWindows: widget.appWindows,
        selectedAppWindowId: widget.selectedAppWindowId,
        areaDisplayId: widget.areaDisplayId,
        areaRect: widget.areaRect,
        onTargetModeChanged: widget.onTargetModeChanged,
        onDisplayChanged: widget.onDisplayChanged,
        onRefreshDisplays: widget.onRefreshDisplays,
        onAppWindowChanged: widget.onAppWindowChanged,
        onRefreshAppWindows: widget.onRefreshAppWindows,
        onPickArea: widget.onPickArea,
        onRevealArea: widget.onRevealArea,
        onClearArea: widget.onClearArea,
      ),
      const SizedBox(height: AppSidebarTokens.sectionGap),
      Divider(color: theme.dividerColor.withValues(alpha: 0.1)),
      const SizedBox(height: AppSidebarTokens.compactGap),
      RecordingAudioSection(
        isRecording: widget.isRecording,
        audioSources: widget.audioSources,
        selectedAudioSourceId: widget.selectedAudioSourceId,
        loadingAudio: widget.loadingAudio,
        systemAudioEnabled: widget.systemAudioEnabled,
        excludeMicFromSystemAudio: widget.excludeMicFromSystemAudio,
        micInputLevelLinear: widget.micInputLevelLinear,
        micInputLevelDbfs: widget.micInputLevelDbfs,
        micInputTooLow: widget.micInputTooLow,
        onAudioSourceChanged: widget.onAudioSourceChanged,
        onRefreshAudio: widget.onRefreshAudio,
        onSystemAudioEnabledChanged: widget.onSystemAudioEnabledChanged,
        onExcludeMicFromSystemAudioChanged:
            widget.onExcludeMicFromSystemAudioChanged,
      ),
      const SizedBox(height: AppSidebarTokens.sectionGap),
      Divider(color: theme.dividerColor.withValues(alpha: 0.1)),
      const SizedBox(height: AppSidebarTokens.sectionGap),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppFormRow(
            label: l10n.cursorHighlightVisibility,
            control: _buildSegmentedControl(
              mode: widget.cursorEnabled
                  ? (widget.cursorLinkedToRecording
                        ? OverlayMode.whileRecording
                        : OverlayMode.alwaysOn)
                  : OverlayMode.off,
              onChanged: widget.onCursorModeChanged,
            ),
          ),
          const SizedBox(height: AppSidebarTokens.compactGap),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child:
                (widget.cursorEnabled &&
                    widget.cursorLinkedToRecording &&
                    !widget.isRecording)
                ? Text(
                    l10n.cursorHint,
                    key: const ValueKey('cursorHint'),
                    style: helperStyle,
                  )
                : const SizedBox.shrink(key: ValueKey('noCursorHint')),
          ),
        ],
      ),
    ];
  }

  List<Widget> _buildCameraTab(BuildContext context) {
    return [
      RecordingCameraSection(
        isRecording: widget.isRecording,
        cams: widget.cams,
        selectedCamId: widget.selectedCamId,
        loadingCams: widget.loadingCams,
        onRefreshCams: widget.onRefreshCams,
        onCamSourceChanged: widget.onCamSourceChanged,
      ),
      if (widget.selectedCamId != null)
        RecordingOverlaySection(
          isRecording: widget.isRecording,
          overlayMode: widget.overlayMode,
          overlayShape: widget.overlayShape,
          overlaySize: widget.overlaySize,
          overlayShadow: widget.overlayShadow,
          overlayBorder: widget.overlayBorder,
          overlayPosition: widget.overlayPosition,
          overlayUseCustomPosition: widget.overlayUseCustomPosition,
          overlayRoundness: widget.overlayRoundness,
          overlayOpacity: widget.overlayOpacity,
          overlayMirror: widget.overlayMirror,
          overlayRecordingHighlightEnabled:
              widget.overlayRecordingHighlightEnabled,
          overlayRecordingHighlightStrength:
              widget.overlayRecordingHighlightStrength,
          overlayBorderWidth: widget.overlayBorderWidth,
          overlayBorderColor: widget.overlayBorderColor,
          chromaKeyEnabled: widget.chromaKeyEnabled,
          chromaKeyStrength: widget.chromaKeyStrength,
          chromaKeyColor: widget.chromaKeyColor,
          onOverlayModeChanged: widget.onOverlayModeChanged,
          onOverlayShapeChanged: widget.onOverlayShapeChanged,
          onOverlaySizeChanged: widget.onOverlaySizeChanged,
          onOverlayShadowChanged: widget.onOverlayShadowChanged,
          onOverlayBorderChanged: widget.onOverlayBorderChanged,
          onOverlayPositionChanged: widget.onOverlayPositionChanged,
          onOverlayRoundnessChanged: widget.onOverlayRoundnessChanged,
          onOverlayOpacityChanged: widget.onOverlayOpacityChanged,
          onOverlayMirrorChanged: widget.onOverlayMirrorChanged,
          onOverlayRecordingHighlightEnabledChanged:
              widget.onOverlayRecordingHighlightEnabledChanged,
          onOverlayRecordingHighlightStrengthChanged:
              widget.onOverlayRecordingHighlightStrengthChanged,
          onOverlayBorderWidthChanged: widget.onOverlayBorderWidthChanged,
          onOverlayBorderColorChanged: widget.onOverlayBorderColorChanged,
          onChromaKeyEnabledChanged: widget.onChromaKeyEnabledChanged,
          onChromaKeyStrengthChanged: widget.onChromaKeyStrengthChanged,
          onChromaKeyColorChanged: widget.onChromaKeyColorChanged,
        ),
    ];
  }

  List<Widget> _buildOutputTab(BuildContext context) {
    final theme = Theme.of(context);

    return [
      RecordingOutputSection(
        isRecording: widget.isRecording,
        captureFrameRate: widget.captureFrameRate,
        autoStopEnabled: widget.autoStopEnabled,
        autoStopAfter: widget.autoStopAfter,
        countdownEnabled: widget.countdownEnabled,
        countdownDuration: widget.countdownDuration,
        onFrameRateChanged: widget.onFrameRateChanged,
        onAutoStopEnabledChanged: widget.onAutoStopEnabledChanged,
        onAutoStopAfterChanged: widget.onAutoStopAfterChanged,
        onCountdownEnabledChanged: widget.onCountdownEnabledChanged,
        onCountdownDurationChanged: widget.onCountdownDurationChanged,
      ),
      if (widget.targetMode != DisplayTargetMode.singleAppWindow) ...[
        const SizedBox(height: AppSidebarTokens.sectionGap),
        Divider(color: theme.dividerColor.withValues(alpha: 0.1)),
        const SizedBox(height: AppSidebarTokens.sectionGap),
        RecordingCaptureSettingsSection(
          isRecording: widget.isRecording,
          excludeRecorderAppFromCapture: widget.excludeRecorderAppFromCapture,
          onExcludeRecorderAppFromCaptureChanged:
              widget.onExcludeRecorderAppFromCaptureChanged,
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
