import 'package:clingfy/core/models/app_models.dart';

/// Localized words the label builder needs. Injected rather than imported so
/// this file stays free of `flutter/*` and of `AppLocalizations` — `lib/core`
/// must not reach into `lib/app`.
class DisplayLabelStrings {
  const DisplayLabelStrings({
    required this.screenWord,
    required this.mainMarker,
    required this.thisWindowMarker,
  });

  /// Fallback base name when the OS gave us nothing usable, e.g. "Screen".
  final String screenWord;

  /// Marker for the system's primary display, e.g. "Main".
  final String mainMarker;

  /// Marker for the display hosting the Clingfy window, e.g. "This window".
  final String thisWindowMarker;
}

/// One rendered picker row.
class DisplayLabelRow {
  const DisplayLabelRow({
    required this.id,
    required this.ordinal,
    required this.label,
    required this.detail,
  });

  final int id;

  /// The number the identify overlay paints on this physical display.
  final int ordinal;

  /// e.g. `2. DELL U2720Q — Main · This window`
  final String label;

  /// e.g. `(2560×1440 @2.0x)`
  final String detail;
}

/// Composes the display-picker rows.
///
/// ORDINAL COHERENCE: every label is prefixed with its own [DisplayLabelRow
/// .ordinal], and that ordinal comes from the same native enumeration that
/// paints the identify overlay. The number on the glass and the number in the
/// row cannot disagree.
abstract class DisplayLabelBuilder {
  static List<DisplayLabelRow> build(
    List<DisplayInfo> displays,
    DisplayLabelStrings strings,
  ) {
    if (displays.isEmpty) return const <DisplayLabelRow>[];

    // Native emits the list already sorted by ordinal. A binary that predates
    // the feature sends no ordinal at all; keep its own enumeration order and
    // number by position rather than inventing an ordering it does not share.
    final hasOrdinals = displays.every((d) => d.ordinal != null);
    final ordered = hasOrdinals
        ? (List<DisplayInfo>.of(displays)
            ..sort((a, b) => a.ordinal!.compareTo(b.ordinal!)))
        : displays;

    final rows = <DisplayLabelRow>[];
    for (var i = 0; i < ordered.length; i++) {
      final display = ordered[i];
      final ordinal = hasOrdinals ? display.ordinal! : i + 1;

      // Native already normalised placeholders away; trim defensively so a
      // whitespace-only name from a legacy binary cannot render as a blank row.
      final osName = display.osName?.trim();
      final base = (osName == null || osName.isEmpty)
          ? strings.screenWord
          : osName;

      final markers = <String>[
        if (display.isPrimary) strings.mainMarker,
        if (display.isAppWindowHost) strings.thisWindowMarker,
      ];

      final buffer = StringBuffer('$ordinal. $base');
      if (markers.isNotEmpty) {
        buffer.write(' — ${markers.join(' · ')}');
      }

      rows.add(
        DisplayLabelRow(
          id: display.id,
          ordinal: ordinal,
          label: buffer.toString(),
          // Unchanged from the pre-existing format, deliberately.
          detail:
              '(${display.width.toInt()}×${display.height.toInt()} @${display.scale}x)',
        ),
      );
    }
    return rows;
  }

  /// The `labels` argument for `identifyDisplays`: stringified id -> label.
  static Map<String, String> labelArgs(List<DisplayLabelRow> rows) => {
    for (final row in rows) row.id.toString(): row.label,
  };
}
