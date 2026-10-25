"""Compare native address checks with an independent reference; exercise file edits."""
import ipaddress
import os
from pathlib import Path
import random
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PRELUDE = '''set -Eeuo pipefail
source "$PROJECT/lib/common.sh"
source "$PROJECT/lib/access.sh"
source "$PROJECT/lib/system.sh"
'''


class NativeHelperTests(unittest.TestCase):
    def run_shell(self, code, *, data='', env=None):
        result = subprocess.run(['bash', '-c', PRELUDE + code], input=data, text=True,
                                capture_output=True, env={**os.environ, 'PROJECT': str(ROOT), **(env or {})})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_address_validation(self):
        rng = random.Random(42)
        valid = ['0.0.0.0', '255.255.255.255/0', '::', '::1/128',
                 '2001:DB8::ABCD/64', '::ffff:192.0.2.1/120',
                 '1:2:3:4:5:6:192.0.2.1', '1::', '::/0']
        for version, bits in [(4, 32), (6, 128)]:
            cls = ipaddress.IPv4Address if version == 4 else ipaddress.IPv6Address
            for prefix in range(bits + 1):
                address = cls(rng.getrandbits(bits))
                valid.extend([f'{address}/{prefix}', str(address), address.exploded])
        invalid = ['', 'hostname', '1.2.3', '1.2.3.4.', '.1.2.3.4', '256.1.1.1',
                   '01.2.3.4', '1.2.3.4/33', '1.2.3.4/', '1.2.3.4/-1',
                   '1.2.3.4/24/2', '1.2.3.4/+24', ':::1', '1::2::3',
                   '1:2:3:4:5:6:7', '1:2:3:4:5:6:7:8:9', '12345::',
                   '1:2:3:4:5:6:7:8::', '1:2:3:4:5:6:7::8', ':1', '1:',
                   '::ffff:256.0.0.1', '::ffff:192.00.2.1', '::1/129',
                   '::1/abc', '::g', '1.2.3.4;id', '$(id)', r'\x31.2.3.4',
                   '1.2.3.4 extra']
        output = self.run_shell('''while IFS= read -r value; do
if address_info "$value" >/dev/null; then echo yes; else echo no; fi
done
''', data='\n'.join(valid + invalid) + '\n').splitlines()
        self.assertEqual(output, ['yes'] * len(valid) + ['no'] * len(invalid))

    def test_membership_at_every_prefix_length(self):
        rng = random.Random(17)
        cases = []
        for version, bits in [(4, 32), (6, 128)]:
            cls = ipaddress.IPv4Address if version == 4 else ipaddress.IPv6Address
            for prefix in range(bits + 1):
                raw = rng.getrandbits(bits)
                network_text = f'{cls(raw)}/{prefix}'
                network = ipaddress.ip_network(network_text, strict=False)
                candidates = [network.network_address, network.broadcast_address,
                              cls(rng.getrandbits(bits)), cls(raw)]
                if prefix:
                    candidates.append(cls(int(network.network_address) ^ (1 << (bits - prefix))))
                cases.extend((str(address), network_text, address in network) for address in candidates)
        cases += [('192.0.2.1', '::/0', False), ('::1', '0.0.0.0/0', False),
                  ('::ffff:192.0.2.1', '::ffff:192.0.2.0/120', True),
                  ('2001:db8::1', '2001:db8::abcd/64', True),
                  ('bad', '0.0.0.0/0', False), ('1.2.3.4/24', '0.0.0.0/0', False)]
        output = self.run_shell('''while read -r address network; do
if address_in_network "$address" "$network"; then echo yes; else echo no; fi
done
''', data=''.join(f'{address} {network}\n' for address, network, _ in cases)).splitlines()
        self.assertEqual(output, ['yes' if expected else 'no' for _, _, expected in cases])

    def test_ssh_include_and_hosts_are_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            ssh = folder / 'sshd_config'
            ssh.write_text('# existing\nPort 2222\n  Include /etc/ssh/server-bootstrap.conf  \nMatch User restricted\n  PasswordAuthentication no\n')
            hosts = folder / 'hosts'
            hosts.write_text('# custom\n127.0.0.1 localhost\n127.0.1.1 old alias # comment\n127.0.1.1 alias extra\n::1 localhost\n')
            ssh.chmod(0o600)
            self.run_shell('''RUN_DIR="$WORK"
ensure_ssh_include "$WORK/sshd_config"
cp "$WORK/sshd_config" "$WORK/once"
ensure_ssh_include "$WORK/sshd_config"
cmp "$WORK/once" "$WORK/sshd_config"
update_hosts_hostname "$WORK/hosts" new-host
cp "$WORK/hosts" "$WORK/hosts-once"
update_hosts_hostname "$WORK/hosts" new-host
cmp "$WORK/hosts-once" "$WORK/hosts"
''', env={'WORK': tmp})
            self.assertEqual(ssh.stat().st_mode & 0o777, 0o600)
            self.assertEqual(ssh.read_text(), 'Include /etc/ssh/server-bootstrap.conf\n# existing\nPort 2222\nMatch User restricted\n  PasswordAuthentication no\n')
            self.assertEqual(hosts.read_text(), '# custom\n127.0.0.1 localhost\n::1 localhost\n127.0.1.1\tnew-host old alias extra\n')

    def test_restricted_key_is_not_reintroduced_without_restrictions(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            for name in ['first', 'second']:
                subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(folder / name)], check=True)
            first = (folder / 'first.pub').read_text().strip()
            second = (folder / 'second.pub').read_text().strip()
            target = folder / 'authorized_keys'
            restricted = 'restrict,command="echo \\"hello world\\"" ' + first
            target.write_text('# preserved\n' + restricted)  # Deliberately no final newline.
            (folder / 'incoming').write_text(first + '\n' + second + '\n' + second + '\n')
            self.run_shell('''RUN_DIR="$WORK"
append_public_keys "$WORK/authorized_keys" "$WORK/incoming"
cp "$WORK/authorized_keys" "$WORK/once"
append_public_keys "$WORK/authorized_keys" "$WORK/incoming"
cmp "$WORK/once" "$WORK/authorized_keys"
''', env={'WORK': tmp})
            self.assertEqual(target.read_text(), '# preserved\n' + restricted + '\n' + second + '\n')


if __name__ == '__main__':
    unittest.main()
