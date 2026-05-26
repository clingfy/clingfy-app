#ifndef RUNNER_BRIDGE_PLAYER_EVENT_PUBLISHER_H_
#define RUNNER_BRIDGE_PLAYER_EVENT_PUBLISHER_H_

#include <flutter/encodable_value.h>
#include <flutter/event_sink.h>

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>

// Process-level publisher for the `com.clingfy/player/events` event
// channel.
//
// Step 5.4 of the Phase 5 implementation plan: replaces the Phase 0
// no-op stub on the player/events channel with a real publisher. The
// stream handler in `Bridge/event_channel_stubs.cpp` installs the
// sink here when Dart subscribes; `PreviewEngine::HandleVideoFrame` +
// the MediaPlayer state subscriptions + the paused heartbeat thread
// then call the `Emit*` helpers to push events back.
//
// Payloads are matched verbatim against the macOS engine
// (`macos/Runner/Preview/InlinePreviewView.swift`'s `sendTick` /
// `sendState` / `playerError` / `playerWarning` shapes) so the Dart
// listener in `lib/core/preview/player_controller.dart` works on
// Windows without any platform-specific branching.
//
// The publisher is intentionally singleton-shaped — `PreviewEngine`
// uses function-pointer style emits with no other path to reach the
// sink. All `Emit*` calls are safe when no Dart listener is attached:
// events are dropped on the floor so a defensive caller never crashes.
namespace clingfy::bridge {

class PlayerEventPublisher {
 public:
  using EventSink = flutter::EventSink<flutter::EncodableValue>;

  static PlayerEventPublisher& Instance();

  PlayerEventPublisher(const PlayerEventPublisher&) = delete;
  PlayerEventPublisher& operator=(const PlayerEventPublisher&) = delete;

  // The stream handler hands the sink in on listen and back to nullptr
  // on cancel. Multiple sequential listens are tolerated — a second
  // listen replaces the first sink (matches the WorkflowEventPublisher
  // pattern).
  void SetSink(std::unique_ptr<EventSink> sink);
  void ClearSink();

  // True when Dart has an active listener. Useful in tests / engine
  // diagnostics; the Emit* methods do not require it (they drop
  // silently when false).
  bool has_sink() const;

  // ---- Per-event helpers — payloads match the macOS engine exactly.

  // `{type: "playerTick", sessionId, positionMs, durationMs}`.
  // Emitted from `PreviewEngine::HandleVideoFrame` after the frame is
  // handed to Flutter, and from the paused heartbeat thread at ~10 Hz.
  void EmitPlayerTick(const std::string& session_id,
                      std::int64_t position_ms,
                      std::int64_t duration_ms);

  // `{type: "playerState", sessionId, state}` where `state` is one of
  // {"playing", "paused", "completed"}. Emitted on every
  // PlaybackStateChanged + MediaEnded transition; `PreviewEngine`
  // debounces duplicate state events before calling this helper.
  void EmitPlayerState(const std::string& session_id,
                       const std::string& state);

  // `{type: "playerError", sessionId, code, message}`. Used for hard
  // failures the Flutter side should surface in the editor UI.
  // Current Windows codes:
  //   * "VIDEO_FILE_MISSING"  — MediaPlayer.MediaFailed fires (file
  //                              moved/deleted mid-playback)
  void EmitPlayerError(const std::string& session_id,
                       const std::string& code,
                       const std::string& message);

  // `{type: "playerWarning", sessionId, code, message}`. Used for
  // non-fatal issues the Flutter side should expose as a banner /
  // toast but should not block playback. Current Windows codes:
  //   * "CURSOR_FILE_MISSING" — cursor_path was provided but parsed
  //                              to zero events (file exists, content
  //                              empty / malformed)
  void EmitPlayerWarning(const std::string& session_id,
                         const std::string& code,
                         const std::string& message);

 private:
  PlayerEventPublisher() = default;

  // Send a pre-built map. Acquires the mutex, snapshots the sink
  // pointer, then calls `Success` outside the lock so a slow Flutter
  // delivery cannot block other Emit* callers.
  void EmitMap(flutter::EncodableMap event);

  mutable std::mutex mutex_;
  std::unique_ptr<EventSink> sink_;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_PLAYER_EVENT_PUBLISHER_H_
