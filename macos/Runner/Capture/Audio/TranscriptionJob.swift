import Foundation

/// Turns a project's audio sidecars into one ordered, non-overlapping cue list.
///
/// ```
///   capture/mic.m4a ──▶ transcribe ──┐
///                                     ├─▶ filter ─▶ dedup ─▶ merge ─▶ [Caption]
///   capture/system.m4a ─▶ transcribe ─┘   (guards)  (bleed)  (overlap)
/// ```
///
/// ## Why this is not on `AudioComputeQueue`
///
/// `AudioComputeQueue.swift:3-16` documents a serial queue whose accepted cost
/// is that "a synchronous caller (the export preamble) can wait behind an
/// unrelated in-flight pass". That bargain was struck for passes lasting
/// seconds. A transcription runs for minutes, and parking an export behind one
/// turns a deliberate memory bound into a frozen-looking app.
///
/// It also documents "**Never call one queue user from inside another**" — both
/// audio caches expose a blocking `outcome` that does `queue.sync`, so anything
/// running on that queue which asks for cleaned audio self-deadlocks with no
/// error. This job therefore runs on its own serial queue and takes already
/// resolved file URLs.
///
/// ## Why the RAW sidecars
///
/// ASR input is `capture/mic.m4a`, never the echo-cancelled or voice-cleaned
/// derivative. Those URLs flip between the raw file and `derived/*.caf`
/// depending on a **user preference toggle** and an algorithm version
/// (`CleanedMicCache.swift:109-118`), so keying transcription on them would
/// make the same recording transcribe differently after a settings change or an
/// app update. Non-deterministic captions in a paid product are worse than a
/// small accuracy delta.
///
/// ## The bleed rule, which is the reverse of the intuitive one
///
/// System audio is a clean digital tap and `excludesCurrentProcessAudio`
/// excludes only Clingfy's own process, so **the mic never leaks into the
/// system track; the system leaks into the mic** via the speakers. Measured on
/// real recordings: envelope correlation r ≈ 0.9 at a ~50 ms offset, with the
/// mic ~30 dB down. When the same sentence appears in both transcripts the
/// SYSTEM copy is kept and the MIC copy dropped, because the system copy came
/// from the clean source.
struct TranscriptionJob {

  struct Sources {
    /// Raw `capture/mic.m4a`, when present and decodable.
    var micURL: URL?
    /// Raw `capture/system.m4a`, when present and decodable.
    var systemURL: URL?
    /// Fallback when neither sidecar exists: audio embedded in `screen.mov`.
    ///
    /// Not an edge case. Sidecars are only written by the ScreenCaptureKit
    /// backend, which is `@available(macOS 15.0, *)`, so every recording made
    /// on macOS 13-14 has audio only inside `screen.mov` — and on that path the
    /// AVFoundation backend never captured system audio at all, so what is in
    /// there is the microphone alone.
    var embeddedURL: URL?

    var hasSeparatedSources: Bool { micURL != nil || systemURL != nil }
  }

  /// How close two cues must start, and how similar their text must be, before
  /// the mic copy is treated as bleed of the system copy.
  ///
  /// 1200 ms is generous against the ~50 ms acoustic offset measured on real
  /// recordings; the slack is for Whisper's segmentation jitter, which moves
  /// boundaries far more than the speakers do.
  static let bleedStartToleranceMs = 1200
  static let bleedSimilarityThreshold = 0.8

  let transcriber: CaptionTranscriber

  /// Runs the sources through the engine and returns merged cues.
  ///
  /// `progress` is reported across the whole job, so two sources each advance
  /// half of it. `isCancelled` is polled by the engine and between stages.
  func run(
    sources: Sources,
    micOptions: TranscriptionOptions = .default,
    systemOptions: TranscriptionOptions = .strict,
    progress: @escaping (TranscriptionProgress) -> Void,
    isCancelled: @escaping () -> Bool
  ) throws -> [Caption] {
    guard transcriber.availability.isAvailable else {
      throw TranscriptionError.unavailable(
        reason: {
          if case .unavailable(let reason) = transcriber.availability { return reason }
          return "unknown"
        }())
    }

    // Sub-ranges of the overall progress, so the UI moves smoothly rather than
    // resetting to zero when the second source starts.
    var passes: [(url: URL, options: TranscriptionOptions, source: CaptionSource)] = []
    if let micURL = sources.micURL {
      passes.append((micURL, micOptions, .mic))
    }
    if let systemURL = sources.systemURL {
      passes.append((systemURL, systemOptions, .system))
    }
    if passes.isEmpty, let embeddedURL = sources.embeddedURL {
      // Sub-15 recordings and legacy pre-separation bundles. Tagged `mic`
      // rather than `mixed` on the AVFoundation path because that backend never
      // captured system audio — what is in screen.mov is the microphone.
      passes.append((embeddedURL, micOptions, .mic))
    }
    guard !passes.isEmpty else { return [] }

    var micSegments: [TranscribedSegment] = []
    var systemSegments: [TranscribedSegment] = []

    for (index, pass) in passes.enumerated() {
      if isCancelled() { throw TranscriptionError.cancelled }
      let lower = Double(index) / Double(passes.count)
      let span = 1.0 / Double(passes.count)

      let raw: [TranscribedSegment]
      do {
        raw = try transcriber.transcribe(
          url: pass.url,
          options: pass.options,
          progress: { update in
            // Only transcription fractions belong to a source's sub-range. The
            // model download happens once for the whole job, so scaling it into
            // the first source's half would report 50% for a finished download.
            guard update.phase == .transcribing, let fraction = update.fraction else {
              progress(update)
              return
            }
            progress(.transcribing(lower + (fraction * span)))
          },
          isCancelled: isCancelled
        )
      } catch {
        // This is the seam where an engine's error becomes an engine-agnostic
        // one, so it is where the decode-error leak is stopped for EVERY
        // implementation rather than for the one that happens to ship today.
        // Above here, cancel-versus-failure is decided by `error as?
        // TranscriptionError` in three separate places; a `DecodeError` reaching
        // any of them reports the user's own Stop as a failure.
        throw TranscriptionError.normalizing(error)
      }
      let kept = Self.applyGuards(raw, options: pass.options)
      switch pass.source {
      case .mic, .mixed: micSegments = kept
      case .system: systemSegments = kept
      }
    }

    if isCancelled() { throw TranscriptionError.cancelled }
    let merged = Self.merge(mic: micSegments, system: systemSegments)
    progress(.transcribing(1.0))
    return merged
  }

  // MARK: - Guards

  /// Drops segments that are almost certainly hallucination or noise.
  ///
  /// Deliberately NOT a blacklist of known hallucinated strings ("Thank you.",
  /// "Subtitles by…"). Those lists are English-only and this app ships Arabic
  /// and Romanian, so a blacklist would silently protect one locale and not the
  /// others.
  static func applyGuards(
    _ segments: [TranscribedSegment], options: TranscriptionOptions
  ) -> [TranscribedSegment] {
    var kept: [TranscribedSegment] = []
    for segment in segments {
      let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.count < options.minimumCharacters { continue }
      if segment.durationMs < options.minimumDurationMs { continue }
      if let probability = segment.noSpeechProbability,
        probability > options.noSpeechThreshold
      {
        continue
      }
      if options.suppressRepeats, let previous = kept.last,
        segment.startMs - previous.startMs <= options.repetitionWindowMs,
        normalized(previous.text) == normalized(text)
      {
        continue
      }
      kept.append(
        TranscribedSegment(
          startMs: segment.startMs,
          endMs: segment.endMs,
          text: text,
          words: segment.words,
          noSpeechProbability: segment.noSpeechProbability
        ))
    }
    return kept
  }

  // MARK: - Merge

  /// Bleed dedup, then overlap resolution, into one sorted non-overlapping list.
  ///
  /// Resolving overlap HERE rather than at render time is what lets the export's
  /// cue cursor stay a simple forward scan instead of tracking a set of
  /// simultaneously active cues, and it guarantees burn-in and the `.srt`
  /// sidecar cannot disagree about what was on screen.
  static func merge(
    mic: [TranscribedSegment], system: [TranscribedSegment]
  ) -> [Caption] {
    // 1. Bleed: drop mic segments that duplicate a system segment.
    let micKept = mic.filter { micSegment in
      !system.contains { systemSegment in
        abs(micSegment.startMs - systemSegment.startMs) <= bleedStartToleranceMs
          && similarity(micSegment.text, systemSegment.text) >= bleedSimilarityThreshold
      }
    }

    // 2. Union and order.
    //
    // Written out longhand rather than as one chained expression: the inline
    // version tripped Swift's type-checker time limit, and a `Sourced` struct
    // reads better than a tuple of tuples anyway.
    struct Sourced {
      let segment: TranscribedSegment
      let source: CaptionSource
    }
    var pending: [Sourced] = []
    pending.reserveCapacity(micKept.count + system.count)
    for segment in micKept {
      pending.append(Sourced(segment: segment, source: .mic))
    }
    for segment in system {
      pending.append(Sourced(segment: segment, source: .system))
    }
    pending.sort { lhs, rhs in
      if lhs.segment.startMs != rhs.segment.startMs {
        return lhs.segment.startMs < rhs.segment.startMs
      }
      return lhs.segment.endMs < rhs.segment.endMs
    }

    // 3. Overlap resolution.
    var out: [Caption] = []
    var index = 0
    while index < pending.count {
      var segment = pending[index].segment
      let source = pending[index].source
      index += 1

      if var last = out.last, segment.startMs < last.endMs {
        let overlap = min(last.endMs, segment.endMs) - segment.startMs
        let shorter = min(last.endMs - last.startMs, segment.durationMs)
        if shorter > 0, Double(overlap) / Double(shorter) >= 0.5 {
          // Substantially simultaneous: one cue, two lines. This is what
          // meeting captions look like anyway.
          out.removeLast()
          last = Caption(
            id: last.id,
            startMs: min(last.startMs, segment.startMs),
            endMs: max(last.endMs, segment.endMs),
            text: "\(last.text)\n\(segment.text)",
            words: last.words + segment.words.map { $0 },
            source: last.source == source ? source : .mixed
          )
          out.append(last)
          continue
        }
        // Partial: push the later start, unless too little would survive.
        let survivingMs = segment.endMs - last.endMs
        if survivingMs < 700 {
          out.removeLast()
          out.append(
            Caption(
              id: last.id,
              startMs: last.startMs,
              endMs: max(last.endMs, segment.endMs),
              text: "\(last.text)\n\(segment.text)",
              words: last.words + segment.words.map { $0 },
              source: last.source == source ? source : .mixed
            ))
          continue
        }
        segment = TranscribedSegment(
          startMs: last.endMs,
          endMs: segment.endMs,
          text: segment.text,
          words: segment.words,
          noSpeechProbability: segment.noSpeechProbability
        )
      }

      out.append(
        Caption(
          id: "cue_\(out.count)",
          startMs: segment.startMs,
          endMs: segment.endMs,
          text: segment.text,
          words: segment.words,
          source: source
        ))
    }
    return out
  }

  // MARK: - Text comparison

  static func normalized(_ text: String) -> String {
    text.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  /// Token overlap (Jaccard), 0...1.
  ///
  /// Deliberately token-based rather than character-based: the bleed copy is
  /// the same words heard through speakers and a microphone, so it differs by
  /// whole misheard words far more often than by characters.
  static func similarity(_ a: String, _ b: String) -> Double {
    let left = Set(normalized(a).split(separator: " "))
    let right = Set(normalized(b).split(separator: " "))
    if left.isEmpty && right.isEmpty { return 1.0 }
    if left.isEmpty || right.isEmpty { return 0.0 }
    let intersection = left.intersection(right).count
    let union = left.union(right).count
    return Double(intersection) / Double(union)
  }
}

/// Which recorded source a cue came from. Stored, not rendered.
///
/// Speaker labels ("You" / "Screen") are deliberately not shipped: they are
/// wrong for the primary use case, since in a meeting the system track is *the
/// other participants* rather than "the screen", and they would need three
/// localizations plus RTL placement.
enum CaptionSource: String, Equatable {
  case mic
  case system
  case mixed
}

/// A merged cue, ready to hand to the rasterizer.
struct Caption: Equatable {
  let id: String
  let startMs: Int
  let endMs: Int
  let text: String
  let words: [TranscribedWord]
  let source: CaptionSource

  func toFlutter() -> [String: Any] {
    [
      "id": id,
      "startMs": startMs,
      "endMs": endMs,
      "text": text,
      "source": source.rawValue,
      "words": words.map {
        ["text": $0.text, "startMs": $0.startMs, "endMs": $0.endMs]
      },
    ]
  }
}
