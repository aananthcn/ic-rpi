#!/usr/bin/env bash
# build.sh — Build ic-rpi for a given target
#
# Outputs land in ./build/install/ (staging area).
# To push them to /opt/car-ui run: ./scripts/deploy.sh --target <pc|rpi>
#
# Usage:
#   ./scripts/build.sh --target pc    # Ubuntu Linux pc
#   ./scripts/build.sh --target rpi    # Raspberry Pi 4/5

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROFILES_DIR="${PROJECT_ROOT}/profiles"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; }
fail()    { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    echo "Usage: $0 --target <pc|rpi> [--qt-prefix <path>] [--jobs <N>]"
    echo
    echo "  --target     pc  : build for Ubuntu Linux pc"
    echo "               rpi  : build for Raspberry Pi 5"
    echo "  --qt-prefix  <path>: path to Qt cmake dir (e.g. /usr/lib/x86_64-linux-gnu/cmake)"
    echo "                       required only if Qt is not on the default cmake search path"
    echo "  --jobs       <N>   : parallel build jobs (default: nproc)"
    echo
    echo "Build outputs are staged to: ./build/install/"
    echo "To deploy run: ./scripts/deploy.sh --target <pc|rpi>"
    exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET=""
QT_PREFIX=""
SYSROOT=""
JOBS=$(nproc)
BUILD_CLUSTER_UI=""   # empty = auto; set by sysroot detection below

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)          TARGET="$2";          shift 2 ;;
        --qt-prefix)       QT_PREFIX="$2";       shift 2 ;;
        --sysroot)         SYSROOT="$2";         shift 2 ;;
        --jobs)            JOBS="$2";             shift 2 ;;
        --with-cluster-ui) BUILD_CLUSTER_UI="ON"; shift   ;;
        -h|--help)   usage ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ -z "$TARGET" ]] && usage

case "$TARGET" in
    pc|rpi) ;;
    *) fail "Unknown target '$TARGET'. Must be 'pc' or 'rpi'." ;;
esac


# ---------------------------------------------------------------------------
# Target-specific build directories
# ---------------------------------------------------------------------------
case "$TARGET" in
    pc) TARGET_DIR="pc" ;;
    rpi) TARGET_DIR="rpi" ;;
esac

BUILD_ROOT="${PROJECT_ROOT}/build/${TARGET_DIR}"

CONAN_DIR="${BUILD_ROOT}/conan"
CMAKE_BUILD_DIR="${BUILD_ROOT}/build"
STAGE_DIR="${BUILD_ROOT}/install"
FULL_DEPLOY_DIR="${CONAN_DIR}/full_deploy"

mkdir -p "${BUILD_ROOT}"


PROFILE="${PROFILES_DIR}/${TARGET}"
[[ -f "$PROFILE" ]] || fail "Conan profile not found: ${PROFILE}. Run ./scripts/setup.sh first."

# ---------------------------------------------------------------------------
# Qt6 detection
#
# CMAKE_PREFIX_PATH must contain the Qt6 library dir so cluster-ui's
# find_package(Qt6) succeeds.  Qt is NOT managed by Conan — it is expected
# to be installed on the pc (apt) or cross-sysroot (rpi).
#
# Detection order:
#   1. --qt-prefix supplied by the user  → use as-is
#   2. qmake6 / qmake found on PATH      → ask it for QT_INSTALL_LIBS
#   3. Common system paths               → scan and pick the first hit
#   4. Nothing found                     → fail with install hint
# ---------------------------------------------------------------------------
detect_qt() {
    if [[ -n "$QT_PREFIX" ]]; then
        # Expand a leading ~ that the shell did not expand (happens when the
        # argument was passed inside quotes, e.g. --qt-prefix "~/Qt/...").
        QT_PREFIX="${QT_PREFIX/#\~/$HOME}"
        info "Qt6 prefix (user supplied): ${QT_PREFIX}"
        return
    fi

    # 1. Try qmake on PATH (works for apt installs and Qt installer if PATH is set)
    local qmake=""
    for cmd in qmake6 qmake-qt6 qmake; do
        if command -v "$cmd" &>/dev/null; then
            local ver
            ver=$("$cmd" -query QT_VERSION 2>/dev/null || true)
            if [[ "$ver" == 6.* ]]; then
                qmake="$cmd"
                break
            fi
        fi
    done

    if [[ -n "$qmake" ]]; then
        # QT_INSTALL_PREFIX is the kit root (e.g. ~/Qt/6.11.0/gcc_64).
        # CMake find_package then appends lib/cmake/Qt6/ automatically.
        local prefix
        prefix=$("$qmake" -query QT_INSTALL_PREFIX 2>/dev/null)
        if [[ -n "$prefix" && -f "${prefix}/lib/cmake/Qt6/Qt6Config.cmake" ]]; then
            QT_PREFIX="$prefix"
            info "Auto-detected Qt6 via ${qmake}: ${QT_PREFIX}"
            return
        fi
    fi

    # 2. Scan Qt Online Installer paths under ~/Qt (sorted newest-first so the
    #    highest version wins when multiple are installed).
    #    Layout: ~/Qt/<ver>/gcc_64/lib/cmake/Qt6/Qt6Config.cmake
    #    Prefix: ~/Qt/<ver>/gcc_64  (the kit root, not the lib subdir)
    local qt_home="${HOME}/Qt"
    if [[ -d "$qt_home" ]]; then
        while IFS= read -r -d '' kit_dir; do
            if [[ -f "${kit_dir}/lib/cmake/Qt6/Qt6Config.cmake" ]]; then
                QT_PREFIX="$kit_dir"
                info "Auto-detected Qt6 (Qt installer): ${QT_PREFIX}"
                return
            fi
        done < <(find "${qt_home}" -maxdepth 3 -type d -name "gcc_64" -print0 2>/dev/null | sort -rz)
    fi

    # 3. System paths (apt / distro packages)
    # On Debian/Ubuntu multiarch the cmake dir sits directly under the arch lib dir,
    # so the arch lib dir itself serves as the prefix.
    local arch_lib="/usr/lib/$(uname -m)-linux-gnu"
    for candidate in "${arch_lib}" "/usr/local/lib"; do
        if [[ -f "${candidate}/cmake/Qt6/Qt6Config.cmake" ]]; then
            QT_PREFIX="$candidate"
            info "Auto-detected Qt6 (system): ${QT_PREFIX}"
            return
        fi
    done

    fail "Qt6 not found. Install via the Qt Online Installer:"\
         "  https://www.qt.io/download-qt-installer"\
         "Then either add its bin/ to PATH or pass the kit root explicitly:"\
         "  ./scripts/build.sh --target ${TARGET} --qt-prefix ~/Qt/6.11.0/gcc_64"
}

detect_qt

# ---------------------------------------------------------------------------
# Step 1: conan install — resolve, download, and deploy all Conan dependencies
#
# --deployer=full_deploy copies every package's files (headers, .a, .so, ...)
# into build/full_deploy/<pkg>/<version>/  so we can harvest shared libraries
# for the target device in the staging step below.
# ---------------------------------------------------------------------------
info "Running conan install for target '${TARGET}'..."

conan install "${PROJECT_ROOT}" \
    --output-folder="${CONAN_DIR}" \
    --deployer=full_deploy \
    --build=missing \
    --profile="${PROFILE}"

success "Conan install complete."

# ---------------------------------------------------------------------------
# Step 1b: load the Conan build environment
#
# conanbuild.sh adds the BUILD-context bin dirs (x86_64 protoc, grpc_cpp_plugin)
# to PATH.  This is essential for cross-compilation: the Conan cmake modules for
# protobuf and gRPC search PATH first for these tools, and fall back to the
# target-arch binary (armv8) which cannot run on the build machine.
# For native pc builds this is a no-op (same-arch binaries, PATH already set).
# ---------------------------------------------------------------------------
if [[ -f "${CONAN_DIR}/conanbuild.sh" ]]; then
    # shellcheck disable=SC1090
    source "${CONAN_DIR}/conanbuild.sh"
    info "Conan build environment loaded (conanbuild.sh)."
fi

# ---------------------------------------------------------------------------
# Step 2: cmake configure
# ---------------------------------------------------------------------------
info "Configuring cmake (staging: ${STAGE_DIR})..."

# ---------------------------------------------------------------------------
# Sysroot detection (rpi only)
#
# Cross-compiling Qt apps requires a target-filesystem sysroot so the
# cross-linker can find OpenGL, EGL, and other RPi libraries.
# Default location: ~/sdk/rpi/root  (copy of the live RPi /usr tree).
# Override with: --sysroot <path>
# ---------------------------------------------------------------------------
if [[ "$TARGET" == "rpi" && -z "$SYSROOT" ]]; then
    DEFAULT_SYSROOT="${HOME}/sdk/rpi/root"
    if [[ -d "$DEFAULT_SYSROOT" ]]; then
        SYSROOT="$DEFAULT_SYSROOT"
        info "RPi sysroot auto-detected: ${SYSROOT}"
    fi
fi

# Expand leading ~ (in case the user passed --sysroot "~/...")
SYSROOT="${SYSROOT/#\~/$HOME}"

# Decide whether to build cluster-ui
if [[ -z "$BUILD_CLUSTER_UI" ]]; then
    case "$TARGET" in
        pc) BUILD_CLUSTER_UI="ON" ;;
        rpi) [[ -n "$SYSROOT" ]] && BUILD_CLUSTER_UI="ON" || BUILD_CLUSTER_UI="OFF" ;;
    esac
fi

[[ "$BUILD_CLUSTER_UI" == "ON" ]] \
    && info "cluster-ui: enabled" \
    || warn "cluster-ui: disabled (no sysroot found — pass --sysroot <path> to enable)"

# ---------------------------------------------------------------------------
# CMake extra args
# ---------------------------------------------------------------------------
CMAKE_EXTRA_ARGS=("-DBUILD_CLUSTER_UI=${BUILD_CLUSTER_UI}")

if [[ "$TARGET" == "rpi" && -n "$SYSROOT" ]]; then
    # Cross-compilation: Qt lives in the sysroot, pc tools come from gcc_64 kit.
    SYSROOT_QT="${SYSROOT}/usr/lib/aarch64-linux-gnu/cmake/Qt6"
    if [[ -f "${SYSROOT_QT}/Qt6Config.cmake" ]]; then
        CMAKE_EXTRA_ARGS+=("-DQt6_DIR=${SYSROOT_QT}")
        info "Qt6 target (sysroot): ${SYSROOT_QT}"
    fi
    # Pass as RPI_SYSROOT, not CMAKE_SYSROOT, so the superbuild itself does not
    # search for pc build tools (ninja, make) inside the sysroot.
    CMAKE_EXTRA_ARGS+=("-DRPI_SYSROOT=${SYSROOT}")
    # QT_HOST_PATH: x86_64 Qt kit that provides moc, rcc, uic, qmlcachegen.
    # detect_qt() has already set QT_PREFIX to the gcc_64 installation.
    if [[ -n "$QT_PREFIX" ]]; then
        CMAKE_EXTRA_ARGS+=("-DQT_HOST_PATH=${QT_PREFIX}")
        info "QT_HOST_PATH (pc tools): ${QT_PREFIX}"
    fi
else
    # Native pc build: pin Qt6_DIR so system Qt 6.2.x (apt) is not picked up.
    if [[ -n "$QT_PREFIX" ]]; then
        CMAKE_EXTRA_ARGS+=("-DCMAKE_PREFIX_PATH=${QT_PREFIX}")
        Qt6_CONFIG="${QT_PREFIX}/lib/cmake/Qt6/Qt6Config.cmake"
        if [[ -f "$Qt6_CONFIG" ]]; then
            CMAKE_EXTRA_ARGS+=("-DQt6_DIR=${QT_PREFIX}/lib/cmake/Qt6")
            info "Qt6_DIR pinned to: ${QT_PREFIX}/lib/cmake/Qt6"
        fi
    fi
fi

cmake -B "${CMAKE_BUILD_DIR}" \
    -DCMAKE_TOOLCHAIN_FILE="${CONAN_DIR}/conan_toolchain.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${STAGE_DIR}" \
    "${CMAKE_EXTRA_ARGS[@]}" \
    "${PROJECT_ROOT}"

success "CMake configure complete."

# ---------------------------------------------------------------------------
# Step 3: cmake build
# ---------------------------------------------------------------------------
info "Building (jobs: ${JOBS})..."
cmake --build "${CMAKE_BUILD_DIR}" --parallel "${JOBS}"
success "Build complete."

# ---------------------------------------------------------------------------
# Step 4: stage — install project artifacts into ./build/install/
# ---------------------------------------------------------------------------
info "Staging build outputs to ${STAGE_DIR}..."
cmake --install "${CMAKE_BUILD_DIR}"
success "Project artifacts staged."

# ---------------------------------------------------------------------------
# Step 5: collect Conan shared libraries into ./build/install/lib/
#
# Conan's full_deploy deployer copied all package files into
# ./build/full_deploy/<pkg>/<version>/.  We harvest every .so file from there
# so the staging tree is self-contained and deploy.sh can push a complete
# image to the target without relying on system-installed versions of gRPC,
# protobuf, jsoncpp, etc.
#
# Symlinks are preserved (-P) so versioned .so chains (libfoo.so →
# libfoo.so.1 → libfoo.so.1.2.3) arrive intact on the target.
# ---------------------------------------------------------------------------
LIB_STAGE="${STAGE_DIR}/lib"
mkdir -p "${LIB_STAGE}"

if [[ -d "${FULL_DEPLOY_DIR}" ]]; then
    info "Collecting Conan shared libraries into ${LIB_STAGE}..."
    COPIED=0
    while IFS= read -r -d '' sofile; do
        cp -Pv "${sofile}" "${LIB_STAGE}/"
        COPIED=$((COPIED + 1))
    done < <(find "${FULL_DEPLOY_DIR}" \( -name "*.so" -o -name "*.so.*" \) -print0)

    if [[ $COPIED -eq 0 ]]; then
        info "No shared libraries found in full_deploy (all Conan deps are static — nothing to collect)."
    else
        success "Collected ${COPIED} shared library file(s) from Conan packages."
    fi
else
    warn "full_deploy directory not found at ${FULL_DEPLOY_DIR} — skipping shared library collection."
fi

echo
echo "Staging complete: ${STAGE_DIR}"
echo "  bin/    — executables (RPATH set to \$ORIGIN/../lib)"
echo "  lib/    — project static libs + Conan shared libs (.so)"
echo "  etc/    — runtime config files"
echo "  qml/    — QML UI files"
echo "  assets/ — fonts and icons"
echo
echo "To deploy to /opt/car-ui run:"
echo "  ./scripts/deploy.sh --target ${TARGET}"

if [[ "$TARGET" == "rpi" && "$BUILD_CLUSTER_UI" == "OFF" ]]; then
    echo
    warn "cluster-ui was NOT built (no RPi sysroot found on this machine)."
    echo "  To enable cross-compilation of cluster-ui:"
    echo "    1. Create a sysroot by copying the RPi filesystem:"
    echo "         mkdir -p ~/sdk/rpi/root"
    echo "         rsync -av --rsync-path='sudo rsync' ${USER}@192.168.10.10:/usr ~/sdk/rpi/root/"
    echo "         rsync -av --rsync-path='sudo rsync' ${USER}@192.168.10.10:/lib ~/sdk/rpi/root/"
    echo "    2. Re-run this script (sysroot is auto-detected at ~/sdk/rpi/root)."
fi
