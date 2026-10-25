#!/usr/bin/env bash

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
