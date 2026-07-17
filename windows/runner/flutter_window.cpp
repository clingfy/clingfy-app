#include "flutter_window.h"

#include <optional>

#include "Bridge/camera_overlay_move_publisher.h"
#include "Bridge/export_progress_publisher.h"
#include "Bridge/native_log_publisher.h"
#include "Bridge/platform_thread_dispatcher.h"
#include "Capture/Camera/live_camera_texture.h"
#include "Capture/Export/export_session.h"
#include "Capture/recording_engine.h"
#include "Services/temp_orphan_scan.h"
#include "flutter/generated_plugin_registrant.h"
#include "preview/preview_engine.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // Initialize the platform-thread dispatcher BEFORE the event-channel
  // stubs register `player/events`. Step 5.4.1 fix: any worker thread
  // that wants to emit a player/events payload (VideoFrameAvailable,
  // PlaybackStateChanged, MediaEnded, MediaFailed, the heartbeat
  // thread) must marshal through the dispatcher so the actual
  // EventSink::Success call lands on the platform thread that runs
  // this constructor. We're already on that thread here, so this is
  // the right place to register the hidden message-only window.
  if (!clingfy::bridge::PlatformThreadDispatcher::Instance().Initialize()) {
    // Without the dispatcher, exportVideo falls back to a synchronous,
    // non-cancellable run on the platform thread (export_router gates on
    // is_initialized()). Surface the failure so a broken setup is
    // diagnosable rather than silent.
    OutputDebugStringW(
        L"[clingfy] PlatformThreadDispatcher::Initialize failed; export will "
        L"run synchronously and cannot be cancelled.\n");
  }

  // Stand up the native bridge before the first frame. Methods called from
  // Flutter (NativeBridge.instance) must always have a registered handler —
  // otherwise we leak MissingPluginException through every recorder action.
  auto* messenger = flutter_controller_->engine()->messenger();
  method_dispatcher_ =
      std::make_unique<clingfy::bridge::MethodDispatcher>(messenger);
  event_channel_stubs_ =
      std::make_unique<clingfy::bridge::EventChannelStubs>(messenger);

  // Give the export-progress publisher the screen_recorder method channel so
  // the (worker-thread) export can push `updateExportProgress` back to Dart.
  // Cleared in OnDestroy before the dispatcher (and its channel) is torn down.
  clingfy::bridge::ExportProgressPublisher::Instance().SetChannel(
      method_dispatcher_->channel());

  // Phase 10.1: same channel for the native→Dart log bridge, so native
  // WARN/ERROR lines reach the Dart JSONL logs and Sentry (the Windows
  // counterpart of macOS NativeLogger). Cleared alongside the export
  // publisher in OnDestroy.
  clingfy::bridge::NativeLogPublisher::Instance().SetChannel(
      method_dispatcher_->channel());

  // Editing port P1: same channel for the floating camera-bubble drag
  // write-back (`cameraOverlayMoved`), emitted from the overlay thread when a
  // drag ends. Cleared alongside the other publishers in OnDestroy.
  clingfy::bridge::CameraOverlayMovePublisher::Instance().SetChannel(
      method_dispatcher_->channel());

  // Phase 10.1: detect recordings stranded in %TEMP% by a crash/kill in a
  // previous session (detection + reporting only; salvage is Phase 10.4).
  // Runs on its own short-lived thread, off the startup path.
  clingfy::storage::StartTempOrphanScanAsync();

  // PreviewEngine (Phase 5). Initialized through the raw C registrar
  // ref to avoid pulling in the flutter_wrapper_plugin library (which
  // conflicts on core_implementations.cc with flutter_wrapper_app, the
  // wrapper the runner already links). The registrar ref is owned by
  // the engine; we only borrow it. The plugin name is kept as the
  // historical "ClingfyPocStage2a" key during the Step 5.0 -> 5.7
  // window so the dart-define POC debug screen and the production
  // previewOpen path share a single registrar ref. Step 5.3 retires
  // the key alongside the deprecated pocStage2a* aliases.
  clingfy::preview::PreviewEngine::Instance()->Initialize(
      flutter_controller_->engine()->GetRegistrarForPlugin(
          "ClingfyPocStage2a"));

  // Phase 9.3.1: register the live camera preview texture once for the app
  // lifetime. The recorder feeds it BGRA frames during recording; Dart shows a
  // Texture widget for it. Same raw-C-registrar approach as PreviewEngine.
  clingfy::capture::LiveCameraTexture::Instance().Initialize(
      flutter_controller_->engine()->GetRegistrarForPlugin(
          "ClingfyLiveCamera"));

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Phase 10.4: closing the window mid-recording used to kill the process
  // with the encoder unfinalized — a moov-less, unplayable %TEMP% strand
  // that only the next launch's recovery sweep could (partially) explain.
  // Finalize the active session synchronously instead (typically <2s); the
  // user keeps the recording and finds the bundle in the recordings folder.
  // Workflow events emitted during this teardown may not reach Dart (the
  // channel is going away) — the on-disk project is the point.
  clingfy::capture::RecordingEngine::Instance().StopActiveSessionForShutdown();

  // Abort any in-flight export so its worker stops decoding/encoding and
  // deletes its partial output instead of racing teardown. (The worker's
  // terminal reply is safe regardless: the Flutter embedder drops a reply
  // that arrives after the engine is destroyed — core_implementations.cc
  // ForwardToHandler checks FlutterDesktopMessengerIsAvailable.)
  clingfy::capture::export_::ExportSession::Instance().RequestCancel();

  // Tear bridges down before the engine so their channel handlers don't
  // outlive the messenger they were registered against. Drop the export
  // progress publisher's borrowed channel pointer first — the in-flight export
  // worker (if any) then emits into a null channel (no-op) instead of a freed
  // one.
  clingfy::bridge::ExportProgressPublisher::Instance().ClearChannel();
  clingfy::bridge::NativeLogPublisher::Instance().ClearChannel();
  clingfy::bridge::CameraOverlayMovePublisher::Instance().ClearChannel();
  event_channel_stubs_.reset();
  method_dispatcher_.reset();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_POWERBROADCAST:
      // Modern Standby / suspend resume invalidates the GPU + media
      // stack (the 2026-07 55-minute-recording incident: D3D device
      // removed, WinRT frame server dead). An open preview session
      // would otherwise sit on a dead device until its render loop
      // dies mid-play — proactively ask Dart to rebuild it instead.
      // PBT_APMRESUMEAUTOMATIC fires on every wake, user-initiated or
      // not; recording/export are protected separately by KeepAwake
      // power requests (#263) so resume-with-active-capture is not a
      // case this needs to handle.
      if (wparam == PBT_APMRESUMEAUTOMATIC) {
        clingfy::preview::PreviewEngine::Instance()->OnSystemResumed();
        return TRUE;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
