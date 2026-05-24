import FlutterMacOS
import Foundation

/// Slice 6 / PR 21: pure decision helper for the post-state-reset half of
/// `ScreenRecorderFacade.completeRecordingLifecycle(...)`. Given the error/
/// mode/state inputs, returns a typed `FinalizationAction` describing what
/// the facade must do (which callback to fire, with what payload).
///
/// PR 21 scope is intentionally **decisions only** — no side effects, no
/// manifest writes, no callback firing. The facade still owns:
/// `MetadataSidecarWriter.updateProjectManifestStatus(...)`,
/// `onRecordingFailed?(...)`, `onRecordingFinalized?(...)`,
/// `pendingStartResult?(...)`, `completion?(...)`, the `NativeLogger` calls,
/// and the session-field clears (`activeRecordingProjectRoot = nil`, etc.).
/// Those migrate in follow-up PRs once the decision boundary is stable.
///
/// Engine-domain; see `windows-port-inventory.md` §7.
enum RecordingFinalizer {

  /// Replaces the facade-private `RecordingCompletionMode`. `ready` is the
  /// normal terminal state; `cancelled` is the cancel-before-finalize-complete
  /// branch (no error, but no success payload either).
  enum CompletionMode: Equatable {
    case ready
    case cancelled
  }

  /// Action the facade must take after the state has been reset to `.idle`.
  /// One of:
  /// - `.fail(...)` — the recording ended in error; facade writes manifest
  ///   status `.failed`, fires `onRecordingFailed`, returns the start error
  ///   when `wasStarting` was true, and resolves `completion` with a
  ///   `FlutterError(code:, message:)` built from the same `errorMessage` /
  ///   `code` pair.
  /// - `.ready(...)` — happy path; facade fires `onRecordingFinalized` and
  ///   resolves `completion` with the project path.
  /// - `.cancelled(...)` — cancel-before-finalize; facade resolves
  ///   `completion(nil)`.
  enum FinalizationAction: Equatable {
    case fail(errorMessage: String, code: String, stage: String)
    case ready(projectPath: String?, sessionId: String?)
    case cancelled(projectPath: String?)
  }

  /// Stage label used in the `onRecordingFailed` payload — verbatim from the
  /// original `completeRecordingLifecycle`: `"start"` when the failure
  /// happened during the start path, `"finalize"` otherwise.
  static func stageLabel(wasStarting: Bool) -> String {
    wasStarting ? "start" : "finalize"
  }

  /// Verbatim from the facade's old `private static func errorMessage(from:)`:
  /// FlutterError → `.message ?? .code`, otherwise `.localizedDescription`.
  static func errorMessage(from error: Error) -> String {
    if let flutterError = error as? FlutterError {
      return flutterError.message ?? flutterError.code
    }
    return error.localizedDescription
  }

  /// Pure decision. The facade interprets the result and runs the side
  /// effects (manifest write, callback fires, session-field clears) in the
  /// order they used to run inline.
  ///
  /// Error wins: any non-nil `error` produces `.fail(...)` regardless of
  /// `mode`. Only when `error` is nil does `mode` decide between
  /// `.ready(...)` and `.cancelled(...)`.
  static func decideAction(
    error: Error?,
    wasStarting: Bool,
    mode: CompletionMode,
    activeProjectPath: String?,
    activeSessionId: String?,
    recordingErrorCode: String
  ) -> FinalizationAction {
    if let error {
      return .fail(
        errorMessage: errorMessage(from: error),
        code: recordingErrorCode,
        stage: stageLabel(wasStarting: wasStarting))
    }
    switch mode {
    case .ready:
      return .ready(projectPath: activeProjectPath, sessionId: activeSessionId)
    case .cancelled:
      return .cancelled(projectPath: activeProjectPath)
    }
  }
}
