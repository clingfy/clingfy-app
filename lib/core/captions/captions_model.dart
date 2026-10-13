/// Which on-device speech model transcribes a recording.
///
/// A PERSISTED preference, not per-recording (docs/editing-platform-plan.md
/// §A.7.1). The language control beside it is per-recording because its reset
/// target, Auto, is correct for every recording; a model has no such value, and
/// resetting it would silently revert a deliberate choice to a 626 MB download.
///
/// [wire] is the exact WhisperKit variant id native loads. These are checked
/// against the hub, not written from memory, because two traps sit right next
/// to the right answers:
///
/// - A `_turbo` SUFFIX is WhisperKit's extra context-prefill build, not OpenAI's
///   turbo release, and it is dead download weight. Eight of the hub's
///   twenty-three variants carry it. [best] IS the turbo release and has no
///   suffix.
/// - `.en` builds are English-only. Offering one would silently break the
///   language control next to this picker, so none are listed.
///
/// Native refuses anything outside a plain-name pattern regardless, falling back
/// to the default — see `CaptionsService.resolvedVariant`.
enum CaptionsModel {
  /// Today's model, and the default, so nobody's transcripts change on upgrade.
  best('openai_whisper-large-v3-v20240930_626MB', approxMegabytes: 626),
  balanced('openai_whisper-small_216MB', approxMegabytes: 216),
  fast('openai_whisper-tiny', approxMegabytes: 75);

  const CaptionsModel(this.wire, {required this.approxMegabytes});

  final String wire;

  /// Rough download size, for the label. Display only — the real figure is what
  /// lands on disk, which the Storage card reports per variant.
  final int approxMegabytes;

  /// Unknown values read as [best], so a preference written by a newer build
  /// degrades to the model everybody already had rather than to a smaller one.
  static CaptionsModel fromWire(String? raw) =>
      values.firstWhere((m) => m.wire == raw, orElse: () => best);
}
