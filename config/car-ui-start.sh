#!/usr/bin/env bash
# car-ui-start.sh — Sequential startup of the instrument cluster stack.
#
# Executed by car-ui.service (systemd). All backgrounded processes share
# the same systemd cgroup, so they are killed automatically when systemd
# stops the service or when cluster-ui exits.
#
# Installed to: /opt/car-ui/bin/car-ui-start.sh (by run.sh --target rpi)
# Per-process logs: /tmp/socket-can-gw.log, /tmp/vhal-core.log, /tmp/vhal-gateway.log

set -e

D="/opt/car-ui/bin"
LOG="/tmp"

"${D}/socket-can-gw"  >"${LOG}/socket-can-gw.log"  2>&1 &
sleep 1
"${D}/vhal-core"      >"${LOG}/vhal-core.log"       2>&1 &
sleep 1
"${D}/vhal-gateway"   >"${LOG}/vhal-gateway.log"    2>&1 &

# exec replaces this shell — systemd tracks cluster-ui's PID directly.
exec "${D}/cluster-ui"
