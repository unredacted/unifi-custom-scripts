#!/bin/bash
# ---- Monitor Watchdog ----
#
# Supervises the per-subsystem monitor daemons in this repository
# (rules-monitor, switch-config-monitor, neighbor-poll-wrapper-monitor,
# and any future ones).  Designed to be invoked once per minute by
# cron, so that the supervisor itself runs in the cron daemon's
# process tree — outside any process group UBIOS may pause/SIGSTOP
# during config-sync or reprovisioning cycles.
#
# Why this exists:
#   The per-subsystem monitors all background themselves once at
#   boot from /data/on_boot.d and then run forever (in theory).  In
#   practice we have observed log-evidence of one of them not
#   logging for 2.5 hours despite its PID still being valid in
#   /var/run.  The shape of the gap (no error, no restart sequence,
#   no "Killing old instance" line) is consistent with the process
#   being SIGSTOP'd and later SIGCONT'd by something in the system.
#   While stopped, it does not run apply-script cycles, the wrapper
#   bind-mount can drift, and the IX fabric sees the storm.
#
#   A watchdog that lives outside that process tree (cron-invoked)
#   detects "stuck" not just "dead" by checking heartbeat-file mtime,
#   then SIGKILL+restart.  Phase-2 work is to migrate the monitors
#   to systemd units with WatchdogSec= for sub-10s recovery; this
#   cron-based supervisor brings worst-case from observed 2.5 hours
#   down to ≤60 seconds.
#
# Detection logic per monitored daemon:
#   1. PIDfile exists, points at a live process (kill -0)
#   2. Heartbeat file exists, mtime is within max_silence_sec
#   If either fails: SIGKILL the stale PID (SIGTERM cannot be
#   delivered to a SIGSTOP'd process; SIGKILL always can), clean
#   up the PIDfile, then invoke the launcher.
#
# Registry format (lib/monitors.conf):
#   <name> <pidfile> <heartbeat-file> <max_silence_sec> <launcher-path>
#
# Lines starting with # and blank lines are ignored.  Whitespace-
# separated; no quoting required because all fields are simple
# tokens (paths and integers).
#
# Logging:
#   • Routine "all healthy" cycles → /var/log/monitor-watchdog.log
#     only at LOG_VERBOSE=1 (default off) to keep volume bounded
#   • Restart events → both the log AND syslog (logger -t
#     monitor-watchdog -p daemon.warning) so they're easy to find
#     via journalctl and correlate with UBIOS events
#
# Self-supervision:
#   The watchdog touches /var/run/monitor-watchdog.heartbeat on
#   every successful run.  If you want to alert on the watchdog
#   itself dying, point an external system at that file's mtime.
#   (Cron's own logging to /var/log/cron is also a useful signal.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Config resolution: explicit arg > monitors.conf next to this script
if [[ -n "${1:-}" ]]; then
    CONF="$1"
elif [[ -f "${SCRIPT_DIR}/monitors.conf" ]]; then
    CONF="${SCRIPT_DIR}/monitors.conf"
else
    echo "[monitor-watchdog] No registry found. Looked for ${SCRIPT_DIR}/monitors.conf" >&2
    exit 1
fi

LOG="${MONITOR_WATCHDOG_LOG:-/var/log/monitor-watchdog.log}"
SELF_HEARTBEAT="/var/run/monitor-watchdog.heartbeat"
LOG_VERBOSE="${LOG_VERBOSE:-0}"

# Lockfile to prevent concurrent watchdog runs from racing
# (e.g. if cron fires before the previous run finished).
LOCKFILE="/var/run/monitor-watchdog.lock"
exec 9>"$LOCKFILE" || { echo "[monitor-watchdog] Could not open lockfile $LOCKFILE" >&2; exit 1; }
if ! flock -n 9; then
    # Another watchdog is running.  Don't queue up multiple — exit silently.
    exit 0
fi

# -----------------------------------------------------------------
# log: append a line to $LOG with timestamp
# -----------------------------------------------------------------
log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"
}

# -----------------------------------------------------------------
# alert: log AND send to syslog at daemon.warning priority
# -----------------------------------------------------------------
alert() {
    log "$*"
    logger -t monitor-watchdog -p daemon.warning "$*" 2>/dev/null || true
}

# -----------------------------------------------------------------
# check_one: inspect one registered monitor; restart if stuck/dead.
#
# Args:
#   $1 — name (e.g. "rules-monitor")
#   $2 — pidfile path
#   $3 — heartbeat-file path
#   $4 — max_silence_sec (seconds since last heartbeat that count
#                          as "stuck"; if 0, heartbeat check is
#                          skipped — useful for monitors that don't
#                          yet emit heartbeats)
#   $5 — launcher path (script that, when invoked, kills any
#                        previous instance and starts a new one)
#
# Returns:
#   0 — healthy (no action) or successfully restarted
#   1 — restart attempt failed (launcher exited non-zero)
# -----------------------------------------------------------------
check_one() {
    local name="$1" pidfile="$2" heartbeat="$3" max_silence="$4" launcher="$5"

    if [[ ! -x "$launcher" ]]; then
        alert "${name}: launcher missing or not executable: ${launcher} — skipping"
        return 1
    fi

    # ---- 1. PID liveness ----
    local pid="" pid_alive=0
    if [[ -f "$pidfile" ]]; then
        pid=$(cat "$pidfile" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            pid_alive=1
        fi
    fi

    # ---- 2. Heartbeat freshness (only if we expect heartbeats) ----
    local hb_fresh=1 hb_age=0
    if [[ "$max_silence" -gt 0 ]]; then
        if [[ -f "$heartbeat" ]]; then
            local now mtime
            now=$(date +%s)
            mtime=$(stat -c %Y "$heartbeat" 2>/dev/null || echo 0)
            hb_age=$((now - mtime))
            if [[ "$hb_age" -gt "$max_silence" ]]; then
                hb_fresh=0
            fi
        else
            # No heartbeat file yet — give the monitor one max_silence
            # window after install before treating its absence as stuck.
            # We approximate that by accepting absence iff the launcher
            # has been touched within max_silence.
            local launcher_age now
            now=$(date +%s)
            launcher_age=$(( now - $(stat -c %Y "$launcher" 2>/dev/null || echo 0) ))
            if [[ "$launcher_age" -lt "$max_silence" ]]; then
                hb_fresh=1
            else
                hb_fresh=0
                hb_age="missing"
            fi
        fi
    fi

    # ---- 3. Decide ----
    if [[ "$pid_alive" -eq 1 && "$hb_fresh" -eq 1 ]]; then
        [[ "$LOG_VERBOSE" -eq 1 ]] && log "${name}: healthy (pid=${pid}, heartbeat_age=${hb_age}s)"
        return 0
    fi

    # Something's wrong — characterize and restart.
    local reason
    if [[ "$pid_alive" -eq 0 && "$hb_fresh" -eq 0 ]]; then
        reason="dead (no live PID; heartbeat ${hb_age}s old vs max ${max_silence}s)"
    elif [[ "$pid_alive" -eq 0 ]]; then
        reason="dead (no live PID for ${pid:-<no pidfile>})"
    else
        reason="stuck (pid=${pid} alive but heartbeat ${hb_age}s old vs max ${max_silence}s)"
    fi
    alert "${name}: ${reason} — restarting"

    # SIGKILL is necessary because SIGTERM cannot be delivered to a
    # SIGSTOP'd process.  SIGKILL is always delivered, even to
    # stopped processes (the kernel reaps them on the next scheduler
    # pass).  The launcher's own "kill old instance" logic uses
    # SIGTERM, which would silently no-op against our suspect.
    if [[ "$pid_alive" -eq 1 ]]; then
        kill -KILL "$pid" 2>/dev/null || true
        # Brief wait so the launcher's own pidfile read sees a
        # cleared slot, not a still-running process.
        for _i in 1 2 3 4 5; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
    fi
    rm -f "$pidfile"

    # Run the launcher.  Its output goes into $LOG.
    if "$launcher" >> "$LOG" 2>&1; then
        alert "${name}: restarted successfully"
        return 0
    else
        alert "${name}: LAUNCHER FAILED (exit non-zero) — see ${LOG}"
        return 1
    fi
}

# -----------------------------------------------------------------
# Main loop: read registry, check each monitor.
# -----------------------------------------------------------------
fail=0
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    # Expect 5 whitespace-separated fields.
    read -r name pidfile heartbeat max_silence launcher <<<"$line"
    if [[ -z "$name" || -z "$pidfile" || -z "$heartbeat" || -z "$max_silence" || -z "$launcher" ]]; then
        alert "registry parse error (need 5 fields): $line"
        fail=1
        continue
    fi
    check_one "$name" "$pidfile" "$heartbeat" "$max_silence" "$launcher" || fail=1
done < "$CONF"

# Self-heartbeat (so anything watching us has a positive signal too).
: > "$SELF_HEARTBEAT"

exit "$fail"
