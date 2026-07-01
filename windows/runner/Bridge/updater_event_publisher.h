#ifndef RUNNER_BRIDGE_UPDATER_EVENT_PUBLISHER_H_
#define RUNNER_BRIDGE_UPDATER_EVENT_PUBLISHER_H_

#include <flutter/encodable_value.h>
#include <flutter/event_sink.h>

#include <memory>
#include <mutex>
#include <string>

// Phase 10.6 — process-level publisher for the `com.clingfy/updater/events`
// event channel (D2), replacing the Phase-0 NoopStreamHandler. Same shape as
// WorkflowEventPublisher: the stream handler installs / removes the sink as
// Dart subscribes / cancels; the update checker worker thread calls Emit*
// and EmitMap marshals to the platform thread via PlatformThreadDispatcher.
//
// Payload contract: macOS Sparkle emits `{type:'updateAvailable',
// version:String, build:String}` (UpdaterController.swift) and Dart's
// NativeBridge flips `isUpdateAvailable` on that type. Windows keeps that
// exact shape and adds `url` / `versionFull` keys (Dart reads them
// tolerantly; macOS simply never sends them) plus three Windows-only event
// types — `checking`, `noUpdateAvailable`, `updateError` — that drive the
// honest About-section status line. macOS handles those states inside
// Sparkle's own UI and never emits them.
namespace clingfy::bridge {

class UpdaterEventPublisher {
 public:
  using EventSink = flutter::EventSink<flutter::EncodableValue>;

  static UpdaterEventPublisher& Instance();

  UpdaterEventPublisher(const UpdaterEventPublisher&) = delete;
  UpdaterEventPublisher& operator=(const UpdaterEventPublisher&) = delete;

  void SetSink(std::unique_ptr<EventSink> sink);
  void ClearSink();
  bool has_sink() const;

  void EmitChecking();

  // `version` / `build` are strings for macOS parity (Sparkle sends
  // displayVersionString / versionString). `url` is the https installer
  // download the Dart side opens in the browser; `version_full` is the
  // feed's "x.y.z+build".
  void EmitUpdateAvailable(const std::string& version,
                           const std::string& build,
                           const std::string& url,
                           const std::string& version_full);

  // `version` is the feed's latest published version (what the user is
  // already on or ahead of).
  void EmitNoUpdateAvailable(const std::string& version);

  // `code` is one of clingfy::updater::codes::*; `message` is the
  // human-readable fallback for unrecognized codes.
  void EmitUpdateError(const std::string& code, const std::string& message);

 private:
  UpdaterEventPublisher() = default;

  void EmitMap(flutter::EncodableMap event);

  mutable std::mutex mutex_;
  std::unique_ptr<EventSink> sink_;
};

}  // namespace clingfy::bridge

#endif  // RUNNER_BRIDGE_UPDATER_EVENT_PUBLISHER_H_
