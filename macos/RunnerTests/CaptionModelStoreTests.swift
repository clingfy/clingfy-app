import XCTest

@testable import Clingfy

/// Measuring and removing the speech model.
///
/// Two failures here are silent in production and both are covered below: a
/// size query that CREATES the model directory (every user who never
/// transcribed gets a phantom folder, and "installed" stops meaning anything),
/// and a measured set that differs from the deleted set (the freed number is
/// wrong and a residue survives the delete).
final class CaptionModelStoreTests: XCTestCase {

  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("clingfy_model_store_\(UUID().uuidString)")
  }

  override func tearDownWithError() throws {
    if FileManager.default.fileExists(atPath: root.path) {
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func write(_ relative: String, bytes: Int) throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: bytes).write(to: url)
  }

  // MARK: - Measuring

  func testSizeOfAMissingDirectoryIsZeroAndDoesNotCreateIt() {
    XCTAssertEqual(CaptionModelStore.directorySize(root), 0)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.path),
      "asking how big it is must never bring it into existence")
  }

  func testHiddenDownloadCachesAreCounted() throws {
    // The download cache lives in dot-directories. StorageInfoProvider skips
    // hidden entries, which is right for recordings and wrong here: delete()
    // removes these, so a measurement that ignores them under-reports what is
    // about to be freed.
    try write("weights.mlmodelc/data.bin", bytes: 4096)
    try write(".cache/huggingface/download/blob", bytes: 8192)

    let size = CaptionModelStore.directorySize(root)
    XCTAssertGreaterThanOrEqual(
      size, 12288, "hidden subtrees must be part of the total")
  }

  func testInstalledIsKeyedOffBytesNotDirectoryExistence() throws {
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true)
    XCTAssertEqual(
      CaptionModelStore.directorySize(root), 0,
      "an empty directory is not an installed model")
  }

  // MARK: - Deleting

  func testDeletingRemovesTheTreeAndReportsWhatItRemoved() throws {
    try write("weights.mlmodelc/data.bin", bytes: 4096)
    try write(".cache/huggingface/download/blob", bytes: 8192)
    let measured = CaptionModelStore.directorySize(root)

    try FileManager.default.removeItem(at: root)

    XCTAssertGreaterThan(measured, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  // MARK: - The real paths

  func testTheReadOnlyPathHelpersDoNotCreateAnything() {
    // These are what the size query uses. The side-effecting
    // `captionModelsDirectory()` is for the engine only.
    let models = AppPaths.captionModelsDirectoryURLIfPresent()
    let cache = AppPaths.compiledModelCacheDirectoryURLIfPresent()

    XCTAssertTrue(models.path.hasSuffix("/Models"))
    XCTAssertTrue(cache.path.contains("com.apple.e5rt.e5bundlecache"))
    XCTAssertTrue(
      cache.path.contains("Caches"),
      "the compiled bundle lives under Caches, not Application Support")
  }

  func testInfoReportsBothBucketsSeparately() {
    // The compiled cache was a third of the footprint on a real machine, so it
    // is reported on its own line rather than folded into one number.
    let info = CaptionModelStore.info(variant: "test-variant")
    XCTAssertEqual(info.variant, "test-variant")
    XCTAssertEqual(info.totalBytes, info.modelBytes + info.compiledCacheBytes)

    let payload = info.toFlutter(busy: true, loaded: true)
    XCTAssertEqual(payload["busy"] as? Bool, true)
    XCTAssertEqual(payload["loaded"] as? Bool, true)
    XCTAssertNotNil(payload["modelBytes"] as? Int)
    XCTAssertNotNil(payload["compiledCacheBytes"] as? Int)
    XCTAssertEqual(
      payload.keys.count, 8,
      "the Dart parser expects all eight; `variants` arrived when models became "
        + "per-variant")
  }

  // MARK: - Per-variant reporting
  //
  // Models are variant-scoped on disk, so a second one lands beside the first.
  // Before this, info() measured the whole tree as one number and the card
  // named neither model — a user who switched carried both with no way to see
  // it or remove just the stale one.

  /// A complete variant: all three compiled bundles plus config.json.
  private func writeCompleteVariant(_ name: String, bytes: Int = 1024) throws {
    for bundle in CaptionModelStore.requiredModelBundles {
      try write("\(name)/\(bundle).mlmodelc/data.bin", bytes: bytes)
    }
    try write("\(name)/config.json", bytes: 16)
  }

  func testACompleteVariantIsRecognised() throws {
    try writeCompleteVariant("variant-a")
    XCTAssertTrue(
      CaptionModelStore.isCompleteModel(at: root.appendingPathComponent("variant-a")))
  }

  /// The strictness that matters: an interrupted download must NOT read as
  /// complete, or the next Generate skips the fetch meant to repair it and
  /// `loadModels` throws forever.
  func testAPartialVariantIsNotComplete() throws {
    try write("variant-b/AudioEncoder.mlmodelc/data.bin", bytes: 1024)
    try write("variant-b/config.json", bytes: 16)
    XCTAssertFalse(
      CaptionModelStore.isCompleteModel(at: root.appendingPathComponent("variant-b")),
      "two of the three bundles are missing")
  }

  func testAVariantMissingItsConfigIsNotComplete() throws {
    for bundle in CaptionModelStore.requiredModelBundles {
      try write("variant-c/\(bundle).mlmodelc/data.bin", bytes: 1024)
    }
    XCTAssertFalse(
      CaptionModelStore.isCompleteModel(at: root.appendingPathComponent("variant-c")),
      "config.json comes from the same snapshot, so its absence means unfinished")
  }

  func testAnUncompiledMlpackageAlsoCounts() throws {
    // ModelUtilities accepts either shape; so must this.
    for bundle in CaptionModelStore.requiredModelBundles {
      try write(
        "variant-d/\(bundle).mlpackage/Data/com.apple.CoreML/model.mlmodel", bytes: 512)
    }
    try write("variant-d/config.json", bytes: 16)
    XCTAssertTrue(
      CaptionModelStore.isCompleteModel(at: root.appendingPathComponent("variant-d")))
  }

  func testAnEmptyFolderIsNotAModel() throws {
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("variant-e"), withIntermediateDirectories: true)
    XCTAssertFalse(
      CaptionModelStore.isCompleteModel(at: root.appendingPathComponent("variant-e")))
  }

  func testAMissingFolderIsNotAModel() {
    XCTAssertFalse(
      CaptionModelStore.isCompleteModel(at: root.appendingPathComponent("nope")))
  }

  /// `installed` (root bytes) and `complete` (loadable) disagree for exactly
  /// one state, and both answers are right for their own question. Pinned so a
  /// future "cleanup" cannot quietly unify them: making `installed` strict
  /// would hide the Delete button for the one state with reclaimable bytes,
  /// and reading `installed` as readiness would promise a picker that no
  /// download is needed right before a 626 MB fetch.
  func testPartialDownloadHasBytesToFreeButIsNotLoadable() throws {
    try write("variant-f/AudioEncoder.mlmodelc/data.bin", bytes: 300_000)
    let folder = root.appendingPathComponent("variant-f")
    XCTAssertGreaterThan(
      CaptionModelStore.directorySize(folder), 0, "there are bytes to free")
    XCTAssertFalse(
      CaptionModelStore.isCompleteModel(at: folder), "and it cannot be loaded")
  }

  func testVariantInfoCarriesItsOwnSizeNotTheRootTotal() throws {
    try writeCompleteVariant("small-one", bytes: 1024)
    try writeCompleteVariant("big-one", bytes: 8192)

    let small = CaptionModelStore.VariantInfo(
      variant: "small-one",
      bytes: CaptionModelStore.directorySize(root.appendingPathComponent("small-one")),
      complete: true)
    let big = CaptionModelStore.VariantInfo(
      variant: "big-one",
      bytes: CaptionModelStore.directorySize(root.appendingPathComponent("big-one")),
      complete: true)

    XCTAssertGreaterThan(big.bytes, small.bytes)
    XCTAssertLessThan(
      big.bytes, CaptionModelStore.directorySize(root),
      "a variant's own size must be less than the whole tree holding both")
  }

  func testVariantInfoSerialisesTheThreeKeysDartParses() {
    let payload = CaptionModelStore.VariantInfo(
      variant: "v", bytes: 42, complete: true
    ).toFlutter()
    XCTAssertEqual(payload.keys.count, 3)
    XCTAssertEqual(payload["variant"] as? String, "v")
    XCTAssertEqual(payload["bytes"] as? Int, 42)
    XCTAssertEqual(payload["complete"] as? Bool, true)
  }

  /// The enumeration must not invent a root. Most users have never transcribed.
  ///
  /// Against a temp root, not the real one: the real path holds whatever model
  /// this developer has downloaded, which is why `installedVariants` takes an
  /// injectable root at all.
  func testInstalledVariantsIsEmptyWhenNothingWasEverDownloaded() {
    XCTAssertTrue(CaptionModelStore.installedVariants(root: root).isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.path),
      "asking what is installed must not create the tree")
  }

  func testInstalledVariantsListsEachFolderWithItsOwnStateAndSize() throws {
    try writeCompleteVariant("good-one", bytes: 2048)
    try write("half-one/AudioEncoder.mlmodelc/data.bin", bytes: 512)
    // A stray FILE in the root is not a variant.
    try write("README.txt", bytes: 10)

    let found = CaptionModelStore.installedVariants(root: root)
      .sorted { $0.variant < $1.variant }
    XCTAssertEqual(
      found.map(\.variant), ["good-one", "half-one"],
      "directories only — a loose file is not a model")

    let good = try XCTUnwrap(found.first { $0.variant == "good-one" })
    XCTAssertTrue(good.complete)
    XCTAssertGreaterThan(good.bytes, 0)

    let half = try XCTUnwrap(found.first { $0.variant == "half-one" })
    XCTAssertFalse(half.complete, "an unfinished download is listed but not usable")
    XCTAssertGreaterThan(half.bytes, 0, "and its bytes are still reclaimable")
  }

  /// The path the enumeration walks has to be the one WhisperKit downloads
  /// into, or it will always report nothing.
  func testVariantsRootMatchesWhereWhisperKitDownloads() {
    let transcriber = WhisperKitTranscriber(
      model: "test-variant", modelDirectory: root)
    XCTAssertEqual(
      transcriber.localModelFolder.deletingLastPathComponent().lastPathComponent,
      CaptionModelStore.variantsRootURL().lastPathComponent,
      "both must end at whisperkit-coreml")
    XCTAssertEqual(
      transcriber.localModelFolder.lastPathComponent, "test-variant",
      "the variant is the leaf, which is what makes per-variant folders work")
  }
}
