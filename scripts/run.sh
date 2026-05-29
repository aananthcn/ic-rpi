#!/usr/bin/env bash
# run.sh — Start the instrument cluster stack on pc or Raspberry Pi 5
#
# Starts vhal-core (gRPC server) first, then cluster-ui (Qt client).
# On pc both processes run locally; on rpi they run on the device over SSH.
# Ctrl-C (SIGINT) stops both processes cleanly.
#
# Usage:
#   ./scripts/run.sh --target pc
#   ./scripts/run.sh --target rpi [--rpi-ip 192.168.10.10] [--qt-platform <platform>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEPLOY_ROOT="/opt/car-ui"
VHAL_BIN="${DEPLOY_ROOT}/bin/vhal-core"
VHAL_GTW="${DEPLOY_ROOT}/bin/vhal-gateway"
ICUI_BIN="${DEPLOY_ROOT}/bin/cluster-ui"
SCAN_GTW="${DEPLOY_ROOT}/bin/socket-can-gw"

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
    echo "Usage: $0 --target <pc|rpi> [--rpi-ip <IP>] [--qt-platform <platform>]"
    echo
    echo "  --target       pc         : run on this machine"
    echo "                 rpi          : run on the Raspberry Pi 4/5 via SSH"
    echo "  --rpi-ip      <IP>          : RPi IP address (default: \$RPI_IP or 192.168.10.10)"
    echo "  --qt-platform  <platform>   : QT_QPA_PLATFORM override (default: xcb for pc,"
    echo "                               wayland for rpi). Use 'eglfs' for bare-metal RPi."
    echo
    echo "Examples:"
    echo "  ./scripts/run.sh --target pc"
    echo "  ./scripts/run.sh --target rpi"
    echo "  ./scripts/run.sh --target rpi --qt-platform eglfs"
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
        --rpi-ip)      RPI_IP="$2";       shift 2 ;;
        --qt-platform)  QT_PLATFORM="$2";  shift 2 ;;
        -h|--help)      usage ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ -z "$TARGET" ]] && usage

case "$TARGET" in
    pc|rpi) ;;
    *) fail "Unknown target '$TARGET'. Must be 'pc' or 'rpi'." ;;
esac

# Default QT_QPA_PLATFORM per target
if [[ -z "$QT_PLATFORM" ]]; then
    case "$TARGET" in
        pc) QT_PLATFORM="xcb" ;;
        rpi) QT_PLATFORM="wayland" ;;
    esac
fi

# ---------------------------------------------------------------------------
# run_host — start both processes locally
#
# vhal-core is launched in the background; its PID is tracked so it can be
# killed when cluster-ui exits (or Ctrl-C is pressed).
# ---------------------------------------------------------------------------
run_host() {
    [[ -x "$VHAL_BIN" ]] || fail "${VHAL_BIN} not found. Run ./scripts/deploy.sh --target pc first."
    [[ -x "$ICUI_BIN" ]] || fail "${ICUI_BIN} not found. Run ./scripts/deploy.sh --target pc first."
    [[ -x "$VHAL_GTW" ]] || fail "${VHAL_GTW} not found. Run ./scripts/deploy.sh --target pc first."
    [[ -x "$SCAN_GTW" ]] || fail "${SCAN_GTW} not found. Run ./scripts/deploy.sh --target pc first."

    info "Starting socket-can-gw ..."
    "${SCAN_GTW}" &
    SCAN_GTW_PID=$!
    success "socket-can-gw started (PID ${SCAN_GTW_PID})"

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
        trap '' INT TERM TSTP   # ignore further signals — let cleanup finish
        trap - EXIT
        echo
        info "Stopping cluster-ui, vhal-gateway and vhal-core ..."
        kill -9 "$VHAL_BIN_PID" "$VHAL_GTW_PID" "$SCAN_GTW_PID" 2>/dev/null || true
        wait "$VHAL_BIN_PID" "$VHAL_GTW_PID" "$SCAN_GTW_PID" 2>/dev/null || true
        success "Stopped."
    }
    trap cleanup EXIT INT TERM

    info "Starting cluster-ui (QT_QPA_PLATFORM=${QT_PLATFORM}) ..."
    QT_QPA_PLATFORM="${QT_PLATFORM}" "${ICUI_BIN}"
    # cluster-ui exiting (normally or via Ctrl-C) falls through to cleanup above.
}

# ---------------------------------------------------------------------------
# run_rpi — start both processes on the RPi over SSH
#
# Two SSH sessions are used: one to start vhal-core in the background on the
# device, one to run cluster-ui in the foreground (so its output streams back
# here and Ctrl-C propagates correctly).
# A final SSH cleanup command kills vhal-core when this script exits.
# ---------------------------------------------------------------------------
run_rpi() {
    info "Target RPi      : ${RPI_USER}@${RPI_IP}"
    info "QT_QPA_PLATFORM  : ${QT_PLATFORM}"

    # Check SSH connectivity
    info "Checking SSH connectivity ..."
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes \
             "${RPI_USER}@${RPI_IP}" "exit" 2>/dev/null; then
        fail "Cannot reach ${RPI_USER}@${RPI_IP} via SSH.\n"\
             "Ensure the RPi is online and your public key is authorised."
    fi
    success "SSH connection OK."

    # Verify binaries are present on the device
    ssh "${RPI_USER}@${RPI_IP}" \
        "[[ -x '${VHAL_BIN}' ]] || { echo '[ERROR] ${VHAL_BIN} not found on RPi. Run deploy.sh first.' >&2; exit 1; }"
    ssh "${RPI_USER}@${RPI_IP}" \
        "[[ -x '${ICUI_BIN}' ]] || { echo '[ERROR] ${ICUI_BIN} not found on RPi. Run deploy.sh first.' >&2; exit 1; }"
    ssh "${RPI_USER}@${RPI_IP}" \
        "[[ -x '${VHAL_GTW}' ]] || { echo '[ERROR] ${VHAL_GTW} not found on RPi. Run deploy.sh first.' >&2; exit 1; }"
    ssh "${RPI_USER}@${RPI_IP}" \
        "[[ -x '${SCAN_GTW}' ]] || { echo '[ERROR] ${SCAN_GTW} not found on RPi. Run deploy.sh first.' >&2; exit 1; }"

    # Log paths scoped to the remote user to avoid permission conflicts if the
    # files were previously created by root (e.g. after a sudo run).
    REMOTE_SCAN_LOG="/tmp/${RPI_USER}-socket-can-gw.log"
    REMOTE_VHAL_LOG="/tmp/${RPI_USER}-vhal-core.log"
    REMOTE_GTW_LOG="/tmp/${RPI_USER}-vhal-gateway.log"

    # Start socket-can-gw in the background on the device, capture its PID
    info "Starting socket-can-gw on RPi ..."
    REMOTE_SCAN_GTW_PID=$(ssh "${RPI_USER}@${RPI_IP}" \
        "nohup '${SCAN_GTW}' >'${REMOTE_SCAN_LOG}' 2>&1 & echo \$!")
    success "socket-can-gw started on RPi (PID ${REMOTE_SCAN_GTW_PID})"

    # Start vhal-core in the background on the device, capture its PID
    info "Starting vhal-core on RPi ..."
    REMOTE_VHAL_BIN_PID=$(ssh "${RPI_USER}@${RPI_IP}" \
        "nohup '${VHAL_BIN}' >'${REMOTE_VHAL_LOG}' 2>&1 & echo \$!")
    success "vhal-core started on RPi (PID ${REMOTE_VHAL_BIN_PID})"

    sleep 1

    info "Starting vhal-gateway on RPi ..."
    REMOTE_VHAL_GTW_PID=$(ssh "${RPI_USER}@${RPI_IP}" \
        "nohup '${VHAL_GTW}' >'${REMOTE_GTW_LOG}' 2>&1 & echo \$!")
    success "vhal-core started on RPi (PID ${REMOTE_VHAL_GTW_PID})"

    cleanup_rpi() {
        trap '' INT TERM TSTP
        trap - EXIT
        echo
        info "Stopping vhal-core, vhal-gateway on RPi (PID ${REMOTE_VHAL_BIN_PID}, ${REMOTE_VHAL_GTW_PID}) ..."
        ssh "${RPI_USER}@${RPI_IP}" \
            "kill ${REMOTE_VHAL_BIN_PID} 2>/dev/null || true" 2>/dev/null || true
        ssh "${RPI_USER}@${RPI_IP}" \
            "kill ${REMOTE_VHAL_GTW_PID} 2>/dev/null || true" 2>/dev/null || true
        ssh "${RPI_USER}@${RPI_IP}" \
            "kill ${REMOTE_SCAN_GTW_PID} 2>/dev/null || true" 2>/dev/null || true
        success "vhal-core, vhal-gateway are stopped."
    }
    trap cleanup_rpi EXIT INT TERM

    info "Starting cluster-ui on RPi (QT_QPA_PLATFORM=${QT_PLATFORM}) ..."
    info "(vhal-core log: ssh ${RPI_USER}@${RPI_IP} tail -f ${REMOTE_VHAL_LOG})"
    ssh -t "${RPI_USER}@${RPI_IP}" \
        "QT_QPA_PLATFORM='${QT_PLATFORM}' '${ICUI_BIN}'"
    # cluster-ui exiting falls through to cleanup_rpi above.
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$TARGET" in
    pc) run_host ;;
    rpi) run_rpi ;;
esac
