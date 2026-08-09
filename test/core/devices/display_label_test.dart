import 'package:clingfy/core/devices/display_label.dart';
import 'package:clingfy/core/models/app_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _strings = DisplayLabelStrings(
  screenWord: 'Screen',
  mainMarker: 'Main',
  thisWindowMarker: 'This window',
);

DisplayInfo _display({
  required int id,
  int? ordinal,
  String? osName,
  double width = 2560,
  double height = 1440,
  double scale = 2,
  bool isPrimary = false,
  bool isAppWindowHost = false,
}) => DisplayInfo(
  id: id,
  name: 'ignored',
  x: 0,
  y: 0,
  width: width,
  height: height,
  scale: scale,
  ordinal: ordinal,
  osName: osName,
  isPrimary: isPrimary,
  isAppWindowHost: isAppWindowHost,
);

void main() {
  group('DisplayLabelBuilder', () {
    test('ordinals come from native when present', () {
      final rows = DisplayLabelBuilder.build([
        _display(id: 30, ordinal: 3, osName: 'C'),
        _display(id: 10, ordinal: 1, osName: 'A'),
        _display(id: 20, ordinal: 2, osName: 'B'),
      ], _strings);

      expect(rows.map((r) => r.ordinal), [1, 2, 3]);
      expect(rows.map((r) => r.id), [10, 20, 30]);
      expect(rows[0].label, startsWith('1. '));
      expect(rows[1].label, startsWith('2. '));
      expect(rows[2].label, startsWith('3. '));
    });

    test('falls back to list position when native omits the ordinal', () {
      final rows = DisplayLabelBuilder.build([
        _display(id: 30, osName: 'C'),
        _display(id: 10, osName: 'A'),
      ], _strings);

      // Input order preserved — a legacy binary has its own enumeration order
      // and we must not invent a different one.
      expect(rows.map((r) => r.id), [30, 10]);
      expect(rows[0].label, '1. C');
      expect(rows[1].label, '2. A');
    });

    test('a null osName falls back to the localized screen word', () {
      final rows = DisplayLabelBuilder.build(
        [_display(id: 1, ordinal: 2, osName: null)],
        const DisplayLabelStrings(
          screenWord: 'Ecran',
          mainMarker: 'Principal',
          thisWindowMarker: 'Fereastra',
        ),
      );

      expect(rows.single.label, '2. Ecran');
    });

    test('a whitespace-only osName is treated as null', () {
      final rows = DisplayLabelBuilder.build([
        _display(id: 1, ordinal: 1, osName: '   '),
      ], _strings);

      expect(rows.single.label, '1. Screen');
    });

    test('two monitors with the same OS name get distinct labels', () {
      final rows = DisplayLabelBuilder.build([
        _display(id: 1, ordinal: 2, osName: 'DELL U2720Q'),
        _display(id: 2, ordinal: 3, osName: 'DELL U2720Q'),
      ], _strings);

      expect(rows[0].label, '2. DELL U2720Q');
      expect(rows[1].label, '3. DELL U2720Q');
      expect(rows.map((r) => r.label).toSet().length, 2);
    });

    test('the primary display is marked', () {
      final rows = DisplayLabelBuilder.build([
        _display(id: 1, ordinal: 1, osName: 'Studio Display', isPrimary: true),
      ], _strings);

      expect(rows.single.label, '1. Studio Display — Main');
    });

    test('the app-window host is marked', () {
      final rows = DisplayLabelBuilder.build([
        _display(
          id: 1,
          ordinal: 1,
          osName: 'Studio Display',
          isAppWindowHost: true,
        ),
      ], _strings);

      expect(rows.single.label, '1. Studio Display — This window');
    });

    test('both markers render in a fixed order', () {
      final rows = DisplayLabelBuilder.build([
        _display(
          id: 1,
          ordinal: 1,
          osName: 'Built-in Retina Display',
          isPrimary: true,
          isAppWindowHost: true,
        ),
      ], _strings);

      expect(
        rows.single.label,
        '1. Built-in Retina Display — Main · This window',
      );
    });

    test('no markers means no em dash', () {
      final rows = DisplayLabelBuilder.build([
        _display(id: 1, ordinal: 1, osName: 'Studio Display'),
      ], _strings);

      expect(rows.single.label.contains('—'), isFalse);
    });

    test('the detail keeps the existing resolution format', () {
      final rows = DisplayLabelBuilder.build([
        _display(id: 1, ordinal: 1, width: 2560, height: 1440, scale: 2),
      ], _strings);

      expect(rows.single.detail, '(2560×1440 @2.0x)');
    });

    test('every label starts with its own ordinal', () {
      // The coherence invariant, as an executable assertion.
      final rows = DisplayLabelBuilder.build([
        _display(id: 1, ordinal: 1, osName: 'A'),
        _display(id: 2, ordinal: 2, osName: null),
        _display(id: 3, ordinal: 3, osName: 'C', isPrimary: true),
        _display(id: 4, ordinal: 4, osName: 'D', isAppWindowHost: true),
      ], _strings);

      expect(rows.every((r) => r.label.startsWith('${r.ordinal}. ')), isTrue);
    });

    test('an empty display list yields no rows', () {
      expect(DisplayLabelBuilder.build(const [], _strings), isEmpty);
    });

    test('labelArgs keys by stringified id', () {
      final rows = DisplayLabelBuilder.build([
        _display(id: 7, ordinal: 1, osName: 'A'),
        _display(id: 9, ordinal: 2, osName: 'B'),
      ], _strings);

      expect(DisplayLabelBuilder.labelArgs(rows), {'7': '1. A', '9': '2. B'});
    });
  });
}
