import AVFoundation
import Cocoa
import FlutterMacOS
import XCTest

@testable import Clingfy

final class AppPathsTests: XCTestCase {
  func testCameraArtifactsUseScreenRecordingStem() {
    let rawURL = URL(fileURLWithPath: "/tmp/recording.mov")

    XCTAssertEqual(AppPaths.cameraRawURL(for: rawURL).lastPathComponent, "recording.camera.mov")
    XCTAssertEqual(
      AppPaths.cameraMetadataSidecarURL(for: rawURL).lastPathComponent,
      "recording.camera.meta.json"
    )
    XCTAssertEqual(
      AppPaths.cameraSegmentDirectoryURL(for: rawURL).lastPathComponent,
      "recording.camera.segments"
    )

    let artifactNames = AppPaths.allRecordingArtifactURLs(for: rawURL).map(\.lastPathComponent)
    XCTAssertEqual(
      artifactNames,
      [
        "recording.mov",
        "recording.cursor.json",
        "recording.meta.json",
        "recording.zoom.manual.json",
        "recording.camera.mov",
        "recording.camera.meta.json",
        "recording.camera.segments",
      ]
    )
  }
}

final class RecordingMetadataTests: XCTestCase {
  func testVersion2RoundTripPreservesCameraAndEditorSeed() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let rawURL = tempDir.appendingPathComponent("recording.mov")
    let metadataURL = AppPaths.metadataSidecarURL(for: rawURL)
    let cameraInfo = RecordingMetadata.CameraCaptureInfo(
      mode: .separateCameraAsset,
      enabled: true,
      rawRelativePath: "recording.camera.mov",
      metadataRelativePath: "recording.camera.meta.json",
      deviceId: "camera-1",
      mirroredRaw: true,
      nominalFrameRate: 30,
      dimensions: .init(width: 1920, height: 1080),
      segments: [
        .init(
          index: 0,
          relativePath: "recording.camera.segments/segment_000.mov",
          startWallClock: RecordingMetadata.iso8601String(from: Date(timeIntervalSince1970: 0)),
          endWallClock: RecordingMetadata.iso8601String(from: Date(timeIntervalSince1970: 5))
        )
      ]
    )
    let editorSeed = RecordingMetadata.EditorSeed(
      cameraVisible: true,
      cameraLayoutPreset: .overlayTopLeft,
      cameraNormalizedCenter: .init(x: 0.4, y: 0.6),
      cameraSizeFactor: 0.22,
      cameraShape: .roundedRect,
      cameraCornerRadius: 0.25,
      cameraBorderWidth: 3.0,
      cameraBorderColorArgb: 0xFFFFFFFF,
      cameraShadow: 1,
      cameraOpacity: 0.8,
      cameraMirror: false,
      cameraContentMode: .fit,
      cameraZoomBehavior: .scaleDownWhenScreenZooms,
      cameraChromaKeyEnabled: true,
      cameraChromaKeyStrength: 0.5,
      cameraChromaKeyColorArgb: 0xFF00FF00
    )
    let metadata = RecordingMetadata.create(
      rawURL: rawURL,
      displayMode: .explicitID,
      displayID: 123,
      cropRect: CGRect(x: 10, y: 20, width: 300, height: 200),
      frameRate: 60,
      quality: .fhd,
      cursorEnabled: true,
      cursorLinked: true,
      windowID: 77,
      excludedRecorderApp: true,
      camera: cameraInfo,
      editorSeed: editorSeed
    )

    try metadata.write(to: metadataURL)
    let decoded = try RecordingMetadata.read(from: metadataURL)

    XCTAssertEqual(decoded.version, 2)
    XCTAssertEqual(decoded.screen.rawRelativePath, "recording.mov")
    XCTAssertEqual(decoded.screen.windowId, 77)
    XCTAssertEqual(decoded.camera, cameraInfo)
    XCTAssertEqual(decoded.editorSeed, editorSeed)
  }

  func testLegacyMetadataReadMigratesToVersion2Schema() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let metadataURL = tempDir.appendingPathComponent("recording.meta.json")
    let legacyJSON = """
      {
        "schemaVersion": 1,
        "appVersion": "1.0.0",
        "bundleId": "com.clingfy.app",
        "startedAt": "2025-01-01T00:00:00.000Z",
        "endedAt": "2025-01-01T00:00:05.000Z",
        "displayMode": 0,
        "displayID": 123,
        "cropRect": {
          "x": 10,
          "y": 20,
          "width": 300,
          "height": 200
        },
        "frameRate": 60,
        "quality": "fhd",
        "cursorEnabled": true,
        "cursorLinked": true,
        "overlayEnabled": true,
        "windowID": 42,
        "excludedRecorderApp": true
      }
      """
    let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
    try data.write(to: metadataURL)

    let decoded = try RecordingMetadata.read(from: metadataURL)

    XCTAssertEqual(decoded.version, 2)
    XCTAssertNil(decoded.camera)
    XCTAssertEqual(decoded.screen.rawRelativePath, "recording.mov")
    XCTAssertEqual(decoded.screen.windowId, 42)
    XCTAssertEqual(decoded.editorSeed.cameraVisible, true)
    XCTAssertEqual(decoded.editorSeed.cameraLayoutPreset, .overlayBottomRight)
  }

  private func makeTemporaryDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: nil
    )
    return url
  }
}

final class CameraRecorderTests: XCTestCase {
  func testRecordingStoppedErrorWithSuccessKeyIsTreatedAsSuccessfulFinish() {
    let error = NSError(
      domain: AVFoundationErrorDomain,
      code: AVError.unknown.rawValue,
      userInfo: [
        NSLocalizedDescriptionKey: "Recording Stopped",
        AVErrorRecordingSuccessfullyFinishedKey: true,
      ]
    )

    XCTAssertTrue(CameraRecorder._testRecordingFinishedSuccessfully(error))
  }

  func testRecordingStoppedErrorWithoutSuccessKeyIsTreatedAsFailure() {
    let error = NSError(
      domain: AVFoundationErrorDomain,
      code: AVError.unknown.rawValue,
      userInfo: [
        NSLocalizedDescriptionKey: "Recording Stopped"
      ]
    )

    XCTAssertFalse(CameraRecorder._testRecordingFinishedSuccessfully(error))
  }
}

final class CameraLayoutResolverTests: XCTestCase {
  func testManualFrameClampsIntoCanvasBounds() {
    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayBottomRight,
      normalizedCanvasCenter: CGPoint(x: 1.2, y: -0.2),
      sizeFactor: 0.3,
      shape: .circle,
      cornerRadius: 0,
      opacity: 1,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )

    let resolution = CameraLayoutResolver.effectiveFrame(
      canvasSize: CGSize(width: 1000, height: 600),
      params: params
    )

    XCTAssertTrue(resolution.shouldRender)
    XCTAssertEqual(resolution.zOrder, .aboveScreen)
    XCTAssertEqual(resolution.frame.maxX, 1000, accuracy: 0.001)
    XCTAssertEqual(resolution.frame.minY, 0, accuracy: 0.001)
  }

  func testBackgroundBehindUsesFullCanvasAndHiddenDoesNotRender() {
    var params = CameraCompositionParams.hidden
    params.visible = true
    params.layoutPreset = .backgroundBehind

    let background = CameraLayoutResolver.resolve(
      canvasSize: CGSize(width: 1280, height: 720),
      params: params
    )

    XCTAssertTrue(background.shouldRender)
    XCTAssertEqual(background.zOrder, .behindScreen)
    XCTAssertEqual(background.frame, CGRect(x: 0, y: 0, width: 1280, height: 720))

    let hidden = CameraLayoutResolver.resolve(
      canvasSize: CGSize(width: 1280, height: 720),
      params: .hidden
    )
    XCTAssertFalse(hidden.shouldRender)
    XCTAssertEqual(hidden.frame, .zero)
  }

  func testMaskPathMatchesRequestedShape() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 120)
    var params = CameraCompositionParams.hidden
    params.visible = true
    params.layoutPreset = .overlayBottomRight
    params.shape = .roundedRect
    params.cornerRadius = 0.25

    let roundedRect = CameraLayoutResolver.maskPath(in: rect, params: params)
    XCTAssertEqual(roundedRect.boundingBox, rect)

    params.shape = .circle
    let circle = CameraLayoutResolver.maskPath(in: rect, params: params)
    XCTAssertEqual(circle.boundingBox, rect)
  }
}

final class LetterboxExporterTests: XCTestCase {
  func testSeparateCameraExportUsesStyledIntermediateForAdvancedStyling() {
    let exporter = LetterboxExporter()
    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayBottomRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .circle,
      cornerRadius: 0.0,
      opacity: 0.9,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )

    XCTAssertTrue(exporter._testShouldUseStyledCameraIntermediate(cameraParams: params))
  }

  func testSeparateCameraExportSkipsStyledIntermediateForGeometryOnlyParams() {
    let exporter = LetterboxExporter()
    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayBottomRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .square,
      cornerRadius: 0.0,
      opacity: 0.9,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 0,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )

    XCTAssertFalse(exporter._testShouldUseStyledCameraIntermediate(cameraParams: params))
  }

  func testStyledCameraIntermediateRendersNonBlackFrame() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let cameraURL = tempDir.appendingPathComponent("camera.mov")
    try makeSolidColorVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .systemRed
    )

    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .squircle,
      cornerRadius: 0.15,
      opacity: 1.0,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 2,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )

    let styledURL = tempDir.appendingPathComponent("styled.mov")
    let exporter = LetterboxExporter()
    let renderExpectation = expectation(description: "styled intermediate rendered")
    var renderResult: Result<URL, Error>?

    exporter._testRenderStyledCameraIntermediate(
      inputURL: cameraURL,
      outputURL: styledURL,
      canvasSize: CGSize(width: 640, height: 360),
      cameraParams: params,
      fpsHint: 30
    ) { result in
      renderResult = result
      renderExpectation.fulfill()
    }

    wait(for: [renderExpectation], timeout: 30.0)
    XCTAssertEqual(try renderResult?.get(), styledURL)

    let ratio = try nonBlackRatio(for: sampleFrameImage(url: styledURL), ignoreTransparentPixels: true)
    XCTAssertGreaterThan(ratio, 0.05)

    XCTAssertNil(
      exporter._testValidateStyledCameraIntermediate(
        rawCameraURL: cameraURL,
        styledCameraURL: styledURL
      )
    )
  }

  func testAdvancedSeparateCameraExportProducesNonBlackCameraCrop() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("screen.mov")
    let cameraURL = tempDir.appendingPathComponent("camera.mov")
    try makeSolidColorVideo(
      url: screenURL,
      size: CGSize(width: 320, height: 180),
      durationSeconds: 1.0,
      color: .systemBlue
    )
    try makeSolidColorVideo(
      url: cameraURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .systemRed
    )

    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .squircle,
      cornerRadius: 0.15,
      opacity: 1.0,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 2,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )
    let target = CGSize(width: 640, height: 360)
    let outputURL = tempDir.appendingPathComponent("final.mov")

    let exporter = LetterboxExporter()
    let exportExpectation = expectation(description: "final export")
    var exportResult: Result<URL, Error>?

    exporter.export(
      inputURL: screenURL,
      cameraInputURL: cameraURL,
      target: target,
      padding: 0.0,
      cornerRadius: 0.0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: false,
      zoomEnabled: false,
      zoomFactor: 1.5,
      followStrength: 0.15,
      fpsHint: 30,
      outputURL: outputURL,
      format: "mov",
      codec: "h264",
      bitrate: "auto",
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0,
      autoNormalizeOnExport: false,
      targetLoudnessDbfs: -16.0,
      cameraParams: params
    ) { result in
      exportResult = result
      exportExpectation.fulfill()
    }

    wait(for: [exportExpectation], timeout: 30.0)
    let finalURL = try XCTUnwrap(try exportResult?.get())

    let resolution = CameraLayoutResolver.effectiveFrame(canvasSize: target, params: params)
    let cropRatio = try cropNonBlackRatio(
      for: sampleFrameImage(url: finalURL),
      canvasSize: target,
      cropRect: resolution.frame
    )
    XCTAssertGreaterThan(cropRatio, 0.05)
  }

  func testStyledCameraIntermediateValidationFailsForBlackStyledAsset() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let rawURL = tempDir.appendingPathComponent("raw.mov")
    let styledURL = tempDir.appendingPathComponent("styled.mov")
    try makeSolidColorVideo(
      url: rawURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .systemRed
    )
    try makeSolidColorVideo(
      url: styledURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .black
    )

    let exporter = LetterboxExporter()
    let error = exporter._testValidateStyledCameraIntermediate(
      rawCameraURL: rawURL,
      styledCameraURL: styledURL
    )

    XCTAssertEqual(error?.userInfo["stage"] as? String, "styled_intermediate_validation")
  }

  func testFinalStyledCameraExportValidationFailsForBlackFinalCrop() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let styledURL = tempDir.appendingPathComponent("styled.mov")
    let finalURL = tempDir.appendingPathComponent("final.mov")
    try makeSolidColorVideo(
      url: styledURL,
      size: CGSize(width: 128, height: 128),
      durationSeconds: 1.0,
      color: .systemRed
    )
    try makeSolidColorVideo(
      url: finalURL,
      size: CGSize(width: 640, height: 360),
      durationSeconds: 1.0,
      color: .black
    )

    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayTopRight,
      normalizedCanvasCenter: nil,
      sizeFactor: 0.2,
      shape: .squircle,
      cornerRadius: 0.15,
      opacity: 1.0,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 0.0,
      borderColorArgb: nil,
      shadowPreset: 2,
      chromaKeyEnabled: false,
      chromaKeyStrength: 0.4,
      chromaKeyColorArgb: nil
    )

    let exporter = LetterboxExporter()
    let error = exporter._testValidateFinalStyledCameraExport(
      styledCameraURL: styledURL,
      finalExportURL: finalURL,
      canvasSize: CGSize(width: 640, height: 360),
      cameraParams: params
    )

    XCTAssertEqual(error?.userInfo["stage"] as? String, "final_output_validation")
  }

  private func makeTemporaryDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: nil
    )
    return url
  }

  private func makeSolidColorVideo(
    url: URL,
    size: CGSize,
    durationSeconds: Double,
    color: NSColor
  ) throws {
    try? FileManager.default.removeItem(at: url)

    let writer = try AVAssetWriter(url: url, fileType: .mov)
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false

    let pixelAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: Int(size.width),
      kCVPixelBufferHeightKey as String: Int(size.height),
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: pixelAttributes
    )

    XCTAssertTrue(writer.canAdd(input))
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    let fps: Int32 = 30
    let frameCount = max(6, Int(durationSeconds * Double(fps)))

    for frame in 0..<frameCount {
      while !input.isReadyForMoreMediaData {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
      }

      let pixelBuffer = try makePixelBuffer(size: size, color: color)
      let time = CMTime(value: CMTimeValue(frame), timescale: fps)
      XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: time))
    }

    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
      semaphore.signal()
    }
    semaphore.wait()

    if let error = writer.error {
      throw error
    }
    XCTAssertEqual(writer.status, .completed)
  }

  private func makePixelBuffer(size: CGSize, color: NSColor) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      Int(size.width),
      Int(size.height),
      kCVPixelFormatType_32BGRA,
      attrs as CFDictionary,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
      throw NSError(domain: "RunnerTests", code: Int(status))
    }

    let deviceColor = color.usingColorSpace(.deviceRGB) ?? color
    let red = UInt8(max(0.0, min(255.0, deviceColor.redComponent * 255.0)))
    let green = UInt8(max(0.0, min(255.0, deviceColor.greenComponent * 255.0)))
    let blue = UInt8(max(0.0, min(255.0, deviceColor.blueComponent * 255.0)))
    let alpha = UInt8(max(0.0, min(255.0, deviceColor.alphaComponent * 255.0)))

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let baseAddress = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
      .assumingMemoryBound(to: UInt8.self)

    for y in 0..<height {
      let row = baseAddress.advanced(by: y * bytesPerRow)
      for x in 0..<width {
        let offset = x * 4
        row[offset] = blue
        row[offset + 1] = green
        row[offset + 2] = red
        row[offset + 3] = alpha
      }
    }

    return pixelBuffer
  }

  private func exportComposition(
    _ result: CompositionBuilder.ExportCompositionResult,
    to outputURL: URL,
    preset: String
  ) throws {
    XCTAssertTrue(
      Set(AVAssetExportSession.exportPresets(compatibleWith: result.asset)).contains(preset)
    )
    let export = try XCTUnwrap(AVAssetExportSession(asset: result.asset, presetName: preset))
    export.videoComposition = result.videoComposition
    export.outputFileType = .mov
    export.outputURL = outputURL

    let semaphore = DispatchSemaphore(value: 0)
    export.exportAsynchronously {
      semaphore.signal()
    }
    semaphore.wait()

    if let error = export.error {
      throw error
    }
    XCTAssertEqual(export.status, .completed)
  }

  private func sampleFrameImage(url: URL) throws -> CGImage {
    let asset = AVAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    return try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
  }

  private func nonBlackRatio(
    for image: CGImage,
    ignoreTransparentPixels: Bool
  ) throws -> Double {
    let width = 64
    let height = 64
    let bytesPerRow = width * 4
    var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    try buffer.withUnsafeMutableBytes { rawBuffer in
      let context = try XCTUnwrap(
        CGContext(
          data: rawBuffer.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        )
      )
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    var visiblePixels = 0
    var nonBlackPixels = 0
    for pixelIndex in 0..<(width * height) {
      let offset = pixelIndex * 4
      let alpha = buffer[offset + 3]
      if ignoreTransparentPixels && alpha <= 8 {
        continue
      }
      visiblePixels += 1
      if max(buffer[offset], max(buffer[offset + 1], buffer[offset + 2])) > 12 {
        nonBlackPixels += 1
      }
    }

    guard visiblePixels > 0 else { return 0.0 }
    return Double(nonBlackPixels) / Double(visiblePixels)
  }

  private func cropNonBlackRatio(
    for image: CGImage,
    canvasSize: CGSize,
    cropRect: CGRect
  ) throws -> Double {
    let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let scaleX = CGFloat(image.width) / max(canvasSize.width, 1.0)
    let scaleY = CGFloat(image.height) / max(canvasSize.height, 1.0)

    let ratios = try [false, true].compactMap { flipY -> Double? in
      let sourceY = flipY ? (canvasSize.height - cropRect.maxY) : cropRect.minY
      let pixelRect = CGRect(
        x: cropRect.minX * scaleX,
        y: sourceY * scaleY,
        width: cropRect.width * scaleX,
        height: cropRect.height * scaleY
      ).integral.intersection(imageBounds)

      guard pixelRect.width >= 1.0, pixelRect.height >= 1.0 else { return nil }
      guard let cropped = image.cropping(to: pixelRect) else { return nil }
      return try nonBlackRatio(for: cropped, ignoreTransparentPixels: false)
    }

    return ratios.max() ?? 0.0
  }
}

final class ScreenCaptureKitOverlayFilterPolicyTests: XCTestCase {
  func testOverlayWindowExcludedWhenSeparateCameraModeKeepsRecorderVisible() {
    let windows = [
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 11, bundleIdentifier: "com.clingfy.clingfy.dev"),
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 12, bundleIdentifier: "com.apple.finder"),
    ]

    let excluded = ScreenCaptureKitOverlayFilterPolicy.excludedWindowIDs(
      windows: windows,
      selfBundleIdentifier: "com.clingfy.clingfy.dev",
      overlayWindowID: 11,
      excludeRecorderApp: false,
      excludeCameraOverlayWindow: true
    )

    XCTAssertEqual(excluded, [11])
  }

  func testOverlayAndRecorderWindowsExcludedTogetherWhenRecorderAppExcluded() {
    let windows = [
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 11, bundleIdentifier: "com.clingfy.clingfy.dev"),
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 13, bundleIdentifier: "com.clingfy.clingfy.dev"),
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 12, bundleIdentifier: "com.apple.finder"),
    ]

    let excluded = ScreenCaptureKitOverlayFilterPolicy.excludedWindowIDs(
      windows: windows,
      selfBundleIdentifier: "com.clingfy.clingfy.dev",
      overlayWindowID: 11,
      excludeRecorderApp: true,
      excludeCameraOverlayWindow: true
    )

    XCTAssertEqual(excluded, [11, 13])
  }

  func testBakedOverlayKeepsOverlayWindowWhenRecorderAppExcluded() {
    let windows = [
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 11, bundleIdentifier: "com.clingfy.clingfy.dev"),
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 13, bundleIdentifier: "com.clingfy.clingfy.dev"),
      ScreenCaptureKitOverlayFilterPolicy.WindowRecord(windowID: 12, bundleIdentifier: "com.apple.finder"),
    ]

    let excluded = ScreenCaptureKitOverlayFilterPolicy.excludedWindowIDs(
      windows: windows,
      selfBundleIdentifier: "com.clingfy.clingfy.dev",
      overlayWindowID: 11,
      excludeRecorderApp: true,
      excludeCameraOverlayWindow: false
    )

    XCTAssertEqual(excluded, [13])
  }
}

private final class MockCaptureBackend: CaptureBackend {
  var onStarted: ((URL) -> Void)?
  var onFinished: ((URL?, Error?) -> Void)?
  var onPaused: (() -> Void)?
  var onResumed: (() -> Void)?
  var onMicrophoneLevel: ((MicrophoneLevelSample) -> Void)?

  var canPauseResume: Bool = true
  var supportsLiveOverlayExclusionDuringSeparateCameraCapture: Bool = false
  var isRecording: Bool = false
  var isPaused: Bool = false
  var currentOutputURL: URL?
  private(set) var overlayUpdates: [CGWindowID?] = []
  private(set) var stopCallCount: Int = 0

  func start(config: CaptureStartConfig) {}
  func stop() { stopCallCount += 1 }
  func pause() {}
  func resume() {}

  func updateOverlay(windowID: CGWindowID?) {
    overlayUpdates.append(windowID)
  }
}

@MainActor
final class ScreenRecorderFacadeSeparateCameraTests: XCTestCase {
  func testFinishMetadataPublishesFinalCameraBasename() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let publishedScreenURL = tempDir.appendingPathComponent("recording.mov")
    let inProgressScreenURL = tempDir.appendingPathComponent("recording.123.inprogress.mov")
    let metadataURL = AppPaths.metadataSidecarURL(for: inProgressScreenURL)

    let initialMetadata = RecordingMetadata.create(
      rawURL: publishedScreenURL,
      displayMode: .explicitID,
      displayID: 1,
      cropRect: nil,
      frameRate: 60,
      quality: .fhd,
      cursorEnabled: true,
      cursorLinked: true,
      windowID: nil,
      excludedRecorderApp: false,
      camera: RecordingMetadata.CameraCaptureInfo(
        mode: .separateCameraAsset,
        enabled: true,
        rawRelativePath: AppPaths.cameraRawURL(for: publishedScreenURL).lastPathComponent,
        metadataRelativePath: AppPaths.cameraMetadataSidecarURL(for: publishedScreenURL).lastPathComponent,
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        segments: []
      ),
      editorSeed: makeEditorSeed()
    )
    try initialMetadata.write(to: metadataURL)

    let cameraResult = CameraRecordingResult(
      rawURL: AppPaths.cameraRawURL(for: inProgressScreenURL),
      metadataURL: AppPaths.cameraMetadataSidecarURL(for: inProgressScreenURL),
      metadata: CameraRecordingMetadata(
        version: 1,
        recordingId: "camera-recording-id",
        rawRelativePath: AppPaths.cameraRawURL(for: inProgressScreenURL).lastPathComponent,
        metadataRelativePath: AppPaths.cameraMetadataSidecarURL(for: inProgressScreenURL)
          .lastPathComponent,
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        startedAt: RecordingMetadata.iso8601String(from: Date(timeIntervalSince1970: 0)),
        endedAt: RecordingMetadata.iso8601String(from: Date(timeIntervalSince1970: 5)),
        segments: []
      )
    )

    let facade = ScreenRecorderFacade()
    facade._testUpdateMetadataSidecarOnFinish(
      for: inProgressScreenURL,
      cameraResult: cameraResult,
      publishedScreenURL: publishedScreenURL
    )

    let updated = try RecordingMetadata.read(from: metadataURL)
    XCTAssertEqual(updated.camera?.rawRelativePath, "recording.camera.mov")
    XCTAssertEqual(updated.camera?.metadataRelativePath, "recording.camera.meta.json")
    XCTAssertFalse(updated.camera?.rawRelativePath?.contains(".inprogress.") ?? true)
  }

  func testSeparateCameraCaptureConfigRespectsRecorderExclusionPreference() {
    let prefs = PreferencesStore()
    let originalOverlayEnabled = prefs.overlayEnabled
    let originalOverlayLinked = prefs.overlayLinked
    let originalExcludeRecorderApp = prefs.excludeRecorderApp
    let originalCameraCaptureMode = prefs.cameraCaptureMode
    defer {
      prefs.overlayEnabled = originalOverlayEnabled
      prefs.overlayLinked = originalOverlayLinked
      prefs.excludeRecorderApp = originalExcludeRecorderApp
      prefs.cameraCaptureMode = originalCameraCaptureMode
    }

    prefs.overlayEnabled = true
    prefs.overlayLinked = true
    prefs.cameraCaptureMode = .separateCameraAsset
    prefs.excludeRecorderApp = false

    let facade = ScreenRecorderFacade()
    let target = CaptureTarget(mode: .explicitID, displayID: 1)

    let defaultConfig = facade._testBuildCaptureStartConfig(
      target: target,
      effectiveOverlayID: 42
    )
    XCTAssertFalse(defaultConfig.excludeRecorderApp)
    XCTAssertEqual(defaultConfig.cameraOverlayWindowID, 42)
    XCTAssertTrue(defaultConfig.excludeCameraOverlayWindow)

    prefs.excludeRecorderApp = true

    let excludedConfig = facade._testBuildCaptureStartConfig(
      target: target,
      effectiveOverlayID: 42
    )
    XCTAssertTrue(excludedConfig.excludeRecorderApp)
    XCTAssertEqual(excludedConfig.cameraOverlayWindowID, 42)
    XCTAssertTrue(excludedConfig.excludeCameraOverlayWindow)
  }

  func testSeparateCameraModeSuppressesOverlayWindowDuringCaptureOnAVFoundation() {
    let prefs = PreferencesStore()
    let originalOverlayEnabled = prefs.overlayEnabled
    let originalOverlayLinked = prefs.overlayLinked
    let originalCameraCaptureMode = prefs.cameraCaptureMode
    defer {
      prefs.overlayEnabled = originalOverlayEnabled
      prefs.overlayLinked = originalOverlayLinked
      prefs.cameraCaptureMode = originalCameraCaptureMode
    }

    prefs.overlayEnabled = true
    prefs.overlayLinked = true
    prefs.cameraCaptureMode = .separateCameraAsset

    let facade = ScreenRecorderFacade()
    let backend = MockCaptureBackend()
    backend.supportsLiveOverlayExclusionDuringSeparateCameraCapture = false
    facade._testSetCaptureBackend(backend)
    XCTAssertTrue(facade._testShouldSuppressOverlayWindowDuringCapture())
  }

  func testSeparateCameraModeKeepsOverlayVisibleOnScreenCaptureKit() {
    let prefs = PreferencesStore()
    let originalOverlayEnabled = prefs.overlayEnabled
    let originalOverlayLinked = prefs.overlayLinked
    let originalCameraCaptureMode = prefs.cameraCaptureMode
    defer {
      prefs.overlayEnabled = originalOverlayEnabled
      prefs.overlayLinked = originalOverlayLinked
      prefs.cameraCaptureMode = originalCameraCaptureMode
    }

    prefs.overlayEnabled = true
    prefs.overlayLinked = true
    prefs.cameraCaptureMode = .separateCameraAsset

    let facade = ScreenRecorderFacade()
    let backend = MockCaptureBackend()
    backend.supportsLiveOverlayExclusionDuringSeparateCameraCapture = true
    facade._testSetCaptureBackend(backend)
    XCTAssertFalse(facade._testShouldSuppressOverlayWindowDuringCapture())
  }

  func testSeparateCameraOverlaySyncUsesNilOnAVFoundation() {
    let prefs = PreferencesStore()
    let originalOverlayEnabled = prefs.overlayEnabled
    let originalOverlayLinked = prefs.overlayLinked
    let originalCameraCaptureMode = prefs.cameraCaptureMode
    defer {
      prefs.overlayEnabled = originalOverlayEnabled
      prefs.overlayLinked = originalOverlayLinked
      prefs.cameraCaptureMode = originalCameraCaptureMode
    }

    prefs.overlayEnabled = true
    prefs.overlayLinked = true
    prefs.cameraCaptureMode = .separateCameraAsset

    let facade = ScreenRecorderFacade()
    let backend = MockCaptureBackend()
    backend.supportsLiveOverlayExclusionDuringSeparateCameraCapture = false
    facade._testSetCaptureBackend(backend)
    facade._testSetRecorderState(.recording)

    XCTAssertNil(facade._testOverlayWindowIDForCapture(liveOverlayWindowID: 77))
  }

  func testSeparateCameraOverlaySyncUsesLiveOverlayWindowOnScreenCaptureKit() {
    let prefs = PreferencesStore()
    let originalOverlayEnabled = prefs.overlayEnabled
    let originalOverlayLinked = prefs.overlayLinked
    let originalCameraCaptureMode = prefs.cameraCaptureMode
    defer {
      prefs.overlayEnabled = originalOverlayEnabled
      prefs.overlayLinked = originalOverlayLinked
      prefs.cameraCaptureMode = originalCameraCaptureMode
    }

    prefs.overlayEnabled = true
    prefs.overlayLinked = true
    prefs.cameraCaptureMode = .separateCameraAsset

    let facade = ScreenRecorderFacade()
    let backend = MockCaptureBackend()
    backend.supportsLiveOverlayExclusionDuringSeparateCameraCapture = true
    facade._testSetCaptureBackend(backend)
    facade._testSetRecorderState(.recording)

    XCTAssertEqual(facade._testOverlayWindowIDForCapture(liveOverlayWindowID: 77), 77)
  }

  func testCameraRecorderBeginResultDispatchesBeginCaptureToMain() {
    let facade = ScreenRecorderFacade()
    let beginCaptureExpectation = expectation(description: "beginCapture invoked on main")
    let noFailureExpectation = expectation(description: "no failure callback")
    noFailureExpectation.isInverted = true

    DispatchQueue.global(qos: .userInitiated).async {
      Task { @MainActor in
        facade._testHandleCameraRecorderBeginResult(
          .success(()),
          beginCapture: {
            XCTAssertTrue(Thread.isMainThread)
            beginCaptureExpectation.fulfill()
          },
          onFailure: { _ in
            noFailureExpectation.fulfill()
          }
        )
      }
    }

    wait(for: [beginCaptureExpectation, noFailureExpectation], timeout: 1.0)
  }

  func testOverlayUITransitionDispatchesToMain() {
    let facade = ScreenRecorderFacade()
    let expectation = expectation(description: "overlay transition runs on main")

    DispatchQueue.global(qos: .userInitiated).async {
      Task { @MainActor in
        facade._testRunOverlayUITransitionOnMain { isMainThread in
          XCTAssertTrue(isMainThread)
          expectation.fulfill()
        }
      }
    }

    wait(for: [expectation], timeout: 1.0)
  }

  func testResolvePreviewMediaSourcesUsesPublishedCameraAsset() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("recording.mov")
    let cameraURL = AppPaths.cameraRawURL(for: screenURL)
    try Data("screen".utf8).write(to: screenURL)
    try Data("camera".utf8).write(to: cameraURL)

    let metadata = RecordingMetadata.create(
      rawURL: screenURL,
      displayMode: .explicitID,
      displayID: 1,
      cropRect: nil,
      frameRate: 60,
      quality: .fhd,
      cursorEnabled: true,
      cursorLinked: true,
      windowID: nil,
      excludedRecorderApp: false,
      camera: RecordingMetadata.CameraCaptureInfo(
        mode: .separateCameraAsset,
        enabled: true,
        rawRelativePath: cameraURL.lastPathComponent,
        metadataRelativePath: AppPaths.cameraMetadataSidecarURL(for: screenURL).lastPathComponent,
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        segments: []
      ),
      editorSeed: makeEditorSeed()
    )
    try metadata.write(to: AppPaths.metadataSidecarURL(for: screenURL))

    let facade = ScreenRecorderFacade()
    let mediaSources = facade.resolvePreviewMediaSources(source: screenURL.path)

    XCTAssertEqual(mediaSources.cameraPath, cameraURL.path)
  }

  func testResolvePreviewMediaSourcesFallsBackWhenMetadataPointsToMissingInProgressCamera() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("recording.mov")
    let publishedCameraURL = AppPaths.cameraRawURL(for: screenURL)
    try Data("screen".utf8).write(to: screenURL)
    try Data("camera".utf8).write(to: publishedCameraURL)

    let metadata = RecordingMetadata.create(
      rawURL: screenURL,
      displayMode: .explicitID,
      displayID: 1,
      cropRect: nil,
      frameRate: 60,
      quality: .fhd,
      cursorEnabled: true,
      cursorLinked: true,
      windowID: nil,
      excludedRecorderApp: false,
      camera: RecordingMetadata.CameraCaptureInfo(
        mode: .separateCameraAsset,
        enabled: true,
        rawRelativePath: "recording.123.inprogress.camera.mov",
        metadataRelativePath: "recording.123.inprogress.camera.meta.json",
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        segments: []
      ),
      editorSeed: makeEditorSeed()
    )
    try metadata.write(to: AppPaths.metadataSidecarURL(for: screenURL))

    let facade = ScreenRecorderFacade()
    let mediaSources = facade.resolvePreviewMediaSources(source: screenURL.path)

    XCTAssertNil(mediaSources.cameraPath)
  }

  func testResolvePreviewSceneIncludesTwoSourceMediaAndCameraParams() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("recording.mov")
    let cameraURL = AppPaths.cameraRawURL(for: screenURL)
    try Data("screen".utf8).write(to: screenURL)
    try Data("camera".utf8).write(to: cameraURL)

    let metadata = RecordingMetadata.create(
      rawURL: screenURL,
      displayMode: .explicitID,
      displayID: 1,
      cropRect: nil,
      frameRate: 60,
      quality: .fhd,
      cursorEnabled: true,
      cursorLinked: true,
      windowID: nil,
      excludedRecorderApp: false,
      camera: RecordingMetadata.CameraCaptureInfo(
        mode: .separateCameraAsset,
        enabled: true,
        rawRelativePath: cameraURL.lastPathComponent,
        metadataRelativePath: AppPaths.cameraMetadataSidecarURL(for: screenURL).lastPathComponent,
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        segments: []
      ),
      editorSeed: makeEditorSeed()
    )
    try metadata.write(to: AppPaths.metadataSidecarURL(for: screenURL))

    let params = CompositionParams(
      targetSize: CGSize(width: 1280, height: 720),
      padding: 0,
      cornerRadius: 0,
      backgroundColor: nil,
      backgroundImagePath: nil,
      cursorSize: 1.0,
      showCursor: true,
      zoomEnabled: true,
      zoomFactor: 1.5,
      followStrength: 0.15,
      fpsHint: 60,
      fitMode: "fit",
      audioGainDb: 0.0,
      audioVolumePercent: 100.0
    )
    let facade = ScreenRecorderFacade()
    let scene = facade.resolvePreviewScene(source: screenURL.path, screenParams: params)

    XCTAssertEqual(scene.mediaSources.screenPath, screenURL.path)
    XCTAssertEqual(scene.mediaSources.cameraPath, cameraURL.path)
    XCTAssertEqual(scene.cameraParams?.layoutPreset, .overlayBottomRight)
  }

  func testRecordingSceneInfoExposesFeatureLevelCameraExportCapabilities() throws {
    let tempDir = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let screenURL = tempDir.appendingPathComponent("recording.mov")
    let cameraURL = AppPaths.cameraRawURL(for: screenURL)
    try Data("screen".utf8).write(to: screenURL)
    try Data("camera".utf8).write(to: cameraURL)

    let metadata = RecordingMetadata.create(
      rawURL: screenURL,
      displayMode: .explicitID,
      displayID: 1,
      cropRect: nil,
      frameRate: 60,
      quality: .fhd,
      cursorEnabled: true,
      cursorLinked: true,
      windowID: nil,
      excludedRecorderApp: false,
      camera: RecordingMetadata.CameraCaptureInfo(
        mode: .separateCameraAsset,
        enabled: true,
        rawRelativePath: cameraURL.lastPathComponent,
        metadataRelativePath: AppPaths.cameraMetadataSidecarURL(for: screenURL).lastPathComponent,
        deviceId: "camera-1",
        mirroredRaw: true,
        nominalFrameRate: 30,
        dimensions: .init(width: 1920, height: 1080),
        segments: []
      ),
      editorSeed: makeEditorSeed()
    )
    try metadata.write(to: AppPaths.metadataSidecarURL(for: screenURL))

    let facade = ScreenRecorderFacade()
    var scenePayload: Any?
    facade.getRecordingSceneInfo(source: screenURL.path) { value in
      scenePayload = value
    }

    let payload = try XCTUnwrap(scenePayload as? [String: Any])
    XCTAssertEqual(payload["cameraPath"] as? String, cameraURL.path)
    XCTAssertEqual(payload["supportsAdvancedCameraExportStyling"] as? Bool, false)
    let capabilities = try XCTUnwrap(payload["cameraExportCapabilities"] as? [String: Bool])
    XCTAssertEqual(capabilities["shapeMask"], true)
    XCTAssertEqual(capabilities["cornerRadius"], true)
    XCTAssertEqual(capabilities["border"], true)
    XCTAssertEqual(capabilities["shadow"], true)
    XCTAssertEqual(capabilities["chromaKey"], false)
  }

  func testSeparateCameraExportSanitizesOnlyUnsupportedChromaKeyStyling() {
    let params = CameraCompositionParams(
      visible: true,
      layoutPreset: .overlayBottomRight,
      normalizedCanvasCenter: CGPoint(x: 0.5, y: 0.5),
      sizeFactor: 0.2,
      shape: .circle,
      cornerRadius: 0.35,
      opacity: 0.9,
      mirror: true,
      contentMode: .fill,
      zoomBehavior: .fixed,
      borderWidth: 6,
      borderColorArgb: 0xFFFFFFFF,
      shadowPreset: 2,
      chromaKeyEnabled: true,
      chromaKeyStrength: 0.8,
      chromaKeyColorArgb: 0xFF00FF00
    )

    let facade = ScreenRecorderFacade()
    let sanitized = facade._testSanitizedCameraParamsForExport(
      params,
      cameraPath: "/tmp/recording.camera.mov"
    )

    XCTAssertEqual(sanitized?.shape, params.shape)
    XCTAssertEqual(sanitized?.cornerRadius, params.cornerRadius)
    XCTAssertEqual(sanitized?.borderWidth, params.borderWidth)
    XCTAssertEqual(sanitized?.borderColorArgb, params.borderColorArgb)
    XCTAssertEqual(sanitized?.shadowPreset, params.shadowPreset)
    XCTAssertEqual(sanitized?.chromaKeyEnabled, false)
    XCTAssertNil(sanitized?.chromaKeyColorArgb)
    XCTAssertEqual(sanitized?.chromaKeyStrength, 0.4)
    XCTAssertEqual(sanitized?.opacity, params.opacity)
    XCTAssertEqual(sanitized?.mirror, params.mirror)
  }

  func testSeparateCameraRecorderFailureStopsCaptureAndStoresFailure() {
    let prefs = PreferencesStore()
    let originalOverlayEnabled = prefs.overlayEnabled
    let originalOverlayLinked = prefs.overlayLinked
    let originalCameraCaptureMode = prefs.cameraCaptureMode
    defer {
      prefs.overlayEnabled = originalOverlayEnabled
      prefs.overlayLinked = originalOverlayLinked
      prefs.cameraCaptureMode = originalCameraCaptureMode
    }

    prefs.overlayEnabled = true
    prefs.overlayLinked = true
    prefs.cameraCaptureMode = .separateCameraAsset

    let facade = ScreenRecorderFacade()
    let backend = MockCaptureBackend()
    backend.supportsLiveOverlayExclusionDuringSeparateCameraCapture = true
    facade._testSetCaptureBackend(backend)
    facade._testSetRecorderState(.recording)

    facade._testHandleSeparateCameraRecorderFailure(
      FlutterError(code: NativeErrorCode.recordingError, message: "camera failed", details: nil)
    )

    XCTAssertEqual(backend.stopCallCount, 1)
    XCTAssertEqual(facade._testPendingSeparateCameraFailureCode(), NativeErrorCode.recordingError)
    XCTAssertEqual(
      (facade._testTerminalRecordingError(screenError: nil) as? FlutterError)?.message,
      "camera failed"
    )
  }

  private func makeTemporaryDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: nil
    )
    return url
  }

  private func makeEditorSeed() -> RecordingMetadata.EditorSeed {
    RecordingMetadata.EditorSeed(
      cameraVisible: true,
      cameraLayoutPreset: .overlayBottomRight,
      cameraNormalizedCenter: nil,
      cameraSizeFactor: 0.18,
      cameraShape: .circle,
      cameraCornerRadius: 0.0,
      cameraBorderWidth: 0.0,
      cameraBorderColorArgb: nil,
      cameraShadow: 0,
      cameraOpacity: 1.0,
      cameraMirror: true,
      cameraContentMode: .fill,
      cameraZoomBehavior: .fixed,
      cameraChromaKeyEnabled: false,
      cameraChromaKeyStrength: 0.4,
      cameraChromaKeyColorArgb: nil
    )
  }
}
