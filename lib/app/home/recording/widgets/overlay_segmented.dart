import 'package:clingfy/ui/platform/widgets/responsive_shell_scope.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:clingfy/core/overlay/overlay_mode.dart';
import 'package:clingfy/l10n/app_localizations.dart';

class OverlaySegmented extends StatelessWidget {
  const OverlaySegmented({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final OverlayMode mode;
  final ValueChanged<OverlayMode> onChanged;

  bool get _isMac => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final metrics = context.shellMetricsOrNull;
    final scale = metrics?.scale ?? 1.0;
    final hPad = (12 * scale).clamp(8.0, 12.0).toDouble();
    final vPad = (10 * scale).clamp(7.0, 10.0).toDouble();

    final labels = <OverlayMode, String>{
      OverlayMode.off: l10n.off,
      OverlayMode.whileRecording: l10n.whileRecording,
      OverlayMode.alwaysOn: l10n.alwaysOn,
    };

    Widget segLabel(String text) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible,
        ),
      );
    }

    final control = _isMac
        ? CupertinoSlidingSegmentedControl<OverlayMode>(
            groupValue: mode,
            proportionalWidth: true,
            onValueChanged: (v) {
              if (v != null) onChanged(v);
            },
            children: {
              for (final e in labels.entries) e.key: segLabel(e.value),
            },
          )
        : SegmentedButton<OverlayMode>(
            segments: [
              for (final e in labels.entries)
                ButtonSegment<OverlayMode>(
                  value: e.key,
                  label: segLabel(e.value),
                ),
            ],
            selected: {mode},
            onSelectionChanged: (set) {
              if (set.isNotEmpty) onChanged(set.first);
            },
            style: const ButtonStyle(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Align(alignment: Alignment.centerLeft, child: control),
    );
  }
}
