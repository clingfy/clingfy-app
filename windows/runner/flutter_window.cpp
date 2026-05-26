#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "preview/poc_stage_2a/stage2a_texture_bridge.h"

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

  // Stand up the native bridge before the first frame. Methods called from
  // Flutter (NativeBridge.instance) must always have a registered handler —
  // otherwise we leak MissingPluginException through every recorder action.
  auto* messenger = flutter_controller_->engine()->messenger();
  method_dispatcher_ =
      std::make_unique<clingfy::bridge::MethodDispatcher>(messenger);
  event_channel_stubs_ =
      std::make_unique<clingfy::bridge::EventChannelStubs>(messenger);

  // Stage 2A-1 (debug-only POC) texture bridge. Initialized through
  // the raw C registrar ref to avoid pulling in the
  // flutter_wrapper_plugin library (which conflicts on
  // core_implementations.cc with flutter_wrapper_app, the wrapper the
  // runner already links). The registrar ref is owned by the engine;
  // we only borrow it.
  clingfy::poc::stage2a::Stage2aTextureBridge::Instance()->Initialize(
      flutter_controller_->engine()->GetRegistrarForPlugin(
          "ClingfyPocStage2a"));

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
  // Tear bridges down before the engine so their channel handlers don't
  // outlive the messenger they were registered against.
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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
