#!/bin/bash
#
# Monitor plugin for checking Proxmox Datacenter Manager (PDM) via REST API
#
# Author:
#   Felix Longardt <monitoring@longardt.com>
#
# Version history:
# 1.0.0  2026-06-11  Initial release: -eSys -eRemotes -eResources -eSub -eUpdates -eTasks -eCerts -eAll
# 1.1.0  2026-06-12  Add -eTime -eDNS -eNet; -U/-P user/password auth; token auth fallback to cookie
# 1.2.0  2026-06-12  Add -eVM -eCT with --vm/--ct/--remote selection and guest thresholds;
#                    fix -eCerts endpoint (/certificates/info); fix -eRemotes (use /remotes/remote);
#                    add SDN zones + PBS to -eResources
# 1.3.0  2026-06-12  -eRemotes: show per-node detail in verbose; -eUpdates: check remote nodes via
#                    /remotes/updates/summary (warn on pending); note PDM 1.0.x token auth bug
# 1.4.0  2026-06-12  Fix token auth: PDM uses colon (:) separator (auto-normalize = to :);
#                    -eRemotes: per-node CPU/mem/uptime with warn/crit thresholds + perf data
# 1.5.0  2026-06-12  Graceful degradation for token auth: /nodes requires root@pam; all per-node
#                    checks (-eSys -eTime -eDNS -eNet -eSub -eTasks -eCerts) skip with single
#                    UNKNOWN notice; resource/remote checks always work with Auditor token
# 1.6.0  2026-06-12  -eUpdates: detect /remotes/updates/summary permission failure (requires
#                    Administrator or root@pam); show UNKNOWN instead of misleading OK with token

## VARIABLES
PROGNAME="${0##*/}"
REVISION="1.6.0"
JQ="$(which jq)"
CURL="$(which curl)"
AWK="$(which awk)"

status_ok="[OK]"
status_warn="[WARNING]"
status_crit="[CRITICAL]"
status_unknown="[UNKNOWN]"

exit_unknown() {
    echo "UNKNOWN: ${1}"
    exit 3
}

## FUNCTIONS
print_usage() {
    echo "Usage: ${PROGNAME} [-h] [-V] -H <host> { -T <token> | -U <user> -P <pass> } [-opts] [-eX]"
}

print_revision() {
    echo "${1} - v${2}"
}

print_help() {
    print_revision "${PROGNAME}" "${REVISION}"
    echo ""
    print_usage
cat << EOM


 This plugin monitors Proxmox Datacenter Manager (PDM) via the PDM REST API
 (https://<host>:8443/api2/json/).

 Authentication -- choose one:
   Token:         -T 'root@pdm!monitoring:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
                  Create token in PDM UI: Administration -> Access Control -> API Tokens
                  Use single quotes -- bash expands '!' in double quotes.
                  PDM uses colon (:) as separator between token ID and secret.
                  PVE-style equals (=) is also accepted and auto-converted.
                  The token user needs Auditor or Administrator role granted in the PDM
                  UI (Administration -> Access Control -> Permissions).
   User/password: -U root@pam -P 'password'
                  Uses ticket-based login (PDMAuthCookie).

Options:
 -h, --help
    Print detailed help screen
 -V, --version
    Print version information

 -H, --host <hostname|IP>
    Hostname or IP address of the PDM node
 --port <port>
    API port (default: 8443)
 -T, --token <token>
    API token -- full format: USER@REALM!TOKENID=SECRET
    Example: -T 'root@pam!monitoring=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
 -U, --username <user@realm>
    Username for ticket auth (e.g. root@pam). Requires -P.
 -P, --password <password>
    Password for ticket auth. Requires -U.

 Enable flags (opt-in -- at least one -eX flag is required):
 -eSys,       --enable-sys
    PDM node system resources: CPU%, memory%, swap%, load average, uptime
    Thresholds: -wCPU/-cCPU (default: 80/95%), -wMem/-cMem (default: 80/95%)
    Swap: --warn-swap/--crit-swap (default: 20/50%)
    Load: --warn-load/--crit-load (default: disabled)
 -eTime,      --enable-time
    PDM node system time: timezone and drift vs. monitoring host
    --expected-tz <tz>:        WARN when timezone != expected (e.g. Europe/Berlin)
    --warn-time-drift <sec>:   WARN when drift > N seconds (default: 60)
    --crit-time-drift <sec>:   CRIT when drift > N seconds (default: 300)
 -eDNS,       --enable-dns
    PDM node DNS configuration: DNS servers and search domain
 -eNet,       --enable-net
    PDM node network interfaces: link state (active/autostart)
    --blacklist-net <iface[,iface,...]>: skip specific interfaces
 -eRemotes,   --enable-remotes
    Remote PVE/PBS cluster connectivity; derives status from node online/offline state
    CRIT when any remote node offline; WARN when remote has unknown nodes
    --blacklist-remote <id[,id,...]>: skip specific remotes by name
 -eResources, --enable-resources
    Aggregated resource overview across all connected remotes:
    PVE nodes online/offline, VMs/containers running/stopped,
    storage availability, SDN zones, PBS nodes,
    aggregate CPU/memory/storage utilisation
    --crit-failed-remotes <n>: CRIT when N or more remotes are failed (default: 1)
    --warn-failed-remotes <n>: WARN when N or more remotes are failed (default: 1)
 -eVM,        --enable-vm
    Virtual machine (QEMU) status across all remotes: running/stopped
    WARN on paused/suspended; CRIT on error state
    --warn-stopped-vm: also WARN on stopped VMs
    --crit-stopped-vm: CRIT on stopped VMs
    --blacklist-vm <vmid[,vmid,...]>: skip specific VMs by VMID or name
    --vm <vmid|name>: restrict to a single VM with detailed CPU/mem output
    --remote <id>: restrict to VMs on a specific remote
    Guest thresholds (running VMs only):
    --warn-guest-cpu / --crit-guest-cpu: CPU% thresholds (default: same as -wCPU/-cCPU)
    --warn-guest-mem / --crit-guest-mem: Memory% thresholds (default: same as -wMem/-cMem)
 -eCT,        --enable-ct
    Container (LXC) status across all remotes: running/stopped
    --warn-stopped-ct: also WARN on stopped containers
    --crit-stopped-ct: CRIT on stopped containers
    --blacklist-ct <vmid[,vmid,...]>: skip specific CTs by VMID or name
    --ct <vmid|name>: restrict to a single CT with detailed CPU/mem/disk output
    --remote <id>: restrict to CTs on a specific remote (same flag as -eVM)
 -eSub,       --enable-sub
    Subscription status: local PDM subscription + all remote subscriptions
    --warn-sub-days <days>: WARN when expiry within N days (default: 30)
    --crit-sub-days <days>: CRIT when expiry within N days (default: 14)
    --ignore-no-sub: treat missing subscription as OK
 -eUpdates,   --enable-updates
    Available package updates on the PDM node and all connected remote nodes
    --warn-updates <n>: WARN when >= N updates available (default: 1)
    --crit-updates <n>: CRIT when >= N security updates on PDM node (default: 1)
    Note: security vs. normal update classification is only available for the
          PDM node itself; remote node updates always trigger WARN
 -eTasks,     --enable-tasks
    PDM local task log and aggregated remote task statistics
    NOT included in -eAll; enable explicitly with -eTasks
    --taskcheck-time <dur>: look-back window (default: 1h; supports Nm/Nh/Nd)
    --warn-tasks <n>: WARN when >= N warning tasks (default: 1)
    --crit-tasks <n>: CRIT when >= N failed tasks (default: 1)
 -eCerts,     --enable-certs
    Local PDM TLS certificate expiry
    --warn-cert <days>: WARN when expiry within N days (default: 30)
    --crit-cert <days>: CRIT when expiry within N days (default: 14)
 -eAll, -A,   --enable-all
    Enable all standard checks (note: -eTasks is never included in -eAll)

 Disable flags (useful with -eAll):
 --disable-sys        --disable-time       --disable-dns
 --disable-net        --disable-remotes    --disable-resources
 --disable-vm         --disable-ct         --disable-sub
 --disable-updates    --disable-certs

 Threshold options:
 -wCPU, --warn-cpu <pct>       CPU warn threshold (default: 80)
 -cCPU, --crit-cpu <pct>       CPU crit threshold (default: 95)
 -wMem, --warn-mem <pct>       Memory warn threshold (default: 80)
 -cMem, --crit-mem <pct>       Memory crit threshold (default: 95)
 --warn-swap <pct>             Swap warn threshold (default: 20)
 --crit-swap <pct>             Swap crit threshold (default: 50)
 --warn-load <n>               Load avg warn (per-CPU; default: disabled)
 --crit-load <n>               Load avg crit (per-CPU; default: disabled)
 --warn-sub-days <days>        Subscription expiry warn days (default: 30)
 --crit-sub-days <days>        Subscription expiry crit days (default: 14)
 --warn-updates <n>            Update count warn (default: 1)
 --crit-updates <n>            Security update count crit (default: 1)
 --warn-tasks <n>              Task warning count (default: 1)
 --crit-tasks <n>              Task failure count (default: 1)
 --taskcheck-time <dur>        Task look-back window (default: 1h)
 --warn-cert <days>            Certificate expiry warn days (default: 30)
 --crit-cert <days>            Certificate expiry crit days (default: 14)
 --warn-failed-remotes <n>     Failed remote WARN count (default: 1)
 --crit-failed-remotes <n>     Failed remote CRIT count (default: 1)
 --expected-tz <tz>            Expected timezone (default: disabled)
 --warn-time-drift <sec>       Time drift warn seconds (default: 60)
 --crit-time-drift <sec>       Time drift crit seconds (default: 300)
 --blacklist-net <iface,...>   Skip network interfaces by name
 --warn-guest-cpu <pct>        VM/CT CPU warn % (default: same as --warn-cpu)
 --crit-guest-cpu <pct>        VM/CT CPU crit % (default: same as --crit-cpu)
 --warn-guest-mem <pct>        VM/CT memory warn % (default: same as --warn-mem)
 --crit-guest-mem <pct>        VM/CT memory crit % (default: same as --crit-mem)

 Output options:
 -v, --verbose
    Verbose output: show all check details, not just problems
 -s, --silent
    Only output problem lines (no OK lines)
 --no-perfdata
    Suppress performance data output
 -d, --debug
    Enable bash debug output (set -x)

EOM
}

[[ -z "${JQ}" ]]   && exit_unknown "jq is required but not found in PATH"
[[ -z "${CURL}" ]] && exit_unknown "curl is required but not found in PATH"
[[ -z "${AWK}" ]]  && exit_unknown "awk is required but not found in PATH"

## ARGUMENT PARSING
while [[ -n "${1}" ]]; do
    case "${1}" in
    -h|--help)
        print_help
        exit 0
        ;;
    -V|--version)
        print_revision "${PROGNAME}" "${REVISION}"
        exit 0
        ;;
    -H|--host)      shift; pdm_host="${1}" ;;
    --port)         shift; pdm_port="${1}" ;;
    -T|--token)     shift; api_token="${1}" ;;
    -U|--username)  shift; pdm_user="${1}" ;;
    -P|--password)  shift; pdm_pass="${1}" ;;

    # Enable flags
    -eSys|--enable-sys)           enable_sys=1 ;;
    -eTime|--enable-time)         enable_time=1 ;;
    -eDNS|--enable-dns)           enable_dns=1 ;;
    -eNet|--enable-net)           enable_net=1 ;;
    -eRemotes|--enable-remotes)   enable_remotes=1 ;;
    -eResources|--enable-resources) enable_resources=1 ;;
    -eVM|--enable-vm)             enable_vm=1 ;;
    -eCT|--enable-ct)             enable_ct=1 ;;
    -eSub|--enable-sub)           enable_sub=1 ;;
    -eUpdates|--enable-updates)   enable_updates=1 ;;
    -eTasks|--enable-tasks)       enable_tasks=1 ;;
    -eCerts|--enable-certs)       enable_certs=1 ;;
    -eAll|-A|--enable-all)        enable_all=1 ;;

    # Disable flags
    --disable-sys)        disable_sys=1 ;;
    --disable-time)       disable_time=1 ;;
    --disable-dns)        disable_dns=1 ;;
    --disable-net)        disable_net=1 ;;
    --disable-remotes)    disable_remotes=1 ;;
    --disable-resources)  disable_resources=1 ;;
    --disable-vm)         disable_vm=1 ;;
    --disable-ct)         disable_ct=1 ;;
    --disable-sub)        disable_sub=1 ;;
    --disable-updates)    disable_updates=1 ;;
    --disable-certs)      disable_certs=1 ;;

    # Thresholds
    -wCPU|--warn-cpu)   shift; warn_cpu="${1}" ;;
    -cCPU|--crit-cpu)   shift; crit_cpu="${1}" ;;
    -wMem|--warn-mem)   shift; warn_mem="${1}" ;;
    -cMem|--crit-mem)   shift; crit_mem="${1}" ;;
    --warn-swap)        shift; warn_swap="${1}" ;;
    --crit-swap)        shift; crit_swap="${1}" ;;
    --warn-load)        shift; warn_load="${1}" ;;
    --crit-load)        shift; crit_load="${1}" ;;
    --warn-sub-days)    shift; warn_sub_days="${1}" ;;
    --crit-sub-days)    shift; crit_sub_days="${1}" ;;
    --warn-updates)     shift; warn_updates="${1}" ;;
    --crit-updates)     shift; crit_updates="${1}" ;;
    --warn-tasks)       shift; warn_tasks="${1}" ;;
    --crit-tasks)       shift; crit_tasks="${1}" ;;
    --taskcheck-time)   shift; taskcheck_time="${1}" ;;
    --warn-cert)        shift; warn_cert="${1}" ;;
    --crit-cert)        shift; crit_cert="${1}" ;;
    --warn-failed-remotes) shift; warn_failed_remotes="${1}" ;;
    --crit-failed-remotes) shift; crit_failed_remotes="${1}" ;;
    --expected-tz)      shift; expected_tz="${1}" ;;
    --warn-time-drift)  shift; warn_time_drift="${1}" ;;
    --crit-time-drift)  shift; crit_time_drift="${1}" ;;
    --warn-guest-cpu)   shift; warn_guest_cpu="${1}" ;;
    --crit-guest-cpu)   shift; crit_guest_cpu="${1}" ;;
    --warn-guest-mem)   shift; warn_guest_mem="${1}" ;;
    --crit-guest-mem)   shift; crit_guest_mem="${1}" ;;

    # VM/CT filters
    --vm)               shift; vm_filter="${1}" ;;
    --ct)               shift; ct_filter="${1}" ;;
    --remote)           shift; remote_filter="${1}" ;;
    --warn-stopped-vm)  warn_stopped_vm=1 ;;
    --crit-stopped-vm)  crit_stopped_vm=1 ;;
    --warn-stopped-ct)  warn_stopped_ct=1 ;;
    --crit-stopped-ct)  crit_stopped_ct=1 ;;
    --blacklist-vm)     shift; vm_blacklist="${1}" ;;
    --blacklist-ct)     shift; ct_blacklist="${1}" ;;

    # Other filters
    --blacklist-remote) shift; remote_blacklist="${1}" ;;
    --blacklist-net)    shift; net_blacklist="${1}" ;;
    --ignore-no-sub)    ignore_no_sub=1 ;;

    # Output
    -v|--verbose)       verbose=1 ;;
    -s|--silent)        silent=1 ;;
    --no-perfdata)      no_perfdata=1 ;;
    -d|--debug)         debug=1 ;;
    *) echo "Unknown option: ${1}"; print_usage; exit 3 ;;
    esac
    shift
done

## VALIDATION
[[ -z "${pdm_host}" ]] && { echo "Error: -H <host> is required"; print_usage; exit 3; }

if [[ -n "${api_token}" ]]; then
    if [[ "${api_token}" =~ ^PVEAPIToken= || "${api_token}" =~ ^PDMAPIToken= ]]; then
        exit_unknown "Pass only the token value, not the header prefix. Example: -T 'root@pdm!monitoring:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'"
    fi
    # PDM uses TOKEN_ID:SECRET (colon), not TOKEN_ID=SECRET like PVE. Accept both; normalize to colon.
    if [[ "${api_token}" =~ ^([^:=]+)=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$ ]]; then
        api_token="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
    fi
elif [[ -n "${pdm_user}" && -n "${pdm_pass}" ]]; then
    : # ticket auth -- validated at login time
else
    echo "Error: either -T <token> or -U <user> -P <pass> is required"
    print_usage; exit 3
fi

_any_enabled=0
for _ef in enable_sys enable_time enable_dns enable_net \
           enable_remotes enable_resources enable_vm enable_ct \
           enable_sub enable_updates enable_tasks enable_certs enable_all; do
    [[ -n "${!_ef}" ]] && { _any_enabled=1; break; }
done
[[ "${_any_enabled}" -eq 0 ]] && { echo "Error: at least one -eX check flag required"; print_usage; exit 3; }

## DEFAULTS
[[ -z "${pdm_port}" ]]          && pdm_port=8443
[[ -z "${warn_cpu}" ]]          && warn_cpu=80
[[ -z "${crit_cpu}" ]]          && crit_cpu=95
[[ -z "${warn_mem}" ]]          && warn_mem=80
[[ -z "${crit_mem}" ]]          && crit_mem=95
[[ -z "${warn_swap}" ]]         && warn_swap=20
[[ -z "${crit_swap}" ]]         && crit_swap=50
[[ -z "${warn_load}" ]]         && warn_load=-1
[[ -z "${crit_load}" ]]         && crit_load=-1
[[ -z "${warn_sub_days}" ]]     && warn_sub_days=30
[[ -z "${crit_sub_days}" ]]     && crit_sub_days=14
[[ -z "${warn_updates}" ]]      && warn_updates=1
[[ -z "${crit_updates}" ]]      && crit_updates=1
[[ -z "${warn_tasks}" ]]        && warn_tasks=1
[[ -z "${crit_tasks}" ]]        && crit_tasks=1
[[ -z "${taskcheck_time}" ]]    && taskcheck_time="1h"
[[ -z "${warn_cert}" ]]         && warn_cert=30
[[ -z "${crit_cert}" ]]         && crit_cert=14
[[ -z "${warn_failed_remotes}" ]] && warn_failed_remotes=1
[[ -z "${crit_failed_remotes}" ]] && crit_failed_remotes=1
[[ -z "${warn_time_drift}" ]]   && warn_time_drift=60
[[ -z "${crit_time_drift}" ]]   && crit_time_drift=300

# Strip optional trailing % from percentage thresholds
for _v in warn_cpu crit_cpu warn_mem crit_mem warn_swap crit_swap; do
    printf -v "${_v}" '%s' "${!_v//%/}"
done
unset _v

# Guest thresholds default to host thresholds after % strip
[[ -z "${warn_guest_cpu}" ]] && warn_guest_cpu="${warn_cpu}"
[[ -z "${crit_guest_cpu}" ]] && crit_guest_cpu="${crit_cpu}"
[[ -z "${warn_guest_mem}" ]] && warn_guest_mem="${warn_mem}"
[[ -z "${crit_guest_mem}" ]] && crit_guest_mem="${crit_mem}"
for _v in warn_guest_cpu crit_guest_cpu warn_guest_mem crit_guest_mem; do
    printf -v "${_v}" '%s' "${!_v//%/}"
done
unset _v

# Parse taskcheck duration to seconds
_taskcheck_secs=$(echo "${taskcheck_time}" | "${AWK}" '{
    v=$1; u=tolower(v)
    if (u ~ /d$/) { sub(/d$/, "", v); printf "%d", v*86400 }
    else if (u ~ /h$/) { sub(/h$/, "", v); printf "%d", v*3600 }
    else if (u ~ /m$/) { sub(/m$/, "", v); printf "%d", v*60 }
    else printf "%d", v
}')
_taskcheck_since=$(( $(date +%s) - _taskcheck_secs ))

[[ -n "${debug}" ]] && set -x

## API
PDM_API="https://${pdm_host}:${pdm_port}/api2/json"

pdm_api_get() {
    if [[ -n "${api_token}" ]]; then
        "${CURL}" -sk --connect-timeout 10 --max-time 30 \
            -H "Authorization: PDMAPIToken=${api_token}" \
            "${1}" 2>/dev/null
    else
        "${CURL}" -sk --connect-timeout 10 --max-time 30 \
            -b "${_pdm_cookiejar}" \
            "${1}" 2>/dev/null
    fi
}

## HELPER: format bytes
_fmt_bytes() {
    echo "${1:-0}" | "${AWK}" '{
        v=$1+0
        if (v>=1073741824)      printf "%.1f GB", v/1073741824
        else if (v>=1048576)    printf "%.1f MB", v/1048576
        else if (v>=1024)       printf "%.1f KB", v/1024
        else                    printf "%d B", v
    }'
}

## HELPER: format uptime seconds
_fmt_uptime() {
    echo "${1:-0}" | "${AWK}" '{
        s=$1+0; d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60)
        if (d>0) printf "%dd %dh %dm", d, h, m
        else if (h>0) printf "%dh %dm", h, m
        else printf "%dm", m
    }'
}

## TEMP DIR
_pf=$(mktemp -d /tmp/.pdm_check_XXXXXX) || exit_unknown "mktemp failed in /tmp"
_pdm_cookiejar="${_pf}/cookies"
trap 'rm -rf "${_pf}"' EXIT

## AUTH: ticket login (user/pass) or token check
if [[ -z "${api_token}" ]]; then
    _login_resp=$("${CURL}" -sk --connect-timeout 10 --max-time 15 \
        -c "${_pdm_cookiejar}" \
        -X POST "${PDM_API}/access/ticket" \
        -d "username=${pdm_user}&password=${pdm_pass}" 2>/dev/null)
    if [[ -z "${_login_resp}" ]]; then
        exit_unknown "Cannot reach PDM API at ${PDM_API} (host unreachable or wrong port)"
    fi
    _login_ok=$(echo "${_login_resp}" | "${JQ}" -r '.data.username // empty' 2>/dev/null)
    if [[ -z "${_login_ok}" ]]; then
        _login_err=$(echo "${_login_resp}" | "${JQ}" -r '(.errors // .message // empty)' 2>/dev/null)
        [[ -z "${_login_err}" ]] && _login_err="${_login_resp}"
        exit_unknown "PDM login failed: ${_login_err}"
    fi
fi

## CONNECTIVITY + AUTH CHECK (use /version -- accessible to all authenticated users)
_ver_buf=$(pdm_api_get "${PDM_API}/version")
_auth_check=$(echo "${_ver_buf}" | "${JQ}" -r '.data.version // empty' 2>/dev/null)
if [[ -z "${_auth_check}" ]]; then
    if [[ -z "${_ver_buf}" ]]; then
        exit_unknown "Cannot reach PDM API at ${PDM_API} (host unreachable or wrong port)"
    fi
    _raw_err=$(echo "${_ver_buf}" | "${JQ}" -r '(.errors // .message // empty)' 2>/dev/null)
    [[ -z "${_raw_err}" ]] && _raw_err="${_ver_buf}"
    if echo "${_raw_err}" | grep -qi "token\|credential\|auth\|disabled\|expired"; then
        exit_unknown "PDM API authentication failed: ${_raw_err}. Check token format: -T 'USER@REALM!TOKENID:SECRET' (colon separator)."
    elif [[ -n "${_raw_err}" ]]; then
        exit_unknown "PDM API error: ${_raw_err}"
    else
        exit_unknown "PDM API returned no data"
    fi
fi

## NODE NAME (local PDM node) -- /nodes inaccessible via any API token (PDM design); fails gracefully
_nod_buf=$(pdm_api_get "${PDM_API}/nodes")
_pdm_node=$(echo "${_nod_buf}" | "${JQ}" -r '.data[0].node // empty' 2>/dev/null)
_pdm_node_avail=1
if [[ -z "${_pdm_node}" ]]; then
    _pdm_node_avail=0
    _pdm_node="${pdm_host}"  # use hostname as display fallback
fi

## PREFETCH BASE DATA
pdm_api_get "${PDM_API}/resources/status"               > "${_pf}/resources_status.json" 2>/dev/null
[[ ( -n "${enable_remotes}"   || -n "${enable_all}" ) && -z "${disable_remotes}" ]] && \
    pdm_api_get "${PDM_API}/remotes/remote"             > "${_pf}/remotes.json"           2>/dev/null
[[ ( -n "${enable_sub}"       || -n "${enable_all}" ) && -z "${disable_sub}" ]] && \
    pdm_api_get "${PDM_API}/resources/subscription"     > "${_pf}/resources_sub.json"     2>/dev/null

## LOAD BASE DATA
_res_buf=$(cat "${_pf}/resources_status.json" 2>/dev/null)

## RESOURCES LIST (for -eVM, -eCT, -eRemotes node status)
_need_rlist=0
[[ ( -n "${enable_vm}"      || -n "${enable_all}" ) && -z "${disable_vm}" ]]      && _need_rlist=1
[[ ( -n "${enable_ct}"      || -n "${enable_all}" ) && -z "${disable_ct}" ]]      && _need_rlist=1
[[ ( -n "${enable_remotes}" || -n "${enable_all}" ) && -z "${disable_remotes}" ]] && _need_rlist=1
if [[ "${_need_rlist}" -eq 1 ]]; then
    pdm_api_get "${PDM_API}/resources/list" > "${_pf}/resources_list.json" 2>/dev/null
fi

## PER-NODE PREFETCH (only when /nodes was accessible)
[[ ( -n "${enable_sys}"     || -n "${enable_all}" ) && -z "${disable_sys}" ]] && \
    [[ "${_pdm_node_avail}" -eq 1 ]] && \
    pdm_api_get "${PDM_API}/nodes/${_pdm_node}/status"            > "${_pf}/node_status.json"   2>/dev/null
[[ ( -n "${enable_time}"    || -n "${enable_all}" ) && -z "${disable_time}" ]] && \
    pdm_api_get "${PDM_API}/nodes/${_pdm_node}/time"              > "${_pf}/node_time.json"     2>/dev/null
[[ ( -n "${enable_dns}"     || -n "${enable_all}" ) && -z "${disable_dns}" ]] && \
    [[ "${_pdm_node_avail}" -eq 1 ]] && \
    pdm_api_get "${PDM_API}/nodes/${_pdm_node}/dns"               > "${_pf}/node_dns.json"      2>/dev/null
[[ ( -n "${enable_net}"     || -n "${enable_all}" ) && -z "${disable_net}" ]] && \
    [[ "${_pdm_node_avail}" -eq 1 ]] && \
    pdm_api_get "${PDM_API}/nodes/${_pdm_node}/network"           > "${_pf}/node_network.json"  2>/dev/null
[[ ( -n "${enable_updates}" || -n "${enable_all}" ) && -z "${disable_updates}" ]] && {
    [[ "${_pdm_node_avail}" -eq 1 ]] && \
        pdm_api_get "${PDM_API}/nodes/${_pdm_node}/apt/update"    > "${_pf}/node_updates.json"    2>/dev/null
    pdm_api_get "${PDM_API}/remotes/updates/summary"              > "${_pf}/remote_updates.json"  2>/dev/null
}
[[ ( -n "${enable_certs}"   || -n "${enable_all}" ) && -z "${disable_certs}" ]] && \
    [[ "${_pdm_node_avail}" -eq 1 ]] && \
    pdm_api_get "${PDM_API}/nodes/${_pdm_node}/certificates/info" > "${_pf}/node_certs.json"    2>/dev/null
[[ ( -n "${enable_sub}"     || -n "${enable_all}" ) && -z "${disable_sub}" ]] && \
    [[ "${_pdm_node_avail}" -eq 1 ]] && \
    pdm_api_get "${PDM_API}/nodes/${_pdm_node}/subscription"      > "${_pf}/node_sub.json"      2>/dev/null
[[ -n "${enable_tasks}" ]] && [[ "${_pdm_node_avail}" -eq 1 ]] && {
    pdm_api_get "${PDM_API}/nodes/${_pdm_node}/tasks?limit=500&since=${_taskcheck_since}" \
        > "${_pf}/node_tasks.json" 2>/dev/null
    pdm_api_get "${PDM_API}/remotes/tasks/statistics" \
        > "${_pf}/remote_tasks_stats.json" 2>/dev/null
}

## OUTPUT ACCUMULATORS
pdm_output=""
pdm_problem_output=""
pdm_perf=""
_exit_code=0

# ---------------------------------------------------------------------------
# -eSys: PDM node system resources
# ---------------------------------------------------------------------------
_node_unavail_msg="${status_unknown} - Node checks unavailable: /nodes inaccessible via API token (PDM restriction; use -U/-P password auth for full node checks)\n"
_node_unavail_shown=0

if [[ ( -n "${enable_sys}" || -n "${enable_all}" ) && -z "${disable_sys}" ]]; then
    if [[ "${_pdm_node_avail}" -eq 0 ]]; then
        [[ "${_node_unavail_shown}" -eq 0 ]] && { pdm_output+="${_node_unavail_msg}"; _node_unavail_shown=1; }
    else
    [[ -n "${verbose}" ]] && pdm_output+="PDM Node (${_pdm_node}):\n---------------------------------------\n"

    _sbuf=$(cat "${_pf}/node_status.json" 2>/dev/null)
    _sys_vals=$(echo "${_sbuf}" | "${JQ}" -r '
        .data | [
            ((.cpu // 0) * 100 | round | tostring),
            ((.memory.used  // 0) | tostring),
            ((.memory.total // 0) | tostring),
            ((.swap.used    // 0) | tostring),
            ((.swap.total   // 0) | tostring),
            ((.uptime       // 0) | tostring),
            ((.loadavg[0]   // "0") | tostring),
            ((.loadavg[1]   // "0") | tostring),
            ((.wait         // 0) * 100 | round | tostring),
            ((.cpuinfo.cpus // 1) | tostring)
        ] | join("\t")' 2>/dev/null)

    IFS=$'\t' read -r _s_cpu _s_mem_used _s_mem_total _s_swap_used _s_swap_total \
                       _s_uptime _s_load1 _s_load5 _s_iowait _s_cpucount <<< "${_sys_vals}"

    _s_mem_pct=0
    [[ "${_s_mem_total}" -gt 0 ]] 2>/dev/null && \
        _s_mem_pct=$(( _s_mem_used * 100 / _s_mem_total ))
    _s_swap_pct=0
    [[ "${_s_swap_total}" -gt 0 ]] 2>/dev/null && \
        _s_swap_pct=$(( _s_swap_used * 100 / _s_swap_total ))
    _s_load_per_cpu=$(echo "${_s_load1} ${_s_cpucount}" | "${AWK}" '{printf "%.2f", $1/$2}')

    _s_state="${status_ok}"
    _s_warn=0; _s_crit=0

    if [[ "${_s_cpu}" -ge "${crit_cpu}" ]] 2>/dev/null; then
        _s_state="${status_crit}"; (( _s_crit++ ))
        pdm_problem_output+="${status_crit} - ${_pdm_node} CPU: ${_s_cpu}% >= ${crit_cpu}%\n"
    elif [[ "${_s_cpu}" -ge "${warn_cpu}" ]] 2>/dev/null; then
        _s_state="${status_warn}"; (( _s_warn++ ))
        pdm_problem_output+="${status_warn} - ${_pdm_node} CPU: ${_s_cpu}% >= ${warn_cpu}%\n"
    fi

    if [[ "${_s_mem_pct}" -ge "${crit_mem}" ]] 2>/dev/null; then
        [[ "${_s_state}" != "${status_crit}" ]] && { _s_state="${status_crit}"; (( _s_crit++ )); }
        pdm_problem_output+="${status_crit} - ${_pdm_node} Memory: ${_s_mem_pct}% >= ${crit_mem}%\n"
    elif [[ "${_s_mem_pct}" -ge "${warn_mem}" ]] 2>/dev/null; then
        [[ "${_s_state}" == "${status_ok}" ]] && { _s_state="${status_warn}"; (( _s_warn++ )); }
        pdm_problem_output+="${status_warn} - ${_pdm_node} Memory: ${_s_mem_pct}% >= ${warn_mem}%\n"
    fi

    if [[ "${_s_swap_pct}" -ge "${crit_swap}" ]] 2>/dev/null; then
        [[ "${_s_state}" != "${status_crit}" ]] && { _s_state="${status_crit}"; (( _s_crit++ )); }
        pdm_problem_output+="${status_crit} - ${_pdm_node} Swap: ${_s_swap_pct}% >= ${crit_swap}%\n"
    elif [[ "${_s_swap_pct}" -ge "${warn_swap}" ]] 2>/dev/null; then
        [[ "${_s_state}" == "${status_ok}" ]] && { _s_state="${status_warn}"; (( _s_warn++ )); }
        pdm_problem_output+="${status_warn} - ${_pdm_node} Swap: ${_s_swap_pct}% >= ${warn_swap}%\n"
    fi

    if [[ "${crit_load}" != "-1" ]] && \
       echo "${_s_load_per_cpu} ${crit_load}" | "${AWK}" 'BEGIN{exit 0} {exit ($1<$2)}' 2>/dev/null; then
        [[ "${_s_state}" != "${status_crit}" ]] && { _s_state="${status_crit}"; (( _s_crit++ )); }
        pdm_problem_output+="${status_crit} - ${_pdm_node} Load: ${_s_load1} (per-CPU: ${_s_load_per_cpu}) >= ${crit_load}\n"
    elif [[ "${warn_load}" != "-1" ]] && \
         echo "${_s_load_per_cpu} ${warn_load}" | "${AWK}" 'BEGIN{exit 0} {exit ($1<$2)}' 2>/dev/null; then
        [[ "${_s_state}" == "${status_ok}" ]] && { _s_state="${status_warn}"; (( _s_warn++ )); }
        pdm_problem_output+="${status_warn} - ${_pdm_node} Load: ${_s_load1} (per-CPU: ${_s_load_per_cpu}) >= ${warn_load}\n"
    fi

    if [[ "${_s_crit}" -gt 0 ]]; then
        pdm_output+="${status_crit} - Node ${_pdm_node}: ${_s_crit} critical resource(s)\n"
    elif [[ "${_s_warn}" -gt 0 ]]; then
        pdm_output+="${status_warn} - Node ${_pdm_node}: ${_s_warn} resource warning(s)\n"
    else
        pdm_output+="${status_ok} - Node ${_pdm_node}: CPU ${_s_cpu}% | Mem ${_s_mem_pct}% | Uptime: $(_fmt_uptime "${_s_uptime}")\n"
    fi

    if [[ -n "${verbose}" ]]; then
        pdm_output+="${_s_state} -   ${_pdm_node} CPU: ${_s_cpu}% (warn: ${warn_cpu}%, crit: ${crit_cpu}%)\n"
        pdm_output+="${_s_state} -   ${_pdm_node} Memory: $(_fmt_bytes "${_s_mem_used}") / $(_fmt_bytes "${_s_mem_total}") (${_s_mem_pct}%)\n"
        [[ "${_s_swap_total}" -gt 0 ]] && \
            pdm_output+="${_s_state} -   ${_pdm_node} Swap: $(_fmt_bytes "${_s_swap_used}") / $(_fmt_bytes "${_s_swap_total}") (${_s_swap_pct}%)\n"
        pdm_output+="${status_ok} -   ${_pdm_node} Load: ${_s_load1} / ${_s_load5} (per-CPU: ${_s_load_per_cpu})\n"
        pdm_output+="${status_ok} -   ${_pdm_node} IOWait: ${_s_iowait}%\n"
        pdm_output+="${status_ok} -   ${_pdm_node} Uptime: $(_fmt_uptime "${_s_uptime}")\n"
    fi

    pdm_perf+=" pdm_cpu=${_s_cpu}%;${warn_cpu};${crit_cpu};0;100"
    pdm_perf+=" pdm_mem=${_s_mem_used} pdm_mem_pct=${_s_mem_pct}%;${warn_mem};${crit_mem};0;100"
    [[ "${_s_swap_total}" -gt 0 ]] && \
        pdm_perf+=" pdm_swap=${_s_swap_used} pdm_swap_pct=${_s_swap_pct}%;${warn_swap};${crit_swap};0;100"
    pdm_perf+=" pdm_load=${_s_load1} pdm_load_per_cpu=${_s_load_per_cpu}"
    pdm_perf+=" pdm_iowait=${_s_iowait}%"
    pdm_perf+=" pdm_uptime=${_s_uptime}"

    [[ -n "${verbose}" ]] && pdm_output+="---------------------------------------\n\n"
    fi  # _pdm_node_avail
fi

# ---------------------------------------------------------------------------
# -eTime: Node time drift and timezone
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_time}" || -n "${enable_all}" ) && -z "${disable_time}" ]]; then
    if [[ "${_pdm_node_avail}" -eq 0 ]]; then
        [[ "${_node_unavail_shown}" -eq 0 ]] && { pdm_output+="${_node_unavail_msg}"; _node_unavail_shown=1; }
    else
    [[ -n "${verbose}" ]] && pdm_output+="Time:\n---------------------------------------\n"
    _tbuf=$(cat "${_pf}/node_time.json" 2>/dev/null)
    _t_server=$(echo "${_tbuf}"   | "${JQ}" -r '.data.time     // 0' 2>/dev/null)
    _t_tz=$(echo "${_tbuf}"       | "${JQ}" -r '.data.timezone // ""' 2>/dev/null)
    _t_local=$(date +%s)
    _t_drift=$(( _t_server - _t_local ))
    [[ "${_t_drift}" -lt 0 ]] && _t_drift=$(( -_t_drift ))

    _t_state="${status_ok}"
    if [[ "${_t_drift}" -ge "${crit_time_drift}" ]] 2>/dev/null; then
        _t_state="${status_crit}"
        pdm_problem_output+="${status_crit} - ${_pdm_node} time drift: ${_t_drift}s >= ${crit_time_drift}s\n"
    elif [[ "${_t_drift}" -ge "${warn_time_drift}" ]] 2>/dev/null; then
        _t_state="${status_warn}"
        pdm_problem_output+="${status_warn} - ${_pdm_node} time drift: ${_t_drift}s >= ${warn_time_drift}s\n"
    fi
    if [[ -n "${expected_tz}" && "${_t_tz}" != "${expected_tz}" ]]; then
        [[ "${_t_state}" == "${status_ok}" ]] && _t_state="${status_warn}"
        pdm_problem_output+="${status_warn} - ${_pdm_node} timezone: ${_t_tz} (expected ${expected_tz})\n"
    fi

    pdm_output+="${_t_state} - Time: drift ${_t_drift}s | TZ: ${_t_tz}\n"
    [[ -n "${verbose}" ]] && \
        pdm_output+="${_t_state} -   ${_pdm_node} time drift: ${_t_drift}s (warn: ${warn_time_drift}s, crit: ${crit_time_drift}s) | TZ: ${_t_tz}\n"

    pdm_perf+=" time_drift=${_t_drift};${warn_time_drift};${crit_time_drift};0"
    [[ -n "${verbose}" ]] && pdm_output+="---------------------------------------\n\n"
    fi  # _pdm_node_avail
fi

# ---------------------------------------------------------------------------
# -eDNS: Node DNS configuration
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_dns}" || -n "${enable_all}" ) && -z "${disable_dns}" ]]; then
    if [[ "${_pdm_node_avail}" -eq 0 ]]; then
        [[ "${_node_unavail_shown}" -eq 0 ]] && { pdm_output+="${_node_unavail_msg}"; _node_unavail_shown=1; }
    else
    [[ -n "${verbose}" ]] && pdm_output+="DNS:\n---------------------------------------\n"
    _dbuf=$(cat "${_pf}/node_dns.json" 2>/dev/null)
    _d_dns1=$(echo "${_dbuf}"   | "${JQ}" -r '.data.dns1   // ""' 2>/dev/null)
    _d_dns2=$(echo "${_dbuf}"   | "${JQ}" -r '.data.dns2   // ""' 2>/dev/null)
    _d_search=$(echo "${_dbuf}" | "${JQ}" -r '.data.search // ""' 2>/dev/null)

    if [[ -z "${_d_dns1}" ]]; then
        pdm_problem_output+="${status_warn} - ${_pdm_node}: no DNS server configured\n"
        pdm_output+="${status_warn} - DNS: no DNS server configured\n"
    else
        _d_servers="${_d_dns1}${_d_dns2:+, ${_d_dns2}}"
        pdm_output+="${status_ok} - DNS: ${_d_servers}${_d_search:+ (search: ${_d_search})}\n"
        [[ -n "${verbose}" ]] && \
            pdm_output+="${status_ok} -   ${_pdm_node} DNS1: ${_d_dns1}${_d_dns2:+, DNS2: ${_d_dns2}}${_d_search:+ | search: ${_d_search}}\n"
    fi
    [[ -n "${verbose}" ]] && pdm_output+="---------------------------------------\n\n"
    fi  # _pdm_node_avail
fi

# ---------------------------------------------------------------------------
# -eNet: Node network interfaces
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_net}" || -n "${enable_all}" ) && -z "${disable_net}" ]]; then
    if [[ "${_pdm_node_avail}" -eq 0 ]]; then
        [[ "${_node_unavail_shown}" -eq 0 ]] && { pdm_output+="${_node_unavail_msg}"; _node_unavail_shown=1; }
    else
    _nbuf=$(cat "${_pf}/node_network.json" 2>/dev/null)
    _net_any_warn=0; _net_total=0

    declare -A _net_bl_map=()
    if [[ -n "${net_blacklist}" ]]; then
        IFS=',' read -ra _net_bl_arr <<< "${net_blacklist}"
        for _e in "${_net_bl_arr[@]}"; do _net_bl_map["${_e// /}"]=1; done
    fi

    [[ -n "${verbose}" ]] && pdm_output+="Network:\n---------------------------------------\n"

    while IFS=$'\t' read -r _niface _nactive _ncidr _ntype; do
        [[ -z "${_niface}" ]] && continue
        [[ -n "${_net_bl_map[${_niface}]:-}" ]] && continue
        (( _net_total++ ))

        _n_state="${status_ok}"
        _n_status="active"
        if [[ "${_nactive}" != "true" ]]; then
            _n_state="${status_warn}"; _n_status="inactive"; (( _net_any_warn++ ))
            pdm_problem_output+="${status_warn} - ${_pdm_node} interface ${_niface}: not active\n"
        fi
        [[ -n "${verbose}" ]] && \
            pdm_output+="${_n_state} -   ${_pdm_node} ${_niface} (${_ntype:-eth}): ${_n_status}${_ncidr:+ -- ${_ncidr}}\n"
    done < <(echo "${_nbuf}" | "${JQ}" -r '
        .data[]? | [
            (.iface  // .name // ""),
            ((.active // false) | tostring),
            (.cidr // ""),
            (.type // "")
        ] | join("\t")' 2>/dev/null)

    if [[ "${_net_any_warn}" -gt 0 ]]; then
        pdm_output+="${status_warn} - Network: ${_net_total} interface(s), ${_net_any_warn} inactive\n"
    else
        pdm_output+="${status_ok} - Network: ${_net_total} interface(s) active\n"
    fi

    pdm_perf+=" net_interfaces=${_net_total} net_inactive=${_net_any_warn}"
    unset _net_bl_map
    [[ -n "${verbose}" ]] && pdm_output+="---------------------------------------\n\n"
    fi  # _pdm_node_avail
fi

# ---------------------------------------------------------------------------
# -eRemotes: Remote PVE/PBS connectivity (using /remotes/remote + resources/list node status)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_remotes}" || -n "${enable_all}" ) && -z "${disable_remotes}" ]]; then
    [[ -n "${verbose}" ]] && pdm_output+="Remote Connections:\n---------------------------------------\n"

    declare -A _rmt_bl_map=()
    if [[ -n "${remote_blacklist}" ]]; then
        IFS=',' read -ra _rmt_bl_arr <<< "${remote_blacklist}"
        for _e in "${_rmt_bl_arr[@]}"; do _rmt_bl_map["${_e// /}"]=1; done
    fi

    # Build per-remote node resource map from resources/list
    declare -A _rmt_node_offline=()
    declare -A _rmt_node_total=()
    declare -A _rmt_node_warn_c=()
    declare -A _rmt_node_crit_c=()
    declare -A _rmt_node_lines=()
    _rlist_buf=$(cat "${_pf}/resources_list.json" 2>/dev/null)

    while IFS=$'\t' read -r _rnr_remote _rnr_node _rnr_status _rnr_cpu _rnr_mem _rnr_maxmem _rnr_uptime; do
        [[ -z "${_rnr_remote}" ]] && continue
        [[ -n "${_rmt_bl_map[${_rnr_remote}]:-}" ]] && continue
        _rmt_node_total["${_rnr_remote}"]=$(( ${_rmt_node_total["${_rnr_remote}"]:-0} + 1 ))
        [[ "${_rnr_status}" != "online" ]] && \
            _rmt_node_offline["${_rnr_remote}"]=$(( ${_rmt_node_offline["${_rnr_remote}"]:-0} + 1 ))

        _rnr_mem_pct=0
        [[ "${_rnr_maxmem}" -gt 0 ]] 2>/dev/null && \
            _rnr_mem_pct=$(( _rnr_mem * 100 / _rnr_maxmem ))
        _rnr_nstate="${status_ok}"

        if [[ "${_rnr_status}" == "online" ]]; then
            if [[ "${_rnr_cpu}" -ge "${crit_cpu}" ]] 2>/dev/null; then
                _rnr_nstate="${status_crit}"
                _rmt_node_crit_c["${_rnr_remote}"]=$(( ${_rmt_node_crit_c["${_rnr_remote}"]:-0} + 1 ))
            elif [[ "${_rnr_cpu}" -ge "${warn_cpu}" ]] 2>/dev/null; then
                _rnr_nstate="${status_warn}"
                _rmt_node_warn_c["${_rnr_remote}"]=$(( ${_rmt_node_warn_c["${_rnr_remote}"]:-0} + 1 ))
            fi
            if [[ "${_rnr_mem_pct}" -ge "${crit_mem}" ]] 2>/dev/null; then
                [[ "${_rnr_nstate}" != "${status_crit}" ]] && {
                    _rnr_nstate="${status_crit}"
                    _rmt_node_crit_c["${_rnr_remote}"]=$(( ${_rmt_node_crit_c["${_rnr_remote}"]:-0} + 1 ))
                }
            elif [[ "${_rnr_mem_pct}" -ge "${warn_mem}" ]] 2>/dev/null; then
                [[ "${_rnr_nstate}" == "${status_ok}" ]] && {
                    _rnr_nstate="${status_warn}"
                    _rmt_node_warn_c["${_rnr_remote}"]=$(( ${_rmt_node_warn_c["${_rnr_remote}"]:-0} + 1 ))
                }
            fi
        else
            _rnr_nstate="${status_crit}"
        fi

        _rnr_mem_str="$(_fmt_bytes "${_rnr_mem}")/$(_fmt_bytes "${_rnr_maxmem}")"
        _rnr_detail="${_rnr_status}"
        [[ "${_rnr_status}" == "online" ]] && \
            _rnr_detail+=" | CPU: ${_rnr_cpu}% (warn: ${warn_cpu}%, crit: ${crit_cpu}%) | Mem: ${_rnr_mem_pct}% (${_rnr_mem_str}) | Uptime: $(_fmt_uptime "${_rnr_uptime}")"
        _rmt_node_lines["${_rnr_remote}"]+="${_rnr_nstate} -     ${_rnr_node}: ${_rnr_detail}\n"

        pdm_perf+=" node_${_rnr_node//[^a-zA-Z0-9_]/_}_cpu=${_rnr_cpu}%;${warn_cpu};${crit_cpu};0;100"
        pdm_perf+=" node_${_rnr_node//[^a-zA-Z0-9_]/_}_mem=${_rnr_mem_pct}%;${warn_mem};${crit_mem};0;100"
        [[ "${_rnr_uptime:-0}" -gt 0 ]] && \
            pdm_perf+=" node_${_rnr_node//[^a-zA-Z0-9_]/_}_uptime=${_rnr_uptime}"

    done < <(echo "${_rlist_buf}" | "${JQ}" -r '
        .data[]? | .remote as $r | .resources[]? |
        select(.type == "pve-node") |
        [$r, (.node // ""), (.status // "unknown"),
         ((.cpu // 0) * 100 | round | tostring),
         ((.mem // 0) | tostring),
         ((.maxmem // 0) | tostring),
         ((.uptime // 0) | tostring)
        ] | join("\t")' 2>/dev/null)

    _rmt_any_warn=0; _rmt_any_crit=0; _rmt_total=0

    while IFS=$'\t' read -r _rname _rtype _rauthid; do
        [[ -z "${_rname}" ]] && continue
        [[ -n "${_rmt_bl_map[${_rname}]:-}" ]] && continue
        (( _rmt_total++ ))

        _offline_nodes="${_rmt_node_offline[${_rname}]:-0}"
        _total_nodes="${_rmt_node_total[${_rname}]:-0}"
        _warn_nodes="${_rmt_node_warn_c[${_rname}]:-0}"
        _crit_nodes="${_rmt_node_crit_c[${_rname}]:-0}"

        _rmt_state="${status_ok}"
        if [[ "${_offline_nodes}" -gt 0 || "${_crit_nodes}" -gt 0 ]]; then
            _rmt_state="${status_crit}"; (( _rmt_any_crit++ ))
            [[ "${_offline_nodes}" -gt 0 ]] && \
                pdm_problem_output+="${status_crit} - Remote ${_rname} (${_rtype}): ${_offline_nodes} node(s) offline\n"
            [[ "${_crit_nodes}" -gt 0 ]] && \
                pdm_problem_output+="${status_crit} - Remote ${_rname} (${_rtype}): ${_crit_nodes} node(s) overloaded\n"
        elif [[ "${_warn_nodes}" -gt 0 ]]; then
            _rmt_state="${status_warn}"; (( _rmt_any_warn++ ))
            pdm_problem_output+="${status_warn} - Remote ${_rname} (${_rtype}): ${_warn_nodes} node(s) over threshold\n"
        fi

        if [[ -n "${verbose}" ]]; then
            _rmt_summary="${_total_nodes} node(s)"
            [[ "${_offline_nodes}" -gt 0 ]] && _rmt_summary+=", ${_offline_nodes} offline"
            [[ "${_warn_nodes}" -gt 0 || "${_crit_nodes}" -gt 0 ]] && \
                _rmt_summary+=", ${_warn_nodes} warn, ${_crit_nodes} crit"
            pdm_output+="${_rmt_state} -   Remote ${_rname} (${_rtype}): ${_rmt_summary}\n"
            pdm_output+="${_rmt_node_lines[${_rname}]:-}"
        fi

    done < <(echo "${_rmt_buf:-$(cat "${_pf}/remotes.json" 2>/dev/null)}" | "${JQ}" -r '
        .data[]? | [
            (.id   // ""),
            (.type // ""),
            (.authid // "")
        ] | join("\t")' 2>/dev/null)

    if [[ "${_rmt_any_crit}" -gt 0 ]]; then
        pdm_output+="${status_crit} - Remotes: ${_rmt_total} total | ${_rmt_any_crit} error(s)\n"
    elif [[ "${_rmt_any_warn}" -gt 0 ]]; then
        pdm_output+="${status_warn} - Remotes: ${_rmt_total} total | ${_rmt_any_warn} warning(s)\n"
    else
        pdm_output+="${status_ok} - Remotes: ${_rmt_total} total, all reachable\n"
    fi

    pdm_perf+=" remotes_total=${_rmt_total} remotes_ok=$(( _rmt_total - _rmt_any_crit - _rmt_any_warn ))"
    pdm_perf+=" remotes_warn=${_rmt_any_warn} remotes_crit=${_rmt_any_crit}"
    unset _rmt_bl_map _rmt_node_offline _rmt_node_total _rmt_node_warn_c _rmt_node_crit_c _rmt_node_lines
    [[ -n "${verbose}" ]] && pdm_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eResources: Aggregated cluster resource overview
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_resources}" || -n "${enable_all}" ) && -z "${disable_resources}" ]]; then
    [[ -n "${verbose}" ]] && pdm_output+="Aggregated Resources:\n---------------------------------------\n"

    _failed_remotes=$(echo "${_res_buf}"  | "${JQ}" -r '.data.failed_remotes   // 0' 2>/dev/null)
    _pve_online=$(echo "${_res_buf}"      | "${JQ}" -r '.data.pve_nodes.online  // 0' 2>/dev/null)
    _pve_offline=$(echo "${_res_buf}"     | "${JQ}" -r '.data.pve_nodes.offline // 0' 2>/dev/null)
    _pve_unknown=$(echo "${_res_buf}"     | "${JQ}" -r '.data.pve_nodes.unknown // 0' 2>/dev/null)
    _qemu_running=$(echo "${_res_buf}"    | "${JQ}" -r '.data.qemu.running  // 0' 2>/dev/null)
    _qemu_stopped=$(echo "${_res_buf}"    | "${JQ}" -r '.data.qemu.stopped  // 0' 2>/dev/null)
    _lxc_running=$(echo "${_res_buf}"     | "${JQ}" -r '.data.lxc.running   // 0' 2>/dev/null)
    _lxc_stopped=$(echo "${_res_buf}"     | "${JQ}" -r '.data.lxc.stopped   // 0' 2>/dev/null)
    _stor_ok=$(echo "${_res_buf}"         | "${JQ}" -r '.data.storages.available // 0' 2>/dev/null)
    _stor_unk=$(echo "${_res_buf}"        | "${JQ}" -r '.data.storages.unknown   // 0' 2>/dev/null)
    _sdn_avail=$(echo "${_res_buf}"       | "${JQ}" -r '.data.sdn_zones.available // 0' 2>/dev/null)
    _sdn_error=$(echo "${_res_buf}"       | "${JQ}" -r '.data.sdn_zones.error     // 0' 2>/dev/null)
    _sdn_pending=$(echo "${_res_buf}"     | "${JQ}" -r '.data.sdn_zones.pending   // 0' 2>/dev/null)
    _pbs_online=$(echo "${_res_buf}"      | "${JQ}" -r '.data.pbs_nodes.online    // 0' 2>/dev/null)
    _pbs_offline=$(echo "${_res_buf}"     | "${JQ}" -r '.data.pbs_nodes.offline   // 0' 2>/dev/null)
    _pve_cpu_used=$(echo "${_res_buf}"    | "${JQ}" -r '.data.pve_cpu_stats.used  // 0' 2>/dev/null)
    _pve_cpu_max=$(echo "${_res_buf}"     | "${JQ}" -r '.data.pve_cpu_stats.max   // 0' 2>/dev/null)
    _pve_mem_used=$(echo "${_res_buf}"    | "${JQ}" -r '.data.pve_memory_stats.used // 0' 2>/dev/null)
    _pve_mem_max=$(echo "${_res_buf}"     | "${JQ}" -r '.data.pve_memory_stats.max  // 0' 2>/dev/null)
    _pve_stor_used=$(echo "${_res_buf}"   | "${JQ}" -r '.data.pve_storage_stats.used // 0' 2>/dev/null)
    _pve_stor_max=$(echo "${_res_buf}"    | "${JQ}" -r '.data.pve_storage_stats.max  // 0' 2>/dev/null)

    _res_state="${status_ok}"
    _res_any_crit=0; _res_any_warn=0

    if [[ "${_failed_remotes}" -ge "${crit_failed_remotes}" ]] 2>/dev/null && \
       [[ "${_failed_remotes}" -gt 0 ]]; then
        _res_state="${status_crit}"; (( _res_any_crit++ ))
        pdm_problem_output+="${status_crit} - ${_failed_remotes} remote(s) failed\n"
    elif [[ "${_failed_remotes}" -ge "${warn_failed_remotes}" ]] 2>/dev/null && \
         [[ "${_failed_remotes}" -gt 0 ]]; then
        _res_state="${status_warn}"; (( _res_any_warn++ ))
        pdm_problem_output+="${status_warn} - ${_failed_remotes} remote(s) failed\n"
    fi

    if [[ "${_pve_offline}" -gt 0 ]] 2>/dev/null; then
        [[ "${_res_state}" != "${status_crit}" ]] && { _res_state="${status_crit}"; (( _res_any_crit++ )); }
        pdm_problem_output+="${status_crit} - ${_pve_offline} PVE node(s) offline\n"
    fi

    if [[ "${_sdn_error}" -gt 0 ]] 2>/dev/null; then
        [[ "${_res_state}" != "${status_crit}" ]] && { _res_state="${status_crit}"; (( _res_any_crit++ )); }
        pdm_problem_output+="${status_crit} - ${_sdn_error} SDN zone(s) in error state\n"
    elif [[ "${_sdn_pending}" -gt 0 ]] 2>/dev/null; then
        [[ "${_res_state}" == "${status_ok}" ]] && { _res_state="${status_warn}"; (( _res_any_warn++ )); }
        pdm_problem_output+="${status_warn} - ${_sdn_pending} SDN zone(s) pending (config not applied)\n"
    fi

    if [[ "${_res_any_crit}" -gt 0 ]]; then
        pdm_output+="${status_crit} - Resources: ${_pve_offline} node(s) offline, ${_failed_remotes} remote(s) failed\n"
    elif [[ "${_res_any_warn}" -gt 0 ]]; then
        pdm_output+="${status_warn} - Resources: ${_failed_remotes} remote(s) failed${_sdn_pending:+, ${_sdn_pending} SDN zone(s) pending}\n"
    else
        pdm_output+="${status_ok} - Resources: ${_pve_online} node(s) online | ${_qemu_running} VM(s) running | ${_lxc_running} CT(s) running\n"
    fi

    if [[ -n "${verbose}" ]]; then
        pdm_output+="${status_ok} -   PVE Nodes: ${_pve_online} online, ${_pve_offline} offline, ${_pve_unknown} unknown\n"
        pdm_output+="${status_ok} -   VMs (QEMU): ${_qemu_running} running, ${_qemu_stopped} stopped\n"
        pdm_output+="${status_ok} -   Containers (LXC): ${_lxc_running} running, ${_lxc_stopped} stopped\n"
        pdm_output+="${status_ok} -   Storage: ${_stor_ok} available, ${_stor_unk} unknown\n"
        _sdn_total=$(( _sdn_avail + _sdn_error + _sdn_pending ))
        [[ "${_sdn_total}" -gt 0 ]] && \
            pdm_output+="${_res_state} -   SDN Zones: ${_sdn_avail} available, ${_sdn_pending} pending, ${_sdn_error} error\n"
        [[ $(( _pbs_online + _pbs_offline )) -gt 0 ]] && \
            pdm_output+="${status_ok} -   PBS Nodes: ${_pbs_online} online, ${_pbs_offline} offline\n"
        if [[ "${_pve_cpu_max}" -gt 0 ]] 2>/dev/null; then
            _pve_cpu_pct=$(echo "${_pve_cpu_used} ${_pve_cpu_max}" | "${AWK}" '{printf "%.1f", $1/$2*100}')
            pdm_output+="${status_ok} -   Aggregate CPU: ${_pve_cpu_pct}% (${_pve_cpu_used} / ${_pve_cpu_max} cores)\n"
        fi
        if [[ "${_pve_mem_max}" -gt 0 ]] 2>/dev/null; then
            _pve_mem_pct=$(echo "${_pve_mem_used} ${_pve_mem_max}" | "${AWK}" '{printf "%d", $1/$2*100}')
            pdm_output+="${status_ok} -   Aggregate Memory: $(_fmt_bytes "${_pve_mem_used}") / $(_fmt_bytes "${_pve_mem_max}") (${_pve_mem_pct}%)\n"
        fi
        if [[ "${_pve_stor_max}" -gt 0 ]] 2>/dev/null; then
            _pve_stor_pct=$(echo "${_pve_stor_used} ${_pve_stor_max}" | "${AWK}" '{printf "%d", $1/$2*100}')
            pdm_output+="${status_ok} -   Aggregate Storage: $(_fmt_bytes "${_pve_stor_used}") / $(_fmt_bytes "${_pve_stor_max}") (${_pve_stor_pct}%)\n"
        fi
    fi

    pdm_perf+=" pve_nodes_online=${_pve_online} pve_nodes_offline=${_pve_offline}"
    pdm_perf+=" qemu_running=${_qemu_running} qemu_stopped=${_qemu_stopped}"
    pdm_perf+=" lxc_running=${_lxc_running} lxc_stopped=${_lxc_stopped}"
    pdm_perf+=" failed_remotes=${_failed_remotes};${warn_failed_remotes};${crit_failed_remotes};0"
    pdm_perf+=" sdn_zones_avail=${_sdn_avail} sdn_zones_pending=${_sdn_pending} sdn_zones_error=${_sdn_error}"
    [[ "${_pve_cpu_max}" -gt 0 ]] 2>/dev/null && \
        pdm_perf+=" pve_cpu_used=${_pve_cpu_used} pve_cpu_max=${_pve_cpu_max}"
    [[ "${_pve_mem_max}" -gt 0 ]] 2>/dev/null && \
        pdm_perf+=" pve_mem_used=${_pve_mem_used} pve_mem_max=${_pve_mem_max}"
    [[ "${_pve_stor_max}" -gt 0 ]] 2>/dev/null && \
        pdm_perf+=" pve_stor_used=${_pve_stor_used} pve_stor_max=${_pve_stor_max}"

    [[ -n "${verbose}" ]] && pdm_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# HELPER: guest check loop (shared by -eVM and -eCT)
# _g_type_filter: "pve-qemu" or "pve-lxc"
# _g_label: "VM" or "CT"
# _g_filter: vmid or name to select single guest
# _g_blacklist: comma-separated blacklist
# _g_warn_stopped / _g_crit_stopped: flags
# ---------------------------------------------------------------------------
_check_guests() {
    local _g_type_filter="${1}"
    local _g_label="${2}"
    local _g_filter="${3}"
    local _g_blacklist="${4}"
    local _g_warn_stopped="${5}"
    local _g_crit_stopped="${6}"

    local _rlist_buf
    _rlist_buf=$(cat "${_pf}/resources_list.json" 2>/dev/null)

    declare -A _g_bl_map=()
    if [[ -n "${_g_blacklist}" ]]; then
        IFS=',' read -ra _g_bl_arr <<< "${_g_blacklist}"
        for _e in "${_g_bl_arr[@]}"; do _g_bl_map["${_e// /}"]=1; done
    fi

    local _g_any_warn=0 _g_any_crit=0 _g_total=0
    local _g_detail_lines=""

    while IFS=$'\t' read -r _gr _gname _gvmid _gnode _gstatus _gcpu _gmem _gmaxmem _gdisk _gmaxdisk; do
        [[ -z "${_gvmid}" ]] && continue
        [[ -n "${_g_bl_map[${_gvmid}]:-}" || -n "${_g_bl_map[${_gname}]:-}" ]] && continue
        [[ -n "${remote_filter}" && "${_gr}" != "${remote_filter}" ]] && continue
        if [[ -n "${_g_filter}" ]]; then
            [[ "${_gvmid}" != "${_g_filter}" && "${_gname}" != "${_g_filter}" ]] && continue
        fi
        (( _g_total++ ))

        local _g_state="${status_ok}"
        local _g_cpu_pct
        _g_cpu_pct=$(echo "${_gcpu}" | "${AWK}" '{printf "%d", $1*100}')
        local _g_mem_pct=0
        [[ "${_gmaxmem}" -gt 0 ]] 2>/dev/null && \
            _g_mem_pct=$(( _gmem * 100 / _gmaxmem ))
        local _g_disk_pct=0
        [[ "${_gmaxdisk}" -gt 0 ]] 2>/dev/null && \
            _g_disk_pct=$(( _gdisk * 100 / _gmaxdisk ))
        local _glbl="${_g_label} ${_gvmid}/${_gname} (${_gr}/${_gnode})"

        case "${_gstatus}" in
            running) ;;
            stopped)
                if [[ -n "${_g_crit_stopped}" ]]; then
                    _g_state="${status_crit}"; (( _g_any_crit++ ))
                    pdm_problem_output+="${status_crit} - ${_glbl}: stopped\n"
                elif [[ -n "${_g_warn_stopped}" ]]; then
                    _g_state="${status_warn}"; (( _g_any_warn++ ))
                    pdm_problem_output+="${status_warn} - ${_glbl}: stopped\n"
                fi
                ;;
            *)
                _g_state="${status_warn}"; (( _g_any_warn++ ))
                pdm_problem_output+="${status_warn} - ${_glbl}: ${_gstatus}\n"
                ;;
        esac

        if [[ "${_gstatus}" == "running" ]]; then
            if [[ "${_g_cpu_pct}" -ge "${crit_guest_cpu}" ]] 2>/dev/null; then
                [[ "${_g_state}" != "${status_crit}" ]] && { _g_state="${status_crit}"; (( _g_any_crit++ )); }
                pdm_problem_output+="${status_crit} - ${_glbl}: CPU ${_g_cpu_pct}% >= ${crit_guest_cpu}%\n"
            elif [[ "${_g_cpu_pct}" -ge "${warn_guest_cpu}" ]] 2>/dev/null; then
                [[ "${_g_state}" == "${status_ok}" ]] && { _g_state="${status_warn}"; (( _g_any_warn++ )); }
                pdm_problem_output+="${status_warn} - ${_glbl}: CPU ${_g_cpu_pct}% >= ${warn_guest_cpu}%\n"
            fi
            if [[ "${_g_mem_pct}" -ge "${crit_guest_mem}" ]] 2>/dev/null; then
                [[ "${_g_state}" != "${status_crit}" ]] && { _g_state="${status_crit}"; (( _g_any_crit++ )); }
                pdm_problem_output+="${status_crit} - ${_glbl}: Memory ${_g_mem_pct}% >= ${crit_guest_mem}%\n"
            elif [[ "${_g_mem_pct}" -ge "${warn_guest_mem}" ]] 2>/dev/null; then
                [[ "${_g_state}" == "${status_ok}" ]] && { _g_state="${status_warn}"; (( _g_any_warn++ )); }
                pdm_problem_output+="${status_warn} - ${_glbl}: Memory ${_g_mem_pct}% >= ${warn_guest_mem}%\n"
            fi
        fi

        local _g_detail_str=""
        if [[ "${_gstatus}" == "running" ]]; then
            _g_detail_str=" CPU: ${_g_cpu_pct}% | Mem: ${_g_mem_pct}%"
            [[ "${_gmaxdisk}" -gt 0 ]] && _g_detail_str+=" | Disk: ${_g_disk_pct}%"
        fi

        if [[ -n "${_g_filter}" ]]; then
            # Single-guest selection: always show detail line
            pdm_output+="${_g_state} - ${_g_label} ${_gvmid} ${_gname} (${_gr}/${_gnode}): ${_gstatus}${_g_detail_str}\n"
        elif [[ -n "${verbose}" ]]; then
            _g_detail_lines+="${_g_state} -   ${_g_label} ${_gvmid} ${_gname} (${_gr}/${_gnode}): ${_gstatus}${_g_detail_str}\n"
        fi

        local _g_lbl_perf="${_gvmid}_${_gname//[^a-zA-Z0-9]/_}"
        pdm_perf+=" guest_${_g_lbl_perf}_cpu=${_g_cpu_pct}%;${warn_guest_cpu};${crit_guest_cpu};0;100"
        pdm_perf+=" guest_${_g_lbl_perf}_mem=${_g_mem_pct}%;${warn_guest_mem};${crit_guest_mem};0;100"

    done < <(echo "${_rlist_buf}" | "${JQ}" -r --arg t "${_g_type_filter}" '
        .data[]? | .remote as $r | .resources[]? |
        select(.type == $t) |
        [$r, (.name // ""), ((.vmid // 0) | tostring), (.node // ""), (.status // "unknown"),
         ((.cpu // 0) | tostring), ((.mem // 0) | tostring), ((.maxmem // 0) | tostring),
         ((.disk // 0) | tostring), ((.maxdisk // 0) | tostring)] | join("\t")' 2>/dev/null)

    [[ -n "${verbose}" ]] && pdm_output+="${_g_detail_lines}"

    if [[ -n "${_g_filter}" && "${_g_total}" -eq 0 ]]; then
        pdm_output+="${status_unknown} - ${_g_label}: '${_g_filter}' not found\n"
    elif [[ -z "${_g_filter}" ]]; then
        if [[ "${_g_any_crit}" -gt 0 ]]; then
            pdm_output+="${status_crit} - ${_g_label}s: ${_g_total} total, ${_g_any_crit} critical\n"
        elif [[ "${_g_any_warn}" -gt 0 ]]; then
            pdm_output+="${status_warn} - ${_g_label}s: ${_g_total} total, ${_g_any_warn} warning(s)\n"
        else
            pdm_output+="${status_ok} - ${_g_label}s: ${_g_total} total, all running\n"
        fi
    fi

    unset _g_bl_map
}

# ---------------------------------------------------------------------------
# -eVM: Virtual machine status
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_vm}" || -n "${enable_all}" ) && -z "${disable_vm}" ]]; then
    [[ -n "${verbose}" && -z "${vm_filter}" ]] && pdm_output+="Virtual Machines:\n---------------------------------------\n"
    _check_guests "pve-qemu" "VM" "${vm_filter}" "${vm_blacklist}" "${warn_stopped_vm}" "${crit_stopped_vm}"
    [[ -n "${verbose}" && -z "${vm_filter}" ]] && pdm_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eCT: Container status
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_ct}" || -n "${enable_all}" ) && -z "${disable_ct}" ]]; then
    [[ -n "${verbose}" && -z "${ct_filter}" ]] && pdm_output+="Containers:\n---------------------------------------\n"
    _check_guests "pve-lxc" "CT" "${ct_filter}" "${ct_blacklist}" "${warn_stopped_ct}" "${crit_stopped_ct}"
    [[ -n "${verbose}" && -z "${ct_filter}" ]] && pdm_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eSub: Subscription status
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_sub}" || -n "${enable_all}" ) && -z "${disable_sub}" ]]; then
    [[ -n "${verbose}" ]] && pdm_output+="Subscriptions:\n---------------------------------------\n"

    _sub_any_warn=0; _sub_any_crit=0
    _now=$(date +%s)

    if [[ "${_pdm_node_avail}" -eq 0 ]]; then
        [[ -n "${verbose}" ]] && pdm_output+="${status_unknown} -   PDM (${_pdm_node}): subscription check unavailable (API tokens cannot access /nodes; use password auth)\n"
    else
    _lsub_buf=$(cat "${_pf}/node_sub.json" 2>/dev/null)
    _lsub_status=$(echo "${_lsub_buf}" | "${JQ}" -r '.data.status // "Unknown"' 2>/dev/null)
    _lsub_due=$(echo "${_lsub_buf}"    | "${JQ}" -r '.data.nextduedate // ""'   2>/dev/null)
    _lsub_name=$(echo "${_lsub_buf}"   | "${JQ}" -r '.data.productname // ""'   2>/dev/null)

    _lsub_state="${status_ok}"
    case "${_lsub_status,,}" in
        active)
            if [[ -n "${_lsub_due}" ]]; then
                _lsub_due_ts=$(date -d "${_lsub_due}" +%s 2>/dev/null || echo 0)
                _lsub_days=$(( (_lsub_due_ts - _now) / 86400 ))
                if [[ "${_lsub_days}" -le "${crit_sub_days}" ]] 2>/dev/null; then
                    _lsub_state="${status_crit}"; (( _sub_any_crit++ ))
                    pdm_problem_output+="${status_crit} - PDM subscription expiring in ${_lsub_days}d (${_lsub_due})\n"
                elif [[ "${_lsub_days}" -le "${warn_sub_days}" ]] 2>/dev/null; then
                    _lsub_state="${status_warn}"; (( _sub_any_warn++ ))
                    pdm_problem_output+="${status_warn} - PDM subscription expiring in ${_lsub_days}d (${_lsub_due})\n"
                fi
                [[ -n "${verbose}" ]] && \
                    pdm_output+="${_lsub_state} -   PDM (${_pdm_node}): Active${_lsub_due:+ (expires ${_lsub_due}, ${_lsub_days}d left)}${_lsub_name:+ -- ${_lsub_name}}\n"
            else
                [[ -n "${verbose}" ]] && \
                    pdm_output+="${status_ok} -   PDM (${_pdm_node}): Active${_lsub_name:+ -- ${_lsub_name}}\n"
            fi
            ;;
        notfound|none|"")
            if [[ -z "${ignore_no_sub}" ]]; then
                _lsub_state="${status_warn}"; (( _sub_any_warn++ ))
                pdm_problem_output+="${status_warn} - PDM (${_pdm_node}): no subscription\n"
            fi
            [[ -n "${verbose}" ]] && pdm_output+="${_lsub_state} -   PDM (${_pdm_node}): no subscription\n"
            ;;
        *)
            _lsub_state="${status_crit}"; (( _sub_any_crit++ ))
            pdm_problem_output+="${status_crit} - PDM (${_pdm_node}): subscription ${_lsub_status}\n"
            [[ -n "${verbose}" ]] && pdm_output+="${_lsub_state} -   PDM (${_pdm_node}): ${_lsub_status}\n"
            ;;
    esac
    fi  # _pdm_node_avail

    _rsub_buf=$(cat "${_pf}/resources_sub.json" 2>/dev/null)
    while IFS=$'\t' read -r _rsname _rsstate _rserr; do
        [[ -z "${_rsname}" ]] && continue
        _rs_st="${status_ok}"
        case "${_rsstate,,}" in
            active) ;;
            mixed)
                _rs_st="${status_warn}"; (( _sub_any_warn++ ))
                pdm_problem_output+="${status_warn} - Remote ${_rsname}: subscription Mixed${_rserr:+ (${_rserr})}\n"
                ;;
            none|notfound|"")
                if [[ -z "${ignore_no_sub}" ]]; then
                    _rs_st="${status_warn}"; (( _sub_any_warn++ ))
                    pdm_problem_output+="${status_warn} - Remote ${_rsname}: no subscription\n"
                fi
                ;;
            *)
                _rs_st="${status_crit}"; (( _sub_any_crit++ ))
                pdm_problem_output+="${status_crit} - Remote ${_rsname}: subscription ${_rsstate}${_rserr:+ (${_rserr})}\n"
                ;;
        esac
        [[ -n "${verbose}" ]] && pdm_output+="${_rs_st} -   Remote ${_rsname}: ${_rsstate:-Unknown}\n"
    done < <(echo "${_rsub_buf}" | "${JQ}" -r '
        .data[]? | [
            (.remote // ""),
            (.state  // ""),
            (.error  // "")
        ] | join("\t")' 2>/dev/null)

    if [[ "${_sub_any_crit}" -gt 0 ]]; then
        pdm_output+="${status_crit} - Subscriptions: ${_sub_any_crit} critical\n"
    elif [[ "${_sub_any_warn}" -gt 0 ]]; then
        pdm_output+="${status_warn} - Subscriptions: ${_sub_any_warn} warning(s)\n"
    else
        pdm_output+="${status_ok} - Subscriptions: all active\n"
    fi

    [[ -n "${verbose}" ]] && pdm_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eUpdates: Package updates (PDM node + remote nodes via /remotes/updates/summary)
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_updates}" || -n "${enable_all}" ) && -z "${disable_updates}" ]]; then
    [[ -n "${verbose}" ]] && pdm_output+="Package Updates:\n---------------------------------------\n"
    _ubuf=$(cat "${_pf}/node_updates.json" 2>/dev/null)
    _rubuf=$(cat "${_pf}/remote_updates.json" 2>/dev/null)

    # Detect if /remotes/updates/summary was accessible (needs more than Auditor role)
    _remote_upd_avail=1
    if [[ -z "${_rubuf}" ]] || ! echo "${_rubuf}" | "${JQ}" -e '.data' >/dev/null 2>&1; then
        _remote_upd_avail=0
    fi

    # PDM node updates
    _upd_total=$(echo "${_ubuf}" | "${JQ}" '[.data[]?] | length' 2>/dev/null)
    _upd_sec=$(echo "${_ubuf}"   | "${JQ}" '[.data[]? | select(.Priority=="security" or (.Package // "" | test("security";"i")))] | length' 2>/dev/null)
    _upd_total=${_upd_total:-0}; _upd_sec=${_upd_sec:-0}

    # Remote node updates
    _remupd_nodes=0
    _remupd_total=0
    _remupd_detail=""

    while IFS=$'\t' read -r _run_remote _run_node _run_count _run_pkgs; do
        [[ -z "${_run_node}" ]] && continue
        _run_count=${_run_count:-0}
        [[ "${_run_count}" -eq 0 ]] 2>/dev/null && continue
        (( _remupd_nodes++ ))
        (( _remupd_total += _run_count ))
        _remupd_detail+="${status_warn} -   ${_run_node} (${_run_remote}): ${_run_count} update(s)${_run_pkgs:+ -- ${_run_pkgs}}\n"
    done < <(echo "${_rubuf}" | "${JQ}" -r '
        .data.remotes // {} | to_entries[] |
        .key as $remote |
        .value.nodes // {} | to_entries[] |
        [$remote, .key,
         ((.value."number-of-updates" // 0) | tostring),
         (.value.versions // [] | map(.package + " " + .version) | join(", "))
        ] | join("\t")' 2>/dev/null)

    # Determine overall state
    _upd_state="${status_ok}"
    if [[ "${_upd_sec}" -ge "${crit_updates}" ]] 2>/dev/null && [[ "${_upd_sec}" -gt 0 ]]; then
        _upd_state="${status_crit}"
        pdm_problem_output+="${status_crit} - ${_upd_sec} security update(s) pending on ${_pdm_node}\n"
    elif [[ "${_upd_total}" -ge "${warn_updates}" ]] 2>/dev/null && [[ "${_upd_total}" -gt 0 ]]; then
        _upd_state="${status_warn}"
        pdm_problem_output+="${status_warn} - ${_upd_total} update(s) pending on ${_pdm_node}\n"
    fi
    if [[ "${_remupd_nodes}" -gt 0 ]]; then
        [[ "${_upd_state}" == "${status_ok}" ]] && _upd_state="${status_warn}"
        pdm_problem_output+="${status_warn} - ${_remupd_nodes} remote node(s) with ${_remupd_total} pending update(s)\n"
    fi

    # Summary line
    if [[ "${_upd_state}" == "${status_ok}" ]]; then
        if [[ "${_remote_upd_avail}" -eq 0 && "${_pdm_node_avail}" -eq 0 ]]; then
            pdm_output+="${status_unknown} - Updates: unavailable (API token cannot access /nodes or /remotes/updates/summary; use password auth or Administrator-role token)\n"
        elif [[ "${_remote_upd_avail}" -eq 0 ]]; then
            pdm_output+="${status_ok} - Updates: PDM node up to date (remote updates unavailable: token needs Administrator role)\n"
        else
            pdm_output+="${status_ok} - Updates: up to date\n"
        fi
    else
        _upd_parts=""
        [[ "${_upd_total}" -gt 0 ]] && _upd_parts+=" PDM: ${_upd_total} available${_upd_sec:+ (${_upd_sec} security)}"
        [[ "${_remupd_nodes}" -gt 0 ]] && _upd_parts+="${_upd_parts:+,} Remotes: ${_remupd_nodes} node(s) pending"
        pdm_output+="${_upd_state} - Updates:${_upd_parts}\n"
    fi

    if [[ -n "${verbose}" ]]; then
        if [[ "${_pdm_node_avail}" -eq 1 && "${_upd_total}" -gt 0 ]]; then
            while IFS=$'\t' read -r _upkg _uver _upri; do
                [[ -z "${_upkg}" ]] && continue
                _upd_lbl="${status_warn}"
                [[ "${_upri,,}" == "security" ]] && _upd_lbl="${status_crit}"
                pdm_output+="${_upd_lbl} -   ${_pdm_node}: ${_upkg} ${_uver}${_upri:+ [${_upri}]}\n"
            done < <(echo "${_ubuf}" | "${JQ}" -r '
                .data[]? | [
                    (.Package  // ""),
                    (.Version  // ""),
                    (.Priority // "")
                ] | join("\t")' 2>/dev/null)
        fi
        if [[ "${_remote_upd_avail}" -eq 0 ]]; then
            pdm_output+="${status_unknown} -   Remote updates: unavailable (/remotes/updates/summary requires Administrator-role token or password auth)\n"
        else
            pdm_output+="${_remupd_detail}"
        fi
    fi

    pdm_perf+=" updates_total=${_upd_total};${warn_updates};;0 updates_security=${_upd_sec};${crit_updates};;0"
    pdm_perf+=" updates_remote_nodes=${_remupd_nodes} updates_remote_total=${_remupd_total}"
    [[ -n "${verbose}" ]] && pdm_output+="---------------------------------------\n\n"
fi

# ---------------------------------------------------------------------------
# -eTasks: Task log -- NOT included in -eAll
# ---------------------------------------------------------------------------
if [[ -n "${enable_tasks}" ]]; then
    if [[ "${_pdm_node_avail}" -eq 0 ]]; then
        [[ "${_node_unavail_shown}" -eq 0 ]] && { pdm_output+="${_node_unavail_msg}"; _node_unavail_shown=1; }
    else
    [[ -n "${verbose}" ]] && pdm_output+="Task Log (last ${taskcheck_time}):\n---------------------------------------\n"

    _task_warn=0; _task_crit=0; _task_ok=0

    _tbuf=$(cat "${_pf}/node_tasks.json" 2>/dev/null)
    while IFS=$'\t' read -r _ttype _tstatus _tstart _tend; do
        [[ -z "${_ttype}" ]] && continue
        [[ "${_tend}" == "0" || -z "${_tend}" ]] && continue
        case "${_tstatus}" in
            OK|ok)
                (( _task_ok++ ))
                ;;
            *WARN*|*warn*|WARNING|warning)
                (( _task_warn++ ))
                [[ -n "${verbose}" ]] && \
                    pdm_output+="${status_warn} -   ${_pdm_node} task ${_ttype} ($(date -d "@${_tstart}" '+%Y-%m-%d %H:%M' 2>/dev/null)): ${_tstatus}\n"
                ;;
            *)
                (( _task_crit++ ))
                [[ -n "${verbose}" ]] && \
                    pdm_output+="${status_crit} -   ${_pdm_node} task ${_ttype} ($(date -d "@${_tstart}" '+%Y-%m-%d %H:%M' 2>/dev/null)): ${_tstatus}\n"
                ;;
        esac
    done < <(echo "${_tbuf}" | "${JQ}" -r '
        .data[]? | [
            (.type      // ""),
            (.status    // ""),
            ((.starttime // 0) | tostring),
            ((.endtime   // 0) | tostring)
        ] | join("\t")' 2>/dev/null)

    _rtbuf=$(cat "${_pf}/remote_tasks_stats.json" 2>/dev/null)
    if [[ -n "${_rtbuf}" ]]; then
        _rt_failed=$(echo "${_rtbuf}" | "${JQ}" -r '
            .data."by-remote" | to_entries | map(.value.error // 0) | add // 0' 2>/dev/null)
        _rt_warn=$(echo "${_rtbuf}"   | "${JQ}" -r '
            .data."by-remote" | to_entries | map(.value.warning // 0) | add // 0' 2>/dev/null)
        _rt_done=$(echo "${_rtbuf}"   | "${JQ}" -r '
            .data."by-remote" | to_entries | map(.value.ok // 0) | add // 0' 2>/dev/null)
        [[ "${_rt_failed}" =~ ^[0-9]+$ ]] && (( _task_crit += _rt_failed ))
        [[ "${_rt_warn}" =~ ^[0-9]+$ ]]   && (( _task_warn += _rt_warn ))
        [[ "${_rt_done}" =~ ^[0-9]+$ ]]   && (( _task_ok += _rt_done ))
        [[ -n "${verbose}" && ( "${_rt_failed}" -gt 0 || "${_rt_warn}" -gt 0 ) ]] && \
            pdm_output+="${status_warn} -   Remote tasks: ${_rt_failed} failed, ${_rt_warn} warnings (last aggregation)\n"
    fi

    _task_total=$(( _task_ok + _task_warn + _task_crit ))
    if [[ "${_task_crit}" -ge "${crit_tasks}" ]] 2>/dev/null && [[ "${_task_crit}" -gt 0 ]]; then
        pdm_output+="${status_crit} - Task log: ${_task_crit} failed task(s) in last ${taskcheck_time} (${_task_total} checked)\n"
        pdm_problem_output+="${status_crit} - ${_task_crit} failed task(s) in last ${taskcheck_time}\n"
    elif [[ "${_task_warn}" -ge "${warn_tasks}" ]] 2>/dev/null && [[ "${_task_warn}" -gt 0 ]]; then
        pdm_output+="${status_warn} - Task log: ${_task_warn} warning task(s) in last ${taskcheck_time} (${_task_total} checked)\n"
        pdm_problem_output+="${status_warn} - ${_task_warn} warning task(s) in last ${taskcheck_time}\n"
    else
        pdm_output+="${status_ok} - Task log: no errors/warnings in last ${taskcheck_time} (${_task_total} tasks checked)\n"
    fi
    pdm_perf+=" tasks_ok=${_task_ok} tasks_warn=${_task_warn} tasks_crit=${_task_crit}"
    [[ -n "${verbose}" ]] && pdm_output+="---------------------------------------\n\n"
    fi  # _pdm_node_avail
fi

# ---------------------------------------------------------------------------
# -eCerts: Certificate expiry
# ---------------------------------------------------------------------------
if [[ ( -n "${enable_certs}" || -n "${enable_all}" ) && -z "${disable_certs}" ]]; then
    if [[ "${_pdm_node_avail}" -eq 0 ]]; then
        [[ "${_node_unavail_shown}" -eq 0 ]] && { pdm_output+="${_node_unavail_msg}"; _node_unavail_shown=1; }
    else
    [[ -n "${verbose}" ]] && pdm_output+="Certificates:\n---------------------------------------\n"
    _cbuf=$(cat "${_pf}/node_certs.json" 2>/dev/null)
    _cert_any_warn=0; _cert_any_crit=0
    _now=$(date +%s)

    while IFS=$'\t' read -r _cname _cexpiry _csubject; do
        [[ -z "${_cname}" || "${_cexpiry}" == "0" || -z "${_cexpiry}" ]] && continue
        _cdays=$(( (_cexpiry - _now) / 86400 ))
        _c_state="${status_ok}"
        if [[ "${_cdays}" -le "${crit_cert}" ]] 2>/dev/null; then
            _c_state="${status_crit}"; (( _cert_any_crit++ ))
            pdm_problem_output+="${status_crit} - Cert ${_cname}: expires in ${_cdays}d (<= ${crit_cert}d)\n"
        elif [[ "${_cdays}" -le "${warn_cert}" ]] 2>/dev/null; then
            _c_state="${status_warn}"; (( _cert_any_warn++ ))
            pdm_problem_output+="${status_warn} - Cert ${_cname}: expires in ${_cdays}d (<= ${warn_cert}d)\n"
        fi
        [[ -n "${verbose}" ]] && \
            pdm_output+="${_c_state} -   Cert ${_cname}: ${_cdays}d left ($(date -d "@${_cexpiry}" '+%Y-%m-%d' 2>/dev/null))\n"
        pdm_perf+=" cert_${_cname//[^a-zA-Z0-9_]/_}_days=${_cdays};${warn_cert};${crit_cert};0"
    done < <(echo "${_cbuf}" | "${JQ}" -r '
        .data[]? | [
            (.filename  // ""),
            ((.notafter // 0) | tostring),
            (.subject   // "")
        ] | join("\t")' 2>/dev/null)

    if [[ "${_cert_any_crit}" -gt 0 ]]; then
        pdm_output+="${status_crit} - Certificates: ${_cert_any_crit} expiring critically\n"
    elif [[ "${_cert_any_warn}" -gt 0 ]]; then
        pdm_output+="${status_warn} - Certificates: ${_cert_any_warn} expiring soon\n"
    else
        pdm_output+="${status_ok} - Certificates: all valid\n"
    fi
    [[ -n "${verbose}" ]] && pdm_output+="---------------------------------------\n\n"
    fi  # _pdm_node_avail
fi

# ---------------------------------------------------------------------------
# Determine exit state and build output
# ---------------------------------------------------------------------------
_exit_code=0
if echo -e "${pdm_problem_output}" | grep -q "^\[CRITICAL\]"; then
    _exit_code=2
elif echo -e "${pdm_problem_output}" | grep -q "^\[WARNING\]"; then
    _exit_code=1
fi

_sep="---------------------------------------\n"
_perf="${no_perfdata:+}"; [[ -z "${no_perfdata}" && -n "${pdm_perf}" ]] && _perf="|${pdm_perf# }"

if [[ -n "${silent}" ]]; then
    if [[ -n "${pdm_problem_output}" ]]; then
        printf '%b' "One or more Problems detected:\n${_sep}${pdm_problem_output}"
    else
        printf 'All Services OK\n'
    fi
elif [[ -n "${pdm_problem_output}" ]]; then
    printf '%b' "One or more Problems detected:\n${_sep}${pdm_problem_output}${_sep}\nAll Services:\n${_sep}${pdm_output}"
else
    printf '%b' "All Services OK\n\n${pdm_output}"
fi

[[ -n "${_perf}" ]] && echo "${_perf}"

exit "${_exit_code}"
