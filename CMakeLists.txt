cmake_minimum_required(VERSION 3.22)
project(ic-rpi5 LANGUAGES NONE)

# ──────────────────────────────────────────────────────────────────────────────
# Staging prefix  (build output, no root required)
#   cmake --install lands here: ./build/install/{bin,lib,etc,...}
#   deploy.sh then copies this tree to /opt/car-ui with sudo.
# ──────────────────────────────────────────────────────────────────────────────
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT OR
   CMAKE_INSTALL_PREFIX STREQUAL "/usr/local")
    set(CMAKE_INSTALL_PREFIX "${CMAKE_CURRENT_BINARY_DIR}/install" CACHE PATH
        "Staging area for build outputs (deploy.sh copies this to /opt/car-ui)" FORCE)
endif()

message(STATUS "ic-rpi5 staging prefix : ${CMAKE_INSTALL_PREFIX}")

# ──────────────────────────────────────────────────────────────────────────────
# Runtime prefix  (baked into binaries at compile time)
#   Separate from the staging prefix so VHAL_CONFIG_ROOT always points at
#   /opt/car-ui/etc/vhal regardless of where the build tree lives.
# ──────────────────────────────────────────────────────────────────────────────
set(CAR_UI_RUNTIME_PREFIX "/opt/car-ui" CACHE PATH
    "Runtime deployment root — baked into binaries (do not change unless you also change deploy.sh)")

message(STATUS "ic-rpi5 runtime prefix : ${CAR_UI_RUNTIME_PREFIX}")

# ──────────────────────────────────────────────────────────────────────────────
# Superbuild via ExternalProject
#
# Each sub-project is built independently to avoid CMake target name
# collisions: cluster-ui already pulls in vhal-core packages via its own
# add_subdirectory() calls, so a shared-target monorepo approach would cause
# duplicate-target errors.
# ──────────────────────────────────────────────────────────────────────────────
include(ExternalProject)

# Arguments forwarded to every sub-project cmake invocation.
#
# CMAKE_INSTALL_RPATH=$ORIGIN/../lib  — executables locate their bundled
# shared libraries relative to themselves, so they work from both the staging
# directory (./build/install/bin/) and the deployed location (/opt/car-ui/bin/)
# without needing LD_LIBRARY_PATH to be set at runtime.
set(_RPATH "\$ORIGIN/../lib")
set(_COMMON_CMAKE_ARGS
    -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
    -DCMAKE_INSTALL_PREFIX=${CMAKE_INSTALL_PREFIX}
    -DCMAKE_INSTALL_RPATH=${_RPATH}
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON
)

# Forward the Conan toolchain file when present (always the case after
# 'conan install . --output-folder=build').
if(CMAKE_TOOLCHAIN_FILE)
    list(APPEND _COMMON_CMAKE_ARGS
        -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
    )
endif()

# Forward Qt location if the caller provided one (needed by cluster-ui since
# Qt is NOT managed by Conan).
if(CMAKE_PREFIX_PATH)
    list(APPEND _COMMON_CMAKE_ARGS
        "-DCMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH}"
    )
endif()

# Pin Qt6_DIR explicitly so CMake cannot shadow the installer Qt with a
# system-installed Qt 6.2.x (apt).  CMAKE_PREFIX_PATH alone is not sufficient
# because CMake's built-in system search paths may resolve first.
if(Qt6_DIR)
    list(APPEND _COMMON_CMAKE_ARGS
        "-DQt6_DIR=${Qt6_DIR}"
    )
endif()

# ── vhal-core ─────────────────────────────────────────────────────────────────
# Builds all three packages (vhal-types, vhal-ipc-grpc, vhal-server) in a
# single cmake invocation using vhal-core's workspace CMakeLists.txt.
#
# VHAL_CONFIG_ROOT is set to the *runtime* path (/opt/car-ui/etc/vhal) so the
# vhal-core binary finds its JSON config after deployment — not in the staging
# tree and not in the source tree.
#
# Staging layout (./build/install/):
#   bin/vhal-core          <- vhal-server executable
#   lib/libVehicleHal*.a   <- static libraries
#   etc/vhal/              <- runtime JSON config (DefaultProperties.json etc.)
#   include/               <- public headers
# ──────────────────────────────────────────────────────────────────────────────
ExternalProject_Add(vhal-core
    SOURCE_DIR  ${CMAKE_CURRENT_SOURCE_DIR}/src/vhal-core
    BINARY_DIR  ${CMAKE_CURRENT_BINARY_DIR}/vhal-core
    INSTALL_DIR ${CMAKE_INSTALL_PREFIX}
    CMAKE_ARGS
        ${_COMMON_CMAKE_ARGS}
        # Runtime config path baked into the binary — must match the deployed
        # location, not the staging location.
        -DVHAL_CONFIG_ROOT=${CAR_UI_RUNTIME_PREFIX}/etc/vhal
    BUILD_ALWAYS ON
    USES_TERMINAL_BUILD ON
)

# ── cluster-ui ────────────────────────────────────────────────────────────────
# Builds the Qt6/QML instrument cluster application.
# cluster-ui brings in vhal-types and vhal-ipc-grpc via its own
# add_subdirectory() so it compiles what it needs independently.
#
# Staging layout (./build/install/):
#   bin/cluster-ui         <- Qt application executable
#   qml/                   <- QML source files (loaded at runtime)
#   assets/fonts/          <- custom fonts
#   assets/images/         <- SVG icons
# ──────────────────────────────────────────────────────────────────────────────
ExternalProject_Add(cluster-ui
    SOURCE_DIR  ${CMAKE_CURRENT_SOURCE_DIR}/src/cluster-ui
    BINARY_DIR  ${CMAKE_CURRENT_BINARY_DIR}/cluster-ui
    INSTALL_DIR ${CMAKE_INSTALL_PREFIX}
    CMAKE_ARGS
        ${_COMMON_CMAKE_ARGS}
    BUILD_ALWAYS ON
    USES_TERMINAL_BUILD ON
    # cluster-ui links against vhal-core targets; build vhal-core first so
    # the generated proto/grpc headers are present when cluster-ui configures.
    DEPENDS vhal-core
)
