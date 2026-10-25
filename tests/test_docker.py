"""Docker installation policy and service ordering without changing the host."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PRELUDE = '''set -Eeuo pipefail
source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/docker.sh"
source "$PROJECT/lib/system.sh"
source "$PROJECT/lib/access.sh"
defaults
'''


class DockerTests(unittest.TestCase):
    def run_shell(self, code, *, ok=True, env=None):
        result = subprocess.run(['bash', '-c', PRELUDE + code], capture_output=True, text=True,
                                env={**os.environ, 'PROJECT': str(ROOT), **(env or {})})
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_default_and_explicit_option(self):
        self.run_shell('''[[ $DOCKER_INSTALL == 0 ]]
parse_args plan --docker
validate_options
[[ $DOCKER_INSTALL == 1 ]]
print_plan
''')

    def test_conflicting_packages_stop_before_mutations(self):
        for name in ['docker.io', 'docker-compose', 'docker-doc', 'docker-buildx', 'podman-docker', 'containerd', 'runc']:
            with self.subTest(name=name):
                result = self.run_shell('''dpkg() { echo arm64; }
package_installed() { [[ $1 == "$CONFLICT" ]]; }
docker_preflight
''', ok=False, env={'CONFLICT': name})
                self.assertIn('Conflicting package ' + name, result.stderr)

    def test_unsupported_architecture(self):
        self.run_shell('dpkg() { echo riscv64; }; docker_preflight', ok=False)

    def test_duplicate_repo_is_rejected_but_comments_are_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'sources.list.d').mkdir()
            repo = root / 'sources.list.d/old-docker.list'
            repo.write_text('# deb https://download.docker.com/linux/debian trixie stable\n')
            self.run_shell('check_docker_sources "$WORK"', env={'WORK': tmp})
            repo.write_text('deb https://download.docker.com/linux/debian trixie stable\n')
            self.run_shell('check_docker_sources "$WORK"', ok=False, env={'WORK': tmp})

    def test_official_source_uses_explicit_key_and_target_release(self):
        output = self.run_shell('dpkg() { echo arm64; }; render_docker_source').stdout
        self.assertIn('URIs: https://download.docker.com/linux/debian', output)
        self.assertIn('Suites: trixie', output)
        self.assertIn('Architectures: arm64', output)
        self.assertIn('Signed-By: /etc/apt/keyrings/docker.asc', output)

    def test_fresh_install_is_masked_until_explicit_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.run_shell('''RUN_DIR="$WORK"
package_installed() { return 1; }
systemctl() { printf '%s\n' "$*" >> "$WORK/events"; }
install() { :; }
dpkg() { echo arm64; }
curl() {
    while [[ $1 != -o ]]; do shift; done
    printf '%s\n' '-----BEGIN PGP PUBLIC KEY BLOCK-----' > "$2"
}
write_config() {
    mkdir -p "$WORK/output$(dirname "$1")"
    cat > "$WORK/output$1"
}
apt_run() { printf 'apt %s\n' "$*" >> "$WORK/events"; }
timeout() { shift; "$@"; }
verify_docker() { echo verified >> "$WORK/events"; }
install_docker_packages
[[ ${#DOCKER_TEMP_UNITS[@]} == 3 ]]
if grep -q -- '--now' "$WORK/events"; then exit 1; fi
start_docker
[[ ${#DOCKER_TEMP_UNITS[@]} == 0 ]]
''', env={'WORK': tmp})
            events = (Path(tmp) / 'events').read_text()
            self.assertIn('mask --runtime docker.service', events)
            self.assertIn('docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin', events)
            self.assertLess(events.index('unmask --runtime'), events.index('enable --now'))
            self.assertTrue(events.rstrip().endswith('verified'))

    def test_install_failure_releases_own_masks(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.run_shell('''STATE_DIR="$WORK"
DOCKER_INSTALL=1
preflight() { :; }; install_packages() { :; }
install_docker_packages() {
    DOCKER_TEMP_UNITS=(docker.service docker.socket)
    die 'simulated install failure'
}
systemctl() { printf '%s\n' "$*" >> "$WORK/events"; }
apply_all
''', ok=False, env={'WORK': tmp})
            self.assertIn('unmask --runtime docker.service docker.socket', (Path(tmp) / 'events').read_text())

    def test_downloads_precede_timer_and_start_follows_ufw(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.run_shell('''STATE_DIR="$WORK"; DOCKER_INSTALL=1
preflight() { :; }
install_packages() { echo base; }
install_docker_packages() { echo download-docker; }
configure_system() { echo configure-system; }
prepare_access() { :; }
arm_rollback() { echo arm-timer; }
configure_access() { echo configure-ufw; }
start_docker() { echo start-docker; }
verify_access() { echo verified; }
report() { :; }
apply_all > "$WORK/events"
''', env={'WORK': tmp})
            events = (Path(tmp) / 'events').read_text()
            self.assertLess(events.index('download-docker'), events.index('arm-timer'))
            self.assertLess(events.index('configure-ufw'), events.index('start-docker'))
            self.assertLess(events.index('start-docker'), events.index('verified'))

    def test_rollback_state_preserves_empty_and_nonempty_mask_lists(self):
        for units in ['', 'docker.service docker.socket containerd.service']:
            with self.subTest(units=units), tempfile.TemporaryDirectory() as tmp:
                self.run_shell('''RUN_DIR="$WORK"; DOCKER_INSTALL=1
SSH_CONNECTION='192.0.2.1 50000 192.0.2.2 22'; SERVER_PORT=22
IFS=' ' read -r -a DOCKER_TEMP_UNITS <<< "$UNITS"
sshd() { if [[ $1 == -T ]]; then echo 'port 22'; fi; }
systemctl() { return 1; }
ufw() { echo 'Status: inactive'; }
save_file() { :; }; prepare_keys() { :; }
prepare_access
DOCKER_TEMP_UNITS=(); DOCKER_INSTALL=0
source "$RUN_DIR/access.env"
[[ $DOCKER_INSTALL == 1 && "${DOCKER_TEMP_UNITS[*]:-}" == "$UNITS" ]]
if [[ -z $UNITS ]]; then [[ ${#DOCKER_TEMP_UNITS[@]} == 0 ]]; fi
''', env={'WORK': tmp, 'UNITS': units})


if __name__ == '__main__':
    unittest.main()
