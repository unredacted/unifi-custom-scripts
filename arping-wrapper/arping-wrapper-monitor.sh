#!/bin/bash
# ---- Arping Wrapper Monitor ----
#
# Periodically re-runs apply-arping-wrapper.sh to ensure the bind-mount
# over /usr/sbin/arping survives UBIOS provisioning cycles and any
# filesystem remounts.  The mount itself is cheap to check — if it's
# already in place the apply script is a no-op.
#
# Config resolution (first match wins):
#   1. Explicit argument:              $1 (if not a number)
#   2. Per-host conf:                  conf/$(hostname).conf
#   3. Flat preferred:                 arping-wrapper.conf
#
# Usage:
#   arping-wrapper-monitor.sh [config-path] [interval-seconds]
#
# Environment:
#   INTERVAL=30    — override the re-application interval (seconds)
#
# Designed to be launched from an on-boot script.  Backgrounds itself
# automatically and writes PID to /var/run/arping-wrapper-monitor.pid.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Config resolution: explicit arg > conf/<hostname>.conf > arping-wrapper.conf
if [[ -n "${1:-}" && ! "${1:-}" =~ ^[0-9]+$ ]]; then
    CONF="$1"
    INTERVAL="${2:-${INTERVAL:-30}}"
elif [[ -f "${SCRIPT_DIR}/conf/$(hostname).conf" ]]; then
    CONF="${SCRIPT_DIR}/conf/$(hostname).conf"
    INTERVAL="${1:-${INTERVAL:-30}}"
elif [[ -f "${SCRIPT_DIR}/arping-wrapper.conf" ]]; then
    CONF="${SCRIPT_DIR}/arping-wrapper.conf"
    INTERVAL="${1:-${INTERVAL:-30}}"
else
    echo "[arping-wrapper-monitor] No config found for host '$(hostname)'. Exiting."
    exit 1
fi

APPLY_SCRIPT="${SCRIPT_DIR}/apply-arping-wrapper.sh"
PIDFILE="/var/run/arping-wrapper-monitor.pid"
LOG="/var/log/arping-wrapper-monitor.log"

# -----------------------------------------------------------------
# Prevent duplicate instances — kill any existing monitor
# -----------------------------------------------------------------
if [[ -f "$PIDFILE" ]]; then
    old_pid=$(cat "$PIDFILE" 2>/dev/null)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        echo "[arping-wrapper-monitor] Killing old instance (PID $old_pid)."
        kill "$old_pid" 2>/dev/null
        for _i in $(seq 1 50); do
            kill -0 "$old_pid" 2>/dev/null || break
            sleep 0.1
        done
    fi
    rm -f "$PIDFILE"
fi

echo "[arping-wrapper-monitor] Host: $(hostname)"
echo "[arping-wrapper-monitor] Config: $CONF"
echo "[arping-wrapper-monitor] Interval: ${INTERVAL}s"
echo "[arping-wrapper-monitor] Log: $LOG"

# -----------------------------------------------------------------
# Background the monitor loop
# -----------------------------------------------------------------
_monitor() {
    echo $BASHPID > "$PIDFILE"
    trap 'rm -f "$PIDFILE"; kill 0 2>/dev/null; exit 0' INT TERM

    while true; do
        echo "[$(date)] Running $APPLY_SCRIPT" >> "$LOG"
        "$APPLY_SCRIPT" "$CONF" >> "$LOG" 2>&1 || true
        echo "[$(date)] Next run in ${INTERVAL}s" >> "$LOG"

        # Interruptible sleep — break into 1s chunks for prompt TERM handling
        local remaining="$INTERVAL"
        while [[ "$remaining" -gt 0 ]]; do
            sleep 1
            (( remaining-- )) || true
        done
    done
}

_monitor &
disown

echo "[arping-wrapper-monitor] Started in background (PID $(cat "$PIDFILE" 2>/dev/null || echo '?'))."
