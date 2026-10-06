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
      variants: [],
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
      variants: [],
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

  group('per-variant reporting', () {
    Map<String, dynamic> payload({List<Map<String, dynamic>>? variants}) => {
      'installed': true,
      'modelBytes': 1200,
      'compiledCacheBytes': 24,
      'modelPath': '/tmp/Models',
      'variant': 'openai_whisper-large-v3-v20240930_626MB',
      if (variants != null) 'variants': variants,
      'busy': false,
      'loaded': false,
    };

    test('parses the variant list', () {
      final info = CaptionModelInfo.fromMap(
        payload(
          variants: [
            {
              'variant': 'openai_whisper-large-v3-v20240930_626MB',
              'bytes': 600,
              'complete': true,
            },
            {'variant': 'openai_whisper-tiny', 'bytes': 75, 'complete': false},
          ],
        ),
      );
      expect(info.variants, hasLength(2));
      expect(info.variants.first.bytes, 600);
      expect(info.variants.first.complete, isTrue);
      expect(info.variants.last.complete, isFalse);
      expect(info.hasMultipleVariants, isTrue);
    });

    /// Older payloads and the Windows stub send no list. Empty is the honest
    /// reading, and it must not throw into the settings page.
    test('an absent or malformed list reads as empty', () {
      expect(CaptionModelInfo.fromMap(payload()).variants, isEmpty);
      expect(
        CaptionModelInfo.fromMap({
          ...payload(),
          'variants': 'nonsense',
        }).variants,
        isEmpty,
      );
      expect(
        CaptionModelInfo.fromMap({
          ...payload(),
          'variants': [42, 'x'],
        }).variants,
        isEmpty,
        reason: 'non-map entries are skipped rather than crashing the parse',
      );
      expect(CaptionModelInfo.fromMap(payload()).hasMultipleVariants, isFalse);
    });

    /// The figure the delete dialog quotes. `modelBytes` is the whole tree, so
    /// with two models on disk it roughly doubles what a re-download fetches.
    test('activeVariantBytes is the active model, not the root total', () {
      final info = CaptionModelInfo.fromMap(
        payload(
          variants: [
            {
              'variant': 'openai_whisper-large-v3-v20240930_626MB',
              'bytes': 600,
              'complete': true,
            },
            {'variant': 'openai_whisper-tiny', 'bytes': 75, 'complete': true},
          ],
        ),
      );
      expect(info.modelBytes, 1200, reason: 'the root holds both');
      expect(
        info.activeVariantBytes,
        600,
        reason: 'but one would be refetched',
      );
    });

    test('activeVariantBytes is null when the active model is not on disk', () {
      final info = CaptionModelInfo.fromMap(
        payload(
          variants: [
            {'variant': 'openai_whisper-tiny', 'bytes': 75, 'complete': true},
          ],
        ),
      );
      expect(
        info.activeVariantBytes,
        isNull,
        reason: 'the caller falls back to the root total in this case',
      );
    });

    test(
      'displayName drops the vendor prefix and keeps what distinguishes',
      () {
        const v = CaptionModelVariant(
          variant: 'openai_whisper-large-v3-v20240930_626MB',
          bytes: 1,
          complete: true,
        );
        expect(v.displayName, 'large-v3-v20240930_626MB');
        // An unprefixed name is left alone rather than mangled.
        const other = CaptionModelVariant(
          variant: 'custom-build',
          bytes: 1,
          complete: true,
        );
        expect(other.displayName, 'custom-build');
      },
    );

    test('variants participate in equality', () {
      final a = CaptionModelInfo.fromMap(
        payload(
          variants: [
            {'variant': 'x', 'bytes': 1, 'complete': true},
          ],
        ),
      );
      final b = CaptionModelInfo.fromMap(
        payload(
          variants: [
            {'variant': 'x', 'bytes': 2, 'complete': true},
          ],
        ),
      );
      expect(a, isNot(equals(b)));
      expect(a.hashCode, isNot(equals(b.hashCode)));
    });
  });
}
