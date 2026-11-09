"""Decoder parity fixture for the m2s int4 graph (the default model), from the Python reference decoder.

The block4 reference outputs and candidate / tokenizer cases come from the Android engine's fixtures (made by
autocorrect/android_export/make_fixtures.py). This adds m2s: the same 50 messages (same precomputed candidate slots),
corrector.decode() (system e: first pass + re-check of the previous word) with the m2s.step.int4m.ort graph and the
standard style token, exactly like the Kotlin / Swift NeuralScorer: context = [EOS, STYLE] + last 62 tokens.

  ~/projects/autocorrect/.venv/bin/python -I scripts/make_fixtures.py \
      ~/projects/autocorrect/android_export/out/publish Tests/EngineTests/Fixtures
"""
import json, os, sys, time
from collections import OrderedDict

AC = os.path.expanduser('~/projects/autocorrect')
sys.path.insert(0, AC); sys.path.insert(0, os.path.join(AC, 'web'))
import numpy as np
import onnxruntime as ort
import sentencepiece as spm
import pipeline_ref as R
from corrector import decode

pub, out = sys.argv[1], sys.argv[2]
N = int(sys.argv[3]) if len(sys.argv) > 3 else 50   # messages (CPU time on a small box: ~1-2 s per LM call)
man = json.load(open(f'{pub}/manifest.json'))
spec = next(m for m in man['models'] if m['id'] == 'm2s_int4')
STYLE = spec['style_tokens']['standard']
p = spec['style_params'].get('standard', spec['params'])
MAX_CTX = 64


class Step(R.Step):
    def __init__(self, path, meta, threads=2):
        so = ort.SessionOptions()
        so.intra_op_num_threads = threads
        so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL   # pre-optimized .ort, like the apps
        so.add_session_config_entry('session.load_model_format', 'ORT')
        self.s = ort.InferenceSession(path, so, providers=['CPUExecutionProvider'])
        self.meta = meta
        self.names = meta['state_names']


class StyleScorer(R.OnnxScorer):
    """OnnxScorer with the style control token after the leading EOS (NeuralScorer.clip in the apps)."""
    def score(self, reqs):
        keys = []
        for left, cont, *_ in reqs:
            eot = cont.endswith(R.EOT)
            if eot: cont = cont[:-1]
            lt, ft = self.enc(left), self.enc(left + cont)
            k, n = 0, min(len(lt), len(ft) - 1)
            while k < n and lt[k] == ft[k]: k += 1
            body = ft[1:k][-(MAX_CTX - 2):]
            ctx, tgt = [ft[0], STYLE] + body, ft[k:] + ([self.sp.eos_id()] if eot else [])
            keys.append((ctx, tgt, eot))
        outv = np.zeros(len(reqs))
        ctxs = [c for c, _, _ in keys]
        P = 0
        while all(len(c) > P for c in ctxs) and len({c[P] for c in ctxs}) == 1: P += 1
        pres, pm, last = self.prefix(((), tuple(ctxs[0][:P])), ctxs[0][:P], None)
        rems = [c[P:] + t for c, t, _ in keys]
        tok_lp, bnd, _, _, _ = self.step.run(rems, P, pres, pm, None)
        for b, (ctx, tgt, eot) in enumerate(keys):
            s = 0.0
            for q in range(len(tgt)):
                j = len(ctx) - P + q
                s += float(last[tgt[q]]) if j == 0 else float(tok_lp[b, j - 1])
            if not eot: s += float(bnd[b, len(rems[b]) - 1])
            outv[b] = s
        return outv


ref = json.load(open(f'{out}/pipeline_ref.json'))
msgs = []
for text, cands in list(zip(ref['texts'], ref['cands']))[:N]:
    seps, typed = R.segment(text)
    msgs.append(dict(text=text, seps=seps, words=[dict(w, typed=t) for w, t in zip(cands, typed)]))
sp = spm.SentencePieceProcessor(model_file=f'{AC}/data/m2tok/tokenizer.model')
step = Step(f"{pub}/{spec['graph']['file']}", spec['meta'])
t0 = time.time()
outs = []


def save():
    res = dict(model='m2s_int4', graph=spec['graph'], style='standard', style_id=STYLE, meta=spec['meta'],
               params=dict(lam=p['lam'], bias=p['bias'], margin=p.get('margin'), lam_r=p.get('lam_r')), outs=outs)
    with open(f'{out}/pipeline_m2s.json', 'w') as f: json.dump(res, f)


for i, m in enumerate(msgs):
    sc = StyleScorer(sp, step)   # fresh caches per message
    outs.append(decode([m], sc, p['lam'], p['bias'], margin=p.get('margin'), lam_r=p.get('lam_r'))[0])
    print(i, f'{time.time() - t0:.0f}s', flush=True)
    save()
changed = sum(o != w['cands'][w['typed_idx']] for os_, m in zip(outs, msgs) for o, w in zip(os_, m['words']))
print('m2s:', sum(map(len, outs)), 'words,', changed, 'changed from typed,', f'{time.time() - t0:.0f}s')
