# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(clingfy LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "clingfy")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Phase 10.4 (crash pipeline): emit full linker PDBs for optimized builds so
# native crashes from beta Release copies can be symbolicated in Sentry
# (uploaded by ops/release/windows/upload_symbols.ps1). CMake's MSVC Release
# defaults include neither /Zi nor /DEBUG, so without this no PDB exists for
# the runner at all. /DEBUG:FULL is explicit because FASTLINK-style PDBs are
# not portable (sentry-cli cannot use them). /DEBUG flips the linker's
# defaults to /OPT:NOREF,NOICF, so /OPT:REF /OPT:ICF are restored explicitly
# -- the linked binary stays byte-comparable to a PDB-less Release link.
# Appended BEFORE the Profile block below so Profile inherits the same flags
# via the copy. The matching compiler-side /Z7 lives in
# APPLY_STANDARD_SETTINGS.
set(CMAKE_EXE_LINKER_FLAGS_RELEASE
  "${CMAKE_EXE_LINKER_FLAGS_RELEASE} /DEBUG:FULL /OPT:REF /OPT:ICF")
set(CMAKE_SHARED_LINKER_FLAGS_RELEASE
  "${CMAKE_SHARED_LINKER_FLAGS_RELEASE} /DEBUG:FULL /OPT:REF /OPT:ICF")

# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# C++/WinRT (winrt/base.h, pulled in by wgc_display_capture_backend.cpp) drags
# in <experimental/coroutine> when compiled as C++17 -- even though this code
# uses no coroutines. Newer MSVC STL (VS 2022 17.10+ / VS 18, as on the GitHub
# windows-latest runner) turns that header's deprecation into a hard error
# (STL1011 / C2338), so the runner fails to build there while an older dev-box
# toolchain compiles it fine. Define the documented escape hatch so the build
# is toolchain-portable; the eventual clean fix is C++20, where C++/WinRT uses
# the standard <coroutine>. Global so every target built here -- runner,
# runner_bridge, and the native tests -- picks it up.
add_definitions(-D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  # Phase 10.4 (crash pipeline): compile optimized configs with /Z7 so debug
  # info is embedded in every .obj; the linker's /DEBUG:FULL pass (configured
  # above) folds it into one complete PDB next to each binary. /Z7 is chosen
  # over /Zi because runner_bridge is a static library -- with /Zi its debug
  # info lives in an intermediate vcNNN.pdb that must survive until the final
  # link, while /Z7 carries it inside the .lib itself, and /Z7 has no
  # parallel-compile PDB write contention. Debug keeps CMake's default /Zi.
  target_compile_options(${TARGET} PRIVATE
    "$<$<CONFIG:Release>:/Z7>"
    "$<$<CONFIG:Profile>:/Z7>")
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Optional native unit tests ===
#
# `flutter build windows` does NOT enable this -- it builds only the runner
# executable target. Tests are an opt-in build step driven by CMake directly:
#
#   cmake -S windows -B build/windows-tests -DBUILD_RUNNER_TESTS=ON
#   cmake --build build/windows-tests --config Debug
#   ctest --test-dir build/windows-tests --output-on-failure -C Debug
#
# Keeping the option default-OFF avoids paying the GoogleTest FetchContent
# cost on every normal app build.
option(BUILD_RUNNER_TESTS "Build native Windows unit tests under windows/runner_tests/" OFF)
if(BUILD_RUNNER_TESTS)
  enable_testing()
  add_subdirectory("runner_tests")
endif()


# === Optional Windows Phase 5 live-compositor POC ===
#
# Opt-in target. `flutter build windows` does NOT enable this -- it only
# builds the runner executable. The POC is a standalone Win32 GUI exe
# used to de-risk the Phase 5 design before any production wiring goes
# in. Build with:
#
#   cmake -S windows -B build/windows-poc -DBUILD_LIVE_COMPOSITOR_POC=ON
#   cmake --build build/windows-poc --config Debug --target live_compositor_demo
#
# See windows/runner/preview/live_compositor_demo.cpp for what it does
# and what is intentionally out of scope.
option(BUILD_LIVE_COMPOSITOR_POC
  "Build the Windows Phase 5 live-compositor POC executable" OFF)
if(BUILD_LIVE_COMPOSITOR_POC)
  add_subdirectory("runner/preview")
endif()


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
