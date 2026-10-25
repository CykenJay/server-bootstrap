"""Behavior tests: temporary files and mocked service commands, never host changes."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BootstrapTests(unittest.TestCase):
    def shell(self, code, *, ok=True, env=None):
        prelude = '''set -Eeuo pipefail
source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/system.sh"
source "$PROJECT/lib/access.sh"
defaults
'''
        result = subprocess.run(
            ['bash', '-c', prelude + code], text=True, capture_output=True,
            env={**os.environ, 'PROJECT': str(ROOT), **(env or {})},
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def test_noninteractive_default_refuses_changes(self):
        result = subprocess.run(['bash', str(ROOT / 'bootstrap.sh')], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('需要终端', result.stderr)

    def test_valid_options_and_decimal_normalization(self):
        self.shell('''parse_args plan --ssh-port 02222 --allow 443/tcp --allow 53/udp@2001:db8::/32 --trusted-ip 192.0.2.0/24 --timezone Asia/Shanghai
validate_options
[[ $SSH_PORT == 2222 && ${#ALLOW_RULES[@]} == 2 ]]
''')

    def test_invalid_arguments(self):
        for args in ['--ssh-port 0', '--ssh-port 65536', '--ssh-port -1', '--ssh-port',
                     '--allow 22/sctp', '--allow 22/tcp@999.1.1.1', '--allow 1:65535/tcp',
                     '--trusted-ip "127.0.0.1;id"', '--rollback-seconds 1',
                     '--timezone ../../etc', '--hostname a.b', '--github-user ../root',
                     '--swap-mib 255 --zram-percent 50', '--zram-percent 101', '--dns 1.1.1.1,',
                     '--key-file a --github-user octocat', '--unknown']:
            with self.subTest(args=args):
                self.shell(f'parse_args plan {args}\nvalidate_options', ok=False)

    def test_combined_swap_and_zram_configuration(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.shell('''RUN_DIR="$TMP"
parse_args plan --swap-mib 2048 --zram-percent 50
validate_options
configure_swap() { printf '%s %s\\n' "$*" "$SWAP_MIB" > "$TMP/swap-call"; }
apt_run() { :; }
write_config() { cat > "$TMP/zram.conf"; }
configure_optional
''', env={'TMP': tmp})
            self.assertEqual((Path(tmp) / 'swap-call').read_text().strip(),
                             '/var/lib/server-bootstrap.swap /etc/fstab 2048')
            config = (Path(tmp) / 'zram.conf').read_text()
            self.assertIn('zram-size = ram * 50 / 100', config)
            self.assertIn('swap-priority = 100', config)

    def test_swap_priority_is_persisted_without_disabling_active_swap(self):
        for priority in ['', '-2', '200', '10']:
            with self.subTest(priority=priority), tempfile.TemporaryDirectory() as tmp:
                folder = Path(tmp)
                swap = folder / 'swap'
                swap.touch()
                fstab = folder / 'fstab'
                original = '# keep comment\n/dev/other none swap sw,pri=20 0 0\n'
                fstab.write_text(original + f'{swap} none swap sw,discard,pri=200 0 0 # managed\n')
                result = self.shell('''RUN_DIR="$TMP/run"; mkdir -p "$RUN_DIR"
SWAP_MIB=1024
stat() { echo 1073741824; }
blkid() { echo swap; }
swapon() {
    if [[ $1 == --show=NAME,PRIO ]]; then
        if [[ -n $PRIORITY ]]; then printf '%s %s\\n' "$TMP/swap" "$PRIORITY"; fi
    else
        printf '%s\\n' "$*" >> "$TMP/activations"
        PRIORITY=10
    fi
}
swapoff() { echo 'Unexpected swapoff' >&2; exit 99; }
configure_swap "$TMP/swap" "$TMP/fstab"
cp "$TMP/fstab" "$TMP/once"
configure_swap "$TMP/swap" "$TMP/fstab"
cmp "$TMP/once" "$TMP/fstab"
''', env={'TMP': tmp, 'PRIORITY': priority})
                self.assertEqual(fstab.read_text(), original + f'{swap} none swap sw,discard,pri=10 0 0 # managed\n')
                activation = folder / 'activations'
                if priority:
                    self.assertFalse(activation.exists())
                    if priority != '10':
                        self.assertIn('after a manual reboot', result.stdout)
                else:
                    self.assertEqual(activation.read_text(), f'--priority 10 {swap}\n')

    def test_swap_fstab_adds_missing_entry(self):
        result = self.shell("printf '# existing\\n' | render_swap_fstab /var/lib/server-bootstrap.swap")
        self.assertEqual(result.stdout, '# existing\n/var/lib/server-bootstrap.swap none swap sw,pri=10 0 0\n')

    def test_run_id_cannot_escape_state_directory(self):
        self.shell('parse_args rollback ../../etc', ok=False)

    def test_backup_retains_first_version_and_restores_absent_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.shell('''RUN_DIR="$TMP/run"
mkdir -p "$TMP/config"
printf original > "$TMP/config/present"
save_file "$TMP/config/present" access
printf changed > "$TMP/config/present"
save_file "$TMP/config/present" access
save_file "$TMP/config/absent" access
printf new > "$TMP/config/absent"
restore_group access
[[ $(cat "$TMP/config/present") == original && ! -e $TMP/config/absent ]]
''', env={'TMP': tmp})

    def test_write_refuses_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.shell('''RUN_DIR="$TMP/run"
printf safe > "$TMP/original"
ln -s "$TMP/original" "$TMP/link"
write_config "$TMP/link" <<< changed
''', ok=False, env={'TMP': tmp})
            self.assertEqual((Path(tmp) / 'original').read_text(), 'safe')

    def test_key_auth_is_required_before_disabling_passwords(self):
        self.shell('DISABLE_PASSWORD=1\nAUTH_INFO=\nverify_key_session', ok=False)

    def test_root_cannot_disable_own_root_login(self):
        with tempfile.TemporaryDirectory() as tmp:
            auth = Path(tmp) / 'auth'
            auth.write_text('publickey ssh-ed25519 sample\n')
            self.shell('''DISABLE_ROOT=1
AUTH_INFO="$TMP/auth"
SSH_CONNECTION='192.0.2.1 50000 192.0.2.2 22'
SUDO_USER=root
stat() { printf '0\n'; }
id() { printf '0\n'; }
verify_key_session
''', ok=False, env={'TMP': tmp})

    def test_same_connection_cannot_confirm(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.shell('''RUN_DIR="$TMP"
STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
RUN_ID=20261025T000000Z-1
printf pending > "$RUN_DIR/status"
printf '%s' "$RUN_ID" > "$STATE_DIR/pending"
load_run() { :; }
SSH_CONNECTION='192.0.2.1 50000 192.0.2.2 22'
ORIGINAL_CONNECTION=$SSH_CONNECTION
confirm_access
''', ok=False, env={'TMP': tmp})

    def test_confirm_checks_new_port_before_cancelling_timer(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.shell('''RUN_DIR="$TMP"; STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
RUN_ID=20261025T000000Z-1
printf pending > "$RUN_DIR/status"; printf '%s' "$RUN_ID" > "$STATE_DIR/pending"
load_run() { :; }
ORIGINAL_CONNECTION='192.0.2.1 50000 192.0.2.2 22'
SSH_CONNECTION='192.0.2.1 50001 192.0.2.2 22'
REQUIRED_PORT=2222
cleanup_timer() { touch "$TMP/cancelled"; }
confirm_access
''', ok=False, env={'TMP': tmp})
            self.assertFalse((Path(tmp) / 'cancelled').exists())

    def test_successful_confirm_records_state_before_timer_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.shell('''RUN_DIR="$TMP"; STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
RUN_ID=20261025T000000Z-1
printf pending > "$RUN_DIR/status"; printf '%s' "$RUN_ID" > "$STATE_DIR/pending"
load_run() { :; }
ORIGINAL_CONNECTION='192.0.2.1 50000 192.0.2.2 22'
SSH_CONNECTION='192.0.2.1 50001 192.0.2.2 2222'
REQUIRED_PORT=2222; EXPECTED_USER=operator; SUDO_USER=operator
verify_ssh_policy() { :; }; verify_access() { :; }
cleanup_timer() { [[ $(cat "$RUN_DIR/status") == confirmed && ! -f $STATE_DIR/pending ]]; }
confirm_access
''', env={'TMP': tmp})

    def test_queued_rollback_does_not_touch_confirmed_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.shell('''RUN_DIR="$TMP"; AUTOMATIC=1
printf confirmed > "$RUN_DIR/status"
restore_group() { exit 99; }
rollback_access
''', env={'TMP': tmp})

    def test_failed_restore_retains_pending_state_for_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.shell('''RUN_DIR="$TMP"; RUN_ID=20261025T000000Z-1
printf pending > "$RUN_DIR/status"
F2B_ACTIVE=0; F2B_ENABLED=0; UFW_ACTIVE=0; UFW_ENABLED=0
timeout() { :; }; systemctl() { :; }; sshd() { :; }
restore_group() { return 1; }
cleanup_timer() { touch "$TMP/cancelled"; }
rollback_access
''', ok=False, env={'TMP': tmp})
            self.assertEqual((Path(tmp) / 'status').read_text(), 'pending')
            self.assertFalse((Path(tmp) / 'cancelled').exists())

    def test_explicit_failure_also_runs_exit_rollback(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.shell('''STATE_DIR="$TMP"
preflight() { :; }; install_packages() { :; }; configure_system() { :; }
prepare_access() { :; }; arm_rollback() { ACCESS_ARMED=1; }
configure_access() { die 'deliberate failure'; }
rollback_access() { touch "$TMP/restored"; }
apply_all
''', ok=False, env={'TMP': tmp})
            self.assertTrue((Path(tmp) / 'restored').exists())

    def test_ssh_match_override_is_detected(self):
        self.shell('''DISABLE_PASSWORD=1
CLIENT_IP=192.0.2.1; SERVER_IP=192.0.2.2; REQUIRED_PORT=22
sshd() { printf 'pubkeyauthentication yes\nexposeauthinfo yes\npasswordauthentication yes\n'; }
verify_ssh_policy
''', ok=False)

    def test_rerun_keeps_existing_auth_restrictions(self):
        with tempfile.TemporaryDirectory() as tmp:
            previous = Path(tmp) / 'previous'
            previous.write_text('PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n')
            out = self.shell('SSH_PORTS=(22 2222)\nrender_ssh_config "$TMP/previous"', env={'TMP': tmp}).stdout
            self.assertIn('PasswordAuthentication no\n', out)
            self.assertIn('KbdInteractiveAuthentication no\n', out)
            self.assertIn('PermitRootLogin no\n', out)
            self.assertIn('Port 2222\n', out)

    def test_initial_ssh_configuration_keeps_login_policy(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = self.shell('SSH_PORTS=(22)\nrender_ssh_config "$TMP/absent"', env={'TMP': tmp}).stdout
            self.assertNotIn('PasswordAuthentication', out)
            self.assertNotIn('PermitRootLogin', out)

    def test_successful_rollback_restores_original_service_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.shell('''RUN_DIR="$TMP"; STATE_DIR="$TMP/state"; mkdir -p "$STATE_DIR"
RUN_ID=20261025T000000Z-1
printf pending > "$RUN_DIR/status"; printf '%s' "$RUN_ID" > "$STATE_DIR/pending"
F2B_ACTIVE=1; F2B_ENABLED=0; UFW_ACTIVE=0; UFW_ENABLED=0
systemctl() { printf '%s\\n' "$*" >> "$TMP/commands"; }
ufw() { printf '%s\\n' "$*" >> "$TMP/commands"; }
timeout() { shift; "$@"; }; sshd() { :; }; restore_group() { :; }
cleanup_timer() { :; }
rollback_access
[[ $(cat "$RUN_DIR/status") == rolled-back && ! -f $STATE_DIR/pending ]]
''', env={'TMP': tmp})
            commands = (Path(tmp) / 'commands').read_text()
            self.assertIn('--force disable', commands)
            self.assertIn('disable fail2ban', commands)
            self.assertIn('start fail2ban', commands)

    def test_fail2ban_journal_and_ufw_configuration(self):
        out = self.shell('''SSH_PORTS=(22 2222)
TRUSTED_IPS=(192.0.2.0/24 2001:db8::/32)
render_fail2ban_config
''').stdout
        for line in ['backend = systemd', 'banaction = ufw', 'port = 22,2222',
                     'findtime = 10m', 'bantime = 1h', 'maxretry = 5', '2001:db8::/32']:
            self.assertIn(line, out)


if __name__ == '__main__':
    unittest.main()
