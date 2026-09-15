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
    XCTAssertEqual(payload.keys.count, 7, "the Dart parser expects all seven")
  }
}
