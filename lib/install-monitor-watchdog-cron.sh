#!/bin/bash
# ---- Install Monitor Watchdog Cron Entry ----
#
# Idempotently installs a once-a-minute cron entry that runs
# monitor-watchdog.sh.  Safe to run repeatedly; it identifies its
# own entry by a sentinel comment and replaces it in-place if the
# command line has changed.
#
# Why cron and not systemd timer (yet):
#   On UBIOS, dropping a unit file under /etc/systemd/system can be
#   wiped on firmware upgrade and behavior across UBIOS versions
#   varies.  cron lives in /etc/crontab and persists.  cron daemon
#   is part of the OS service set, runs outside our process tree,
#   and survives the same UBIOS reprovisioning cycles that have
#   silently SIGSTOP'd our user-space monitors.  Phase-2 plan is to
#   migrate to systemd units with WatchdogSec= once we've validated
#   that path on UBIOS; until then, cron's 60-second floor on
#   recovery latency is a 150× improvement on the 2.5-hour gap we
#   observed in the field.
#
# Usage:
#   install-monitor-watchdog-cron.sh           # install/update
#   install-monitor-watchdog-cron.sh --remove  # uninstall

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="${SCRIPT_DIR}/monitor-watchdog.sh"
CRON_FILE="/etc/cron.d/unifi-scripts-monitor-watchdog"

# Sentinel marks our entry so we can find/replace it without
# disturbing other cron rules the operator has installed.
SENTINEL="# MANAGED BY unifi-scripts/lib/install-monitor-watchdog-cron.sh — do not edit"

if [[ "${1:-}" == "--remove" ]]; then
    if [[ -f "$CRON_FILE" ]]; then
        rm -f "$CRON_FILE"
        echo "[install-monitor-watchdog-cron] Removed $CRON_FILE"
    else
        echo "[install-monitor-watchdog-cron] No cron file at $CRON_FILE — nothing to remove"
    fi
    exit 0
fi

if [[ ! -x "$WATCHDOG" ]]; then
    echo "[install-monitor-watchdog-cron] ERROR: watchdog not executable at $WATCHDOG" >&2
    exit 1
fi

# /etc/cron.d entries require a username field; cron daemon reads
# them automatically without needing crontab -u root edits.
NEW_CONTENT=$(cat <<EOF
${SENTINEL}
# Runs every minute.  Worst-case detection latency for a stuck or
# dead monitor is ~max_silence_sec from monitors.conf + 60s cron tick.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root ${WATCHDOG} >> /var/log/monitor-watchdog.log 2>&1
EOF
)

# Idempotency: only write if content differs from what's there.
if [[ -f "$CRON_FILE" ]] && [[ "$(cat "$CRON_FILE")" == "$NEW_CONTENT" ]]; then
    echo "[install-monitor-watchdog-cron] Cron entry already current at $CRON_FILE"
    exit 0
fi

mkdir -p "$(dirname "$CRON_FILE")"
printf '%s\n' "$NEW_CONTENT" > "$CRON_FILE"
chmod 0644 "$CRON_FILE"
echo "[install-monitor-watchdog-cron] Installed cron entry: $CRON_FILE"
echo "[install-monitor-watchdog-cron] Watchdog will fire once per minute."

# Some cron implementations require a SIGHUP or service reload to
# pick up new files in /etc/cron.d.  Most modern crons (vixie,
# cronie, systemd-cron) inotify-watch the directory, so this is a
# belt-and-suspenders nudge.
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet cron 2>/dev/null; then
    systemctl reload cron 2>/dev/null || systemctl restart cron 2>/dev/null || true
elif command -v service >/dev/null 2>&1; then
    service cron reload 2>/dev/null || service cron restart 2>/dev/null || true
fi
