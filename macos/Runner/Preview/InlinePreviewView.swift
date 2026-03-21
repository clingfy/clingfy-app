//
//  InlinePreviewView.swift
//  Runner
//
//  Created by Nabil Alhafez on 13/11/2025.
//

import AVFoundation
import Cocoa
import FlutterMacOS
import Foundation

final class InlinePreviewView: NSView {
  private struct PreviewTickState {
    let time: Double
    let frame: CursorFrame?
  }

  struct PreviewUpdatePlan {
    let requiresFullRebuild: Bool
    let refreshCanvasGeometry: Bool
    let refreshMask: Bool
    let refreshBackground: Bool
    let refreshAudioMix: Bool
    let refreshOverlay: Bool
  }

  struct CanvasLayoutMetrics: Equatable {
    let targetSize: CGSize
    let viewSize: CGSize
    let fitScale: CGFloat
    let pixelScale: CGFloat

    var containerCenter: CGPoint {
      CGPoint(x: viewSize.width / 2.0, y: viewSize.height / 2.0)
    }
  }

  private var player: AVPlayer?
  private var playerLayer: AVPlayerLayer?
  private var timeObserver: Any?
  // Observation state
  private var itemObservers: [NSKeyValueObservation] = []
  private var layerReadyObserver: NSKeyValueObservation?
  private let tick = CMTime(value: 1, timescale: 60)
  private let compositionDebounceInterval: TimeInterval = 0.10
  private let backgroundImageQueue = DispatchQueue(
    label: "com.clingfy.preview.background-image", qos: .userInitiated)

  // Retry state for cursor loading
  private var cursorRetryTimer: Timer?
  private var cursorRetryCount = 0
  private let maxCursorRetries = 5

  // Safety net retry for open
  private var openRetryCount = 0
  private var lastOpenRequestTime: Date?

  // Layer Hierarchy
  // 1. self.layer (Root - should be clear)
  // 2. canvasContainer (Centered, scaled to fit view, fixed at targetSize)
  // 3. canvasBackground (Child of container, holds the background color/image)
  // 4. zoomedContentLayer (Handles zoom/pan transform)
  // 5. maskedContentLayer (Handles padding + corner radius mask)
  private var canvasContainer: CALayer?
  private var canvasBackground: CALayer?
  private var zoomedContentLayer: CALayer?
  private var maskedContentLayer: CALayer?

  // Zoom state
  private var smoothZoom: CGFloat = 1.0
  private var smoothCenterX: CGFloat = 0.0
  private var smoothCenterY: CGFloat = 0.0
  private var defaultSpriteID: Int?
  private let zoomHysteresis = ZoomHysteresis()
  private let cursorFrameResolver = CursorFrameResolver()
  private let previewBackgroundImageCache = PreviewBackgroundImageCache()
  private var cursorSpritesByID: [Int: CursorSprite] = [:]
  private var cursorSpriteImages: [Int: CGImage] = [:]

  var playerEventSink: FlutterEventSink?
  var workflowEventSink: FlutterEventSink?
  private var debugTick: Int = 0
  private var lastZoomTime: Double = 0
  private var didLogZoomSmootherProfile: Bool = false

  // Token to prevent race conditions between concurrent open() calls
  private var currentOpenToken: UUID?
  private(set) var currentSessionId: String?

  // Track if we've emitted previewReady for current token
  private var hasEmittedReadyForCurrentToken = false
  private var hasAppliedInitialCompositionForCurrentToken = false
  private var isApplyingInitialCompositionForCurrentToken = false
  private var currentPreviewProfile: PreviewProfile?
  private var pendingCompositionWorkItem: DispatchWorkItem?

  init(
    viewIdentifier viewId: Int64,
    arguments args: Any?,
    messenger: FlutterBinaryMessenger?
  ) {
    super.init(frame: .zero)
    wantsLayer = true
    layer = CALayer()
    layer?.backgroundColor = NSColor.clear.cgColor

    setupLayers()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupLayers()
  }

  private func setupLayers() {
    let container = CALayer()
    container.masksToBounds = true
    container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    container.backgroundColor = NSColor.clear.cgColor

    let bgLayer = CALayer()
    bgLayer.anchorPoint = .zero
    bgLayer.position = .zero
    bgLayer.backgroundColor = NSColor.clear.cgColor  // This will hold our Yellow
    container.addSublayer(bgLayer)

    let zoomed = CALayer()
    zoomed.anchorPoint = .zero
    zoomed.position = .zero
    zoomed.backgroundColor = NSColor.clear.cgColor

    let masked = CALayer()
    masked.masksToBounds = true
    masked.anchorPoint = .zero
    masked.backgroundColor = NSColor.clear.cgColor

    let player = AVPlayer()
    let pLayer = AVPlayerLayer(player: player)

    pLayer.backgroundColor = NSColor.clear.cgColor
    pLayer.videoGravity = .resizeAspectFill

    masked.addSublayer(pLayer)
    zoomed.addSublayer(masked)
    container.addSublayer(zoomed)
    self.layer?.addSublayer(container)

    self.canvasContainer = container
    self.canvasBackground = bgLayer
    self.zoomedContentLayer = zoomed
    self.maskedContentLayer = masked
    self.player = player
    self.playerLayer = pLayer
  }

  override func layout() {
    super.layout()
    updateContainerLayout()
    refreshPreviewProfileForCurrentBounds()
  }

  private func updateContainerLayout() {
    guard
      let params = currentCompositionParams,
      let metrics = Self.canvasLayoutMetrics(
        viewSize: bounds.size,
        backingScale: window?.backingScaleFactor ?? 1.0,
        targetSize: params.targetSize
      )
    else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    applyCanvasGeometry(metrics: metrics)
    updatePreviewMaskLayout(params: params, pixelScale: metrics.pixelScale)
  }  // updateContainerLayout

  private func applyCanvasGeometry(metrics: CanvasLayoutMetrics) {
    guard let container = canvasContainer else { return }

    Self.applyCanvasGeometry(
      container: container,
      backgroundLayer: canvasBackground,
      zoomedLayer: zoomedContentLayer,
      metrics: metrics,
      debugLoggingEnabled: shouldShowDebugVisuals
    )
  }

  private func updatePreviewMaskLayout() {
    guard
      let params = currentCompositionParams,
      let metrics = Self.canvasLayoutMetrics(
        viewSize: bounds.size,
        backingScale: window?.backingScaleFactor ?? 1.0,
        targetSize: params.targetSize
      )
    else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }

    updatePreviewMaskLayout(params: params, pixelScale: metrics.pixelScale)
  }

  private func updatePreviewMaskLayout(params: CompositionParams, pixelScale: CGFloat) {
    guard currentLayout != nil else { return }
    if let layout = currentLayout {
      applyPreviewMask(from: params, layout: layout, pixelScale: pixelScale)
    }
  }

  private func makePreviewProfile(for params: CompositionParams) -> PreviewProfile {
    PreviewProfile.make(
      viewBounds: bounds.size,
      backingScale: window?.backingScaleFactor ?? 2.0,
      targetSize: params.targetSize,
      fpsHint: params.fpsHint
    )
  }

  private func previewCanvasPixelSize(for targetSize: CGSize) -> CGSize {
    PreviewProfile.make(
      viewBounds: bounds.size,
      backingScale: window?.backingScaleFactor ?? 2.0,
      targetSize: targetSize,
      fpsHint: PreviewProfile.defaultFps
    ).canvasRenderSize
  }

  private static func shouldRebuildPreviewProfile(old: PreviewProfile?, new: PreviewProfile) -> Bool {
    old != new
  }

  private func refreshPreviewProfileForCurrentBounds() {
    guard
      let params = currentCompositionParams,
      currentLayout != nil
    else { return }

    let newProfile = makePreviewProfile(for: params)
    guard Self.shouldRebuildPreviewProfile(old: currentPreviewProfile, new: newProfile) else {
      return
    }

    scheduleCompositionUpdate(
      params: params,
      reason: "boundsChanged",
      forceImmediate: false
    )
  }

  private func clampAudioGainDb(_ value: Double) -> Double {
    return max(0, min(24, value))
  }

  private func clampAudioVolumePercent(_ value: Double) -> Double {
    return max(0, min(100, value))
  }

  private func applyAudioMix(to item: AVPlayerItem, gainDb: Double, volumePercent: Double) {
    item.audioMix = AudioMixEngine.makeAudioMix(
      asset: item.asset,
      volumePercent: clampAudioVolumePercent(volumePercent),
      gainDb: clampAudioGainDb(gainDb)
    )
  }

  func open(path: String, sessionId: String) {
    // Generate a new token for this open operation
    let openToken = UUID()
    currentOpenToken = openToken
    currentSessionId = sessionId
    hasEmittedReadyForCurrentToken = false
    hasAppliedInitialCompositionForCurrentToken = false
    isApplyingInitialCompositionForCurrentToken = false
    pendingCompositionWorkItem?.cancel()
    pendingCompositionWorkItem = nil
    currentLayout = nil
    currentPreviewProfile = nil
    setPreviewContentVisible(false)

    NativeLogger.i(
      "Player", "InlinePreviewView.open called",
      context: [
        "path": path,
        "sessionId": sessionId,
        "token": openToken.uuidString,
        "previousPath": currentVideoPath ?? "nil",
      ])

    // Emit previewPreparing event immediately
    emitPreviewLifecycleEvent(
      type: "previewPreparing",
      sessionId: sessionId,
      path: path,
      token: openToken
    )

    // Fully tear down previous state
    teardownPlayerObservers()

    self.currentVideoPath = path
    let url = URL(fileURLWithPath: path)
    lastOpenRequestTime = Date()

    // Resilient cursor loading
    cancelCursorRetry()
    clearCursorCaches()
    loadCursorWithRetry(path: path, token: openToken, attempt: 1)

    // Reset cursor layer
    cursorLayer?.removeFromSuperlayer()
    cursorLayer = nil

    // Reset Zoom State completely
    resetZoomState(clearDefaultSpriteID: true)
    lastZoomTime = 0
    debugTick = 0
    didLogZoomSmootherProfile = false

    // Create new asset and player item
    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)

    // Make seeking wait for video composition rendering (improves seek accuracy)
    if #available(macOS 10.13, *) {
      item.seekingWaitsForVideoCompositionRendering = true
    }

    // Replace player item
    if let player = player {
      player.replaceCurrentItem(with: item)
    }

    // Set up observers for the new item
    observeTicks()
    observeCurrentItem(for: openToken)

    // Start playback
    player?.play()

    // DO NOT apply composition yet. It will be applied in checkAndEmitPreviewReady
    // when both item and layer are ready, preventing race conditions.
    NativeLogger.d("Player", "Deferred composition until readyToPlay")

    emitCurrentState()
    sendState(state: "playing")

    NativeLogger.d(
      "Player", "InlinePreviewView.open completed", context: ["token": openToken.uuidString])
  }

  static func previewLifecycleEventPayload(
    type: String,
    sessionId: String,
    path: String,
    token: UUID,
    reason: String? = nil,
    error: String? = nil
  ) -> [String: Any] {
    var event: [String: Any] = [
      "type": type,
      "sessionId": sessionId,
      "path": path,
      "token": token.uuidString,
    ]

    if let reason = reason {
      event["reason"] = reason
    }

    if let error = error {
      event["error"] = error
    }

    return event
  }

  static func canEmitPreviewReady(
    hasEmittedReady: Bool,
    tokenMatches: Bool,
    itemReady: Bool,
    layerReady: Bool,
    initialCompositionApplied: Bool
  ) -> Bool {
    !hasEmittedReady && tokenMatches && itemReady && layerReady && initialCompositionApplied
  }

  static func previewUpdatePlan(
    from oldParams: CompositionParams,
    to newParams: CompositionParams,
    oldProfile: PreviewProfile,
    newProfile: PreviewProfile
  ) -> PreviewUpdatePlan {
    let requiresFullRebuild =
      shouldRebuildPreviewProfile(old: oldProfile, new: newProfile)
      || oldParams.targetSize != newParams.targetSize
      || oldParams.padding != newParams.padding
      || oldParams.fitMode != newParams.fitMode

    if requiresFullRebuild {
      return PreviewUpdatePlan(
        requiresFullRebuild: true,
        refreshCanvasGeometry: true,
        refreshMask: true,
        refreshBackground: true,
        refreshAudioMix: true,
        refreshOverlay: true
      )
    }

    return PreviewUpdatePlan(
      requiresFullRebuild: false,
      refreshCanvasGeometry: false,
      refreshMask: oldParams.cornerRadius != newParams.cornerRadius,
      refreshBackground:
        oldParams.backgroundColor != newParams.backgroundColor
        || oldParams.backgroundImagePath != newParams.backgroundImagePath,
      refreshAudioMix:
        oldParams.audioGainDb != newParams.audioGainDb
        || oldParams.audioVolumePercent != newParams.audioVolumePercent,
      refreshOverlay:
        oldParams.showCursor != newParams.showCursor
        || oldParams.cursorSize != newParams.cursorSize
        || oldParams.zoomFactor != newParams.zoomFactor
        || oldParams.zoomSegments != newParams.zoomSegments
        || oldParams.zoomEnabled != newParams.zoomEnabled
    )
  }

  static func canvasLayoutMetrics(
    viewSize: CGSize,
    backingScale: CGFloat,
    targetSize: CGSize
  ) -> CanvasLayoutMetrics? {
    guard targetSize.width > 0 && targetSize.height > 0 else { return nil }

    let fitScale = min(viewSize.width / targetSize.width, viewSize.height / targetSize.height)
    let safeBackingScale = backingScale > 0 ? backingScale : 1.0

    return CanvasLayoutMetrics(
      targetSize: targetSize,
      viewSize: viewSize,
      fitScale: fitScale,
      pixelScale: fitScale * safeBackingScale
    )
  }

  static func applyCanvasGeometry(
    container: CALayer,
    backgroundLayer: CALayer?,
    zoomedLayer: CALayer?,
    metrics: CanvasLayoutMetrics,
    debugLoggingEnabled: Bool = false
  ) {
    let contentBounds = CGRect(origin: .zero, size: metrics.targetSize)

    // Avoid recomputing transformed geometry from `frame` while zoom is active.
    let savedZoomTransform = zoomedLayer?.affineTransform() ?? .identity
    zoomedLayer?.setAffineTransform(.identity)

    container.bounds = contentBounds
    container.position = metrics.containerCenter
    container.setAffineTransform(CGAffineTransform(scaleX: metrics.fitScale, y: metrics.fitScale))

    backgroundLayer?.bounds = contentBounds
    backgroundLayer?.position = .zero

    zoomedLayer?.bounds = contentBounds
    zoomedLayer?.position = .zero
    zoomedLayer?.setAffineTransform(savedZoomTransform)

    if debugLoggingEnabled {
      NativeLogger.d(
        "PreviewLayout",
        "zoomed layer geometry",
        context: [
          "viewSize": "\(metrics.viewSize)",
          "targetSize": "\(metrics.targetSize)",
          "fitScale": metrics.fitScale,
          "bounds": "\(zoomedLayer?.bounds ?? .zero)",
          "position": "\(zoomedLayer?.position ?? .zero)",
          "frame": "\(zoomedLayer?.frame ?? .zero)",
          "transform": "\(zoomedLayer?.affineTransform() ?? .identity)",
        ]
      )
    }
  }

  /// Emit preview lifecycle event to Flutter
  private func emitPreviewLifecycleEvent(
    type: String,
    sessionId: String,
    path: String,
    token: UUID,
    reason: String? = nil,
    error: String? = nil
  ) {
    NativeLogger.i(
      "Player", "Emitting preview lifecycle event",
      context: [
        "type": type,
        "sessionId": sessionId,
        "path": path,
        "token": token.uuidString,
        "reason": reason ?? "nil",
        "error": error ?? "nil",
      ])

    workflowEventSink?(
      Self.previewLifecycleEventPayload(
        type: type,
        sessionId: sessionId,
        path: path,
        token: token,
        reason: reason,
        error: error
      ))
  }

  private func emitPlayerEvent(_ event: [String: Any]) {
    guard let sessionId = currentSessionId else { return }
    var payload = event
    payload["sessionId"] = sessionId
    playerEventSink?(payload)
  }

  private func setPreviewContentVisible(_ visible: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    canvasContainer?.opacity = visible ? 1.0 : 0.0
    CATransaction.commit()
  }

  func play() {
    player?.play()
    sendState(state: "playing")
  }

  func pause() {
    player?.pause()
    sendState(state: "paused")
  }

  func seekTo(milliseconds: Int) {
    guard let player = player else { return }
    let seconds = Double(milliseconds) / 1000.0

    /// If seeking backwards, reset zoom/hysteresis
    if seconds + 0.0001 < lastZoomTime {
      resetZoomState()
    }
    lastZoomTime = seconds
    ///

    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    sendTick(position: time)
  }
  /// Fully tears down observers and notifications from previous player item
  private func teardownPlayerObservers() {
    cancelCursorRetry()
    pendingCompositionWorkItem?.cancel()
    pendingCompositionWorkItem = nil

    // Remove time observer
    if let obs = timeObserver, let player = player {
      player.removeTimeObserver(obs)
    }
    timeObserver = nil

    // Invalidate KVO observers
    itemObservers.forEach { $0.invalidate() }
    itemObservers.removeAll()

    // Invalidate layer ready observer
    layerReadyObserver?.invalidate()
    layerReadyObserver = nil

    // Remove all notification observers for this object
    NotificationCenter.default.removeObserver(self)
  }

  private func cancelCursorRetry() {
    cursorRetryTimer?.invalidate()
    cursorRetryTimer = nil
  }
  ////

  public func resetPlayback(reason: String = "reset") {
    let closingSessionId = currentSessionId
    let closingPath = currentVideoPath
    let closingToken = currentOpenToken
    teardownPlayerObservers()

    // Cancel seeks/loading for current item
    if let item = player?.currentItem {
      item.cancelPendingSeeks()
      item.asset.cancelLoading()
    }

    player?.replaceCurrentItem(with: nil)
    setPreviewContentVisible(false)

    // Reset state that depends on current item
    currentVideoPath = nil
    currentSessionId = nil
    currentOpenToken = nil
    hasEmittedReadyForCurrentToken = false
    hasAppliedInitialCompositionForCurrentToken = false
    isApplyingInitialCompositionForCurrentToken = false
    openRetryCount = 0
    lastOpenRequestTime = nil
    currentLayout = nil
    currentPreviewProfile = nil
    pendingCompositionParams = nil
    pendingZoomSegments = nil

    cursorLayer?.removeFromSuperlayer()
    cursorLayer = nil
    clearCursorCaches()

    resetZoomState(clearDefaultSpriteID: true)
    lastZoomTime = 0

    if let sessionId = closingSessionId,
      let path = closingPath,
      let token = closingToken
    {
      emitPreviewLifecycleEvent(
        type: "previewClosed",
        sessionId: sessionId,
        path: path,
        token: token,
        reason: reason
      )
    }
  }
  func dispose(reason: String = "dispose") {
    resetPlayback(reason: reason)

    playerLayer?.player = nil
    playerLayer?.removeFromSuperlayer()
    playerLayer = nil

    player = nil
  }
  deinit {
    resetPlayback(reason: "deinit")
  }

  private func observeCurrentItem(for token: UUID) {
    itemObservers.forEach { $0.invalidate() }
    itemObservers.removeAll()

    guard let item = player?.currentItem else { return }

    let obs1 = item.observe(\.status) { [weak self] observedItem, _ in
      guard let self else { return }

      // Check if this callback is for the current open token
      if self.currentOpenToken != token {
        NativeLogger.d(
          "Player", "Ignoring status change from stale open",
          context: [
            "observedToken": token.uuidString,
            "currentToken": self.currentOpenToken?.uuidString ?? "nil",
          ])
        return
      }

      let status = observedItem.status
      NativeLogger.d(
        "Player", "AVPlayerItem status changed",
        context: [
          "status": statusString(status),
          "token": token.uuidString,
        ])

      if status == .failed {
        if let error = observedItem.error {
          // Safety Net Retry
          let now = Date()
          let timeSinceOpen = now.timeIntervalSince(self.lastOpenRequestTime ?? now)

          if self.openRetryCount < 1 && timeSinceOpen < 2.0 {
            self.openRetryCount += 1
            let retryPath = self.currentVideoPath ?? ""
            NativeLogger.w(
              "Player", "AVPlayerItem failed early, triggering safety net retry",
              context: [
                "path": retryPath,
                "attempt": self.openRetryCount,
                "timeSinceOpen": timeSinceOpen,
              ])

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
              guard let self = self else { return }
              // Only retry if the path hasn't changed
              if self.currentVideoPath == retryPath, let sessionId = self.currentSessionId {
                self.open(path: retryPath, sessionId: sessionId)
              }
            }
            return  // Wait for the retry
          }

          NativeLogger.e(
            "Player", "AVPlayerItem failed",
            context: [
              "error": error.localizedDescription,
              "token": token.uuidString,
            ])

          // Emit previewFailed event
          if let path = self.currentVideoPath,
            let sessionId = self.currentSessionId,
            !self.hasEmittedReadyForCurrentToken
          {
            self.emitPreviewLifecycleEvent(
              type: "previewFailed",
              sessionId: sessionId,
              path: path,
              token: token,
              reason: "AVPlayerItem failed",
              error: error.localizedDescription
            )
            self.hasEmittedReadyForCurrentToken = true
          }
        }
      } else if status == .readyToPlay {
        // Reset retry count on success
        self.openRetryCount = 0
        // Player item is ready, but we need to check if layer is ready too
        self.checkAndEmitPreviewReady(token: token)
      }

      self.emitCurrentState()
    }

    let obs2 = item.observe(\.duration) { [weak self] _, _ in
      guard let self else { return }

      // Check token
      if self.currentOpenToken != token {
        return
      }

      self.emitCurrentState()
    }

    itemObservers = [obs1, obs2]

    // Observe playerLayer.isReadyForDisplay
    if let playerLayer = self.playerLayer {
      layerReadyObserver = playerLayer.observe(\.isReadyForDisplay, options: [.new]) {
        [weak self] layer, change in
        guard let self else { return }

        if self.currentOpenToken != token {
          return
        }

        let isReady = change.newValue ?? false
        NativeLogger.d(
          "Player", "playerLayer.isReadyForDisplay changed",
          context: [
            "isReady": isReady,
            "token": token.uuidString,
          ])

        if isReady {
          self.checkAndEmitPreviewReady(token: token)
        }
      }
    }

    // Add completion observer
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(playerDidFinishPlaying),
      name: .AVPlayerItemDidPlayToEndTime,
      object: item
    )
  }

  /// Check if both player item and layer are ready, then emit previewReady
  private func checkAndEmitPreviewReady(token: UUID) {
    guard currentOpenToken == token else { return }
    guard let item = player?.currentItem, item.status == .readyToPlay else { return }
    guard let playerLayer = self.playerLayer, playerLayer.isReadyForDisplay else { return }

    if !hasAppliedInitialCompositionForCurrentToken {
      if isApplyingInitialCompositionForCurrentToken {
        return
      }

      if let params = pendingCompositionParams ?? currentCompositionParams {
        NativeLogger.i("Player", "Applying deferred composition before previewReady")
        isApplyingInitialCompositionForCurrentToken = true
        scheduleCompositionUpdate(
          params: params,
          reason: "previewReady",
          forceImmediate: true,
          onApplied: { [weak self] success in
            guard let self else { return }
            guard self.currentOpenToken == token else { return }
            self.isApplyingInitialCompositionForCurrentToken = false
            guard success else { return }
            self.hasAppliedInitialCompositionForCurrentToken = true
            self.finishPreviewReadyIfPossible(token: token)
          }
        )
        return
      }

      hasAppliedInitialCompositionForCurrentToken = true
    }

    finishPreviewReadyIfPossible(token: token)
  }

  private func finishPreviewReadyIfPossible(token: UUID) {
    guard
      let item = player?.currentItem,
      let playerLayer = self.playerLayer,
      Self.canEmitPreviewReady(
        hasEmittedReady: hasEmittedReadyForCurrentToken,
        tokenMatches: currentOpenToken == token,
        itemReady: item.status == .readyToPlay,
        layerReady: playerLayer.isReadyForDisplay,
        initialCompositionApplied: hasAppliedInitialCompositionForCurrentToken
      )
    else {
      return
    }

    guard let path = currentVideoPath, let sessionId = currentSessionId else { return }

    NativeLogger.i(
      "Player", "Preview is fully ready",
      context: [
        "path": path,
        "token": token.uuidString,
      ])

    setPreviewContentVisible(true)
    emitPreviewLifecycleEvent(
      type: "previewReady",
      sessionId: sessionId,
      path: path,
      token: token
    )
    hasEmittedReadyForCurrentToken = true
  }

  // MARK: - Resilient Loading Logic
  private func loadCursorWithRetry(path: String, token: UUID, attempt: Int) {
    let url = URL(fileURLWithPath: path)
    let cursorDataURL = url.deletingPathExtension().appendingPathExtension("cursor.json")

    NativeLogger.d(
      "Player", "Attempting to load cursor recording",
      context: [
        "attempt": attempt,
        "path": cursorDataURL.path,
      ])

    if let data = try? Data(contentsOf: cursorDataURL),
      let recording = try? JSONDecoder().decode(CursorRecording.self, from: data)
    {

      guard currentOpenToken == token, currentVideoPath == path else {
        NativeLogger.d(
          "Player", "Ignoring cursor load from stale preview",
          context: ["path": path, "token": token.uuidString]
        )
        return
      }

      self.cursorRecording = recording
      cursorFrameResolver.reset(with: recording)
      cursorSpritesByID = Dictionary(uniqueKeysWithValues: recording.sprites.map { ($0.id, $0) })
      cursorSpriteImages = recording.sprites.reduce(into: [:]) { result, sprite in
        if let image = makeCGImage(from: sprite) {
          result[sprite.id] = image
        }
      }
      defaultSpriteID =
        recording.frames.first(where: { isInBounds($0) })?.spriteID
        ?? recording.frames.first(where: { $0.spriteID >= 0 })?.spriteID

      NativeLogger.i(
        "Player", "Successfully loaded cursor recording",
        context: [
          "frames": recording.frames.count,
          "sprites": recording.sprites.count,
          "attempt": attempt,
        ])

      // If we already have composition params and layout, we should trigger a redraw
      if currentCompositionParams != nil {
        applyPreviewOverlayState(at: player?.currentTime().seconds ?? 0, snap: true)
      }
    } else {
      if attempt < maxCursorRetries {
        let delay = Double(attempt) * 0.2  // 0.2s, 0.4s, 0.6s, etc.
        NativeLogger.w(
          "Player", "Cursor file missing or corrupt, scheduling retry",
          context: [
            "attempt": attempt,
            "delay": delay,
          ])
        cursorRetryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) {
          [weak self] _ in
          self?.loadCursorWithRetry(path: path, token: token, attempt: attempt + 1)
        }
      } else {
        NativeLogger.e(
          "Player", "Failed to load cursor recording after \(maxCursorRetries) attempts")
        if currentOpenToken == token, currentVideoPath == path {
          clearCursorCaches()
        }
      }
    }
  }

  private func statusString(_ status: AVPlayerItem.Status) -> String {
    switch status {
    case .unknown: return "unknown"
    case .readyToPlay: return "readyToPlay"
    case .failed: return "failed"
    @unknown default: return "unknown(\(status.rawValue))"
    }
  }

  @objc private func playerDidFinishPlaying(note: NSNotification) {
    // Seek to zero
    let targetTime = CMTime.zero
    player?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)

    resetZoomState()
    lastZoomTime = 0

    // Send tick for 0
    sendTick(position: targetTime)

    // Send state completed
    sendState(state: "completed")
  }

  private func observeTicks() {
    guard let player = player else { return }
    if let obs = timeObserver {
      player.removeTimeObserver(obs)
    }
    timeObserver = player.addPeriodicTimeObserver(forInterval: tick, queue: .main) {
      [weak self] time in
      guard let self else { return }
      self.sendTick(position: time)
    }
  }

  private func sendTick(position: CMTime) {
    guard let duration = player?.currentItem?.duration else { return }

    let posSeconds = CMTimeGetSeconds(position)
    let durSeconds = CMTimeGetSeconds(duration)

    let posMs = (posSeconds.isNaN || posSeconds.isInfinite) ? 0 : Int(posSeconds * 1000)
    let durMs = (durSeconds.isNaN || durSeconds.isInfinite) ? 0 : Int(durSeconds * 1000)

    let t = (posSeconds.isNaN || posSeconds.isInfinite) ? 0 : posSeconds
    let tickState = PreviewTickState(time: t, frame: cursorFrameResolver.frame(at: t))

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    updateCursorLayer(tick: tickState)
    updateZoom(tick: tickState)

    emitPlayerEvent([
      "type": "playerTick",
      "positionMs": posMs,
      "durationMs": durMs,
    ])
  }

  private func sendState(state: String) {
    emitPlayerEvent([
      "type": "playerState",
      "state": state,
    ])
  }

  private let builder = CompositionBuilder()
  private var cursorRecording: CursorRecording?
  private var cursorLayer: CALayer?
  private var currentCompositionParams: CompositionParams?
  private var currentLayout: CompositionBuilder.PreviewCompositionResult?
  private var pendingCompositionParams: CompositionParams?
  private var pendingZoomSegments: [ZoomTimelineSegment]?

  private(set) var currentVideoPath: String?

  func updateComposition(params: CompositionParams) {
    scheduleCompositionUpdate(
      params: params,
      reason: "externalUpdate",
      forceImmediate: false,
      onApplied: nil
    )
  }

  private func scheduleCompositionUpdate(
    params: CompositionParams,
    reason: String,
    forceImmediate: Bool,
    onApplied: ((Bool) -> Void)? = nil
  ) {
    NativeLogger.d(
      "Player", "updateComposition called",
      context: [
        "reason": reason,
        "currentPath": currentVideoPath ?? "nil",
        "hasAsset": player?.currentItem?.asset != nil,
      ])

    guard let asset = player?.currentItem?.asset else {
      NativeLogger.d("Player", "No asset yet, storing params as pending")
      pendingCompositionParams = params
      return
    }
    let mergedParams = paramsApplyingPendingZoomSegments(into: params)
    pendingCompositionParams = mergedParams

    let newProfile = makePreviewProfile(for: mergedParams)

    if
      let currentParams = currentCompositionParams,
      let currentProfile = currentPreviewProfile,
      currentLayout != nil
    {
      let updatePlan = Self.previewUpdatePlan(
        from: currentParams,
        to: mergedParams,
        oldProfile: currentProfile,
        newProfile: newProfile
      )

      if !updatePlan.requiresFullRebuild {
        pendingCompositionWorkItem?.cancel()
        pendingCompositionWorkItem = nil
        pendingCompositionParams = nil
        applyLightweightPreviewUpdate(
          to: mergedParams,
          updatePlan: updatePlan,
          profile: newProfile,
          onApplied: onApplied
        )
        return
      }
    }

    let shouldApplyImmediately = forceImmediate || currentLayout == nil || currentPreviewProfile == nil
    if shouldApplyImmediately {
      pendingCompositionWorkItem?.cancel()
      pendingCompositionWorkItem = nil
      applyCompositionNow(
        params: mergedParams,
        profile: newProfile,
        asset: asset,
        reason: reason,
        onApplied: onApplied
      )
      return
    }

    let scheduledToken = currentOpenToken
    pendingCompositionWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      guard self.currentOpenToken == scheduledToken else { return }
      guard let latestAsset = self.player?.currentItem?.asset else { return }

      let latestParams = self.pendingCompositionParams ?? mergedParams
      let latestProfile = self.makePreviewProfile(for: latestParams)
      self.applyCompositionNow(
        params: latestParams,
        profile: latestProfile,
        asset: latestAsset,
        reason: "debounced:\(reason)",
        onApplied: onApplied
      )
    }

    pendingCompositionWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + compositionDebounceInterval,
      execute: workItem
    )
  }

  private func paramsApplyingPendingZoomSegments(into params: CompositionParams) -> CompositionParams {
    guard let pending = pendingZoomSegments else { return params }
    var updated = params
    updated.zoomSegments = pending
    pendingZoomSegments = nil
    return updated
  }

  private func applyLightweightPreviewUpdate(
    to newParams: CompositionParams,
    updatePlan: PreviewUpdatePlan,
    profile: PreviewProfile,
    onApplied: ((Bool) -> Void)? = nil
  ) {
    currentCompositionParams = newParams
    currentPreviewProfile = profile

    if updatePlan.refreshCanvasGeometry {
      updateContainerLayout()
    }

    if updatePlan.refreshBackground {
      applyPreviewBackground(from: newParams, profile: profile)
    }

    if updatePlan.refreshMask {
      updatePreviewMaskLayout()
    }

    if updatePlan.refreshAudioMix, let item = player?.currentItem {
      applyAudioMix(
        to: item,
        gainDb: newParams.audioGainDb,
        volumePercent: newParams.audioVolumePercent
      )
    }

    if updatePlan.refreshOverlay {
      applyPreviewOverlayState(at: player?.currentTime().seconds ?? 0, snap: true)
    }

    applyDebugVisualsIfNeeded()
    onApplied?(true)
  }

  private func applyCompositionNow(
    params: CompositionParams,
    profile: PreviewProfile,
    asset: AVAsset,
    reason: String,
    onApplied: ((Bool) -> Void)? = nil
  ) {
    pendingCompositionWorkItem = nil

    let currentTime = player?.currentTime() ?? .zero
    let wasPlaying = (player?.rate ?? 0) != 0
    if wasPlaying {
      player?.pause()
    }

    NativeLogger.d(
      "Player", "Applying preview composition",
      context: [
        "reason": reason,
        "currentTime": "\(CMTimeGetSeconds(currentTime))s",
        "wasPlaying": wasPlaying,
        "renderSize": "\(Int(profile.canvasRenderSize.width))x\(Int(profile.canvasRenderSize.height))",
        "fps": profile.fps,
      ])

    if let path = currentVideoPath {
      let exists = FileManager.default.fileExists(atPath: path)
      NativeLogger.d(
        "Player", "updateComposition: file check",
        context: [
          "path": path,
          "exists": exists,
        ])

      if !exists {
        NativeLogger.e("Player", "VIDEO_FILE_MISSING", context: ["path": path])
        player?.pause()
        emitPlayerEvent([
          "type": "playerError",
          "code": "VIDEO_FILE_MISSING",
          "message": "Recording file was moved or deleted \(path).",
        ])
        onApplied?(false)
        return
      }
    }

    if params.showCursor && cursorRecording == nil {
      NativeLogger.w("Player", "Cursor requested but cursorRecording is nil")
      emitPlayerEvent([
        "type": "playerWarning",
        "code": "CURSOR_FILE_MISSING",
        "message": "Cursor data is missing. Cursor effects are disabled.",
      ])
    }

    NativeLogger.d("Player", "Building preview composition")
    guard let layout = builder.buildPreview(asset: asset, params: params, profile: profile) else {
      NativeLogger.e(
        "Player", "ASSET_INVALID: buildPreview returned nil",
        context: [
          "path": currentVideoPath ?? "nil",
          "assetType": "\(type(of: asset))",
        ])

      if let path = currentVideoPath,
        let token = currentOpenToken,
        let sessionId = currentSessionId,
        !hasEmittedReadyForCurrentToken
      {
        emitPreviewLifecycleEvent(
          type: "previewFailed",
          sessionId: sessionId,
          path: path,
          token: token,
          reason: "ASSET_INVALID",
          error: "Failed to prepare video preview"
        )
        hasEmittedReadyForCurrentToken = true
      }

      emitPlayerEvent([
        "type": "playerError",
        "code": "ASSET_INVALID",
        "message": "Failed to prepare video preview.",
      ])
      onApplied?(false)
      return
    }

    currentCompositionParams = params
    currentLayout = layout
    currentPreviewProfile = profile
    pendingCompositionParams = nil

    if let item = player?.currentItem {
      item.videoComposition = layout.composition
      if #available(macOS 10.15, *) {
        item.preferredMaximumResolution = layout.renderSize
      }
      applyAudioMix(
        to: item,
        gainDb: params.audioGainDb,
        volumePercent: params.audioVolumePercent
      )
    }

    let seekTolerance = CMTime(
      seconds: 1.0 / Double(max(profile.fps, 1)),
      preferredTimescale: 600
    )
    if currentTime != .zero {
      player?.seek(to: currentTime, toleranceBefore: seekTolerance, toleranceAfter: seekTolerance)
      NativeLogger.d(
        "Player", "Restored playback position",
        context: ["time": "\(CMTimeGetSeconds(currentTime))s"]
      )
    }

    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.contents = nil
    updateContainerLayout()
    applyPreviewBackground(from: params, profile: profile)
    applyDebugVisualsIfNeeded()
    applyPreviewOverlayState(at: currentTime.seconds.isFinite ? currentTime.seconds : 0, snap: true)
    needsDisplay = true

    if wasPlaying {
      player?.play()
      NativeLogger.d("Player", "Restored playback state: playing")
    } else {
      NativeLogger.d("Player", "Playback state: paused")
    }

    onApplied?(true)
  }

  func updateAudioGainOnly(gainDb: Double) {
    let volumePercent = currentCompositionParams?.audioVolumePercent ?? 100.0
    updateAudioMixOnly(gainDb: gainDb, volumePercent: volumePercent)
  }

  func updateAudioMixOnly(gainDb: Double, volumePercent: Double) {
    guard let item = player?.currentItem else { return }

    // Update local state so if updateComposition is called later, it uses the new audio mix.
    if let params = currentCompositionParams {
      let updatedParams = CompositionParams(
        targetSize: params.targetSize,
        padding: params.padding,
        cornerRadius: params.cornerRadius,
        backgroundColor: params.backgroundColor,
        backgroundImagePath: params.backgroundImagePath,
        cursorSize: params.cursorSize,
        showCursor: params.showCursor,
        zoomEnabled: params.zoomEnabled,
        zoomFactor: params.zoomFactor,
        followStrength: params.followStrength,
        fpsHint: params.fpsHint,
        fitMode: params.fitMode,
        audioGainDb: clampAudioGainDb(gainDb),
        audioVolumePercent: clampAudioVolumePercent(volumePercent),
        zoomSegments: params.zoomSegments
      )
      self.currentCompositionParams = updatedParams
    }

    applyAudioMix(to: item, gainDb: gainDb, volumePercent: volumePercent)

    NativeLogger.d(
      "Player", "updateAudioMixOnly: applied",
      context: [
        "gainDb": gainDb,
        "volumePercent": volumePercent,
        "tracks": item.asset.tracks(withMediaType: .audio).count,
      ])
  }

  func updateZoomSegmentsOnly(segments: [ZoomTimelineSegment]) {
    guard var params = currentCompositionParams, currentLayout != nil else {
      pendingZoomSegments = segments
      NativeLogger.d(
        "Player", "updateZoomSegmentsOnly: stored pending segments",
        context: ["count": segments.count])
      self.needsDisplay = true
      return
    }
    params.zoomSegments = segments
    self.currentCompositionParams = params
    pendingZoomSegments = nil

    // Force immediate visual update WITHOUT interpolation (snap: true)
    applyPreviewOverlayState(at: player?.currentTime().seconds ?? 0, snap: true)
    needsDisplay = true

    NativeLogger.d(
      "Player", "updateZoomSegmentsOnly: updated segments and forced redraw",
      context: ["count": segments.count])
  }

  private func applyPreviewOverlayState(at time: Double, snap: Bool) {
    let normalizedTime = time.isFinite ? time : 0
    let tick = PreviewTickState(
      time: normalizedTime,
      frame: cursorFrameResolver.frame(at: normalizedTime)
    )

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    updateCursorLayer(tick: tick)
    updateZoom(tick: tick, snap: snap)
    CATransaction.commit()
  }

  // MARK: - Update Cursor
  private func updateCursorLayer(tick: PreviewTickState) {
    guard
      let params = currentCompositionParams,
      params.showCursor,
      let layout = currentLayout,
      let zoomedLayer = zoomedContentLayer,
      let frame = tick.frame,
      isInBounds(frame),
      let sprite = cursorSpritesByID[frame.spriteID],
      let spriteImage = cursorSpriteImages[frame.spriteID]
    else {
      cursorLayer?.isHidden = true
      return
    }

    if cursorLayer == nil {
      let cl = CALayer()
      cl.zPosition = 10
      cl.masksToBounds = false
      zoomedLayer.addSublayer(cl)
      cursorLayer = cl
    }

    if cursorLayer?.name != "\(frame.spriteID)" {
      cursorLayer?.contents = spriteImage
      cursorLayer?.name = "\(frame.spriteID)"
    }

    guard let cursorLayer = cursorLayer else { return }
    cursorLayer.isHidden = false
    cursorLayer.contentsGravity = .resizeAspect

    let logicalContentFrame = layout.contentFrame
    let nx = frame.x
    let ny = 1.0 - frame.y

    let cursorLogicalX = logicalContentFrame.origin.x + nx * logicalContentFrame.width
    let cursorLogicalY = logicalContentFrame.origin.y + ny * logicalContentFrame.height

    let finalScale = CGFloat(params.cursorSize) * layout.videoToTargetScale
    let spriteWidth = CGFloat(sprite.width) * finalScale
    let spriteHeight = CGFloat(sprite.height) * finalScale
    let hotspotX = CGFloat(sprite.hotspotX) * finalScale
    let hotspotY = CGFloat(sprite.hotspotY) * finalScale

    let originX = cursorLogicalX - hotspotX
    let originY = cursorLogicalY - (spriteHeight - hotspotY)

    cursorLayer.frame = CGRect(
      x: originX,
      y: originY,
      width: spriteWidth,
      height: spriteHeight
    )
  }

  private func isInBounds(_ f: CursorFrame) -> Bool {
    (0.0...1.0).contains(f.x) && (0.0...1.0).contains(f.y) && f.spriteID >= 0
  }

  // MARK: - Update Zoom
  private func updateZoom(tick: PreviewTickState, snap: Bool = false) {
    let time = tick.time
    // If time jumped backwards (replay/seek), reset hysteresis + zoom state
    if time + 0.0001 < lastZoomTime {
      resetZoomState()
      lastZoomTime = 0
    }

    let dt: Double
    if snap {
      dt = 1.0 / 60.0
    } else if lastZoomTime > 0 {
      dt = ZoomFollowSmoother.clampedDtSeconds(time - lastZoomTime)
    } else {
      dt = 1.0 / 60.0
    }
    lastZoomTime = time

    guard
      let params = currentCompositionParams,
      params.zoomEnabled,
      let layout = self.currentLayout,
      let zoomedLayer = self.zoomedContentLayer
    else {
      self.zoomedContentLayer?.setAffineTransform(.identity)
      return
    }

    guard let frame = tick.frame else {
      zoomedLayer.setAffineTransform(.identity)
      return
    }

    let defID = defaultSpriteID ?? frame.spriteID

    let targetSize = params.targetSize
    guard targetSize.width > 0 && targetSize.height > 0 else {
      zoomedLayer.setAffineTransform(.identity)
      return
    }

    let logicalContentFrame = layout.contentFrame

    // Center of contentRect in target space
    let focusX = logicalContentFrame.midX
    let focusY = logicalContentFrame.midY

    let nx = frame.x
    let ny = 1.0 - frame.y

    let cursorLogicalX = logicalContentFrame.origin.x + nx * logicalContentFrame.width
    let cursorLogicalY = logicalContentFrame.origin.y + ny * logicalContentFrame.height

    // Min / Max for center so that we never expose outside of the contentRect
    let contentMinX = logicalContentFrame.minX
    let contentMaxX = logicalContentFrame.maxX
    let contentMinY = logicalContentFrame.minY
    let contentMaxY = logicalContentFrame.maxY

    let isInside = isInBounds(frame)

    // Is zoom active? (with hysteresis)
    let rawZoomWanted = isInside && (frame.spriteID != defID)

    var stableZoomActive: Bool = false
    if isInside {
      if let manualSegments = params.zoomSegments {
        let tMs = Int(time * 1000)
        stableZoomActive = manualSegments.contains { $0.contains(timeMs: tMs) }
      } else {
        stableZoomActive = zoomHysteresis.update(time: time, rawZoomWanted: rawZoomWanted)
      }
    } else {
      zoomHysteresis.reset()
      stableZoomActive = false
    }

    let targetZ: CGFloat = stableZoomActive ? params.zoomFactor : 1.0

    let targetLookAtX = (stableZoomActive && isInside) ? cursorLogicalX : focusX
    let targetLookAtY = (stableZoomActive && isInside) ? cursorLogicalY : focusY

    let alpha =
      snap
      ? 1.0
      : ZoomFollowSmoother.alpha(
        baseStrength: params.followStrength,
        dt: dt
      )

    smoothZoom = ZoomFollowSmoother.lerp(current: smoothZoom, target: targetZ, alpha: alpha)
    smoothCenterX = ZoomFollowSmoother.lerp(current: smoothCenterX, target: targetLookAtX, alpha: alpha)
    smoothCenterY = ZoomFollowSmoother.lerp(current: smoothCenterY, target: targetLookAtY, alpha: alpha)

    if !didLogZoomSmootherProfile {
      didLogZoomSmootherProfile = true
      NativeLogger.d(
        "ZoomSmoother",
        "Preview smoother configured",
        context: [
          "followStrength": ZoomFollowSmoother.clampedFollowStrength(params.followStrength),
          "alpha": alpha,
          "fps": currentPreviewProfile?.fps ?? params.fpsHint,
          "dt": ZoomFollowSmoother.clampedDtSeconds(dt),
        ]
      )
    }

    // 2) Clamp center inside contentRect (using content width/height)
    let contentWidth = (contentMaxX - contentMinX)
    let contentHeight = (contentMaxY - contentMinY)

    let safeZoom = max(smoothZoom, 0.0001)
    let halfWidth = contentWidth / (2.0 * safeZoom)
    let halfHeight = contentHeight / (2.0 * safeZoom)

    let minCenterX = contentMinX + halfWidth
    let maxCenterX = contentMaxX - halfWidth
    let minCenterY = contentMinY + halfHeight
    let maxCenterY = contentMaxY - halfHeight

    smoothCenterX = min(max(smoothCenterX, minCenterX), maxCenterX)
    smoothCenterY = min(max(smoothCenterY, minCenterY), maxCenterY)
    debugTick += 1

    if ZoomFollowParityDebug.shouldLogPreview(tick: debugTick) {
      ZoomFollowParityDebug.logSample(
        source: "preview",
        time: time,
        zoom: smoothZoom,
        centerX: smoothCenterX,
        centerY: smoothCenterY,
        targetZoom: targetZ,
        targetCenterX: targetLookAtX,
        targetCenterY: targetLookAtY
      )
    }

    // 3) Build transform
    // Pivot is center of view (which is targetSize/2)
    // But we want to center on smoothCenterX/Y

    // Transform logic:
    // We want the point (smoothCenterX, smoothCenterY) to be at the center of the viewport.
    // Viewport center is (targetWidth/2, targetHeight/2).

    let viewportCenterX = targetSize.width / 2.0
    let viewportCenterY = targetSize.height / 2.0

    var t = CGAffineTransform.identity

    // Move to center of viewport
    t = t.translatedBy(x: viewportCenterX, y: viewportCenterY)

    // Scale
    t = t.scaledBy(x: smoothZoom, y: smoothZoom)

    // Move back so that smoothCenter is at (0,0) before translation
    t = t.translatedBy(x: -smoothCenterX, y: -smoothCenterY)

    zoomedLayer.setAffineTransform(t)
  }

  // MARK: - Helpers
  func emitCurrentState() {
    guard let player = player else { return }
    sendTick(position: player.currentTime())
  }

  private func applyPreviewBackground(from params: CompositionParams, profile: PreviewProfile) {
    canvasBackground?.backgroundColor = previewBackgroundColor(from: params.backgroundColor)

    guard let path = params.backgroundImagePath, !path.isEmpty else {
      canvasBackground?.contents = nil
      canvasBackground?.contentsGravity = .resizeAspectFill
      return
    }

    let requestedCanvasSize = profile.canvasRenderSize
    let token = currentOpenToken

    backgroundImageQueue.async { [weak self] in
      guard let self else { return }
      let image = self.previewBackgroundImageCache.image(
        for: path,
        canvasRenderSize: requestedCanvasSize
      )

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard self.currentOpenToken == token else { return }
        guard self.currentCompositionParams?.backgroundImagePath == path else { return }
        guard self.currentPreviewProfile?.canvasRenderSize == requestedCanvasSize else { return }

        self.canvasBackground?.contents = image
        self.canvasBackground?.contentsGravity = .resizeAspectFill
      }
    }
  }

  private func previewBackgroundColor(from color: Int?) -> CGColor {
    guard let color else { return CGColor.black }

    let r = CGFloat((color >> 16) & 0xFF) / 255.0
    let g = CGFloat((color >> 8) & 0xFF) / 255.0
    let b = CGFloat(color & 0xFF) / 255.0
    let a = (color > 0xFFFFFF) ? CGFloat((color >> 24) & 0xFF) / 255.0 : 1.0
    return CGColor(red: r, green: g, blue: b, alpha: a)
  }

  private func applyPreviewMask(
    from params: CompositionParams,
    layout: CompositionBuilder.PreviewCompositionResult,
    pixelScale: CGFloat
  ) {
    guard let masked = maskedContentLayer else { return }

    let snapped = snapRect(layout.contentFrame, scale: pixelScale)
    masked.frame = snapped

    let radius = CGFloat(params.cornerRadius)
    if radius > 0 {
      let maskLayer = CAShapeLayer()
      maskLayer.frame = masked.bounds
      maskLayer.path = CGPath(
        roundedRect: masked.bounds,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
      )
      masked.mask = maskLayer
    } else {
      masked.mask = nil
    }

    playerLayer?.frame = masked.bounds
  }

  private func makeCGImage(from sprite: CursorSprite) -> CGImage? {
    let width = sprite.width
    let height = sprite.height
    let bitsPerComponent = 8
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    return sprite.pixels.withUnsafeBytes { ptr -> CGImage? in
      guard let baseAddress = ptr.baseAddress else { return nil }
      guard
        let ctx = CGContext(
          data: UnsafeMutableRawPointer(mutating: baseAddress),
          width: width,
          height: height,
          bitsPerComponent: bitsPerComponent,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: bitmapInfo.rawValue
        )
      else { return nil }
      return ctx.makeImage()
    }
  }

  private func resetZoomState() {
    resetZoomState(clearDefaultSpriteID: false)
  }

  private func resetZoomState(clearDefaultSpriteID: Bool) {
    smoothZoom = 1.0
    if clearDefaultSpriteID {
      defaultSpriteID = nil
    }
    zoomHysteresis.reset()

    // Reset center to content center if we have layout/params, otherwise 0
    if let layout = currentLayout {
      let cf = layout.contentFrame
      smoothCenterX = cf.midX
      smoothCenterY = cf.midY
    } else {
      smoothCenterX = 0
      smoothCenterY = 0
    }

    zoomedContentLayer?.setAffineTransform(.identity)
  }

  private func clearCursorCaches() {
    cursorRecording = nil
    cursorFrameResolver.clear()
    cursorSpritesByID = [:]
    cursorSpriteImages = [:]
    defaultSpriteID = nil
  }

  private func snap(_ v: CGFloat, scale: CGFloat) -> CGFloat {
    guard scale > 0 else { return v }
    return (v * scale).rounded() / scale
  }

  private func snapRect(_ r: CGRect, scale: CGFloat) -> CGRect {
    let x = snap(r.origin.x, scale: scale)
    let y = snap(r.origin.y, scale: scale)
    let w = snap(r.size.width, scale: scale)
    let h = snap(r.size.height, scale: scale)
    return CGRect(x: x, y: y, width: w, height: h)
  }

  private var shouldShowDebugVisuals: Bool {
    #if DEBUG
      return ProcessInfo.processInfo.environment["CLINGFY_PREVIEW_DEBUG_VISUALS"] == "1"
    #else
      return false
    #endif
  }

  private func applyDebugVisualsIfNeeded() {
    if shouldShowDebugVisuals {
      applyDebugVisuals()
    } else {
      clearDebugVisuals()
    }
  }

  private func clearDebugVisuals() {
    canvasContainer?.borderWidth = 0
    canvasContainer?.borderColor = nil
    canvasBackground?.borderWidth = 0
    canvasBackground?.borderColor = nil
    maskedContentLayer?.borderWidth = 0
    maskedContentLayer?.borderColor = nil
    playerLayer?.borderWidth = 0
    playerLayer?.borderColor = nil
  }

  private func applyDebugVisuals() {
    // [DEBUG_LAYER_VIZ] High-contrast debugging for padding issues

    // The container that should represent the whole canvas
    canvasContainer?.borderWidth = 2
    canvasContainer?.borderColor = NSColor.red.cgColor

    // The background color layer
    canvasBackground?.borderWidth = 2
    canvasBackground?.borderColor = NSColor.green.cgColor

    // The layer holding the video + padding
    maskedContentLayer?.borderWidth = 2
    maskedContentLayer?.borderColor = NSColor.blue.cgColor

    // The actual video player layer
    playerLayer?.borderWidth = 2
    playerLayer?.borderColor = NSColor.magenta.cgColor

    NativeLogger.d(
      "[DEBUG_LAYER_VIZ]", "Layer frames sync check",
      context: [
        "container": "\(canvasContainer?.frame ?? .zero)",
        "background": "\(canvasBackground?.frame ?? .zero)",
        "masked": "\(maskedContentLayer?.frame ?? .zero)",
        "player": "\(playerLayer?.frame ?? .zero)",
      ])
  }

}
