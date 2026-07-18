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
  "update_feed_test.cpp"
  "updater_event_publisher_test.cpp"
  "updater_router_test.cpp"
  "area_picker_geometry_test.cpp"
  "argv_project_path_test.cpp"
  "camera_bubble_border_pixel_test.cpp"
  "camera_bubble_shape_geometry_test.cpp"
  "camera_dcomp_device_loss_test.cpp"
  "camera_export_layout_test.cpp"
  "camera_format_test.cpp"
  "camera_meta_test.cpp"
  "camera_nudge_plan_test.cpp"
  "camera_dcomp_overlay_poc_test.cpp"
  "camera_floating_overlay_geometry_smoke_test.cpp"
  "camera_overlay_geometry_store_test.cpp"
  "camera_overlay_glow_test.cpp"
  "camera_overlay_host_test.cpp"
  "camera_overlay_move_publisher_test.cpp"
  "camera_overlay_presenter_test.cpp"
  "camera_overlay_style_store_test.cpp"
  "camera_preview_support_test.cpp"
  "camera_readiness_test.cpp"
  "camera_recorder_test.cpp"
  "live_camera_texture_test.cpp"
  "cursor_export_renderer_test.cpp"
  "cursor_sample_mapper_test.cpp"
  "cursor_sampler_test.cpp"
  "cursor_sidecar_reader_test.cpp"
  "cursor_sidecar_writer_test.cpp"
  "zoom_export_controller_test.cpp"
  "zoom_follow_smoother_test.cpp"
  "zoom_hysteresis_test.cpp"
  "zoom_timeline_builder_test.cpp"
  "audio_format_test.cpp"
  "audio_mixer_test.cpp"
  "audio_packet_queue_test.cpp"
  "device_record_test.cpp"
  "devices_router_test.cpp"
  "encoder_output_path_test.cpp"
  "clip_audio_stitch_test.cpp"
  "clip_playback_planner_test.cpp"
  "clip_args_test.cpp"
  "preview_compositor_color_test.cpp"
  "color_grade_args_test.cpp"
  "color_grade_test.cpp"
  "export_audio_test.cpp"
  "export_format_test.cpp"
  "export_geometry_test.cpp"
  "export_passthrough_test.cpp"
  "export_pipeline_test.cpp"
  "export_progress_publisher_test.cpp"
  "export_session_test.cpp"
  "gif_export_policy_test.cpp"
  "keep_awake_test.cpp"
  "log_locations_test.cpp"
  "preview_open_reconcile_test.cpp"
  "mf_encoder_config_test.cpp"
  "native_log_publisher_test.cpp"
  "permission_probe_test.cpp"
  "permissions_details_router_test.cpp"
  "platform_thread_dispatcher_test.cpp"
  "player_event_publisher_test.cpp"
  "preview_camera_renderer_test.cpp"
  "preview_router_test.cpp"
  "preview_source_reader_test.cpp"
  "project_open_coordinator_test.cpp"
  "misc_router_crash_gate_test.cpp"
  "recording_clock_test.cpp"
  "reorder_audio_pump_test.cpp"
  "recording_engine_test.cpp"
  "recording_project_reader_test.cpp"
  "recording_project_writer_test.cpp"
  "recording_session_state_test.cpp"
  "recovery_sweep_test.cpp"
  "save_folder_test.cpp"
  "single_instance_test.cpp"
  "storage_router_reveal_test.cpp"
  "storage_zoom_truth_test.cpp"
  "temp_orphan_scan_test.cpp"
  "video_frame_queue_test.cpp"
  "window_enumerator_test.cpp"
  "windows_selection_state_test.cpp"
  "workflow_event_publisher_test.cpp"
  "zoom_easing_constants_test.cpp"
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
  # Discovery runs `runner_tests.exe --gtest_list_tests`, which loads
  # flutter_windows.dll and runs every static initializer. The 5s default
  # timed out on a cold CI runner (PR #264's first Windows run) while the
  # listing was visibly mid-print — give it room.
  DISCOVERY_TIMEOUT 60
  PROPERTIES
    LABELS "windows-runner"
)
