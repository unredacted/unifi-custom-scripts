#!/bin/bash
# ---- Rules Sync Monitor ----
#
# Watches for kernel changes that indicate any rule managed by
# inject-rules.sh might have been flushed, and re-runs the inject
# script to restore idempotent state.
#
# What is monitored (auto-detected from config):
#   • ip monitor route  — route-sync interfaces/tables, static routes,
#                          and IPv6 routes.  A provisioning flush here
#                          also implies iptables/ebtables were likely
#                          flushed too, so the full inject runs.
#   • ip monitor rule   — ip rule add/del directives (v4 + v6).
#                          UBIOS provisioning often flushes policy rules.
#   • Periodic heartbeat — every HEARTBEAT seconds, verify that at least
#                          one iptables/ebtables rule still exists.  If a
#                          rule is missing, trigger a full re-inject.
#                          This catches netfilter flushes that have no
#                          kernel event channel.
#
# Debounce strategy: when a matching event arrives, keep draining
# events until no new event arrives for DEBOUNCE seconds. Only then
# run the sync. This ensures we wait for UBIOS to finish its entire
# provisioning cycle before re-adding everything.
#
# All interfaces, tables, and verification rules are parsed from
# the config — nothing is hardcoded.
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
HEARTBEAT=60        # seconds between iptables/ebtables verification polls
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
# Parse config to discover what needs monitoring
# -----------------------------------------------------------------

# Extract unique interface names from route-sync directives
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

    printf '%s\n' "${ifaces[@]}" 2>/dev/null | sort -u
}

# Extract unique table IDs from route-sync directives
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

    printf '%s\n' "${tables[@]}" 2>/dev/null | sort -u
}

# Extract interfaces referenced in ip route add directives (dev <iface>)
get_route_interfaces() {
    local conf="$1"
    local ifaces=()

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" == ip\ route\ add\ * || "$line" == "ip -6 route add"\ * ]]; then
            # Extract interface from "dev <iface>"
            local dev
            dev="$(echo "$line" | sed -nE 's/.*dev ([^ ]+).*/\1/p')" || true
            if [[ -n "$dev" ]]; then
                ifaces+=("$dev")
            fi
        fi
    done < "$conf"

    printf '%s\n' "${ifaces[@]}" 2>/dev/null | sort -u
}

# Extract table IDs from ip route add directives (table <id>)
get_route_tables() {
    local conf="$1"
    local tables=()

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" == ip\ route\ add\ * || "$line" == "ip -6 route add"\ * ]]; then
            # Extract table from "table <id>"
            local tbl
            tbl="$(echo "$line" | sed -nE 's/.*table ([^ ]+).*/\1/p')" || true
            if [[ -n "$tbl" ]]; then
                tables+=("$tbl")
            fi
        fi
    done < "$conf"

    printf '%s\n' "${tables[@]}" 2>/dev/null | sort -u
}

# Detect which directive types are present in the config
detect_directive_types() {
    local conf="$1"
    local types=()

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        case "$line" in
            iptables\ *)           types+=("iptables") ;;
            ebtables\ *)           types+=("ebtables") ;;
            ip\ rule\ *|"ip -6 rule"\ *)    types+=("ip-rule") ;;
            ip\ route\ *|"ip -6 route"\ *)  types+=("ip-route") ;;
            route-sync\ *)         types+=("route-sync") ;;
        esac
    done < "$conf"

    printf '%s\n' "${types[@]}" 2>/dev/null | sort -u
}

# Extract the first iptables rule from config (for heartbeat verification)
get_first_iptables_check() {
    local conf="$1"

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" == iptables\ * ]]; then
            # Convert -I/-A to -C for check
            local check="${line/-I /-C }"
            check="${check/-A /-C }"
            # Strip positional arg (e.g. "-C FORWARD 1" → "-C FORWARD")
            check="$(echo "$check" | sed -E 's/(-C [A-Z]+) [0-9]+/\1/')"
            echo "$check"
            return
        fi
    done < "$conf"
}

# Extract the first ebtables rule from config (for heartbeat verification)
# Returns a delete-form command that exits 0 only if the rule exists
get_first_ebtables_check() {
    local conf="$1"

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" == ebtables\ * ]]; then
            # We can't use -C, but we can list-and-grep the chain
            local chain
            chain="$(echo "$line" | sed -E 's/^ebtables\s+-[AI]\s+(\S+).*/\1/')"
            local rule_body
            rule_body="$(echo "$line" | sed -E 's/^ebtables\s+-[AI]\s+\S+\s+//')"
            # Return a check command that greps the chain listing
            echo "ebtables -L ${chain} --Lmac2 2>/dev/null | grep -qi '$(echo "$rule_body" | sed "s/'/'\\''/g")'"
            return
        fi
    done < "$conf"
}

# -----------------------------------------------------------------
# Gather all monitoring parameters
# -----------------------------------------------------------------
DIRECTIVE_TYPES=( $(detect_directive_types "$CONF") )

if [[ ${#DIRECTIVE_TYPES[@]} -eq 0 ]]; then
    echo "[rules-monitor] No active directives found in $CONF. Nothing to monitor."
    exit 0
fi

# Merge interfaces from route-sync and ip route directives
ALL_IFACES=( $(
    { get_sync_interfaces "$CONF"; get_route_interfaces "$CONF"; } | sort -u
) )

# Merge tables from route-sync and ip route directives
ALL_TABLES=( $(
    { get_sync_tables "$CONF"; get_route_tables "$CONF"; } | sort -u
) )

# Determine what event types to monitor
WATCH_ROUTES=false
WATCH_RULES=false
WATCH_NETFILTER=false

for dtype in "${DIRECTIVE_TYPES[@]}"; do
    case "$dtype" in
        route-sync|ip-route) WATCH_ROUTES=true ;;
        ip-rule)             WATCH_RULES=true ;;
        iptables|ebtables)   WATCH_NETFILTER=true ;;
    esac
done

# Build iptables/ebtables check commands for heartbeat verification
IPTABLES_CHECK=""
EBTABLES_CHECK=""
if $WATCH_NETFILTER; then
    IPTABLES_CHECK="$(get_first_iptables_check "$CONF")"
    EBTABLES_CHECK="$(get_first_ebtables_check "$CONF")"
fi

echo "[rules-monitor] Host: $(hostname)"
echo "[rules-monitor] Config: $CONF"
echo "[rules-monitor] Directive types: ${DIRECTIVE_TYPES[*]}"
[[ ${#ALL_IFACES[@]} -gt 0 ]] && echo "[rules-monitor] Watching interfaces: ${ALL_IFACES[*]}"
[[ ${#ALL_TABLES[@]} -gt 0 ]] && echo "[rules-monitor] Watching tables: ${ALL_TABLES[*]}"
$WATCH_ROUTES && echo "[rules-monitor] Monitoring: ip route events"
$WATCH_RULES && echo "[rules-monitor] Monitoring: ip rule events"
$WATCH_NETFILTER && echo "[rules-monitor] Monitoring: netfilter heartbeat (every ${HEARTBEAT}s)"
echo "[rules-monitor] Debounce: ${DEBOUNCE}s of silence | Log: $LOG"

# -----------------------------------------------------------------
# Background the monitor loop
# -----------------------------------------------------------------
_monitor() {
    echo $BASHPID > "$PIDFILE"
    trap 'rm -f "$PIDFILE" "$LOCKFILE" /var/run/rules-monitor.fifo; kill 0 2>/dev/null; exit 0' INT TERM

    # ---- event FIFO ----
    # All event sources write trigger lines into a single FIFO.
    # The main loop reads from it, debounces, and runs the inject script.
    local fifo="/var/run/rules-monitor.fifo"
    rm -f "$fifo"
    mkfifo "$fifo"

    # ---- Route monitor ----
    if $WATCH_ROUTES; then
        (
            # Build grep pattern for our interfaces and tables
            local patterns=()
            for iface in "${ALL_IFACES[@]}"; do
                patterns+=("dev ${iface}")
            done
            for table in "${ALL_TABLES[@]}"; do
                patterns+=("table ${table}")
            done

            if [[ ${#patterns[@]} -gt 0 ]]; then
                local grep_pattern
                grep_pattern=$(printf '%s\|' "${patterns[@]}")
                grep_pattern="${grep_pattern%\\|}"

                ip monitor route 2>/dev/null | while IFS= read -r event; do
                    if echo "$event" | grep -q "\(${grep_pattern}\)"; then
                        echo "route: $event" > "$fifo" 2>/dev/null || exit 0
                    fi
                done
            else
                # No specific interfaces/tables — watch all route changes
                ip monitor route 2>/dev/null | while IFS= read -r event; do
                    echo "route: $event" > "$fifo" 2>/dev/null || exit 0
                done
            fi
        ) &
    fi

    # ---- Rule monitor ----
    if $WATCH_RULES; then
        (
            ip monitor rule 2>/dev/null | while IFS= read -r event; do
                # Any rule change is potentially ours being flushed
                echo "rule: $event" > "$fifo" 2>/dev/null || exit 0
            done
        ) &
    fi

    # ---- Netfilter heartbeat ----
    # iptables/ebtables have no kernel event channel, so we poll.
    # We check if a known rule still exists; if not, trigger re-inject.
    if $WATCH_NETFILTER; then
        (
            sleep 10  # Give initial inject time to finish
            while true; do
                sleep "$HEARTBEAT"

                local missing=false

                # Check iptables
                if [[ -n "$IPTABLES_CHECK" ]]; then
                    if ! eval "$IPTABLES_CHECK" 2>/dev/null; then
                        missing=true
                    fi
                fi

                # Check ebtables
                if [[ -n "$EBTABLES_CHECK" ]] && ! $missing; then
                    if ! eval "$EBTABLES_CHECK" 2>/dev/null; then
                        missing=true
                    fi
                fi

                if $missing; then
                    echo "heartbeat: netfilter rule missing" > "$fifo" 2>/dev/null || exit 0
                fi
            done
        ) &
    fi

    # ---- Main debounce loop ----
    # Open persistent FDs on the FIFO:
    #   FD 3 = read end (blocks until data arrives)
    #   FD 4 = dummy write end (prevents EOF when real writers close)
    exec 3<"$fifo"
    exec 4>"$fifo"

    # Reads trigger events from the FIFO, debounces, runs inject.
    while true; do
        # Block until the first event
        local event
        IFS= read -r event <&3 || break

        # Self-trigger guard: if lockfile is fresh, this is our own event
        if [[ -f "$LOCKFILE" ]]; then
            local lock_age
            lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0) ))
            if [[ "$lock_age" -lt "$COOLDOWN" ]]; then
                echo "[$(date)] Ignoring event during cooldown (${lock_age}s < ${COOLDOWN}s): $event" >> "$LOG"
                # Drain queued events
                while IFS= read -t "$DEBOUNCE" -r event <&3; do :; done
                continue
            fi
        fi

        echo "[$(date)] Change detected: $event" >> "$LOG"

        # Drain: keep reading until DEBOUNCE seconds of silence.
        # This lets UBIOS finish its entire provisioning flush
        # before we attempt to re-sync.
        local drained=0
        while IFS= read -t "$DEBOUNCE" -r event <&3; do
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

    # Cleanup
    exec 3<&-
    exec 4>&-
    rm -f "$fifo"
}

_monitor &
disown

echo "[rules-monitor] Started in background (PID $(cat "$PIDFILE" 2>/dev/null || echo '?'))."
