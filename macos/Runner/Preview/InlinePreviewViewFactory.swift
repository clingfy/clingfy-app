//
//  InlinePreviewViewFactory.swift
//  Runner
//
//  Created by Nabil Alhafez on 13/11/2025.
//
import AVFoundation
import Cocoa
import FlutterMacOS
import Foundation

var inlinePreviewViewInstance: InlinePreviewView?
var inlinePreviewPlayerEventSink: FlutterEventSink?
var workflowLifecycleEventSink: FlutterEventSink?
var pendingPreviewZoomSegments: [ZoomTimelineSegment]?
var pendingPreviewSceneRequest: PendingPreviewSceneRequest?

struct PendingPreviewOpenRequest {
  let sessionId: String
  let mediaSources: PreviewMediaSources
}

struct PendingPreviewSceneRequest {
  let sessionId: String?
  let scene: PreviewScene
}

var pendingPreviewOpenRequest: PendingPreviewOpenRequest?

final class InlinePreviewViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  // macOS: return NSView, not FlutterPlatformView

  func create(
    withViewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> NSView {
    NativeLogger.i(
      "Preview", "Creating inline preview host view",
      context: [
        "viewId": "\(viewId)",
        "hasPendingOpenRequest": pendingPreviewOpenRequest != nil,
        "hasPendingPreviewSceneRequest": pendingPreviewSceneRequest != nil,
        "hasPendingZoomSegments": pendingPreviewZoomSegments != nil,
      ])
    let v = InlinePreviewView(
      viewIdentifier: viewId,
      arguments: args,
      messenger: messenger
    )
    inlinePreviewViewInstance = v
    v.playerEventSink = inlinePreviewPlayerEventSink
    v.workflowEventSink = workflowLifecycleEventSink
    var didOpenPreview = false

    if let request = pendingPreviewOpenRequest {
      NativeLogger.i(
        "Preview", "Consuming pending previewOpen request in new host view",
        context: [
          "sessionId": request.sessionId,
          "path": request.mediaSources.screenPath,
          "cameraPath": request.mediaSources.cameraPath ?? "nil",
        ])
      v.open(mediaSources: request.mediaSources, sessionId: request.sessionId)
      didOpenPreview = true
      pendingPreviewOpenRequest = nil
    }

    if let request = pendingPreviewSceneRequest {
      if !didOpenPreview,
        let sessionId = request.sessionId
      {
        NativeLogger.i(
          "Preview", "Opening preview from pending scene request in new host view",
          context: [
            "sessionId": sessionId,
            "path": request.scene.mediaSources.screenPath,
            "cameraPath": request.scene.mediaSources.cameraPath ?? "nil",
          ])
        v.open(mediaSources: request.scene.mediaSources, sessionId: sessionId)
        didOpenPreview = true
      }

      NativeLogger.i("Preview", "Applying pending preview scene to new host view")
      v.updateComposition(scene: request.scene)
      pendingPreviewSceneRequest = nil
    }

    if let segments = pendingPreviewZoomSegments {
      NativeLogger.i(
        "Preview", "Applying pending zoom segments to new host view",
        context: ["count": "\(segments.count)"])
      v.updateZoomSegmentsOnly(segments: segments)
      pendingPreviewZoomSegments = nil
    }

    return v
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}
