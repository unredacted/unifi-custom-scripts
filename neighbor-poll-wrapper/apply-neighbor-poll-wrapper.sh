#!/bin/bash
# ---- Apply Neighbor-Poll Wrapper ----
#
# UBIOS's ubios-udapi-server runs an `nl-neighbors-poll` subsystem that
# watches the kernel neighbor cache and shells out to small probe tools
# for every entry, on a short periodic cycle:
#
#   IPv4: /usr/sbin/arping -q -c 2 -w 3 -I <bridge> <ip>
#   IPv6: /usr/bin/ndisc6  [opts] <ipv6> <bridge>
#
# On an IXP peering fabric this produces a continuous broadcast ARP and
# multicast NS storm that violates IX policy (AMS-IX / SIX require a
# 4-hour ARP/ND cache timeout).
#
# There is no config switch to disable the behavior in ubios-udapi-server.
# The surgical fix is to interpose a wrapper over each probe binary that
# silently returns success (exit 0) when invoked with an IXP bridge
# anywhere in its arguments.  All other invocations pass through to the
# real binary unchanged.  The kernel's own NUD handles real reachability
# on the IXP via BGP dst_confirm(), so no functionality is lost.
#
# The wrappers are installed via bind-mount to avoid modifying the real
# binaries — unmounting restores original behavior.
#
# Config file format (one interface name per line, comments with #):
#   br3996
#   br3997
#   br3998
#   br3999
#
# Config resolution (first match wins):
#   1. Explicit argument:              $1
#   2. Per-host conf:                  conf/$(hostname).conf
#   3. Flat preferred:                 neighbor-poll-wrapper.conf
#
# Usage:
#   apply-neighbor-poll-wrapper.sh [config-path]
#   apply-neighbor-poll-wrapper.sh --uninstall    # remove all bind-mounts only

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_DIR="/data/ix-neighbor-poll-wrapper"

# Probe binaries to wrap.  Add more here if ubios-udapi-server starts
# using additional tools (e.g. rdisc6, ping6, ndppd).
TARGETS=(
    "/usr/sbin/arping"
    "/usr/bin/ndisc6"
)

# -----------------------------------------------------------------
# Uninstall mode — unmount every wrapper, restore original behavior
# -----------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    for target in "${TARGETS[@]}"; do
        if mount | grep -q " on ${target} "; then
            umount "${target}"
            echo "[neighbor-poll-wrapper] Unmounted wrapper from ${target}"
        else
            echo "[neighbor-poll-wrapper] No wrapper mount found at ${target}"
        fi
    done
    exit 0
fi

# -----------------------------------------------------------------
# Config resolution
# -----------------------------------------------------------------
if [[ -n "${1:-}" ]]; then
    CONF="$1"
elif [[ -f "${SCRIPT_DIR}/conf/$(hostname).conf" ]]; then
    CONF="${SCRIPT_DIR}/conf/$(hostname).conf"
elif [[ -f "${SCRIPT_DIR}/neighbor-poll-wrapper.conf" ]]; then
    CONF="${SCRIPT_DIR}/neighbor-poll-wrapper.conf"
else
    echo "[neighbor-poll-wrapper] No config found for host '$(hostname)'."
    echo "                        Looked for:"
    echo "                          ${SCRIPT_DIR}/conf/$(hostname).conf"
    echo "                          ${SCRIPT_DIR}/neighbor-poll-wrapper.conf"
    exit 1
fi

if [[ ! -f "${CONF}" ]]; then
    echo "[neighbor-poll-wrapper] Config file not found: ${CONF}"
    exit 1
fi

# -----------------------------------------------------------------
# Parse config: strip comments, blank lines, and whitespace
# -----------------------------------------------------------------
INTERFACES=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    INTERFACES+=("$line")
done < "${CONF}"

if [[ ${#INTERFACES[@]} -eq 0 ]]; then
    echo "[neighbor-poll-wrapper] No interfaces in config: ${CONF}"
    exit 1
fi

echo "[neighbor-poll-wrapper] Config: ${CONF}"
echo "[neighbor-poll-wrapper] Interfaces to skip: ${INTERFACES[*]}"

# -----------------------------------------------------------------
# Build the wrapper case-pattern from the interface list
# -----------------------------------------------------------------
CASE_PATTERN=""
for iface in "${INTERFACES[@]}"; do
    if [[ -n "$CASE_PATTERN" ]]; then
        CASE_PATTERN+="|${iface}"
    else
        CASE_PATTERN="${iface}"
    fi
done

mkdir -p "${WRAPPER_DIR}"

# -----------------------------------------------------------------
# install_wrapper: install one bind-mount wrapper
#
# Args:
#   $1 — full path to the real binary (e.g. /usr/sbin/arping)
# -----------------------------------------------------------------
install_wrapper() {
    local target="$1"
    local name
    name="$(basename "$target")"
    local wrapper_bin="${WRAPPER_DIR}/${name}"
    local wrapper_real="${WRAPPER_DIR}/${name}.real"

    if [[ ! -e "$target" ]]; then
        echo "[neighbor-poll-wrapper] ${target} not present on this system, skipping."
        return 0
    fi

    # Save the real binary if we haven't already.  Use the mount table
    # to detect "already wrapped" — if mounted, ${target} is the wrapper.
    if ! mount | grep -q " on ${target} "; then
        if [[ ! -f "$wrapper_real" ]]; then
            cp "$target" "$wrapper_real"
            echo "[neighbor-poll-wrapper] Saved real binary: ${wrapper_real}"
        fi
    fi

    # Always rewrite the wrapper so the interface list stays in sync
    # with the config file.  We match if ANY argument equals an IX
    # bridge name — covers both arping (-I <iface>) and ndisc6
    # (positional <iface> at end), plus any future tool that takes an
    # interface as a bare argument.
    cat > "$wrapper_bin" <<WRAPPER
#!/bin/bash
# Auto-generated by apply-neighbor-poll-wrapper.sh — do not edit by hand.
# Wraps: ${target}
# Interfaces skipped: ${INTERFACES[*]}
#
# Returns 0 (success) if any argument matches an IX bridge so the
# caller (typically ubios-udapi-server's nl-neighbors-poll) believes
# the probe succeeded.  Kernel NUD handles real reachability via BGP
# dst_confirm() so no functionality is lost on the IXP fabric.
for arg in "\$@"; do
    case "\$arg" in
        ${CASE_PATTERN}) exit 0 ;;
    esac
done
exec "${wrapper_real}" "\$@"
WRAPPER
    chmod +x "$wrapper_bin"
    echo "[neighbor-poll-wrapper] Installed wrapper: ${wrapper_bin}"

    # Apply the bind-mount (idempotent).
    #
    # If the mount was previously established and has since disappeared,
    # UBIOS (or some other process) removed it.  This is a critical
    # event because between unmount and re-mount, the real arping/ndisc6
    # binary is exposed and ubios-udapi-server's nl-neighbors-poll can
    # fire a full peer-sweep that the IX NOC will see.  Log it LOUDLY
    # and also to syslog so it's easy to correlate with other events.
    if mount | grep -q " on ${target} "; then
        echo "[neighbor-poll-wrapper] Wrapper already bind-mounted at ${target}"
    else
        # Differentiate first-install from recovery: if the wrapper has
        # ever been mounted here (evidenced by the .real file existing
        # and being populated), this is a re-mount after loss.
        local alert_prefix="Bind-mounted"
        if [[ -f "${wrapper_real}" ]] && [[ -s "${wrapper_real}" ]]; then
            alert_prefix="!!! MOUNT LOST !!! restoring"
            echo "[neighbor-poll-wrapper] $(date -u +%Y-%m-%dT%H:%M:%SZ) ${alert_prefix}: ${target}"
            logger -t neighbor-poll-wrapper -p daemon.warning \
                "MOUNT LOST: ${target} was unmounted; restoring wrapper bind-mount. IX peers may have been exposed to nl-neighbors-poll."
        fi
        mount --bind "$wrapper_bin" "$target"
        echo "[neighbor-poll-wrapper] ${alert_prefix}: ${wrapper_bin} -> ${target}"
    fi

    if ! mount | grep -q " on ${target} "; then
        echo "[neighbor-poll-wrapper] ERROR: bind-mount did not take effect for ${target}"
        return 1
    fi

    local size real_size
    size=$(stat -c %s "$target")
    real_size=$(stat -c %s "$wrapper_real" 2>/dev/null || echo "?")
    echo "[neighbor-poll-wrapper] ${target} is now ${size} bytes (real binary is ${real_size})."
}

# -----------------------------------------------------------------
# Install all wrappers
# -----------------------------------------------------------------
fail=0
for target in "${TARGETS[@]}"; do
    install_wrapper "$target" || fail=1
done

if [[ "$fail" -ne 0 ]]; then
    echo "[neighbor-poll-wrapper] One or more wrappers failed to install."
    exit 1
fi

echo "[neighbor-poll-wrapper] Active."
