#!/bin/bash
# ---- Custom Routes & Rules ----
#
# Reads raw commands from a config file and applies them idempotently.
# If a rule already exists, it is skipped. Nothing is ever deleted
# unless explicitly requested via "del" directives.
#
# Config resolution (first match wins):
#   1. Explicit argument:              $1
#   2. Per-host conf:                  conf/$(hostname).conf
#   3. Flat preferred:                 inject-rules.conf
#   4. Legacy fallback:                custom-routes.conf
#
# Supported directives:
#   iptables ...                            — idempotent iptables rule insertion
#   ebtables ...                            — idempotent ebtables rule insertion
#   ip rule add ...                         — idempotent policy rule insertion
#   ip rule del ...                         — idempotent policy rule deletion
#   ip route add ...                        — idempotent route insertion
#   ip route del ...                        — idempotent route deletion
#   ip -6 route add ...                     — idempotent IPv6 route insertion
#   ip -6 route del ...                     — idempotent IPv6 route deletion
#   ip -6 rule add ...                      — idempotent IPv6 policy rule insertion
#   ip -6 rule del ...                      — idempotent IPv6 policy rule deletion
#   route-sync <iface> <table> [subnet]     — mirror routes on <iface> into <table>
#                                             optional subnet filter (e.g. 23.191.200.0/24)

set -euo pipefail

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
    echo "[ERROR] No config found for host '$(hostname)'. Looked for:"
    echo "        ${SCRIPT_DIR}/conf/$(hostname).conf"
    echo "        ${SCRIPT_DIR}/inject-rules.conf"
    echo "        ${SCRIPT_DIR}/custom-routes.conf"
    exit 1
fi

ADDED=0
EXISTED=0
FAILED=0
SKIPPED=0
DELETED=0

inc() { eval "$1=\$(( $1 + 1 ))"; }

# -----------------------------------------------------------------
# Helper: check if an IP falls within a CIDR prefix.
# Usage: _ip_in_cidr 23.191.200.2 23.191.200.0/24  → returns 0 or 1
# -----------------------------------------------------------------
_ip_to_int() {
    local IFS='.'
    read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

_ip_in_cidr() {
    local ip="$1"
    local cidr="$2"
    local net="${cidr%/*}"
    local bits="${cidr#*/}"

    local ip_int net_int mask

    ip_int=$(_ip_to_int "$ip")
    net_int=$(_ip_to_int "$net")

    if [[ "$bits" -eq 0 ]]; then
        return 0
    fi
    mask=$(( 0xFFFFFFFF << (32 - bits) ))

    if (( (ip_int & mask) == (net_int & mask) )); then
        return 0
    else
        return 1
    fi
}

# -----------------------------------------------------------------
# iptables: swap -I/-A with -C to check, then insert if missing
# -----------------------------------------------------------------
run_iptables() {
    local check_cmd="${1/-I /-C }"
    check_cmd="${check_cmd/-A /-C }"

    # Strip positional argument (e.g. "-I FORWARD 1" → "-C FORWARD")
    # -C does not accept a position number.
    check_cmd="$(echo "$check_cmd" | sed -E 's/(-C [A-Z]+) [0-9]+/\1/')"

    if eval "$check_cmd" 2>/dev/null; then
        echo "  [EXISTS] $1"
        inc EXISTED
    elif eval "$1" 2>/dev/null; then
        echo "  [ADDED]  $1"
        inc ADDED
    else
        echo "  [FAILED] $1"
        inc FAILED
    fi
}

# -----------------------------------------------------------------
# ebtables: idempotent rule insertion.
#
# ebtables-legacy (v2.0.x) does not support -C (check), and the
# output of "ebtables -L" doesn't reliably match input arguments
# (implicit protocol flags, whitespace, option reordering), making
# string-matching fragile.
#
# Instead, we use -D (delete) which accepts the exact same argument
# format as -A/-I. If deletion succeeds, the rule existed and we
# re-add it. If deletion fails, the rule didn't exist and we just
# add it. Either way, exactly one copy of the rule ends up in the
# chain.
# -----------------------------------------------------------------
run_ebtables() {
    local cmd="$1"

    # Build the delete command by swapping -A/-I with -D
    local del_cmd
    del_cmd="$(echo "$cmd" | sed -E 's/^(ebtables\s+)-[AI]/\1-D/')"

    # Also strip any positional index for -I (e.g. "ebtables -I CHAIN 1 ..."
    # → the position is not valid for -D)
    del_cmd="$(echo "$del_cmd" | sed -E 's/(-D\s+\S+)\s+[0-9]+/\1/')"

    if eval "$del_cmd" 2>/dev/null; then
        # Rule existed — re-add it to restore it
        if eval "$cmd" 2>/dev/null; then
            echo "  [EXISTS] $cmd"
            inc EXISTED
        else
            echo "  [FAILED] $cmd (existed but re-add failed)"
            inc FAILED
        fi
    else
        # Rule did not exist — add it fresh
        if eval "$cmd" 2>/dev/null; then
            echo "  [ADDED]  $cmd"
            inc ADDED
        else
            echo "  [FAILED] $cmd"
            inc FAILED
        fi
    fi
}

# -----------------------------------------------------------------
# Helper: normalize ip rule arguments for reliable comparison.
# Strips priority, normalizes table→lookup, collapses whitespace,
# and prepends "from all" when no "from" selector is present
# (since ip rule show always includes it).
# -----------------------------------------------------------------
_normalize_rule_args() {
    local args="$1"

    # Normalize "table" to "lookup" (ip rule show always prints "lookup")
    args="${args//table /lookup }"

    # Strip "priority NNN" (ip rule show prints priority as a line prefix)
    args="$(echo "$args" | sed -E 's/priority [0-9]+//')"

    # Collapse whitespace
    args="$(echo "$args" | tr -s ' ' | sed 's/^ //;s/ $//')"

    # ip rule show always includes "from all" — add it if no "from" clause
    if [[ "$args" != *"from "* ]]; then
        args="from all $args"
    fi

    echo "$args"
}

# -----------------------------------------------------------------
# Helper: count how many rules in "ip rule show" match the
# normalized args. Uses line-by-line normalization of the show
# output so the comparison is apples-to-apples.
# -----------------------------------------------------------------
_count_matching_rules() {
    local family="$1"
    local needle="$2"
    local count=0

    while IFS= read -r line; do
        # Strip the "NNN:\t" priority prefix from ip rule show output
        local body="${line#*:}"
        # Collapse whitespace and trim
        body="$(echo "$body" | tr -s ' ' | sed 's/^ //;s/ $//')"
        if [[ "$body" == "$needle" ]]; then
            (( count++ )) || true
        fi
    done < <(ip $family rule show 2>/dev/null)

    echo "$count"
}

# -----------------------------------------------------------------
# ip rule add: count matches, add if 0, deduplicate if >1
# -----------------------------------------------------------------
run_ip_rule() {
    local cmd="$1"
    local family=""

    # Detect IPv6
    if [[ "$cmd" == *" -6 "* ]]; then
        family="-6"
    fi

    local args="${cmd#ip rule add }"
    args="${args#-6 rule add }"       # handle "ip -6 rule add ..."
    args="${args#ip -6 rule add }"    # redundant safety

    local normalized
    normalized="$(_normalize_rule_args "$args")"

    local count
    count=$(_count_matching_rules "$family" "$normalized")

    if [[ "$count" -eq 0 ]]; then
        if eval "$cmd" 2>/dev/null; then
            echo "  [ADDED]  $cmd"
            inc ADDED
        else
            echo "  [FAILED] $cmd"
            inc FAILED
        fi
    elif [[ "$count" -eq 1 ]]; then
        echo "  [EXISTS] $cmd"
        inc EXISTED
    else
        # Self-heal: delete extras until only 1 remains
        local del_cmd="${cmd/rule add/rule del}"
        local extras=$(( count - 1 ))
        local i
        for (( i = 0; i < extras; i++ )); do
            eval "$del_cmd" 2>/dev/null || true
        done
        echo "  [DEDUP]  $cmd (removed $extras duplicate(s), kept 1)"
        inc EXISTED
    fi
}

# -----------------------------------------------------------------
# ip rule del: count matches, delete only if found
# -----------------------------------------------------------------
run_ip_rule_del() {
    local cmd="$1"
    local family=""

    # Detect IPv6
    if [[ "$cmd" == *" -6 "* ]]; then
        family="-6"
    fi

    local args="${cmd#ip rule del }"
    args="${args#-6 rule del }"
    args="${args#ip -6 rule del }"

    local normalized
    normalized="$(_normalize_rule_args "$args")"

    local count
    count=$(_count_matching_rules "$family" "$normalized")

    if [[ "$count" -eq 0 ]]; then
        echo "  [ABSENT] $cmd"
        inc SKIPPED
    else
        # Delete all copies (there may be duplicates from past bugs)
        local deleted=0
        local i
        for (( i = 0; i < count; i++ )); do
            if eval "$cmd" 2>/dev/null; then
                (( deleted++ )) || true
            fi
        done
        if [[ "$deleted" -gt 1 ]]; then
            echo "  [DELETED] $cmd ($deleted copies removed, including duplicates)"
        else
            echo "  [DELETED] $cmd"
        fi
        inc DELETED
    fi
}

# -----------------------------------------------------------------
# ip route add: try to add, treat "File exists" as already present
# -----------------------------------------------------------------
run_ip_route() {
    local err
    if err=$(eval "$1" 2>&1); then
        echo "  [ADDED]  $1"
        inc ADDED
    elif [[ "$err" == *"File exists"* ]]; then
        echo "  [EXISTS] $1"
        inc EXISTED
    else
        echo "  [FAILED] $1 ($err)"
        inc FAILED
    fi
}

# -----------------------------------------------------------------
# ip route del: try to delete, treat "No such process" as absent
# -----------------------------------------------------------------
run_ip_route_del() {
    local err
    if err=$(eval "$1" 2>&1); then
        echo "  [DELETED] $1"
        inc DELETED
    elif [[ "$err" == *"No such process"* || "$err" == *"No such file"* || "$err" == *"Cannot find device"* ]]; then
        echo "  [ABSENT] $1"
        inc SKIPPED
    else
        echo "  [FAILED] $1 ($err)"
        inc FAILED
    fi
}

# -----------------------------------------------------------------
# route-sync: mirror routes from an interface into a policy
#             routing table. Uses "ip route replace" for idempotency.
#
# Usage:  route-sync <interface> <table> [subnet]
#   If subnet is provided (e.g. 23.191.200.0/24), only routes whose
#   destination falls within that prefix are synced. Routes that
#   exactly match the filter (i.e. the /24 itself) are skipped to
#   avoid clobbering the catchall bridge route in the same table.
# -----------------------------------------------------------------
run_route_sync() {
    local iface="$1"
    local table="$2"
    local filter="${3:-}"
    local synced=0
    local skipped_filter=0
    local failed_sync=0

    # Verify the interface exists
    if ! ip link show dev "$iface" &>/dev/null; then
        echo "  [FAILED] route-sync: interface $iface does not exist (not up yet?)"
        inc FAILED
        return
    fi

    # Verify the table has at least one route
    if ! ip route show table "$table" &>/dev/null; then
        echo "  [FAILED] route-sync: table $table does not exist or is empty"
        inc FAILED
        return
    fi

    if [[ -n "$filter" ]]; then
        echo "  [SYNC]   route-sync $iface -> table $table (filter: $filter)"
    else
        echo "  [SYNC]   route-sync $iface -> table $table (no filter)"
    fi

    # Read all routes on the interface in one pass
    while IFS= read -r route; do
        [[ -z "$route" ]] && continue

        # First field is the prefix (e.g. "23.191.200.2" or "10.10.0.0/24")
        local prefix="${route%% *}"

        # Apply subnet filter if set
        if [[ -n "$filter" ]]; then
            # Skip if prefix exactly matches the filter (don't clobber the catchall)
            if [[ "$prefix" == "$filter" ]]; then
                echo "           [SKIP]   $prefix (same as catchall)"
                (( skipped_filter++ )) || true
                continue
            fi

            # Extract just the IP portion (strip /mask if present)
            local ip_part="${prefix%/*}"

            if ! _ip_in_cidr "$ip_part" "$filter"; then
                echo "           [SKIP]   $prefix (outside $filter)"
                (( skipped_filter++ )) || true
                continue
            fi
        fi

        local err
        if err=$(ip route replace $route dev "$iface" table "$table" 2>&1); then
            echo "           [OK]     $prefix"
            (( synced++ )) || true
        else
            echo "           [FAIL]   $prefix ($err)"
            (( failed_sync++ )) || true
        fi
    done < <(ip route show dev "$iface" 2>/dev/null)

    if [[ "$failed_sync" -gt 0 ]]; then
        echo "  [WARN]   route-sync $iface: $synced synced, $failed_sync failed, $skipped_filter filtered"
        inc FAILED
    elif [[ "$synced" -eq 0 ]]; then
        echo "  [WARN]   route-sync $iface: no matching routes found"
        inc SKIPPED
    else
        echo "  [DONE]   route-sync $iface: $synced routes synced to table $table ($skipped_filter filtered out)"
        inc ADDED
    fi
}

# -----------------------------------------------------------------
# Main: read config, dispatch each line to the right handler
# -----------------------------------------------------------------
echo "=== Custom Routes & Rules ($(date)) ==="
echo "Host: $(hostname)"
echo "Config: $CONF"
echo ""

while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    # Skip blank lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue

    case "$line" in
        iptables\ *)              run_iptables "$line" ;;
        ebtables\ *)              run_ebtables "$line" ;;
        "ip -6 rule add"\ *)     run_ip_rule "$line" ;;
        "ip -6 rule del"\ *)     run_ip_rule_del "$line" ;;
        "ip -6 route add"\ *)    run_ip_route "$line" ;;
        "ip -6 route del"\ *)    run_ip_route_del "$line" ;;
        "ip rule add"\ *)        run_ip_rule "$line" ;;
        "ip rule del"\ *)        run_ip_rule_del "$line" ;;
        "ip route add"\ *)       run_ip_route "$line" ;;
        "ip route del"\ *)       run_ip_route_del "$line" ;;
        ip\ rule\ *)             run_ip_rule "$line" ;;
        ip\ route\ *)            run_ip_route "$line" ;;
        ip\ *)                   run_ip_route "$line" ;;
        route-sync\ *)
            # Parse: route-sync <interface> <table> [subnet]
            read -ra rs_args <<< "$line"
            if [[ ${#rs_args[@]} -lt 3 || ${#rs_args[@]} -gt 4 ]]; then
                echo "  [SKIP]   $line (expected: route-sync <interface> <table> [subnet])"
                inc SKIPPED
            else
                run_route_sync "${rs_args[1]}" "${rs_args[2]}" "${rs_args[3]:-}"
            fi
            ;;
        *)              echo "  [SKIP]   $line" ;;
    esac

done < "$CONF"

echo ""
echo "=== Done: $ADDED added, $DELETED deleted, $EXISTED unchanged, $SKIPPED skipped, $FAILED failed ==="
[[ "$FAILED" -eq 0 ]] || exit 1
