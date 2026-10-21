#!/usr/bin/env python3
"""Talks to AI Notch's VPN helper the way the app does: one JSON request, one JSON reply.

    scripts/dev/vpnctl.py status
    scripts/dev/vpnctl.py import ~/Downloads/work.ovpn [name]
    scripts/dev/vpnctl.py connect <profile id>
    scripts/dev/vpnctl.py answer <prompt id> <username> [response]   (asks for the password)
    scripts/dev/vpnctl.py disconnect | log | delete <profile id>

The helper answers only the user it was installed for (and root).
"""
import getpass
import json
import os
import socket
import sys

SOCKET = "/var/run/info.ankeshshiv.notch.vpn.sock"


def ask(request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(10)
        s.connect(SOCKET)
        s.sendall((json.dumps(request) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    return json.loads(data)


def main(args):
    if not args:
        print(__doc__.strip())
        return 2
    op, rest = args[0], args[1:]
    if op == "import":
        path = os.path.expanduser(rest[0])
        name = rest[1] if len(rest) > 1 else os.path.splitext(os.path.basename(path))[0]
        with open(path, encoding="utf-8", errors="replace") as f:
            request = {"op": "import", "name": name, "config": f.read()}
    elif op in ("connect", "delete"):
        request = {"op": op, "id": rest[0]}
    elif op == "answer":
        request = {"op": "answer", "prompt": int(rest[0]), "username": rest[1],
                   "password": getpass.getpass("Password: ")}
        if len(rest) > 2:
            request["response"] = rest[2]
    else:
        request = {"op": op}
    reply = ask(request)
    if op == "log" and reply.get("ok"):
        print("\n".join(reply.get("log") or []))
    else:
        print(json.dumps(reply, indent=2))
    return 0 if reply.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
