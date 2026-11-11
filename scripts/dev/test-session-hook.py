#!/usr/bin/env python3
"""Pipes StopFailure, PreCompact, PostCompact, UserPromptSubmit and SessionStart through the built
hook into a temp sessions folder (CLAUDE_NOTCH_SESSIONS) and checks the state file. Touches nothing else."""
import json, os, subprocess, sys, tempfile, shutil

hook = os.path.join(os.path.dirname(__file__), "..", "..", ".build", "release", "ai-notch-hook")
folder = tempfile.mkdtemp(prefix="notch-hook-")
sid = "t-session-hook"
env = dict(os.environ, CLAUDE_NOTCH_SESSIONS=folder, CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="75")
fails = checks = 0

def send(event, cwd="/tmp/x", **extra):
    payload = dict(hook_event_name=event, session_id=sid, cwd=cwd, **extra)
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

    # Work folder: a temp repository with linked worktrees.
    base = os.path.realpath(tempfile.mkdtemp(prefix="notch-wt-"))
    main, wta, wtb = base + "/main", base + "/wt-a", base + "/wt-b"
    genv = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    def git(*a): subprocess.run(["git", "-C", main] + list(a), capture_output=True, env=genv, check=True)
    os.makedirs(main + "/sub")
    git("init", "-q", "-b", "main"); git("commit", "-q", "--allow-empty", "-m", "i")
    git("worktree", "add", "-q", "-b", "feat-a", wta); git("worktree", "add", "-q", "-b", "feat-b", wtb)
    os.makedirs(base + "/other"); subprocess.run(["git", "-C", base + "/other", "init", "-q"], capture_output=True)
    sid = "t-worktree"
    def tool(event, name, cwd=main, agent_id=None, agent_type=None, **inp):
        extra = dict(agent_id=agent_id, agent_type=agent_type) if agent_id else {}
        return send(event, cwd=cwd, tool_name=name, tool_input=inp, tool_use_id="u" + str(time_ns()), **extra)
    from time import time_ns
    send("SessionStart", cwd=main + "/sub", source="startup")
    expect(state()["cwd"] == main + "/sub" and state().get("workDir") is None, "wt: starts in the main checkout")
    tool("PreToolUse", "Read", file_path=wta + "/x.txt", cwd=main + "/sub")
    tool("PreToolUse", "Grep", cwd=main + "/sub", pattern="x", path=wta)
    tool("PreToolUse", "Bash", cwd=main + "/sub", command="cat " + wta + "/x.txt")
    expect(state().get("workDir") is None, "wt: reads in another tree do not switch")
    r = tool("PreToolUse", "Edit", cwd=main + "/sub", file_path=wta + "/src/a.swift", old_string="a", new_string="b")
    expect(r.returncode == 0 and r.stdout == "", "wt: prints nothing")
    expect(state().get("workDir") == wta, "wt: an edit in worktree A switches to A")
    tool("PreToolUse", "Read", cwd=main + "/sub", file_path=wtb + "/y.txt")
    send("UserPromptSubmit", cwd=main + "/sub", prompt="more")
    expect(state().get("workDir") == wta, "wt: a read in B and an unchanged cwd keep A")
    tool("PreToolUse", "Bash", cwd=main + "/sub", command="git -C " + wtb + " commit -am x")
    expect(state().get("workDir") == wtb, "wt: Bash git -C B switches to B")
    tool("PreToolUse", "Edit", cwd=main + "/sub", file_path=base + "/other/f.txt", old_string="a", new_string="b")
    tool("PreToolUse", "Write", cwd=main + "/sub", file_path="/etc/notch-test-nope", content="x")
    expect(state().get("workDir") == wtb, "wt: another repository and non-git paths are ignored")
    tool("PreToolUse", "Write", cwd=main + "/sub", file_path=main + "/sub/z.txt", content="x")
    expect(state().get("workDir") is None, "wt: a write in the start checkout goes back")
    tool("PreToolUse", "Bash", cwd=main + "/sub", command="cd " + wta + " && ls")
    expect(state().get("workDir") == wta, "wt: Bash cd A switches")
    send("CwdChanged", cwd=wtb, old_cwd=wta, new_cwd=wtb)
    expect(state().get("workDir") == wtb, "wt: CwdChanged switches")
    send("UserPromptSubmit", cwd=wtb, prompt="x")
    expect(state().get("workDir") == wtb, "wt: same cwd again changes nothing")
    send("UserPromptSubmit", cwd=main + "/sub", prompt="x")
    expect(state().get("workDir") is None, "wt: cwd back to the start folder goes back")
    tool("PreToolUse", "NotebookEdit", cwd=main + "/sub", notebook_path=wta + "/n.ipynb")
    expect(state().get("workDir") == wta, "wt: NotebookEdit switches")
    git("worktree", "remove", "--force", wta)
    send("UserPromptSubmit", cwd=main + "/sub", prompt="x")
    expect(state().get("workDir") is None, "wt: removed worktree falls back, no error state")
    expect(state().get("failure") is None, "wt: no failure")
    # Two subagents in two worktrees: each on its own card, the session keeps its own folder.
    send("SubagentStart", cwd=main + "/sub", agent_id="s1", agent_type="builder")
    send("SubagentStart", cwd=main + "/sub", agent_id="s2", agent_type="builder")
    git("worktree", "add", "-q", "-b", "feat-a2", wta)
    tool("PreToolUse", "Edit", cwd=wta, agent_id="s1", agent_type="builder", file_path=wta + "/q.swift", old_string="a", new_string="b")
    tool("PreToolUse", "Edit", cwd=wtb, agent_id="s2", agent_type="builder", file_path=wtb + "/q.swift", old_string="a", new_string="b")
    st = state()
    by = {a["id"]: a for a in st["agents"]}
    expect(st.get("workDir") is None, "wt: subagent edits leave the session's folder alone")
    expect(by["s1"].get("workDir") == wta and by["s2"].get("workDir") == wtb, "wt: each subagent has its own worktree")
    tool("PreToolUse", "Read", cwd=wta, agent_id="s1", agent_type="builder", file_path=main + "/sub/r.txt")
    expect(state()["agents"][0].get("workDir") == wta, "wt: a subagent's read in the start tree keeps its worktree")
    send("SessionEnd", cwd=main + "/sub")
    shutil.rmtree(base, ignore_errors=True)
    sid = "t-session-hook"
finally:
    shutil.rmtree(folder, ignore_errors=True)
print(f"session-hook: {checks - fails}/{checks} passed")
sys.exit(1 if fails else 0)
