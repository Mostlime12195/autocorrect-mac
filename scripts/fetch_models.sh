#!/bin/bash
# model files for the tests / self-test -> $1 (default models/): both served graphs + vocabs + the manifest
# Manifest from Nest (fallback: the GitHub models-v1 copy); files from each model's base_urls (Hugging Face, then Nest),
# then the top-level base_urls.
set -euo pipefail
OUT="${1:-models}"
NEST=https://autocorrect.mostlime.hackclub.app/autocorrect-android
mkdir -p "$OUT"
curl -fsSL --retry 3 "$NEST/manifest.json?cb=$RANDOM$RANDOM" -o "$OUT/manifest.json" \
  || curl -fsSL --retry 3 "https://github.com/Mostlime12195/keylime-models/releases/download/models-v1/manifest.json?cb=$RANDOM$RANDOM" -o "$OUT/manifest.json"
python3 - "$OUT" "$NEST/" <<'PY'
import hashlib, json, os, subprocess, sys
out, nest = sys.argv[1], sys.argv[2]
m = json.load(open(f'{out}/manifest.json'))
def sha(p): return hashlib.sha256(open(p, 'rb').read()).hexdigest()
for spec in m['models']:
    bases = list(dict.fromkeys(spec.get('base_urls', []) + m.get('base_urls', []) + [nest]))
    for f in (spec['graph'], spec['vocab']):
        p = f'{out}/{f["file"]}'
        ok = os.path.exists(p) and sha(p) == f['sha256']
        for base in bases:
            if ok: break
            r = subprocess.run(['curl', '-fsSL', '--retry', '3', f'{base}{f["file"]}', '-o', p])
            ok = r.returncode == 0 and sha(p) == f['sha256']
            if not ok: print('miss', base, f['file'], file=sys.stderr)
        assert ok, f'no mirror has {f["file"]} with sha256 {f["sha256"]}'
        print('ok', p, os.path.getsize(p))
PY
