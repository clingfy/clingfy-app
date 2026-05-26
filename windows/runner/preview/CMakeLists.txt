cmake_minimum_required(VERSION 3.14)
project(live_compositor_demo LANGUAGES CXX)

# === Windows Phase 5 POC — Stage 1A0 executable ===
#
# Opt-in target. `flutter build windows` never enters this CMakeLists
# because the parent windows/CMakeLists.txt only `add_subdirectory(...)`s
# us when BUILD_LIVE_COMPOSITOR_POC=ON. So the option is invisible by
# default and adds nothing to normal app builds.
#
# Stage 1A0 is the Direct2D HWND timing harness — pure GPU 2D rendering
# + QPC frame timing, no video decode. Stage 1B adds MediaPlayer
# frame-server feeding the same Direct2D path; Win2D / WindowsAppSDK
# come later, only if the Direct2D path doesn't suffice.
#
# Stage 1A0 deliberately depends on nothing beyond what the Windows SDK
# ships:
#   * d2d1.lib       — Direct2D 1.1
#   * d3d11.lib      — Direct3D 11 device
#   * dxgi.lib       — DXGI 1.2 swap chain

add_executable(live_compositor_demo WIN32
  "live_compositor_demo.cpp"
  "frame_timing.cpp"
)

# Pick up the project-wide standard settings (cxx_std_17, /W4 /WX, etc.).
# These are defined as a function on the parent scope by the top-level
# windows/CMakeLists.txt.
apply_standard_settings(live_compositor_demo)

# The POC includes its own headers via `#include "preview/foo.h"` paths.
# Add the windows/runner directory as an include root so those paths
# resolve. Done as PRIVATE because nothing else links against this
# executable.
target_include_directories(live_compositor_demo
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")

target_compile_definitions(live_compositor_demo PRIVATE "NOMINMAX")

target_link_libraries(live_compositor_demo
  PRIVATE
    "d2d1.lib"
    "d3d11.lib"
    "dxgi.lib"
)

set_target_properties(live_compositor_demo PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  CXX_EXTENSIONS OFF
)
