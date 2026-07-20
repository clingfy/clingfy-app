import XCTest

@testable import Clingfy

/// The export destination is remembered as a plain path string, so a folder on
/// an ejected volume still looks valid in the export dialog. Without a
/// pre-flight the export renders every intermediate first and only fails when
/// AVAssetWriter tries to create the output — minutes of wasted work ending in
/// a bare "Cannot create file".
@MainActor
final class ExportDestinationPreflightTests: XCTestCase {
  private var workDirectory: URL!

  override func setUpWithError() throws {
    workDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("export-preflight-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
  }

  func testWritableFolderPasses() {
    XCTAssertNil(ExportEngine.destinationProblem(folder: workDirectory))
  }

  func testProbeLeavesNothingBehind() throws {
    _ = ExportEngine.destinationProblem(folder: workDirectory)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: workDirectory.path)
    XCTAssertTrue(leftovers.isEmpty, "The write probe must clean up after itself")
  }

  func testMissingFolderIsRejected() {
    let missing = workDirectory.appendingPathComponent("gone", isDirectory: true)
    XCTAssertNotNil(ExportEngine.destinationProblem(folder: missing))
  }

  /// The reported failure: exporting to a remembered folder on a disk that was
  /// disconnected. The message has to name the actual problem — a generic
  /// "folder no longer exists" would send the user looking for a deleted
  /// folder that is really just unplugged.
  func testUnmountedVolumeSaysTheDiskIsDisconnected() {
    let ejected = URL(fileURLWithPath: "/Volumes/some-external-drive/exports", isDirectory: true)
    let problem = ExportEngine.destinationProblem(folder: ejected)
    XCTAssertNotNil(problem)
    XCTAssertTrue(
      problem!.lowercased().contains("not connected"),
      "Expected a disconnected-disk message, got: \(problem ?? "nil")")
  }

  func testAFileWhereAFolderIsExpectedIsRejected() throws {
    let file = workDirectory.appendingPathComponent("not-a-folder.mov")
    try Data("x".utf8).write(to: file)
    let problem = ExportEngine.destinationProblem(folder: file)
    XCTAssertNotNil(problem)
    XCTAssertTrue(problem!.lowercased().contains("not a folder"))
  }

  func testReadOnlyFolderIsRejected() throws {
    let readOnly = workDirectory.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: readOnly.path)
    }

    XCTAssertNotNil(
      ExportEngine.destinationProblem(folder: readOnly),
      "A folder that cannot be written to must be caught before rendering")
  }
}
