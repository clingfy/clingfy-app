cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# === Bridge static library ===
#
# Bridge sources live in a static library so they can be linked by both the
# runner executable AND the unit-test binary under `windows/runner_tests/`
# without duplicating compilation rules. Sources here must NOT depend on a
# live Flutter engine (no `flutter_window.cpp`, no plugin registrant) so the
# test target can construct a `MethodRouter` in isolation.
add_library(runner_bridge STATIC
  "Bridge/method_dispatcher.cpp"
  "Bridge/method_router.cpp"
  "Bridge/event_channel_stubs.cpp"
  "Bridge/Devices/audio_source_enumerator.cpp"
  "Bridge/Devices/device_record.cpp"
  "Bridge/Devices/display_enumerator.cpp"
  "Bridge/Devices/video_source_enumerator.cpp"
  "Bridge/Devices/window_enumerator.cpp"
  "Bridge/Routers/camera_overlay_router.cpp"
  "Bridge/Routers/devices_router.cpp"
  "Bridge/Routers/export_router.cpp"
  "Bridge/Routers/indicator_router.cpp"
  "Bridge/Routers/misc_router.cpp"
  "Bridge/Routers/permissions_router.cpp"
  "Bridge/Routers/preview_router.cpp"
  "Bridge/Routers/recording_router.cpp"
  "Bridge/Routers/storage_router.cpp"
  "Capture/recording_clock.cpp"
  "Capture/recording_engine.cpp"
  "Capture/recording_session_state.cpp"
)
apply_standard_settings(runner_bridge)
target_compile_definitions(runner_bridge PRIVATE "NOMINMAX")
target_include_directories(runner_bridge PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(runner_bridge PUBLIC flutter flutter_wrapper_app)

# Win32 / WASAPI / Media Foundation libraries required by the Phase 2 device
# enumerators. These ship with the Windows SDK and do not pull in any
# additional CMake dependencies.
#   * shcore   — GetDpiForMonitor (per-monitor DPI scale)
#   * dwmapi   — DwmGetWindowAttribute (cloaked + extended frame bounds)
#   * mmdevapi — IMMDeviceEnumerator (WASAPI capture endpoints)
#   * propsys  — PROPVARIANT helpers for reading device friendly names
#   * mf / mfplat / mfuuid — Media Foundation video capture enumeration
target_link_libraries(runner_bridge PUBLIC
  "shcore.lib"
  "dwmapi.lib"
  "mmdevapi.lib"
  "propsys.lib"
  "mf.lib"
  "mfplat.lib"
  "mfuuid.lib"
)

# === Runner executable ===
#
# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE runner_bridge)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
