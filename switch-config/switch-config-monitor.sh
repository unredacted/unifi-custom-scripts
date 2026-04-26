#!/bin/bash
# ---- Switch Config Monitor ----
#
# Periodically re-runs apply-switch-config.sh to ensure switch CLI
# commands persist across reboots. UniFi switch CLI changes made via
# telnet do not survive reboots, so this daemon re-applies them on
# a configurable interval.
#
# Config resolution (first match wins):
#   1. Explicit argument:              $1
#   2. Per-host conf:                  conf/$(hostname).conf
#   3. Flat preferred:                 switch-config.conf
#
# Usage:
#   switch-config-monitor.sh [config-path] [interval-seconds]
#
# Environment:
#   INTERVAL=30    — override the re-application interval (seconds)
#
# Designed to be launched from an on-boot script. Backgrounds itself
# automatically and writes PID to /var/run/switch-config-monitor.pid.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Config file resolution: explicit arg > conf/<hostname>.conf > switch-config.conf
if [[ -n "${1:-}" && ! "${1:-}" =~ ^[0-9]+$ ]]; then
    CONF="$1"
    INTERVAL="${2:-${INTERVAL:-30}}"
elif [[ -f "${SCRIPT_DIR}/conf/$(hostname).conf" ]]; then
    CONF="${SCRIPT_DIR}/conf/$(hostname).conf"
    INTERVAL="${1:-${INTERVAL:-30}}"
elif [[ -f "${SCRIPT_DIR}/switch-config.conf" ]]; then
    CONF="${SCRIPT_DIR}/switch-config.conf"
    INTERVAL="${1:-${INTERVAL:-30}}"
else
    echo "[switch-config-monitor] No config found for host '$(hostname)'. Exiting."
    exit 1
fi

APPLY_SCRIPT="${SCRIPT_DIR}/apply-switch-config.sh"
PIDFILE="/var/run/switch-config-monitor.pid"
# Touched at the top of every loop iteration; lib/monitor-watchdog.sh
# uses its mtime to detect a stuck process (PID alive but not making
# progress, e.g. SIGSTOP'd by UBIOS during config-sync).
HEARTBEAT_FILE="/var/run/switch-config-monitor.heartbeat"
LOG="/var/log/switch-config-monitor.log"

# -----------------------------------------------------------------
# Prevent duplicate instances — kill any existing monitor
# -----------------------------------------------------------------
if [[ -f "$PIDFILE" ]]; then
    old_pid=$(cat "$PIDFILE" 2>/dev/null)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        echo "[switch-config-monitor] Killing old instance (PID $old_pid)."
        kill "$old_pid" 2>/dev/null
        for _i in $(seq 1 50); do
            kill -0 "$old_pid" 2>/dev/null || break
            sleep 0.1
        done
    fi
    rm -f "$PIDFILE"
fi

echo "[switch-config-monitor] Host: $(hostname)"
echo "[switch-config-monitor] Config: $CONF"
echo "[switch-config-monitor] Interval: ${INTERVAL}s"
echo "[switch-config-monitor] Log: $LOG"

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

        # Interruptible sleep: break into 1-second chunks so TERM
        # signals are handled promptly instead of waiting the full
        # interval.
        local remaining="$INTERVAL"
        while [[ "$remaining" -gt 0 ]]; do
            sleep 1
            (( remaining-- )) || true
        done
    done
}

_monitor &
disown

echo "[switch-config-monitor] Started in background (PID $(cat "$PIDFILE" 2>/dev/null || echo '?'))."
