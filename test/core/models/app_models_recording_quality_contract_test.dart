import 'package:clingfy/core/models/app_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RecordingQuality names and order match the Swift wire contract', () {
    // Mirror of `enum RecordingQuality: String` in
    // macos/Runner/Core/Models.swift — case names are the wire values.
    expect(RecordingQuality.values.map((q) => q.name).toList(), const [
      'sd',
      'hd720',
      'fhd',
      'uhd2k',
      'uhd4k',
      'uhd8k',
      'vertical4k',
      'native',
    ]);
  });
}
