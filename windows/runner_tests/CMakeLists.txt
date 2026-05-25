cmake_minimum_required(VERSION 3.14)
project(runner_tests LANGUAGES CXX)

include(FetchContent)

# Pin GoogleTest to a known-good release tag. `flutter build windows` does
# not enable BUILD_RUNNER_TESTS, so this FetchContent never runs during a
# normal app build -- only when a developer explicitly configures with
# `-DBUILD_RUNNER_TESTS=ON`.
FetchContent_Declare(
  googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG        v1.15.2
)

# Match the MSVC runtime the rest of the project uses. Without this,
# GoogleTest defaults to /MT and the link step fails with a CRT mismatch
# against the dynamically-linked Flutter wrapper.
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)

# GoogleTest's own targets are not part of the install set we care about.
set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(googletest)

# === runner_tests executable ===
#
# Links against `runner_bridge` (defined in windows/runner/CMakeLists.txt),
# which gives us the routing logic plus the Flutter C++ wrapper headers
# without dragging in `flutter_window.cpp` or the live engine. The test
# binary never spins up a `FlutterViewController`; it constructs a
# `MethodRouter` directly and exercises `Dispatch`.
add_executable(runner_tests
  "method_router_test.cpp"
  "bridge_contract_coverage_test.cpp"
  "router_stub_shapes_test.cpp"
  "audio_format_test.cpp"
  "audio_mixer_test.cpp"
  "audio_packet_queue_test.cpp"
  "device_record_test.cpp"
  "encoder_output_path_test.cpp"
  "mf_encoder_config_test.cpp"
  "permission_probe_test.cpp"
  "recording_clock_test.cpp"
  "recording_engine_test.cpp"
  "recording_project_writer_test.cpp"
  "recording_session_state_test.cpp"
  "video_frame_queue_test.cpp"
  "windows_selection_state_test.cpp"
  "workflow_event_publisher_test.cpp"
)

target_link_libraries(runner_tests
  PRIVATE
    runner_bridge
    GTest::gtest
    GTest::gtest_main
)

# Test target uses default MSVC settings (exceptions enabled, /W3) instead
# of the runner's hardened /W4 /WX + `_HAS_EXCEPTIONS=0`. GoogleTest macros
# use exceptions in some assertion paths, and we do not want a warning in a
# test to fail the test build.
target_compile_definitions(runner_tests PRIVATE "NOMINMAX")
target_include_directories(runner_tests
  PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")

# Copy flutter_windows.dll next to runner_tests.exe so the test binary can
# launch. The tests do not actually invoke the engine -- they construct a
# `MethodRouter` directly -- but linking transitively pulls in
# flutter_windows.dll.lib via `flutter_wrapper_app`, and Windows resolves
# the import library at process load time.
add_custom_command(TARGET runner_tests POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${CMAKE_SOURCE_DIR}/flutter/ephemeral/flutter_windows.dll"
    "$<TARGET_FILE_DIR:runner_tests>"
)

include(GoogleTest)
gtest_discover_tests(runner_tests
  PROPERTIES
    LABELS "windows-runner"
)
