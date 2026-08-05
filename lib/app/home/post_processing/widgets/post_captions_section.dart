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
    required this.progress,
    required this.isProcessing,
    required this.onUseMicChanged,
    required this.onUseSystemChanged,
    required this.onGenerate,
    required this.onCancel,
    required this.onCueTextChanged,
    required this.subtitleMode,
    required this.onSubtitleModeChanged,
    this.stageLabel,
    this.hasEverGenerated = false,
  });

  final CaptionsCapabilityInfo? capability;
  final List<Caption> captions;
  final bool useMic;
  final bool useSystem;
  final bool isGenerating;

  /// `null` while the job cannot report a fraction — model download and Core ML
  /// specialisation take tens of seconds before any real progress exists, and a
  /// bar pinned at 0% through that reads as a hang.
  final double? progress;
  final String? stageLabel;

  /// Export or preview work in flight; every control is inert.
  final bool isProcessing;

  /// Distinguishes "not run yet" from "ran and found nothing", which are very
  /// different messages to show someone.
  final bool hasEverGenerated;

  final ValueChanged<bool> onUseMicChanged;
  final ValueChanged<bool> onUseSystemChanged;
  final VoidCallback onGenerate;
  final VoidCallback onCancel;
  final void Function(String cueId, String text) onCueTextChanged;

  /// Where subtitles go on export. Only meaningful once cues exist, so the
  /// control is not shown before then.
  final SubtitleMode subtitleMode;
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

    final canGenerate = !isProcessing && (useMic || useSystem);

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
                label: stageLabel ?? l10n.captionsPreparing,
                progress: progress,
                onCancel: onCancel,
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
              for (final caption in captions)
                _CueRow(
                  key: Key('captions_cue_${caption.id}'),
                  caption: caption,
                  enabled: !isGenerating && !isProcessing,
                  onTextChanged: (text) => onCueTextChanged(caption.id, text),
                ),
            ],
          ),
        ] else if (hasEverGenerated && !isGenerating) ...[
          const SizedBox(height: AppSidebarTokens.compactGap),
          AppInlineNotice(
            message: l10n.captionsNoSpeechFound,
            variant: AppInlineNoticeVariant.info,
          ),
        ],
      ],
    );
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
  final VoidCallback onCancel;
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
    required this.enabled,
    required this.onTextChanged,
  });

  final Caption caption;
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

  @override
  void initState() {
    super.initState();
    // Commit on blur rather than per keystroke: every commit is an undoable
    // edit, and one per character would bury real changes in the undo stack.
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && _controller.text != widget.caption.text) {
        widget.onTextChanged(_controller.text);
      }
    });
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
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  String get _timestamp {
    final seconds = widget.caption.startMs ~/ 1000;
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
