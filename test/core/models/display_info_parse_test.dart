import 'package:clingfy/core/models/app_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DisplayInfo.fromMap', () {
    test('a legacy 7-key payload parses without throwing', () {
      final info = DisplayInfo.fromMap({
        'id': 3,
        'name': 'Screen 1',
        'x': 0.0,
        'y': 0.0,
        'width': 1512.0,
        'height': 982.0,
        'scale': 2.0,
      });

      expect(info.id, 3);
      expect(info.name, 'Screen 1');
      expect(info.ordinal, isNull);
      expect(info.osName, isNull);
      expect(info.isPrimary, isFalse);
      expect(info.isAppWindowHost, isFalse);
    });

    test('a missing name no longer throws', () {
      final info = DisplayInfo.fromMap({
        'id': 3,
        'x': 0.0,
        'y': 0.0,
        'width': 1.0,
        'height': 1.0,
        'scale': 1.0,
      });

      expect(info.name, '');
    });

    test('missing geometry falls back instead of throwing', () {
      final info = DisplayInfo.fromMap({'id': 9});

      expect(info.x, 0);
      expect(info.y, 0);
      expect(info.width, 0);
      expect(info.height, 0);
      expect(info.scale, 1);
    });

    test('a full payload round-trips every field', () {
      final info = DisplayInfo.fromMap({
        'id': 42,
        'name': '2. DELL U2720Q',
        'x': 1512.0,
        'y': -120.0,
        'width': 2560.0,
        'height': 1440.0,
        'scale': 2.0,
        'ordinal': 2,
        'osName': 'DELL U2720Q',
        'isPrimary': true,
        'isAppWindowHost': true,
      });

      expect(info.id, 42);
      expect(info.name, '2. DELL U2720Q');
      expect(info.x, 1512.0);
      expect(info.y, -120.0);
      expect(info.width, 2560.0);
      expect(info.height, 1440.0);
      expect(info.scale, 2.0);
      expect(info.ordinal, 2);
      expect(info.osName, 'DELL U2720Q');
      expect(info.isPrimary, isTrue);
      expect(info.isAppWindowHost, isTrue);
    });

    test('an empty osName becomes null', () {
      expect(DisplayInfo.fromMap({'id': 1, 'osName': ''}).osName, isNull);
      expect(DisplayInfo.fromMap({'id': 1, 'osName': '   '}).osName, isNull);
    });

    test('tryFromMap returns null instead of throwing without an id', () {
      expect(DisplayInfo.tryFromMap({'name': '1. Screen'}), isNull);
      expect(DisplayInfo.tryFromMap({'id': 'not-a-number'}), isNull);
      expect(DisplayInfo.tryFromMap({'id': 4})?.id, 4);
    });

    test('equality is by value', () {
      Map<String, Object?> payload() => {
        'id': 1,
        'name': '1. Studio Display',
        'x': 0.0,
        'y': 0.0,
        'width': 5120.0,
        'height': 2880.0,
        'scale': 2.0,
        'ordinal': 1,
        'osName': 'Studio Display',
        'isPrimary': true,
        'isAppWindowHost': false,
      };

      final a = DisplayInfo.fromMap(payload());
      final b = DisplayInfo.fromMap(payload());
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));

      final c = DisplayInfo.fromMap(payload()..['ordinal'] = 2);
      expect(a, isNot(equals(c)));
    });
  });
}
