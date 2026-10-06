import Foundation

/// What the speech model costs on disk, and how to get it back.
///
/// The model is a dependency, not the user's data: several hundred megabytes
/// arrive on first transcription and nothing in the app has ever shown them or
/// offered to remove them. It is deliberately kept out of the storage snapshot's
/// "Total Clingfy usage" for the same reason — re-downloadable weights are not
/// recordings, and folding them in would make that number jump by the better
/// part of a gigabyte the first time somebody captions something (600 MB of
/// weights on this machine, plus the tokenizer repo beside them).
enum CaptionModelStore {

  /// One Whisper variant as it exists on disk.
  ///
  /// Models are variant-scoped: WhisperKit downloads into
  /// `Models/models/argmaxinc/whisperkit-coreml/<variant>/`, so a second
  /// variant lands BESIDE the first rather than replacing it. Before this
  /// existed, nothing in the app could tell one from the other — the Storage
  /// card measured the whole `Models/` tree as a single number, so switching
  /// models would have left the user carrying both with no way to see it.
  struct VariantInfo {
    let variant: String

    /// This variant's own folder, excluding the tokenizer repo that sits
    /// outside it and the app-wide compiled cache. So the variants do NOT sum
    /// to `modelBytes`; see [info].
    let bytes: Int64

    /// Whether the engine could actually LOAD this variant, by the same rule
    /// `WhisperKitTranscriber` uses before deciding to skip a download: all
    /// three compiled bundles plus `config.json`.
    ///
    /// Distinct from the root-level `installed` on purpose. `installed` means
    /// "there are bytes here to free"; this means "picking it will not start a
    /// download". An interrupted download is `installed` and NOT `complete`,
    /// and a picker that confused the two would tell the user nothing needs
    /// fetching right before spending minutes fetching 626 MB.
    let complete: Bool

    func toFlutter() -> [String: Any] {
      ["variant": variant, "bytes": Int(bytes), "complete": complete]
    }
  }

  struct Info {
    /// Whether there are bytes here to report and to free — keyed off bytes,
    /// never directory existence, because an empty `Models/` folder is not an
    /// installed model and something else may well have created it.
    ///
    /// NOT the same question as `WhisperKitTranscriber.existingModelFolder()`,
    /// which is stricter: it requires all three compiled bundles plus
    /// `config.json` and answers "can the engine load this". The two disagree
    /// for exactly one state, a half-finished download, and both are right for
    /// their own purpose — this one says "300 MB you can delete", that one says
    /// "not loadable, fetch again". The engine repairs such a folder on the next
    /// Generate, so the disagreement is not a stuck state, and the Storage card
    /// never claims readiness: it shows the byte count and a Delete button,
    /// both of which are true of a partial download.
    ///
    /// Do not unify them. Making this one stricter would hide the Delete button
    /// for the one state where there are real bytes and no way for the user to
    /// reclaim them.
    let installed: Bool
    let modelBytes: Int64
    let compiledCacheBytes: Int64
    let modelPath: String

    /// The variant the engine would use. Reported so the UI can say which of
    /// [variants] is the active one.
    let variant: String

    /// Every variant found on disk, newest-first by nothing in particular —
    /// the order is whatever the filesystem enumerated. May be EMPTY while
    /// `installed` is true: a download interrupted before it created the
    /// variant folder leaves bytes in the tokenizer repo with no variant yet.
    let variants: [VariantInfo]

    var totalBytes: Int64 { modelBytes + compiledCacheBytes }

    func toFlutter(busy: Bool, loaded: Bool) -> [String: Any] {
      [
        "installed": installed,
        "modelBytes": Int(modelBytes),
        "compiledCacheBytes": Int(compiledCacheBytes),
        "modelPath": modelPath,
        "variant": variant,
        "variants": variants.map { $0.toFlutter() },
        "busy": busy,
        "loaded": loaded,
      ]
    }
  }

  /// The three compiled bundles `WhisperKit.loadModels` resolves, by name.
  ///
  /// Lives here rather than on the transcriber because TWO callers need it now:
  /// the engine, to decide whether to skip a download, and this store, to tell
  /// the UI which variants are usable. `WhisperKitTranscriber` delegates to
  /// [isCompleteModel] so there is exactly one answer to "is this variant
  /// installed" — the alternative is two copies that drift, and the drift would
  /// be invisible until a picker offered a variant the engine then refetched.
  static let requiredModelBundles = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

  /// Where WhisperKit puts variants: `Models/models/argmaxinc/whisperkit-coreml`.
  ///
  /// Mirrors `WhisperKitTranscriber.localModelFolder` minus the trailing
  /// variant component. Read-only: it never creates anything, for the same
  /// reason `captionModelsDirectoryURLIfPresent` does not.
  static func variantsRootURL() -> URL {
    AppPaths.captionModelsDirectoryURLIfPresent()
      .appendingPathComponent("models", isDirectory: true)
      .appendingPathComponent("argmaxinc", isDirectory: true)
      .appendingPathComponent("whisperkit-coreml", isDirectory: true)
  }

  /// Whether `folder` holds a model the engine can load: all three compiled
  /// bundles plus the variant's `config.json`.
  ///
  /// The strictness is load-bearing and was a bug fix. A single `.mlmodelc`
  /// match used to be enough, which turned an interrupted first download into a
  /// permanent failure: stop after `AudioEncoder.mlmodelc` lands and before the
  /// other two, and the next Generate saw one bundle, SKIPPED the fetch meant to
  /// repair it, and built the config with `download: false` — so `loadModels`
  /// threw on the missing `MelSpectrogram` every time, unrecoverably.
  static func isCompleteModel(at folder: URL) -> Bool {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return false }
    for name in requiredModelBundles {
      guard compiledModelExists(inFolder: folder, named: name) else { return false }
    }
    return fm.fileExists(atPath: folder.appendingPathComponent("config.json").path)
  }

  /// Mirrors `ModelUtilities.detectModelURL(inFolder:named:)`: a compiled
  /// `<name>.mlmodelc`, or an uncompiled `<name>.mlpackage` whose Core ML
  /// payload is on disk.
  ///
  /// Reimplemented rather than called because that helper returns a URL whether
  /// or not anything is there — it is a path builder, not an existence check —
  /// so asking it alone would answer "installed" for an empty folder.
  static func compiledModelExists(inFolder folder: URL, named name: String) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: folder.appendingPathComponent("\(name).mlmodelc").path) {
      return true
    }
    let packagePayload = folder
      .appendingPathComponent("\(name).mlpackage")
      .appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
    return fm.fileExists(atPath: packagePayload.path)
  }

  /// Every variant folder on disk, with its own size and whether it is usable.
  ///
  /// Returns empty when the root is absent, which is the common case: most users
  /// have never transcribed.
  ///
  /// `root` is injectable for tests only; production always passes the real
  /// one. It is a parameter rather than a hardcoded call because without it this
  /// function reads the developer's own installed model and cannot be tested at
  /// all — which is how a storage layer ends up wrong without anyone noticing.
  static func installedVariants(
    root: URL = variantsRootURL(), fileManager: FileManager = .default
  ) -> [VariantInfo] {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])
    else { return [] }
    return entries.compactMap { url in
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
      else { return nil }
      return VariantInfo(
        variant: url.lastPathComponent,
        bytes: directorySize(url, fileManager: fileManager),
        complete: isCompleteModel(at: url)
      )
    }
  }

  static func info(variant: String) -> Info {
    let modelsURL = AppPaths.captionModelsDirectoryURLIfPresent()
    let modelBytes = directorySize(modelsURL)
    return Info(
      installed: modelBytes > 0,
      modelBytes: modelBytes,
      compiledCacheBytes: directorySize(
        AppPaths.compiledModelCacheDirectoryURLIfPresent()),
      modelPath: modelsURL.path,
      variant: variant,
      variants: installedVariants()
    )
  }

  /// Removes both directories and returns what was measured immediately before.
  ///
  /// Measured before, not after, and measured with the same walk that deletes:
  /// reporting a number derived from a different set than the one removed is how
  /// a "freed" figure ends up describing bytes that are still on disk.
  ///
  /// Both directories here are Clingfy's own. The shared ANE cache that holds
  /// the real compiled bundles is deliberately not among them — see
  /// `AppPaths.compiledModelCacheDirectoryURLIfPresent` for why removing it
  /// would take other apps' models with it.
  @discardableResult
  static func delete() -> Int64 {
    var freed: Int64 = 0
    for url in [
      AppPaths.captionModelsDirectoryURLIfPresent(),
      AppPaths.compiledModelCacheDirectoryURLIfPresent(),
    ] {
      let size = directorySize(url)
      guard size > 0 || FileManager.default.fileExists(atPath: url.path) else { continue }
      do {
        try FileManager.default.removeItem(at: url)
        freed += size
      } catch {
        NativeLogger.e(
          "Captions", "Failed to remove \(url.lastPathComponent)",
          error: String(describing: error))
      }
    }
    return freed
  }

  /// Recursive allocated size, hidden entries INCLUDED.
  ///
  /// `StorageInfoProvider.directorySize` passes `.skipsHiddenFiles`, which is
  /// right for user-facing recordings and wrong here: the download cache lives
  /// in dot-directories, so skipping them would report less than `delete()`
  /// removes.
  static func directorySize(_ url: URL, fileManager: FileManager = .default) -> Int64 {
    guard fileManager.fileExists(atPath: url.path) else { return 0 }
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
    ]
    guard
      let enumerator = fileManager.enumerator(
        at: url, includingPropertiesForKeys: keys, options: [])
    else { return 0 }

    var total: Int64 = 0
    for case let entry as URL in enumerator {
      guard let values = try? entry.resourceValues(forKeys: Set(keys)),
        values.isRegularFile == true
      else { continue }
      let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
      total += Int64(size)
    }
    return total
  }
}
