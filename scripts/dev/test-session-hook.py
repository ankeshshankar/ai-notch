#!/usr/bin/env python3
"""Pipes StopFailure, PreCompact, PostCompact, UserPromptSubmit and SessionStart through the built
hook into a temp sessions folder (CLAUDE_NOTCH_SESSIONS) and checks the state file. Touches nothing else."""
import json, os, subprocess, sys, tempfile, shutil

hook = os.path.join(os.path.dirname(__file__), "..", "..", ".build", "release", "ai-notch-hook")
folder = tempfile.mkdtemp(prefix="notch-hook-")
sid = "t-session-hook"
env = dict(os.environ, CLAUDE_NOTCH_SESSIONS=folder, CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="75")
fails = checks = 0

def send(event, **extra):
    payload = dict(hook_event_name=event, session_id=sid, cwd="/tmp/x", **extra)
    r = subprocess.run([hook], input=json.dumps(payload), capture_output=True, text=True, env=env, timeout=10)
    return r

def state():
    with open(os.path.join(folder, sid + ".json")) as f:
        return json.load(f)

def expect(ok, what):
    global fails, checks
    checks += 1
    if not ok:
        fails += 1
        print("FAIL", what)

try:
    r = send("SessionStart", source="startup")
    expect(r.returncode == 0 and r.stdout == "", "start exits 0 and prints nothing")
    expect(state().get("autoCompact", {}).get("pct") == 75, "env captured")
    send("UserPromptSubmit", prompt="hi")
    expect(state()["phase"] == "working", "working")
    r = send("StopFailure", error="rate_limit", error_details="429", last_assistant_message="x")
    s = state()
    expect(r.returncode == 0 and r.stdout == "", "failure prints nothing")
    expect(s["phase"] == "idle" and s.get("failure") == "rate_limit" and s.get("failedAt"), "failed state")
    send("UserPromptSubmit", prompt="again")
    s = state()
    expect(s["phase"] == "working" and s.get("failure") is None and s.get("failedAt") is None, "prompt clears failure")
    send("StopFailure", error="server_error")
    send("SessionStart", source="resume")
    expect(state().get("failure") is None, "start clears failure")
    send("PreCompact", trigger="auto")
    expect(state().get("compactingSince"), "compacting set")
    send("PostCompact", trigger="auto")
    s = state()
    expect(s.get("compactingSince") is None and s.get("compactedAt"), "compaction done, compactedAt set")
    send("PreCompact", trigger="auto", agent_id="sub1")
    expect(state().get("compactingSince") is None, "subagent compaction ignored")
    send("StopFailure", error="rate_limit", agent_id="sub1")
    expect(state().get("failure") is None, "subagent failure ignored")
    send("PreCompact")
    send("SessionStart", source="compact")
    s = state()
    expect(s.get("compactingSince") is None and s.get("compactedAt"), "compact start resets")
    send("SessionEnd", reason="other")
    expect(not os.path.exists(os.path.join(folder, sid + ".json")), "session end removes the file")
finally:
    shutil.rmtree(folder, ignore_errors=True)
print(f"session-hook: {checks - fails}/{checks} passed")
sys.exit(1 if fails else 0)
