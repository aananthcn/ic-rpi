#!/usr/bin/env bash
# scan-rpi5-profile.sh — SSH into RPi5, detect library versions, generate Conan profile
#
# Connects to the Raspberry Pi 5, queries the installed toolchain and library
# versions, checks that required prerequisites are present, then writes a
# tailored Conan profile to profiles/rpi5.
#
# The profile is NOT committed because RPi5 library versions change with OS
# updates. Regenerate it whenever you update Raspbian.
#
# Usage:
#   ./scripts/scan-rpi5-profile.sh [--rpi5-ip <IP>]
#   RPI5_IP=192.168.10.10 ./scripts/scan-rpi5-profile.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROFILES_DIR="${PROJECT_ROOT}/profiles"

RPI5_IP="${RPI5_IP:-192.168.10.10}"
RPI5_USER="${USER}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; }
fail()    { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    echo "Usage: $0 [--rpi5-ip <IP>]"
    echo
    echo "  --rpi5-ip  <IP>  RPi5 IP address (default: \$RPI5_IP or 192.168.10.10)"
    exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rpi5-ip) RPI5_IP="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

rpi5_ssh() {
    ssh -o ConnectTimeout=10 -o BatchMode=yes "${RPI5_USER}@${RPI5_IP}" "$@"
}

# ---------------------------------------------------------------------------
# Step 1: Check SSH connectivity
# ---------------------------------------------------------------------------
info "Connecting to ${RPI5_USER}@${RPI5_IP} ..."
if ! rpi5_ssh "exit" 2>/dev/null; then
    fail "Cannot reach ${RPI5_USER}@${RPI5_IP} via SSH.\n"\
         "Ensure:\n"\
         "  1. The RPi5 is powered on and reachable at ${RPI5_IP}\n"\
         "  2. openssh-server is running on the RPi5:\n"\
         "       sudo apt-get install -y openssh-server\n"\
         "       sudo systemctl enable --now ssh\n"\
         "  3. Your public key is in ~/.ssh/authorized_keys on the device:\n"\
         "       ssh-copy-id ${RPI5_USER}@${RPI5_IP}"
fi
success "SSH connection OK."

# ---------------------------------------------------------------------------
# Step 2: Check prerequisites on RPi5
# ---------------------------------------------------------------------------
info "Checking prerequisites on RPi5 ..."

MISSING_PKGS=()

check_remote_pkg() {
    local pkg="$1"
    if ! rpi5_ssh "dpkg -s '${pkg}' >/dev/null 2>&1"; then
        MISSING_PKGS+=("$pkg")
    fi
}

check_remote_pkg "build-essential"
check_remote_pkg "cmake"
check_remote_pkg "pkg-config"
check_remote_pkg "ninja-build"

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    warn "The following packages are missing on the RPi5: ${MISSING_PKGS[*]}"
    echo
    echo "  Install them on the RPi5 with:"
    echo "    sudo apt-get update"
    echo "    sudo apt-get install -y ${MISSING_PKGS[*]}"
    echo
    fail "Install missing packages on RPi5 then re-run this script."
fi

success "Prerequisites OK."

# ---------------------------------------------------------------------------
# Step 3: Detect versions from RPi5
# ---------------------------------------------------------------------------
info "Detecting toolchain versions on RPi5 ..."

# Architecture
REMOTE_ARCH=$(rpi5_ssh "uname -m")
CONAN_ARCH="armv8"
if [[ "$REMOTE_ARCH" != "aarch64" ]]; then
    warn "Unexpected architecture on RPi5: ${REMOTE_ARCH} (expected aarch64). Proceeding anyway."
    CONAN_ARCH="armv8"
fi
info "  Architecture : ${REMOTE_ARCH} (Conan: ${CONAN_ARCH})"

# OS
REMOTE_OS=$(rpi5_ssh "uname -s")
info "  OS           : ${REMOTE_OS}"

# GCC version
GCC_VER=$(rpi5_ssh "gcc -dumpfullversion 2>/dev/null || gcc -dumpversion")
GCC_MAJOR="${GCC_VER%%.*}"
info "  GCC version  : ${GCC_VER} (major: ${GCC_MAJOR})"

# glibc version
GLIBC_VER=$(rpi5_ssh "ldd --version 2>&1 | head -1 | grep -oP '\d+\.\d+' | head -1")
info "  glibc version: ${GLIBC_VER}"

# Qt version (optional — not required for Conan profile but useful for verification)
QT_VER=""
if rpi5_ssh "command -v qmake6 >/dev/null 2>&1"; then
    QT_VER=$(rpi5_ssh "qmake6 -query QT_VERSION 2>/dev/null || true")
elif rpi5_ssh "command -v qmake >/dev/null 2>&1"; then
    QT_VER=$(rpi5_ssh "qmake -query QT_VERSION 2>/dev/null || true")
fi

if [[ -n "$QT_VER" ]]; then
    info "  Qt version   : ${QT_VER}"
else
    warn "  Qt not found on RPi5. Install it before running the cluster-ui application."
    echo
    echo "  Install Qt on RPi5 with:"
    echo "    sudo apt-get install -y qt6-base-dev qt6-declarative-dev"
    echo "    qt6-tools-dev libqt6quick6 libqt6qml6 qml6-module-qtquick"
    echo "    qml6-module-qtquick-controls qml6-module-qtquick-layouts"
fi

# Python (used by some Conan generators)
PYTHON_VER=$(rpi5_ssh "python3 --version 2>&1 | grep -oP '\d+\.\d+' | head -1" || echo "")
[[ -n "$PYTHON_VER" ]] && info "  Python       : ${PYTHON_VER}"

# ---------------------------------------------------------------------------
# Step 4: Check for a cross-compiler on this host
# ---------------------------------------------------------------------------
CROSS_PREFIX=""
CROSS_COMPILER_NOTE=""

if command -v aarch64-linux-gnu-gcc &>/dev/null; then
    CROSS_PREFIX="aarch64-linux-gnu-"
    CROSS_GCC_VER=$(aarch64-linux-gnu-gcc -dumpfullversion 2>/dev/null || \
                    aarch64-linux-gnu-gcc -dumpversion)
    info "  Cross-compiler (host): aarch64-linux-gnu-gcc ${CROSS_GCC_VER}"
    CROSS_COMPILER_NOTE="# Cross-compiler detected on host: aarch64-linux-gnu-gcc ${CROSS_GCC_VER}"
else
    CROSS_COMPILER_NOTE="# No cross-compiler found on host — install with:"
    CROSS_COMPILER_NOTE+=$'\n'"#   sudo apt-get install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu"
    CROSS_COMPILER_NOTE+=$'\n'"# If building directly on the RPi5, this is not needed."
    warn "No aarch64 cross-compiler found on host (aarch64-linux-gnu-gcc)."
    warn "Install with: sudo apt-get install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu"
    warn "Skip this if you intend to build directly on the RPi5."
fi

# ---------------------------------------------------------------------------
# Step 5: Write the Conan profile
# ---------------------------------------------------------------------------
mkdir -p "${PROFILES_DIR}"
PROFILE_PATH="${PROFILES_DIR}/rpi5"

info "Writing Conan profile to ${PROFILE_PATH} ..."

cat > "${PROFILE_PATH}" <<EOF
# Auto-generated by scan-rpi5-profile.sh — do NOT commit (listed in .gitignore)
# Regenerate with: ./scripts/scan-rpi5-profile.sh
#
# Scanned from RPi5 at ${RPI5_IP} on $(date '+%Y-%m-%d %H:%M:%S')
# RPi5 glibc    : ${GLIBC_VER}
# RPi5 GCC      : ${GCC_VER}
${CROSS_COMPILER_NOTE}

[settings]
os=Linux
arch=${CONAN_ARCH}
compiler=gcc
compiler.version=${GCC_MAJOR}
compiler.libcxx=libstdc++11
compiler.cppstd=17
build_type=Release

EOF

# Append cross-compiler buildenv only if a cross-compiler was found
if [[ -n "$CROSS_PREFIX" ]]; then
    cat >> "${PROFILE_PATH}" <<EOF
[buildenv]
CC=${CROSS_PREFIX}gcc
CXX=${CROSS_PREFIX}g++
AR=${CROSS_PREFIX}ar
STRIP=${CROSS_PREFIX}strip

EOF
fi

cat >> "${PROFILE_PATH}" <<EOF
[conf]
tools.cmake.cmaketoolchain:generator=Ninja
user.car_ui:install_prefix=/opt/car-ui
EOF

success "RPi5 Conan profile written to profiles/rpi5."
echo
echo "  Architecture  : ${CONAN_ARCH} (${REMOTE_ARCH})"
echo "  GCC major     : ${GCC_MAJOR}"
echo "  glibc         : ${GLIBC_VER}"
[[ -n "$QT_VER" ]] && echo "  Qt on RPi5    : ${QT_VER}"
echo
echo "Next step:"
echo "  ./scripts/build.sh --target rpi5"
