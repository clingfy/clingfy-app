//
//  PlayerEventHandler.swift
//  Runner
//
//  Created by Nabil Alhafez on 13/11/2025.
//
import AVFoundation
import Cocoa
import FlutterMacOS
import Foundation

final class PlayerEventHandler: NSObject, FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    inlinePreviewPlayerEventSink = events
    inlinePreviewViewInstance?.playerEventSink = events
    inlinePreviewViewInstance?.emitCurrentState()
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    inlinePreviewPlayerEventSink = nil
    inlinePreviewViewInstance?.playerEventSink = nil
    return nil
  }
}

final class WorkflowEventHandler: NSObject, FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    workflowLifecycleEventSink = events
    inlinePreviewViewInstance?.workflowEventSink = events
    ProjectOpenCoordinator.shared.attachWorkflowEventSink(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    workflowLifecycleEventSink = nil
    inlinePreviewViewInstance?.workflowEventSink = nil
    ProjectOpenCoordinator.shared.detachWorkflowEventSink()
    return nil
  }
}
