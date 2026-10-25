"""Verify the deployed file and its rollback copy without a source checkout."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='bootstrap build ')
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.bundle = self.work / 'output' / 'bootstrap.sh'
        self.build()

    def build(self):
        result = subprocess.run(['bash', str(ROOT / 'build.sh'), str(self.bundle)],
                                cwd=self.work, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_renamed_file_runs_alone(self):
        deploy = self.work / 'deploy'
        deploy.mkdir()
        uploaded = deploy / 'init-server.sh'
        shutil.copy2(self.bundle, uploaded)
        self.bundle.unlink()
        for args in [['--help'], ['plan', '--ssh-port', '2222', '--timezone', 'Asia/Shanghai']]:
            with self.subTest(args=args):
                result = subprocess.run(['bash', str(uploaded), *args], cwd=deploy,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(deploy.iterdir()), [uploaded])
        self.assertTrue(os.access(uploaded, os.X_OK))
        self.assertNotIn('source "$BASE_DIR/lib/', uploaded.read_text())

    def test_build_is_reproducible(self):
        original = self.bundle.read_bytes()
        self.build()
        self.assertEqual(original, self.bundle.read_bytes())

    def test_rollback_copy_survives_removal_of_uploaded_file(self):
        uploaded = self.work / 'renamed.sh'
        self.bundle.rename(uploaded)
        # Load the bundled definitions without invoking the public CLI.
        parts = uploaded.read_text().rsplit('\nmain "$@"\n', 1)
        self.assertEqual(len(parts), 2)
        library = self.work / 'definitions.sh'
        library.write_text(parts[0] + '\n')
        result = subprocess.run(['bash', '-c', '''
set -Eeuo pipefail
source "$LIBRARY"
SCRIPT_PATH="$UPLOADED"
RUN_DIR="$WORK/run"
snapshot_runner
cmp "$UPLOADED" "$RUN_DIR/runner/bootstrap.sh"
rm "$UPLOADED" "$LIBRARY"
cd /
bash "$RUN_DIR/runner/bootstrap.sh" plan
'''], capture_output=True, text=True, env={**os.environ, 'LIBRARY': str(library),
                                         'UPLOADED': str(uploaded), 'WORK': str(self.work)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('no changes', result.stdout)
        self.assertEqual([p.name for p in (self.work / 'run/runner').iterdir()], ['bootstrap.sh'])

    def test_source_overwrite_is_rejected(self):
        original = (ROOT / 'bootstrap.sh').read_bytes()
        result = subprocess.run(['bash', str(ROOT / 'build.sh'), str(ROOT / 'bootstrap.sh')],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(original, (ROOT / 'bootstrap.sh').read_bytes())

    def test_invalid_source_does_not_replace_existing_output(self):
        checkout = self.work / 'broken'
        checkout.mkdir()
        for name in ['build.sh', 'bootstrap.sh']:
            shutil.copy2(ROOT / name, checkout / name)
        shutil.copytree(ROOT / 'lib', checkout / 'lib')
        with (checkout / 'lib/common.sh').open('a') as handle:
            handle.write('\nif then\n')
        original = self.bundle.read_bytes()
        result = subprocess.run(['bash', str(checkout / 'build.sh'), str(self.bundle)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(original, self.bundle.read_bytes())


if __name__ == '__main__':
    unittest.main()
