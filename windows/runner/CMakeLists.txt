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
  "Bridge/export_progress_publisher.cpp"
  "Bridge/platform_thread_dispatcher.cpp"
  "Bridge/player_event_publisher.cpp"
  "Bridge/project_open_coordinator.cpp"
  "Bridge/workflow_event_publisher.cpp"
  "Core/argv_project_path.cpp"
  "Core/single_instance.cpp"
  "Audio/audio_format.cpp"
  "Audio/audio_mixer.cpp"
  "Audio/audio_packet_queue.cpp"
  "Audio/wasapi_audio_capture.cpp"
  "Bridge/Devices/audio_source_enumerator.cpp"
  "Bridge/Devices/device_probe_log.cpp"
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
  "Capture/Export/export_audio.cpp"
  "Capture/Export/export_format.cpp"
  "Capture/Export/export_geometry.cpp"
  "Capture/Export/export_pipeline.cpp"
  "Capture/Export/export_passthrough.cpp"
  "Capture/Export/export_session.cpp"
  "Capture/Export/gif_export_policy.cpp"
  "Capture/Camera/camera_export_layout.cpp"
  "Capture/Camera/camera_export_renderer.cpp"
  "Capture/Camera/camera_floating_overlay.cpp"
  "Capture/Camera/camera_format.cpp"
  "Capture/Camera/camera_meta.cpp"
  "Capture/Camera/camera_preview_support.cpp"
  "Capture/Camera/camera_recorder.cpp"
  "Capture/Camera/live_camera_texture.cpp"
  "Capture/Cursor/cursor_click_hook.cpp"
  "Capture/Cursor/cursor_export_renderer.cpp"
  "Capture/Cursor/cursor_sample_mapper.cpp"
  "Capture/Cursor/cursor_sampler.cpp"
  "Capture/Cursor/cursor_sidecar_reader.cpp"
  "Capture/Cursor/cursor_sidecar_writer.cpp"
  "Capture/Zoom/zoom_export_controller.cpp"
  "Capture/Zoom/zoom_follow_smoother.cpp"
  "Capture/Zoom/zoom_hysteresis.cpp"
  "Capture/Zoom/zoom_timeline_builder.cpp"
  "Capture/recording_clock.cpp"
  "Capture/recording_engine.cpp"
  "Capture/recording_project_reader.cpp"
  "Capture/recording_project_writer.cpp"
  "Capture/recording_session_state.cpp"
  "Capture/video_frame_queue.cpp"
  "Capture/wgc_display_capture_backend.cpp"
  "Capture/windows_selection_state.cpp"
  "Encoding/encoder_output_path.cpp"
  "Encoding/gif_encoder.cpp"
  "Encoding/mf_dxgi_manager.cpp"
  "Encoding/mf_encoder_config.cpp"
  "Encoding/mf_sink_writer_encoder.cpp"
  "Graphics/d3d_device.cpp"
  "Overlay/area_picker_geometry.cpp"
  "Overlay/area_picker_overlay.cpp"
  "Permissions/camera_readiness.cpp"
  "Permissions/permission_probe.cpp"
  "Services/save_folder.cpp"
  "preview/frame_timing.cpp"
  "preview/preview_compositor.cpp"
  "preview/preview_engine.cpp"
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

# Phase 3B: Direct3D 11, DXGI, and the C++/WinRT runtime libs needed by
# WgcDisplayCaptureBackend.
#   * d3d11      — D3D11CreateDevice (D3DDevice)
#   * dxgi       — IDXGIDevice query needed for the WGC interop conversion
#   * windowsapp — RoGetActivationFactory / WinRT activation, plus the
#                  CreateDirect3D11DeviceFromDXGIDevice interop helper
target_link_libraries(runner_bridge PUBLIC
  "d3d11.lib"
  "dxgi.lib"
  "windowsapp.lib"
)

# Phase 3C: Media Foundation Sink Writer for MP4 / H.264 encoding.
#   * mfreadwrite — IMFSinkWriter + MFCreateSinkWriterFromURL
# (mf.lib, mfplat.lib, mfuuid.lib were already linked for the Phase 2
# video source enumerator.)
target_link_libraries(runner_bridge PUBLIC
  "mfreadwrite.lib"
)

# Phase 3D: WASAPI audio capture (microphone + system loopback) and AAC
# encoding. mmdevapi.lib was already linked for the Phase 2 audio
# source enumerator.
#   * avrt — AvSetMmThreadCharacteristics (Pro Audio MMCSS task)
target_link_libraries(runner_bridge PUBLIC
  "avrt.lib"
)

# Phase 5: Direct2D 1.1 + WinRT C++/WinRT runtime are needed by
# `PreviewEngine` to composite MediaPlayer frame-server frames into the
# DXGI shared texture before handing it to Flutter.
#   * d2d1 — D2D1CreateFactory, ID2D1DeviceContext, RenderTargetBitmap
# d3d11.lib + dxgi.lib + windowsapp.lib were already linked above for
# Phase 3B / 3C.
target_link_libraries(runner_bridge PUBLIC
  "d2d1.lib"
)

# Phase 6 Slice 2 follow-up: the export save-folder resolver + folder
# picker (Services/save_folder.cpp).
#   * shell32 — SHGetKnownFolderPath (FOLDERID_Videos), IFileOpenDialog
#   * ole32   — CoInitializeEx / CoCreateInstance / CoTaskMemFree
target_link_libraries(runner_bridge PUBLIC
  "shell32.lib"
  "ole32.lib"
)

# Phase 6 Slice 5B: WIC (Windows Imaging Component) animated-GIF encoder
# (Encoding/gif_encoder.cpp).
#   * windowscodecs — IWICImagingFactory / IWICBitmapEncoder
#                     (GUID_ContainerFormatGif) + the WIC format/CLSID GUIDs
# propsys.lib (InitPropVariantFromBuffer for the loop/delay metadata) and
# ole32.lib (CoInitializeEx) are already linked above.
target_link_libraries(runner_bridge PUBLIC
  "windowscodecs.lib"
)

# C++/WinRT headers use the standard-layout `co_await`-friendly types but
# this PR's code is plain (non-coroutine). Still, enable C++17 just to be
# explicit — the project compiles at C++17 already, this only makes it
# load-bearing.
set_target_properties(runner_bridge PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  CXX_EXTENSIONS OFF
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
