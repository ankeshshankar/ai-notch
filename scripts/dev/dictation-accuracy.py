#!/usr/bin/env python3
"""Before/after accuracy of dictation's speech engine on `say` audio: Hinglish sentences with dev
jargon. Runs `AINotch --dictation-transcribe` per sentence for each configuration and scores
(a) jargon-term recall and (b) word error rate against the spoken text, on the rule-cleaned output.
Needs a release build: swift build -c release. The audio is synthetic and made in a temp folder.
  python3 scripts/dev/dictation-accuracy.py [--voices Rishi,Lekha] [--vocab "Priya,Arjun"]
"""
import argparse, os, re, subprocess, sys, tempfile

SENTENCES = [
    ("kal PR review karna hai Bitbucket pe, pipeline fail ho gayi", ["PR", "Bitbucket", "pipeline"]),
    ("Expo ka EAS build chal raha hai, TestFlight pe upload ho jayega", ["Expo", "EAS", "TestFlight"]),
    ("Figma ka design Forge component se match karo", ["Figma", "Forge"]),
    ("worktree banao aur commit karke branch push kar do", ["worktree", "commit", "branch"]),
    ("Datadog aur PostHog dono mein error dikh raha hai", ["Datadog", "PostHog"]),
    ("Linear ticket mein TypeScript ka type error likh do", ["Linear", "TypeScript"]),
    ("billing ka staging endpoint webhook ko call nahi kar raha", ["billing", "staging", "endpoint", "webhook"]),
    ("Claude Code ne refactor kiya aur Haiku se cleanup chala", ["Claude Code", "refactor", "Haiku"]),
]
CONFIGS = [  # (label, locale, engine, vocab)
    ("before: speech en-IN", "en-IN", "speech", None),
    ("before: speech hi-IN", "hi-IN", "speech", None),
    ("dictation en-IN, no vocab", "en-IN", "dictation", None),
    ("dictation hi-IN, no vocab", "hi-IN", "dictation", None),
    ("after: dictation en-IN + vocab", "en-IN", "dictation", "builtin"),
    ("after: dictation hi-IN + vocab", "hi-IN", "dictation", "builtin"),
]

def words(t): return re.findall(r"[a-z0-9]+", t.lower())

def wer(ref, hyp):
    r, h = words(ref), words(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev = cur
    return d[len(h)] / max(1, len(r))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--voices", default="Rishi,Lekha")
    ap.add_argument("--bin", default=".build/release/AINotch")
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="dict-acc-")
    rows = {}
    for voice in a.voices.split(","):
        for n, (text, terms) in enumerate(SENTENCES):
            f = os.path.join(tmp, f"{voice}-{n}.aiff")
            subprocess.run(["say", "-v", voice, "-o", f, text], check=True)
            for label, loc, eng, vocab in CONFIGS:
                cmd = [a.bin, "--dictation-transcribe", f, "--locale", loc, "--engine", eng]
                if vocab: cmd += ["--vocab", vocab]
                out = subprocess.run(cmd, capture_output=True, text=True, timeout=120).stdout
                m = re.search(r"^rules:\s*(.*)$", out, re.M)
                hyp = m.group(1) if m else ""
                hit = sum(1 for t in terms if t.lower() in hyp.lower())
                w = wer(text, hyp)
                r = rows.setdefault((voice, label), [0, 0, 0.0, 0])
                r[0] += hit; r[1] += len(terms); r[2] += w; r[3] += 1
    print(f"{'voice':8} {'configuration':34} {'jargon recall':>14} {'mean WER':>9}")
    for (voice, label), (hit, tot, w, n) in rows.items():
        print(f"{voice:8} {label:34} {hit:>5}/{tot:<3} {100*hit/tot:5.0f}% {100*w/n:8.0f}%")
    for f in os.listdir(tmp): os.remove(os.path.join(tmp, f))
    os.rmdir(tmp)

main()
