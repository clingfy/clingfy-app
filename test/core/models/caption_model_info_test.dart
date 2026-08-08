import 'package:clingfy/core/models/caption_model_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// Parsing the speech-model payload.
///
/// This only ever feeds a settings card, so every failure mode here should
/// degrade to "nothing installed" rather than throw — a storage page that
/// cannot render is a worse outcome than a missing row.
void main() {
  test('a full payload parses every field', () {
    final info = CaptionModelInfo.fromMap(const {
      'installed': true,
      'modelBytes': 629485189,
      'compiledCacheBytes': 271581184,
      'modelPath': '/Users/x/Library/Application Support/app/Models',
      'variant': 'openai_whisper-large-v3-v20240930_626MB',
      'busy': false,
      'loaded': true,
    });

    expect(info.installed, isTrue);
    expect(info.modelBytes, 629485189);
    expect(info.compiledCacheBytes, 271581184);
    expect(info.loaded, isTrue);
    expect(info.canDelete, isTrue);
  });

  test('the total spans both buckets, not just the weights', () {
    // The compiled cache was a third of the real footprint. Reporting only the
    // weights would understate what a delete frees by that much.
    const info = CaptionModelInfo(
      installed: true,
      modelBytes: 600,
      compiledCacheBytes: 259,
      modelPath: '/m',
      variant: 'v',
      busy: false,
      loaded: false,
    );
    expect(info.totalBytes, 859);
  });

  test('a null or malformed payload reads as nothing installed', () {
    expect(CaptionModelInfo.fromMap(null), CaptionModelInfo.notInstalled);
    expect(CaptionModelInfo.fromMap(const {}).installed, isFalse);
    expect(CaptionModelInfo.fromMap(const {}).totalBytes, 0);
    // Wrong types, not just missing keys: native could be an older build.
    expect(
      CaptionModelInfo.fromMap(const {'modelBytes': 'not a number'}).modelBytes,
      0,
    );
    expect(
      CaptionModelInfo.fromMap(const {'installed': 'yes'}).installed,
      isFalse,
    );
    expect(CaptionModelInfo.fromMap(const {'modelPath': 42}).modelPath, '');
  });

  test('a busy model cannot be deleted, however big it is', () {
    const info = CaptionModelInfo(
      installed: true,
      modelBytes: 629485189,
      compiledCacheBytes: 0,
      modelPath: '/m',
      variant: 'v',
      busy: true,
      loaded: true,
    );
    expect(
      info.canDelete,
      isFalse,
      reason: 'deleting under a live transcription frees nothing and lies',
    );
  });

  test('an empty install is not deletable either', () {
    expect(CaptionModelInfo.notInstalled.canDelete, isFalse);
  });
}
