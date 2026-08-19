#!/bin/sh

program='hetzner_ddns'
version='1.1.1'
upstream='https://github.com/filiparag/hetzner_ddns'
update_api='https://api.github.com/repos/filiparag/hetzner_ddns/releases/latest'
detach=0
verbose=0
cfg_file="/usr/local/etc/${program}.json"
pid_file="/var/run/${program}.pid"

# User-modifiable settings
conf_log_file=
conf_log_level='INFO'
conf_ip_check_cooldown=30
conf_request_timeout=10
conf_api_url='https://api.hetzner.cloud/v1'
conf_ip_url='https://ip.hetzner.com/'
conf_check_updates=0
conf_auto_create_records=0
conf_ipv6_event_monitor='true'
conf_ipv6_event_cooldown=10
conf_ipv6_event_require_global='true'

log() {
    level='INFO'
    message="$1"
    if [ "$#" -ge 2 ]; then
        level="$1"
        message="$2"
    else
        case "$message" in
            Error:*)
                level='ERROR'
                message="${message#Error: }";;
            Warning:*)
                level='WARN'
                message="${message#Warning: }";;
        esac
    fi
    if [ "$conf_log_level" = 'NONE' ]; then
        return
    elif [ "$conf_log_level" = 'ERROR' ]; then
        if [ "$level" != 'ERROR' ]; then
            return
        fi
    elif [ "$conf_log_level" = 'WARN' ]; then
        if [ "$level" != 'ERROR' ] && [ "$level" != 'WARN' ]; then
            return
        fi
    fi
    if test -r "$conf_log_file"; then
        printf '[%s] %s %s\n' "$(date +"%Y-%m-%dT%H:%M:%S%z")" "$level" "$message" >> "$conf_log_file"
    fi
    if [ "$verbose" = 1 ]; then
        >&2 printf '[%s] %s %s\n' "$(date +"%Y-%m-%dT%H:%M:%S%z")" "$level" "$message"
    fi
}

create_log_file() {
    if [ -z "$conf_log_file" ]; then
        return
    fi
    if install -m 644 /dev/null "$conf_log_file" 1>/dev/null 2>/dev/null; then
        log "Using log file '$conf_log_file'"
    else
        log "Warning: Unable to use log file '$conf_log_file'"
    fi
}

test_dependencies() {
    for d in awk curl cut getopts jq mkfifo mktemp netstat ifconfig sed sort uniq touch uname cat tr wc; do
        if ! command -v "$d" 1> /dev/null 2> /dev/null; then
            echo "Error: Missing dependency '$d'"
            return 1
        fi
    done
}

parse_cli_args() {
    while getopts c:l:L:P:vVdh opt; do
        case "$opt" in
            c)
                cfg_file="$OPTARG";;
            l)
                conf_log_file="$OPTARG";;
            L)
                conf_log_level_override="$OPTARG";;
            P)
                pid_file="$OPTARG";;
            v)
                display_version;
                exit 0;;
            V)
                verbose=1;;
            d)
                detach=1;;
            h)
                display_version;
                display_help;
                exit 0;;
            *)  exit 1;;
        esac
    done
    shift "$((OPTIND - 1))"
}

display_version() {
    echo "$program $version - Hetzner Dynamic DNS Daemon"
}

display_help() {
    echo '
Options:

    -c <file>   Use specified configuration file
    -l <file>   Use specified log file
    -L <level>  Log level (info, warn, error, none)
    -P <file>   Use specified PID file when daemonized
    -V          Display all log messages to stderr
    -d          Detach from current shell and run as a daemon
    -h          Print help and exit
    -v          Print version and exit
'
echo '
Configuration:

    "api_key": Read-write API key (64 characters) or an absolute file path containing it

    "settings": {
      "log_file": Path to a custom configuration file
      "log_level": Log level (info, warn, error, none)
      "ip_check_cooldown": Time between subsequent checks of interface'\''s IP address
      "request_timeout": Maximum duration of HTTP requests
      "api_url": URL of the Hetzner Console'\''s API
      "ip_url": URL of a service for retrieving external IP addresses
      "check_updates": Check for program updates on GitHub (default: false)
      "auto_create_records": Automatically create missing DNS records (default: false)
      "ipv6_event_monitor": Enable immediate IPv6-triggered updates on Linux (true/false)
      "ipv6_event_cooldown": Minimal number of seconds between IPv6 event triggers
      "ipv6_event_require_global": React only to global IPv6 addresses (true/false)
    }

    "defaults": {
      "type": Default record type (can be "A", "AAAA", or "A/AAAA")
      "interface": Default network interface name (auto-detect if unspecified)
      "ttl": Default TTL value in seconds (60 <= TTL <= 2147483647)
    }

    "zones": [
      {
        "domain": Domain name of a zone
        "records": [
          {
            "name": Name of the record (use @ for domain'\''s root)
            "type": Override of the default record type
            "ttl": Override of the default TTL
            "interface": Override of the default interface
          }
        ]
      }
    ]
'
echo '
Usage:

    Run on startup
        service hetzner_ddns enable

    Start
        service hetzner_ddns start

    Stop
        service hetzner_ddns stop

    Trigger update of all records
        service hetzner_ddns reload
'
}

test_cfg_file() {
    # Test if file exists
    if ! test -f "$cfg_file"; then
        log "Error: Configuration file '$cfg_file' not found"
        return 1
    fi
    if ! test -r "$cfg_file"; then
        log 'Error: Configuration file is not readable'
        return 1
    fi
    # Check version
    version_major="$(jq -r '.version | split(".") | .[0]' "$cfg_file")"
    if [ "$version_major" -ne 1 ] ; then
        log 'Error: Incompatible configuration file version'
        return 1
    fi
    log "Using configuration file '$cfg_file'"
}

test_pid_file() {
    if [ "$detach" = 1 ]; then
        # Test if file is writeable
        if ! touch "$pid_file" 1>/dev/null 2>/dev/null; then
            log "Error: Unable to open background process ID file '$pid_file'"
            return 1
        fi
    fi
}

check_daemon_already_running() {
    if [ "$detach" = 1 ]; then
        daemon_pid="$(cat "$pid_file")"
        if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 1>/dev/null 2>/dev/null; then
            log "Error: Another daemon is already running as process $daemon_pid"
            return 1
        fi
    fi
}

load_and_test_api_key() {
    api_key_field="$(jq -r '.api_key' "$cfg_file")"
    api_key_file_path="$(jq -r '.api_key_file' "$cfg_file")"
    api_key_source='inline'

    if [ -n "$api_key_file_path" ] && [ "$api_key_file_path" != 'null' ]; then
        if [ -n "$api_key_field" ] && [ "$api_key_field" != 'null' ]; then
            log 'ERROR' 'API key provided through BOTH config and file'
            return 1
        fi
        if [ ! -r "$api_key_file_path" ]; then
            log 'ERROR' "API key file '$api_key_file_path' is not readable"
            return 1
        fi
        api_key="$(tr -d '[:space:]' < "$api_key_file_path")"
        api_key_source='file'
    else
        if [ -z "$api_key_field" ] || [ "$api_key_field" = 'null' ]; then
            log 'ERROR' 'API key not provided'
            return 1
        fi
        if [ "$(printf '%s' "$api_key_field" | wc -m | tr -d '[:space:]')" = 64 ]; then
            api_key="$api_key_field"
        elif [ -r "$api_key_field" ]; then
            api_key="$(tr -d '[:space:]' < "$api_key_field")"
            api_key_source='file'
        else
            log 'ERROR' 'Invalid API key field format'
            return 1
        fi
    fi

    if [ "$(printf '%s' "$api_key" | wc -m | tr -d '[:space:]')" != 64 ]; then
        log 'ERROR' 'Invalid API key format'
        return 1
    fi
    if [ "$(curl \
            --connect-timeout "$conf_request_timeout" --max-time "$conf_request_timeout" \
            -H "Authorization: Bearer $api_key" \
            -I -w "%{http_code}" \
            -s -o /dev/null \
            "$conf_api_url/zones")" != 200 ]; then
        log 'ERROR' 'Provided API key is unauthorized'
        return 1
    fi
    if [ "$api_key_source" = 'file' ]; then
        log 'INFO' "Loaded valid API key from file: '$api_key_file_path'"
    else
        log 'INFO' 'Loaded valid API key from the configuration file'
    fi
}

load_settings() {
    if [ "$(jq -r '.settings' "$cfg_file")" != 'null' ]; then
        eval "$(jq -r '.settings | to_entries[] | "conf_\(.key)='\''\(.value|tostring)'\''"' "$cfg_file")"
        log 'Loaded user settings from configuration file'
    fi
    if [ -n "$conf_log_level_override" ]; then
        conf_log_level="$conf_log_level_override"
    fi
}

validate_settings() {
    case "$conf_log_level" in
        info|INFO|3)
            conf_log_level='INFO';;
        warn|warning|WARN|WARNING|2)
            conf_log_level='WARN';;
        error|ERROR|1)
            conf_log_level='ERROR';;
        none|NONE|false|FALSE|off|OFF|0)
            conf_log_level='NONE';;
        *)
            conf_log_level='INFO'
            log 'ERROR' 'Invalid log level, falling back to INFO';;
    esac
    log 'INFO' "Set log level to '$conf_log_level'"
    case "$conf_check_updates" in
        1|true|TRUE|yes|YES|on|ON)
            conf_check_updates=1
            log 'INFO' 'Program update checking is enabled';;
        *)
            conf_check_updates=0;;
    esac
    case "$conf_auto_create_records" in
        1|true|TRUE|yes|YES|on|ON)
            conf_auto_create_records=1
            log 'INFO' 'Automatic missing record creation is enabled';;
        *)
            conf_auto_create_records=0;;
    esac
    case "$conf_ipv6_event_monitor" in
        true|false) ;;
        *)
            conf_ipv6_event_monitor='false'
            log "Warning: Invalid value of ipv6_event_monitor, falling back to '$conf_ipv6_event_monitor'";;
    esac
    case "$conf_ipv6_event_require_global" in
        true|false) ;;
        *)
            conf_ipv6_event_require_global='true'
            log "Warning: Invalid value of ipv6_event_require_global, falling back to '$conf_ipv6_event_require_global'";;
    esac
    case "$conf_ipv6_event_cooldown" in
        *[!0-9]*|'')
            conf_ipv6_event_cooldown=10
            log "Warning: Invalid value of ipv6_event_cooldown, falling back to '$conf_ipv6_event_cooldown'";;
    esac
    if [ "$conf_ipv6_event_cooldown" -lt 1 ]; then
        conf_ipv6_event_cooldown=1
        log "Warning: Value of ipv6_event_cooldown too small, falling back to '$conf_ipv6_event_cooldown'"
    fi
}

check_for_updates() {
    if [ "$conf_check_updates" != '1' ]; then
        log 'INFO' 'Program update checking is not enabled'
        return
    fi
    latest_version_tag="$(curl -s "$update_api" | jq -r .tag_name)"
    if [ $? -ne 0 ] || [ -z "$latest_version_tag" ] || [ "$latest_version_tag" = 'null' ]; then
        log 'WARN' 'Failed to check for program updates: network or API error'
        return
    fi
    update_type="$(awk -v ver="$version" -v latest="$latest_version_tag" '
        BEGIN {
            split(ver, v, ".")
            split(latest, l, ".")
            if (l[1] > v[1]) {
                print "major"
            } else if (l[1] == v[1] && l[2] > v[2]) {
                print "minor"
            } else if (l[1] == v[1] && l[2] == v[2] && l[3] > v[3]) {
                print "patch"
            } else {
                print "none"
            }
        }
    ')"
    if [ "$update_type" = 'none' ]; then
        log 'INFO' 'No program updates are available'
    else
        log 'WARN' "A $update_type-level update v$latest_version_tag is available at '$upstream'"
    fi
}

load_records() {
    records="$(jq \
        --arg default_interface "$(
            netstat -rn | awk '$1 == "default" || $1 == "0.0.0.0" {print $NF; exit}'
        )" \
        --arg default_ttl 60 \
        --arg default_type 'A/AAAA' \
        -r '
        (
          (.defaults // {
            type: $default_type,
            interface: $default_interface,
            ttl: $default_ttl,
          })
          | {
            type: (.type // $default_type),
            interface: (.interface // $default_interface),
            ttl: (.ttl // $default_ttl)
          }
        ) as $defaults
        | .zones[]
        | .domain as $domain
        | .records[]
        | {
            domain: $domain,
            type: (.type // $defaults.type),
            name: .name,
            interface: (.interface // $defaults.interface),
            ttl: (.ttl // $defaults.ttl)
          }
        | (.name | split("/")) as $names
        | (.type | split("/")) as $types
        | $names[] as $name
        | $types[] as $type
        | "\($domain)\t\($name)\t\($type)\t\(.ttl)\t\(.interface)"
    ' "$cfg_file")"
    if [ -z "$records" ]; then
        log 'No records found'
        return 1
    fi
}

display_records() {
    w_domain="$(printf 'DOMAIN\n%s' "$records" | cut -f1 | wc -L | tr -d '[:space:]')"
    w_name="$(printf 'NAME\n%s' "$records" | cut -f2 | wc -L | tr -d '[:space:]')"
    w_type="$(printf 'TYPE\n%s' "$records" | cut -f3 | wc -L | tr -d '[:space:]')"
    w_ttl="$(printf 'TTL\n%s' "$records" | cut -f4 | wc -L | tr -d '[:space:]')"
    w_interface="$(printf 'INTERFACE\n%s' "$records" | cut -f5 | wc -L | tr -d '[:space:]')"
    log "$(printf "+-%-${w_domain}s-+-%-${w_name}s-+-%-${w_type}s-+-%-${w_ttl}s-+-%-${w_interface}s-+\n" \
        | tr ' ' '-')"
    log "$(printf "| %-${w_domain}s | %-${w_name}s | %-${w_type}s | %-${w_ttl}s | %-${w_interface}s |\n" \
        "DOMAIN" "NAME" "TYPE" "TTL" "INTERFACE")"
    log "$(printf "+-%-${w_domain}s-+-%-${w_name}s-+-%-${w_type}s-+-%-${w_ttl}s-+-%-${w_interface}s-+\n" \
        | tr ' ' '-')"
    while IFS="$(printf '\t')" read -r record_domain record_name record_type record_ttl record_interface; do
        log "$(printf "| %-${w_domain}s | %-${w_name}s | %-${w_type}s | %${w_ttl}d | %-${w_interface}s |\n" \
            "$record_domain" "$record_name" "$record_type" "$record_ttl" "$record_interface")"
done <<EOF
$records
EOF
    log "$(printf "+-%-${w_domain}s-+-%-${w_name}s-+-%-${w_type}s-+-%-${w_ttl}s-+-%-${w_interface}s-+\n" \
        | tr ' ' '-')"
}

test_interfaces() {
    for i in $(printf '%s' "$records" | cut -f5 | sort | uniq); do
        if ! ifconfig "$i" >/dev/null 2>/dev/null; then
            log "Error: Missing network interface '$i'"
            return 1
        fi
    done
    log 'All network interfaces are working'
}

test_domains() {
    for d in $(printf '%s' "$records" | cut -f1 | sort | uniq -d); do
        if [ "$(curl \
                --connect-timeout "$conf_request_timeout" --max-time "$conf_request_timeout" \
                -H "Authorization: Bearer $api_key" \
                -I -w "%{http_code}" \
                -s -o /dev/null \
                "$conf_api_url/zones/$d/rrsets")" != 200 ]; then
            log "Error: Unable to access zone of domain '$d'"
            return 1
        fi
    done
    log 'All domain zones are accessible using provided API key'
}

test_records() {
    record_duplicates="$(printf '%s' "$records" | cut -f1-3 | sort | uniq -d)"
    # Check duplicate entries
    if [ -n "$record_duplicates" ]; then
        while IFS="$(printf '\t')" read -r record_domain record_name record_type; do
            log "Error: Multiple entries for record '$record_name' of type '$record_type' for domain '$record_domain'"
            return 1
done <<EOF
$record_duplicates
EOF
    fi
    while IFS="$(printf '\t')" read -r record_domain record_name record_type record_ttl record_interface; do
        # Check record type
        if [ "$record_type" != 'A' ] && [ "$record_type" != 'AAAA' ]; then
            log "Error: Record '$record_name' of type '$record_type' for domain '$record_domain' is not supported"
            return 1
        fi
        # Check record TTL
        if [ "$record_ttl" -lt 60 ]; then
            log "Error: $record_type record '$record_name' for domain '$record_domain' has too small TTL value"
            return 1
        elif [ "$record_ttl" -gt 2147483647 ]; then
            log "Error: $record_type record '$record_name' for domain '$record_domain' has large TTL value"
            return 1
        fi
        # Check number of entries for record
        record_entries="$(
            curl --connect-timeout "$conf_request_timeout" --max-time "$conf_request_timeout" \
                -H "Authorization: Bearer $api_key" -s \
                "$conf_api_url/zones/$record_domain/rrsets/$record_name/$record_type" | \
                jq '.rrset.records | length'
        )"
        if [ "$record_entries" -eq 0 ]; then
            if [ "$conf_auto_create_records" = 1 ]; then
                log 'INFO' "$record_type record '$record_name' for domain '$record_domain' does not exist and will be created"
            else
                log "Error: $record_type record '$record_name' for domain '$record_domain' doesn't exist in Hetzner Console"
                log 'INFO' 'To allow automatic record creation set `auto_create_records` option to true'
                return 1
            fi
        elif [ "$record_entries" -gt 1 ]; then
            log "Error: $record_type record '$record_name' for domain '$record_domain' has more than one entry"
            return 1
        fi
        # Check record interface connection
        case "$record_type" in
            'A') v='4';;
            'AAAA') v='6';;
        esac
        if ! curl --connect-timeout "$conf_request_timeout" --max-time "$conf_request_timeout" \
                "-$v" --interface "$record_interface" -s -I "$conf_ip_url" -o /dev/null; then
            log "Warning: Network interface $record_interface has no IPv$v internet connection"
        fi
done <<EOF
$records
EOF
    log 'All records are valid:'
    display_records
}

create_service_state() {
    # Create directory
    state_dir="$(mktemp -d -t "${program}_XXXXXXXX")"
    # Register cleanup routine trigger
    trap cleanup_service_state TERM INT
    # Create event pipe
    event_pipe="$state_dir/event_pipe"
    if ! mkfifo -m 600 "$event_pipe"; then
        log "Error: Unable to create event pipe '$event_pipe'"
        return 1
    fi
    # PIDs of the service itself and event tickers
    long_processes="$state_dir/long_running_processes"
    # PIDs of short-lived updaters
    short_processes="$state_dir/temporary_processes"
    echo "$$" > "$long_processes"
    touch "$short_processes"
    # Dump all records
    echo "$records" > "$state_dir/records"
    # For each used interface create current IP values and last updated
    for i in $(echo "$records" | cut -f5 | sort | uniq); do
        echo > "$state_dir/if_${i}_ipv4_addr"
        echo > "$state_dir/if_${i}_ipv6_addr"
        echo '0' > "$state_dir/if_${i}_ipv4_last_updated"
        echo '0' > "$state_dir/if_${i}_ipv6_last_updated"
    done
    log "Service state directory '$state_dir' created"
}

trigger_manual_update() {
    if [ -p "$event_pipe" ]; then
        log 'Triggering update of all records'
        for t in $(printf '%s' "$records" | cut -f4 | sort | uniq); do
            echo "$t" > "$event_pipe"
        done
    else
        log 'Unable to trigger manual update'
    fi
}

cleanup_service_state() {
    log 'Cleanup started'
    # Kill all short-lived children processes
    for p in $(cat "$short_processes"); do
        kill -9 "$p" 1>/dev/null 2>/dev/null
        wait "$p" 1>/dev/null 2>/dev/null
    done
    # Kill all long-running children processes
    for p in $(tail -n +2 "$long_processes" | sort -r); do
        kill -9 "$p" 1>/dev/null 2>/dev/null
        wait "$p" 1>/dev/null 2>/dev/null
    done
    log 'Background tickers stopped'
    # Remove state directory
    rm -rf "$state_dir"
    log 'Service state directory removed'
    log 'Exiting cleanly'
    exit 0
}


clean_up_short_processes() {
    for p in $(cat "$short_processes"); do
        if kill -0 "$p" 2>/dev/null; then
            short_keep="$p $short_keep"
        fi
    done
    # Keep only still-running PIDs
    echo "$short_keep" | sed 's/ /\n/g' > "$short_processes"
}

event_ticker() {
    # Write TTL value to event pipe every TTL seconds
    exec 3> "$event_pipe"
    while :; do
        echo "$1" >&3
        sleep "$1"
    done
}

spawn_event_tickers() {
    for t in $(printf '%s' "$records" | cut -f4 | sort | uniq); do
        event_ticker "$t" &
        echo "$!" >> "$long_processes"
    done
    log 'Spawned background tickers'
}

watch_interface_ipv6_events() {
    interface="$1"
    trigger_ts_file="$state_dir/ipv6_watcher_ts_${interface}"
    last_addr_file="$state_dir/ipv6_watcher_last_addr_${interface}"
    echo "0" > "$trigger_ts_file"
    select_linux_ipv6_address "$interface" > "$last_addr_file"
    log "Started IPv6 event watcher for interface '$interface'"
    while :; do
        ip -6 monitor address dev "$interface" 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                *" inet6 "*) ;;
                *) continue;;
            esac
            case "$line" in
                Deleted*|*" deprecated "*) continue;;
            esac
            if [ "$conf_ipv6_event_require_global" = 'true' ]; then
                case "$line" in
                    *" scope global "*) ;;
                    *) continue;;
                esac
            fi
            # If address is still tentative, skip for now;
            # the subsequent stable event will trigger the update
            case "$line" in
                *" tentative "*) continue;;
            esac
            address="${line#* inet6 }"
            address="${address%%/*}"
            if [ -z "$address" ]; then
                continue
            fi
            case "$address" in
                fc*|fd*) continue;;
            esac
            last_address="$(cat "$last_addr_file" 2>/dev/null)"
            if [ "$last_address" = "$address" ]; then
                continue
            fi
            last_trigger="$(cat "$trigger_ts_file" 2>/dev/null || echo 0)"
            now="$(date +%s)"
            if [ $((now - last_trigger)) -lt "$conf_ipv6_event_cooldown" ]; then
                continue
            fi
            echo "$now" > "$trigger_ts_file"
            echo "$address" > "$last_addr_file"
            log "Interface '$interface' has a new IPv6 address $address"
            trigger_manual_update
        done
        log "Warning: IPv6 event watcher for interface '$interface' restarted after monitor stream ended"
        sleep 1
    done
}

spawn_ipv6_event_watchers() {
    if [ "$conf_ipv6_event_monitor" != 'true' ]; then
        return
    fi
    if ! command -v ip 1>/dev/null 2>/dev/null; then
        log "Warning: IPv6 event monitor is enabled but 'ip' command is unavailable; using TTL-based checks"
        return
    fi
    watchers=0
    for i in $(printf '%s' "$records" | awk '$3 == "AAAA" { print $5 }' | sort | uniq); do
        watch_interface_ipv6_events "$i" &
        echo "$!" >> "$long_processes"
        watchers=$((watchers + 1))
    done
    if [ "$watchers" -gt 0 ]; then
        log "Spawned $watchers IPv6 event watcher(s)"
    else
        log 'No AAAA records found for IPv6 event monitoring'
    fi
}

select_linux_ipv6_address() {
    interface="$1"
    if ! command -v ip 1>/dev/null 2>/dev/null; then
        return 1
    fi
    ip -6 addr show dev "$interface" scope global 2>/dev/null | awk '
        $1 == "inet6" {
            address=$2
            sub(/\/.*/, "", address)
            deprecated=(index($0, " deprecated ") > 0 || $0 ~ / deprecated$/)
            tentative=(index($0, " tentative ") > 0 || $0 ~ / tentative$/)
            ula=(address ~ /^(fc|fd)[0-9a-fA-F]*:/)
            if (!deprecated && !tentative && !ula && preferred_public == "") {
                preferred_public=address
            }
            if (!ula && fallback_public == "") {
                fallback_public=address
            }
        }
        END {
            if (preferred_public != "") print preferred_public
            else if (fallback_public != "") print fallback_public
        }
    '
}

start_event_loop() {
    log 'Started record update event loop'
    # Register manual update trigger
    trap trigger_manual_update USR1
    # Re-register cleanup if detached
    trap cleanup_service_state TERM INT
    spawn_ipv6_event_watchers
    while true; do
        while IFS= read -r ttl; do
            # Process the records whose TTL expired
            process_tick "$ttl"
            # Clean up temporary process list
            clean_up_short_processes
        done < "$event_pipe"
    done
}

update_interface_ip() {
    version="$1"
    interface="$2"
    last_updated="$(cat "$state_dir/if_${interface}_ipv${version}_last_updated")"
    now="$(date +%s)"
    if [ $((now - last_updated)) -lt "$conf_ip_check_cooldown" ]; then
        # Cooldown period not reached
        return
    fi
    old_value="$(cat "$state_dir/if_${interface}_ipv${version}_addr")"
    if [ "$version" = '6' ]; then
        new_value="$(select_linux_ipv6_address "$interface")"
    fi
    if [ -z "$new_value" ]; then
        new_value="$(
            curl --connect-timeout "$conf_request_timeout" --max-time "$conf_request_timeout" \
                --interface "$interface" -"$version" "$conf_ip_url" 2>/dev/null
        )"
    fi
    if [ -z "$new_value" ]; then
        log "Warning: Could not fetch new IPv$version address for interface '$interface'"
        return 1
    fi
    echo "$now" > "$state_dir/if_${interface}_ipv${version}_last_updated"
    if [ "$old_value" != "$new_value" ]; then
        echo "$new_value" > "$state_dir/if_${interface}_ipv${version}_addr"
        log "Interface '$interface' has a new IPv$version address $new_value"
        log "Interface '$interface' kept IPv$version address $new_value"
    fi
}

update_record() {
    domain=$1
    name=$2
    type=$3
    ttl=$4
    interface=$5
    log "Update time reached for $type record '$name' for domain '$domain'"
    current_rrset="$(
        curl -s -H "Authorization: Bearer $api_key" \
        "$conf_api_url/zones/$domain/rrsets/$name/$type"
    )"
    current_value="$(
        echo "$current_rrset" | \
        jq -r '.rrset.records[0].value'
    )"
    current_ttl="$(
        echo "$current_rrset" | \
        jq -r '.rrset.ttl'
    )"
    case "$type" in
        'A') version='4';;
        'AAAA') version='6';;
    esac
    expected_value="$(cat "$state_dir/if_${interface}_ipv${version}_addr")"
    if [ -z "$expected_value" ]; then
        log "Warning: Skipping update of $type record $name for domain $domain"
        return 1
    fi
    if [ -z "$current_value" ] || [ "$current_value" = 'null' ]; then
        log "Warning: Unable to fetch value of $type record $name for domain $domain"
        return 1
    fi
    if [ -z "$current_value" ] || [ "$current_value" = 'null' ]; then
        log "Warning: Failed reading IPv$version address of interface '$interface'"
        return 1
    fi
    if [ "$current_value" = "$expected_value" ]; then
        log "Keep existing value of $type record '$name' for domain '$domain'"
    else
        if curl -s -X POST -H "Authorization: Bearer $api_key" \
            -H "Content-Type: application/json" \
            -d "{
                \"records\": [
                    {
                        \"value\": \"$expected_value\",
                        \"comment\": \"Managed by $program on $(uname -n)\"
                    }
                ]
            }" \
            "$conf_api_url/zones/$domain/rrsets/$name/$type/actions/set_records" >/dev/null; then
            log "Changed $type record '$name' for domain '$domain': $current_value => $expected_value"
        else
            log "Warning: Unable to update value of $type record '$name' for domain '$domain'"
        fi
    fi
    if [ "$current_ttl" = "$ttl" ]; then
        log "Keep existing TTL of $type record '$name' for domain '$domain'"
    else
        if curl -s -X POST -H "Authorization: Bearer $api_key" \
            -H "Content-Type: application/json" \
            -d "{
                \"ttl\": $ttl
            }" \
            "$conf_api_url/zones/$domain/rrsets/$name/$type/actions/change_ttl" >/dev/null; then
            log "Changed $type record '$name' for domain '$domain': TTL = $ttl"
        else
            log "Warning: Unable to update TTL of $type record '$name' for domain '$domain'"
        fi
    fi
}

process_tick() {
    ttl="$1"
    log "Check records with TTL value of $ttl seconds"
    # Update IPv4 addresses for all relevant interfaces
    updaters=
    for i in $(
        printf '%s' "$records" | \
        awk -v OFS='\t' -v ttl="$ttl" '$4 == ttl && $3 == "A" { print $5 }' \
        | sort | uniq); do
        update_interface_ip 4 "$i" &
        updaters="$! $updaters"
        echo "$!" >> "$short_processes"
    done
    # Update IPv6 addresses for all relevant interfaces
    for i in $(
        printf '%s' "$records" | \
        awk -v OFS='\t' -v ttl="$ttl" '$4 == ttl && $3 == "AAAA" { print $5 }' \
        | sort | uniq); do
        update_interface_ip 6 "$i" &
        updaters="$! $updaters"
        echo "$!" >> "$short_processes"
    done
    # Wait for IP updates to finish
    eval "wait $updaters"
    updaters=
    # Update all relevant records
    while IFS="$(printf '\t')" read -r record_domain record_name record_type record_ttl record_interface; do
        update_record "$record_domain" "$record_name" "$record_type" "$record_ttl" "$record_interface" &
        updaters="$! $updaters"
        echo "$!" >> "$short_processes"
done <<EOF
$(printf '%s' "$records" | awk  -v ttl="$ttl" '$4 == ttl')
EOF
    # Wait for record updates to finish
    eval "wait $updaters"
}

log "Starting $program $version"
{
    test_dependencies && \
    parse_cli_args "$@" && \
    test_pid_file && \
    check_daemon_already_running && \
    test_cfg_file && \
    load_settings && \
    create_log_file && \
    validate_settings && \
    check_for_updates && \
    load_and_test_api_key && \
    load_records && \
    test_interfaces && \
    test_domains && \
    test_records && \
    create_service_state && \
    log 'Setup completed'
} ||
{
    log 'Setup failed';
    exit 1
}

if [ "$detach" = 1 ]; then
    {
        verbose=0
        spawn_event_tickers && \
        start_event_loop
        cleanup_service_state
    } 1>/dev/null 2>/dev/null &
    daemon_pid="$!"
    printf '%d' "$daemon_pid" > "$pid_file"
    log "Registering daemon in $pid_file"
    log "Detaching $program to background as process $daemon_pid"
else
    spawn_event_tickers && \
    start_event_loop
    cleanup_service_state
fi
