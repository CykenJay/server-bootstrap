#!/usr/bin/env bash

log() { printf '[server-bootstrap] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

defaults() {
    COMMAND=wizard INTERACTIVE=0
    STATE_DIR=/var/lib/server-bootstrap
    RUN_ID='' RUN_DIR='' ACCESS_ARMED=0 F2B_TEMP_MASK=0
    TIMEZONE=Etc/UTC SSH_PORT='' KEY_USER=root KEY_FILE='' GITHUB_USER=''
    DISABLE_PASSWORD=0 DISABLE_ROOT=0 AUTH_INFO=''
    BBR=0 SWAP_MIB=0 ZRAM_PERCENT=0 NOFILE=0 HOSTNAME_VALUE='' DNS=''
    AUTOREMOVE=0 ROLLBACK_SECONDS=600 AUTOMATIC=0 CONSOLE=0
    DOCKER_INSTALL=0
    DOCKER_TEMP_UNITS=()
    ALLOW_RULES=() SSH_SOURCES=() TRUSTED_IPS=()
}

usage() {
    cat <<'EOF'
直接运行：bash bootstrap.sh
默认进入中文交互向导；回车选择默认项，执行前会展示清单并要求确认。
如有待确认的运行，自动进入连接确认/回滚菜单，无需输入运行 ID。

自动化/高级用法：
Usage: bash bootstrap.sh [wizard|plan|apply|status|confirm RUN_ID|rollback RUN_ID] [options]
Without a terminal, explicitly choose plan or apply; no changes occur by default.

  --timezone ZONE          Default Etc/UTC
  --ssh-port PORT          Add an SSH port, retaining existing ports
  --ssh-source CIDR        Limit newly added SSH allows to this source (repeatable)
  --allow PORT/tcp[@CIDR]   Additional inbound rule; tcp or udp (repeatable)
  --trusted-ip CIDR        Fail2ban exemption (repeatable)
  --key-user USER          Existing account to receive public keys; default root
  --key-file PATH          OpenSSH public key file
  --github-user USER       Import https://github.com/USER.keys
  --disable-password      Require prior key login; disables password and keyboard auth
  --disable-root          Require prior key login through a non-root sudo account
  --auth-info PATH         Current SSH_USER_AUTH file for authentication changes
  --rollback-seconds N     Confirmation window, 120..3600 seconds; default 600
  --console               Confirm from recovery console (authentication changes excluded)
  --bbr                   Enable BBR with fq
  --docker                Install Docker Engine, Compose and Buildx from Docker APT
  --swap-mib N             Create a dedicated swap file, 256..65536 MiB
  --zram-percent N         Configure zram0, 1..100% of RAM, applied after reboot
  --nofile N               PAM and future systemd services, 1024..1048576
  --hostname NAME          Set static hostname
  --dns IP[,IP...]         Configure an already-active systemd-resolved
  --autoremove            Also remove unused dependencies (off by default)
  --help                  Show this help

Keep SSH_CONNECTION when using sudo. Confirm from a NEW SSH connection.
EOF
}

parse_args() {
    if [[ ${1:-} =~ ^(wizard|plan|apply|status|confirm|rollback)$ ]]; then
        COMMAND=$1; shift
    fi
    if [[ $COMMAND == confirm || $COMMAND == rollback ]]; then
        [[ $# -gt 0 ]] || die 'A run ID is required.'
        RUN_ID=$1; shift
        [[ $RUN_ID =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || die 'Invalid run ID.'
    fi
    while (($#)); do
        case "$1" in
            --help|-h) usage; exit 0 ;;
            --bbr) BBR=1; shift ;;
            --docker) DOCKER_INSTALL=1; shift ;;
            --disable-password) DISABLE_PASSWORD=1; shift ;;
            --disable-root) DISABLE_ROOT=1; shift ;;
            --autoremove) AUTOREMOVE=1; shift ;;
            --console) CONSOLE=1; shift ;;
            --automatic) AUTOMATIC=1; shift ;;
            --timezone|--ssh-port|--ssh-source|--allow|--trusted-ip|--key-user|--key-file|--github-user|--auth-info|--rollback-seconds|--swap-mib|--zram-percent|--nofile|--hostname|--dns)
                [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "Missing value for $1"
                case "$1" in
                    --timezone) TIMEZONE=$2 ;; --ssh-port) SSH_PORT=$2 ;;
                    --ssh-source) SSH_SOURCES+=("$2") ;; --allow) ALLOW_RULES+=("$2") ;;
                    --trusted-ip) TRUSTED_IPS+=("$2") ;; --key-user) KEY_USER=$2 ;;
                    --key-file) KEY_FILE=$2 ;; --github-user) GITHUB_USER=$2 ;;
                    --auth-info) AUTH_INFO=$2 ;; --rollback-seconds) ROLLBACK_SECONDS=$2 ;;
                    --swap-mib) SWAP_MIB=$2 ;; --zram-percent) ZRAM_PERCENT=$2 ;;
                    --nofile) NOFILE=$2 ;; --hostname) HOSTNAME_VALUE=$2 ;; --dns) DNS=$2 ;;
                esac
                shift 2 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
}

number_between() {
    [[ $1 =~ ^[0-9]+$ && ${#1} -le 9 ]] || die "Invalid number: $1"
    ((10#$1 >= $2 && 10#$1 <= $3)) || die "Number outside $2..$3: $1"
}

validate_options() {
    [[ -z $SSH_PORT ]] || number_between "$SSH_PORT" 1 65535
    number_between "$ROLLBACK_SECONDS" 120 3600
    [[ $SWAP_MIB == 0 ]] || number_between "$SWAP_MIB" 256 65536
    [[ $ZRAM_PERCENT == 0 ]] || number_between "$ZRAM_PERCENT" 1 100
    [[ $NOFILE == 0 ]] || number_between "$NOFILE" 1024 1048576
    ROLLBACK_SECONDS=$((10#$ROLLBACK_SECONDS))
    SWAP_MIB=$((10#$SWAP_MIB))
    ZRAM_PERCENT=$((10#$ZRAM_PERCENT))
    NOFILE=$((10#$NOFILE))
    [[ -z $SSH_PORT ]] || SSH_PORT=$((10#$SSH_PORT))
    [[ -z $KEY_FILE || -z $GITHUB_USER ]] || die 'Choose key-file or github-user.'
    [[ $KEY_USER =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die 'Invalid key-user.'
    [[ -z $GITHUB_USER || $GITHUB_USER =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,38}$ ]] || die 'Invalid GitHub username.'
    [[ $TIMEZONE != /* && $TIMEZONE != *..* && $TIMEZONE =~ ^[a-zA-Z0-9_+/-]+$ ]] || die 'Invalid timezone.'
    [[ -z $HOSTNAME_VALUE || ( ${#HOSTNAME_VALUE} -le 63 && $HOSTNAME_VALUE =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ) ]] || die 'Use a short hostname without dots.'
    local rule source address
    for rule in ${ALLOW_RULES[@]+"${ALLOW_RULES[@]}"}; do
        [[ $rule =~ ^([0-9]{1,5})/(tcp|udp)(@[^[:space:]]+)?$ ]] || die "Invalid allow rule: $rule"
        number_between "${rule%%/*}" 1 65535
        [[ $rule != *@* ]] || validate_address "${rule#*@}"
    done
    for source in ${SSH_SOURCES[@]+"${SSH_SOURCES[@]}"} ${TRUSTED_IPS[@]+"${TRUSTED_IPS[@]}"}; do validate_address "$source"; done
    if [[ -n $DNS ]]; then
        [[ $DNS != ,* && $DNS != *, && $DNS != *,,* ]] || die 'Invalid DNS list.'
        local addresses=()
        IFS=, read -r -a addresses <<< "$DNS"
        for address in "${addresses[@]}"; do
            [[ $address != */* ]] || die 'DNS requires addresses, not networks.'
            validate_address "$address"
        done
    fi
}

validate_address() {
    address_info "$1" >/dev/null || die "Invalid IP/CIDR: $1"
}

# Emit family, prefix length, then four octets or eight 16-bit words.
# POSIX awk avoids interpreter dependencies and non-portable bitwise extensions.
address_info() {
    [[ $1 =~ ^[0-9a-fA-F:./]+$ && ${#1} -le 100 ]] || return 1
    LC_ALL=C awk -v value="$1" '
    function ipv4(text, out,    n, i, a) {
        n = split(text, a, ".")
        if (n != 4) return -1
        for (i = 1; i <= 4; i++) {
            if (a[i] !~ /^[0-9]+$/ || length(a[i]) > 3 || a[i] + 0 > 255) return -1
            if (length(a[i]) > 1 && substr(a[i], 1, 1) == "0") return -1
            out[i] = a[i] + 0
        }
        return 4
    }
    function words(text, out,    n, i, j, a, digit, number) {
        if (text == "") return 0
        n = split(text, a, ":")
        for (i = 1; i <= n; i++) {
            if (a[i] !~ /^[0-9a-fA-F]+$/ || length(a[i]) > 4) return -1
            number = 0
            for (j = 1; j <= length(a[i]); j++) {
                digit = index("0123456789abcdef", tolower(substr(a[i], j, 1))) - 1
                number = number * 16 + digit
            }
            out[i] = number
        }
        return n
    }
    BEGIN {
        parts = split(value, input, "/")
        if (parts > 2) exit 1
        ip = input[1]
        family = index(ip, ":") ? 6 : 4
        maximum = family == 4 ? 32 : 128
        prefix = maximum
        if (parts == 2) {
            if (input[2] !~ /^[0-9]+$/ || input[2] + 0 > maximum) exit 1
            prefix = input[2] + 0
        }
        if (family == 4) {
            if (ipv4(ip, result) < 0) exit 1
            count = 4
        } else {
            # IPv4-embedded IPv6, e.g. ::ffff:192.0.2.1.
            if (index(ip, ".")) {
                match(ip, /[^:]+$/)
                tail = substr(ip, RSTART)
                if (ipv4(tail, bytes) < 0) exit 1
                ip = substr(ip, 1, RSTART - 1) sprintf("%x:%x", bytes[1] * 256 + bytes[2], bytes[3] * 256 + bytes[4])
            }
            compressed = index(ip, "::")
            if (compressed) {
                left = substr(ip, 1, compressed - 1)
                right = substr(ip, compressed + 2)
                nl = words(left, lwords)
                nr = words(right, rwords)
                if (nl < 0 || nr < 0 || nl + nr >= 8) exit 1
                for (i = 1; i <= nl; i++) result[i] = lwords[i]
                for (i = nl + 1; i <= 8 - nr; i++) result[i] = 0
                for (i = 1; i <= nr; i++) result[8 - nr + i] = rwords[i]
            } else if (words(ip, result) != 8) exit 1
            count = 8
        }
        printf "%d %d", family, prefix
        for (i = 1; i <= count; i++) printf " %d", result[i]
        printf "\n"
    }'
}

address_in_network() {
    local address network
    [[ $1 != */* ]] || return 1
    address=$(address_info "$1") || return 1
    network=$(address_info "$2") || return 1
    awk -v address="$address" -v network="$network" 'BEGIN {
        count = split(address, a, " ")
        split(network, n, " ")
        if (a[1] != n[1]) exit 1
        width = a[1] == 4 ? 8 : 16
        remaining = n[2]
        for (i = 3; i <= count && remaining > 0; i++) {
            used = remaining < width ? remaining : width
            divisor = 2 ^ (width - used)
            if (int(a[i] / divisor) != int(n[i] / divisor)) exit 1
            remaining -= used
        }
    }'
}

print_plan() {
    cat <<EOF
Debian 13 initialization plan (no changes):
  Update APT indexes and upgrade installed packages; install basic tools.
  Timezone: $TIMEZONE; keep an existing NTP provider or install timesyncd.
  SSH: preserve current ports${SSH_PORT:+ and add $SSH_PORT}; MaxAuthTries=3,
       LoginGraceTime=30s, ClientAliveInterval=300, ClientAliveCountMax=2.
       Disable password: $DISABLE_PASSWORD; disable root: $DISABLE_ROOT.
  UFW: deny incoming, allow outgoing, enable IPv4/IPv6; preserve existing rules.
  Fail2ban: systemd journal, UFW action, 5 failures / 10 minutes, ban 1 hour.
  Security-only unattended upgrades; no automatic reboot.
  Persistent journal: max 200M, keep 500M free, retention 14 days; logrotate.
  Conservative kernel security settings; clean downloaded APT packages.
  Optional: BBR=$BBR, swap=${SWAP_MIB}MiB, zram=$ZRAM_PERCENT%, nofile=$NOFILE,
            hostname=${HOSTNAME_VALUE:-unchanged}, DNS=${DNS:-unchanged}, autoremove=$AUTOREMOVE.
  Access changes require confirmation within ${ROLLBACK_SECONDS}s from a new SSH session.
  Backups: $STATE_DIR/runs/RUN_ID; package upgrades are not rolled back.
EOF
    if ((DOCKER_INSTALL)); then
        log 'Docker: install official Engine + Compose + Buildx; start after UFW setup.'
        log 'Published Docker ports require separate access controls; ordinary UFW rules may be bypassed.'
    fi
    local rule
    for rule in ${SSH_SOURCES[@]+"${SSH_SOURCES[@]}"}; do log "SSH source: $rule"; done
    for rule in ${ALLOW_RULES[@]+"${ALLOW_RULES[@]}"}; do log "Additional allow: $rule"; done
    for rule in ${TRUSTED_IPS[@]+"${TRUSTED_IPS[@]}"}; do log "Fail2ban trusted source: $rule"; done
    [[ -z $KEY_FILE && -z $GITHUB_USER ]] || log "Import public keys for $KEY_USER from ${KEY_FILE:-GitHub:$GITHUB_USER}"
}

require_host() {
    [[ $EUID -eq 0 ]] || die 'Run as root or through sudo.'
    [[ -r /etc/os-release ]] || die 'Missing os-release.'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ $ID == debian && $VERSION_ID == 13 ]] || die 'Only Debian 13 is supported.'
    [[ -d /run/systemd/system ]] || die 'A running systemd host is required.'
}

save_file() {
    local path=$1 root="$RUN_DIR/backup/${2:-system}"
    mkdir -p "$root/files" "$root/markers"
    [[ ! -e $root/markers/${path//\//_} ]] || return 0
    if [[ -e $path || -L $path ]]; then
        mkdir -p "$root/files$(dirname "$path")"
        cp -a -- "$path" "$root/files$path"
        printf 'present\t%s\n' "$path" >> "$root/manifest"
    else
        printf 'absent\t%s\n' "$path" >> "$root/manifest"
    fi
    touch "$root/markers/${path//\//_}"
}

write_config() {
    local path=$1 group=${2:-system} tmp
    save_file "$path" "$group"
    mkdir -p "$(dirname "$path")"
    [[ ! -L $path ]] || die "Refusing to replace symlink: $path"
    tmp=$(mktemp "${path}.XXXXXX")
    cat > "$tmp"
    chmod 644 "$tmp"
    mv -f -- "$tmp" "$path"
}

restore_group() {
    local root="$RUN_DIR/backup/$1" state path failed=0
    [[ -f $root/manifest ]] || return 0
    while IFS=$'\t' read -r state path; do
        if [[ $state == present ]]; then
            rm -rf -- "$path" || failed=1
            cp -a -- "$root/files$path" "$path" || failed=1
        else
            rm -rf -- "$path" || failed=1
        fi
    done < "$root/manifest"
    return "$failed"
}

load_run() {
    RUN_DIR="$STATE_DIR/runs/$RUN_ID"
    [[ -d $RUN_DIR && -f $RUN_DIR/access.env ]] || die 'No access transaction for this run.'
    # This file is generated by printf %q in a root-only directory.
    # shellcheck source=/dev/null
    source "$RUN_DIR/access.env"
}
