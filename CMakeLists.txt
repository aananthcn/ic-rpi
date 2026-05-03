cmake_minimum_required(VERSION 3.22)
project(ic-rpi LANGUAGES NONE)

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

message(STATUS "ic-rpi staging prefix : ${CMAKE_INSTALL_PREFIX}")

# ──────────────────────────────────────────────────────────────────────────────
# Runtime prefix  (baked into binaries at compile time)
#   Separate from the staging prefix so VHAL_CONFIG_ROOT always points at
#   /opt/car-ui/etc/vhal regardless of where the build tree lives.
# ──────────────────────────────────────────────────────────────────────────────
set(CAR_UI_RUNTIME_PREFIX "/opt/car-ui" CACHE PATH
    "Runtime deployment root — baked into binaries (do not change unless you also change deploy.sh)")

message(STATUS "ic-rpi runtime prefix : ${CAR_UI_RUNTIME_PREFIX}")

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

# ── cluster-ui Qt args ────────────────────────────────────────────────────────
# Qt is not managed by Conan.  The args below are forwarded only to cluster-ui.
#
# Native (pc) build:
#   CMAKE_PREFIX_PATH / Qt6_DIR  — point cmake at the installer Qt kit.
#
# Cross-compilation (rpi with sysroot):
#   CMAKE_SYSROOT   — target filesystem root; the cross-compiler and all
#                     find_library/find_package calls search here for target libs
#                     (OpenGL, EGL, Qt libraries, etc.)
#   QT_HOST_PATH    — Qt pc-tools installation (moc, rcc, uic, qmlcachegen);
#                     must match the same major.minor as the target Qt.
#   Qt6_DIR         — pinned path to the target Qt cmake config dir inside the
#                     sysroot, bypassing any system search-path ambiguity.
set(_CLUSTER_UI_QT_ARGS)

if(CMAKE_PREFIX_PATH)
    list(APPEND _CLUSTER_UI_QT_ARGS "-DCMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH}")
endif()
if(Qt6_DIR)
    list(APPEND _CLUSTER_UI_QT_ARGS "-DQt6_DIR=${Qt6_DIR}")
endif()
if(QT_HOST_PATH)
    list(APPEND _CLUSTER_UI_QT_ARGS "-DQT_HOST_PATH=${QT_HOST_PATH}")
endif()
# RPI_SYSROOT is a forwarding variable — we intentionally do NOT set
# CMAKE_SYSROOT at the superbuild level because that would cause CMake to
# search for build tools (ninja, make) inside the sysroot and find armv8
# binaries that cannot run on the pc.  Only cluster-ui's sub-cmake gets
# CMAKE_SYSROOT, where the cross-compiler can use it correctly.
if(RPI_SYSROOT)
    list(APPEND _CLUSTER_UI_QT_ARGS "-DCMAKE_SYSROOT=${RPI_SYSROOT}")
    # The Conan toolchain sets CMAKE_FIND_ROOT_PATH_MODE_PROGRAM=BOTH, which
    # makes cmake search the sysroot for build tools (make, ninja, moc) before
    # the pc paths — and picks up armv8 binaries that cannot run.
    # Override to NEVER so pc programs are always used.
    list(APPEND _CLUSTER_UI_QT_ARGS "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER")
    # Explicitly forward the pc make/ninja program so the cluster-ui cmake
    # compiler test does not fall back to searching PATH.
    list(APPEND _CLUSTER_UI_QT_ARGS "-DCMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}")
    # Force the linker to search the sysroot lib dirs BEFORE the pc
    # cross-toolchain stubs.  Without this, the Ubuntu 22.04 cross-toolchain's
    # glibc 2.35 libc.so.6 is used for symbol resolution, causing
    # "undefined reference to foo@GLIBC_2.36+" errors.
    #
    # The sysroot's GCC lib dir (e.g. usr/lib/gcc/aarch64-linux-gnu/14) must
    # come first: it contains the unversioned libstdc++.so linker stub that
    # the linker uses to resolve -lstdc++.  The pc cross-compiler's own stub
    # (gcc-cross/aarch64-linux-gnu/11/libstdc++.so) only provides GLIBCXX up
    # to 3.4.30, whereas the sysroot Qt libraries need 3.4.32+.
    #
    # Auto-detect the highest GCC version installed in the sysroot.
    file(GLOB _SYSROOT_GCC_DIRS
        "${RPI_SYSROOT}/usr/lib/gcc/aarch64-linux-gnu/[0-9]*")
    if(_SYSROOT_GCC_DIRS)
        list(SORT _SYSROOT_GCC_DIRS ORDER DESCENDING)
        list(GET _SYSROOT_GCC_DIRS 0 _SYSROOT_GCC_LIB_DIR)
        message(STATUS "Sysroot GCC lib dir : ${_SYSROOT_GCC_LIB_DIR}")
    else()
        set(_SYSROOT_GCC_LIB_DIR "")
        message(WARNING "No GCC lib dir found in sysroot — libstdc++ symbol resolution may fail")
    endif()

    set(_SYSROOT_LIBDIRS "")
    if(_SYSROOT_GCC_LIB_DIR)
        string(APPEND _SYSROOT_LIBDIRS "-L${_SYSROOT_GCC_LIB_DIR} ")
    endif()
    string(APPEND _SYSROOT_LIBDIRS
        "-L${RPI_SYSROOT}/lib/aarch64-linux-gnu -L${RPI_SYSROOT}/usr/lib/aarch64-linux-gnu")
    list(APPEND _CLUSTER_UI_QT_ARGS "-DCMAKE_EXE_LINKER_FLAGS=${_SYSROOT_LIBDIRS}")
    list(APPEND _CLUSTER_UI_QT_ARGS "-DCMAKE_SHARED_LINKER_FLAGS=${_SYSROOT_LIBDIRS}")
    list(APPEND _CLUSTER_UI_QT_ARGS "-DCMAKE_MODULE_LINKER_FLAGS=${_SYSROOT_LIBDIRS}")
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
        # Runtime config paths baked into the binaries — must match the deployed
        # location, not the staging or source location.
        -DVHAL_CONFIG_ROOT=${CAR_UI_RUNTIME_PREFIX}/etc/vhal
        -DGATEWAY_CONFIG_ROOT=${CAR_UI_RUNTIME_PREFIX}/etc/vhal
    BUILD_ALWAYS ON
    USES_TERMINAL_BUILD ON
)

# ── cluster-ui ────────────────────────────────────────────────────────────────
# Builds the Qt6/QML instrument cluster application.
# cluster-ui brings in vhal-types and vhal-ipc-grpc via its own
# add_subdirectory() so it compiles what it needs independently.
#
# Cross-compiling Qt apps requires a Qt kit built for the target architecture.
# When building for RPi from a pc machine, no such kit is available — the
# Qt installer only provides pc (x86_64) kits here.  Set BUILD_CLUSTER_UI=OFF
# to skip this step; build cluster-ui natively on the RPi instead.
#
# Staging layout (./build/install/):
#   bin/cluster-ui         <- Qt application executable
#   qml/                   <- QML source files (loaded at runtime)
#   assets/fonts/          <- custom fonts
#   assets/images/         <- SVG icons
# ──────────────────────────────────────────────────────────────────────────────
option(BUILD_CLUSTER_UI "Build cluster-ui (requires a Qt kit for the target arch)" ON)

if(BUILD_CLUSTER_UI)
    ExternalProject_Add(cluster-ui
        SOURCE_DIR  ${CMAKE_CURRENT_SOURCE_DIR}/src/cluster-ui
        BINARY_DIR  ${CMAKE_CURRENT_BINARY_DIR}/cluster-ui
        INSTALL_DIR ${CMAKE_INSTALL_PREFIX}
        CMAKE_ARGS
            ${_COMMON_CMAKE_ARGS}
            ${_CLUSTER_UI_QT_ARGS}
        BUILD_ALWAYS ON
        USES_TERMINAL_BUILD ON
        # cluster-ui links against vhal-core targets; build vhal-core first so
        # the generated proto/grpc headers are present when cluster-ui configures.
        DEPENDS vhal-core
    )
else()
    message(STATUS "BUILD_CLUSTER_UI=OFF — skipping cluster-ui (build natively on the target device)")
endif()
