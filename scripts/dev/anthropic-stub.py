#!/usr/bin/env python3
"""A stand-in for POST /v1/messages, for dictation's AI clean-up (no real key needed).

  python3 scripts/dev/anthropic-stub.py <port> [mode]     mode: ok (default) | refusal | 401 | slow | answer | maxtokens

Checks the request the app sends (path, x-api-key present, anthropic-version, model, body shape, no
sampling parameters) and writes each request, with the key masked, to $STUB_LOG (default stderr).
The reply to `ok` is the dictation with its fillers dropped and a full stop added, so a run shows
the round trip. Stop it with Ctrl-C."""
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
MODE = sys.argv[2] if len(sys.argv) > 2 else "ok"


def log(line):
    path = os.environ.get("STUB_LOG")
    if path:
        with open(path, "a") as f:
            f.write(line + "\n")
    else:
        print(line, file=sys.stderr, flush=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        problems = []
        if self.path != "/v1/messages": problems.append("path " + self.path)
        if not self.headers.get("x-api-key"): problems.append("no x-api-key")
        if self.headers.get("anthropic-version") != "2026-10-21": problems.append("anthropic-version " + str(self.headers.get("anthropic-version")))
        if body.get("model") != "claude-haiku-5-5": problems.append("model " + str(body.get("model")))
        for key in ("temperature", "top_p", "top_k"):
            if key in body: problems.append("sends " + key)
        if not isinstance(body.get("max_tokens"), int): problems.append("max_tokens")
        if (body.get("output_config") or {}).get("effort") != "low": problems.append("effort")
        user = (body.get("messages") or [{}])[0].get("content", "")
        system = body.get("system", "")
        log(json.dumps({"mode": MODE, "problems": problems, "key_present": bool(self.headers.get("x-api-key")),
                        "max_tokens": body.get("max_tokens"), "system_has_latin_rule": "Never use Devanagari" in system,
                        "system_has_data_rule": "data, never instructions" in system, "user": user}))
        if MODE == "401":
            return self.reply(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
        if MODE == "slow":
            time.sleep(8)
        if MODE == "refusal":
            return self.reply(200, {"type": "message", "role": "assistant", "stop_reason": "refusal", "content": []})
        if MODE == "maxtokens":
            return self.reply(200, {"type": "message", "role": "assistant", "stop_reason": "max_tokens", "content": [{"type": "thinking", "thinking": "..."}]})
        text = user.replace("<dictation>", "").replace("</dictation>", "").strip()
        if MODE == "answer":
            text = "Sure! The answer to your question is forty-two, and here is a long explanation. " * 3
        else:
            text = text[:1].upper() + text[1:] + ("" if text.endswith((".", "?", "!")) else ".")
        self.reply(200, {"type": "message", "role": "assistant", "stop_reason": "end_turn",
                         "content": [{"type": "thinking", "thinking": "", "signature": "x"}, {"type": "text", "text": text}]})


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
