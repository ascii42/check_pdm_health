# check_pdm_health

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Monitoring](https://img.shields.io/badge/Monitoring-Icinga%2FNagios-blue.svg)](https://icinga.com/)
[![Version](https://img.shields.io/badge/version-1.6.0-orange.svg)](CHANGELOG.md)

A comprehensive Bash-based monitoring plugin for Proxmox Datacenter Manager (PDM), compatible with Icinga and Nagios monitoring systems. This plugin monitors the PDM node itself, all connected remote PVE/PBS clusters, virtual machines, containers, subscriptions, updates, task logs, and certificates — directly via the PDM REST API. No agent or additional software required on the PDM host.

## Features

- **Direct API Access**: Connects to the PDM REST API (`https://<host>:8443/api2/json/`) — no agent, no SSH required
- **Remote Cluster Monitoring**: Discovers all connected PVE/PBS remotes and checks connectivity, node online/offline state, and per-node CPU/memory/uptime
- **Aggregated Resource Overview**: Combined VM, container, storage, SDN zone, and PBS node status across all connected remotes
- **Guest Monitoring**: QEMU VM and LXC container status with CPU%, memory%, disk% thresholds — filterable by remote
- **Update Awareness**: Package updates on the PDM node and pending updates on all remote nodes (requires Administrator-role token or password auth)
- **Subscription Checks**: PDM local subscription expiry + subscription state on all connected remotes
- **Certificate Expiry**: TLS certificate days-remaining with configurable warn/crit thresholds
- **Task Log Watch**: PDM local task history and aggregated remote task error/warning counts
- **Flexible Authentication**: API token (recommended) or username/password; PVE-style `=` separator auto-normalised to PDM's `:` separator
- **Token Auth Awareness**: Gracefully degrades when API token cannot access node-level endpoints (PDM design restriction); clearly reports what is and is not checked
- **Opt-in Checks**: Use `-eX` flags to run only the modules you need, or `-A` for everything
- **Opt-out Suppression**: `--disable-X` flags to skip individual modules when using `-A`
- **Granular Thresholds**: Per-metric warn/crit for CPU, memory, swap, load, time drift, subscription expiry, certificate expiry, update counts, task counts, and more
- **Blacklisting**: Skip specific remotes, VMs, containers, or network interfaces
- **Perfdata Output**: Full Nagios-compatible perfdata for all modules — works with PNP4Nagios, Graphite, InfluxDB, etc.
- **Verbose & Silent Modes**: Tunable output verbosity for dashboards and alert notifications

## Prerequisites

Ensure the following tools are installed on your monitoring server:

- **bash** (4.0 or higher — requires associative arrays)
- **curl** (for API communication)
- **jq** (for JSON parsing)
- **awk** (for text processing)

### Installation on Different Platforms

**Ubuntu/Debian:**
```bash
sudo apt-get update && sudo apt-get install curl jq gawk
```

**RHEL/CentOS/Rocky Linux:**
```bash
sudo dnf install curl jq gawk
```

**Gentoo:**
```bash
sudo emerge net-misc/curl app-misc/jq sys-apps/gawk
```

## Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/ascii42/check_pdm_health.git
   cd check_pdm_health
   ```

2. **Make the script executable:**
   ```bash
   chmod +x check_pdm_health.sh
   ```

3. **Copy to your monitoring plugins directory:**
   ```bash
   # For Icinga2
   sudo cp check_pdm_health.sh /usr/lib/nagios/plugins/

   # For Nagios
   sudo cp check_pdm_health.sh /usr/local/nagios/libexec/
   ```

## PDM API Token Setup

Create a dedicated API token in the PDM UI:

1. **Administration -> Access Control -> API Tokens -> Add**
2. User: `root@pdm` (PDM-native user) or `root@pam` (Linux superuser)
3. Token ID: `monitoring`
4. Copy the generated secret immediately — it is shown only once

Then grant the token user a role in the PDM permissions:

1. **Administration -> Access Control -> Permissions -> Add**
2. User/Token: the token you just created
3. Role: `Auditor` (read-only) or `Administrator`

The token format used with `-T` is:
```
USER@REALM!TOKENID:SECRET
```
Example:
```
root@pdm!monitoring:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

> **Note:** Always wrap the token in single quotes on the command line — bash history expansion treats `!` specially in double quotes.

> **Note:** PDM uses a **colon** (`:`) as separator between token ID and secret, unlike PVE which uses `=`. The plugin accepts both formats and auto-normalises `=` to `:`.

### Token Permission Levels

PDM enforces strict API token restrictions regardless of role assignment:

| Endpoint | Auditor token | Administrator token | Password auth |
|---|---|---|---|
| Remote connections, resources, VMs, containers | works | works | works |
| `/remotes/updates/summary` (remote updates) | blocked | works | works |
| `/nodes/*` (PDM node checks: Sys/Time/DNS/Net/Sub/Certs/Tasks) | blocked | blocked | works |

**Recommendation:** For full coverage, use password auth (`-U root@pam -P ...`). For token-based monitoring, use an Administrator-role token to gain remote update visibility; node-level checks will remain unavailable but the plugin clearly marks them as such with a single `[UNKNOWN]` notice rather than producing false results.

## Usage

### Basic Syntax

```bash
./check_pdm_health.sh [-h] [-V] -H <host> { -T <token> | -U <user> -P <pass> } [options] [-eX ...]
```

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `-H, --host <hostname\|IP>` | Hostname or IP address of the PDM node |
| `-T, --token <token>` | API token — full format: `USER@REALM!TOKENID:SECRET` |
| `-U, --username <user@realm>` | Username for password authentication |
| `-P, --password <password>` | Password for username/password authentication |

### Enable Flags (opt-in)

At least one `-eX` flag is required. Use `-A` to run all standard checks.

| Flag | Long form | Description |
|------|-----------|-------------|
| `-eSys` | `--enable-sys` | PDM node system resources: CPU%, memory%, swap%, load average, IOWait%, uptime |
| `-eTime` | `--enable-time` | PDM node system time: timezone and drift vs. monitoring host |
| `-eDNS` | `--enable-dns` | PDM node DNS server configuration and search domain |
| `-eNet` | `--enable-net` | PDM node network interfaces: link state |
| `-eRemotes` | `--enable-remotes` | Remote PVE/PBS connectivity; per-node CPU/memory/uptime in verbose; CRIT on offline nodes |
| `-eResources` | `--enable-resources` | Aggregated resource overview: PVE nodes, VMs, containers, storage, SDN zones, PBS nodes |
| `-eVM` | `--enable-vm` | QEMU VM status across all remotes; CPU/memory thresholds; filter by `--vm` or `--remote` |
| `-eCT` | `--enable-ct` | LXC container status across all remotes; CPU/memory thresholds; filter by `--ct` or `--remote` |
| `-eSub` | `--enable-sub` | Subscription status: PDM local subscription + all remote subscriptions |
| `-eUpdates` | `--enable-updates` | Package updates on PDM node + pending updates on all connected remote nodes |
| `-eTasks` | `--enable-tasks` | PDM task log + aggregated remote task statistics — **not included in `-A`** |
| `-eCerts` | `--enable-certs` | PDM TLS certificate expiry |
| `-A, -eAll` | `--enable-all` | Enable all standard checks (excludes `-eTasks`) |

> **Note:** `-eSys`, `-eTime`, `-eDNS`, `-eNet`, `-eSub`, `-eTasks`, and `-eCerts` require access to `/nodes/*`. API tokens cannot access this endpoint (PDM design restriction). These checks show `[UNKNOWN]` with token auth; use password auth for full coverage.

### Disable Flags (opt-out)

Suppress individual modules when running with `-A`:

```
--disable-sys        --disable-time       --disable-dns
--disable-net        --disable-remotes    --disable-resources
--disable-vm         --disable-ct         --disable-sub
--disable-updates    --disable-certs
```

### Threshold Options

Percentage values accept an optional trailing `%` (e.g. `80` and `80%` are equivalent).

| Option | Default | Description |
|--------|---------|-------------|
| `-wCPU, --warn-cpu <pct>` | 80 | Node/remote CPU warn % |
| `-cCPU, --crit-cpu <pct>` | 95 | Node/remote CPU crit % |
| `-wMem, --warn-mem <pct>` | 80 | Node/remote memory warn % |
| `-cMem, --crit-mem <pct>` | 95 | Node/remote memory crit % |
| `--warn-swap <pct>` | 20 | Swap usage warn % |
| `--crit-swap <pct>` | 50 | Swap usage crit % |
| `--warn-load <n>` | disabled | Load average warn (per-CPU) |
| `--crit-load <n>` | disabled | Load average crit (per-CPU) |
| `--warn-sub-days <days>` | 30 | Subscription expiry warn days |
| `--crit-sub-days <days>` | 14 | Subscription expiry crit days |
| `--warn-updates <n>` | 1 | Available update count warn |
| `--crit-updates <n>` | 1 | Security update count crit (PDM node only) |
| `--warn-tasks <n>` | 1 | Task warning count warn threshold |
| `--crit-tasks <n>` | 1 | Task failure count crit threshold |
| `--taskcheck-time <dur>` | 1h | Task log look-back window (supports `Nm`, `Nh`, `Nd`) |
| `--warn-cert <days>` | 30 | Certificate expiry warn days |
| `--crit-cert <days>` | 14 | Certificate expiry crit days |
| `--warn-failed-remotes <n>` | 1 | Failed remote WARN count |
| `--crit-failed-remotes <n>` | 1 | Failed remote CRIT count |
| `--warn-time-drift <sec>` | 60 | Time drift warn seconds |
| `--crit-time-drift <sec>` | 300 | Time drift crit seconds |
| `--warn-guest-cpu <pct>` | = `--warn-cpu` | VM/CT CPU warn % |
| `--crit-guest-cpu <pct>` | = `--crit-cpu` | VM/CT CPU crit % |
| `--warn-guest-mem <pct>` | = `--warn-mem` | VM/CT memory warn % |
| `--crit-guest-mem <pct>` | = `--crit-mem` | VM/CT memory crit % |

### Filter & Behaviour Options

| Option | Description |
|--------|-------------|
| `--remote <id>` | Restrict `-eVM` / `-eCT` checks to a specific remote |
| `--vm <vmid\|name>` | Restrict `-eVM` to a single VM |
| `--ct <vmid\|name>` | Restrict `-eCT` to a single container |
| `--blacklist-remote <list>` | Skip remotes by name (comma-separated) |
| `--blacklist-vm <list>` | Skip VMs by VMID or name |
| `--blacklist-ct <list>` | Skip containers by VMID or name |
| `--blacklist-net <list>` | Skip network interfaces by name |
| `--warn-stopped-vm` | WARN on stopped VMs (default: OK) |
| `--crit-stopped-vm` | CRIT on stopped VMs |
| `--warn-stopped-ct` | WARN on stopped containers (default: OK) |
| `--crit-stopped-ct` | CRIT on stopped containers |
| `--ignore-no-sub` | Treat missing subscription as OK (not WARN) |
| `--expected-tz <tz>` | WARN when node timezone differs from expected (e.g. `Europe/Berlin`) |

### Output Options

| Option | Description |
|--------|-------------|
| `-v, --verbose` | Show all check details, not just problems |
| `-s, --silent` | Only output problem lines; suppress OK lines |
| `--no-perfdata` | Suppress the perfdata section entirely |
| `--port <port>` | API port (default: 8443) |
| `-d, --debug` | Enable bash trace output (`set -x`) |

## Examples

### Full PDM Health Check
```bash
./check_pdm_health.sh -H pdm.example.com -T 'root@pdm!monitoring:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -A
```

### Full Check with Password Auth (includes node-level checks)
```bash
./check_pdm_health.sh -H pdm.example.com -U root@pam -P 'password' -A -v
```

### Remote Connections with Custom CPU Threshold
```bash
./check_pdm_health.sh -H 192.0.2.10 -T 'root@pdm!mon:...' -eRemotes \
  -wCPU 70 -cCPU 90 -wMem 75 -cMem 90 -v
```

### VM Status Filtered to a Specific Remote
```bash
./check_pdm_health.sh -H pdm.example.com -T 'root@pdm!mon:...' -eVM \
  --remote pve-remote -v
```

### Single VM Detail
```bash
./check_pdm_health.sh -H pdm.example.com -T 'root@pdm!mon:...' -eVM \
  --vm 118 --warn-guest-cpu 70 --crit-guest-cpu 90 -v
```

### Updates with Remote Nodes (requires Administrator token or password)
```bash
./check_pdm_health.sh -H pdm.example.com -T 'root@pam!monitoring:...' -eUpdates -v
```

### Task Log — Last 4 Hours
```bash
./check_pdm_health.sh -H pdm.example.com -U root@pam -P 'password' -eTasks \
  --taskcheck-time 4h --warn-tasks 1 --crit-tasks 1 -v
```

### Subscriptions, Ignore Missing
```bash
./check_pdm_health.sh -H pdm.example.com -T 'root@pdm!mon:...' -eSub --ignore-no-sub
```

### All Checks, Suppress Updates and Certs
```bash
./check_pdm_health.sh -H pdm.example.com -U root@pam -P 'password' -A \
  --disable-updates --disable-certs -v
```

## Sample Output

### Token auth, all checks, verbose (`-A -v`)
```
One or more Problems detected:
---------------------------------------
[CRITICAL] - Remote pve-remote (pve): 1 node(s) overloaded
[WARNING] - 1 SDN zone(s) pending (config not applied)
[CRITICAL] - VM 118/vm-heavy (pve-remote/pve-node2): CPU 95% >= 95%
[WARNING] - VM 118/vm-heavy (pve-remote/pve-node2): Memory 94% >= 80%
[WARNING] - Remote pve-remote: no subscription
[WARNING] - 2 remote node(s) with 2 pending update(s)
---------------------------------------

All Services:
---------------------------------------
[UNKNOWN] - Node checks unavailable: /nodes inaccessible via API token (PDM restriction; use -U/-P password auth for full node checks)
Remote Connections:
---------------------------------------
[CRITICAL] -   Remote pve-remote (pve): 2 node(s), 0 warn, 1 crit
[CRITICAL] -     pve-node2: online | CPU: 100% (warn: 80%, crit: 95%) | Mem: 60% (18.8 GB/31.2 GB) | Uptime: 60d 0h 54m
[OK] -     pve-node1: online | CPU: 5% (warn: 80%, crit: 95%) | Mem: 26% (8.3 GB/31.2 GB) | Uptime: 59d 23h 37m
[CRITICAL] - Remotes: 1 total | 1 error(s)
---------------------------------------
...
Subscriptions:
---------------------------------------
[UNKNOWN] -   PDM (192.0.2.10): subscription check unavailable (API tokens cannot access /nodes; use password auth)
[WARNING] -   Remote pve-remote: none
[WARNING] - Subscriptions: 1 warning(s)
---------------------------------------
Package Updates:
---------------------------------------
[WARNING] - Updates: Remotes: 2 node(s) pending
[WARNING] -   pve-node1 (pve-remote): 1 update(s) -- pve-manager 9.2.3
[WARNING] -   pve-node2 (pve-remote): 1 update(s) -- pve-manager 9.2.3
---------------------------------------
```

### Password auth, all checks, verbose (`-U root@pam -P ... -A -v`)
```
One or more Problems detected:
---------------------------------------
[CRITICAL] - Remote pve-remote (pve): 1 node(s) overloaded
[CRITICAL] - PDM (pdm-node): subscription invalid
[WARNING] - 2 remote node(s) with 2 pending update(s)
---------------------------------------

All Services:
---------------------------------------
PDM Node (pdm-node):
---------------------------------------
[OK] - Node pdm-node: CPU 1% | Mem 21% | Uptime: 2d 1h 22m
[OK] -   pdm-node CPU: 1% (warn: 80%, crit: 95%)
[OK] -   pdm-node Memory: 426.1 MB / 1.9 GB (21%)
[OK] -   pdm-node Swap: 0 B / 1.9 GB (0%)
[OK] -   pdm-node Load: 0.04 / 0.03 (per-CPU: 0.01)
[OK] -   pdm-node IOWait: 0%
[OK] -   pdm-node Uptime: 2d 1h 22m
---------------------------------------
Time:
---------------------------------------
[OK] - Time: drift 0s | TZ: Europe/Berlin
---------------------------------------
...
Certificates:
---------------------------------------
[OK] -   Cert proxy.pem: 364995d left (3025-10-08)
[OK] - Certificates: all valid
---------------------------------------
```

## Integration with Monitoring Systems

### Icinga2 Configuration

Create a command definition in `/etc/icinga2/conf.d/commands.conf`:

```icinga2
object CheckCommand "check_pdm" {
    command = [ PluginDir + "/check_pdm_health.sh" ]
    arguments = {
        "-H"  = "$pdm_host$"
        "-T"  = "$pdm_token$"
        "-A"  = {
            set_if = "$pdm_check_all$"
        }
        "-v"  = {
            set_if = "$pdm_verbose$"
        }
        "-wCPU"                  = "$pdm_warn_cpu$"
        "-cCPU"                  = "$pdm_crit_cpu$"
        "-wMem"                  = "$pdm_warn_mem$"
        "-cMem"                  = "$pdm_crit_mem$"
        "--warn-failed-remotes"  = "$pdm_warn_failed_remotes$"
        "--crit-failed-remotes"  = "$pdm_crit_failed_remotes$"
        "--warn-sub-days"        = "$pdm_warn_sub_days$"
        "--crit-sub-days"        = "$pdm_crit_sub_days$"
        "--warn-cert"            = "$pdm_warn_cert$"
        "--crit-cert"            = "$pdm_crit_cert$"
        "--ignore-no-sub"        = {
            set_if = "$pdm_ignore_no_sub$"
        }
        "--no-perfdata"          = {
            set_if = "$pdm_no_perfdata$"
        }
    }
    vars.pdm_warn_cpu             = 80
    vars.pdm_crit_cpu             = 95
    vars.pdm_warn_mem             = 80
    vars.pdm_crit_mem             = 95
    vars.pdm_warn_failed_remotes  = 1
    vars.pdm_crit_failed_remotes  = 1
    vars.pdm_warn_sub_days        = 30
    vars.pdm_crit_sub_days        = 14
    vars.pdm_warn_cert            = 30
    vars.pdm_crit_cert            = 14
    vars.pdm_check_all            = true
    vars.pdm_verbose              = false
    vars.pdm_ignore_no_sub        = false
    vars.pdm_no_perfdata          = false
}
```

Create a service definition:

```icinga2
apply Service "PDM Health" {
    check_command = "check_pdm"
    vars.pdm_host  = host.vars.pdm_host
    vars.pdm_token = host.vars.pdm_token

    assign where host.vars.pdm_host != ""
}
```

### Nagios Configuration

Add to `commands.cfg`:

```nagios
define command {
    command_name    check_pdm
    command_line    $USER1$/check_pdm_health.sh -H $ARG1$ -T $ARG2$ -A -wCPU $ARG3$ -cCPU $ARG4$
}
```

Add to `services.cfg`:

```nagios
define service {
    use                 generic-service
    host_name           pdm-server
    service_description PDM Health
    check_command       check_pdm!192.0.2.10!root@pdm!monitoring:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx!80!95
}
```

## Security Considerations

- **API Token**: Create a dedicated monitoring token. Assign the `Auditor` role for resource/remote monitoring, or `Administrator` for remote update visibility.
- **Node-Level Checks**: If you need PDM node system checks (Sys/Time/DNS/Net/Certs/Tasks), use password auth (`-U root@pam -P ...`). API tokens cannot access `/nodes/*` — this is a PDM design restriction, not a role/permission issue.
- **Credential Storage**: Store credentials in your monitoring system's secrets store (Icinga2 constants, HashiCorp Vault, etc.) — not in plain-text config files.
- **Network Access**: The monitoring server requires HTTPS (port 8443) access to the PDM management IP. No outbound internet access is required.
- **Self-Signed Certificates**: The plugin uses `curl --insecure` to accept PDM's default self-signed certificate. If you use a CA-signed certificate, this has no effect on security.

## Troubleshooting

### Common Issues

**`[UNKNOWN] - PDM API authentication failed`:**
- Verify the token format: must be `USER@REALM!TOKENID:SECRET` (colon separator, single-quoted on the command line)
- PDM uses `:` between token ID and secret, unlike PVE which uses `=`. The plugin auto-normalises `=` to `:` but the overall format must still be correct.
- Test connectivity:
  ```bash
  curl -sk -H "Authorization: PDMAPIToken=root@pdm!monitoring:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" \
    https://<host>:8443/api2/json/version
  ```
- Confirm the token has not been deleted or disabled in the PDM UI (Administration -> Access Control -> API Tokens)
- Confirm the token user has a role assigned (Administration -> Access Control -> Permissions)

**`[UNKNOWN] - Node checks unavailable`:**
- This is expected with API token auth. PDM does not allow any API token to access `/nodes/*`, regardless of role.
- Use `-U root@pam -P <password>` for full node-level monitoring.
- All resource/remote/guest checks work normally with token auth.

**`[UNKNOWN] - Updates: unavailable`:**
- The `/remotes/updates/summary` endpoint requires at minimum an Administrator-role token.
- Auditor-role tokens cannot access this endpoint — use an Administrator-role token or password auth.

**`[UNKNOWN] - jq is required but not found in PATH`:**
- Install jq: `apt install jq` / `dnf install jq` / `emerge app-misc/jq`

**Remote nodes show `[CRITICAL]` unexpectedly:**
- Check PDM UI -> Remotes to verify the remote connection is healthy.
- A remote node offline in PDM maps directly to CRIT in `-eRemotes`.

**`-eTasks` shows no entries despite recent activity:**
- Ensure `--taskcheck-time` covers a long enough window. Default is `1h`.
- `-eTasks` requires password auth (node-level endpoint).

### Debug Mode

Enable full bash trace output for deep troubleshooting:
```bash
./check_pdm_health.sh -H 192.0.2.10 -T 'root@pdm!mon:...' -A -d 2>&1 | less
```

Or use verbose for readable per-module detail:
```bash
./check_pdm_health.sh -H 192.0.2.10 -T 'root@pdm!mon:...' -eRemotes -eResources -v
```

## Contributing

Contributions are welcome! Please feel free to submit issues, feature requests, or pull requests.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-new-check`)
3. Make your changes
4. Test against a real PDM instance or captured API JSON fixtures
5. Submit a pull request

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

## Support

For support, please:
1. Review the troubleshooting section above
2. Check existing GitHub issues
3. Open a new issue with your PDM version, number of connected remotes, and the full plugin output with `-d` (debug) enabled

## Author

**Felix Longardt**
- Email: monitoring@longardt.com
- GitHub: [@ascii42](https://github.com/ascii42)

## Acknowledgments

- Proxmox Server Solutions for the PDM REST API
- The Icinga and Nagios communities for feedback and testing

---

**Note:** This plugin is not officially supported by Proxmox Server Solutions GmbH. Use at your own discretion and test thoroughly in your environment before deploying to production monitoring.
