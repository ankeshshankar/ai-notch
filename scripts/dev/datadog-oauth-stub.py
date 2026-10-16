#!/usr/bin/env python3
"""A stand-in for Datadog's OAuth sign-in and API, for testing "Sign in with Datadog".

    python3 datadog-oauth-stub.py <state.json> [port] [requests.log]

It serves everything datadog-stub.py does (the monitor search, the incident search, the scalar
query; see its docstring for the state file's keys), and on top of it Datadog's OAuth endpoints as
pup uses them:

    POST /api/v2/oauth2/register       Dynamic Client Registration (RFC 7591): a public client
    GET  /oauth2/v1/authorize          the browser's step: 302 to the redirect with code and state
    POST /api/v2/oauth2/token          authorization_code (PKCE S256 checked) and refresh_token

An API request with `Authorization: Bearer <token>` is let through when the stub issued that
access token, it has not expired, and it was not revoked; else 401. Requests with
DD-API-KEY / DD-APPLICATION-KEY go through datadog-stub.py's own check.

Run the app (or `AINotch --datadog-auth ...`) with
    CLAUDE_NOTCH_DATADOG_API=http://127.0.0.1:<port>
    CLAUDE_NOTCH_DATADOG_OAUTH_DIR=<a scratch folder: the token and client files go there>
    CLAUDE_NOTCH_DATADOG_TEST_BROWSER=<a file the authorize URL is appended to>
    CLAUDE_NOTCH_BUILDS_CONFIG=<a builds.json with a datadog part>
and follow each URL in the browser file with a fake browser (test-datadog-oauth.py does).

The state file's "oauth" part, read on every request:

    "oauth": {
      "accessTtl": 3600,                 expires_in of the access tokens it issues
      "orgName": "Stub Org",             dd_org_name in the redirect
      "domain": null,                    `domain` in the redirect, when set
      "consent": "allow",                "deny": the redirect carries error=access_denied
      "unknownClient": "page",           authorize with an unknown client: "page" (a 400 page,
                                         no redirect, as real servers do) or "redirect"
                                         (error=invalid_client in the redirect)
      "refresh": "ok",                   "invalid_grant": every refresh is refused
      "refreshInvalidClient": false,     true: a refresh answers invalid_client and forgets it
      "exchangeInvalidClientOnce": false,true: the next code exchange answers invalid_client,
                                         forgets that client, and the flag is cleared
      "revokeBefore": 0,                 access tokens issued before this time get a 401
      "noRefreshToken": false,           true: the code exchange gives no refresh token
      "grant": null                      scopes to grant (default: all requested)
    }

Each request is a line in the log (time, method, path, status, grant type, client known or not).
Codes, tokens and the verifiers it receives are never written there; they go to
<requests.log>.secrets, one per line, so a
test can check that none of them leaked into the app's log.
"""
import base64
import hashlib
import importlib.util
import json
import os
import secrets
import sys
import threading
import time
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

sys.dont_write_bytecode = True  # no __pycache__ beside the scripts
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("datadog_stub", os.path.join(HERE, "datadog-stub.py"))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

STATE = base.STATE
PORT = base.PORT
LOG = base.LOG
SECRETS = (LOG + ".secrets") if LOG else None

lock = threading.Lock()
clients = {}    # client_id -> {"redirect_uris": [...]}
codes = {}      # code -> {"client_id", "redirect_uri", "challenge", "scope", "used"}
access = {}     # token -> {"client_id", "issued", "expires", "scope"}
refresh = {}    # token -> {"client_id", "scope", "live"}


def oauth_state():
    return base.state().get("oauth", {})


def remember(value):
    if SECRETS and value:
        with open(SECRETS, "a") as f:
            f.write(value + "\n")


def secret(prefix):
    value = prefix + secrets.token_urlsafe(32)
    remember(value)
    return value


def challenge_of(verifier):
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()


class Handler(base.Handler):
    def note(self, status, extra=""):
        if LOG:
            with open(LOG, "a") as f:
                f.write(f"{time.time():.1f} {self.command} {urlparse(self.path).path} {status}{(' ' + extra) if extra else ''}\n")

    def answer_json(self, status, body, extra=""):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)
        self.note(status, extra)

    def answer_page(self, status, text):
        data = f"<!doctype html><title>stub</title><p>{text}</p>".encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.note(status)

    def redirect(self, location, extra=""):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()
        self.note(302, extra)

    # The API: a bearer token the stub issued, else the keys as datadog-stub.py checks them.
    def gate(self, s):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return super().gate(s)
        if s.get("rateLimit"):
            self.answer(429, {"errors": ["Too many requests"]}, self.rate(s, 0))
            return False
        token = header[len("Bearer "):]
        o = s.get("oauth", {})
        with lock:
            info = access.get(token)
        if not info or info["expires"] < time.time() or info["issued"] < o.get("revokeBefore", 0):
            self.answer(401, {"errors": ["Unauthorized"]})
            return False
        return True

    def do_GET(self):
        url = urlparse(self.path)
        if url.path != "/oauth2/v1/authorize":
            return super().do_GET()
        o = oauth_state()
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        with lock:
            client = clients.get(q.get("client_id", ""))
        redirect = q.get("redirect_uri", "")
        state = q.get("state", "")
        if client is None:
            if o.get("unknownClient", "page") == "redirect" and redirect.startswith("http://127.0.0.1:"):
                return self.redirect(redirect + "?" + urlencode({"error": "invalid_client", "state": state}), "client=unknown")
            return self.answer_page(400, "Unknown client")
        if redirect not in client["redirect_uris"]:
            return self.answer_page(400, "redirect_uri not registered")
        if q.get("response_type") != "code" or q.get("code_challenge_method") != "S256" or not q.get("code_challenge"):
            return self.redirect(redirect + "?" + urlencode({"error": "invalid_request", "state": state}))
        if o.get("consent", "allow") == "deny":
            return self.redirect(redirect + "?" + urlencode({"error": "access_denied", "error_description": "The user denied access", "state": state}), "consent=deny")
        requested = q.get("scope", "").split()
        granted = [x for x in requested if x in o["grant"]] if o.get("grant") is not None else requested
        code = secret("stubcode_")
        with lock:
            codes[code] = {"client_id": q["client_id"], "redirect_uri": redirect, "challenge": q["code_challenge"],
                           "scope": " ".join(granted), "used": False}
        params = {"code": code, "state": state, "dd_org_name": o.get("orgName", "Stub Org")}
        if o.get("domain"):
            params["domain"] = o["domain"]
        self.redirect(redirect + "?" + urlencode(params), "consent=allow")

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/v2/oauth2/register":
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
            uris = body.get("redirect_uris") or []
            if not uris or not all(u.startswith("http://127.0.0.1:") for u in uris):
                return self.answer_json(400, {"error": "invalid_redirect_uri"})
            client_id = secrets.token_hex(16)
            with lock:
                clients[client_id] = {"redirect_uris": uris}
            return self.answer_json(201, {"client_id": client_id, "client_name": body.get("client_name"), "redirect_uris": uris,
                                          "token_endpoint_auth_method": "none", "grant_types": body.get("grant_types"),
                                          "response_types": ["code"]}, f"redirects={len(uris)}")
        if path != "/api/v2/oauth2/token":
            return super().do_POST()
        if self.headers.get("Content-Type", "").split(";")[0] != "application/x-www-form-urlencoded":
            return self.answer_json(400, {"error": "invalid_request", "error_description": "form body expected"})
        form = {k: v[0] for k, v in parse_qs(self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()).items()}
        o = oauth_state()
        grant = form.get("grant_type", "")
        client_id = form.get("client_id", "")
        with lock:
            known = client_id in clients
        tag = f"grant={grant} client={'known' if known else 'unknown'}"
        if not known:
            return self.answer_json(401, {"error": "invalid_client", "error_description": "Client not found"}, tag)
        if grant == "authorization_code":
            remember(form.get("code_verifier"))
            if o.get("exchangeInvalidClientOnce"):
                with lock:
                    clients.pop(client_id, None)
                s = base.state()
                s.setdefault("oauth", {})["exchangeInvalidClientOnce"] = False
                with open(STATE, "w") as f:
                    json.dump(s, f, indent=2)
                return self.answer_json(401, {"error": "invalid_client", "error_description": "Client not found"}, tag + " forced")
            with lock:
                info = codes.get(form.get("code", ""))
                ok = (info is not None and not info["used"] and info["client_id"] == client_id
                      and info["redirect_uri"] == form.get("redirect_uri") and challenge_of(form.get("code_verifier", "")) == info["challenge"])
                if info is not None:
                    info["used"] = True
            if not ok:
                return self.answer_json(400, {"error": "invalid_grant", "error_description": "Bad code, redirect or verifier"}, tag)
            return self.issue(client_id, info["scope"], o, tag, with_refresh=not o.get("noRefreshToken"))
        if grant == "refresh_token":
            if o.get("refreshInvalidClient"):
                with lock:
                    clients.pop(client_id, None)
                return self.answer_json(401, {"error": "invalid_client", "error_description": "Client not found"}, tag + " forced")
            with lock:
                info = refresh.get(form.get("refresh_token", ""))
            if o.get("refresh", "ok") != "ok" or not info or not info["live"] or info["client_id"] != client_id:
                return self.answer_json(400, {"error": "invalid_grant", "error_description": "Refresh token expired or revoked"}, tag)
            with lock:
                info["live"] = False   # rotation: a refresh token works once
            return self.issue(client_id, info["scope"], o, tag, with_refresh=True)
        return self.answer_json(400, {"error": "unsupported_grant_type"}, tag)

    def issue(self, client_id, scope, o, tag, with_refresh):
        ttl = int(o.get("accessTtl", 3600))
        token = secret("stubAT_")
        body = {"access_token": token, "token_type": "Bearer", "expires_in": ttl, "scope": scope}
        with lock:
            access[token] = {"client_id": client_id, "issued": time.time(), "expires": time.time() + ttl, "scope": scope}
        if with_refresh:
            rt = secret("stubRT_")
            with lock:
                refresh[rt] = {"client_id": client_id, "scope": scope, "live": True}
            body["refresh_token"] = rt
        self.answer_json(200, body, tag)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
