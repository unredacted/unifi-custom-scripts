#!/bin/bash
# ---- Apply Switch CLI Config ----
#
# Reads a hierarchical config file and applies CLI commands to UniFi
# switches remotely via SSH + telnet. Commands are applied idempotently
# when verify directives are present; otherwise they are applied
# unconditionally (safe because repeated CLI commands are no-ops).
#
# Config resolution (first match wins):
#   1. Explicit argument:              $1 (after stripping flags)
#   2. Per-host conf:                  conf/$(hostname).conf
#   3. Flat preferred:                 switch-config.conf
#
# Usage:
#   apply-switch-config.sh [-n|--dry-run] [config-path]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------------------------------------------
# Flags
# -----------------------------------------------------------------
DRY_RUN=false
CONF_ARG=""

for arg in "$@"; do
    case "$arg" in
        -n|--dry-run) DRY_RUN=true ;;
        *)            CONF_ARG="$arg" ;;
    esac
done

# -----------------------------------------------------------------
# Mutual exclusion — prevent concurrent runs from racing
# -----------------------------------------------------------------
FLOCK_FILE="/tmp/apply-switch-config.lock"
exec 9>"$FLOCK_FILE"
if ! flock -w 30 9; then
    echo "[ERROR] Could not acquire lock after 30s — another apply is stuck?"
    exit 1
fi

# -----------------------------------------------------------------
# Config file resolution
# -----------------------------------------------------------------
if [[ -n "$CONF_ARG" ]]; then
    CONF="$CONF_ARG"
elif [[ -f "${SCRIPT_DIR}/conf/$(hostname).conf" ]]; then
    CONF="${SCRIPT_DIR}/conf/$(hostname).conf"
elif [[ -f "${SCRIPT_DIR}/switch-config.conf" ]]; then
    CONF="${SCRIPT_DIR}/switch-config.conf"
else
    echo "[ERROR] No config found for host '$(hostname)'. Looked for:"
    echo "        ${SCRIPT_DIR}/conf/$(hostname).conf"
    echo "        ${SCRIPT_DIR}/switch-config.conf"
    exit 1
fi

# -----------------------------------------------------------------
# Counters
# -----------------------------------------------------------------
APPLIED=0
EXISTS=0
FAILED=0
SKIPPED=0
UNREACHABLE=0

inc() { eval "$1=\$(( $1 + 1 ))"; }

# -----------------------------------------------------------------
# SSH options used for all connections
# -----------------------------------------------------------------
SSH_OPTS=(
    -o ConnectTimeout=10
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=3
)
SSH_TIMEOUT=30

# -----------------------------------------------------------------
# expand_port_list: expand port specs into individual ports
#
# Supports:
#   "0/13"           → "0/13"
#   "0/13-16"        → "0/13 0/14 0/15 0/16"
#   "0/1 0/3-5 0/10" → "0/1 0/3 0/4 0/5 0/10"
# -----------------------------------------------------------------
expand_port_list() {
    local result=()
    for spec in $1; do
        if [[ "$spec" =~ ^([0-9]+)/([0-9]+)-([0-9]+)$ ]]; then
            local slot="${BASH_REMATCH[1]}"
            local start="${BASH_REMATCH[2]}"
            local end="${BASH_REMATCH[3]}"
            for (( p = start; p <= end; p++ )); do
                result+=("${slot}/${p}")
            done
        elif [[ "$spec" =~ ^[0-9]+/[0-9]+$ ]]; then
            result+=("$spec")
        else
            echo "[WARN] Invalid port spec: $spec" >&2
        fi
    done
    echo "${result[*]}"
}

# -----------------------------------------------------------------
# parse_config: read config file into structured data
#
# Populates parallel arrays indexed by switch order:
#   SWITCHES[]                — SSH targets (user@host)
#   SWITCH_IFACE_PORTS[]      — newline-delimited port lists per interface block
#   SWITCH_IFACE_CMDS[]       — newline-delimited commands per interface block
#   SWITCH_GLOBAL_CMDS[]      — newline-delimited global configure commands
#   SWITCH_VERIFIES[]         — newline-delimited "port|show-cmd|field|expected" tuples
#
# Each switch can have multiple interface blocks; they are stored as
# pipe-separated groups within the array entries.
# -----------------------------------------------------------------
declare -a SWITCHES=()
declare -a SWITCH_IFACE_DATA=()    # "port1 port2|cmd1\ncmd2;;port3|cmd3"
declare -a SWITCH_GLOBAL_CMDS=()
declare -a SWITCH_VERIFIES=()

parse_config() {
    local conf="$1"
    local current_switch=-1
    local in_interface=false
    local current_ports=""
    local current_cmds=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Preserve original for error messages
        local orig="$line"

        # Check if line is indented (belongs to current switch block)
        local is_indented=false
        if [[ "$line" =~ ^[[:space:]] ]]; then
            is_indented=true
        fi

        # Strip leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Skip blank lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$is_indented" == false ]]; then
            # Top-level directive — must be "switch"
            if [[ "$line" == switch\ * ]]; then
                # Flush any pending interface block
                if [[ "$in_interface" == true && "$current_switch" -ge 0 ]]; then
                    _flush_interface_block
                fi

                local target="${line#switch }"
                target="${target#"${target%%[![:space:]]*}"}"
                SWITCHES+=("$target")
                SWITCH_IFACE_DATA+=("")
                SWITCH_GLOBAL_CMDS+=("")
                SWITCH_VERIFIES+=("")
                current_switch=$(( ${#SWITCHES[@]} - 1 ))
                in_interface=false
            else
                echo "  [SKIP] Unrecognized top-level directive: $orig"
                inc SKIPPED
            fi
        elif [[ "$current_switch" -ge 0 ]]; then
            # Indented line — belongs to current switch
            if [[ "$line" == interface\ * ]]; then
                # Flush previous interface block if any
                if [[ "$in_interface" == true ]]; then
                    _flush_interface_block
                fi

                local port_spec="${line#interface }"
                current_ports="$(expand_port_list "$port_spec")"
                current_cmds=""
                in_interface=true

            elif [[ "$line" == configure\ * ]]; then
                # Flush interface block if we were in one
                if [[ "$in_interface" == true ]]; then
                    _flush_interface_block
                fi
                in_interface=false

                local gcmd="${line#configure }"
                if [[ -n "${SWITCH_GLOBAL_CMDS[$current_switch]}" ]]; then
                    SWITCH_GLOBAL_CMDS[$current_switch]+=$'\n'"$gcmd"
                else
                    SWITCH_GLOBAL_CMDS[$current_switch]="$gcmd"
                fi

            elif [[ "$line" == verify\ * ]]; then
                # Flush interface block if we were in one
                if [[ "$in_interface" == true ]]; then
                    _flush_interface_block
                fi
                in_interface=false

                # Parse: verify <port> <show-command...> <field> <expected>
                # We split from the right: last word is expected, second-to-last is field,
                # first word after "verify" is port, everything in between is the show command.
                local vargs="${line#verify }"
                local vport="${vargs%% *}"
                vargs="${vargs#* }"

                # Expected value is the last word
                local expected="${vargs##* }"
                vargs="${vargs% *}"

                # Field is the new last word
                local field="${vargs##* }"
                vargs="${vargs% *}"

                # Remaining is the show command
                local show_cmd="$vargs"

                local entry="${vport}|${show_cmd}|${field}|${expected}"
                if [[ -n "${SWITCH_VERIFIES[$current_switch]}" ]]; then
                    SWITCH_VERIFIES[$current_switch]+=$'\n'"$entry"
                else
                    SWITCH_VERIFIES[$current_switch]="$entry"
                fi

            elif [[ "$in_interface" == true ]]; then
                # Command within an interface block
                if [[ -n "$current_cmds" ]]; then
                    current_cmds+=$'\n'"$line"
                else
                    current_cmds="$line"
                fi
            else
                echo "  [SKIP] Unrecognized indented directive: $orig"
                inc SKIPPED
            fi
        fi
    done < "$conf"

    # Flush final interface block
    if [[ "$in_interface" == true && "$current_switch" -ge 0 ]]; then
        _flush_interface_block
    fi
}

_flush_interface_block() {
    if [[ -z "$current_ports" || -z "$current_cmds" ]]; then
        return
    fi
    # Append as a ";;" delimited group: "ports|cmds"
    local block="${current_ports}|${current_cmds}"
    if [[ -n "${SWITCH_IFACE_DATA[$current_switch]}" ]]; then
        SWITCH_IFACE_DATA[$current_switch]+=";;${block}"
    else
        SWITCH_IFACE_DATA[$current_switch]="$block"
    fi
    current_ports=""
    current_cmds=""
    in_interface=false
}

# -----------------------------------------------------------------
# run_ssh: execute a command on a switch via SSH
# Returns: 0 on success, 1 on failure
# Captures output in RUN_SSH_OUTPUT
# -----------------------------------------------------------------
RUN_SSH_OUTPUT=""

run_ssh() {
    local switch="$1"
    local remote_cmd="$2"

    if $DRY_RUN; then
        echo "  [DRY-RUN] ssh ${switch} '${remote_cmd}'"
        RUN_SSH_OUTPUT=""
        return 0
    fi

    local err
    if RUN_SSH_OUTPUT=$(timeout "$SSH_TIMEOUT" ssh "${SSH_OPTS[@]}" "$switch" "$remote_cmd" 2>&1); then
        return 0
    else
        local rc=$?
        if [[ $rc -eq 124 ]]; then
            RUN_SSH_OUTPUT="Connection timed out"
        elif [[ $rc -eq 255 ]]; then
            # SSH connection error — extract useful message
            RUN_SSH_OUTPUT="${RUN_SSH_OUTPUT:-SSH connection failed}"
        fi
        return 1
    fi
}

# -----------------------------------------------------------------
# build_telnet_session: construct echo commands for telnet CLI
#
# Arguments:
#   $1 — switch index in SWITCHES[]
#   $2 — if "verify-only", only build show commands (no config changes)
#   $3 — if set, space-separated list of ports to restrict to
#
# Outputs the full command string to pipe into telnet.
# -----------------------------------------------------------------
build_telnet_session() {
    local idx="$1"
    local mode="${2:-apply}"
    local restrict_ports="${3:-}"
    local cmds=""

    _add() { cmds+="echo ${1}; "; }

    if [[ "$mode" == "verify-only" ]]; then
        # Build verify-only session (show commands with markers)
        _add "enable"
        local verifies="${SWITCH_VERIFIES[$idx]}"
        while IFS= read -r vline; do
            [[ -z "$vline" ]] && continue
            local vport="${vline%%|*}"
            local rest="${vline#*|}"
            local show_cmd="${rest%%|*}"
            _add "\"===MARKER_${vport}_START===\""
            _add "\"${show_cmd}\""
            _add "\"===MARKER_${vport}_END===\""
        done <<< "$verifies"
        cmds+="sleep 1"
        echo "$cmds"
        return
    fi

    # Build apply session
    _add "enable"
    _add "configure"

    # Interface commands
    local iface_data="${SWITCH_IFACE_DATA[$idx]}"
    if [[ -n "$iface_data" ]]; then
        # Split by ";;" into blocks
        local IFS_SAVE="$IFS"
        local blocks
        IFS='@' read -ra blocks <<< "${iface_data//;;/@}"
        IFS="$IFS_SAVE"

        for block in "${blocks[@]}"; do
            [[ -z "$block" ]] && continue
            local ports="${block%%|*}"
            local block_cmds="${block#*|}"

            for port in $ports; do
                # If restrict_ports is set, skip ports not in the list
                if [[ -n "$restrict_ports" ]]; then
                    local found=false
                    for rp in $restrict_ports; do
                        if [[ "$rp" == "$port" ]]; then
                            found=true
                            break
                        fi
                    done
                    $found || continue
                fi

                _add "\"interface ${port}\""
                while IFS= read -r cmd; do
                    [[ -z "$cmd" ]] && continue
                    _add "\"${cmd}\""
                done <<< "$block_cmds"
                _add "exit"
            done
        done
    fi

    # Global configure commands
    local global_cmds="${SWITCH_GLOBAL_CMDS[$idx]}"
    if [[ -n "$global_cmds" ]]; then
        while IFS= read -r gcmd; do
            [[ -z "$gcmd" ]] && continue
            _add "\"${gcmd}\""
        done <<< "$global_cmds"
    fi

    _add "exit"     # exit configure
    _add "exit"     # exit enable
    cmds+="sleep 1"
    echo "$cmds"
}

# -----------------------------------------------------------------
# parse_verify_field: extract a field value from telnet verify output
#
# Looks between MARKER_<port>_START and MARKER_<port>_END for a line
# containing <field>, and returns the word immediately after it.
# -----------------------------------------------------------------
parse_verify_field() {
    local output="$1"
    local port="$2"
    local field="$3"

    local in_section=false
    while IFS= read -r line; do
        if [[ "$line" == *"===MARKER_${port}_START==="* ]]; then
            in_section=true
            continue
        fi
        if [[ "$line" == *"===MARKER_${port}_END==="* ]]; then
            break
        fi
        if $in_section; then
            # Look for the field name in this line
            if [[ "$line" == *"$field"* ]]; then
                # Extract the word after the field name
                # Handle both "Field  Value" table format and "Field: Value" format
                local after="${line##*$field}"
                after="${after#"${after%%[![:space:]]*}"}"  # strip leading whitespace
                after="${after%%[[:space:]]*}"              # take first word
                after="${after#:}"                          # strip leading colon
                after="${after#"${after%%[![:space:]]*}"}"  # strip whitespace after colon
                if [[ -z "$after" ]]; then
                    # Try next non-empty word if the field consumed the rest
                    after="${line##*$field}"
                    after="$(echo "$after" | awk '{print $1}')"
                fi
                echo "$after"
                return 0
            fi
        fi
    done <<< "$output"

    return 1
}

# -----------------------------------------------------------------
# get_all_iface_ports: get all ports from a switch's interface data
# -----------------------------------------------------------------
get_all_iface_ports() {
    local idx="$1"
    local iface_data="${SWITCH_IFACE_DATA[$idx]}"
    local all_ports=""

    [[ -z "$iface_data" ]] && return

    local IFS_SAVE="$IFS"
    local blocks
    IFS='@' read -ra blocks <<< "${iface_data//;;/@}"
    IFS="$IFS_SAVE"

    for block in "${blocks[@]}"; do
        [[ -z "$block" ]] && continue
        local ports="${block%%|*}"
        if [[ -n "$all_ports" ]]; then
            all_ports+=" $ports"
        else
            all_ports="$ports"
        fi
    done
    echo "$all_ports"
}

# -----------------------------------------------------------------
# get_iface_cmd_desc: get a description of commands for a port
# -----------------------------------------------------------------
get_iface_cmd_desc() {
    local idx="$1"
    local target_port="$2"
    local iface_data="${SWITCH_IFACE_DATA[$idx]}"

    [[ -z "$iface_data" ]] && return

    local IFS_SAVE="$IFS"
    local blocks
    IFS='@' read -ra blocks <<< "${iface_data//;;/@}"
    IFS="$IFS_SAVE"

    for block in "${blocks[@]}"; do
        [[ -z "$block" ]] && continue
        local ports="${block%%|*}"
        for port in $ports; do
            if [[ "$port" == "$target_port" ]]; then
                local block_cmds="${block#*|}"
                # Return first command as description
                echo "${block_cmds%%$'\n'*}"
                return
            fi
        done
    done
}

# -----------------------------------------------------------------
# run_switch: orchestrate apply for a single switch
# -----------------------------------------------------------------
run_switch() {
    local idx="$1"
    local switch="${SWITCHES[$idx]}"

    echo ""
    echo "--- ${switch} ---"

    # Collect all ports
    local all_ports
    all_ports="$(get_all_iface_ports "$idx")"

    local verifies="${SWITCH_VERIFIES[$idx]}"
    local has_verifies=false
    [[ -n "$verifies" ]] && has_verifies=true

    # Step 1: Pre-check with verify commands (if any)
    local needs_apply_ports=""
    local already_ok_ports=""

    if $has_verifies; then
        local verify_session
        verify_session="$(build_telnet_session "$idx" "verify-only")"
        local verify_cmd="(${verify_session}) | telnet 127.0.0.1 23 2>/dev/null"

        if ! run_ssh "$switch" "$verify_cmd"; then
            echo "  [UNREACHABLE] ${switch} (${RUN_SSH_OUTPUT})"
            inc UNREACHABLE
            return
        fi

        local verify_output="$RUN_SSH_OUTPUT"

        # Check each verify directive
        while IFS= read -r vline; do
            [[ -z "$vline" ]] && continue
            local vport="${vline%%|*}"
            local rest="${vline#*|}"
            local show_cmd="${rest%%|*}"
            rest="${rest#*|}"
            local field="${rest%%|*}"
            local expected="${rest#*|}"

            local current_val
            if current_val=$(parse_verify_field "$verify_output" "$vport" "$field"); then
                if [[ "$current_val" == "$expected" ]]; then
                    local cmd_desc
                    cmd_desc="$(get_iface_cmd_desc "$idx" "$vport")"
                    echo "  [EXISTS]  interface ${vport}: ${cmd_desc:-configured} (${field}: ${current_val})"
                    inc EXISTS
                    already_ok_ports+=" $vport"
                else
                    needs_apply_ports+=" $vport"
                fi
            else
                echo "  [WARN]    Could not parse verify output for port ${vport} (field: ${field})"
                needs_apply_ports+=" $vport"
            fi
        done <<< "$verifies"

        # For ports with interface commands but no verify, apply unconditionally
        for port in $all_ports; do
            local has_verify=false
            while IFS= read -r vline; do
                [[ -z "$vline" ]] && continue
                local vport="${vline%%|*}"
                if [[ "$vport" == "$port" ]]; then
                    has_verify=true
                    break
                fi
            done <<< "$verifies"

            if ! $has_verify; then
                # Check it's not already in either list
                local in_list=false
                for p in $needs_apply_ports $already_ok_ports; do
                    [[ "$p" == "$port" ]] && in_list=true
                done
                $in_list || needs_apply_ports+=" $port"
            fi
        done
    else
        # No verify directives — apply all ports unconditionally
        needs_apply_ports="$all_ports"

        # Quick SSH connectivity check
        if ! $DRY_RUN; then
            if ! timeout "$SSH_TIMEOUT" ssh "${SSH_OPTS[@]}" "$switch" "echo ok" >/dev/null 2>&1; then
                echo "  [UNREACHABLE] ${switch} (SSH connection failed)"
                inc UNREACHABLE
                return
            fi
        fi
    fi

    # Trim whitespace
    needs_apply_ports="${needs_apply_ports#"${needs_apply_ports%%[![:space:]]*}"}"

    # Step 2: Apply changes
    local has_global_cmds=false
    [[ -n "${SWITCH_GLOBAL_CMDS[$idx]}" ]] && has_global_cmds=true

    if [[ -z "$needs_apply_ports" ]] && ! $has_global_cmds; then
        return
    fi

    local apply_session
    apply_session="$(build_telnet_session "$idx" "apply" "$needs_apply_ports")"
    local apply_cmd="(${apply_session}) | telnet 127.0.0.1 23 2>/dev/null"

    if ! run_ssh "$switch" "$apply_cmd"; then
        echo "  [FAILED]  ${switch}: could not apply changes (${RUN_SSH_OUTPUT})"
        inc FAILED
        return
    fi

    # Report applied ports
    for port in $needs_apply_ports; do
        local cmd_desc
        cmd_desc="$(get_iface_cmd_desc "$idx" "$port")"
        echo "  [APPLIED] interface ${port}: ${cmd_desc:-configured}"
        inc APPLIED
    done

    # Report global commands
    if $has_global_cmds; then
        while IFS= read -r gcmd; do
            [[ -z "$gcmd" ]] && continue
            echo "  [APPLIED] configure: ${gcmd}"
            inc APPLIED
        done <<< "${SWITCH_GLOBAL_CMDS[$idx]}"
    fi

    # Step 3: Post-verify (if verify directives exist)
    if $has_verifies && [[ -n "$needs_apply_ports" ]] && ! $DRY_RUN; then
        local verify_session
        verify_session="$(build_telnet_session "$idx" "verify-only")"
        local verify_cmd="(${verify_session}) | telnet 127.0.0.1 23 2>/dev/null"

        if run_ssh "$switch" "$verify_cmd"; then
            local verify_output="$RUN_SSH_OUTPUT"
            local verified=0
            local verify_failed=0

            while IFS= read -r vline; do
                [[ -z "$vline" ]] && continue
                local vport="${vline%%|*}"

                # Only verify ports we just applied
                local was_applied=false
                for p in $needs_apply_ports; do
                    [[ "$p" == "$vport" ]] && was_applied=true
                done
                $was_applied || continue

                local rest="${vline#*|}"
                local show_cmd="${rest%%|*}"
                rest="${rest#*|}"
                local field="${rest%%|*}"
                local expected="${rest#*|}"

                local current_val
                if current_val=$(parse_verify_field "$verify_output" "$vport" "$field"); then
                    if [[ "$current_val" == "$expected" ]]; then
                        (( verified++ )) || true
                    else
                        echo "  [WARN]    interface ${vport}: ${field} is ${current_val}, expected ${expected}"
                        (( verify_failed++ )) || true
                    fi
                else
                    echo "  [WARN]    Could not parse post-verify for port ${vport}"
                    (( verify_failed++ )) || true
                fi
            done <<< "$verifies"

            if [[ "$verify_failed" -eq 0 && "$verified" -gt 0 ]]; then
                echo "  [VERIFY]  ${verified} port(s) confirmed"
            elif [[ "$verify_failed" -gt 0 ]]; then
                echo "  [VERIFY]  ${verified} confirmed, ${verify_failed} failed post-check"
            fi
        fi
    fi
}

# -----------------------------------------------------------------
# Main
# -----------------------------------------------------------------
echo "=== Switch CLI Config ($(date)) ==="
echo "Host: $(hostname)"
echo "Config: $CONF"
$DRY_RUN && echo "Mode: DRY RUN"

parse_config "$CONF"

if [[ ${#SWITCHES[@]} -eq 0 ]]; then
    echo ""
    echo "No switches found in config."
    exit 0
fi

for (( i = 0; i < ${#SWITCHES[@]}; i++ )); do
    run_switch "$i"
done

echo ""
echo "=== Done: $APPLIED applied, $FAILED failed, $EXISTS unchanged, $SKIPPED skipped, $UNREACHABLE unreachable ==="
[[ "$FAILED" -eq 0 ]] || exit 1
