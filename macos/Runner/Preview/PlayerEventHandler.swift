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

/// Every send from native to Flutter must happen on the platform (main)
/// thread. Flutter says so at runtime — "sent a message from native to Flutter
/// on a non-platform thread … may result in data loss or crashes" — and a live
/// paused take logged exactly that for the workflow channel: capture
/// callbacks on background queues reached the sink directly.
///
/// On main, `run` calls `work` at once, so a send that was already on main is
/// unchanged in timing and order: an event still reaches Dart before the
/// method reply that follows it. Off main, it hops with `main.async`, which
/// keeps those sends in the order they were made.
enum FlutterMainThread {
  static func run(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  /// `sink`, made safe to call from any thread. Wrapping at `onListen` covers
  /// every copy of the sink a handler hands out.
  static func eventSink(_ sink: @escaping FlutterEventSink) -> FlutterEventSink {
    { event in run { sink(event) } }
  }
}

final class PlayerEventHandler: NSObject, FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    let events = FlutterMainThread.eventSink(events)
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
    let events = FlutterMainThread.eventSink(events)
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
