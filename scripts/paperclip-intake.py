#!/usr/bin/env python3
"""paperclip-intake: hydra agents file Paperclip cards instead of DMing a human.

One card per DISTINCT problem. Filing the same problem again comments the
occurrence and bumps `Occurrences: N` on the existing card.

Subcommands:
  file       --agent NAME --title T --body B [--component C]   file or bump a card
  precheck   --wake-job ID                                     ZERO-TOKEN sweep: wake Clio's triage job only if an
                                                               untriaged intake card is waiting
  escalate   --to-agent ID|NAME [--after-minutes 30]                reassign intake cards untriaged for 30 min (aged from createdAt) to the pilot agent
  waiting                                                      list untriaged intake cards (for the triage agent)
  escalations                                                  count cards the fallback has escalated (pilot report)

Dedupe key (ported from hydra#1002 plugins/tracker/src/fingerprint.ts, spec 4):
  fp = sha256(normalize(component) + NUL + normalize(title))[:16]
The card carries `fp:<hash>` in its description; a search hit is bumped ONLY if
the exact token is present (search is relevance-ranked, a near-match comes
back, and bumping the wrong card hides a real problem). Concurrent filers can
both miss and both create: accepted, triage merges the twin. Filers on one host
are serialised per fingerprint by a lock file, so counter bumps never overlap.

The API key is read from a FILE at call time, never from the environment: an
env-file change needs a gateway restart (~25 min cold start) and this script
must never be the reason for one.

Env (all optional):
  PAPERCLIP_INTAKE_URL       default http://127.0.0.1:3100
  PAPERCLIP_INTAKE_KEY_FILE  default /etc/paperclip/secrets/hydra-intake
  PAPERCLIP_INTAKE_STATE     default /var/tmp/hydra-paperclip-intake-wake  # tmp-ok: fixed wake-state file

Exit codes: 0 ok · 1 API/IO failure · 2 usage or refused input
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

DEFAULT_URL = "http://127.0.0.1:3100"
DEFAULT_KEY_FILE = "/etc/paperclip/secrets/hydra-intake"
DEFAULT_STATE = "/var/tmp/hydra-paperclip-intake-wake"  # tmp-ok: fixed wake-state file, not scratch
INTAKE_MARKER = "Source: hydra-intake"
ESCALATED_LABEL = "intake-escalated"
CLOSED = ("done", "cancelled")
HTTP_TIMEOUT = 20
MAX_PAGES = 5  # the search API refuses offset > 200 (limit 50): 250 hits is its ceiling, and search_issues raises rather than return a truncated list

# ---- fingerprint (port of plugins/tracker/src/fingerprint.ts) ---------------
# Order matters: most specific first. A URL contains digits and a UUID contains
# hex runs; scrubbing digits first shreds a UUID into "<N>a<N>b<N>". ASCII flag
# keeps \d \w \b identical to the JS originals.
_A = re.ASCII
ISO_TS_RE = re.compile(
    r"\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)?", re.I | _A)
URL_RE = re.compile(r"\b(?:https?|wss?|ftp)://\S+", re.I | _A)
UUID_RE = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I | _A)
PATH_RE = re.compile(r"(?:[A-Za-z]:\\|/)(?:[\w.@~-]+[/\\])*[\w.@~-]+", _A)
# REQUIRES one a-f letter so a purely decimal run (epoch, batch number) falls
# through to NUM_RE and becomes <N>, not <ID>; else "batch 1789156623" and
# "batch 42" never dedupe.
HEX_RE = re.compile(r"\b(?=[0-9a-f]{8,}\b)[0-9a-f]*[a-f][0-9a-f]*\b", re.I | _A)
CLOCK_RE = re.compile(r"\b\d{1,2}:\d{2}(?::\d{2})?\b", _A)
NUM_RE = re.compile(r"\b\d+(?:\.\d+)?\b", _A)
# Keep letters, digits, whitespace and the <> of the placeholders.
PUNCT_RE = re.compile(r"(?:[^\w\s<>]|_)+")
WS_RE = re.compile(r"\s+")


def normalize(text):
    s = str(text if text is not None else "").lower()
    s = URL_RE.sub(" <URL> ", s)
    s = UUID_RE.sub(" <ID> ", s)
    s = ISO_TS_RE.sub(" <TS> ", s)
    s = PATH_RE.sub(" <PATH> ", s)
    s = HEX_RE.sub(" <ID> ", s)
    s = CLOCK_RE.sub(" <TS> ", s)
    s = NUM_RE.sub(" <N> ", s)
    s = PUNCT_RE.sub(" ", s)
    return WS_RE.sub(" ", s).strip()


def fingerprint(title, component=None):
    """NUL separator stops component/title boundary collisions."""
    key = f"{normalize(component)}\x00{normalize(title)}"
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]


# ---- Paperclip client --------------------------------------------------------

class ApiError(Exception):
    pass


SECRET_RE = re.compile(
    r"sk-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}"
    r"|pcp_[A-Za-z0-9]{16,}|Bearer\s+[A-Za-z0-9._-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----")


def read_key(env):
    """Read the key file NOW. Refuse a world-accessible file: the secret is
    root:paperclip 0640 or 0600, anything looser means it was mis-placed."""
    path = env.get("PAPERCLIP_INTAKE_KEY_FILE", DEFAULT_KEY_FILE)
    try:
        st = os.stat(path)
        if st.st_mode & (stat.S_IROTH | stat.S_IWOTH | stat.S_IXOTH):
            raise ApiError(f"key file {path} has unsafe permissions {oct(st.st_mode & 0o777)}")
        with open(path, encoding="utf-8") as fh:
            key = fh.read().strip()
    except OSError as exc:
        raise ApiError(f"key file {path} unreadable: {exc.strerror}") from exc
    if not key:
        raise ApiError(f"key file {path} is empty")
    return key


class Client:
    def __init__(self, env):
        self.base = env.get("PAPERCLIP_INTAKE_URL", DEFAULT_URL).rstrip("/")
        self.key = read_key(env)
        self._company = None

    def call(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method, headers={
            "Authorization": f"Bearer {self.key}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
                return json.loads(resp.read() or b"null")
        except urllib.error.HTTPError as exc:
            raise ApiError(f"{method} {path} -> HTTP {exc.code}") from exc
        except (urllib.error.URLError, OSError, ValueError) as exc:
            raise ApiError(f"{method} {path} failed: {exc}") from exc

    @property
    def company(self):
        if self._company is None:
            self._company = self.call("GET", "/api/agents/me")["companyId"]
        return self._company

    def search_issues(self, q, status=None, limit=50):
        """Every issue hit for `q`, paged: a short page is the last one. If all MAX_PAGES pages come back
        full the list is provably incomplete, so raise: a dedupe read that silently misses a twin files a duplicate."""
        hits = []
        for page in range(MAX_PAGES):
            params = {"q": q, "scope": "issues", "limit": str(limit), "offset": str(page * limit)}
            if status:
                params["status"] = status
            res = self.call("GET", f"/api/companies/{self.company}/search?{urllib.parse.urlencode(params)}")
            raw = res.get("results", [])
            hits += [r for r in raw if r.get("type") == "issue"]
            if len(raw) < limit:
                return hits
        raise ApiError(f"search for {q!r} returned the {MAX_PAGES * limit}-hit ceiling; result is incomplete")

    def list_issues(self, status, q, limit=100):
        """Every issue with `status` (any status when None) matching `q`, paged until a short page. The list endpoint has no
        250-hit ceiling (the search one does), so the waiting queue is never cut off."""
        rows, offset = [], 0
        while True:
            params = {"q": q, "limit": str(limit), "offset": str(offset)}
            if status:
                params["status"] = status
            params = urllib.parse.urlencode(params)
            page = self.call("GET", f"/api/companies/{self.company}/issues?{params}")
            rows += page
            if len(page) < limit:
                return rows
            offset += limit

    def issue(self, issue_id):
        return self.call("GET", f"/api/issues/{issue_id}")

    def comment(self, issue_id, body):
        self.call("POST", f"/api/issues/{issue_id}/comments", {"body": body})

    def agent_id(self, ref):
        """Accept an agent id, name or urlKey (the pilot agent's id is only known on the node-8 instance)."""
        for a in self.call("GET", f"/api/companies/{self.company}/agents"):
            if ref in (a.get("id"), a.get("name"), a.get("urlKey")):
                return a["id"]
        raise ApiError(f"no agent matching {ref!r}")

    def label_id(self, name):
        for lab in self.call("GET", f"/api/companies/{self.company}/labels"):
            if lab["name"] == name:
                return lab["id"]
        return self.call("POST", f"/api/companies/{self.company}/labels",
                         {"name": name, "color": "#dc2626"})["id"]


def has_token(description, fp):
    """Exact whitespace-delimited `fp:<hash>` token: not a prefix of a longer
    token, not a suffix of `otherfp:<hash>`."""
    return re.search(rf"(?<!\S)fp:{fp}(?!\S)", description or "") is not None


def waiting_cards(client):
    """Untriaged intake cards: marker present, status todo, nobody assigned."""
    out = []
    for row in client.list_issues("todo", "hydra-intake"):
        if row.get("assigneeAgentId"):
            continue
        card = client.issue(row["id"])
        if (INTAKE_MARKER in (card.get("description") or "") and card.get("status") == "todo"
                and not card.get("assigneeAgentId")):
            out.append(card)
    return out


# ---- subcommands -------------------------------------------------------------

def cmd_file(client, args, env):
    if SECRET_RE.search(f"{args.title}\n{args.body}"):
        raise SystemExit("refused: title/body looks like it contains a secret; remove it and refile")
    component = args.component or args.agent
    fp = fingerprint(args.title, component)
    # One filer per fingerprint at a time on this host: the counter bump is a
    # read-modify-write, and two overlapping bumps would count two filings as one.
    # Sibling lock file, never removed (same pattern as cmd_precheck).
    state = env.get("PAPERCLIP_INTAKE_STATE", DEFAULT_STATE)
    with open(f"{state}.file-{fp}.lock", "w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _file_locked(client, args, component, fp)


def _file_locked(client, args, component, fp):
    for hit in client.search_issues(f"fp:{fp}"):
        card = client.issue(hit["id"])
        if card.get("status") in CLOSED or not has_token(card.get("description"), fp):
            continue
        desc = card.get("description") or ""
        m = re.search(r"Occurrences: (\d+)", desc)
        n = (int(m.group(1)) if m else 1) + 1
        desc = re.sub(r"Occurrences: \d+", f"Occurrences: {n}", desc) if m else f"{desc}\nOccurrences: {n}"
        # Comment first: if it fails nothing has been counted, so a retry counts once.
        # If the PATCH fails after it, the retry posts the same "Occurrence n" again
        # but the counter still lands on n.
        client.comment(card["id"], f"Occurrence {n}, filed by {args.agent}.\n\n{args.body}")
        client.call("PATCH", f"/api/issues/{card['id']}", {"description": desc})
        return {"action": "bumped", "id": card["id"], "identifier": card.get("identifier"),
                "occurrences": n, "fp": fp}
    description = (f"{INTAKE_MARKER}\nFiled by: {args.agent}\nComponent: {component}\n"
                   f"fp:{fp}\nOccurrences: 1\n\n{args.body}")
    card = client.call("POST", f"/api/companies/{client.company}/issues",
                       {"title": args.title, "description": description, "status": "todo",
                        "priority": "medium"})
    return {"action": "created", "id": card["id"], "identifier": card.get("identifier"),
            "occurrences": 1, "fp": fp}


def wake_job(job_id):
    """Fire Clio's (disabled) triage job. `cron run` is a forced fire that works
    on a disabled job. The ONLY thing this script does that costs tokens, and
    only when a card is waiting."""
    subprocess.run(["openclaw", "--profile", "main", "cron", "run", job_id],
                   check=True, timeout=60, capture_output=True)


def _woken_ids(state):
    try:
        with open(state, encoding="utf-8") as fh:
            data = json.load(fh)
        return float(data["ts"]), set(data["ids"])
    except (OSError, ValueError, KeyError, TypeError):
        return 0.0, set()


def cmd_precheck(client, args, env):
    waiting = waiting_cards(client)
    state = env.get("PAPERCLIP_INTAKE_STATE", DEFAULT_STATE)
    # Interprocess lock around state read, decision, wake and state write: two
    # overlapping ticks must not both pass the suppression check and wake Clio twice.
    # A sibling lock file, never removed, so the state file can still be deleted below.
    with open(state + ".lock", "w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not waiting:
            # Queue drained: forget the last wake so the next card is never held back by it.
            try:
                os.remove(state)
            except OSError:
                pass
            return None
        ids = {c["id"] for c in waiting}
        last, seen = _woken_ids(state)
        # 0 <= : a ts ahead of the clock (stepped backward) must not hold the wake back.
        if ids <= seen and 0 <= time.time() - last < args.rewake_minutes * 60:
            return {"waiting": len(waiting), "woke": False, "reason": "recently woken"}
        wake_job(args.wake_job)
        with open(state, "w", encoding="utf-8") as fh:
            json.dump({"ts": time.time(), "ids": sorted(ids)}, fh)
        return {"waiting": len(waiting), "woke": True}


def _age_minutes(card):
    raw = card.get("createdAt")
    try:
        ts = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        if ts.tzinfo is None:
            raise ValueError("no timezone")
    except (AttributeError, ValueError):
        # Age 0 would skip the card on every run and exit 0: fail loud instead.
        raise ApiError(f"card {card.get('id')} has no usable createdAt: {raw!r}")
    return (datetime.now(timezone.utc) - ts).total_seconds() / 60


def cmd_escalate(client, args):
    n = 0
    label = None
    # Resolve first: a wrong --to-agent must fail on every run, not only once a card ages out.
    target = client.agent_id(args.to_agent)
    for card in waiting_cards(client):
        if _age_minutes(card) < args.after_minutes:
            continue
        label = label or client.label_id(ESCALATED_LABEL)
        client.call("PATCH", f"/api/issues/{card['id']}",
                    {"assigneeAgentId": target,
                     "labelIds": sorted(set(card.get("labelIds") or []) | {label})})
        client.comment(card["id"], f"Waiting {args.after_minutes} minutes untriaged: escalated to the pilot "
                                   f"agent (label {ESCALATED_LABEL}).")
        n += 1
    return {"escalated": n}


def cmd_waiting(client, args):
    return {"waiting": [{"id": c["id"], "identifier": c.get("identifier"), "title": c.get("title")}
                        for c in waiting_cards(client)]}


def cmd_escalations(client, args):
    label = client.label_id(ESCALATED_LABEL)
    n = sum(1 for card in client.list_issues(None, "hydra-intake")
            if label in (client.issue(card["id"]).get("labelIds") or []))
    return {"escalated": n}


def main(argv=None, env=None):
    env = os.environ if env is None else env
    p = argparse.ArgumentParser(prog="paperclip-intake")
    sub = p.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("file")
    f.add_argument("--agent", required=True)
    f.add_argument("--title", required=True)
    f.add_argument("--body", required=True)
    f.add_argument("--component")
    pc = sub.add_parser("precheck")
    pc.add_argument("--wake-job", required=True)
    pc.add_argument("--rewake-minutes", type=int, default=30)
    e = sub.add_parser("escalate")
    e.add_argument("--to-agent", required=True)
    e.add_argument("--after-minutes", type=int, default=30)
    sub.add_parser("waiting")
    sub.add_parser("escalations")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    try:
        client = Client(env)
        if args.cmd == "file":
            result = cmd_file(client, args, env)
        elif args.cmd == "precheck":
            result = cmd_precheck(client, args, env)
        elif args.cmd == "escalate":
            result = cmd_escalate(client, args)
        elif args.cmd == "waiting":
            result = cmd_waiting(client, args)
        else:
            result = cmd_escalations(client, args)
    except SystemExit as exc:
        print(exc, file=sys.stderr)
        return 2
    except (ApiError, subprocess.SubprocessError) as exc:
        print(f"paperclip-intake: {exc}", file=sys.stderr)
        return 1
    if result is not None:  # an empty pre-check prints NOTHING
        print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
