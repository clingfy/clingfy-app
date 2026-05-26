cmake_minimum_required(VERSION 3.14)
project(live_compositor_pocs LANGUAGES CXX)

# === Windows Phase 5 POC executables ===
#
# Opt-in. `flutter build windows` never enters this CMakeLists because
# the parent windows/CMakeLists.txt only `add_subdirectory(...)`s us
# when BUILD_LIVE_COMPOSITOR_POC=ON. So the option is invisible by
# default and adds nothing to normal app builds.
#
# Two peer executables live here, one per POC sub-stage. Both are
# single-file Win32 GUI apps that share frame_timing.{h,cpp}.
#
#   live_compositor_demo
#     Stage 1A0 — Direct2D HWND timing harness. Animated square +
#     QPC frame timing. No video. Proves the GPU 2D rendering /
#     swap-chain / Present slice works in our build.
#
#   mediaplayer_frame_server_demo
#     Stage 1B / 1C / 1D — MediaPlayer frame-server → Direct2D HWND.
#     One binary covers three modes (decided by --video / --cursor
#     args). Loads a real MP4, runs CopyFrameToVideoSurface in
#     IsVideoFrameServerEnabled mode, blits the decoded frame onto
#     the same swap-chain back buffer Stage 1A0 used, optionally
#     composites a hand-authored cursor.jsonl into zoom + highlight
#     overlays, and Stage 1D adds a native Win32 trackbar + 30 s
#     measurement window + Markdown artifact. Pulls in C++/WinRT
#     headers, windowsapp.lib for MediaPlayer, and comctl32.lib
#     for the trackbar.
#
# Stage 1B/1D bar is what the Phase 5 design doc Stage-1 milestone
# measures. Win2D / WindowsAppSDK come later, only if the Direct2D
# path doesn't suffice.

# Shared helper library — `FrameTimingCollector` + the reusable
# `PreviewCompositor`. Both POC executables link this rather than each
# compiling the sources independently. PreviewCompositor pulls in
# C++/WinRT projection headers so any consumer of this lib that needs
# its own WinRT init must call winrt::init_apartment first.
add_library(preview_poc_common STATIC
  "frame_timing.cpp"
  "preview_compositor.cpp"
)
apply_standard_settings(preview_poc_common)
target_compile_definitions(preview_poc_common PRIVATE "NOMINMAX")
target_include_directories(preview_poc_common
  PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/..")
set_target_properties(preview_poc_common PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  CXX_EXTENSIONS OFF
)

# --- Stage 1A0: live_compositor_demo --------------------------------
# Depends on nothing beyond what the Windows SDK ships:
#   d2d1.lib  — Direct2D 1.1
#   d3d11.lib — Direct3D 11 device
#   dxgi.lib  — DXGI 1.2 swap chain
add_executable(live_compositor_demo WIN32
  "live_compositor_demo.cpp"
)
apply_standard_settings(live_compositor_demo)
target_compile_definitions(live_compositor_demo PRIVATE "NOMINMAX")
target_link_libraries(live_compositor_demo
  PRIVATE
    preview_poc_common
    "d2d1.lib"
    "d3d11.lib"
    "dxgi.lib"
)
set_target_properties(live_compositor_demo PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  CXX_EXTENSIONS OFF
)

# --- Stage 1B / 1C / 1D: mediaplayer_frame_server_demo --------------
# Adds on top of Stage 1A0's link set:
#   windowsapp.lib    — WinRT activation + CreateDirect3D11*From* exports
#   runtimeobject.lib — used by C++/WinRT for WindowsCreateString etc.
#   shell32.lib       — CommandLineToArgvW
#   comctl32.lib      — TRACKBAR_CLASS / InitCommonControlsEx (Stage 1D slider)
add_executable(mediaplayer_frame_server_demo WIN32
  "mediaplayer_frame_server_demo.cpp"
)
apply_standard_settings(mediaplayer_frame_server_demo)
target_compile_definitions(mediaplayer_frame_server_demo PRIVATE "NOMINMAX")
target_link_libraries(mediaplayer_frame_server_demo
  PRIVATE
    preview_poc_common
    "d2d1.lib"
    "d3d11.lib"
    "dxgi.lib"
    "windowsapp.lib"
    "runtimeobject.lib"
    "shell32.lib"
    "comctl32.lib"
)
set_target_properties(mediaplayer_frame_server_demo PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  CXX_EXTENSIONS OFF
)
