#!/usr/bin/env bash
# setup.sh — Initialize the ic-rpi integration project
#
# What this script does:
#   1. Creates /opt/car-ui/{bin,lib,etc} on the pc if missing
#   2. Checks and installs pc build dependencies
#   3. Registers and clones git submodules (vhal-core, cluster-ui)
#   4. Installs Conan 2.x if not present
#   5. Generates the pc Conan profile (profiles/pc)
#   6. Calls scan-rpi-profile.sh to generate the rpi Conan profile

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; }
fail()    { echo "[ERROR] $*" >&2; exit 1; }

require_sudo() {
    if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        info "This step requires sudo. You may be prompted for your password."
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Create /opt/car-ui directory structure
# ---------------------------------------------------------------------------
setup_deploy_dirs() {
    info "Setting up /opt/car-ui directory structure..."

    local dirs=("/opt/car-ui" "/opt/car-ui/bin" "/opt/car-ui/lib" "/opt/car-ui/etc")
    local needs_create=()

    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] || needs_create+=("$d")
    done

    if [[ ${#needs_create[@]} -eq 0 ]]; then
        success "/opt/car-ui structure already exists."
        return
    fi

    require_sudo
    for d in "${needs_create[@]}"; do
        sudo mkdir -p "$d"
        info "Created $d"
    done

    # Give the current user ownership so builds can install without sudo
    sudo chown -R "${USER}:${USER}" /opt/car-ui
    success "/opt/car-ui structure created and owned by ${USER}."
}

# ---------------------------------------------------------------------------
# Step 2: Check and install pc build dependencies
# ---------------------------------------------------------------------------
HOST_DEPS=(
    git
    cmake
    ninja-build
    gcc
    g++
    python3
    python3-pip
    python3-venv
    pkg-config
    openssh-client      # needed to SSH into RPi for profile scan
    rsync               # needed to deploy to RPi
    # Qt6 is NOT installed via apt — use the Qt Online Installer (see README.md)
)

check_host_deps() {
    info "Checking pc build dependencies..."

    local missing=()
    for dep in "${HOST_DEPS[@]}"; do
        if ! dpkg -s "$dep" &>/dev/null && ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        success "All pc dependencies are present."
        return
    fi

    warn "The following packages are missing: ${missing[*]}"
    require_sudo
    info "Installing missing packages via apt..."
    sudo apt-get update -qq
    sudo apt-get install -y "${missing[@]}"
    success "Host dependencies installed."
}

# ---------------------------------------------------------------------------
# Step 3: Register and clone git submodules
# ---------------------------------------------------------------------------
SUBMODULES=(
    "vhal-core|https://github.com/aananthcn/vhal-core.git"
    "cluster-ui|https://github.com/aananthcn/cluster-ui.git"
)

setup_submodules() {
    info "Setting up git submodules..."

    cd "${PROJECT_ROOT}"
    mkdir -p src

    for entry in "${SUBMODULES[@]}"; do
        local name="${entry%%|*}"
        local url="${entry##*|}"

        if git config --file .gitmodules --get "submodule.${name}.url" &>/dev/null; then
            info "Submodule '${name}' already registered."
        else
            info "Registering submodule '${name}' from ${url}..."
            git submodule add "${url}" "src/${name}"
        fi
    done

    info "Initialising and updating all submodules..."
    git submodule update --init --recursive
    success "Submodules ready."
}

# ---------------------------------------------------------------------------
# Step 4: Install Conan 2.x
# ---------------------------------------------------------------------------
CONAN_MIN_VERSION="2.0"

install_conan() {
    info "Checking for Conan..."

    if command -v conan &>/dev/null; then
        local ver
        ver=$(conan --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
        local major="${ver%%.*}"
        if [[ "$major" -ge 2 ]]; then
            success "Conan ${ver} is already installed."
            return
        else
            warn "Conan ${ver} found but Conan 2.x is required. Upgrading..."
        fi
    else
        info "Conan not found. Installing Conan 2.x..."
    fi

    pip3 install --upgrade "conan>=${CONAN_MIN_VERSION}"
    success "Conan $(conan --version) installed."
}

# ---------------------------------------------------------------------------
# Step 5: Generate pc Conan profile
# ---------------------------------------------------------------------------
setup_host_profile() {
    info "Generating pc Conan profile..."

    local profiles_dir="${PROJECT_ROOT}/profiles"
    mkdir -p "${profiles_dir}"

    # Detect compiler version
    local gcc_ver
    gcc_ver=$(gcc -dumpfullversion 2>/dev/null || gcc -dumpversion)
    local gcc_major="${gcc_ver%%.*}"

    # Detect architecture
    local arch
    arch=$(uname -m)
    local conan_arch="x86_64"
    [[ "$arch" == "aarch64" ]] && conan_arch="armv8"

    cat > "${profiles_dir}/pc" <<EOF
# Auto-generated by setup.sh — safe to commit
# Regenerate with: ./scripts/setup.sh
[settings]
os=Linux
arch=${conan_arch}
compiler=gcc
compiler.version=${gcc_major}
compiler.libcxx=libstdc++11
compiler.cppstd=17
build_type=Release

[buildenv]
CC=gcc
CXX=g++

[conf]
tools.cmake.cmaketoolchain:generator=Ninja
user.car_ui:install_prefix=/opt/car-ui
EOF

    success "Host profile written to profiles/pc."
}

# ---------------------------------------------------------------------------
# Step 6: Generate RPi Conan profile (via scan script)
# ---------------------------------------------------------------------------
setup_rpi_profile() {
    local scan_script="${SCRIPT_DIR}/scan-rpi-profile.sh"

    if [[ ! -f "$scan_script" ]]; then
        warn "scan-rpi-profile.sh not found at ${scan_script}. Skipping RPi profile generation."
        warn "Run ./scripts/scan-rpi-profile.sh manually once the RPi is reachable."
        return
    fi

    info "Running RPi profile scan..."
    bash "${scan_script}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "========================================"
    echo "  ic-rpi Project Setup"
    echo "========================================"
    echo

    setup_deploy_dirs
    echo
    check_host_deps
    echo
    setup_submodules
    echo
    install_conan
    echo
    setup_host_profile
    echo
    setup_rpi_profile
    echo

    echo "========================================"
    success "Setup complete."
    echo
    echo "Next steps:"
    echo "  Build for pc :  ./scripts/build.sh --target pc"
    echo "  Build for RPi :  ./scripts/build.sh --target rpi"
    echo "========================================"
}

main "$@"
