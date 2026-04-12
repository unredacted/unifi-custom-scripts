# unifi-scripts

A collection of custom scripts for UniFi OS gateways. Each subdirectory is a self-contained tool with its own config and documentation.

## Scripts

### rules/ — Network rule injection and monitoring

Applies iptables, ebtables, ip rule, ip route, sysctl, and route-sync directives idempotently from a config file. A companion daemon monitors for kernel events that indicate rules were flushed (e.g., UBIOS provisioning cycles) and re-applies them automatically.

**The problem:** UniFi OS periodically re-provisions the network stack, which flushes custom iptables rules, policy routes, routing table entries, and kernel tunables. These scripts solve that by applying rules idempotently and monitoring for flushes to restore them.

#### Directory layout

```
rules/
  inject-rules.sh      # Rule injection engine
  rules-monitor.sh     # Background daemon that watches for flushes
  conf/
    example.conf       # Template config with directive reference
    <hostname>.conf    # Per-device config (git-ignored)
```

#### Configuration

The scripts resolve config files in this order (first match wins):

1. Explicit path passed as `$1`
2. `conf/$(hostname).conf`
3. `inject-rules.conf` (flat file, legacy)
4. `custom-routes.conf` (flat file, legacy)

Per-host configs under `conf/` are git-ignored. Copy `conf/example.conf` to `conf/<hostname>.conf` and edit it for each device.

##### Supported directives

| Directive | Idempotency mechanism |
|---|---|
| `iptables <args>` | Swaps `-I`/`-A` to `-C` to check before inserting |
| `ebtables <args>` | Deletes with `-D` then re-adds (ebtables lacks `-C`) |
| `ip rule add <args>` | Counts matching rules; skips if 1 exists, deduplicates if >1 |
| `ip rule del <args>` | Deletes all copies if present, no-op if absent |
| `ip route add <args>` | Adds; treats "File exists" as success |
| `ip route del <args>` | Deletes; treats "No such process" as already absent |
| `ip -6 rule add\|del <args>` | Same as IPv4 variants |
| `ip -6 route add\|del <args>` | Same as IPv4 variants |
| `sysctl -w <key>=<value>` | Reads `/proc/sys`; writes only if value differs. `-w` is optional. |
| `route-sync <iface> <table> [subnet]` | Mirrors routes from an interface into a routing table using `ip route replace`. Optional CIDR filter. |

Lines starting with `#` and blank lines are ignored. See `conf/example.conf` for the full directive reference and more examples.

##### Example config

```sh
# Policy routing — send a prefix to a custom table
ip rule add to 192.0.2.0/24 lookup 100 priority 100
ip route add 192.0.2.0/24 dev br100 table 100

# Sync host routes from a tunnel into that table
route-sync vti64 100 192.0.2.0/24

# NAT bypass for tunnel traffic
iptables -t nat -I POSTROUTING -d 192.0.2.0/24 -j RETURN

# Block discovery broadcasts on a peering bridge
iptables -I OUTPUT -o br3998 -p udp --dport 10001 -j DROP

# Block STP BPDUs at layer 2
ebtables -A OUTPUT -o br3998 -d 01:80:c2:00:00:00/ff:ff:ff:ff:ff:f0 -j DROP

# Extend ARP/NDP reachable time on a peering bridge (4 hours)
sysctl -w net.ipv4.neigh.br3998.base_reachable_time_ms=14400000
sysctl -w net.ipv6.neigh.br3998.base_reachable_time_ms=14400000
```

#### Usage

**Injecting rules:**

```sh
# Uses conf/$(hostname).conf automatically
./rules/inject-rules.sh

# Or specify a config explicitly
./rules/inject-rules.sh /path/to/custom.conf
```

The script exits non-zero if any directive fails. A file lock (`/var/run/inject-rules.lock`) prevents concurrent runs from racing.

**Starting the monitor:**

```sh
./rules/rules-monitor.sh
```

The monitor backgrounds itself and writes its PID to `/var/run/rules-monitor.pid`. It kills any existing instance on startup. Logs go to `/var/log/rules-monitor.log`.

What it watches depends on what's in the config:

- **Route/route-sync directives**: `ip monitor route`, filtered to referenced interfaces and tables.
- **ip rule directives**: `ip monitor rule` for policy rule flushes.
- **iptables/ebtables directives**: polls every 10 seconds, checking whether a sample rule still exists.
- **sysctl directives**: polls every 10 seconds, checking whether the first sysctl value still matches.

When a relevant event fires, the monitor debounces for 5 seconds of silence (to let UBIOS finish provisioning), then runs `inject-rules.sh`. A 10-second cooldown after each inject suppresses self-triggered events.

#### Integration with on-boot scripts

Both scripts are typically called from a UniFi on-boot setup script:

```sh
/path/to/rules/inject-rules.sh
/path/to/rules/rules-monitor.sh
```

### switch-config/ -- Remote switch CLI configuration

Applies CLI commands to UniFi switches remotely via SSH + telnet. Options not exposed in the controller UI (e.g., disabling LLDP transmit on IXP ports) are applied idempotently and re-applied periodically since they do not persist across switch reboots.

#### Directory layout

```
switch-config/
  apply-switch-config.sh      # CLI injection engine (runs from management host)
  switch-config-monitor.sh    # Background daemon for periodic re-application
  conf/
    example.conf              # Template config with directive reference
    <hostname>.conf           # Per-runner-host config (git-ignored)
```

#### Configuration

The scripts resolve config files using the **runner's** hostname (the machine that SSHes into switches), not the switch hostname. Resolution order (first match wins):

1. Explicit path passed as `$1`
2. `conf/$(hostname).conf`
3. `switch-config.conf` (flat file)

Per-host configs under `conf/` are git-ignored. Copy `conf/example.conf` to `conf/<hostname>.conf` and edit it for each runner host.

##### Syntax

```sh
# Target switch via SSH (key auth must be pre-configured)
switch admin@switch1.example.net

  # Disable LLDP on IXP ports (range expands to 0/25 0/26 0/27 0/28)
  interface 0/25-28
    no lldp transmit

  # Optional: verify state before/after applying
  verify 0/28 show lldp interface 0/28  Transmit  Disabled
```

| Directive | Description |
|---|---|
| `switch <user@host>` | Begins a switch block. All indented lines below belong to it. |
| `interface <port-list>` | Enter interface context. Ports can be single (`0/13`), space-separated (`0/1 0/2`), ranges (`0/13-16`), or mixed (`0/1 0/3-5`). |
| (indented command) | CLI command run inside the interface context (e.g., `no lldp transmit`). |
| `configure <command>` | Global configure-mode command (not interface-scoped). |
| `verify <port> <show-cmd> <field> <expected>` | Pre/post check. If current value matches `<expected>`, the port is skipped. |

Lines starting with `#` and blank lines are ignored. See `conf/example.conf` for the full directive reference and more examples.

##### Example config

```sh
# Disable LLDP transmit on IXP-facing ports
switch admin@switch1.example.net
  interface 0/25-28
    no lldp transmit
  verify 0/28 show lldp interface 0/28  Transmit  Disabled

# Multiple commands per interface
switch admin@switch2.example.net
  interface 0/1 0/2
    no lldp transmit
    no cdp enable
```

#### Usage

**Applying switch config:**

```sh
# Uses conf/$(hostname).conf automatically
./switch-config/apply-switch-config.sh

# Specify a config explicitly
./switch-config/apply-switch-config.sh /path/to/custom.conf

# Dry run — show what would be applied without SSHing
./switch-config/apply-switch-config.sh -n
```

The script exits non-zero if any directive fails. A file lock (`/tmp/apply-switch-config.lock`) prevents concurrent runs.

**Starting the monitor daemon:**

```sh
# Default interval: 30 seconds
./switch-config/switch-config-monitor.sh

# Custom interval: 60 seconds
./switch-config/switch-config-monitor.sh 60

# Or via environment variable
INTERVAL=60 ./switch-config/switch-config-monitor.sh
```

The monitor backgrounds itself and writes its PID to `/var/run/switch-config-monitor.pid`. It kills any existing instance on startup. Logs go to `/var/log/switch-config-monitor.log`.

#### Integration with on-boot scripts

Both scripts are typically called from a UniFi on-boot setup script:

```sh
/path/to/switch-config/apply-switch-config.sh
/path/to/switch-config/switch-config-monitor.sh
```

#### Requirements

- Bash 4+ (for associative arrays; UniFi gateways have bash 5.x)
- SSH key authentication pre-configured to target switches
- The runner machine must be able to reach switches via SSH

## License

GPLv3. See [LICENSE](LICENSE).
