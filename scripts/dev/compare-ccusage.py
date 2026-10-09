"""The notch's usage ledger against ccusage, per month and per tool.

Known, expected differences (2026-10-08, ccusage 20):
- Claude: tokens identical; cost a little higher here (Anthropic's prices vs ccusage's list).
- Codex: within ~1% tokens / ~2% cost; the notch also counts sub-agent logs ccusage skips.
- Qwen: ccusage counts cached prompt tokens twice; the notch's figure is the real total.
"""
import collections, json, os, subprocess

ledger = json.load(open(os.path.expanduser("~/.claude/notch/usage-ledger.json")))
mine = collections.defaultdict(lambda: [0, 0.0])
tools = collections.defaultdict(lambda: [0, 0.0])

def add(month, tool, v):
    n = v["input"] + v["output"] + v["cacheWrite"] + v["cacheRead"]
    for key, table in ((month, mine), (tool, tools)):
        table[key][0] += n
        table[key][1] += v["cost"]

for f in ledger["files"].values():
    for day, v in f["byDay"].items():
        add(day[:7], f.get("kind") or "claude", v)
for day, models in ledger.get("openCode", {}).items():
    for v in models.values():
        add(day[:7], "opencode", v)

def ccusage(*args):
    out = subprocess.run(["npx", "-y", "ccusage@latest", *args, "--json"], capture_output=True, text=True, cwd=os.path.expanduser("~"))
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return {}

theirs = {m["period"]: (m["totalTokens"], m["totalCost"]) for m in ccusage("monthly").get("monthly", [])}
print(f"ledger v{ledger.get('version')}\n{'month':8} {'notch tokens':>16} {'notch $':>10} {'ccusage tokens':>16} {'ccusage $':>10}")
for month in sorted(set(mine) | set(theirs)):
    t, c = mine.get(month, (0, 0))
    ct, cc = theirs.get(month, (0, 0))
    print(f"{month:8} {t:>16,} {c:>10,.2f} {ct:>16,} {cc:>10,.2f}")
print("\nby tool (notch):")
for tool, (t, c) in sorted(tools.items(), key=lambda x: -x[1][1]):
    print(f"  {tool:9} {t:>16,} tokens  ${c:,.2f}")
