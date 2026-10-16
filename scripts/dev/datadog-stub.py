#!/usr/bin/env python3
"""A stand-in for Datadog's API, for testing the Prod chip without real keys.

    python3 datadog-stub.py <state.json> [port] [requests.log]

Then run the app with
    CLAUDE_NOTCH_DATADOG_API=http://127.0.0.1:<port>
    CLAUDE_NOTCH_DATADOG_TEST_KEYS_FILE=<file with two lines: the API key, the application key>
    CLAUDE_NOTCH_BUILDS_CONFIG=<a builds.json with a datadog part>

It answers the three endpoints the app calls, in Datadog's own shapes (its OpenAPI spec):
GET /api/v1/monitor/search, GET /api/v2/incidents/search, POST /api/v2/query/scalar. The state
file is read on every request, so editing it plays a state change:

    {
      "keys": ["<api key>", "<app key>"],        what the stub accepts (else 403, as Datadog does)
      "auth": "ok" | "401" | "403",              force an answer for every request
      "rateLimit": false,                         true: every request gets a 429
      "remaining": 100,                           X-RateLimit-Remaining on success (limit 100)
      "monitors": [{"id": 1, "name": "API errors", "status": "OK", "muted": false}],
      "incidents": [{"id": "abc", "public_id": 7, "title": "Checkout down", "severity": "SEV-2", "state": "active"}],
      "scalar": {"5xx": 0.8, "p95": 0.093},      the value for a query containing that word
      "timeline": [{"at": 0, "note": "green"}, {"at": 20, "monitors": [...]}, ...]
    }

A timeline plays a scripted sequence without editing the file: each step names the keys it
changes ("monitors", "incidents", "scalar", ...) and takes effect `at` seconds after the stub
started (or after the file's "timelineStart", an epoch time). Steps apply in order, each over the
ones before, on top of the rest of the file. `--steps <state.json>` prints the steps and exits.

Each request is a line in the log (time, method, path, status); keys are never written. With a
timeline, each new step is a line too ("step <n> <note>").
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

STATE = sys.argv[1] if sys.argv[1] != "--steps" else sys.argv[2]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[1] != "--steps" else 8765
LOG = sys.argv[3] if len(sys.argv) > 3 else None
START = time.time()
last_step = None


def note(line):
    if LOG:
        with open(LOG, "a") as f:
            f.write(f"{time.time():.1f} {line}\n")


def state():
    global last_step
    with open(STATE) as f:
        s = json.load(f)
    # The timeline stays in what is returned, so a caller writing the state back (the OAuth stub)
    # keeps it.
    timeline = s.get("timeline")
    if not timeline:
        return s
    elapsed = time.time() - s.get("timelineStart", START)
    current = None
    for index, step in enumerate(timeline):
        if step.get("at", 0) > elapsed:
            break
        current = index
        s.update({k: v for k, v in step.items() if k not in ("at", "note")})
    if current is not None and current != last_step:
        last_step = current
        note(f"step {current} {timeline[current].get('note', '')}")
    return s


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, body, extra=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for name, value in (extra or {}).items():
            self.send_header(name, str(value))
        self.end_headers()
        self.wfile.write(data)
        if LOG:
            with open(LOG, "a") as f:
                f.write(f"{time.time():.1f} {self.command} {urlparse(self.path).path} {status}\n")

    def rate(self, s, remaining=None):
        return {
            "X-RateLimit-Limit": 100,
            "X-RateLimit-Period": 60,
            "X-RateLimit-Remaining": s.get("remaining", 100) if remaining is None else remaining,
            "X-RateLimit-Reset": 30,
            "X-RateLimit-Name": "stub",
        }

    def gate(self, s):
        if s.get("rateLimit"):
            self.answer(429, {"errors": ["Too many requests"]}, self.rate(s, 0))
            return False
        auth = s.get("auth", "ok")
        if auth in ("401", "403"):
            self.answer(int(auth), {"errors": ["Unauthorized" if auth == "401" else "Forbidden"]})
            return False
        keys = s.get("keys")
        if keys and [self.headers.get("DD-API-KEY"), self.headers.get("DD-APPLICATION-KEY")] != keys:
            self.answer(403, {"errors": ["Forbidden"]})
            return False
        return True

    def do_GET(self):
        s = state()
        if not self.gate(s):
            return
        url = urlparse(self.path)
        query = parse_qs(url.query)
        if url.path == "/api/v1/monitor/search":
            q = query.get("query", [""])[0]
            monitors = s.get("monitors", [])
            if "muted:false" in q:
                monitors = [m for m in monitors if not m.get("muted")]
            counts = {}
            for m in monitors:
                counts[m["status"]] = counts.get(m["status"], 0) + 1
            per_page = int(query.get("per_page", ["30"])[0])
            page = [{"id": m["id"], "name": m["name"], "status": m["status"], "type": "query alert",
                     "org_id": 1, "tags": [], "classification": "metric", "last_triggered_ts": None,
                     "metrics": [], "notifications": [], "quality_issues": [], "query": "", "scopes": []}
                    for m in monitors[:per_page]]
            self.answer(200, {
                "counts": {"status": [{"count": c, "name": n} for n, c in counts.items()],
                           "muted": [], "tag": [], "type": [{"count": len(monitors), "name": "metric"}]},
                "metadata": {"page": 0, "page_count": 1, "per_page": per_page, "total_count": len(monitors)},
                "monitors": page,
            }, self.rate(s))
        elif url.path == "/api/v2/incidents/search":
            incidents = [i for i in s.get("incidents", []) if i.get("state", "active") != "resolved"]
            self.answer(200, {"data": {"type": "incidents_search_results", "attributes": {
                "facets": {"severity": [], "state": []},
                "incidents": [{"data": {"id": i["id"], "type": "incidents", "attributes": {
                    "title": i["title"], "severity": i.get("severity", "UNKNOWN"), "state": i.get("state", "active"),
                    "public_id": i.get("public_id"), "created": i.get("created", "2026-10-15T10:00:00.000000+00:00"),
                    "customer_impacted": False}}} for i in incidents],
                "total": len(incidents)}}}, self.rate(s))
        else:
            self.answer(404, {"errors": ["Not found"]})

    def do_POST(self):
        s = state()
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        if not self.gate(s):
            return
        if urlparse(self.path).path != "/api/v2/query/scalar":
            return self.answer(404, {"errors": ["Not found"]})
        attributes = body.get("data", {}).get("attributes", {})
        text = " ".join(q.get("query", "") for q in attributes.get("queries", []))
        value = None
        for word, v in s.get("scalar", {}).items():
            if word in text:
                value = v
        self.answer(200, {"data": {"type": "scalar_response", "attributes": {"columns": [
            {"name": "query1", "type": "number", "values": [value], "meta": {"unit": None}}]}}}, self.rate(s))


if __name__ == "__main__":
    if sys.argv[1] == "--steps":
        with open(STATE) as f:
            for index, step in enumerate(json.load(f).get("timeline", [])):
                print(f"{index:2} at {step.get('at', 0):>4}s  {step.get('note', '')}")
        sys.exit(0)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
