#!/usr/bin/env python3
"""Score speech-to-text outputs against Fixtures/speech_truth.json (S3).

Inputs: Spikes/out/s3/*.json, either the common format {engine, fixture, seconds, audioSeconds, words:[{w,start,end}]}
or whisper.cpp `-oj` output (converted on the fly; the filename encodes engine and fixture).
Metrics: WER, filler retention, sentence start/end boundary error, error in the measured length of pauses, realtime factor.
"""
import json, glob, os, re, statistics, sys, wave, array, math

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
truth = json.load(open(f"{ROOT}/Fixtures/speech_truth.json"))
NUM = {"1st": "first", "2nd": "second", "3rd": "third"}

def norm(w):
    w = re.sub(r"[^\w']", "", w.lower())
    return NUM.get(w, w)

# Truth tokens: (word, sentence index, first-in-sentence?, last-in-sentence?)
T = []
for si, s in enumerate(truth["sentences"]):
    toks = [norm(x) for x in s["text"].split() if norm(x)]
    for k, tk in enumerate(toks):
        T.append((tk, si, k == 0, k == len(toks) - 1))

def load(path):
    d = json.load(open(path))
    if "transcription" in d:  # whisper.cpp -oj
        words = [{"w": seg["text"].strip(), "start": seg["offsets"]["from"] / 1000, "end": seg["offsets"]["to"] / 1000}
                 for seg in d["transcription"] if seg["text"].strip() and not seg["text"].strip().startswith("[")]
        meta = json.load(open(path + ".meta")) if os.path.exists(path + ".meta") else {}
        name = os.path.basename(path)[:-5]
        engine, fixture = name.rsplit("__", 1)
        return {"engine": engine, "fixture": fixture, "seconds": meta.get("seconds", 0), "audioSeconds": truth["duration"], "words": words}
    d["fixture"] = d["fixture"].replace(".wav", "")
    return d

def align(ref, hyp):
    n, m = len(ref), len(hyp)
    D = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): D[i][0] = i
    for j in range(m + 1): D[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            D[i][j] = min(D[i-1][j] + 1, D[i][j-1] + 1, D[i-1][j-1] + (ref[i-1] != hyp[j-1]))
    i, j, mapping = n, m, {}
    while i > 0 and j > 0:
        if D[i][j] == D[i-1][j-1] + (ref[i-1] != hyp[j-1]):
            mapping[i-1] = j-1; i -= 1; j -= 1
        elif D[i][j] == D[i-1][j] + 1: i -= 1
        else: j -= 1
    return D[n][m] / n, mapping

def score(d):
    hyp = [(norm(w["w"]), w["start"], w["end"]) for w in d["words"] if norm(w["w"])]
    wer, mp = align([t[0] for t in T], [h[0] for h in hyp])
    starts, ends = [], []
    for ti, (tok, si, first, last) in enumerate(T):
        if ti not in mp: continue
        s = truth["sentences"][si]
        if first: starts.append(abs(hyp[mp[ti]][1] - s["start"]) * 1000)
        if last: ends.append(abs(hyp[mp[ti]][2] - s["end"]) * 1000)
    gap_err = []
    lasts = {si: ti for ti, t in enumerate(T) for si in [t[1]] if t[3]}
    firsts = {si: ti for ti, t in enumerate(T) for si in [t[1]] if t[2]}
    for si, g in enumerate(truth["gaps"]):
        a, b = lasts.get(si), firsts.get(si + 1)
        if a in mp and b in mp:
            gap_err.append(abs((hyp[mp[b]][1] - hyp[mp[a]][2]) - g) * 1000)
    fillers_truth = [i for i, t in enumerate(T) if t[0] in ("um", "uh")]
    fillers_kept = sum(1 for i in fillers_truth if i in mp and hyp[mp[i]][0] == T[i][0])
    p = lambda v, q: sorted(v)[min(len(v) - 1, int(q * len(v)))] if v else float("nan")
    return {
        "engine": d["engine"], "fixture": d["fixture"], "WER%": round(wer * 100, 1),
        "fillers": f"{fillers_kept}/{len(fillers_truth)}",
        "start_med_ms": round(statistics.median(starts)) if starts else None, "start_p90_ms": round(p(starts, .9)) if starts else None,
        "end_med_ms": round(statistics.median(ends)) if ends else None, "end_p90_ms": round(p(ends, .9)) if ends else None,
        "gap_med_ms": round(statistics.median(gap_err)) if gap_err else None,
        "x_realtime": round(d["audioSeconds"] / d["seconds"], 1) if d.get("seconds") else None,
    }

def envelope(fixture, hop=0.01):
    """Per-10 ms RMS in dBFS for a 16-bit mono WAV fixture."""
    w = wave.open(f"{ROOT}/Fixtures/{fixture}.wav")
    sr, n = w.getframerate(), w.getnframes()
    a = array.array("h", w.readframes(n))
    k = int(sr * hop)
    db = []
    for i in range(0, len(a) - k, k):
        e = sum(x * x for x in a[i:i + k]) / k
        db.append(10 * math.log10(e / 32768**2 + 1e-12))
    return db

def snap(d):
    """Refine word edges to the loudness envelope: trim edges that sit in silence, extend edges that cut into voice."""
    db = envelope(d["fixture"])
    floor = sorted(db)[len(db) // 10]
    thr = max(floor + float(os.environ.get("SNAP_MARGIN_DB", 12)), -50)
    voiced = lambda t: 0 <= int(t / 0.01) < len(db) and db[int(t / 0.01)] > thr
    out = []
    for w in d["words"]:
        s, e = w["start"], w["end"]
        if voiced(e - 0.005):
            while e - w["end"] < 0.6 and voiced(e): e += 0.01
        else:
            while e - 0.01 > s and not voiced(e - 0.01): e -= 0.01
        if voiced(s + 0.005):
            while w["start"] - s < 0.15 and s > 0 and voiced(s - 0.01): s -= 0.01
        else:
            while s + 0.01 < e and not voiced(s): s += 0.01
        out.append({"w": w["w"], "start": s, "end": e})
    return {**d, "engine": d["engine"] + "+snap", "words": out}

rows = []
for p in sorted(glob.glob(f"{ROOT}/Spikes/out/s3/*.json")):
    if p.endswith("result.json"): continue
    d = load(p)
    rows += [score(d), score(snap(d))]
cols = list(rows[0].keys()) if rows else []
print(" | ".join(f"{c:>13}" for c in cols))
for r in rows: print(" | ".join(f"{str(r[c]):>13}" for c in cols))
json.dump(rows, open(f"{ROOT}/Spikes/out/s3/result.json", "w"), indent=2)
