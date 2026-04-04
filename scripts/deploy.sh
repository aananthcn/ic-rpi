#!/usr/bin/env bash
# deploy.sh — Deploy staged build outputs to /opt/car-ui
#
# Must be run after build.sh. Copies ./build/install/ to /opt/car-ui on the
# host (requires sudo) or to the Raspberry Pi 5 over SSH/rsync.
#
# Usage:
#   ./scripts/deploy.sh --target host
#   ./scripts/deploy.sh --target rpi5 [--rpi5-ip 192.168.10.10]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STAGE_DIR="${PROJECT_ROOT}/build/install"
DEPLOY_ROOT="/opt/car-ui"
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
    echo "Usage: $0 --target <host|rpi5> [--rpi5-ip <IP>]"
    echo
    echo "  --target    host  : deploy to /opt/car-ui on this machine (requires sudo)"
    echo "              rpi5  : deploy to /opt/car-ui on the Raspberry Pi 5 via rsync+SSH"
    echo "  --rpi5-ip   <IP>  : RPi5 IP address (default: \$RPI5_IP or 192.168.10.10)"
    exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)   TARGET="$2";   shift 2 ;;
        --rpi5-ip)  RPI5_IP="$2";  shift 2 ;;
        -h|--help)  usage ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ -z "$TARGET" ]] && usage

case "$TARGET" in
    host|rpi5) ;;
    *) fail "Unknown target '$TARGET'. Must be 'host' or 'rpi5'." ;;
esac

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
# deploy_host — copy to /opt/car-ui on the local machine
# ---------------------------------------------------------------------------
deploy_host() {
    echo
    info "Deploying to host at ${DEPLOY_ROOT} ..."
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
# deploy_rpi5 — copy to /opt/car-ui on the Raspberry Pi 5 over SSH
# ---------------------------------------------------------------------------
deploy_rpi5() {
    echo
    info "Target RPi5  : ${RPI5_USER}@${RPI5_IP}"
    info "Deploy root  : ${DEPLOY_ROOT}"

    # Check SSH connectivity
    info "Checking SSH connectivity to ${RPI5_IP} ..."
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes \
             "${RPI5_USER}@${RPI5_IP}" "exit" 2>/dev/null; then
        fail "Cannot reach ${RPI5_USER}@${RPI5_IP} via SSH.\n"\
             "Ensure the RPi5 is online, openssh-server is running, and\n"\
             "your public key is in ~/.ssh/authorized_keys on the device."
    fi
    success "SSH connection OK."

    # Ensure /opt/car-ui structure exists on RPi5 (sudo on remote)
    info "Ensuring ${DEPLOY_ROOT} exists on RPi5..."
    ssh "${RPI5_USER}@${RPI5_IP}" \
        "sudo mkdir -p ${DEPLOY_ROOT}/bin ${DEPLOY_ROOT}/lib ${DEPLOY_ROOT}/etc && \
         sudo chown -R ${RPI5_USER}:${RPI5_USER} ${DEPLOY_ROOT}"

    echo
    echo "  This will rsync the following to ${RPI5_USER}@${RPI5_IP}:${DEPLOY_ROOT}:"
    find "${STAGE_DIR}" -mindepth 1 -maxdepth 1 | sort | sed 's|^|    |'
    echo
    read -r -p "Proceed? [y/N] " CONFIRM
    [[ "${CONFIRM,,}" == "y" ]] || { info "Aborted."; exit 0; }

    info "Syncing files to RPi5..."
    rsync -av --progress \
        "${STAGE_DIR}/" \
        "${RPI5_USER}@${RPI5_IP}:${DEPLOY_ROOT}/"

    success "Deployed to ${RPI5_USER}@${RPI5_IP}:${DEPLOY_ROOT}."
    echo
    echo "  Binaries : ${DEPLOY_ROOT}/bin/"
    echo "  Libraries: ${DEPLOY_ROOT}/lib/"
    echo "  Configs  : ${DEPLOY_ROOT}/etc/"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$TARGET" in
    host) deploy_host ;;
    rpi5) deploy_rpi5 ;;
esac
