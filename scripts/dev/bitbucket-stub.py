#!/usr/bin/env python3
"""A stand-in for the Bitbucket Cloud API, for both of AI Notch's Bitbucket lanes: Pipelines and
pull requests. Answers in Bitbucket's own JSON shapes, honours `fields=` (dotted paths, lists
included), ETags (304 on If-None-Match), `pagelen`, `sort`, `state=` and a small BBQL (`q=` with
=, AND, OR and parentheses), and plays scripted changes on a timeline.

    python3 bitbucket-stub.py <state.json> [port] [requests.log]

Run the app or a dev flag with CLAUDE_NOTCH_BITBUCKET_API=http://127.0.0.1:<port>/2.0,
CLAUDE_NOTCH_BITBUCKET_TEST_TOKEN=<state.token> and CLAUDE_NOTCH_BUILDS_CONFIG=<a builds.json
listing the stub's repositories>.

The state file (times are seconds relative to the stub's start; `...Ago` is before it):

    {
      "token": "stub-token",
      "scopes": ["read:repository", "read:pipeline", "read:pullrequest", "read:user"],
      "tokens": {"old": ["read:repository", "read:pipeline"]},   optional: more tokens, own scopes
      "people": {"{u-me}": "Me", "{u-a}": "Alice"},
      "user": "{u-me}",                         who the token belongs to (/2.0/user)
      "commitEmail": "me@example.com",          the email on the user's commits
      "bbqlOr": true,                           false: a q= with OR is a 400, like an old API
      "csetBug": ["ws/repo"],                   a list asking for source.* (or no fields) is a 400
      "nearLimit": false,                       X-RateLimit-NearLimit: true on every answer
      "repos": {
        "ws/repo": {
          "pushes": [-3600, 195],               when updated_on moved
          "pipelines": [{"number": 7, "createdAt": -100, "runsFor": 400, "result": "SUCCESSFUL",
                         "creator": "{u-me}", "branch": "main", "pr": 5,
                         "stepName": "Test", "logLines": 100}],   a FAILED run has a failed step with
                                                                  that many log lines (default 5)
          "pullrequests": [{"id": 5, "title": "…", "author": "{u-me}", "reviewers": ["{u-a}"],
                            "participants": {"{u-a}": "approved"}, "draft": false,
                            "source": "feature/x", "destination": "main", "tasks": 1,
                            "updatedAt": -600, "head": "c0ffee1",      head: the source commit's hash
                            "comments": [{"user": "{u-a}", "at": -900, "text": "Use a guard",
                                          "inline": {"path": "src/a.swift", "to": 42}}],
                            "statuses": [{"state": "INPROGRESS", "key": "k", "pipeline": 7}],
                            "conflict": false,        true: the git check fails with reason "conflicts";
                                                      "impossible": reason "merge_impossible"
                            "mergeChecks": [...]}]      optional: /mergeability/checks as given; else
                                                        made from approvals, changes and statuses
        }
      },
      "timeline": [
        {"at": 90, "pr": "ws/repo#5", "approve": "{u-b}"},
        {"at": 120, "pr": "ws/repo#5", "changes": "{u-a}"},
        {"at": 150, "pr": "ws/repo#5", "comment": "{u-a}"},
        {"at": 200, "pr": "ws/repo#8", "addReviewer": "{u-me}"},
        {"at": 240, "pr": "ws/repo#5", "status": "FAILED", "pipeline": 9},
        {"at": 300, "pr": "ws/repo#5", "merge": true, "by": "{u-a}"},   MERGED, closed_by {u-a}
        {"at": 310, "pr": "ws/repo#6", "decline": true, "by": "{u-a}"}, DECLINED
        {"at": 330, "pr": "ws/repo#5", "head": "d00d", "conflict": true},  a push; the merge check fails
        {"at": 340, "pr": "ws/repo#5", "mergeChecks": [...]},           replace the merge checks
        {"at": 320, "rateLimitNext": "pr"},      the next pull-request request is a 429 (Retry-After 30)
        {"at": 400, "scopes": ["read:repository", "read:pipeline"]}
      ]
    }

Each request is a line in the log: seconds since start, lane (pl, pr, owner), status, method,
path and query. Pipelines, their steps and logs are found by uuid only, as the real API does (the list answers `uuid` and `build_number`).
"""
import hashlib
import json
import re
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_FILE = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8765
LOG = sys.argv[3] if len(sys.argv) > 3 else None
START = time.time()
LOCK = threading.Lock()
STATE = json.load(open(STATE_FILE))
APPLIED = set()
PENDING_429 = set()


def elapsed():
    return time.time() - START


def iso(at):
    """`at` seconds relative to the start, as Bitbucket writes times."""
    t = START + at
    return time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(t)) + '.%06d+00:00' % int((t % 1) * 1e6)


def person(uuid):
    if uuid is None:
        return None
    return {"type": "user", "uuid": uuid, "display_name": STATE.get('people', {}).get(uuid, uuid.strip('{}'))}


def apply_timeline():
    """Plays every timeline entry that is due, once."""
    now = elapsed()
    for index, step in enumerate(STATE.get('timeline', [])):
        if index in APPLIED or step['at'] > now:
            continue
        APPLIED.add(index)
        if 'scopes' in step:
            STATE['scopes'] = step['scopes']
        if 'rateLimitNext' in step:
            PENDING_429.add(step['rateLimitNext'])
        if 'nearLimit' in step:
            STATE['nearLimit'] = step['nearLimit']
        if 'pr' not in step:
            continue
        repo_key, number = step['pr'].split('#')
        repo = STATE['repos'][repo_key]
        pr = next((p for p in repo.get('pullrequests', []) if p['id'] == int(number)), None)
        if pr is None:
            continue
        at = step['at']
        if 'approve' in step:
            pr.setdefault('participants', {})[step['approve']] = 'approved'
            pr['updatedAt'] = at
        if 'changes' in step:
            pr.setdefault('participants', {})[step['changes']] = 'changes_requested'
            pr['updatedAt'] = at
        if 'unapprove' in step:
            pr.setdefault('participants', {}).pop(step['unapprove'], None)
            pr['updatedAt'] = at
        if 'comment' in step:
            pr.setdefault('comments', []).append({"user": step['comment'], "at": at, "text": step.get('text'), "inline": step.get('inline')})
            pr['updatedAt'] = at
        if 'addReviewer' in step:
            pr.setdefault('reviewers', []).append(step['addReviewer'])
            pr['updatedAt'] = at
        if 'status' in step:
            # A build status does not move the pull request's updated_on.
            pr['statuses'] = [{"state": step['status'], "key": step.get('key', 'pipeline'), "pipeline": step.get('pipeline')}]
        if 'push' in step:
            pr['updatedAt'] = at
            pr['statuses'] = [{"state": "INPROGRESS", "key": "pipeline", "pipeline": step.get('pipeline')}]
        if 'head' in step:
            pr['head'] = step['head']
            pr['updatedAt'] = at
        if 'conflict' in step:
            pr['conflict'] = step['conflict']
        if 'mergeChecks' in step:
            pr['mergeChecks'] = step['mergeChecks']
        if step.get('merge'):
            pr['state'] = 'MERGED'
            pr['closedBy'] = step.get('by')
            pr['updatedAt'] = at
        if step.get('decline'):
            pr['state'] = 'DECLINED'
            pr['closedBy'] = step.get('by')
            pr['updatedAt'] = at


# MARK: shapes

def run_object(repo_key, run):
    now = elapsed()
    created = run['createdAt']
    runs_for = run.get('runsFor', 60)
    done = now - created >= runs_for
    state = {"name": "COMPLETED", "result": {"name": run.get('result', 'SUCCESSFUL')}} if done else \
        {"name": "IN_PROGRESS", "stage": {"name": "RUNNING"}}
    target = {"ref_name": run.get('branch', 'main'), "commit": {"hash": hashlib.sha1(f"{repo_key}{run['number']}".encode()).hexdigest()},
              "selector": {"type": "branches", "pattern": run.get('branch', 'main')}}
    if run.get('pr'):
        target = {"ref_name": None, "source": run.get('branch', 'feature'), "destination": "main",
                  "pullrequest": {"id": run['pr']}, "commit": target['commit'],
                  "selector": {"type": "pull-requests", "pattern": "**"}}
    return {"uuid": "{run-%s-%d}" % (repo_key.replace('/', '-'), run['number']), "build_number": run['number'],
            "created_on": iso(created), "completed_on": iso(created + runs_for) if done else None,
            "state": state, "target": target, "trigger": {"name": "PUSH"}, "creator": person(run.get('creator'))}


def step_objects(run):
    now = elapsed()
    done = now - run['createdAt'] >= run.get('runsFor', 60)
    state = {"name": "COMPLETED", "result": {"name": run.get('result', 'SUCCESSFUL')}} if done else \
        {"name": "IN_PROGRESS", "stage": {"name": "RUNNING"}}
    return [{"uuid": "{step-%d}" % run['number'], "name": run.get('stepName', "Build"), "started_on": iso(run['createdAt'] + 5),
             "completed_on": iso(run['createdAt'] + run.get('runsFor', 60)) if done else None,
             "state": state, "trigger": {"type": "pipeline_trigger_automatic"}}]


def pr_object(ws, repo_key, pr):
    participants = []
    reviewers = pr.get('reviewers', [])
    states = pr.get('participants', {})
    for uuid in dict.fromkeys(reviewers + list(states)):
        state = states.get(uuid)
        participants.append({"type": "participant", "user": person(uuid), "role": "REVIEWER" if uuid in reviewers else "PARTICIPANT",
                             "approved": state == 'approved', "state": state, "participated_on": iso(pr.get('updatedAt', 0)) if state else None})
    name = repo_key.split('/')[1]
    return {"type": "pullrequest", "id": pr['id'], "title": pr.get('title', f"Change {pr['id']}"), "draft": pr.get('draft', False),
            "state": pr.get('state', 'OPEN'), "author": person(pr['author']),
            "source": {"branch": {"name": pr.get('source', f"feature/{pr['id']}")}, "commit": {"hash": pr.get('head', "a" * 12)},
                       "repository": {"full_name": repo_key}},
            "destination": {"branch": {"name": pr.get('destination', 'main')}, "commit": {"hash": "b" * 12},
                            "repository": {"full_name": repo_key, "name": name}},
            "reviewers": [person(u) for u in reviewers], "participants": participants,
            "closed_by": person(pr.get('closedBy')),
            "task_count": pr.get('tasks', 0), "comment_count": len(pr.get('comments', [])),
            "created_on": iso(pr.get('createdAt', -86400)), "updated_on": iso(pr.get('updatedAt', 0)),
            "links": {"html": {"href": f"https://bitbucket.org/{repo_key}/pull-requests/{pr['id']}"}}}


def pick(source, paths):
    """`fields=` as Bitbucket reads it: only the dotted paths asked for, through lists."""
    if not paths:
        return source
    out = {}

    def copy(src, dst, parts):
        if not isinstance(src, dict) or parts[0] not in src:
            return
        key, value = parts[0], src[parts[0]]
        if len(parts) == 1 or value is None:
            dst[key] = value
        elif isinstance(value, list):
            items = dst.setdefault(key, [{} for _ in value])
            for s, d in zip(value, items):
                copy(s, d, parts[1:])
        else:
            copy(value, dst.setdefault(key, {}), parts[1:])
    for path in paths:
        copy(source, out, path.lstrip('+').split('.'))
    return out


def merge_checks(pr):
    """`mergeChecks` from the state as given, else made from the pull request: an approval, no
    changes requested, no failed build."""
    if 'mergeChecks' in pr:
        return pr['mergeChecks']
    states = pr.get('participants', {}).values()
    approved = any(s == 'approved' for s in states)
    changes = any(s == 'changes_requested' for s in states)
    failed = any(s['state'] == 'FAILED' for s in pr.get('statuses', []))

    def check(kind, ok):
        return {"type": "standard_merge_check", "check": {"kind": kind, "name": None},
                "status": "PASSED" if ok else "FAILED", "required": True, "blocking": not ok}
    conflict = pr.get('conflict', False)
    git = {"type": "git_mergeability_check", "status": "FAILED" if conflict else "PASSED", "required": True, "blocking": bool(conflict)}
    if conflict:
        git["reason"] = "merge_impossible" if conflict == "impossible" else "conflicts"
    return [git,
            check("minimum_approvals", approved), check("no_changes_requested", not changes), check("failed_builds", not failed)]


# MARK: BBQL

def bbql(query, pr_obj):
    tokens = re.findall(r'\(|\)|"(?:[^"\\]|\\.)*"|[A-Za-z_.]+|!=|=|~|>|<', query)
    pos = [0]

    def peek():
        return tokens[pos[0]] if pos[0] < len(tokens) else None

    def take():
        pos[0] += 1
        return tokens[pos[0] - 1]

    def value_of(path):
        parts = path.split('.')
        values = [pr_obj]
        for part in parts:
            nxt = []
            for v in values:
                v = v.get(part) if isinstance(v, dict) else None
                if isinstance(v, list):
                    nxt.extend(v)
                elif v is not None:
                    nxt.append(v)
            values = nxt
        return values

    def term():
        if peek() == '(':
            take()
            result = expr()
            if take() != ')':
                raise ValueError('expected )')
            return result
        field = take()
        op = take()
        literal = take()
        if not literal.startswith('"'):
            raise ValueError('expected a string')
        literal = literal[1:-1]
        values = [str(v) for v in value_of(field)]
        if op == '=':
            return literal in values
        if op == '!=':
            return literal not in values
        raise ValueError('operator ' + op)

    def conj():
        result = term()
        while peek() == 'AND':
            take()
            right = term()
            result = result and right
        return result

    def expr():
        result = conj()
        while peek() == 'OR':
            take()
            right = conj()
            result = result or right
        return result
    result = expr()
    if peek() is not None:
        raise ValueError('trailing ' + peek())
    return result


# MARK: the server

SCOPE_ERROR = "Your credentials lack one or more required privilege scopes."


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def write_log(self, lane, code):
        if LOG:
            with open(LOG, 'a') as f:
                f.write(f"{elapsed():8.2f} {lane:5s} {code} GET {self.path}\n")

    def send(self, code, obj, lane, extra=None):
        body = json.dumps(obj).encode() if not isinstance(obj, bytes) else obj
        etag = '"%s"' % hashlib.md5(body).hexdigest()
        if code == 200 and self.headers.get('If-None-Match') == etag:
            code, body = 304, b''
        self.write_log(lane, code)
        self.send_response(code)
        self.send_header('Content-Type', 'application/json' if not isinstance(obj, bytes) else 'text/plain')
        if code in (200, 206):
            self.send_header('ETag', etag)
        if STATE.get('nearLimit'):
            self.send_header('X-RateLimit-NearLimit', 'true')
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def scope_error(self, needed, lane):
        granted = [f"{s}:bitbucket" for s in getattr(self, 'granted', [])]
        return self.send(403, {"type": "error", "error": {"message": SCOPE_ERROR, "detail": {"required": [f"{needed}:bitbucket"], "granted": granted}}}, lane)

    def do_GET(self):
        with LOCK:
            apply_timeline()
            self.route()

    def route(self):
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path.rstrip('/')
        query = urllib.parse.parse_qs(parsed.query)
        fields = [f for f in ','.join(query.get('fields', [])).split(',') if f]
        lane = 'pr' if '/pullrequests' in path else 'owner' if path.endswith('/user') or path.endswith('/commits') else 'pl'
        auth = self.headers.get('Authorization') or ''
        token = auth[len('Bearer '):] if auth.startswith('Bearer ') else ''
        tokens = dict(STATE.get('tokens', {}))
        tokens[STATE['token']] = STATE.get('scopes', [])
        if token not in tokens:
            return self.send(401, {"type": "error", "error": {"message": "Unauthorized"}}, lane)
        if lane in PENDING_429:
            PENDING_429.discard(lane)
            return self.send(429, {"type": "error", "error": {"message": "Rate limit for this resource has been exceeded"}}, lane, {"Retry-After": "30"})
        scopes = set(tokens[token])
        self.granted = tokens[token]
        repos = STATE['repos']

        if path == '/2.0/user':
            if 'read:user' not in scopes:
                return self.scope_error('read:user', lane)
            return self.send(200, pick(person(STATE['user']), fields), lane)

        m = re.fullmatch(r'/2\.0/workspaces/([^/]+)/pullrequests/([^/]+)', path)
        if m:
            if 'read:pullrequest' not in scopes:
                return self.scope_error('read:pullrequest', lane)
            ws, user = m.group(1), urllib.parse.unquote(m.group(2))
            states = query.get('state', [])
            values = []
            for key, repo in repos.items():
                if key.split('/')[0] != ws:
                    continue
                for pr in repo.get('pullrequests', []):
                    if pr['author'] == user and (not states or pr.get('state', 'OPEN') in states):
                        values.append(pr_object(ws, key, pr))
            values.sort(key=lambda v: v['updated_on'], reverse=True)
            page = {"size": len(values), "page": 1, "pagelen": int(query.get('pagelen', ['10'])[0]), "values": values}
            return self.send(200, pick(page, fields), lane)

        m = re.fullmatch(r'/2\.0/repositories/([^/]+)', path)
        if m:
            if 'read:repository' not in scopes:
                return self.scope_error('read:repository', lane)
            ws = m.group(1)
            q = query.get('q', [''])[0]
            since = re.search(r'updated_on>"([^"]+)"', q)
            values = []
            for key, repo in repos.items():
                if key.split('/')[0] != ws:
                    continue
                pushes = [p for p in repo.get('pushes', [-86400]) if p <= elapsed()]
                updated = iso(max(pushes) if pushes else -86400)
                if since and updated <= since.group(1).replace('Z', '+00:00'):
                    continue
                values.append({"slug": key.split('/')[1], "updated_on": updated})
            return self.send(200, pick({"size": len(values), "values": values}, fields), lane)

        m = re.fullmatch(r'/2\.0/repositories/([^/]+)/([^/]+)/(.*)', path)
        if not m:
            return self.send(404, {"type": "error", "error": {"message": "Not found"}}, lane)
        key = f"{m.group(1)}/{m.group(2)}"
        rest = m.group(3)
        repo = repos.get(key)
        if repo is None:
            return self.send(404, {"type": "error", "error": {"message": "You may not have access to this repository or it no longer exists in this workspace."}}, lane)

        if rest == 'commits':
            if 'read:repository' not in scopes:
                return self.scope_error('read:repository', lane)
            commit = {"author": {"raw": f"{STATE.get('people', {}).get(STATE['user'], 'Me')} <{STATE.get('commitEmail', 'me@example.com')}>",
                                 "user": person(STATE['user'])}}
            return self.send(200, pick({"values": [commit]}, fields), lane)

        if rest.startswith('pipelines'):
            if 'read:pipeline' not in scopes:
                return self.scope_error('read:pipeline', lane)
            runs = [r for r in repo.get('pipelines', []) if r['createdAt'] <= elapsed()]
            parts = rest.split('/')
            if len(parts) == 1:
                objects = sorted((run_object(key, r) for r in runs), key=lambda o: o['created_on'], reverse=True)
                if query.get('status') == ['PASSED']:
                    objects = [o for o in objects if o['state'].get('result', {}).get('name') == 'SUCCESSFUL']
                objects = objects[:int(query.get('pagelen', ['10'])[0])]
                return self.send(200, pick({"values": objects}, fields), lane)
            run = next((r for r in runs if run_object(key, r)['uuid'] == urllib.parse.unquote(parts[1])), None)
            if run is None:
                return self.send(404, {"type": "error", "error": {"message": "No such pipeline"}}, lane)
            if len(parts) == 2:
                return self.send(200, pick(run_object(key, run), fields), lane)
            if len(parts) == 3 and parts[2] == 'steps':
                return self.send(200, pick({"values": step_objects(run)}, fields), lane)
            if len(parts) == 5 and parts[4] == 'log':
                text = ''.join(f"+ step line {i} at {int(elapsed())}\n" for i in range(run.get('logLines', 5))).encode()
                return self.send(200, text, lane)
            return self.send(404, {"type": "error", "error": {"message": "Not found"}}, lane)

        if rest.startswith('pullrequests'):
            if 'read:pullrequest' not in scopes:
                return self.scope_error('read:pullrequest', lane)
            parts = rest.split('/')
            prs = repo.get('pullrequests', [])
            if len(parts) == 1:
                if key in STATE.get('csetBug', []) and (not fields or any('source' in f for f in fields)):
                    return self.send(400, {"type": "error", "error": {"message": "Either a cset or a repo and commit hash must be provided"}}, lane)
                q = query.get('q', [''])[0]
                if q and not STATE.get('bbqlOr', True) and ' OR ' in q:
                    return self.send(400, {"type": "error", "error": {"message": "Invalid query", "detail": "OR is not supported here"}}, lane)
                objects = [pr_object(m.group(1), key, pr) for pr in prs]
                states = query.get('state', [])
                if states:
                    objects = [o for o in objects if o['state'] in states]
                if q:
                    try:
                        objects = [o for o in objects if bbql(q, o)]
                    except (ValueError, IndexError) as error:
                        return self.send(400, {"type": "error", "error": {"message": "Invalid query", "detail": str(error)}}, lane)
                objects.sort(key=lambda o: o['updated_on'], reverse=True)
                pagelen = int(query.get('pagelen', ['10'])[0])
                return self.send(200, pick({"size": len(objects), "page": 1, "pagelen": pagelen, "values": objects[:pagelen]}, fields), lane)
            pr = next((p for p in prs if str(p['id']) == parts[1]), None)
            if pr is None:
                return self.send(404, {"type": "error", "error": {"message": "No such pull request"}}, lane)
            if len(parts) == 2:
                return self.send(200, pick(pr_object(m.group(1), key, pr), fields), lane)
            if parts[2] == 'statuses':
                values = []
                for status in pr.get('statuses', []):
                    number = status.get('pipeline')
                    values.append({"type": "build", "state": status['state'], "key": status.get('key', 'pipeline'),
                                   "name": "Pipeline", "url": f"https://bitbucket.org/{key}/addon/pipelines/home#!/results/{number}" if number else "https://ci.example.com/1",
                                   "updated_on": iso(elapsed())})
                return self.send(200, pick({"values": values, "size": len(values)}, fields), lane)
            if parts[2] == 'comments':
                comments = [{"id": 1000 + i, "user": person(c['user']), "created_on": iso(c['at']), "updated_on": iso(c['at']),
                             "deleted": False, "content": {"raw": c.get('text') or "stub comment"}, **({"inline": c['inline']} if c.get('inline') else {})}
                            for i, c in enumerate(pr.get('comments', []))]
                if query.get('sort') == ['-updated_on']:
                    comments.reverse()
                pagelen = int(query.get('pagelen', ['10'])[0])
                return self.send(200, pick({"size": len(comments), "values": comments[:pagelen]}, fields), lane)
            if parts[2:] == ['mergeability', 'checks']:
                return self.send(200, pick({"values": merge_checks(pr)}, fields), lane)
            return self.send(404, {"type": "error", "error": {"message": "Not found"}}, lane)

        return self.send(404, {"type": "error", "error": {"message": "Not found"}}, lane)


if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
