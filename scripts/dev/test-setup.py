#!/usr/bin/env python3
"""Tests the setup window's logic (`AINotch --setup-cli`) in temporary home folders
(CLAUDE_NOTCH_SETUP_HOME). Nothing outside them is written.

  python3 scripts/dev/test-setup.py [--app path/to/AINotch] [--real] [--keep] [--quiet]

The settings start from a built-in sample (a status line of its own, a permissions block, hooks
of the user's own). With --real they start from copies of this Mac's ~/.claude/settings.json and
~/.cursor/hooks.json instead (only read).

Scenarios:
  fresh    a Mac that never had AI Notch: Set Up, Set Up again (no change), Disconnect (the
           original, byte for byte), Disconnect again (no change)
  migrate  hooks from before the rename (`claude-notch-hook` in an old app), plus the user's own
           hooks and a duplicate `ai-notch-hook` entry from another copy: Set Up moves ours in
           place, keeps theirs, never duplicates; Disconnect leaves exactly their hooks
  nohooks  no notch hooks at all, in a file formatted another way than setup writes, and with
           no files at all: Disconnect exits 0 and writes nothing (the Homebrew uninstall step)
  nocursor no ~/.cursor: Cursor is left alone and not created
  broken   settings.json that is not JSON: an error, the file untouched
  symlink  settings.json a symlink: its target is written, the link stays
  blocked  a copy whose hook does not run (stand-ins: one that hangs, as a hook macOS holds in
           quarantine does, and one that exits 1): status says `hook blocked` and gives the
           xattr command; apply exits 4 and writes nothing (no hooks, status line, login item);
           no probe process outlives the CLI
  unblocked the same copy once its hook runs (the real hook back in place): apply connects it
  blockeddisconnect hooks pointing at a hook that hangs: Disconnect never runs it, takes them
           out (the original, byte for byte) and returns at once
"""
import argparse, difflib, json, os, shlex, shutil, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOME = os.path.expanduser("~")
HOOK_NAMES = {"ai-notch-hook", "claude-notch-hook"}
LABEL = "info.ankeshshiv.notch"
CLAUDE_EVENTS = {
    "SessionStart": (None, 5), "SessionEnd": (None, 5), "UserPromptSubmit": (None, 5), "Stop": (None, 5),
    "SubagentStart": (None, 5), "SubagentStop": (None, 5), "PreToolUse": ("*", 5), "PostToolUse": ("*", 5),
    "PostToolUseFailure": ("*", 5), "PermissionRequest": ("*", 1800), "PermissionDenied": ("*", 5),
    "Notification": ("permission_prompt|elicitation_dialog|idle_prompt", 5), "PostModelSwitch": (None, 5),
}
CURSOR_EVENTS = ["sessionStart", "sessionEnd", "beforeSubmitPrompt", "postToolUse", "postToolUseFailure",
                 "afterMCPExecution", "subagentStop", "stop"]

SAMPLE_SETTINGS = {
    "$schema": "https://json.schemastore.org/claude-code-settings.json",
    "model": "opus",
    "permissions": {
        "allow": ["Bash(npm test:*)", "Read(~/projects/**)"],
        "ask": ["Bash(git push:*)", "Bash(rm:*)"],
        "deny": ["Read(./.env)"],
    },
    "hooks": {
        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/guard.sh", "timeout": 10}]}],
        "Stop": [{"hooks": [{"type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff"}]}],
    },
    "statusLine": {"type": "command", "command": "npx -y ccusage statusline", "padding": 0},
    "env": {"DISABLE_TELEMETRY": "1"},
}
SAMPLE_CURSOR = {"version": 1, "hooks": {"afterFileEdit": [{"command": "./hooks/format.sh"}]}}

failures = []
args = None


def check(ok, what):
    print(("  ok    " if ok else "  FAIL  ") + what)
    if not ok:
        failures.append(what)


def dump(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def is_notch(command):
    try:
        words = shlex.split(command or "")
    except ValueError:
        return False
    return bool(words) and os.path.basename(words[0]) in HOOK_NAMES


def strip_claude(settings):
    """What Disconnect should leave: written here independently of the Swift code."""
    s = json.loads(json.dumps(settings))
    hooks = s.get("hooks")
    if isinstance(hooks, dict):
        removed_any = False
        for event in list(hooks):
            groups, new, removed = hooks[event], [], False
            for g in groups:
                entries = g.get("hooks")
                if not isinstance(entries, list):
                    new.append(g); continue
                kept = [h for h in entries if not is_notch(h.get("command"))]
                if len(kept) == len(entries):
                    new.append(g); continue
                removed = True
                if kept:
                    g["hooks"] = kept; new.append(g)
            if removed:
                removed_any = True
                if new: hooks[event] = new
                else: del hooks[event]
        if removed_any and not hooks:
            del s["hooks"]
    line = s.get("statusLine")
    if isinstance(line, dict) and is_notch(line.get("command")):
        words = shlex.split(line["command"])
        inner = " ".join(words[2:])
        if inner: line["command"] = inner
        else: del s["statusLine"]
    return s


def strip_cursor(hooks_file):
    s = json.loads(json.dumps(hooks_file))
    for event in list(s.get("hooks", {})):
        kept = [h for h in s["hooks"][event] if not is_notch(h.get("command"))]
        if len(kept) != len(s["hooks"][event]):
            if kept: s["hooks"][event] = kept
            else: del s["hooks"][event]
    return s


def hook_up(settings, cursor, hook):
    """Settings as an older setup left them, pointed at `hook`: one entry per planned event and
    the status line wrapped. Written here independently of the Swift code."""
    s = strip_claude(settings)
    hooks = s.setdefault("hooks", {})
    for event, (matcher, timeout) in CLAUDE_EVENTS.items():
        group = {"matcher": matcher} if matcher else {}
        group["hooks"] = [{"type": "command", "command": hook, "timeout": timeout}]
        hooks.setdefault(event, []).append(group)
    own = (s.get("statusLine") or {}).get("command", "")
    s.setdefault("statusLine", {"type": "command"})["command"] = f"{hook} statusline {shlex.quote(own)}" if own else f"{hook} statusline"
    c = strip_cursor(cursor)
    for event in CURSOR_EVENTS:
        c["hooks"].setdefault(event, []).append({"command": hook + " cursor", "timeout": 5})
    return s, c


def run(home, command, expect_code=0, app=None):
    env = dict(os.environ, CLAUDE_NOTCH_SETUP_HOME=home)
    p = subprocess.run([app or args.app, "--setup-cli", command], env=env, capture_output=True, text=True)
    if not args.quiet:
        for l in p.stdout.splitlines():
            print("        " + l.replace(home, "$HOME"))
    if p.stderr.strip():
        print("        stderr: " + p.stderr.strip())
    check(p.returncode == expect_code, f"setup-cli {command} exits {expect_code} (got {p.returncode})")
    return p.stdout


def read(path):
    with open(path, "rb") as f:
        return f.read()


def snapshot(home):
    """Every file under the home: its bytes and modification time."""
    out = {}
    for d, _, files in os.walk(home):
        for f in files:
            p = os.path.join(d, f)
            out[os.path.relpath(p, home)] = (read(p), os.stat(p).st_mtime_ns)
    return out


def diff(a, b, name):
    lines = list(difflib.unified_diff(a.decode().splitlines(True), b.decode().splitlines(True), f"{name} before", f"{name} after", n=1))
    print(f"  --- diff {name}: {sum(1 for l in lines if l.startswith('+') and not l.startswith('+++'))} lines added, "
          f"{sum(1 for l in lines if l.startswith('-') and not l.startswith('---'))} removed")
    if not args.quiet:
        sys.stdout.write("".join("        " + l for l in lines))
        if lines and not lines[-1].endswith("\n"): print()


def backups(home):
    out = []
    for d, _, files in os.walk(home):
        out += [os.path.join(d, f) for f in files if ".bak-setup-" in f]
    return sorted(out)


def check_claude_connected(path, hook, original):
    s = json.loads(read(path))
    hooks = s.get("hooks", {})
    want = shlex.quote(hook) if shlex.quote(hook) != hook else hook
    total = 0
    for event, (matcher, timeout) in CLAUDE_EVENTS.items():
        ours = [(g, h) for g in hooks.get(event, []) for h in g.get("hooks", []) if is_notch(h.get("command"))]
        total += len(ours)
        ok = len(ours) == 1 and ours[0][1]["command"] == want and ours[0][1].get("timeout") == timeout
        if ok and matcher and len(ours[0][0]["hooks"]) == 1:
            ok = ours[0][0].get("matcher") == matcher
        if not ok:
            check(False, f"{event}: one entry, this copy, timeout {timeout} (found {ours})")
    check(total == 13, f"13 notch hook entries, one per event, none duplicated, all ai-notch-hook (found {total})")
    check(any(h.get("timeout") == 1800 for g in hooks["PermissionRequest"] for h in g["hooks"] if is_notch(h["command"])),
          "PermissionRequest timeout 1800")
    # Everything that is not ours is unchanged.
    check(strip_claude(s) == strip_claude(original), "every other hook, setting and the permissions block unchanged")
    check(s.get("permissions") == original.get("permissions"), "permissions block identical")
    line = s.get("statusLine", {}).get("command", "")
    words = shlex.split(line)
    orig_line = (strip_claude(original).get("statusLine") or {}).get("command", "")
    check(words[:2] == [hook, "statusline"] and " ".join(words[2:]) == orig_line,
          f"statusLine wraps the user's command ({orig_line!r})")
    return s


def check_cursor_connected(path, hook, original):
    s = json.loads(read(path))
    want = (shlex.quote(hook) if shlex.quote(hook) != hook else hook) + " cursor"
    total = 0
    for event, entries in s["hooks"].items():
        ours = [h for h in entries if is_notch(h.get("command"))]
        total += len(ours)
        if event in CURSOR_EVENTS:
            if not (len(ours) == 1 and ours[0]["command"] == want and ours[0]["timeout"] == 5):
                check(False, f"cursor {event}: one entry for this copy ({ours})")
        elif ours:
            check(False, f"cursor {event}: no notch entry on a non-planned event")
    check(total == 8, f"8 Cursor entries, none duplicated, none on permission events (found {total})")
    check(strip_cursor(s) == strip_cursor(original), "Cursor's other hooks unchanged")


def make_home(tmp, name, cursor=True):
    home = os.path.join(tmp, name)
    os.makedirs(os.path.join(home, ".claude"))
    if cursor:
        os.makedirs(os.path.join(home, ".cursor"))
    return home, os.path.join(home, ".claude/settings.json"), os.path.join(home, ".cursor/hooks.json")


def scenario_fresh(tmp, base_settings, base_cursor, hook, exe):
    print("\n== fresh: a Mac that never had AI Notch")
    home, settings, cursor = make_home(tmp, "fresh")
    original = strip_claude(base_settings)
    cursor_original = strip_cursor(base_cursor)
    cursor_original["hooks"].setdefault("afterFileEdit", [{"command": "./hooks/format.sh"}])
    open(settings, "w").write(dump(original)); open(cursor, "w").write(dump(cursor_original))
    before, cursor_before = read(settings), read(cursor)
    check(not is_notch((original.get("statusLine") or {}).get("command")),
          f"original has no notch hooks and its own status line ({(original.get('statusLine') or {}).get('command')!r})")
    out = run(home, "status")
    check("claude  not set up" in out and "cursor  not set up" in out and "login   not set up" in out, "status before: all not set up")
    check("probe   hook runs" in out, "status probes the hook: it runs")

    run(home, "apply")
    after, cursor_after = read(settings), read(cursor)
    diff(before, after, "settings.json"); diff(cursor_before, cursor_after, "hooks.json")
    check_claude_connected(settings, hook, original)
    check_cursor_connected(cursor, hook, cursor_original)
    plist = os.path.join(home, f"Library/LaunchAgents/{LABEL}.plist")
    check(os.path.exists(plist) and f"<string>{exe}</string>" in open(plist).read() and f"<string>{LABEL}</string>" in open(plist).read(),
          f"login item {LABEL} points at this copy")
    b1 = backups(home)
    check(len(b1) == 2 and all(read(b) in (before, cursor_before) for b in b1), f"one backup per file, equal to the original ({len(b1)})")
    out = run(home, "status")
    check("claude  done" in out and "cursor  done" in out and "login   done" in out, "status after: all done")

    run(home, "apply")
    check(read(settings) == after and read(cursor) == cursor_after, "Set Up twice: no byte changes")
    check(backups(home) == b1, "Set Up twice: no new backup")

    run(home, "disconnect")
    diff(after, read(settings), "settings.json (disconnect)")
    check(read(settings) == before, "Disconnect restores settings.json exactly")
    check(read(cursor) == cursor_before, "Disconnect restores hooks.json exactly")
    out = run(home, "status")
    check("claude  not set up" in out, "status after disconnect: not set up")
    b2 = backups(home)
    run(home, "disconnect")
    check(read(settings) == before and backups(home) == b2, "Disconnect twice: no change, no new backup")


def scenario_migrate(tmp, base_settings, base_cursor, hook):
    print("\n== migrate: hooks of the old name (claude-notch-hook), the user's own, and a duplicate")
    home, settings, cursor = make_home(tmp, "migrate")
    old = "/Applications/ClaudeNotch.app/Contents/MacOS/claude-notch-hook"
    other = "/Users/someone/Applications/AINotch.app/Contents/MacOS/ai-notch-hook"
    s, c = hook_up(base_settings, base_cursor, old)
    s["hooks"]["PreToolUse"].insert(0, {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/lint-guard.sh", "timeout": 10}]})
    # A second notch entry on Stop, from another copy under the new name, beside a user hook.
    s["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": "say done"},
                                         {"type": "command", "command": other, "timeout": 5}]})
    c["hooks"]["stop"].append({"command": other + " cursor", "timeout": 5})
    c["hooks"]["preToolUse"] = [{"command": old + " cursor", "timeout": 5}, {"command": "./hooks/guard.sh"}]
    open(settings, "w").write(dump(s)); open(cursor, "w").write(dump(c))
    before, cursor_before = read(settings), read(cursor)
    out = run(home, "status")
    check("claude  other copy" in out and "cursor  other copy" in out, "status before: other copy")

    run(home, "apply")
    after, cursor_after = read(settings), read(cursor)
    diff(before, after, "settings.json"); diff(cursor_before, cursor_after, "hooks.json")
    a = check_claude_connected(settings, hook, s)
    commands = [h.get("command", "") for g in a["hooks"].values() for grp in g for h in grp.get("hooks", [])]
    commands += [a.get("statusLine", {}).get("command", "")]
    commands += [h.get("command", "") for e in json.loads(read(cursor))["hooks"].values() for h in e]
    check(not any("claude-notch-hook" in c for c in commands), "no claude-notch-hook command left in either file")
    check(a["hooks"]["PreToolUse"][0]["hooks"][0]["command"] == "~/bin/lint-guard.sh", "the user's PreToolUse hook kept, in place")
    check(any(h["command"] == "say done" for g in a["hooks"]["Stop"] for h in g["hooks"]), "the user's Stop hook kept")
    check(list(a.keys()) == list(s.keys()), "top-level key order unchanged")
    old_events = list(s["hooks"].keys())
    check(list(a["hooks"].keys()) == old_events, "event order unchanged (entries moved in place)")
    check_cursor_connected(cursor, hook, c)
    check(json.loads(read(cursor))["hooks"]["preToolUse"] == [{"command": "./hooks/guard.sh"}],
          "Cursor permission event: ours removed, theirs kept")
    run(home, "apply")
    check(read(settings) == after and read(cursor) == cursor_after, "Set Up twice: no byte changes")

    run(home, "disconnect")
    check(read(settings).decode() == dump(strip_claude(s)), "Disconnect leaves exactly the user's settings (notch entries out, status line unwrapped)")
    check(read(cursor).decode() == dump(strip_cursor(c)), "Disconnect leaves exactly the user's Cursor hooks")
    left = json.loads(read(settings))
    own = (strip_claude(base_settings).get("statusLine") or {}).get("command")
    check((left.get("statusLine") or {}).get("command") == own, f"status line back to {own!r}")


def scenario_nohooks(tmp, base_settings, base_cursor):
    print("\n== nohooks: Disconnect with nothing to take out (the Homebrew uninstall step)")
    home, settings, cursor = make_home(tmp, "nohooks")
    # Four-space indents and no trailing newline: not the way setup writes.
    open(settings, "w").write(json.dumps(strip_claude(base_settings), indent=4))
    open(cursor, "w").write(json.dumps(strip_cursor(base_cursor), indent=4))
    before = snapshot(home)
    out = run(home, "disconnect")
    check("wrote   nothing" in out, "says it wrote nothing")
    check(snapshot(home) == before, "no file written or touched, no backup (another format kept as it is)")

    home = os.path.join(tmp, "empty")
    os.makedirs(home)
    run(home, "disconnect")
    check(snapshot(home) == {} and os.listdir(home) == [], "no ~/.claude and no ~/.cursor: nothing created")


def scenario_nocursor(tmp, base_settings):
    print("\n== nocursor: no ~/.cursor")
    home, settings, _ = make_home(tmp, "nocursor", cursor=False)
    open(settings, "w").write(dump(strip_claude(base_settings)))
    out = run(home, "apply")
    check("cursor  no ~/.cursor" in out and not os.path.exists(os.path.join(home, ".cursor")), "Cursor not created")


def scenario_broken(tmp):
    print("\n== broken: settings.json is not JSON")
    home, path, _ = make_home(tmp, "broken", cursor=False)
    open(path, "w").write('{"hooks": {,}\n')
    before = read(path)
    run(home, "apply", expect_code=1)
    check(read(path) == before and not [b for b in backups(home) if "settings" in b], "broken file untouched, no backup")


def scenario_symlink(tmp, base_settings):
    print("\n== symlink: settings.json links into a dotfiles folder")
    home, link, _ = make_home(tmp, "symlink", cursor=False)
    os.makedirs(os.path.join(home, "dotfiles"))
    target = os.path.join(home, "dotfiles/claude-settings.json")
    open(target, "w").write(dump(strip_claude(base_settings)))
    os.symlink(target, link)
    before = read(target)
    run(home, "apply")
    check(os.path.islink(link) and read(target) != before, "target written, link kept")
    run(home, "disconnect")
    check(read(target) == before, "Disconnect restores the target exactly")


def stand_in_copy(tmp, name, script):
    """A copy of the app's executable beside a stand-in `ai-notch-hook`, as a bundle's
    Contents/MacOS holds them. The stand-in notes each run in `<dir>/ran`."""
    d = os.path.join(tmp, name)
    os.makedirs(d)
    exe = os.path.join(d, "AINotch")
    shutil.copy2(args.app, exe)
    hook = os.path.join(d, "ai-notch-hook")
    with open(hook, "w") as f:
        f.write(f"#!/bin/sh\necho run >> {shlex.quote(os.path.join(d, 'ran'))}\n{script}\n")
    os.chmod(hook, 0o755)
    return d, exe, hook


def runs_of(d):
    p = os.path.join(d, "ran")
    return len(open(p).read().splitlines()) if os.path.exists(p) else 0


def leftover(hook):
    return subprocess.run(["pgrep", "-f", hook], capture_output=True, text=True).stdout.split()


def scenario_blocked(tmp, base_settings, base_cursor):
    print("\n== blocked: the hook does not run (a stand-in that hangs, one that exits 1)")
    real_hook = os.path.join(os.path.dirname(os.path.realpath(args.app)), "ai-notch-hook")
    # Hangs past the probe's 3 s answer, then exits by itself before the 15 s kill.
    d, exe, hook = stand_in_copy(tmp, "app-hangs", "exec sleep 6")
    home, settings, cursor = make_home(tmp, "blocked")
    open(settings, "w").write(dump(strip_claude(base_settings)))
    open(cursor, "w").write(dump(strip_cursor(base_cursor)))
    before = snapshot(home)
    t = time.time()
    out = run(home, "status", app=exe)
    took = time.time() - t
    check("probe   hook blocked (no answer in 3 s" in out, "status: hook blocked (no answer in 3 s)")
    check(f'fix     xattr -dr com.apple.quarantine "{os.path.realpath(d)}"' in out, "status: gives the xattr command for this copy")
    check(runs_of(d) == 1, f"status ran the probe once ({runs_of(d)})")
    check(3 <= took < 10, f"status answers after the 3 s probe timeout and waits out the stand-in ({took:.1f} s)")
    check(not leftover(hook), "no probe process left after status")
    t = time.time()
    out = run(home, "apply", expect_code=4, app=exe)
    check("wrote   nothing" in out and "error   hook: macOS is blocking ai-notch-hook" in out, "apply: refuses, says so")
    check(snapshot(home) == before, "apply wrote nothing: no hooks, no status line, no login item, no backup")
    check(not leftover(hook), f"no probe process left after apply ({time.time() - t:.1f} s)")

    d2, exe2, hook2 = stand_in_copy(tmp, "app-fails", "exit 1")
    out = run(home, "apply", expect_code=4, app=exe2)
    check("probe   hook blocked (exited with code 1" in out, "a hook that exits 1 counts as blocked")
    check(snapshot(home) == before, "apply wrote nothing")

    print("\n== unblocked: the same copy once its hook runs")
    shutil.copy2(real_hook, hook)  # what xattr -dr does for a quarantined hook: it runs again
    out = run(home, "status", app=exe)
    check("probe   hook runs" in out and "fix" not in out, "status: hook runs, no command")
    run(home, "apply", app=exe)
    check_claude_connected(settings, os.path.realpath(hook), strip_claude(base_settings))
    check_cursor_connected(cursor, os.path.realpath(hook), strip_cursor(base_cursor))
    out = run(home, "status", app=exe)
    check("claude  done" in out and "cursor  done" in out and "login   done" in out, "status after: all done")


def scenario_blocked_disconnect(tmp, base_settings, base_cursor):
    print("\n== blockeddisconnect: Disconnect while the hook hangs")
    d, exe, hook = stand_in_copy(tmp, "app-hangs-2", "exec sleep 30")
    home, settings, cursor = make_home(tmp, "blockeddisconnect")
    s, c = hook_up(base_settings, base_cursor, os.path.realpath(hook))
    open(settings, "w").write(dump(s)); open(cursor, "w").write(dump(c))
    t = time.time()
    out = run(home, "disconnect", app=exe)
    took = time.time() - t
    check("probe" not in out, "disconnect does not probe")
    check(runs_of(d) == 0, "the hook never ran")
    check(took < 2, f"disconnect returns at once ({took:.2f} s)")
    check(read(settings).decode() == dump(strip_claude(s)), "settings.json: notch entries out, status line unwrapped")
    check(read(cursor).decode() == dump(strip_cursor(c)), "hooks.json: notch entries out")


def main():
    global args
    p = argparse.ArgumentParser()
    p.add_argument("--app", default=os.path.join(ROOT, ".build/release/AINotch"), help="the AINotch executable")
    p.add_argument("--real", action="store_true", help="start from copies of this Mac's settings instead of the sample")
    p.add_argument("--keep", action="store_true", help="keep the temporary home folders")
    p.add_argument("--quiet", action="store_true", help="checks only, no diffs")
    args = p.parse_args()
    args.app = os.path.abspath(args.app)
    exe = os.path.realpath(args.app)
    hook = os.path.join(os.path.dirname(exe), "ai-notch-hook")
    base_settings, base_cursor = SAMPLE_SETTINGS, SAMPLE_CURSOR
    if args.real:
        base_settings = json.loads(read(os.path.join(HOME, ".claude/settings.json")))
        cursor_file = os.path.join(HOME, ".cursor/hooks.json")
        base_cursor = json.loads(read(cursor_file)) if os.path.exists(cursor_file) else SAMPLE_CURSOR
        base_cursor.setdefault("hooks", {})
    tmp = tempfile.mkdtemp(prefix="notch-setup-")
    print(f"app {args.app}\nhook {hook}\ntemp {tmp}\nsettings {'copies of this Mac' if args.real else 'built-in sample'}")
    try:
        scenario_fresh(tmp, base_settings, base_cursor, hook, exe)
        scenario_migrate(tmp, base_settings, base_cursor, hook)
        scenario_nohooks(tmp, base_settings, base_cursor)
        scenario_nocursor(tmp, base_settings)
        scenario_broken(tmp)
        scenario_symlink(tmp, base_settings)
        scenario_blocked(tmp, base_settings, base_cursor)
        scenario_blocked_disconnect(tmp, base_settings, base_cursor)
    finally:
        if args.keep:
            print(f"kept {tmp}")
        else:
            shutil.rmtree(tmp)
    print(f"\n{'all checks passed' if not failures else str(len(failures)) + ' FAILED'}")
    sys.exit(1 if failures else 0)


main()
