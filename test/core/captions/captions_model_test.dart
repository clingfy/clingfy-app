import 'package:clingfy/core/captions/captions_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// The speech models the picker offers.
///
/// These strings are WhisperKit variant ids that native downloads verbatim, so
/// a typo is not a cosmetic bug: it is a 404 on the hub, or worse, a valid id
/// for the wrong thing.
void main() {
  /// The default must be the model every existing user already has, so nobody's
  /// transcripts change and nobody is made to download anything on upgrade.
  test('the default is the model that shipped before the picker', () {
    expect(CaptionsModel.best.wire, 'openai_whisper-large-v3-v20240930_626MB');
    expect(CaptionsModel.fromWire(null), CaptionsModel.best);
  });

  test('wire values round-trip', () {
    for (final m in CaptionsModel.values) {
      expect(CaptionsModel.fromWire(m.wire), m);
    }
  });

  /// A value written by a newer build, or garbage, degrades to the model
  /// everybody already had — never to a smaller one they did not choose.
  test('an unknown value reads as the default', () {
    expect(CaptionsModel.fromWire('openai_whisper-medium'), CaptionsModel.best);
    expect(CaptionsModel.fromWire(''), CaptionsModel.best);
    expect(CaptionsModel.fromWire('nonsense'), CaptionsModel.best);
  });

  /// In WhisperKit a `_turbo` SUFFIX means an extra context-prefill model, not
  /// OpenAI's turbo release, and those variants are dead download weight. Eight
  /// of the hub's twenty-three carry it, so this is not a hypothetical guard.
  test('no offered model carries the _turbo suffix', () {
    for (final m in CaptionsModel.values) {
      expect(
        m.wire.endsWith('_turbo') || m.wire.contains('_turbo_'),
        isFalse,
        reason: '${m.wire} is the context-prefill build, not the turbo release',
      );
    }
  });

  /// `.en` builds are English-only. Offering one would silently break the
  /// language control beside the picker: choose Arabic, get garbage.
  test('no offered model is English-only', () {
    for (final m in CaptionsModel.values) {
      expect(m.wire.contains('.en'), isFalse, reason: m.wire);
    }
  });

  test('every offered model is a plain WhisperKit variant id', () {
    // Mirrors native's guard (CaptionsService.isAcceptableVariant). A value that
    // failed it would be silently swapped for the default on the native side.
    final plain = RegExp(r'^openai_whisper-[A-Za-z0-9._-]+$');
    for (final m in CaptionsModel.values) {
      expect(plain.hasMatch(m.wire), isTrue, reason: m.wire);
      expect(m.wire.contains('..'), isFalse, reason: m.wire);
    }
  });

  test('the tiers get smaller as they get faster', () {
    expect(
      CaptionsModel.best.approxMegabytes,
      greaterThan(CaptionsModel.balanced.approxMegabytes),
    );
    expect(
      CaptionsModel.balanced.approxMegabytes,
      greaterThan(CaptionsModel.fast.approxMegabytes),
    );
  });
}
