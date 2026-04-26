#!/bin/bash
# ---- Neighbor-Poll Wrapper Monitor ----
#
# Periodically re-runs apply-neighbor-poll-wrapper.sh to ensure the
# bind-mounts over /usr/sbin/arping and /usr/bin/ndisc6 survive UBIOS
# provisioning cycles and any filesystem remounts.  The mount itself
# is cheap to check — if it's already in place the apply script is a
# no-op.
#
# Config resolution (first match wins):
#   1. Explicit argument:              $1 (if not a number)
#   2. Per-host conf:                  conf/$(hostname).conf
#   3. Flat preferred:                 neighbor-poll-wrapper.conf
#
# Usage:
#   neighbor-poll-wrapper-monitor.sh [config-path] [interval-seconds]
#
# Environment:
#   INTERVAL=30    — override the re-application interval (seconds)
#
# Designed to be launched from an on-boot script.  Backgrounds itself
# automatically and writes PID to /var/run/neighbor-poll-wrapper-monitor.pid.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Config resolution: explicit arg > conf/<hostname>.conf > neighbor-poll-wrapper.conf
if [[ -n "${1:-}" && ! "${1:-}" =~ ^[0-9]+$ ]]; then
    CONF="$1"
    INTERVAL="${2:-${INTERVAL:-30}}"
elif [[ -f "${SCRIPT_DIR}/conf/$(hostname).conf" ]]; then
    CONF="${SCRIPT_DIR}/conf/$(hostname).conf"
    INTERVAL="${1:-${INTERVAL:-30}}"
elif [[ -f "${SCRIPT_DIR}/neighbor-poll-wrapper.conf" ]]; then
    CONF="${SCRIPT_DIR}/neighbor-poll-wrapper.conf"
    INTERVAL="${1:-${INTERVAL:-30}}"
else
    echo "[neighbor-poll-wrapper-monitor] No config found for host '$(hostname)'. Exiting."
    exit 1
fi

APPLY_SCRIPT="${SCRIPT_DIR}/apply-neighbor-poll-wrapper.sh"
PIDFILE="/var/run/neighbor-poll-wrapper-monitor.pid"
LOG="/var/log/neighbor-poll-wrapper-monitor.log"
# Touched at the top of every loop iteration; lib/monitor-watchdog.sh
# uses its mtime to detect a stuck process (PID alive but not making
# progress, e.g. SIGSTOP'd by UBIOS during config-sync).
HEARTBEAT_FILE="/var/run/neighbor-poll-wrapper-monitor.heartbeat"

# -----------------------------------------------------------------
# Prevent duplicate instances — kill any existing monitor
# -----------------------------------------------------------------
if [[ -f "$PIDFILE" ]]; then
    old_pid=$(cat "$PIDFILE" 2>/dev/null)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        echo "[neighbor-poll-wrapper-monitor] Killing old instance (PID $old_pid)."
        kill "$old_pid" 2>/dev/null
        for _i in $(seq 1 50); do
            kill -0 "$old_pid" 2>/dev/null || break
            sleep 0.1
        done
    fi
    rm -f "$PIDFILE"
fi

echo "[neighbor-poll-wrapper-monitor] Host: $(hostname)"
echo "[neighbor-poll-wrapper-monitor] Config: $CONF"
echo "[neighbor-poll-wrapper-monitor] Interval: ${INTERVAL}s"
echo "[neighbor-poll-wrapper-monitor] Log: $LOG"

# -----------------------------------------------------------------
# Background the monitor loop
# -----------------------------------------------------------------
_monitor() {
    echo $BASHPID > "$PIDFILE"
    trap 'rm -f "$PIDFILE"; kill 0 2>/dev/null; exit 0' INT TERM

    while true; do
        # Heartbeat for lib/monitor-watchdog.sh — touched before any
        # work so a stalled apply-script still keeps the watchdog calm
        # (the watchdog only restarts us if the heartbeat itself stops
        # advancing, which means our loop body is hung or we're stopped).
        : > "$HEARTBEAT_FILE"

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

echo "[neighbor-poll-wrapper-monitor] Started in background (PID $(cat "$PIDFILE" 2>/dev/null || echo '?'))."
