#!/usr/bin/env bash
# deploy.sh — Deploy staged build outputs to /opt/car-ui
#
# Must be run after build.sh. Copies ./build/install/ to /opt/car-ui on the
# pc (requires sudo) or to the Raspberry Pi 5 over SSH/rsync.
#
# Usage:
#   ./scripts/deploy.sh --target pc
#   ./scripts/deploy.sh --target rpi [--rpi-ip 192.168.10.10]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_ROOT="${PROJECT_ROOT}/build"
DEPLOY_ROOT="/opt/car-ui"
RPI_IP="${RPI_IP:-192.168.10.10}"
RPI_USER="${USER}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; }
fail()    { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    echo "Usage: $0 --target <pc|rpi> [--rpi-ip <IP>]"
    echo
    echo "  --target    pc  : deploy to /opt/car-ui on this machine (requires sudo)"
    echo "              rpi  : deploy to /opt/car-ui on the Raspberry Pi 5 via rsync+SSH"
    echo "  --rpi-ip   <IP>  : RPi IP address (default: \$RPI_IP or 192.168.10.10)"
    exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)   TARGET="$2";   shift 2 ;;
        --rpi-ip)  RPI_IP="$2";  shift 2 ;;
        -h|--help)  usage ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ -z "$TARGET" ]] && usage

case "$TARGET" in
    pc|rpi) ;;
    *) fail "Unknown target '$TARGET'. Must be 'pc' or 'rpi'." ;;
esac


# ---------------------------------------------------------------------------
# Target-specific staging directory (matches build.sh layout)
# ---------------------------------------------------------------------------
case "$TARGET" in
    pc) TARGET_DIR="pc" ;;
    rpi) TARGET_DIR="rpi" ;;
esac

STAGE_DIR="${BUILD_ROOT}/${TARGET_DIR}/install"


# ---------------------------------------------------------------------------
# Pre-flight: verify staging area exists and has content
# ---------------------------------------------------------------------------
if [[ ! -d "$STAGE_DIR" ]]; then
    fail "Staging directory not found: ${STAGE_DIR}\nRun ./scripts/build.sh --target ${TARGET} first."
fi

if [[ -z "$(ls -A "$STAGE_DIR" 2>/dev/null)" ]]; then
    fail "Staging directory is empty: ${STAGE_DIR}\nRun ./scripts/build.sh --target ${TARGET} first."
fi

info "Staging area : ${STAGE_DIR}"
info "Deploy root  : ${DEPLOY_ROOT}"

# ---------------------------------------------------------------------------
# deploy_pc — copy to /opt/car-ui on the local machine
# ---------------------------------------------------------------------------
deploy_pc() {
    echo
    info "Deploying to pc at ${DEPLOY_ROOT} ..."
    echo "  This will copy the following to ${DEPLOY_ROOT}:"
    find "${STAGE_DIR}" -mindepth 1 -maxdepth 1 | sort | sed 's|^|    |'
    echo
    read -r -p "Proceed? This requires sudo. [y/N] " CONFIRM
    [[ "${CONFIRM,,}" == "y" ]] || { info "Aborted."; exit 0; }

    # Ensure /opt/car-ui structure exists
    for dir in "${DEPLOY_ROOT}" "${DEPLOY_ROOT}/bin" \
                "${DEPLOY_ROOT}/lib" "${DEPLOY_ROOT}/etc"; do
        if [[ ! -d "$dir" ]]; then
            info "Creating $dir ..."
            sudo mkdir -p "$dir"
        fi
    done

    info "Copying files (sudo rsync)..."
    # Trailing slash on source = copy contents, not the directory itself.
    sudo rsync -av --progress "${STAGE_DIR}/" "${DEPLOY_ROOT}/"

    success "Deployed to ${DEPLOY_ROOT}."
    echo
    echo "  Binaries : ${DEPLOY_ROOT}/bin/"
    echo "  Libraries: ${DEPLOY_ROOT}/lib/"
    echo "  Configs  : ${DEPLOY_ROOT}/etc/"
}

# ---------------------------------------------------------------------------
# deploy_rpi — copy to /opt/car-ui on the Raspberry Pi 5 over SSH
# ---------------------------------------------------------------------------
deploy_rpi() {
    echo
    info "Target RPi  : ${RPI_USER}@${RPI_IP}"
    info "Deploy root  : ${DEPLOY_ROOT}"

    # Check SSH connectivity
    info "Checking SSH connectivity to ${RPI_IP} ..."
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes \
             "${RPI_USER}@${RPI_IP}" "exit" 2>/dev/null; then
        fail "Cannot reach ${RPI_USER}@${RPI_IP} via SSH.\n"\
             "Ensure the RPi is online, openssh-server is running, and\n"\
             "your public key is in ~/.ssh/authorized_keys on the device."
    fi
    success "SSH connection OK."

    # Stop the running stack so binaries are not locked during overwrite
    info "Stopping car-ui service on RPi (if running) ..."
    ssh "${RPI_USER}@${RPI_IP}" \
        "sudo systemctl stop car-ui.service 2>/dev/null || true"
    success "car-ui service stopped."

    # Ensure /opt/car-ui structure exists on RPi (sudo on remote)
    info "Ensuring ${DEPLOY_ROOT} exists on RPi..."
    ssh "${RPI_USER}@${RPI_IP}" \
        "sudo mkdir -p ${DEPLOY_ROOT}/bin ${DEPLOY_ROOT}/lib ${DEPLOY_ROOT}/etc && \
         sudo chown -R ${RPI_USER}:${RPI_USER} ${DEPLOY_ROOT}"

    echo
    echo "  This will rsync the following to ${RPI_USER}@${RPI_IP}:${DEPLOY_ROOT}:"
    find "${STAGE_DIR}" -mindepth 1 -maxdepth 1 | sort | sed 's|^|    |'
    echo
    read -r -p "Proceed? [y/N] " CONFIRM
    [[ "${CONFIRM,,}" == "y" ]] || { info "Aborted."; exit 0; }

    info "Syncing files to RPi..."
    rsync -av --progress \
        "${STAGE_DIR}/" \
        "${RPI_USER}@${RPI_IP}:${DEPLOY_ROOT}/"

    success "Deployed to ${RPI_USER}@${RPI_IP}:${DEPLOY_ROOT}."
    echo
    echo "  Binaries : ${DEPLOY_ROOT}/bin/"
    echo "  Libraries: ${DEPLOY_ROOT}/lib/"
    echo "  Configs  : ${DEPLOY_ROOT}/etc/"

    # Restart the service with the newly deployed binaries
    info "Restarting car-ui service with new binaries ..."
    if ssh "${RPI_USER}@${RPI_IP}" \
           "sudo systemctl start car-ui.service 2>/dev/null"; then
        success "car-ui service restarted."
        info "Run './scripts/run.sh --target rpi' first if this is the initial deploy."
    else
        warn "car-ui.service is not installed yet."
        warn "Run './scripts/run.sh --target rpi' to install it, then redeploy."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$TARGET" in
    pc) deploy_pc ;;
    rpi) deploy_rpi ;;
esac
