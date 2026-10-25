#!/usr/bin/env bash

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
