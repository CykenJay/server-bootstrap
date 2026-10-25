#!/usr/bin/env bash
# Build a self-contained deployment script. Python is only used during assembly.
set -Eeuo pipefail
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if (($# > 1)); then
    printf 'Usage: bash build.sh [output.sh]\n' >&2
    exit 1
fi
python3 - "$BASE_DIR" "${1:-$BASE_DIR/dist/bootstrap.sh}" <<'PY'
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
output = Path(sys.argv[2]).absolute()
entry = root / 'bootstrap.sh'
source = entry.read_text()
start, end = '# BEGIN MODULES\n', '# END MODULES\n'
if source.count(start) != 1 or source.count(end) != 1 or source.count('\nBUNDLED=0\n') != 1:
    sys.exit('Unexpected entry structure; refusing to build an incomplete script.')
before, block = source.split(start)
block, after = block.split(end)
modules = re.findall(r'^source "\$BASE_DIR/(lib/[a-z]+\.sh)"$', block, re.MULTILINE)
if not modules or len(modules) != len(set(modules)):
    sys.exit('Missing or duplicate modules.')
for line in block.splitlines():
    if line.strip() and not line.startswith('#') and not re.fullmatch(r'source "\$BASE_DIR/lib/[a-z]+\.sh"', line):
        sys.exit('Unexpected module-loading statement: ' + line)
inputs = [entry, root / 'build.sh', *(root / module for module in modules)]
if output.resolve() in [path.resolve() for path in inputs]:
    sys.exit('Output must not overwrite a source file.')
parts = []
for module in modules:
    body = (root / module).read_text()
    if body.startswith('#!'):
        body = body.split('\n', 1)[1]
    parts.append(f'# Module: {module}\n{body.rstrip()}\n')
bundle = before.replace('\nBUNDLED=0\n', '\nBUNDLED=1\n') + '\n'.join(parts) + after
output.parent.mkdir(parents=True, exist_ok=True)
temporary = None
try:
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=output.parent, prefix='.bootstrap-', delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(bundle)
    subprocess.run(['bash', '-n', str(temporary)], check=True)
    temporary.chmod(0o755)
    os.replace(temporary, output)
finally:
    if temporary is not None:
        temporary.unlink(missing_ok=True)
print(f'Built: {output}')
PY
