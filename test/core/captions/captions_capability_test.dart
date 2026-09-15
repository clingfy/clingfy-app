import 'package:clingfy/core/captions/captions_capability.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the Dart half of the `captionsCapability` wire contract.
///
/// The Swift half is pinned by `CaptionsCapabilityTests`, and the Windows
/// router emits the same keys. Three implementations of one shape, where a
/// rename on any side silently disables captions rather than failing loudly —
/// so both ends assert the literal strings.
void main() {
  group('parsing a native reply', () {
    test('reads an available reply with both sources', () {
      final info = CaptionsCapabilityInfo.fromMap({
        'available': true,
        'hasMicAudio': true,
        'hasSystemAudio': true,
        'usesEmbeddedAudioOnly': false,
      });
      expect(info.available, isTrue);
      expect(info.reason, isNull);
      expect(info.hasMicAudio, isTrue);
      expect(info.hasSystemAudio, isTrue);
    });

    test('maps every reason native can send', () {
      for (final wire in [
        'unsupportedOS',
        'intelSlowPath',
        'noAudio',
        'platformNotSupported',
      ]) {
        final info = CaptionsCapabilityInfo.fromMap({
          'available': false,
          'reason': wire,
        });
        expect(
          info.reason!.wireValue,
          wire,
          reason: 'reason "$wire" did not round-trip',
        );
        expect(info.reason, isNot(CaptionsUnavailableReason.unknown));
      }
    });

    /// An older Flutter against a newer native binary must degrade, not throw.
    test('an unrecognised reason becomes unknown rather than crashing', () {
      final info = CaptionsCapabilityInfo.fromMap({
        'available': false,
        'reason': 'somethingAddedLater',
      });
      expect(info.reason, CaptionsUnavailableReason.unknown);
      expect(info.available, isFalse);
    });

    test('a malformed reply is treated as unavailable', () {
      final info = CaptionsCapabilityInfo.fromMap(<dynamic, dynamic>{});
      expect(info.available, isFalse);
      expect(info.hasMicAudio, isFalse);
      expect(info.hasSystemAudio, isFalse);
    });

    /// Windows sends exactly this. It is a real reply, not a missing method —
    /// an unhandled method throws MissingPluginException, which reaches the
    /// user as a crash-shaped error instead of an explanation.
    test('parses the Windows reply', () {
      final info = CaptionsCapabilityInfo.fromMap({
        'available': false,
        'reason': 'platformNotSupported',
        'hasMicAudio': false,
        'hasSystemAudio': false,
        'usesEmbeddedAudioOnly': false,
      });
      expect(info.available, isFalse);
      expect(info.reason, CaptionsUnavailableReason.platformNotSupported);
    });
  });

  group('source defaults', () {
    CaptionsCapabilityInfo info({
      bool mic = false,
      bool system = false,
      bool embedded = false,
    }) => CaptionsCapabilityInfo(
      available: true,
      hasMicAudio: mic,
      hasSystemAudio: system,
      usesEmbeddedAudioOnly: embedded,
    );

    /// The owner's call: meetings, demos and tutorials are the common case and
    /// both sides matter there.
    test('both sources are on by default when both exist', () {
      final capability = info(mic: true, system: true);
      expect(capability.defaultUsesMic, isTrue);
      expect(capability.defaultUsesSystem, isTrue);
      expect(capability.shouldOfferSourcePicker, isTrue);
    });

    test('a single source is chosen without offering a picker', () {
      expect(info(mic: true).shouldOfferSourcePicker, isFalse);
      expect(info(system: true).shouldOfferSourcePicker, isFalse);
    });

    test('a system-only recording does not default to the absent mic', () {
      final capability = info(system: true);
      expect(capability.defaultUsesMic, isFalse);
      expect(capability.defaultUsesSystem, isTrue);
    });

    /// On a pre-macOS-15 recording the embedded audio is the microphone alone,
    /// because that capture backend never recorded system audio.
    test('embedded-only audio counts as the microphone', () {
      final capability = info(embedded: true);
      expect(capability.defaultUsesMic, isTrue);
      expect(capability.defaultUsesSystem, isFalse);
      expect(capability.shouldOfferSourcePicker, isFalse);
    });
  });

  group('wire values', () {
    /// These strings cross the bridge from two different native
    /// implementations. Changing one is a breaking change, not a rename.
    test('are stable', () {
      expect(
        CaptionsUnavailableReason.unsupportedOs.wireValue,
        'unsupportedOS',
      );
      expect(
        CaptionsUnavailableReason.intelSlowPath.wireValue,
        'intelSlowPath',
      );
      expect(CaptionsUnavailableReason.noAudio.wireValue, 'noAudio');
      expect(
        CaptionsUnavailableReason.platformNotSupported.wireValue,
        'platformNotSupported',
      );
    });
  });

  test('the unsupported fallback is unavailable with a reason', () {
    expect(CaptionsCapabilityInfo.unsupported.available, isFalse);
    expect(
      CaptionsCapabilityInfo.unsupported.reason,
      CaptionsUnavailableReason.platformNotSupported,
    );
  });
}
