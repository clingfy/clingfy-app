#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "Bridge/app_window_anchor.h"
#include "Bridge/project_open_coordinator.h"
#include "Core/argv_project_path.h"
#include "Core/single_instance.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

// Bundle-id suffix used for the single-instance mutex + receiver
// window class. Phase 5 ships a single Windows flavour; if we add a
// dev / prod split later, fork this on a build define.
constexpr wchar_t kBundleIdSuffix[] = L"com.clingfy.clingfy";

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Step 5.6: pre-engine argv pickup. Done before COM init / Flutter
  // bring-up so the second-instance fast path stays cheap.
  const auto cold_start_project_path =
      clingfy::core::ExtractClingfyProjPathFromCommandLine(command_line);

  // Single-instance gate. If we lose the race, forward the path to
  // the existing instance and exit immediately — the existing
  // instance owns the user-visible state.
  const std::wstring bundle_suffix = kBundleIdSuffix;
  const bool first_instance =
      clingfy::core::TryAcquireInstanceMutex(bundle_suffix);
  if (!first_instance) {
    if (cold_start_project_path.has_value()) {
      // Best-effort forwarding. If the receiver isn't yet wired up
      // (race with the first instance's startup) we silently drop
      // the request — the user can re-double-click. Logging is not
      // available at this point (logger lives behind the Flutter
      // engine), so we accept the loss.
      clingfy::core::ForwardProjectPathToExistingInstance(
          bundle_suffix, *cold_start_project_path);
    }
    return EXIT_SUCCESS;
  }

  // From here on we are the canonical (first) instance.

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Step 5.6: pre-queue the cold-start path before the Flutter engine
  // boots. `ProjectOpenCoordinator` holds it until the workflow event
  // sink attaches (which happens shortly after `FlutterWindow` is
  // constructed and Dart subscribes).
  if (cold_start_project_path.has_value()) {
    clingfy::bridge::ProjectOpenCoordinator::Instance().Enqueue(
        clingfy::core::WideToUtf8(*cold_start_project_path));
  }

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"clingfy", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Record the main window so the recording chrome (pre-recording bar,
  // indicator) places itself on the display the user is actually working on.
  // Without this the overlays resolve their monitor from their own window,
  // which is created at (0, 0) and therefore always answers "primary" -- on a
  // multi-monitor desktop the chrome lands on a screen the user isn't watching.
  clingfy::SetMainAppWindow(window.GetHandle());

  // Step 5.6: register the WM_COPYDATA receiver AFTER the Flutter
  // window exists so the receiver lives on the same platform thread
  // that runs the event loop below.
  clingfy::core::RegisterProjectOpenReceiver(bundle_suffix);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  clingfy::core::UnregisterProjectOpenReceiver();
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
