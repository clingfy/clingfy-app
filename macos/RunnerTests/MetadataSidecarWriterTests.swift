import XCTest

@testable import Clingfy

/// PR 10a guard: the stateless MetadataSidecarWriter.updateProjectManifestStatus
/// keeps its exact round-trip + graceful-missing behavior after being moved out
/// of the facade. Real-filesystem integration test (matches the
/// RecordingFailureRecoveryTests convention).
final class MetadataSidecarWriterTests: XCTestCase {
  private func makeTemporaryDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func testUpdateProjectManifestStatusRoundTrips() throws {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = RecordingProjectManifest.create(
      projectId: "rec_meta_test", displayName: "Clingfy Test", includeCamera: false)
    try manifest.write(to: RecordingProjectPaths.manifestURL(for: root))

    MetadataSidecarWriter.updateProjectManifestStatus(.ready, projectRoot: root)

    let reread = try RecordingProjectManifest.read(
      from: RecordingProjectPaths.manifestURL(for: root))
    XCTAssertEqual(reread.status, .ready)
  }

  func testUpdateProjectManifestStatusIsGracefulWhenManifestMissing() {
    let root = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    // No manifest written — must not crash and must not create one.
    MetadataSidecarWriter.updateProjectManifestStatus(.failed, projectRoot: root)

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: RecordingProjectPaths.manifestURL(for: root).path))
  }
}
