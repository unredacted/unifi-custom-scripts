#!/bin/bash
# ---- Rules Sync Monitor ----
#
# Watches interfaces AND routing tables referenced by "route-sync"
# directives in the config file and re-runs the inject rules script
# whenever kernel routes change on any of those interfaces or tables.
#
# This catches two failure modes:
#   1. Tunnel interface routes change (peer add/remove/rekey)
#   2. Policy routing table gets flushed (UBIOS provisioning cycle)
#
# Debounce strategy: when a matching event arrives, keep draining
# events until no new event arrives for DEBOUNCE seconds. Only then
# run the sync. This ensures we wait for UBIOS to finish its entire
# provisioning cycle before re-adding routes.
#
# All interface names and table IDs are read from the config — nothing
# is hardcoded.
#
# Config resolution (first match wins):
#   1. Explicit argument:              $1
#   2. Per-host conf:                  conf/$(hostname).conf
#   3. Flat preferred:                 inject-rules.conf
#   4. Legacy fallback:                custom-routes.conf
#
# Usage:
#   rules-monitor.sh [config-path]
#
# Designed to be launched by unifi-on-boot. Backgrounds itself automatically.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Config file resolution: explicit arg > conf/<hostname>.conf > inject-rules.conf > custom-routes.conf
if [[ -n "${1:-}" ]]; then
    CONF="$1"
elif [[ -f "${SCRIPT_DIR}/conf/$(hostname).conf" ]]; then
    CONF="${SCRIPT_DIR}/conf/$(hostname).conf"
elif [[ -f "${SCRIPT_DIR}/inject-rules.conf" ]]; then
    CONF="${SCRIPT_DIR}/inject-rules.conf"
elif [[ -f "${SCRIPT_DIR}/custom-routes.conf" ]]; then
    CONF="${SCRIPT_DIR}/custom-routes.conf"
else
    echo "[rules-monitor] No config found for host '$(hostname)'. Exiting."
    exit 1
fi

RULES_SCRIPT="${SCRIPT_DIR}/inject-rules.sh"
PIDFILE="/var/run/rules-monitor.pid"
DEBOUNCE=5          # seconds of silence before re-syncing
COOLDOWN=10         # seconds after sync to suppress self-triggered events
LOCKFILE="/var/run/rules-sync.lock"
LOG="/var/log/rules-monitor.log"

# -----------------------------------------------------------------
# Prevent duplicate instances — kill any existing monitor
# -----------------------------------------------------------------
if [[ -f "$PIDFILE" ]]; then
    old_pid=$(cat "$PIDFILE" 2>/dev/null)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        echo "[rules-monitor] Killing old instance (PID $old_pid)."
        kill "$old_pid" 2>/dev/null
        sleep 1
    fi
    rm -f "$PIDFILE"
fi

# -----------------------------------------------------------------
# Parse config to discover which interfaces and tables to watch
# -----------------------------------------------------------------
get_sync_interfaces() {
    local conf="$1"
    local ifaces=()

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" == route-sync\ * ]]; then
            read -ra parts <<< "$line"
            if [[ ${#parts[@]} -ge 3 ]]; then
                ifaces+=("${parts[1]}")
            fi
        fi
    done < "$conf"

    printf '%s\n' "${ifaces[@]}" | sort -u
}

get_sync_tables() {
    local conf="$1"
    local tables=()

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" == route-sync\ * ]]; then
            read -ra parts <<< "$line"
            if [[ ${#parts[@]} -ge 3 ]]; then
                tables+=("${parts[2]}")
            fi
        fi
    done < "$conf"

    printf '%s\n' "${tables[@]}" | sort -u
}

IFACES=( $(get_sync_interfaces "$CONF") )
TABLES=( $(get_sync_tables "$CONF") )

if [[ ${#IFACES[@]} -eq 0 ]]; then
    echo "[rules-monitor] No route-sync directives found in $CONF. Nothing to watch."
    exit 0
fi

echo "[rules-monitor] Host: $(hostname)"
echo "[rules-monitor] Config: $CONF"
echo "[rules-monitor] Watching interfaces: ${IFACES[*]}"
echo "[rules-monitor] Watching tables: ${TABLES[*]}"
echo "[rules-monitor] Debounce: ${DEBOUNCE}s of silence | Log: $LOG"

# -----------------------------------------------------------------
# Background the monitor loop
# -----------------------------------------------------------------
_monitor() {
    echo $BASHPID > "$PIDFILE"
    trap 'rm -f "$PIDFILE" "$LOCKFILE"; exit 0' INT TERM

    # Build grep pattern to match events on our interfaces or tables.
    local patterns=()
    for iface in "${IFACES[@]}"; do
        patterns+=("dev ${iface}")
    done
    for table in "${TABLES[@]}"; do
        patterns+=("table ${table}")
    done

    local grep_pattern
    grep_pattern=$(printf '%s\|' "${patterns[@]}")
    grep_pattern="${grep_pattern%\\|}"

    ip monitor route 2>/dev/null | while true; do
        # Block until the first matching event
        local event
        while IFS= read -r event; do
            if echo "$event" | grep -q "\(${grep_pattern}\)"; then
                break
            fi
        done

        # If read failed (pipe closed), exit
        [[ -z "${event:-}" ]] && break

        # ---- Self-trigger guard ----
        # If the lockfile exists and is younger than COOLDOWN seconds,
        # this event was caused by our own rules-sync.  Drain and skip.
        if [[ -f "$LOCKFILE" ]]; then
            local lock_age
            lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0) ))
            if [[ "$lock_age" -lt "$COOLDOWN" ]]; then
                echo "[$(date)] Ignoring event during cooldown (${lock_age}s < ${COOLDOWN}s): $event" >> "$LOG"
                # Drain any queued events for the debounce window
                while IFS= read -t "$DEBOUNCE" -r event; do :; done
                continue
            fi
        fi

        echo "[$(date)] Route change detected: $event" >> "$LOG"

        # Drain: keep reading until DEBOUNCE seconds of silence.
        # This lets UBIOS finish its entire provisioning flush
        # before we attempt to re-sync.
        local drained=0
        while IFS= read -t "$DEBOUNCE" -r event; do
            (( drained++ )) || true
        done

        if [[ "$drained" -gt 0 ]]; then
            echo "[$(date)] Drained $drained more events during settle window" >> "$LOG"
        fi

        # Create lockfile before running — rules-sync will generate
        # route events that we need to ignore.
        touch "$LOCKFILE"

        echo "[$(date)] Re-running $RULES_SCRIPT" >> "$LOG"
        "$RULES_SCRIPT" "$CONF" >> "$LOG" 2>&1 || true

        # Refresh lockfile timestamp after script completes so the
        # cooldown window starts from now.
        touch "$LOCKFILE"
    done
}

_monitor &
disown

echo "[rules-monitor] Started in background (PID $(cat "$PIDFILE" 2>/dev/null || echo '?'))."
