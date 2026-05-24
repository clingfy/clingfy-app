import AVFoundation
import FlutterMacOS
import Foundation

/// Auto zoom-segment *query* surface, extracted out of the
/// ScreenRecorderFacade body (Slice 2 / PR 8 of the strangler refactor).
///
/// Implemented as an `extension ScreenRecorderFacade` (the
/// ScreenRecorderFacade+Permissions pattern) — no new stored state, the method
/// stays on the facade so the method dispatcher / MainFlutterWindow call site
/// is unchanged. Read/query only (it reads the cursor sidecar and runs
/// ZoomTimelineBuilder); timeline-generation internals are not moved. Pure
/// relocation, behavior identical. Engine-domain (see windows-port-inventory
/// §7).
extension ScreenRecorderFacade {
  func getZoomSegments(projectPath: String, result: @escaping FlutterResult) {
    guard let projectRef = loadRecordingProject(projectPath: projectPath) else {
      result([])
      return
    }
    let mediaSources = projectRef.mediaSources()
    let videoURL = mediaSources.screenVideoURL
    let asset = AVAsset(url: videoURL)

    // 1. Check if asset is valid and duration is finite
    guard asset.duration.isNumeric else {
      NativeLogger.e(
        "Facade", "getZoomSegments: duration is not numeric", context: ["projectPath": projectPath])
      result([])
      return
    }
    let durationSeconds = asset.duration.seconds

    // 2. Locate cursor sidecar
    guard let cursorURL = mediaSources.cursorDataURL else {
      NativeLogger.w(
        "Facade", "getZoomSegments: cursor.json missing", context: ["projectPath": projectPath])
      result([])
      return
    }

    // 3. Load and decode cursor recording
    do {
      let data = try Data(contentsOf: cursorURL)
      let cursorRecording = try JSONDecoder().decode(CursorRecording.self, from: data)

      // 4. Build segments
      let segments = ZoomTimelineBuilder.buildSegments(
        cursorRecording: cursorRecording,
        durationSeconds: durationSeconds
      )

      // 5. Convert to dictionaries for result
      let dicts = segments.enumerated().map { (index, segment) in
        return [
          "id": "auto_\(index)",
          "startMs": segment.startMs,
          "endMs": segment.endMs,
          "source": "auto",
        ]
      }
      result(dicts)
    } catch {
      NativeLogger.e(
        "Facade", "getZoomSegments: failed to decode cursor.json",
        context: [
          "path": cursorURL.path,
          "error": error.localizedDescription,
        ])
      result([])
    }
  }
}
