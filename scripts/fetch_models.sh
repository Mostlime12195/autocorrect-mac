#!/bin/bash
# model files for the tests / self-test -> $1 (default models/): both served graphs + vocabs + the manifest
set -euo pipefail
OUT="${1:-models}"
BASE=https://github.com/Mostlime12195/autocorrect-models/releases/download/models-style1
mkdir -p "$OUT"
curl -fsSL "https://github.com/Mostlime12195/autocorrect-models/releases/download/models-v1/manifest.json?cb=$RANDOM$RANDOM" -o "$OUT/manifest.json"
python3 - "$OUT" "$BASE" <<'PY'
import hashlib, json, os, subprocess, sys
out, base = sys.argv[1], sys.argv[2]
m = json.load(open(f'{out}/manifest.json'))
for spec in m['models']:
    for f in (spec['graph'], spec['vocab']):
        p = f'{out}/{f["file"]}'
        ok = os.path.exists(p) and hashlib.sha256(open(p, 'rb').read()).hexdigest() == f['sha256']
        if not ok:
            subprocess.run(['curl', '-fsSL', '--retry', '3', f'{base}/{f["file"]}', '-o', p], check=True)
            assert hashlib.sha256(open(p, 'rb').read()).hexdigest() == f['sha256'], f'sha mismatch {p}'
        print('ok', p, os.path.getsize(p))
PY
