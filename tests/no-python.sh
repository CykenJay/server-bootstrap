#!/usr/bin/env bash
# Exercise the deployment bundle in a fresh Debian container without Python.
set -Eeuo pipefail
[[ -f /.dockerenv ]] || { echo 'Use a disposable Docker container.' >&2; exit 1; }
if command -v python3 >/dev/null; then echo 'This test requires Python to be absent.' >&2; exit 1; fi
work=$(mktemp -d)
cp /source/dist/bootstrap.sh "$work/bootstrap.sh"
bash "$work/bootstrap.sh" plan --ssh-source 2001:db8::/32 --allow 53/udp@192.0.2.0/24 > "$work/plan"
sed '$d' "$work/bootstrap.sh" > "$work/definitions.sh"
# shellcheck source=/dev/null
source "$work/definitions.sh"
# Used by helper functions loaded from the deployment bundle.
# shellcheck disable=SC2034
RUN_DIR="$work"
validate_address ::ffff:192.0.2.1/120
address_in_network 2001:db8::1 2001:db8::ffff/64
if address_in_network 2001:db9::1 2001:db8::/32; then exit 1; fi
printf 'Port 22\n' > "$work/sshd_config"
ensure_ssh_include "$work/sshd_config"
printf '127.0.1.1 old-host\n' > "$work/hosts"
update_hosts_hostname "$work/hosts" new-host
grep -q 'new-host old-host' "$work/hosts"

# OpenSSH tools do not require Python. These helpers must work before installing
# UFW/Fail2ban and their package-managed dependencies.
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends openssh-client > "$work/packages.log" 2>&1
if command -v python3 >/dev/null; then echo 'Unexpected Python installation.' >&2; exit 1; fi
ssh-keygen -q -t ed25519 -N '' -f "$work/key"
printf 'restrict %s\n' "$(cat "$work/key.pub")" > "$work/authorized_keys"
append_public_keys "$work/authorized_keys" "$work/key.pub"
[[ $(wc -l < "$work/authorized_keys") -eq 1 ]]
printf 'Runtime helper checks passed without Python.\n'
