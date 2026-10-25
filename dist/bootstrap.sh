#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH="$BASE_DIR/$(basename -- "${BASH_SOURCE[0]}")"
BUNDLED=1
# Module: lib/common.sh

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

# Module: lib/docker.sh

package_installed() {
    local status
    status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
    [[ $status == 'install ok installed' ]]
}

check_docker_sources() {
    local directory=${1:-/etc/apt} file
    for file in "$directory/sources.list" "$directory"/sources.list.d/*.list "$directory"/sources.list.d/*.sources; do
        [[ -f $file && $file != "$directory/sources.list.d/docker.sources" ]] || continue
        if grep -Eq '^[[:space:]]*[^#[:space:]].*download\.docker\.com/linux/debian' "$file"; then
            die "Docker repository already exists in $file; consolidate it into sources.list.d/docker.sources before installation."
        fi
    done
}

docker_preflight() {
    local package unit state
    case "$(dpkg --print-architecture)" in
        amd64|arm64|armhf|ppc64el) ;;
        *) die 'This architecture is not supported by this Docker installer.' ;;
    esac
    for package in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
        if package_installed "$package"; then
            die "Conflicting package $package is installed. Migrate it manually before selecting Docker installation."
        fi
    done
    if command -v dockerd >/dev/null && ! package_installed docker-ce; then
        die 'An unmanaged Docker daemon is already installed; migrate it manually first.'
    fi
    for unit in docker.service docker.socket containerd.service; do
        state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
        [[ $state != masked* ]] || die "$unit is masked; resolve this before selecting Docker installation."
    done
    check_docker_sources /etc/apt
    [[ ! -L /etc/apt/keyrings/docker.asc && ! -L /etc/apt/sources.list.d/docker.sources ]] ||
        die 'Docker repository files must not be symlinks.'
}

render_docker_source() {
    cat <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
}

release_docker_masks() {
    if ((${#DOCKER_TEMP_UNITS[@]})); then
        systemctl unmask --runtime "${DOCKER_TEMP_UNITS[@]}"
        DOCKER_TEMP_UNITS=()
    fi
}

install_docker_packages() {
    local unit
    # Prevent first-time package installation from starting container networking
    # before UFW is configured. Existing daemons are never masked or stopped here.
    if ! package_installed docker-ce; then
        for unit in docker.service docker.socket; do
            DOCKER_TEMP_UNITS+=("$unit")
            systemctl mask --runtime "$unit"
        done
    fi
    if ! package_installed containerd.io; then
        DOCKER_TEMP_UNITS+=(containerd.service)
        systemctl mask --runtime containerd.service
    fi
    curl --fail --silent --show-error --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
        --retry 2 --max-filesize 1048576 https://download.docker.com/linux/debian/gpg -o "$RUN_DIR/docker.asc"
    grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "$RUN_DIR/docker.asc" || die 'Invalid Docker signing key response.'
    install -d -m 0755 /etc/apt/keyrings
    write_config /etc/apt/keyrings/docker.asc < "$RUN_DIR/docker.asc"
    render_docker_source | write_config /etc/apt/sources.list.d/docker.sources
    apt_run update --error-on=any
    apt_run install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

start_docker() {
    release_docker_masks
    timeout 60 systemctl enable --now containerd.service docker.service
    verify_docker
}

verify_docker() {
    systemctl is-active --quiet docker.service
    timeout 20 env -u DOCKER_HOST -u DOCKER_CONTEXT docker --host unix:///var/run/docker.sock version --format '{{.Server.Version}}'
    timeout 20 docker compose version
    timeout 20 docker buildx version
}

# Module: lib/system.sh

apt_run() {
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

preflight() {
    local state service
    [[ -f /usr/share/zoneinfo/$TIMEZONE ]] || die 'Unknown timezone.'
    [[ -n ${SSH_CONNECTION:-} ]] || die 'Apply requires SSH_CONNECTION; use sudo --preserve-env=SSH_CONNECTION.'
    read -r CLIENT_IP CLIENT_PORT SERVER_IP SERVER_PORT <<< "$SSH_CONNECTION"
    validate_address "$CLIENT_IP"; validate_address "$SERVER_IP"
    number_between "$CLIENT_PORT" 1 65535; number_between "$SERVER_PORT" 1 65535
    [[ $(df --output=avail -k /var | tail -1) -ge 1048576 ]] || die 'Need at least 1 GiB free on /var.'
    for service in firewalld nftables netfilter-persistent; do
        if systemctl is-active --quiet "$service"; then die "Active $service conflicts with UFW management."; fi
    done
    if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
        die 'ssh.socket activation is not supported; use ssh.service before applying.'
    fi
    for service in ssh ufw fail2ban; do
        state=$(systemctl is-enabled "$service" 2>/dev/null || true)
        [[ $state != masked* ]] || die "$service is masked. Resolve this before applying."
    done
    if [[ -f $STATE_DIR/pending ]]; then die "Confirm or roll back pending run $(cat "$STATE_DIR/pending") first."; fi
    if ((DOCKER_INSTALL)); then docker_preflight; fi
    if ((DISABLE_PASSWORD || DISABLE_ROOT)); then verify_key_session; fi
    if [[ -n $KEY_FILE ]]; then [[ -f $KEY_FILE && -r $KEY_FILE ]] || die 'Cannot read key file.'; fi
    if [[ -n $KEY_FILE || -n $GITHUB_USER ]]; then
        getent passwd "$KEY_USER" >/dev/null || die 'key-user must already exist.'
    fi
    if [[ -n $DNS ]]; then
        systemctl is-active --quiet systemd-resolved || die '--dns requires active systemd-resolved.'
        [[ $(readlink -f /etc/resolv.conf) == /run/systemd/resolve/* ]] || die 'resolv.conf is not managed by systemd-resolved.'
    fi
    if ((SWAP_MIB)); then
        [[ $(findmnt -no FSTYPE -T /var) =~ ^(ext4|xfs)$ ]] || die 'Swap file creation supports ext4/xfs only.'
    fi
    if command -v docker >/dev/null; then
        log 'Docker detected: published container ports need separate forwarding rules; UFW INPUT rules are insufficient.'
    fi
    log "Architecture: $(dpkg --print-architecture); SSH source: $CLIENT_IP; server: $SERVER_IP:$SERVER_PORT"
    if command -v ip >/dev/null; then
        ip -brief address
        ip route show default
        ip -6 route show default
    else
        log 'iproute2 is absent and will be installed with the base tools.'
    fi
    getent ahosts deb.debian.org >/dev/null || die 'DNS lookup of deb.debian.org failed.'
}

install_packages() {
    # Newly installed Fail2ban must not enforce a default jail before rollback is armed.
    if ! dpkg-query -W -f='${Status}' fail2ban 2>/dev/null | grep -q 'install ok installed'; then
        systemctl mask --runtime fail2ban.service
        F2B_TEMP_MASK=1
    fi
    apt_run update --error-on=any
    local apt_policy
    apt_policy=$(apt-cache policy)
    grep -qE 'release .*n=trixie-security([,[:space:]]|$)' <<< "$apt_policy" ||
        die 'No trixie-security APT index found. Configure the Debian security repository before applying.'
    apt_run upgrade -y
    apt_run install -y ca-certificates curl wget sudo vim-tiny less unzip zip tar \
        htop dnsutils iproute2 iputils-ping netcat-openbsd lsof rsync bash-completion dbus kmod procps \
        openssh-server ufw fail2ban python3-systemd unattended-upgrades \
        apt-listchanges logrotate tzdata
}

configure_system() {
    save_file /etc/localtime
    save_file /etc/timezone
    timedatectl set-timezone "$TIMEZONE"
    local service ntp_found=0
    for service in chrony ntpsec systemd-timesyncd; do
        if systemctl is-active --quiet "$service"; then
            log "Keeping active NTP provider: $service"; ntp_found=1; break
        fi
    done
    if ((ntp_found == 0)); then
        if dpkg-query -W -f='${Status}' chrony 2>/dev/null | grep -q 'install ok installed'; then
            service=chrony
        elif dpkg-query -W -f='${Status}' ntpsec 2>/dev/null | grep -q 'install ok installed'; then
            service=ntpsec
        else
            apt_run install -y systemd-timesyncd; service=systemd-timesyncd
        fi
        systemctl enable --now "$service"
    fi
    write_config /etc/apt/apt.conf.d/99-server-bootstrap <<'EOF'
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=trixie-security,label=Debian-Security";
};
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
EOF
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
    write_config /etc/systemd/journald.conf.d/60-server-bootstrap.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=200M
SystemKeepFree=500M
RuntimeMaxUse=50M
MaxRetentionSec=14day
Compress=yes
EOF
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald
    journalctl --flush
    systemctl enable --now logrotate.timer
    write_config /etc/sysctl.d/60-server-bootstrap-security.conf <<'EOF'
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
    sysctl -p /etc/sysctl.d/60-server-bootstrap-security.conf
    configure_optional
    apt_run clean
    if ((AUTOREMOVE)); then apt_run autoremove -y; fi
}

configure_optional() {
    if ((BBR)); then
        modprobe tcp_bbr
        sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr || die 'BBR is unavailable.'
        write_config /etc/sysctl.d/60-server-bootstrap-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        sysctl -p /etc/sysctl.d/60-server-bootstrap-bbr.conf
    fi
    if ((SWAP_MIB)); then configure_swap /var/lib/server-bootstrap.swap /etc/fstab; fi
    if ((ZRAM_PERCENT)); then
        apt_run install -y systemd-zram-generator
        write_config /etc/systemd/zram-generator.conf.d/60-server-bootstrap.conf <<EOF
[zram0]
zram-size = ram * $ZRAM_PERCENT / 100
swap-priority = 100
EOF
        log 'ZRAM configuration saved; takes effect after a manual reboot.'
    fi
    if ((NOFILE)); then
        write_config /etc/security/limits.d/60-server-bootstrap.conf <<EOF
* soft nofile $NOFILE
* hard nofile $NOFILE
root soft nofile $NOFILE
root hard nofile $NOFILE
EOF
        write_config /etc/systemd/system.conf.d/60-server-bootstrap.conf <<EOF
[Manager]
DefaultLimitNOFILE=$NOFILE
EOF
        systemctl daemon-reload
        log 'nofile applies to new logins and future services; existing processes retain their limits.'
    fi
    if [[ -n $HOSTNAME_VALUE ]]; then
        save_file /etc/hostname
        hostnamectl set-hostname "$HOSTNAME_VALUE"
        # Keep sudo/local hostname resolution working without replacing other hosts entries.
        save_file /etc/hosts
        update_hosts_hostname /etc/hosts "$HOSTNAME_VALUE"
    fi
    if [[ -n $DNS ]]; then
        write_config /etc/systemd/resolved.conf.d/60-server-bootstrap.conf <<EOF
[Resolve]
DNS=${DNS//,/ }
EOF
        systemctl restart systemd-resolved
        if ! getent ahosts deb.debian.org >/dev/null; then
            log 'DNS check failed; restoring the previous resolved drop-in.'
            local saved="$RUN_DIR/backup/system/files/etc/systemd/resolved.conf.d/60-server-bootstrap.conf"
            if [[ -f $saved ]]; then cp -a "$saved" /etc/systemd/resolved.conf.d/60-server-bootstrap.conf;
            else rm -f /etc/systemd/resolved.conf.d/60-server-bootstrap.conf; fi
            systemctl restart systemd-resolved
            die 'DNS configuration did not pass validation.'
        fi
    fi
}

update_hosts_hostname() {
    local target=$1 hostname=$2 temporary="$RUN_DIR/hosts-updated"
    awk -v hostname="$hostname" '
        BEGIN { aliases = hostname; seen[hostname] = 1 }
        $1 == "127.0.1.1" {
            sub(/#.*/, "")
            for (i = 2; i <= NF; i++) if (!seen[$i]++) aliases = aliases " " $i
            next
        }
        { print }
        END { print "127.0.1.1\t" aliases }
    ' "$target" > "$temporary"
    cat "$temporary" > "$target"
}

configure_swap() {
    local swap=$1 fstab=$2 available bytes active_priority
    bytes=$((10#$SWAP_MIB * 1024 * 1024))
    if [[ -e $swap ]]; then
        [[ ! -L $swap && $(stat -c %s "$swap") == "$bytes" ]] || die 'Existing managed swap has a different size or is a symlink.'
        [[ $(blkid -p -s TYPE -o value "$swap") == swap ]] || die 'Existing managed file is not swap.'
    else
        available=$(df --output=avail -k /var | tail -1)
        ((available > 10#$SWAP_MIB * 1024 + 1048576)) || die 'Insufficient disk space for swap plus 1 GiB reserve.'
        dd if=/dev/zero of="$swap" bs=1M count="$((10#$SWAP_MIB))" status=progress
        chmod 600 "$swap"
        mkswap "$swap"
    fi
    save_file "$fstab"
    render_swap_fstab "$swap" < "$fstab" > "$RUN_DIR/fstab-swap"
    active_priority=$(swapon --show=NAME,PRIO --noheadings | awk -v p="$swap" '$1 == p {print $2}')
    if [[ -z $active_priority ]]; then
        swapon --priority 10 "$swap"
    elif [[ $active_priority != 10 ]]; then
        log 'Existing disk swap remains active; its priority will change to 10 after a manual reboot.'
    fi
    cat "$RUN_DIR/fstab-swap" > "$fstab"
}

render_swap_fstab() {
    awk -v p="$1" '
        $1 == p && $3 == "swap" {
            found = 1
            count = split($4, options, ",")
            updated = ""
            for (i = 1; i <= count; i++) {
                if (options[i] !~ /^pri=/) updated = updated options[i] ","
            }
            $4 = updated "pri=10"
        }
        { print }
        END { if (!found) print p " none swap sw,pri=10 0 0" }
    '
}

apply_all() {
    preflight
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    RUN_DIR="$STATE_DIR/runs/$RUN_ID"
    mkdir -p "$RUN_DIR"
    trap 'rc=$?; if ((rc != 0)); then apply_failed "$rc"; fi' EXIT
    trap 'exit 130' INT TERM HUP
    install_packages
    if ((DOCKER_INSTALL)); then install_docker_packages; fi
    configure_system
    prepare_access
    arm_rollback
    configure_access
    if ((DOCKER_INSTALL)); then start_docker; fi
    verify_access
    printf 'pending\n' > "$RUN_DIR/status"
    trap - EXIT INT TERM HUP
    if ((INTERACTIVE == 0)); then
        log "Access changes pending. Within ${ROLLBACK_SECONDS}s, open a NEW SSH connection and run:"
        printf 'sudo --preserve-env=SSH_CONNECTION bash %q confirm %q\n' "$RUN_DIR/runner/bootstrap.sh" "$RUN_ID"
    else
        log '配置已应用，仍需从新 SSH 连接进入向导确认。'
    fi
    log "Backups: $RUN_DIR/backup (package upgrades and system options are not part of automatic access rollback)."
    report
}

apply_failed() {
    local rc=$1
    trap - EXIT INT TERM HUP
    log "Initialization failed (exit $rc)."
    if ((ACCESS_ARMED)); then rollback_access || true; fi
    if ((F2B_TEMP_MASK)); then systemctl unmask --runtime fail2ban.service || true; fi
    if ((DOCKER_INSTALL)); then release_docker_masks || true; fi
    exit "$rc"
}

report() {
    log 'Service status:'
    systemctl --no-pager --failed || true
    for service in ssh ufw fail2ban apt-daily-upgrade.timer logrotate.timer; do
        printf '%s: ' "$service"; systemctl is-active "$service" || true
    done
    if command -v ufw >/dev/null; then ufw status verbose || true; fi
    if command -v fail2ban-client >/dev/null; then fail2ban-client status sshd || true; fi
    if command -v sshd >/dev/null; then
        sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|maxauthtries|logingracetime|clientalive)' || true
    fi
    ss -lntup
    timedatectl status
    if [[ -f /var/run/reboot-required ]]; then log 'A manual reboot is required after access confirmation.'; fi
    if [[ -f $STATE_DIR/pending ]]; then log "Pending access confirmation: $(cat "$STATE_DIR/pending")"; fi
}

# Module: lib/access.sh

verify_key_session() {
    # shellcheck disable=SC2016
    [[ -n ${SSH_CONNECTION:-} && -n $AUTH_INFO && -f $AUTH_INFO && ! -L $AUTH_INFO ]] ||
        die 'Authentication changes require a key-authenticated SSH session and --auth-info "$SSH_USER_AUTH". Apply the baseline first, then reconnect using a key.'
    local login_user=${SUDO_USER:-root}
    [[ $(stat -c %u "$AUTH_INFO") == "$(id -u "$login_user")" ]] || die 'Auth-info owner does not match the login user.'
    grep -q '^publickey ' "$AUTH_INFO" || die 'Current session does not report public-key authentication.'
    if ((DISABLE_ROOT)); then
        [[ $login_user != root && -n ${SUDO_USER:-} ]] || die 'Disabling root requires a public-key login as a non-root user with sudo.'
    fi
}

prepare_access() {
    local p source allowed
    SSH_PORTS=()
    while read -r p; do SSH_PORTS+=("$p"); done < <(
        { sshd -T | awk '$1 == "port" {print $2}'; printf '%s\n' "$SERVER_PORT"; [[ -z $SSH_PORT ]] || printf '%s\n' "$SSH_PORT"; } | sort -nu
    )
    ((${#SSH_PORTS[@]} > 0)) || die 'Cannot discover SSH ports.'
    if ((${#SSH_SOURCES[@]})); then
        allowed=0
        for source in "${SSH_SOURCES[@]}"; do
            if address_in_network "$CLIENT_IP" "$source"; then allowed=1; break; fi
        done
        ((allowed)) || die 'Current SSH source must be allowed.'
    fi
    sshd -t
    [[ ! -L /etc/ssh/sshd_config && ! -L /etc/ssh/server-bootstrap.conf ]] || die 'Managed SSH files must not be symlinks.'
    ORIGINAL_CONNECTION=$SSH_CONNECTION
    REQUIRED_PORT=${SSH_PORT:-$SERVER_PORT}
    EXPECTED_USER=${SUDO_USER:-root}
    F2B_ACTIVE=0 F2B_ENABLED=0 UFW_ACTIVE=0 UFW_ENABLED=0
    if systemctl is-active --quiet fail2ban; then F2B_ACTIVE=1; fi
    if systemctl is-enabled --quiet fail2ban; then F2B_ENABLED=1; fi
    if ufw status | grep -q '^Status: active'; then UFW_ACTIVE=1; fi
    if systemctl is-enabled --quiet ufw; then UFW_ENABLED=1; fi
    save_file /etc/ssh/sshd_config access
    save_file /etc/ssh/server-bootstrap.conf access
    save_file /etc/ufw access
    save_file /etc/default/ufw access
    save_file /etc/fail2ban/jail.d/99-server-bootstrap.local access
    prepare_keys
    {
        printf 'ORIGINAL_CONNECTION=%q\nREQUIRED_PORT=%q\nEXPECTED_USER=%q\n' "$ORIGINAL_CONNECTION" "$REQUIRED_PORT" "$EXPECTED_USER"
        printf 'F2B_ACTIVE=%q\nF2B_ENABLED=%q\nUFW_ACTIVE=%q\nUFW_ENABLED=%q\n' "$F2B_ACTIVE" "$F2B_ENABLED" "$UFW_ACTIVE" "$UFW_ENABLED"
        printf 'DISABLE_PASSWORD=%q\nDISABLE_ROOT=%q\n' "$DISABLE_PASSWORD" "$DISABLE_ROOT"
        printf 'F2B_TEMP_MASK=%q\n' "$F2B_TEMP_MASK"
        printf 'DOCKER_INSTALL=%q\n' "$DOCKER_INSTALL"
        printf 'DOCKER_TEMP_UNITS=('
        if ((${#DOCKER_TEMP_UNITS[@]})); then printf '%q ' "${DOCKER_TEMP_UNITS[@]}"; fi
        printf ')\n'
        printf 'SSH_PORTS=('; printf '%q ' "${SSH_PORTS[@]}"; printf ')\n'
    } > "$RUN_DIR/access.env"
}

prepare_keys() {
    [[ -n $KEY_FILE || -n $GITHUB_USER ]] || return 0
    if [[ -n $GITHUB_USER ]]; then
        curl --fail --silent --show-error --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 \
            --max-filesize 1048576 "https://github.com/$GITHUB_USER.keys" > "$RUN_DIR/public-keys"
    else
        cp -- "$KEY_FILE" "$RUN_DIR/public-keys"
    fi
    local line kind body _comment count=0
    : > "$RUN_DIR/validated-keys"
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line || $line == \#* ]] && continue
        read -r kind body _comment <<< "$line"
        [[ $kind =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)$ ]] || die 'Expected plain OpenSSH public keys, without authorized_keys options.'
        printf '%s %s\n' "$kind" "$body" > "$RUN_DIR/key-check"
        ssh-keygen -l -f "$RUN_DIR/key-check" >/dev/null || die 'Invalid public key.'
        cat "$RUN_DIR/key-check" >> "$RUN_DIR/validated-keys"
        count=$((count + 1))
    done < "$RUN_DIR/public-keys"
    ((count > 0)) || die 'Public key source was empty.'
    KEY_HOME=$(getent passwd "$KEY_USER" | cut -d: -f6)
    [[ $KEY_HOME == /* && -d $KEY_HOME && ! -L $KEY_HOME/.ssh && ! -L $KEY_HOME/.ssh/authorized_keys ]] || die 'Invalid home or symlinked SSH key path.'
    # This importer deliberately supports only the normal per-user key location.
    local key_paths
    key_paths=$(sshd -T -C "user=$KEY_USER,addr=$CLIENT_IP,host=$CLIENT_IP,laddr=$SERVER_IP,lport=$SERVER_PORT" | awk '$1 == "authorizedkeysfile" {$1=""; print}')
    [[ " $key_paths " == *' .ssh/authorized_keys '* ]] || die 'Custom AuthorizedKeysFile requires manual key installation.'
    save_file "$KEY_HOME/.ssh" access
}

snapshot_runner() {
    mkdir -p "$RUN_DIR/runner"
    if [[ ${BUNDLED:-0} == 1 ]]; then
        cp -- "$SCRIPT_PATH" "$RUN_DIR/runner/bootstrap.sh"
    else
        mkdir -p "$RUN_DIR/runner/lib"
        cp -- "$BASE_DIR/bootstrap.sh" "$RUN_DIR/runner/"
        cp -- "$BASE_DIR"/lib/*.sh "$RUN_DIR/runner/lib/"
    fi
}

arm_rollback() {
    local unit="server-bootstrap-rollback-$RUN_ID" deadline
    snapshot_runner
    deadline=$(date -u -d "+$((10#$ROLLBACK_SECONDS)) seconds" '+%Y-%m-%d %H:%M:%S UTC')
    printf '%s\n' "$RUN_ID" > "$STATE_DIR/pending"
    printf 'pending\n' > "$RUN_DIR/status"
    # Persistent calendar timer also catches a missed deadline after a reboot.
    cat > "/etc/systemd/system/$unit.service" <<EOF
[Unit]
Description=Restore server access for run $RUN_ID
After=local-fs.target
StartLimitIntervalSec=0
[Service]
Type=oneshot
ExecStart=/bin/bash $RUN_DIR/runner/bootstrap.sh rollback $RUN_ID --automatic
TimeoutStartSec=240
Restart=on-failure
RestartSec=15s
EOF
    cat > "/etc/systemd/system/$unit.timer" <<EOF
[Unit]
Description=Server access rollback deadline
[Timer]
OnCalendar=$deadline
Persistent=true
AccuracySec=1s
Unit=$unit.service
[Install]
WantedBy=timers.target
EOF
    chmod 644 "/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.timer"
    ACCESS_ARMED=1
    systemctl daemon-reload
    systemctl enable --now "$unit.timer"
    systemctl is-active --quiet "$unit.timer"
    log "Rollback armed for $deadline."
}

render_ssh_config() {
    local p previous=${1:-/etc/ssh/server-bootstrap.conf}
    for p in "${SSH_PORTS[@]}"; do printf 'Port %s\n' "$p"; done
    cat <<'EOF'
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
ExposeAuthInfo yes
EOF
    if ((DISABLE_PASSWORD)); then
        printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n'
    elif [[ -f $previous ]]; then
        grep -E '^(PasswordAuthentication|KbdInteractiveAuthentication) ' "$previous" || true
    fi
    if ((DISABLE_ROOT)); then printf 'PermitRootLogin no\n'
    elif [[ -f $previous ]]; then
        grep '^PermitRootLogin ' "$previous" || true
    fi
}

configure_access() {
    local port source rule proto
    timeout 30 systemctl stop fail2ban
    if [[ -n ${KEY_HOME:-} ]]; then
        install -d -m 700 -o "$KEY_USER" -g "$(id -gn "$KEY_USER")" "$KEY_HOME/.ssh"
        touch "$KEY_HOME/.ssh/authorized_keys"
        append_public_keys "$KEY_HOME/.ssh/authorized_keys" "$RUN_DIR/validated-keys"
        chown "$KEY_USER:$(id -gn "$KEY_USER")" "$KEY_HOME/.ssh/authorized_keys"
        chmod 600 "$KEY_HOME/.ssh/authorized_keys"
    fi
    render_ssh_config /etc/ssh/server-bootstrap.conf > "$RUN_DIR/ssh-config"
    write_config /etc/ssh/server-bootstrap.conf access < "$RUN_DIR/ssh-config"
    ensure_ssh_include /etc/ssh/sshd_config
    sshd -t
    verify_ssh_policy
    # Open ports before changing the listener. Existing rules are intentionally retained.
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
    grep -q '^IPV6=yes$' /etc/default/ufw || printf 'IPV6=yes\n' >> /etc/default/ufw
    for port in "${SSH_PORTS[@]}"; do
        if ((${#SSH_SOURCES[@]})); then
            for source in ${SSH_SOURCES[@]+"${SSH_SOURCES[@]}"}; do
                timeout 30 ufw prepend allow proto tcp from "$source" to any port "$port" comment server-bootstrap-ssh
            done
        else
            timeout 30 ufw prepend allow "$port/tcp" comment server-bootstrap-ssh
        fi
    done
    for rule in ${ALLOW_RULES[@]+"${ALLOW_RULES[@]}"}; do
        port=${rule%%/*}; proto=${rule#*/}; proto=${proto%%@*}; source=any
        [[ $rule != *@* ]] || source=${rule#*@}
        timeout 30 ufw allow proto "$proto" from "$source" to any port "$port" comment server-bootstrap
    done
    timeout 30 ufw default deny incoming
    timeout 30 ufw default allow outgoing
    timeout 30 ufw logging low
    timeout 30 ufw --force enable
    timeout 30 systemctl enable --now ufw
    timeout 30 systemctl reload ssh
    # Debian minimal images may not have auth.log, so read the systemd journal.
    render_fail2ban_config | write_config /etc/fail2ban/jail.d/99-server-bootstrap.local access
    timeout 30 fail2ban-client -t
    if ((F2B_TEMP_MASK)); then
        systemctl unmask --runtime fail2ban.service
        F2B_TEMP_MASK=0
    fi
    timeout 30 systemctl enable --now fail2ban
}

append_public_keys() {
    local target=$1 incoming=$2 fingerprints fingerprint line
    # Let OpenSSH parse quoted options and comments. An existing restricted key
    # must never gain an unrestricted duplicate merely because it has options.
    fingerprints=$(ssh-keygen -l -E sha256 -f "$target" 2>/dev/null | awk '{print $2}' || true)
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || continue
        printf '%s\n' "$line" > "$RUN_DIR/key-check"
        fingerprint=$(ssh-keygen -l -E sha256 -f "$RUN_DIR/key-check" | awk '{print $2}')
        [[ -n $fingerprint ]] || die 'Cannot determine public key fingerprint.'
        if ! grep -Fxq "$fingerprint" <<< "$fingerprints"; then
            if [[ -s $target && -n $(tail -c 1 "$target") ]]; then printf '\n' >> "$target"; fi
            printf '%s\n' "$line" >> "$target"
            fingerprints+=$'\n'"$fingerprint"
        fi
    done < "$incoming"
}

ensure_ssh_include() {
    local target=$1 temporary="$RUN_DIR/sshd-main"
    awk 'BEGIN { include = "Include /etc/ssh/server-bootstrap.conf"; print include }
        { trimmed = $0; sub(/^[[:space:]]+/, "", trimmed); sub(/[[:space:]]+$/, "", trimmed)
          if (trimmed != include) print $0 }' "$target" > "$temporary"
    # Keep original ownership, permissions and inode (also works on bind mounts).
    cat "$temporary" > "$target"
}

render_fail2ban_config() {
    local source
    printf '[sshd]\nenabled = true\nbackend = systemd\nbanaction = ufw\n'
    printf 'port = %s\n' "$(IFS=,; echo "${SSH_PORTS[*]}")"
    printf 'findtime = 10m\nmaxretry = 5\nbantime = 1h\nignoreip = 127.0.0.1/8 ::1'
    for source in ${TRUSTED_IPS[@]+"${TRUSTED_IPS[@]}"}; do printf ' %s' "$source"; done
    printf '\n'
}

verify_ssh_policy() {
    local user=${EXPECTED_USER:-root} policy root_policy
    policy=$(sshd -T -C "user=$user,addr=$CLIENT_IP,host=$CLIENT_IP,laddr=$SERVER_IP,lport=$REQUIRED_PORT")
    grep -q '^pubkeyauthentication yes$' <<< "$policy" || die 'Public-key authentication is overridden by another SSH rule.'
    grep -q '^exposeauthinfo yes$' <<< "$policy" || die 'ExposeAuthInfo is overridden.'
    if ((DISABLE_PASSWORD)); then
        grep -q '^passwordauthentication no$' <<< "$policy" || die 'Password policy is overridden.'
        grep -q '^kbdinteractiveauthentication no$' <<< "$policy" || die 'Keyboard authentication policy is overridden.'
    fi
    if ((DISABLE_ROOT)); then
        root_policy=$(sshd -T -C "user=root,addr=$CLIENT_IP,host=$CLIENT_IP,laddr=$SERVER_IP,lport=$REQUIRED_PORT")
        grep -q '^permitrootlogin no$' <<< "$root_policy" || die 'Root login policy is overridden.'
    fi
}

verify_access() {
    local port _tries
    sshd -t
    systemctl is-active --quiet ssh
    systemctl is-active --quiet fail2ban
    ufw status | grep -q '^Status: active'
    for port in "${SSH_PORTS[@]}"; do
        for _tries in 1 2 3 4 5; do
            if ss -H -lntp | awk -v p=":$port" '$4 ~ (p "$") && /sshd/ {found=1} END {exit !found}'; then break; fi
            sleep 1
        done
        ss -H -lntp | awk -v p=":$port" '$4 ~ (p "$") && /sshd/ {found=1} END {exit !found}' || die "SSH is not listening on $port."
    done
    for _tries in 1 2 3 4 5; do
        if fail2ban-client status sshd >/dev/null 2>&1; then break; fi
        sleep 1
    done
    fail2ban-client status sshd >/dev/null
    getent ahosts deb.debian.org >/dev/null
    if ((DOCKER_INSTALL)); then verify_docker; fi
}

cleanup_timer() {
    local unit="server-bootstrap-rollback-$RUN_ID"
    systemctl disable --now "$unit.timer"
    rm -f "/etc/systemd/system/$unit.timer" "/etc/systemd/system/$unit.service"
    systemctl daemon-reload
}

confirm_access() {
    load_run
    [[ $(cat "$RUN_DIR/status") == pending && -f $STATE_DIR/pending && $(cat "$STATE_DIR/pending") == "$RUN_ID" ]] || die 'This run is not pending.'
    if ((CONSOLE)); then
        [[ -z ${SSH_CONNECTION:-} && -z ${SSH_CLIENT:-} ]] || die '--console is only for a local recovery console.'
        ((DISABLE_PASSWORD == 0 && DISABLE_ROOT == 0)) || die 'Authentication changes must be confirmed through SSH.'
    else
        [[ -n ${SSH_CONNECTION:-} && $SSH_CONNECTION != "$ORIGINAL_CONNECTION" ]] || die 'Confirm from a new SSH connection; preserve SSH_CONNECTION through sudo.'
        local remote_port
        read -r CLIENT_IP CLIENT_PORT SERVER_IP remote_port <<< "$SSH_CONNECTION"
        [[ $remote_port == "$REQUIRED_PORT" ]] || die "Connect through the requested port $REQUIRED_PORT before confirming."
        [[ ${SUDO_USER:-root} == "$EXPECTED_USER" ]] || die "Confirm as $EXPECTED_USER (with sudo if needed)."
        verify_ssh_policy
    fi
    verify_access
    # Change state before stopping timer: a queued automatic rollback sees confirmed and exits.
    printf 'confirmed\n' > "$RUN_DIR/status"
    rm -f "$STATE_DIR/pending"
    cleanup_timer
    log "Run $RUN_ID confirmed."
}

rollback_access() {
    local failed=0 status
    status=$(cat "$RUN_DIR/status")
    if [[ $status != pending ]]; then
        if ((AUTOMATIC)); then return 0; fi
        die 'Only a pending access transaction can be rolled back.'
    fi
    log "Restoring access configuration for $RUN_ID."
    if ((DOCKER_INSTALL)); then release_docker_masks || failed=1; fi
    timeout 30 systemctl stop fail2ban || failed=1
    if ((F2B_TEMP_MASK)); then
        systemctl unmask --runtime fail2ban.service || failed=1
        F2B_TEMP_MASK=0
    fi
    restore_group access || failed=1
    if ((UFW_ACTIVE)); then timeout 30 ufw --force enable || failed=1
    else timeout 30 ufw --force disable || failed=1; fi
    if ((UFW_ENABLED)); then systemctl enable ufw || failed=1
    else systemctl disable ufw || failed=1; fi
    if sshd -t; then timeout 30 systemctl reload ssh || failed=1; else failed=1; fi
    if ((F2B_ENABLED)); then systemctl enable fail2ban || failed=1
    else systemctl disable fail2ban || failed=1; fi
    if ((F2B_ACTIVE)); then timeout 30 systemctl start fail2ban || failed=1; fi
    if ((failed)); then
        log 'Rollback had errors. Backups and pending state retained; use the recovery console to retry.'
        return 1
    fi
    printf 'rolled-back\n' > "$RUN_DIR/status"
    if [[ -f $STATE_DIR/pending && $(cat "$STATE_DIR/pending") == "$RUN_ID" ]]; then rm -f "$STATE_DIR/pending"; fi
    cleanup_timer
    ACCESS_ARMED=0
    log 'Access configuration restored; installed packages and system options were retained.'
}

# Module: lib/wizard.sh

# Only the public wizard entry requires a terminal. The collectors are also tested
# with scripted input; EOF always exits before any system changes are requested.
wizard_read() {
    local prompt=$1 fallback=${2:-}
    local display=${3:-${fallback:-无，必填}}
    printf '%s [默认：%s]：' "$prompt" "$display"
    if ! IFS= read -r ANSWER; then
        printf '\n输入已结束，退出向导。\n'
        exit 0
    fi
    ANSWER=${ANSWER:-$fallback}
}

wizard_choice() {
    local prompt=$1 fallback=$2 allowed=$3
    while :; do
        wizard_read "$prompt" "$fallback"
        if [[ $ANSWER =~ ^[0-9]+$ ]]; then
            case " $allowed " in *" $ANSWER "*) return 0 ;; esac
        fi
        printf '请选择列出的编号。\n'
    done
}

wizard_yes() {
    local prompt=$1
    while :; do
        wizard_read "$prompt（y/n）" n 'n（否）'
        case "$ANSWER" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) printf '请输入 y 或 n；回车选择 n（否）。\n' ;;
        esac
    done
}

wizard_number() {
    local prompt=$1 fallback=$2 minimum=$3 maximum=$4
    while :; do
        wizard_read "$prompt" "$fallback"
        if (number_between "$ANSWER" "$minimum" "$maximum") 2>/dev/null; then
            ANSWER=$((10#$ANSWER)); return 0
        fi
        printf '请输入 %s 到 %s 之间的整数。\n' "$minimum" "$maximum"
    done
}

wizard_addresses() {
    local prompt=$1 display=${2:-无，必填} item valid
    while :; do
        wizard_read "$prompt" '' "$display"
        VALUES=()
        IFS=', ' read -r -a VALUES <<< "$ANSWER"
        valid=1
        for item in ${VALUES[@]+"${VALUES[@]}"}; do
            if ! (validate_address "$item") 2>/dev/null; then valid=0; fi
        done
        if ((valid)); then return 0; fi
        printf '地址格式不正确，请输入 IP 或 CIDR，多个用空格或逗号分隔。\n'
    done
}

wizard_timezone() {
    local current=Etc/UTC link
    if [[ -r /etc/timezone ]]; then
        IFS= read -r current < /etc/timezone || current=Etc/UTC
    elif [[ -L /etc/localtime ]]; then
        link=$(readlink /etc/localtime)
        [[ $link != */zoneinfo/* ]] || current=${link#*/zoneinfo/}
    fi
    [[ -f /usr/share/zoneinfo/$current ]] || current=Etc/UTC
    printf '\n时区：1) 保留当前 %s  2) 北京时间  3) UTC  4) 自定义\n' "$current"
    wizard_choice '选择' 1 '1 2 3 4'
    case "$ANSWER" in
        1) TIMEZONE=$current ;; 2) TIMEZONE=Asia/Shanghai ;; 3) TIMEZONE=Etc/UTC ;;
        4)
            while :; do
                wizard_read '时区名称（例如 Asia/Tokyo）'
                if [[ -n $ANSWER && $ANSWER != /* && $ANSWER != *..* && -f /usr/share/zoneinfo/$ANSWER ]]; then
                    TIMEZONE=$ANSWER; break
                fi
                printf '未找到这个时区，请重新输入。\n'
            done ;;
    esac
}

wizard_ssh() {
    local client=${SSH_CONNECTION%% *}
    printf '\nSSH：回车保留现有端口，输入新端口则额外添加并保留旧端口。\n'
    while :; do
        wizard_read '新增 SSH 端口' '' '不新增，保留现有端口'
        if [[ -z $ANSWER ]]; then SSH_PORT=''; break; fi
        if (number_between "$ANSWER" 1 65535) 2>/dev/null; then SSH_PORT=$((10#$ANSWER)); break; fi
        printf '端口必须为 1–65535。\n'
    done
    printf 'SSH 来源：1) 所有地址  2) 仅当前管理 IP  3) 指定 IP/网段\n'
    wizard_choice '选择' 1 '1 2 3'
    case "$ANSWER" in
        1) SSH_SOURCES=() ;;
        2)
            [[ -n $client ]] || die '无法识别当前 SSH 地址，请通过 SSH 运行向导。'
            validate_address "$client"
            SSH_SOURCES=("$client") ;;
        3)
            while :; do
                wizard_addresses '允许的来源 IP/网段'
                if ((${#VALUES[@]})); then SSH_SOURCES=("${VALUES[@]}"); break; fi
            done ;;
    esac
    printf '\n导入公钥：1) 跳过  2) 服务器上的公钥文件  3) GitHub 账号\n'
    wizard_choice '选择' 1 '1 2 3'
    case "$ANSWER" in
        2)
            while :; do
                wizard_read '公钥文件路径'
                if [[ -n $ANSWER && -f $ANSWER && -r $ANSWER ]]; then KEY_FILE=$ANSWER; break; fi
                printf '文件不存在或不可读。\n'
            done ;;
        3)
            while :; do
                wizard_read 'GitHub 用户名'
                if [[ $ANSWER =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,38}$ ]]; then GITHUB_USER=$ANSWER; break; fi
                printf '用户名格式不正确。\n'
            done ;;
    esac
    if [[ -n $KEY_FILE || -n $GITHUB_USER ]]; then
        while :; do
            wizard_read '安装到哪个已有用户' "${SUDO_USER:-root}"
            if [[ $ANSWER =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] && getent passwd "$ANSWER" >/dev/null; then
                KEY_USER=$ANSWER; break
            fi
            printf '请输入一个已存在的本地用户。\n'
        done
    fi
    AUTH_INFO=${SSH_USER_AUTH:-}
    if (verify_key_session) >/dev/null 2>&1; then
        if wizard_yes '当前会话已通过公钥验证，是否关闭密码及键盘交互认证'; then DISABLE_PASSWORD=1; fi
        if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
            if wizard_yes '是否禁止 root 通过 SSH 登录'; then DISABLE_ROOT=1; fi
        fi
    else
        printf '本次保留登录策略。首次初始化后，用公钥重新登录并运行向导，才能选择关闭密码登录。\n'
    fi
}

wizard_firewall() {
    printf '\n业务端口：1) 只新增 SSH 放行  2) 网站 HTTP/HTTPS  3) 自定义\n'
    wizard_choice '选择' 1 '1 2 3'
    local port proto source
    case "$ANSWER" in
        2) ALLOW_RULES+=(80/tcp 443/tcp) ;;
        3)
            while :; do
                wizard_number '端口号' '' 1 65535; port=$ANSWER
                printf '协议：1) TCP  2) UDP\n'
                wizard_choice '选择' 1 '1 2'
                proto=tcp; [[ $ANSWER == 1 ]] || proto=udp
                while :; do
                    wizard_addresses '允许的来源 IP/网段' '所有地址'
                    if ((${#VALUES[@]} <= 1)); then break; fi
                    printf '每条规则只能填写一个来源，可继续添加规则。\n'
                done
                source=${VALUES[0]:-}
                ALLOW_RULES+=("$port/$proto${source:+@$source}")
                if ! wizard_yes '继续添加端口'; then break; fi
            done ;;
    esac
    wizard_addresses 'Fail2ban 信任 IP/网段' '不添加额外白名单'
    TRUSTED_IPS=(${VALUES[@]+"${VALUES[@]}"})
}

wizard_memory_kib() {
    awk '$1 == "MemTotal:" {print $2; exit}' /proc/meminfo 2>/dev/null
}

wizard_swap_size() {
    local memory_kib suggested=2048
    memory_kib=$(wizard_memory_kib || true)
    if [[ $memory_kib =~ ^[0-9]+$ ]] && ((memory_kib >= 8 * 1024 * 1024 && memory_kib <= 64 * 1024 * 1024)); then
        suggested=$((memory_kib / 2048))
        printf '检测到物理内存约 %s MiB，磁盘 Swap 默认按内存的一半设置，可手动修改。\n' "$((memory_kib / 1024))"
    else
        printf '物理内存不在 8–64 GiB 范围内或无法读取，磁盘 Swap 默认 2048 MiB，可手动修改。\n'
    fi
    wizard_number '磁盘 Swap 大小（MiB）' "$suggested" 256 65536
    SWAP_MIB=$ANSWER
}

wizard_advanced() {
    cat <<'EOF'

高级设置（按需选择）：
  BBR：切换 TCP 拥塞控制算法，影响网络传输。
  交换空间：可选磁盘 Swap、压缩内存 ZRAM，或两者同时使用。
  文件描述符上限：调整进程可同时打开的文件和网络连接数量上限。
  主机名：修改这台服务器的名称。
  DNS：修改域名解析服务器地址，仅支持已有 systemd-resolved 的系统。
  依赖清理：删除 APT 判定不再需要的软件包。
  确认窗口：设置通过新 SSH 连接确认配置的时限，默认 10 分钟。
选择 y 后会逐项询问，不会一次启用全部选项；回车跳过，保持这些设置和默认确认时限。
EOF
    if ! wizard_yes '是否进入高级设置'; then return 0; fi
    if wizard_yes '启用 BBR 拥塞控制'; then BBR=1; fi
    printf '交换空间：\n1) 保持现状\n2) 新建磁盘 Swap\n3) 配置 ZRAM（重启后生效）\n4) ZRAM + 磁盘 Swap（ZRAM 优先，磁盘提供额外容量）\n'
    wizard_choice '选择' 1 '1 2 3 4'
    case "$ANSWER" in
        2) wizard_swap_size ;;
        3) wizard_number 'ZRAM 逻辑容量占物理内存百分比（%）' 50 1 100; ZRAM_PERCENT=$ANSWER ;;
        4)
            wizard_number 'ZRAM 逻辑容量占物理内存百分比（%）' 50 1 100; ZRAM_PERCENT=$ANSWER
            wizard_swap_size
            printf 'ZRAM 优先级为 100，脚本管理的磁盘 Swap 为 10；ZRAM 在手动重启后生效。\n' ;;
    esac
    if wizard_yes '调整文件描述符上限'; then
        wizard_number '文件描述符上限' 65535 1024 1048576; NOFILE=$ANSWER
    fi
    while :; do
        wizard_read '新主机名' '' '保留现有主机名'
        if [[ -z $ANSWER || ( ${#ANSWER} -le 63 && $ANSWER =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ) ]]; then
            HOSTNAME_VALUE=$ANSWER; break
        fi
        printf '请输入不带域名的短主机名，仅包含字母、数字和中划线。\n'
    done
    while :; do
        wizard_addresses 'DNS 地址（仅支持已有 systemd-resolved）' '保留现有 DNS 配置'
        DNS=$(IFS=,; printf '%s' "${VALUES[*]:-}")
        [[ $DNS == */* ]] || break
        printf 'DNS 只能填写 IP 地址，不能填写网段。\n'
    done
    if wizard_yes '清理 APT 判定不再需要的依赖（autoremove）'; then AUTOREMOVE=1; fi
    wizard_number '新连接确认窗口（分钟）' 10 2 60
    ROLLBACK_SECONDS=$((ANSWER * 60))
}

wizard_docker() {
    printf '\nDocker：使用官方软件源安装 Engine、Compose 和 Buildx。\n'
    if wizard_yes '是否安装 Docker（已安装官方版时补齐或更新组件）'; then
        DOCKER_INSTALL=1
        printf '提示：Docker 发布的容器端口可能绕过普通 UFW 入站规则，需要单独控制访问。\n'
    fi
}

wizard_summary() {
    printf '\n========== 执行清单 ==========\n'
    printf '基础：更新已装软件、安装工具、UFW、Fail2ban、安全更新、NTP、日志管理与配置备份\n'
    printf '时区：%s\n' "$TIMEZONE"
    printf 'SSH 端口：保留现有%s\n' "${SSH_PORT:+，新增 $SSH_PORT}"
    printf 'SSH 允许来源：%s\n' "${SSH_SOURCES[*]:-所有地址}"
    printf '新增业务端口：%s\n' "${ALLOW_RULES[*]:-无}"
    printf '已有 UFW 规则将保留；新增 SSH 放行规则优先匹配。\n'
    printf 'Fail2ban：10 分钟内失败 5 次封禁 1 小时；额外白名单：%s\n' "${TRUSTED_IPS[*]:-无}"
    if [[ -n $KEY_FILE || -n $GITHUB_USER ]]; then
        printf '公钥导入：%s → 用户 %s\n' "${KEY_FILE:-GitHub:$GITHUB_USER}" "$KEY_USER"
    else printf '公钥导入：跳过\n'; fi
    if ((DISABLE_PASSWORD)); then printf '密码/键盘交互登录：关闭\n'; else printf '密码登录策略：保留\n'; fi
    if ((DISABLE_ROOT)); then printf 'root SSH 登录：禁止\n'; else printf 'root 登录策略：保留\n'; fi
    if ((DOCKER_INSTALL)); then
        printf 'Docker：安装官方 Engine、Compose、Buildx，并启用开机启动\n'
        printf 'Docker 发布端口需单独限制访问；安装和升级不会随访问配置回滚。\n'
    else printf 'Docker：不执行安装模块\n'; fi
    if ((BBR)); then printf 'BBR：启用\n'; fi
    if ((SWAP_MIB)); then printf '新建 Swap：%s MiB\n' "$SWAP_MIB"; fi
    if ((ZRAM_PERCENT)); then printf 'ZRAM：内存的 %s%%，重启生效\n' "$ZRAM_PERCENT"; fi
    if ((NOFILE)); then printf '文件描述符上限：%s\n' "$NOFILE"; fi
    [[ -z $HOSTNAME_VALUE ]] || printf '主机名：%s\n' "$HOSTNAME_VALUE"
    [[ -z $DNS ]] || printf 'DNS：%s\n' "$DNS"
    if ((AUTOREMOVE)); then printf '删除无用依赖：启用\n'; fi
    printf '访问配置确认窗口：%s 分钟；未确认将自动回滚访问配置\n' "$((ROLLBACK_SECONDS / 60))"
    printf '软件升级和其他系统配置不随访问回滚撤销；不会自动重启。\n'
}

wizard_pending() {
    RUN_ID=$(cat "$STATE_DIR/pending")
    [[ $RUN_ID =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || die '待确认运行记录无效。'
    printf '\n检测到尚未确认的初始化：%s\n' "$RUN_ID"
    printf '1) 确认：我已从新 SSH 连接登录\n2) 立即回滚访问配置\n3) 查看状态\n0) 退出，保留定时回滚\n'
    wizard_choice '选择' 0 '0 1 2 3'
    case "$ANSWER" in
        1) COMMAND=confirm ;;
        2)
            COMMAND=cancelled
            if wizard_yes '确认立即恢复此前的 SSH、防火墙和 Fail2ban 配置'; then COMMAND=rollback; fi ;;
        3) COMMAND=status ;;
        0) COMMAND=cancelled ;;
    esac
}

wizard() {
    [[ -t 0 && -t 1 ]] || die '交互向导需要终端。请直接在 SSH 终端运行；仅预览请使用 plan，自动化请显式使用 apply。'
    INTERACTIVE=1
    printf '\nDebian 13 服务器初始化向导\n每项均显示默认值，回车采用；标注“无，必填”的项目需输入。Ctrl+C 随时退出。\n'
    if [[ -r $STATE_DIR/pending ]]; then wizard_pending; return 0; fi
    printf '\n1) 配置并初始化\n2) 仅预览配置（不修改系统）\n3) 查看当前状态\n0) 退出\n'
    wizard_choice '选择' 1 '0 1 2 3'
    local mode=$ANSWER
    case "$mode" in
        0) COMMAND=cancelled; return 0 ;; 3) COMMAND=status; return 0 ;;
        1) require_host ;;
    esac
    SSH_CONNECTION=${SSH_CONNECTION:-}
    wizard_timezone
    wizard_ssh
    wizard_firewall
    wizard_docker
    wizard_advanced
    validate_options
    wizard_summary
    COMMAND=cancelled
    if [[ $mode == 2 ]]; then
        printf '\n预览结束，未修改系统。\n'
    elif wizard_yes '开始执行以上操作'; then
        COMMAND=apply
    else
        printf '\n已取消，未修改系统。\n'
    fi
}

wizard_wait() {
    printf '\n请保留当前终端。在新 SSH 连接中再次运行脚本，选择“确认”。\n'
    if [[ ${SUDO_USER:-root} == root ]]; then
        printf '新连接运行：bash %q\n' "$RUN_DIR/runner/bootstrap.sh"
    else
        printf '新连接运行：sudo --preserve-env=SSH_CONNECTION,SSH_USER_AUTH bash %q\n' "$RUN_DIR/runner/bootstrap.sh"
    fi
    printf '正在等待确认或回滚。Ctrl+C 仅退出等待，不会取消定时回滚。\n'
    while [[ $(cat "$RUN_DIR/status") == pending ]]; do sleep 2; done
    case "$(cat "$RUN_DIR/status")" in
        confirmed) printf '新连接已确认，初始化完成。\n' ;;
        rolled-back) printf '访问配置已回滚；软件升级和其他系统配置保留。\n' ;;
    esac
}

main() {
    defaults
    parse_args "$@"
    if [[ $COMMAND == wizard ]]; then
        wizard
        [[ $COMMAND != cancelled ]] || return 0
    fi
    validate_options
    if [[ $COMMAND == plan ]]; then print_plan; return; fi
    require_host
    mkdir -p "$STATE_DIR/runs"
    chmod 700 "$STATE_DIR" "$STATE_DIR/runs"
    exec 9>"$STATE_DIR/operation.lock"
    flock -w 120 9 || die 'Another operation is running.'
    case "$COMMAND" in
        apply) apply_all ;;
        status) report ;;
        confirm) confirm_access ;;
        rollback) load_run; rollback_access ;;
    esac
    flock -u 9
    if [[ $COMMAND == apply && $INTERACTIVE == 1 ]]; then wizard_wait; fi
}

main "$@"
