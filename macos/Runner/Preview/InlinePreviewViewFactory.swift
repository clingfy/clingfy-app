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
var inlinePreviewHostContainerInstance: InlinePreviewHostContainerView?
var inlinePreviewPlayerEventSink: FlutterEventSink?
var workflowLifecycleEventSink: FlutterEventSink?
var pendingPreviewZoomSegments: [ZoomTimelineSegment]?
var pendingPreviewSceneRequest: PendingPreviewSceneRequest?

enum PreviewSceneDeliveryRoute: String {
  case appliedToLiveView
  case queuedPendingScene
}

final class InlinePreviewHostContainerView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer = CALayer()
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
    layer = CALayer()
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  override func layout() {
    super.layout()
    subviews.first?.frame = bounds
  }

  func attachPreviewView(_ previewView: InlinePreviewView) {
    guard previewView.superview !== self else {
      previewView.frame = bounds
      return
    }

    previewView.removeFromSuperview()
    addSubview(previewView)
    previewView.frame = bounds
    previewView.autoresizingMask = [.width, .height]
  }
}

struct PendingPreviewOpenRequest {
  let sessionId: String
  let mediaSources: PreviewMediaSources
}

struct PendingPreviewSceneRequest {
  let sessionId: String?
  let scene: PreviewScene
}

var pendingPreviewOpenRequest: PendingPreviewOpenRequest?

struct PreviewPlaybackSnapshot: Equatable {
  var positionMs: Int
  var isPlaying: Bool

  static let initial = PreviewPlaybackSnapshot(positionMs: 0, isPlaying: true)
}

struct PreviewAudioMixOverride: Equatable {
  let gainDb: Double
  let volumePercent: Double
}

struct PreviewCameraPlacementOverride: Equatable {
  let cameraParams: CameraCompositionParams?
  let changeKind: CameraPreviewChangeKind
}

struct ActiveInlinePreviewState: Equatable {
  var sessionId: String
  var mediaSources: PreviewMediaSources
  var latestScene: PreviewScene?
  var zoomSegments: [ZoomTimelineSegment]?
  var cameraPlacementOverride: PreviewCameraPlacementOverride?
  var audioMixOverride: PreviewAudioMixOverride?
  var playbackSnapshot: PreviewPlaybackSnapshot
}

var activeInlinePreviewState: ActiveInlinePreviewState?

func ensureInlinePreviewContentView(
  viewIdentifier: Int64,
  arguments args: Any?,
  messenger: FlutterBinaryMessenger?
) -> InlinePreviewView {
  if let existing = inlinePreviewViewInstance {
    return existing
  }

  let view = InlinePreviewView(
    viewIdentifier: viewIdentifier,
    arguments: args,
    messenger: messenger
  )
  inlinePreviewViewInstance = view
  return view
}

@discardableResult
func attachExistingInlinePreviewContentViewIfPossible(
  to host: InlinePreviewHostContainerView
) -> Bool {
  guard
    let view = inlinePreviewViewInstance,
    let sessionId = view.currentSessionId,
    let path = view.currentVideoPath
  else {
    return false
  }

  if let state = activeInlinePreviewState {
    guard state.sessionId == sessionId, state.mediaSources.screenPath == path else {
      return false
    }
  }

  view.playerEventSink = inlinePreviewPlayerEventSink
  view.workflowEventSink = workflowLifecycleEventSink
  host.attachPreviewView(view)
  inlinePreviewHostContainerInstance = host
  NativeLogger.i(
    "Preview", "Attached existing inline preview content view to new host",
    context: [
      "sessionId": sessionId,
      "path": path,
    ])
  return true
}

@discardableResult
func disposeInlinePreviewContentViewIfMatching(
  sessionId: String,
  reason: String
) -> Bool {
  guard let view = inlinePreviewViewInstance, view.currentSessionId == sessionId else {
    return false
  }

  view.removeFromSuperview()
  view.dispose(reason: reason)
  inlinePreviewHostContainerInstance = nil
  inlinePreviewViewInstance = nil
  return true
}

func beginActiveInlinePreviewSession(sessionId: String, mediaSources: PreviewMediaSources) {
  if var existing = activeInlinePreviewState, existing.sessionId == sessionId {
    existing.mediaSources = mediaSources
    activeInlinePreviewState = existing
    return
  }

  activeInlinePreviewState = ActiveInlinePreviewState(
    sessionId: sessionId,
    mediaSources: mediaSources,
    latestScene: nil,
    zoomSegments: nil,
    cameraPlacementOverride: nil,
    audioMixOverride: nil,
    playbackSnapshot: .initial
  )
}

func clearAllInlinePreviewState() {
  activeInlinePreviewState = nil
  pendingPreviewOpenRequest = nil
  pendingPreviewZoomSegments = nil
  pendingPreviewSceneRequest = nil
}

func hasPendingPreviewSceneRequest(matching sessionId: String?) -> Bool {
  pendingPreviewSceneRequest?.sessionId == sessionId
}

@discardableResult
func applyPendingPreviewSceneRequestIfMatching(
  sessionId: String?,
  to view: InlinePreviewView
) -> Bool {
  guard
    let request = pendingPreviewSceneRequest,
    request.sessionId == sessionId
  else {
    return false
  }

  NativeLogger.i(
    "Preview", "Applying pending preview scene to host view",
    context: [
      "sessionId": sessionId ?? "nil",
      "path": request.scene.mediaSources.screenPath,
      "cameraPath": request.scene.mediaSources.cameraPath ?? "nil",
    ])
  view.updateComposition(scene: request.scene)
  pendingPreviewSceneRequest = nil
  return true
}

@discardableResult
func routePreviewSceneRequest(
  sessionId: String?,
  scene: PreviewScene
) -> PreviewSceneDeliveryRoute {
  if
    let sessionId,
    let view = inlinePreviewViewInstance,
    view.currentSessionId == sessionId
  {
    view.updateComposition(scene: scene)
    if pendingPreviewSceneRequest?.sessionId == sessionId {
      pendingPreviewSceneRequest = nil
    }
    return .appliedToLiveView
  }

  pendingPreviewSceneRequest = PendingPreviewSceneRequest(
    sessionId: sessionId,
    scene: scene
  )
  return .queuedPendingScene
}

func updateActiveInlinePreviewScene(sessionId: String?, scene: PreviewScene) {
  guard var state = activeInlinePreviewState else { return }
  if let sessionId, state.sessionId != sessionId {
    return
  }

  state.mediaSources = scene.mediaSources
  state.latestScene = scene

  if let override = state.cameraPlacementOverride,
    override.cameraParams == scene.cameraParams
  {
    state.cameraPlacementOverride = nil
  }

  if let override = state.audioMixOverride,
    override.gainDb == scene.screenParams.audioGainDb,
    override.volumePercent == scene.screenParams.audioVolumePercent
  {
    state.audioMixOverride = nil
  }

  activeInlinePreviewState = state
}

func updateActiveInlinePreviewZoomSegments(sessionId: String?, segments: [ZoomTimelineSegment]) {
  guard var state = activeInlinePreviewState else { return }
  if let sessionId, state.sessionId != sessionId {
    return
  }
  state.zoomSegments = segments
  activeInlinePreviewState = state
}

func updateActiveInlinePreviewCameraPlacementOverride(
  sessionId: String?,
  cameraParams: CameraCompositionParams?,
  changeKind: CameraPreviewChangeKind
) {
  guard var state = activeInlinePreviewState else { return }
  if let sessionId, state.sessionId != sessionId {
    return
  }
  state.cameraPlacementOverride = PreviewCameraPlacementOverride(
    cameraParams: cameraParams,
    changeKind: changeKind
  )
  activeInlinePreviewState = state
}

func updateActiveInlinePreviewAudioMixOverride(
  sessionId: String?,
  gainDb: Double,
  volumePercent: Double
) {
  guard var state = activeInlinePreviewState else { return }
  if let sessionId, state.sessionId != sessionId {
    return
  }
  state.audioMixOverride = PreviewAudioMixOverride(
    gainDb: gainDb,
    volumePercent: volumePercent
  )
  activeInlinePreviewState = state
}

func updateActiveInlinePreviewPlaybackSnapshot(
  sessionId: String?,
  positionMs: Int? = nil,
  isPlaying: Bool? = nil
) {
  guard var state = activeInlinePreviewState else { return }
  if let sessionId, state.sessionId != sessionId {
    return
  }
  if let positionMs {
    state.playbackSnapshot.positionMs = max(0, positionMs)
  }
  if let isPlaying {
    state.playbackSnapshot.isPlaying = isPlaying
  }
  activeInlinePreviewState = state
}

@discardableResult
func rehydrateActivePreviewIfNeeded(on view: InlinePreviewView) -> Bool {
  guard let state = activeInlinePreviewState else { return false }

  let needsOpen =
    view.currentSessionId != state.sessionId
    || view.currentVideoPath != state.mediaSources.screenPath

  if needsOpen {
    NativeLogger.i(
      "Preview", "Rehydrating active preview session in new host view",
      context: [
        "sessionId": state.sessionId,
        "path": state.mediaSources.screenPath,
        "cameraPath": state.mediaSources.cameraPath ?? "nil",
      ])
    view.open(
      mediaSources: state.mediaSources,
      sessionId: state.sessionId,
      initialPlaybackSnapshot: state.playbackSnapshot
    )
  }

  if let scene = state.latestScene {
    view.updateComposition(scene: scene)
  }

  if let segments = state.zoomSegments {
    view.updateZoomSegmentsOnly(segments: segments)
  }

  if let audioMixOverride = state.audioMixOverride {
    view.updateAudioMixOnly(
      gainDb: audioMixOverride.gainDb,
      volumePercent: audioMixOverride.volumePercent
    )
  }

  if let cameraPlacementOverride = state.cameraPlacementOverride {
    view.updateCameraPlacementPreview(
      cameraParams: cameraPlacementOverride.cameraParams,
      changeKind: cameraPlacementOverride.changeKind
    )
  }

  view.queuePlaybackRestore(state.playbackSnapshot)
  return true
}

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
        "hasActivePreviewState": activeInlinePreviewState != nil,
      ])
    let host = InlinePreviewHostContainerView(frame: .zero)
    if attachExistingInlinePreviewContentViewIfPossible(to: host) {
      return host
    }

    let v = ensureInlinePreviewContentView(
      viewIdentifier: viewId,
      arguments: args,
      messenger: messenger
    )
    v.playerEventSink = inlinePreviewPlayerEventSink
    v.workflowEventSink = workflowLifecycleEventSink
    host.attachPreviewView(v)
    inlinePreviewHostContainerInstance = host
    var didOpenPreview = false

    if let request = pendingPreviewOpenRequest {
      let hadMatchingPendingScene = hasPendingPreviewSceneRequest(
        matching: request.sessionId
      )
      NativeLogger.i(
        "Preview", "Consuming pending previewOpen request in new host view",
        context: [
          "sessionId": request.sessionId,
          "path": request.mediaSources.screenPath,
          "cameraPath": request.mediaSources.cameraPath ?? "nil",
        ])
      v.open(mediaSources: request.mediaSources, sessionId: request.sessionId)
      didOpenPreview = true
      let consumedPendingScene = applyPendingPreviewSceneRequestIfMatching(
        sessionId: request.sessionId,
        to: v
      )
      NativeLogger.d(
        "Preview", "Pending preview scene status after host open",
        context: [
          "sessionId": request.sessionId,
          "hadMatchingPendingScene": hadMatchingPendingScene,
          "consumedPendingScene": consumedPendingScene,
        ])
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
        let consumedPendingScene = applyPendingPreviewSceneRequestIfMatching(
          sessionId: sessionId,
          to: v
        )
        NativeLogger.d(
          "Preview", "Pending preview scene status after scene-led host open",
          context: [
            "sessionId": sessionId,
            "hadMatchingPendingScene": true,
            "consumedPendingScene": consumedPendingScene,
          ])
      }
    }

    if let segments = pendingPreviewZoomSegments {
      NativeLogger.i(
        "Preview", "Applying pending zoom segments to new host view",
        context: ["count": "\(segments.count)"])
      v.updateZoomSegmentsOnly(segments: segments)
      pendingPreviewZoomSegments = nil
    }

    _ = rehydrateActivePreviewIfNeeded(on: v)

    return host
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}
