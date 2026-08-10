# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(FlClashM LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "FlClashM")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

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
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
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
if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(AMD64|amd64|x86_64)$")
  message(FATAL_ERROR
    "Unsupported Windows runtime architecture: ${CMAKE_SYSTEM_PROCESSOR}; FlClashM ships desktop runtime artifacts only for Windows x64")
endif()
set(RUNTIME_ARCHITECTURE "x86_64")
set(INSTALL_RUNTIME_DIR
  "${CMAKE_INSTALL_PREFIX}/runtimes/windows/${RUNTIME_ARCHITECTURE}")
set(FLCLASHM_RUNTIME_ASSETS "${CMAKE_CURRENT_SOURCE_DIR}/../.dart_tool/desktop-runtime-assets"
  CACHE PATH "Verified FlClashM desktop runtime asset root")
find_package(Python3 REQUIRED COMPONENTS Interpreter)
execute_process(
  COMMAND "${CMAKE_COMMAND}" -E env
    "RUNTIME_COMPAT_OUT=${FLCLASHM_RUNTIME_ASSETS}"
    "${Python3_EXECUTABLE}"
    "${CMAKE_CURRENT_SOURCE_DIR}/../tool/runtime_compat/runtime_compat.py"
    verify --target windows-x64
  RESULT_VARIABLE RUNTIME_VERIFY_RESULT
  OUTPUT_VARIABLE RUNTIME_VERIFY_OUTPUT
  ERROR_VARIABLE RUNTIME_VERIFY_ERROR)
if(NOT RUNTIME_VERIFY_RESULT EQUAL 0)
  message(FATAL_ERROR
    "Desktop runtime asset verification failed. Build or download desktop-runtime-windows-x64 into ${FLCLASHM_RUNTIME_ASSETS}.\n${RUNTIME_VERIFY_OUTPUT}${RUNTIME_VERIFY_ERROR}")
endif()
set(RUNTIME_ASSET_DIR
  "${FLCLASHM_RUNTIME_ASSETS}/runtimes/windows/${RUNTIME_ARCHITECTURE}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# Desktop runtime artifacts use the ProductInstallLayout contract and are
# verified before CMake is allowed to produce an install bundle.
install(PROGRAMS
  "${RUNTIME_ASSET_DIR}/mihomo.exe"
  "${RUNTIME_ASSET_DIR}/naiveproxy.exe"
  "${RUNTIME_ASSET_DIR}/olcrtc.exe"
  "${RUNTIME_ASSET_DIR}/byedpi.exe"
  "${RUNTIME_ASSET_DIR}/stormdns.exe"
  DESTINATION "${INSTALL_RUNTIME_DIR}" COMPONENT Runtime)
install(FILES "${RUNTIME_ASSET_DIR}/runtime-inventory.json"
  DESTINATION "${INSTALL_RUNTIME_DIR}" COMPONENT Runtime)

set(CLASH_DIR "../libclash/windows")
install(PROGRAMS "${CLASH_DIR}/FlClashHelperService.exe" DESTINATION "${INSTALL_RUNTIME_DIR}"
  RENAME "app.flclashm.client.helper.exe" COMPONENT Runtime)

install(FILES "EnableLoopback.exe" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

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
