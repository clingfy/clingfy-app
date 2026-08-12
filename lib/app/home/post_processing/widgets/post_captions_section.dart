import 'dart:async';
import 'package:clingfy/core/captions/caption_reflow.dart';
import 'package:clingfy/core/captions/captions_capability.dart';
import 'package:clingfy/core/captions/subtitle_serializer.dart';
import 'package:clingfy/core/timeline/model/edit_track.dart';
import 'package:clingfy/l10n/app_localizations.dart';
import 'package:clingfy/ui/platform/widgets/app_inline_notice.dart';
import 'package:clingfy/ui/platform/widgets/app_segmented.dart';
import 'package:clingfy/ui/platform/widgets/app_settings_group.dart';
import 'package:clingfy/ui/platform/widgets/app_sidebar_tokens.dart';
import 'package:clingfy/ui/platform/widgets/app_toggle_row.dart';
import 'package:flutter/material.dart';

/// Subtitle controls: generate, pick which audio to transcribe, and correct
/// what came back.
///
/// Stateless and value-driven like every other post-processing section — no
/// controller access, no provider import; the container binds it.
class PostCaptionsSection extends StatelessWidget {
  const PostCaptionsSection({
    super.key,
    required this.capability,
    required this.captions,
    required this.useMic,
    required this.useSystem,
    required this.isGenerating,
    required this.isCancelling,
    required this.progress,
    required this.isProcessing,
    this.engineBusyOffScreen = false,
    required this.onUseMicChanged,
    required this.onUseSystemChanged,
    required this.onGenerate,
    required this.onCancel,
    required this.onCueTextChanged,
    required this.subtitleMode,
    required this.reflowed,
    required this.onSubtitleModeChanged,
    this.stageLabel,
    this.hasEverGenerated = false,
    this.failed = false,
  });

  final CaptionsCapabilityInfo? capability;
  final List<Caption> captions;
  final bool useMic;
  final bool useSystem;
  final bool isGenerating;

  /// The user asked to stop and the engine has not finished unwinding. The row
  /// stays up, saying so, with the button inert — pressing it again does
  /// nothing, and an unacknowledged press is what made people press repeatedly.
  final bool isCancelling;

  /// `null` while the job cannot report a fraction — model download and Core ML
  /// specialisation take tens of seconds before any real progress exists, and a
  /// bar pinned at 0% through that reads as a hang.
  final double? progress;
  final String? stageLabel;

  /// Export or preview work in flight; every control is inert.
  final bool isProcessing;

  /// The transcription engine is still unwinding a job this panel is not
  /// showing — one started on another recording, or one this recording started
  /// and left. It takes one job at a time, so Generate cannot start and says so:
  /// an enabled button whose press the controller silently drops is
  /// indistinguishable from a broken feature, and the wait can be minutes
  /// because a model download cannot be interrupted.
  final bool engineBusyOffScreen;

  /// Distinguishes "not run yet" from "ran and found nothing", which are very
  /// different messages to show someone.
  final bool hasEverGenerated;

  /// The last run failed rather than finding nothing. Both leave an empty cue
  /// list, so without this the two are indistinguishable here and a failure
  /// gets reported as silence.
  final bool failed;

  final ValueChanged<bool> onUseMicChanged;
  final ValueChanged<bool> onUseSystemChanged;
  final VoidCallback onGenerate;
  final VoidCallback onCancel;
  final void Function(String cueId, String text) onCueTextChanged;

  /// Where subtitles go on export. Only meaningful once cues exist, so the
  /// control is not shown before then.
  final SubtitleMode subtitleMode;

  /// The transcript mapped onto the edited timeline. Each row's timestamp comes
  /// from here rather than from the cue itself: the cue holds a SOURCE time,
  /// and after a trim that number points at a different sentence than the one
  /// the preview will play there.
  final ReflowedCaptions reflowed;
  final ValueChanged<SubtitleMode> onSubtitleModeChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final info = capability;

    // Unknown capability means the probe has not answered yet. Showing controls
    // that might immediately be replaced by an unavailable notice is worse than
    // showing nothing for a moment.
    if (info == null) return const SizedBox.shrink();

    if (!info.available) {
      return AppSettingsGroup(
        title: l10n.captions,
        showHeader: false,
        children: [
          AppInlineNotice(
            message: _unavailableMessage(l10n, info.reason),
            variant: AppInlineNoticeVariant.warning,
          ),
        ],
      );
    }

    final canGenerate =
        !isProcessing && !engineBusyOffScreen && (useMic || useSystem);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSettingsGroup(
          title: l10n.captions,
          showHeader: false,
          children: [
            // Only worth showing when there is a choice to make. A picker with
            // one entry is noise.
            if (info.shouldOfferSourcePicker) ...[
              AppToggleRow(
                key: const Key('captions_source_mic'),
                title: l10n.captionsSourceMic,
                value: useMic,
                onChanged: isGenerating || isProcessing
                    ? null
                    : onUseMicChanged,
              ),
              const SizedBox(height: AppSidebarTokens.rowGap),
              AppToggleRow(
                key: const Key('captions_source_system'),
                title: l10n.captionsSourceSystem,
                value: useSystem,
                onChanged: isGenerating || isProcessing
                    ? null
                    : onUseSystemChanged,
              ),
              const SizedBox(height: AppSidebarTokens.rowGap),
            ],

            // A recording made before separate audio capture has only the
            // microphone on disk — that backend never recorded screen audio —
            // so a meeting captured then is missing one side of the
            // conversation and no transcription recovers it.
            if (info.usesEmbeddedAudioOnly) ...[
              AppInlineNotice(
                message: l10n.captionsMicOnlyRecording,
                variant: AppInlineNoticeVariant.info,
              ),
              const SizedBox(height: AppSidebarTokens.compactGap),
            ],

            if (isGenerating)
              _ProgressRow(
                label: isCancelling
                    ? l10n.captionsStopping
                    : (stageLabel ?? l10n.captionsPreparing),
                // Indeterminate while stopping: there is no meaningful fraction
                // left, and a bar still advancing after Stop is a lie.
                progress: isCancelling ? null : progress,
                onCancel: isCancelling ? null : onCancel,
                cancelLabel: l10n.captionsCancel,
              )
            else
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('captions_generate_button'),
                  onPressed: canGenerate ? onGenerate : null,
                  child: Text(
                    captions.isEmpty
                        ? l10n.captionsGenerate
                        : l10n.captionsRegenerate,
                  ),
                ),
              ),

            // Says why the button above is dead. Without it the disabled
            // Generate on a freshly-opened recording looks like the feature
            // failing, with nothing on screen tying it to the transcription
            // still unwinding on the recording just left.
            if (engineBusyOffScreen && !isGenerating) ...[
              const SizedBox(height: AppSidebarTokens.compactGap),
              AppInlineNotice(
                key: const Key('captions_engine_busy_notice'),
                message: l10n.captionsEngineBusy,
                variant: AppInlineNoticeVariant.info,
              ),
            ],

            // Shown only while generating, and only the first time — the model
            // download is a one-off and repeating the warning is noise.
            if (isGenerating && !hasEverGenerated) ...[
              const SizedBox(height: AppSidebarTokens.compactGap),
              AppInlineNotice(
                message: l10n.captionsFirstRunDownload,
                variant: AppInlineNoticeVariant.info,
              ),
            ],
          ],
        ),
        if (captions.isNotEmpty) ...[
          const SizedBox(height: AppSidebarTokens.rowGap),
          AppSettingsGroup(
            title: l10n.captionsDestination,
            children: [
              AppSegmented<SubtitleMode>(
                key: const ValueKey('captions_destination'),
                value: subtitleMode,
                compact: true,
                onChanged: isProcessing ? null : onSubtitleModeChanged,
                items: [
                  AppSegmentedItem(
                    value: SubtitleMode.none,
                    label: l10n.captionsDestinationOff,
                  ),
                  AppSegmentedItem(
                    value: SubtitleMode.burnIn,
                    label: l10n.captionsDestinationBurnIn,
                  ),
                  AppSegmentedItem(
                    value: SubtitleMode.sidecar,
                    label: l10n.captionsDestinationSidecar,
                  ),
                  AppSegmentedItem(
                    value: SubtitleMode.both,
                    label: l10n.captionsDestinationBoth,
                  ),
                ],
              ),
              const SizedBox(height: AppSidebarTokens.compactGap),
              Text(
                l10n.captionsDestinationHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: AppSidebarTokens.rowGap),
          AppSettingsGroup(
            title: l10n.captionsCueCount(captions.length),
            showHeader: true,
            children: [
              for (final entry in _rowsInPlaybackOrder())
                _CueRow(
                  key: Key('captions_cue_${entry.caption.id}'),
                  caption: entry.caption,
                  // Null when an edit removed every moment this cue covered:
                  // there is no position in the exported file to point at.
                  outputStartMs: entry.outputStartMs,
                  cutLabel: l10n.captionsNotInExport,
                  enabled: !isGenerating && !isProcessing,
                  onTextChanged: (text) =>
                      onCueTextChanged(entry.caption.id, text),
                ),
            ],
          ),
        ] else if (hasEverGenerated && !isGenerating) ...[
          const SizedBox(height: AppSidebarTokens.compactGap),
          AppInlineNotice(
            message: failed ? l10n.captionsFailed : l10n.captionsNoSpeechFound,
            variant: failed
                ? AppInlineNoticeVariant.warning
                : AppInlineNoticeVariant.info,
          ),
        ],
      ],
    );
  }

  /// Cues in the order the exported video plays them, each with the position
  /// it lands at — or null when it was cut away.
  ///
  /// A cut cue is still listed rather than hidden: the user's correction to it
  /// is real work, and undoing the cut must bring the line back rather than a
  /// re-transcription. It is listed last because it has no place in the video.
  List<({Caption caption, int? outputStartMs})> _rowsInPlaybackOrder() {
    final firstOutput = <String, int>{};
    for (final span in reflowed.sidecar) {
      final existing = firstOutput[span.cueId];
      if (existing == null || span.outputStartMs < existing) {
        firstOutput[span.cueId] = span.outputStartMs;
      }
    }
    final rows = [
      for (final caption in captions)
        (caption: caption, outputStartMs: firstOutput[caption.id]),
    ];
    rows.sort((a, b) {
      final ao = a.outputStartMs, bo = b.outputStartMs;
      if (ao == null && bo == null) {
        return a.caption.startMs.compareTo(b.caption.startMs);
      }
      if (ao == null) return 1;
      if (bo == null) return -1;
      return ao.compareTo(bo);
    });
    return rows;
  }

  String _unavailableMessage(
    AppLocalizations l10n,
    CaptionsUnavailableReason? reason,
  ) {
    switch (reason) {
      case CaptionsUnavailableReason.unsupportedOs:
        return l10n.captionsUnavailableOs;
      case CaptionsUnavailableReason.intelSlowPath:
        return l10n.captionsUnavailableIntel;
      case CaptionsUnavailableReason.noAudio:
        return l10n.captionsUnavailableNoAudio;
      case CaptionsUnavailableReason.platformNotSupported:
      case CaptionsUnavailableReason.unknown:
      case null:
        return l10n.captionsUnavailablePlatform;
    }
  }
}

class _ProgressRow extends StatelessWidget {
  const _ProgressRow({
    required this.label,
    required this.progress,
    required this.onCancel,
    required this.cancelLabel,
  });

  final String label;
  final double? progress;

  /// Null once the stop has been accepted, so a second press is inert.
  final VoidCallback? onCancel;
  final String cancelLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                progress == null
                    ? label
                    : '$label  ${(progress!.clamp(0.0, 1.0) * 100).round()}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              key: const Key('captions_cancel_button'),
              onPressed: onCancel,
              child: Text(cancelLabel),
            ),
          ],
        ),
        const SizedBox(height: AppSidebarTokens.compactGap),
        // A null fraction renders indeterminate rather than a bar stuck at zero.
        LinearProgressIndicator(value: progress),
      ],
    );
  }
}

/// One editable cue.
///
/// Cue-level rather than word-level on purpose: a user needs to fix a
/// mis-transcribed product name, and a whole-line text field does that at a
/// fraction of the interaction surface. Word-level editing is recorded as a
/// deferred item.
class _CueRow extends StatefulWidget {
  const _CueRow({
    super.key,
    required this.caption,
    required this.outputStartMs,
    required this.cutLabel,
    required this.enabled,
    required this.onTextChanged,
  });

  final Caption caption;

  /// Where this cue lands in the exported file, or null if an edit cut it.
  final int? outputStartMs;
  final String cutLabel;
  final bool enabled;
  final ValueChanged<String> onTextChanged;

  @override
  State<_CueRow> createState() => _CueRowState();
}

class _CueRowState extends State<_CueRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.caption.text,
  );
  late final FocusNode _focusNode = FocusNode();
  Timer? _commitDebounce;

  /// How long typing has to pause before the correction reaches the preview.
  ///
  /// Commit-on-blur alone was wrong for a feature whose whole point is
  /// watching the caption change: the preview kept showing the old text until
  /// the user clicked somewhere else, which read as the edit not working. Long
  /// enough not to fire mid-word, short enough to feel like the preview is
  /// following you.
  static const Duration _commitDelay = Duration(milliseconds: 350);

  @override
  void initState() {
    super.initState();
    // Blur still commits, so the last edit is never lost to a pending timer.
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        _commitDebounce?.cancel();
        _commit();
      }
    });
  }

  /// Debounced rather than per-keystroke: every commit is an undoable edit and
  /// re-rasterizes the cue, so one per character would both bury real changes
  /// in the undo stack and re-render on every letter.
  void _onChanged(String _) {
    _commitDebounce?.cancel();
    _commitDebounce = Timer(_commitDelay, _commit);
  }

  void _commit() {
    if (_controller.text == widget.caption.text) return;
    widget.onTextChanged(_controller.text);
  }

  @override
  void didUpdateWidget(_CueRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Regenerating replaces the text underneath an unfocused field.
    if (widget.caption.text != oldWidget.caption.text && !_focusNode.hasFocus) {
      _controller.text = widget.caption.text;
    }
  }

  @override
  void dispose() {
    _commitDebounce?.cancel();
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  String get _timestamp {
    final startMs = widget.outputStartMs;
    if (startMs == null) return widget.cutLabel;
    final seconds = startMs ~/ 1000;
    final minutes = seconds ~/ 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSidebarTokens.compactGap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _timestamp,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            // The surrounding editor subtree pins TextDirection.ltr, so an
            // Arabic cue would otherwise lay out against its own script. Letting
            // the field resolve direction from the text itself is what makes a
            // mixed transcript readable.
            child: Directionality(
              textDirection: _directionOf(widget.caption.text),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: widget.enabled,
                maxLines: null,
                style: Theme.of(context).textTheme.bodySmall,
                onChanged: _onChanged,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                ),
                onSubmitted: widget.onTextChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// First strong character wins, which is the Unicode bidi rule for a
  /// paragraph's base direction. Empty or symbol-only text stays LTR.
  static TextDirection _directionOf(String text) {
    for (final rune in text.runes) {
      // Hebrew, Arabic, Arabic Supplement/Extended, and their presentation forms.
      final isRtl =
          (rune >= 0x0590 && rune <= 0x08FF) ||
          (rune >= 0xFB1D && rune <= 0xFDFF) ||
          (rune >= 0xFE70 && rune <= 0xFEFF);
      if (isRtl) return TextDirection.rtl;
      final isLtr =
          (rune >= 0x0041 && rune <= 0x005A) ||
          (rune >= 0x0061 && rune <= 0x007A) ||
          (rune >= 0x00C0 && rune <= 0x024F);
      if (isLtr) return TextDirection.ltr;
    }
    return TextDirection.ltr;
  }
}
