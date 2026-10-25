"""Run the real terminal UI against temporary state and mocked system actions."""
import errno
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def terminal_run(command, answers, env=None):
    master, slave = pty.openpty()
    process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave,
                               env={**os.environ, **(env or {})})
    os.close(slave)
    output = bytearray()
    try:
        os.write(master, answers)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    block = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not block:
                    break
                output.extend(block)
        else:
            raise AssertionError('Wizard did not finish: ' + output.decode(errors='replace'))
        return process.wait(timeout=2), output.decode(errors='replace')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


class WizardTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='wizard-test-')
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        self.bundle = self.work / 'bootstrap.sh'
        subprocess.run(['bash', str(ROOT / 'build.sh'), str(self.bundle)], check=True,
                       capture_output=True)
        library = self.work / 'library.sh'
        library.write_text(self.bundle.read_text().rsplit('\nmain "$@"\n', 1)[0] + '\n')
        self.harness = self.work / 'harness.sh'
        self.harness.write_text('''#!/usr/bin/env bash
source "$WORK/library.sh"
eval "$(declare -f defaults | sed '1s/defaults/defaults_original/')"
defaults() { defaults_original; STATE_DIR="$WORK/state"; }
require_host() { :; }
flock() {
    if [[ $1 == -u ]]; then echo UNLOCK >> "$WORK/events";
    else echo LOCK >> "$WORK/events"; fi
}
apply_all() {
    printf 'DOCKER_MARKER|%s\\n' "$DOCKER_INSTALL"
    printf 'APPLY_MARKER|%s|%s|%s|%s\\n' "$TIMEZONE" "$SSH_PORT" "${ALLOW_RULES[*]:-}" "${TRUSTED_IPS[*]:-}"
    printf 'ADVANCED|%s|%s|%s|%s|%s|%s|%s\\n' "$BBR" "$SWAP_MIB" "$ZRAM_PERCENT" "$NOFILE" "$HOSTNAME_VALUE" "$DNS" "$ROLLBACK_SECONDS"
}
confirm_access() { printf 'CONFIRM_MARKER|%s\\n' "$RUN_ID"; }
rollback_access() { printf 'ROLLBACK_MARKER|%s\\n' "$RUN_ID"; }
load_run() { :; }
report() { printf 'STATUS_MARKER\\n'; }
wizard_wait() {
    [[ $(tail -1 "$WORK/events") == UNLOCK ]] || exit 99
    printf 'WAIT_MARKER\\n'
}
main
''')
        self.env = {'WORK': str(self.work), 'SSH_CONNECTION': '', 'SSH_USER_AUTH': '', 'SUDO_USER': ''}

    def run_ui(self, answers, real=False):
        return terminal_run(['bash', str(self.bundle if real else self.harness)],
                            answers, self.env)

    def test_no_arguments_open_menu_and_exit(self):
        code, output = self.run_ui(b'0\n', real=True)
        self.assertEqual(code, 0, output)
        self.assertIn('服务器初始化向导', output)
        self.assertNotIn('APPLY_MARKER', output)

    def test_menu_rejects_multiple_selections(self):
        code, output = self.run_ui(b'1 2\n0\n', real=True)
        self.assertEqual(code, 0, output)
        self.assertIn('请选择列出的编号', output)

    def test_preview_on_real_bundle_does_not_need_root_or_sources(self):
        code, output = self.run_ui(b'2\n' + b'\n' * 8, real=True)
        self.assertEqual(code, 0, output)
        self.assertIn('预览结束，未修改系统', output)
        self.assertIn('本次保留登录策略', output)

    def test_enter_at_final_confirmation_cancels(self):
        code, output = self.run_ui(b'1\n' + b'\n' * 9)
        self.assertEqual(code, 0, output)
        self.assertIn('已取消，未修改系统', output)
        self.assertNotIn('APPLY_MARKER', output)
        self.assertFalse((self.work / 'state').exists())

    def test_explicit_yes_applies_and_unlocks_before_wait(self):
        code, output = self.run_ui(b'1\n' + b'\n' * 8 + b'y\n')
        self.assertEqual(code, 0, output)
        self.assertIn('APPLY_MARKER', output)
        self.assertIn('WAIT_MARKER', output)
        self.assertIn('DOCKER_MARKER|0', output)

    def test_docker_can_be_selected_without_cli_flags(self):
        code, output = self.run_ui(b'1\n' + b'\n' * 6 + b'y\nn\ny\n')
        self.assertEqual(code, 0, output)
        self.assertIn('DOCKER_MARKER|1', output)
        self.assertIn('安装官方 Engine、Compose、Buildx', output)

    def test_eof_never_applies(self):
        code, output = self.run_ui(b'1\n\x04')
        self.assertEqual(code, 0, output)
        self.assertIn('输入已结束', output)
        self.assertNotIn('APPLY_MARKER', output)

    def test_invalid_input_reprompts_and_custom_rules_are_assembled(self):
        answers = ['1', '2', 'bad', '2222', '1', '1', '3', '0', '443', '2',
                   'invalid', '2001:db8::/32', 'n', '192.0.2.0/24', 'n', 'n', 'y']
        code, output = self.run_ui(('\n'.join(answers) + '\n').encode())
        self.assertEqual(code, 0, output)
        self.assertIn('端口必须', output)
        self.assertIn('地址格式不正确', output)
        self.assertIn('APPLY_MARKER|Asia/Shanghai|2222|443/udp@2001:db8::/32|192.0.2.0/24', output)

    def pending(self):
        state = self.work / 'state'
        state.mkdir()
        run_id = '20261025T000000Z-1'
        (state / 'pending').write_text(run_id)
        return run_id

    def test_advanced_settings_and_range_validation(self):
        answers = ['1', '3', '', '1', '1', '2', '', 'n', 'y', 'y', '2',
                   '16', '1024', 'y', '65535', 'bad.name', 'web-01',
                   'invalid', '1.1.1.1,2606:4700:4700::1111', 'n', '0', '15', 'y']
        code, output = self.run_ui(('\n'.join(answers) + '\n').encode())
        self.assertEqual(code, 0, output)
        self.assertIn('请输入 256 到 65536', output)
        self.assertIn('ADVANCED|1|1024|0|65535|web-01|1.1.1.1,2606:4700:4700::1111|900', output)

    def test_pending_run_is_selected_without_entering_id(self):
        run_id = self.pending()
        code, output = self.run_ui(b'1\n')
        self.assertEqual(code, 0, output)
        self.assertIn('CONFIRM_MARKER|' + run_id, output)
        self.assertNotIn('APPLY_MARKER', output)

    def test_pending_default_keeps_rollback_armed(self):
        self.pending()
        code, output = self.run_ui(b'\n')
        self.assertEqual(code, 0, output)
        self.assertNotIn('CONFIRM_MARKER', output)
        self.assertNotIn('ROLLBACK_MARKER', output)
        self.assertTrue((self.work / 'state/pending').exists())

    def test_pending_rollback_requires_yes(self):
        run_id = self.pending()
        code, output = self.run_ui(b'2\ny\n')
        self.assertEqual(code, 0, output)
        self.assertIn('ROLLBACK_MARKER|' + run_id, output)


if __name__ == '__main__':
    unittest.main()
