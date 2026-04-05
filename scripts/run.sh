#!/usr/bin/env bash
# run.sh — Start the instrument cluster stack on host or Raspberry Pi 5
#
# Starts vhal-core (gRPC server) first, then cluster-ui (Qt client).
# On host both processes run locally; on rpi5 they run on the device over SSH.
# Ctrl-C (SIGINT) stops both processes cleanly.
#
# Usage:
#   ./scripts/run.sh --target host
#   ./scripts/run.sh --target rpi5 [--rpi5-ip 192.168.10.10] [--qt-platform <platform>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEPLOY_ROOT="/opt/car-ui"
VHAL_BIN="${DEPLOY_ROOT}/bin/vhal-core"
VHAL_GTW="${DEPLOY_ROOT}/bin/vhal-gateway"
ICUI_BIN="${DEPLOY_ROOT}/bin/cluster-ui"

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
    echo "Usage: $0 --target <host|rpi5> [--rpi5-ip <IP>] [--qt-platform <platform>]"
    echo
    echo "  --target       host         : run on this machine"
    echo "                 rpi5         : run on the Raspberry Pi 5 via SSH"
    echo "  --rpi5-ip      <IP>         : RPi5 IP address (default: \$RPI5_IP or 192.168.10.10)"
    echo "  --qt-platform  <platform>   : QT_QPA_PLATFORM override (default: xcb for host,"
    echo "                               wayland for rpi5). Use 'eglfs' for bare-metal RPi5."
    echo
    echo "Examples:"
    echo "  ./scripts/run.sh --target host"
    echo "  ./scripts/run.sh --target rpi5"
    echo "  ./scripts/run.sh --target rpi5 --qt-platform eglfs"
    exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET=""
QT_PLATFORM=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)       TARGET="$2";       shift 2 ;;
        --rpi5-ip)      RPI5_IP="$2";      shift 2 ;;
        --qt-platform)  QT_PLATFORM="$2";  shift 2 ;;
        -h|--help)      usage ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ -z "$TARGET" ]] && usage

case "$TARGET" in
    host|rpi5) ;;
    *) fail "Unknown target '$TARGET'. Must be 'host' or 'rpi5'." ;;
esac

# Default QT_QPA_PLATFORM per target
if [[ -z "$QT_PLATFORM" ]]; then
    case "$TARGET" in
        host) QT_PLATFORM="xcb" ;;
        rpi5) QT_PLATFORM="wayland" ;;
    esac
fi

# ---------------------------------------------------------------------------
# run_host — start both processes locally
#
# vhal-core is launched in the background; its PID is tracked so it can be
# killed when cluster-ui exits (or Ctrl-C is pressed).
# ---------------------------------------------------------------------------
run_host() {
    [[ -x "$VHAL_BIN" ]] || fail "${VHAL_BIN} not found. Run ./scripts/deploy.sh --target host first."
    [[ -x "$ICUI_BIN" ]] || fail "${ICUI_BIN} not found. Run ./scripts/deploy.sh --target host first."
    [[ -x "$VHAL_GTW" ]] || fail "${VHAL_GTW} not found. Run ./scripts/deploy.sh --target host first."

    info "Starting vhal-core ..."
    "${VHAL_BIN}" &
    VHAL_BIN_PID=$!
    success "vhal-core started (PID ${VHAL_BIN_PID})"

    # Give the gRPC server a moment to bind before the client connects
    sleep 1

    info "Starting vhal-gateway ..."
    "${VHAL_GTW}" &
    VHAL_GTW_PID=$!
    success "vhal-core started (PID ${VHAL_GTW_PID})"

    cleanup() {
        echo
        info "Stopping cluster-ui, vhal-gateway and vhal-core ..."
        kill "$VHAL_BIN_PID" 2>/dev/null || true
        wait "$VHAL_BIN_PID" 2>/dev/null || true
        kill "$VHAL_GTW_PID" 2>/dev/null || true
        wait "$VHAL_GTW_PID" 2>/dev/null || true
        success "Stopped."
    }
    trap cleanup EXIT INT TERM

    info "Starting cluster-ui (QT_QPA_PLATFORM=${QT_PLATFORM}) ..."
    QT_QPA_PLATFORM="${QT_PLATFORM}" "${ICUI_BIN}"
    # cluster-ui exiting (normally or via Ctrl-C) falls through to cleanup above.
}

# ---------------------------------------------------------------------------
# run_rpi5 — start both processes on the RPi5 over SSH
#
# Two SSH sessions are used: one to start vhal-core in the background on the
# device, one to run cluster-ui in the foreground (so its output streams back
# here and Ctrl-C propagates correctly).
# A final SSH cleanup command kills vhal-core when this script exits.
# ---------------------------------------------------------------------------
run_rpi5() {
    info "Target RPi5      : ${RPI5_USER}@${RPI5_IP}"
    info "QT_QPA_PLATFORM  : ${QT_PLATFORM}"

    # Check SSH connectivity
    info "Checking SSH connectivity ..."
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes \
             "${RPI5_USER}@${RPI5_IP}" "exit" 2>/dev/null; then
        fail "Cannot reach ${RPI5_USER}@${RPI5_IP} via SSH.\n"\
             "Ensure the RPi5 is online and your public key is authorised."
    fi
    success "SSH connection OK."

    # Verify binaries are present on the device
    ssh "${RPI5_USER}@${RPI5_IP}" \
        "[[ -x '${VHAL_BIN}' ]] || { echo '[ERROR] ${VHAL_BIN} not found on RPi5. Run deploy.sh first.' >&2; exit 1; }"
    ssh "${RPI5_USER}@${RPI5_IP}" \
        "[[ -x '${ICUI_BIN}' ]] || { echo '[ERROR] ${ICUI_BIN} not found on RPi5. Run deploy.sh first.' >&2; exit 1; }"
    ssh "${RPI5_USER}@${RPI5_IP}" \
        "[[ -x '${VHAL_GTW}' ]] || { echo '[ERROR] ${VHAL_GTW} not found on RPi5. Run deploy.sh first.' >&2; exit 1; }"

    # Start vhal-core in the background on the device, capture its PID
    info "Starting vhal-core on RPi5 ..."
    REMOTE_VHAL_BIN_PID=$(ssh "${RPI5_USER}@${RPI5_IP}" \
        "nohup '${VHAL_BIN}' >/tmp/vhal-core.log 2>&1 & echo \$!")
    success "vhal-core started on RPi5 (PID ${REMOTE_VHAL_BIN_PID})"

    sleep 1

    info "Starting vhal-gateway on RPi5 ..."
    REMOTE_VHAL_GTW_PID=$(ssh "${RPI5_USER}@${RPI5_IP}" \
        "nohup '${VHAL_GTW}' >/tmp/vhal-core.log 2>&1 & echo \$!")
    success "vhal-core started on RPi5 (PID ${REMOTE_VHAL_GTW_PID})"

    cleanup_rpi5() {
        echo
        info "Stopping vhal-core, vhal-gateway on RPi5 (PID ${REMOTE_VHAL_BIN_PID}, ${REMOTE_VHAL_GTW_PID}) ..."
        ssh "${RPI5_USER}@${RPI5_IP}" \
            "kill ${REMOTE_VHAL_BIN_PID} 2>/dev/null || true" 2>/dev/null || true
        ssh "${RPI5_USER}@${RPI5_IP}" \
            "kill ${REMOTE_VHAL_GTW_PID} 2>/dev/null || true" 2>/dev/null || true
        success "vhal-core, vhal-gateway are stopped."
    }
    trap cleanup_rpi5 EXIT INT TERM

    info "Starting cluster-ui on RPi5 (QT_QPA_PLATFORM=${QT_PLATFORM}) ..."
    info "(vhal-core log: ssh ${RPI5_USER}@${RPI5_IP} tail -f /tmp/vhal-core.log)"
    ssh -t "${RPI5_USER}@${RPI5_IP}" \
        "QT_QPA_PLATFORM='${QT_PLATFORM}' '${ICUI_BIN}'"
    # cluster-ui exiting falls through to cleanup_rpi5 above.
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$TARGET" in
    host) run_host ;;
    rpi5) run_rpi5 ;;
esac
