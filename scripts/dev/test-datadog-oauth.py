#!/usr/bin/env python3
"""Tests "Sign in with Datadog" end to end against datadog-oauth-stub.py, headless.

    python3 scripts/dev/test-datadog-oauth.py

Builds nothing: it runs `.build/release/AINotch --datadog-auth ...` (swift build -c release
first). Each run gets the stub's address, a scratch folder for the token and client files (never
the Keychain), a builds.json with a datadog part, and a browser file; a fake browser here reads
each authorize URL the app "opens", follows the stub's redirect to the app's listener on
127.0.0.1, and keeps the page it got. Scenarios: the full flow (DCR, authorize, callback, code
exchange), a wrong state and another path on the listener, reusing the client, renewal before
expiry, a 401 renewed and retried, an expired refresh token ("Sign in again"), invalid_client at
the exchange, at the authorize step and at a renewal (registering again), consent denied, the
browser timing out, every pup port taken (a port and registration of its own), a sign-in landing
on another site, no refresh token, the keys as fallback and the sign-in preferred over them,
sign-out; then no code, token or verifier in notch.log or the app's output.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(ROOT, ".build/release/AINotch")
STUB = os.path.join(ROOT, "scripts/dev/datadog-oauth-stub.py")
NOTCH_LOG = os.path.expanduser("~/.claude/notch/notch.log")
PUP_PORTS = [8000, 8080, 8888, 9000]

work = tempfile.mkdtemp(prefix="notch-oauth-")
state_file = os.path.join(work, "state.json")
log_file = os.path.join(work, "requests.log")
auth_dir = os.path.join(work, "auth")
browser_file = os.path.join(work, "browser.txt")
builds_file = os.path.join(work, "builds.json")
keys_file = os.path.join(work, "keys.txt")
os.makedirs(auth_dir)

results = []
outputs = []


def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"{'PASS' if ok else 'FAIL'}  {name}{('  -- ' + detail) if detail and not ok else ''}")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


PORT = free_port()
BASE_STATE = {
    "monitors": [{"id": 1, "name": "API errors", "status": "OK"}, {"id": 2, "name": "Latency", "status": "Warn"}],
    "incidents": [],
    "keys": ["stub-api-key-0001", "stub-app-key-0001"],
    "oauth": {"accessTtl": 3600, "orgName": "Stub Org"},
}


def set_state(**oauth):
    s = json.loads(json.dumps(BASE_STATE))
    s["oauth"].update(oauth)
    with open(state_file, "w") as f:
        json.dump(s, f, indent=2)


set_state()
with open(builds_file, "w") as f:
    json.dump({"datadog": {"site": "us3", "monitors": "service:api", "incidents": "state:active"}}, f)

stub = subprocess.Popen([sys.executable, STUB, state_file, str(PORT), log_file], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(50):
    try:
        socket.create_connection(("127.0.0.1", PORT), timeout=0.2).close()
        break
    except OSError:
        time.sleep(0.1)

ENV = dict(os.environ,
           CLAUDE_NOTCH_DATADOG_API=f"http://127.0.0.1:{PORT}",
           CLAUDE_NOTCH_DATADOG_OAUTH_DIR=auth_dir,
           CLAUDE_NOTCH_DATADOG_TEST_BROWSER=browser_file,
           CLAUDE_NOTCH_BUILDS_CONFIG=builds_file,
           CLAUDE_NOTCH_DATADOG_AUTH_TIMEOUT="20")


# The fake browser: follows each new authorize URL; `hooks` can act on the listener first.
class Browser:
    def __init__(self):
        self.seen = 0
        self.pages = []      # (url, status, body)
        self.paused = False
        self.before = None   # callable(location) run before the real callback
        self.stop = False
        threading.Thread(target=self.loop, daemon=True).start()

    def get(self, url):
        class NoFollow(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        opener = urllib.request.build_opener(NoFollow)
        try:
            response = opener.open(url, timeout=10)
            return response.status, response.headers, response.read().decode(errors="replace")
        except urllib.error.HTTPError as error:
            return error.code, error.headers, error.read().decode(errors="replace")
        except Exception as error:   # a reset or refused connection: a page that failed
            return 0, {}, repr(error)

    def loop(self):
        while not self.stop:
            time.sleep(0.05)
            if self.paused or not os.path.exists(browser_file):
                continue
            lines = open(browser_file).read().splitlines()
            for url in lines[self.seen:]:
                self.seen += 1
                status, headers, body = self.get(url)
                self.pages.append((url, status, body))
                location = headers.get("Location") if status in (301, 302, 303, 307) else None
                if location:
                    if self.before:
                        self.before(location)
                    status, _, body = self.get(location)
                    self.pages.append((location, status, body))


browser = Browser()


def run(*args, env=None, timeout=60):
    result = subprocess.run([APP, "--datadog-auth", *args], env=env or ENV, capture_output=True, text=True, timeout=timeout)
    outputs.append(result.stdout + result.stderr)
    return result.stdout + result.stderr


def log_lines():
    return open(log_file).read().splitlines() if os.path.exists(log_file) else []


def since(mark):
    return log_lines()[mark:]


def count(lines, *words):
    return sum(1 for line in lines if all(w in line for w in words))


def token():
    path = os.path.join(auth_dir, "token.json")
    return json.load(open(path)) if os.path.exists(path) else None


def clients():
    path = os.path.join(auth_dir, "clients.json")
    return json.load(open(path)) if os.path.exists(path) else {}


log_start = os.path.getsize(NOTCH_LOG) if os.path.exists(NOTCH_LOG) else 0
started = time.time()
try:
    # 1. The full flow.
    mark = len(log_lines())
    out = run("sign-in")
    lines = since(mark)
    check("sign-in: signed in as the org, read scopes", "result: signed in to us3.datadoghq.com as Stub Org, scopes incident_read monitors_read timeseries_query" in out, out)
    check("sign-in: one DCR with the 4 pup redirects", count(lines, "POST /api/v2/oauth2/register 201", "redirects=4") == 1, "\n".join(lines))
    check("sign-in: authorize redirected, code exchanged", count(lines, "/oauth2/v1/authorize 302") == 1 and count(lines, "grant=authorization_code", " 200 ") == 1, "\n".join(lines))
    url = browser.pages[0][0] if browser.pages else ""
    q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
    redirect_port = urllib.parse.urlparse(q.get("redirect_uri", [""])[0]).port
    check("sign-in: PKCE S256, state, sorted scopes, a pup port",
          q.get("code_challenge_method") == ["S256"] and len(q.get("code_challenge", [""])[0]) == 43 and len(q.get("state", [""])[0]) >= 32
          and q.get("scope") == ["incident_read monitors_read timeseries_query"] and redirect_port in PUP_PORTS, url)
    check("sign-in: the tab says it can close", any(s == 200 and "You can close this tab." in b for u, s, b in browser.pages if "/oauth/callback" in u))
    t = token() or {}
    check("token blob: access, refresh, expiry, scopes, client_id, site", all(t.get(k) for k in ["access", "refresh", "expiry", "scopes", "client_id", "site"]) and t.get("site") == "us3.datadoghq.com", str(sorted(t)))
    with socket.socket() as s:
        try:
            s.bind(("127.0.0.1", redirect_port))
            freed = True
        except OSError:
            freed = False
    check("listener: port free again at once (no TIME_WAIT on it)", freed)

    # 2. A wrong state, and another path, on the listener: refused, the flow goes on.
    seen = {}

    def tamper(location):
        parsed = urllib.parse.urlparse(location)
        bad = parsed._replace(query=urllib.parse.urlencode({"code": "x", "state": "not-the-state"})).geturl()
        seen["bad"] = browser.get(bad)[0]
        seen["other"] = browser.get(parsed._replace(path="/favicon.ico", query="").geturl())[0]
    browser.before = tamper
    mark = len(log_lines())
    out = run("sign-in")
    browser.before = None
    lines = since(mark)
    check("listener: wrong state 400, other path 404, then signed in", seen.get("bad") == 400 and seen.get("other") == 404 and "result: signed in" in out, f"{seen} {out}")
    check("sign-in again reuses the client (no DCR)", count(lines, "oauth2/register") == 0, "\n".join(lines))

    # 3. Not near expiry: the token as it is.
    mark = len(log_lines())
    out = run("token")
    check("token: bearer, no renewal while far from expiry", out.startswith("bearer ") and count(since(mark), "grant=refresh_token") == 0, out)

    # 4. Renewed five minutes before it ends.
    set_state(accessTtl=305)
    run("sign-in")
    first = run("token").split()[1]
    time.sleep(6)
    mark = len(log_lines())
    out = run("token")
    check("token: renewed within 5 minutes of expiry", count(since(mark), "grant=refresh_token", " 200 ") == 1 and out.split()[1] != first, out + "\n".join(since(mark)))

    # 5. A 401: renewed once and the request sent again.
    set_state()
    run("sign-in")
    set_state(revokeBefore=time.time() + 1)
    time.sleep(1.5)
    mark = len(log_lines())
    out = run("watch", "6", env=dict(ENV, CLAUDE_NOTCH_DATADOG_EVERY="2"))
    lines = since(mark)
    order = [l for l in lines if "monitor/search" in l or "grant=refresh_token" in l][:3]
    check("401 → renew → retry → 200", len(order) == 3 and " 401" in order[0] and "grant=refresh_token" in order[1] and " 200" in order[2], "\n".join(lines))
    check("watch: reads with the sign-in", "access=ok via=sign-in monitors=2" in out, out)

    # 6. The refresh token refused: "Sign in again", tokens wiped.
    set_state(refresh="invalid_grant", revokeBefore=time.time() + 1)
    time.sleep(1.5)
    out = run("watch", "5", env=dict(ENV, CLAUDE_NOTCH_DATADOG_EVERY="2"))
    t = token() or {}
    check("expired refresh → Sign in again", "access=sign in again" in out and "sign in again: Your Datadog sign-in ended" in out, out)
    check("ended: tokens wiped, reason kept", t.get("access") == "" and t.get("refresh") == "" and "ended" in (t.get("ended") or ""), str(t.get("ended")))
    set_state()
    out = run("sign-in")
    check("sign in again works", "result: signed in" in out, out)

    # 7. invalid_client at the code exchange: registered again, the browser asked again.
    set_state(exchangeInvalidClientOnce=True)
    mark = len(log_lines())
    pages = len(browser.pages)
    old = clients().get("us3.datadoghq.com", [{}])[-1].get("client_id")
    out = run("sign-in")
    lines = since(mark)
    new = clients().get("us3.datadoghq.com", [{}])[-1].get("client_id")
    check("exchange invalid_client → re-register → signed in",
          "result: signed in" in out and count(lines, "oauth2/register 201") == 1 and count(lines, "grant=authorization_code", "401", "forced") == 1
          and count(lines, "grant=authorization_code", " 200 ") == 1 and new != old and len(browser.pages) - pages == 4, "\n".join(lines))

    # 8. invalid_client at the authorize step (a server that redirects with it).
    set_state(unknownClient="redirect")
    data = clients()
    data["us3.datadoghq.com"] = [dict(c, client_id="gone-client") for c in data["us3.datadoghq.com"]]
    json.dump(data, open(os.path.join(auth_dir, "clients.json"), "w"))
    mark = len(log_lines())
    out = run("sign-in")
    lines = since(mark)
    check("authorize invalid_client → re-register → signed in", "result: signed in" in out and count(lines, "oauth2/register 201") == 1 and count(lines, "client=unknown") == 1, out + "\n".join(lines))

    # 9. invalid_client at a renewal: Sign in again, and the client forgotten.
    set_state(refreshInvalidClient=True, revokeBefore=time.time() + 1)
    time.sleep(1.5)
    gone = (token() or {}).get("client_id")
    out = run("unauthorized")
    check("renewal invalid_client → Sign in again, client forgotten",
          "ended: AI Notch's registration in Datadog is gone" in out and all(c["client_id"] != gone for c in clients().get("us3.datadoghq.com", [])), out)
    set_state()
    mark = len(log_lines())
    out = run("sign-in")
    check("…then signing in registers anew", "result: signed in" in out and count(since(mark), "oauth2/register 201") == 1, out)

    # 10. Consent denied.
    run("sign-out")
    set_state(consent="deny")
    out = run("sign-in")
    check("consent denied → signed out with why", "result: signed out (Access was not allowed in Datadog.)" in out, out)

    # 11. No answer from the browser: timed out, port released.
    set_state()
    browser.paused = True
    out = run("sign-in", env=dict(ENV, CLAUDE_NOTCH_DATADOG_AUTH_TIMEOUT="3"))
    browser.seen = len(open(browser_file).read().splitlines())
    browser.paused = False
    check("browser timeout → signed out with why", "result: signed out (No answer from the browser" in out, out)

    # 12. Every pup port taken: a port of its own, with a registration for it.
    held = []
    for port in PUP_PORTS:
        s = socket.socket()
        try:
            s.bind(("127.0.0.1", port))
            s.listen(1)
            held.append(s)
        except OSError:
            s.close()
    mark = len(log_lines())
    pages = len(browser.pages)
    out = run("sign-in")
    for s in held:
        s.close()
    lines = since(mark)
    url = browser.pages[pages][0] if len(browser.pages) > pages else ""
    port = urllib.parse.urlparse(urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get("redirect_uri", [""])[0]).port
    check("pup ports busy → own port + own registration", "result: signed in" in out and port not in PUP_PORTS and count(lines, "oauth2/register 201", "redirects=1") == 1, out + "\n".join(lines))

    # 13. The browser's answer names another site.
    run("sign-out")
    set_state(domain="datadoghq.eu")
    out = run("sign-in")
    check("org on another site → not signed in, says which", "result: signed out (Your Datadog organization is on datadoghq.eu" in out and token() is None, out)

    # 14. No refresh token: an hour, then Sign in again.
    set_state(noRefreshToken=True, accessTtl=305)
    run("sign-in")
    time.sleep(6)
    out = run("token")
    check("no refresh token → Sign in again at expiry", "ended: Datadog gave no refresh token" in out, out)

    # 15. Keys as fallback; the sign-in preferred over them.
    run("sign-out")
    set_state()
    open(keys_file, "w").write("stub-api-key-0001\nstub-app-key-0001\n")
    kenv = dict(ENV, CLAUDE_NOTCH_DATADOG_TEST_KEYS_FILE=keys_file, CLAUDE_NOTCH_DATADOG_EVERY="2")
    out = run("watch", "4", env=kenv)
    check("signed out + keys → reads with the keys", "access=ok via=keys/none monitors=2" in out, out)
    run("sign-in")
    mark = len(log_lines())
    out = run("watch", "4", env=kenv)
    check("signed in + keys → prefers the sign-in", "access=ok via=sign-in" in out and "via=keys/none" not in out, out)
    out = run("watch", "4", env=dict(ENV, CLAUDE_NOTCH_DATADOG_EVERY="2", CLAUDE_NOTCH_DATADOG_OAUTH_DIR=os.path.join(work, "empty")))
    check("signed out, no keys → not connected", "access=not connected" in out, out)

    # 16. Sign out.
    out = run("sign-out")
    check("sign-out deletes the token", token() is None and out.startswith("signed out (Signed out on this Mac."), out)

    # 17. Secrets: no code, token or verifier anywhere they should not be.
    secrets_issued = [s for s in open(log_file + ".secrets").read().split() if s]
    notch_log = open(NOTCH_LOG, "rb").read()[log_start:].decode(errors="replace") if os.path.exists(NOTCH_LOG) else ""
    leaked = [s[:12] + "…" for s in secrets_issued if s in notch_log or any(s in o for o in outputs) or s in open(log_file).read()]
    check(f"no secret in notch.log, app output or the stub log ({len(secrets_issued)} checked)", not leaked and len(secrets_issued) > 20, str(leaked))
    check("notch.log has the sign-in lines", "datadog: signed in to us3.datadoghq.com" in notch_log and "datadog: sign-in renewed" in notch_log)
except Exception:
    import traceback
    traceback.print_exc()
    check("the run finished without an exception", False)
finally:
    browser.stop = True
    stub.terminate()
    passed = sum(1 for _, ok in results if ok)
    print(f"\n{passed}/{len(results)} passed in {time.time() - started:.0f} s")
    shutil.rmtree(work, ignore_errors=True)
    exit_code = 0 if passed == len(results) else 1
sys.exit(exit_code)
