#!/usr/bin/env bash
# Run only inside an expendable Debian 13 container. Does not enable a firewall.
set -Eeuo pipefail
[[ -f /.dockerenv ]] || { echo 'This test requires an expendable Docker container.' >&2; exit 1; }
cd /source
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends openssh-server ufw fail2ban python3-systemd \
    unattended-upgrades systemd systemd-timesyncd logrotate shellcheck kmod \
    > /tmp/server-bootstrap-test-packages.log 2>&1 || {
        tail -50 /tmp/server-bootstrap-test-packages.log
        exit 1
    }
shellcheck -x bootstrap.sh build.sh tests/*.sh
python3 -m unittest discover -s tests -v
bundle_dir=$(mktemp -d)
bash build.sh "$bundle_dir/bootstrap.sh"
shellcheck "$bundle_dir/bootstrap.sh"
bash "$bundle_dir/bootstrap.sh" plan

source lib/common.sh
source lib/system.sh
source lib/access.sh
defaults
RUN_DIR=$(mktemp -d)
mkdir -p /run/sshd
SSH_PORTS=(22 2222)
DISABLE_PASSWORD=1
DISABLE_ROOT=1
render_ssh_config /dev/null > /etc/ssh/server-bootstrap.conf
sed -i '1i Include /etc/ssh/server-bootstrap.conf' /etc/ssh/sshd_config
sshd -t
CLIENT_IP=192.0.2.1 SERVER_IP=192.0.2.2 REQUIRED_PORT=2222 EXPECTED_USER=root
verify_ssh_policy
# Rerunning with no auth flags must retain previous restrictions.
DISABLE_PASSWORD=0 DISABLE_ROOT=0
render_ssh_config /etc/ssh/server-bootstrap.conf > "$RUN_DIR/second.conf"
grep -q '^PasswordAuthentication no$' "$RUN_DIR/second.conf"
grep -q '^PermitRootLogin no$' "$RUN_DIR/second.conf"
render_fail2ban_config > /etc/fail2ban/jail.d/99-server-bootstrap.local
fail2ban-client -t
fail2ban-client -d > "$RUN_DIR/fail2ban-effective"
grep -q "'add', 'sshd', 'systemd'" "$RUN_DIR/fail2ban-effective"
grep -q "'addaction', 'ufw'" "$RUN_DIR/fail2ban-effective"
ufw --dry-run prepend allow proto tcp from 192.0.2.0/24 to any port 2222 comment server-bootstrap-ssh >/dev/null
ufw --dry-run allow proto udp from 2001:db8::/32 to any port 53 comment server-bootstrap >/dev/null

# Check actual generated non-access config with service operations stubbed out.
systemctl() { return 0; }
timedatectl() { return 0; }
systemd-tmpfiles() { return 0; }
journalctl() { return 0; }
sysctl() { return 0; }
apt_run() { return 0; }
configure_system
apt-config dump > "$RUN_DIR/apt-effective"
grep -q 'origin=Debian,codename=trixie-security,label=Debian-Security' "$RUN_DIR/apt-effective"
if grep '^Unattended-Upgrade::Origins-Pattern:: ' "$RUN_DIR/apt-effective" | grep -v 'trixie-security'; then
    echo 'Unexpected automatic update origin' >&2
    exit 1
fi
grep -q 'Unattended-Upgrade::Automatic-Reboot "false"' "$RUN_DIR/apt-effective"
logrotate --debug /etc/logrotate.conf
# Validate the persistent rollback units with the actual systemd parser.
BASE_DIR=/source
STATE_DIR="$RUN_DIR/state"
mkdir -p "$STATE_DIR"
RUN_ID=20261025T000000Z-1
arm_rollback
systemd-analyze verify "/etc/systemd/system/server-bootstrap-rollback-$RUN_ID.service" \
    "/etc/systemd/system/server-bootstrap-rollback-$RUN_ID.timer"
echo 'Debian 13 configuration checks passed.'
