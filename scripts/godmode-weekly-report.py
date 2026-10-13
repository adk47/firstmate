#!/usr/bin/env python3
"""godmode-weekly-report.py: weekly report to Aaron of every logged god-mode action.

WHY: workspaces/cto/USER.md used to say Nick's requests are "never escalated or
reported to Aaron". Fable credit-fraud review item 10 (2026-10-11) removed that line:
god-mode actions are logged and reported to Aaron weekly. Every agent already writes an
audit record before a write (its SOUL "Write Activity Logging" rule) under
/opt/hydra/workspaces/<agent>/api-logs/. This script is the "reported weekly" half: it
reads those records and renders one Slack message. The cron
`godmode-actions-weekly-report` posts it to Aaron's DM.

READ-ONLY. No network, no writes. Output goes to stdout. A god-mode action is a logged
record whose requester (or operator.slack_id or approved_by) is a god-mode human, or
whose authorization says it was self-approved under god mode. Aaron's own actions are
counted but not itemized; everyone else's are itemized, newest first.

If no api-logs directory can be read, the script says so and exits 1. If any log file
cannot be read, any record cannot be decoded, or a god-mode record has no valid timestamp,
the report says INCOMPLETE and exits 3.
An unreadable log is never the same as "no god-mode actions".

Usage: godmode-weekly-report.py [--days 7] [--root /opt/hydra/workspaces] [--now ISO]
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import glob
import json
import os
import re
import sys

GODMODE = {"U0AL36NADEY": "Nick", "U7RP6HKUZ": "Aaron"}
REPORT_TO = "U7RP6HKUZ"  # Aaron's own actions are counted, not itemized.
NAMES = {**GODMODE, "U038BM16T7W": "Jan", "U02N2NP3H7F": "Artem"}
GODMODE_AUTH = re.compile(r"god[_ -]?mode|self[_ -]?authori[sz]|explicit(ly)? (in-thread )?(direction|approv)|bounded approval", re.I)
# Records written by automation on a human's behalf (the QA bot reviewing a PR its author
# opened, a cron payload): the human is named as requester, but they authorized nothing.
# Counted on one line, never itemized as a god-mode action.
AUTOMATED_AUTH = re.compile(r"^\s*(auto-review-dispatch|qa-review-go-verdict|cron_payload|scheduled monitor)", re.I)
UID = re.compile(r"\bU[A-Z0-9]{8,11}\b")
NAME_TO_UID = {"nick": "U0AL36NADEY", "nicholas": "U0AL36NADEY", "aaron": "U7RP6HKUZ",
               "jan": "U038BM16T7W", "artem": "U02N2NP3H7F"}
EMAIL = re.compile(r"([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
# A credential keyword and the VALUE after it, whatever the separator: "Bearer X",
# "Authorization: Bearer X", "token=X", "api_key: X", "access_token X" (QA on hydra#1143:
# a spaced "Bearer X" used to leave X in the Slack message).
SECRET_KV = re.compile(
    r"(?i)\b((?:[A-Za-z0-9]+[_-])*(?:authorization|bearer|token|secret|password|passwd|api[_-]?key))"
    r"(?:\s*[:=]\s*|\s+)(?:bearer\s+)?[\"']?[^\s\"',;]+[\"']?")
# Credential shapes that need no keyword: Slack, OpenAI-style, GitHub, JWT.
SECRET_SHAPES = re.compile(
    r"\b(?:xox[abprs]-[A-Za-z0-9-]{8,}|sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}"
    r"|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})")
ITEM_LIMIT = 25
AUDIT_SUFFIXES = (".json", ".jsonl", ".log")


def _parse_ts(v) -> dt.datetime | None:
    if v is None:
        return None
    if isinstance(v, (int, float)):
        x = float(v)
        if x > 1e12:
            x /= 1000.0
        try:
            return dt.datetime.fromtimestamp(x, dt.timezone.utc)
        except (OverflowError, OSError, ValueError):
            return None
    s = str(v).strip()
    if not s:
        return None
    try:
        t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def _as_dict(v) -> dict:
    if isinstance(v, dict):
        return v
    return {}


_DECODER = json.JSONDecoder()


def read_records(path: str, problems: collections.Counter | None = None):
    """Yield dict records from a log file: one JSON object, a JSON list, JSONL, or
    pretty-printed objects appended one after another (some writers do that). Never
    raises. Anything that cannot be read or decoded is counted in `problems`
    ("unreadable_files" / "malformed_records"), so the report can say it is incomplete
    instead of presenting a partial read as a complete one (QA on hydra#1143)."""
    problems = problems if problems is not None else collections.Counter()
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError):
        problems["unreadable_files"] += 1
        return
    i, n = 0, len(text)
    while True:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            return
        try:
            obj, i = _DECODER.raw_decode(text, i)
        except ValueError:
            problems["malformed_records"] += 1
            nl = text.find("\n", i)  # resync at the next line
            if nl < 0:
                return
            i = nl + 1
            continue
        for r in obj if isinstance(obj, list) else [obj]:
            if isinstance(r, dict):
                yield r
            else:
                # Valid JSON but not an audit record (null, a number, a string, a
                # nested list): a corrupt entry, counted like an undecodable one
                # (QA on hydra#1143).
                problems["malformed_records"] += 1


def _norm_person(v: str) -> str:
    """Slack UID for 'U0AL36NADEY', 'Nick (U0AL36NADEY)', 'Nick Sollazzo', 'jan@muso.ai'."""
    v = v.strip()
    m = UID.search(v)
    if m:
        return m.group(0)
    first = re.split(r"[\s@._-]+", v.lower(), maxsplit=1)[0] if v else ""
    return NAME_TO_UID.get(first, v)


def identities(rec: dict) -> list[str]:
    """Every person a record names: requester, operator.slack_id, requested_by,
    approved_by. All are checked; the first non-empty one is not enough (QA on
    hydra#1143: requester='customer' with operator.slack_id=Nick was missed)."""
    op = _as_dict(rec.get("operator"))
    out = []
    for v in (rec.get("requester"), op.get("slack_id"), rec.get("requested_by"), rec.get("approved_by")):
        if isinstance(v, str) and v.strip():
            p = _norm_person(v)
            if p not in out:
                out.append(p)
    return out


def who(rec: dict) -> str:
    """The person to attribute the action to: a god-mode identity if any field names
    one, otherwise the first identity named."""
    ids = identities(rec)
    for p in ids:
        if p in GODMODE:
            return p
    return ids[0] if ids else ""


def is_automated(rec: dict) -> bool:
    return bool(AUTOMATED_AUTH.search(authorization(rec)))


def authorization(rec: dict) -> str:
    op = _as_dict(rec.get("operator"))
    parts = [rec.get("authorization"), op.get("authorization"), rec.get("auth")]
    return " ".join(str(p) for p in parts if p)


def is_godmode(rec: dict) -> bool:
    if any(p in GODMODE for p in identities(rec)):
        return True
    return bool(GODMODE_AUTH.search(authorization(rec)))


def action_of(rec: dict) -> str:
    return str(rec.get("action") or rec.get("operation") or rec.get("endpoint") or "unspecified")[:60]


def safe(s, n: int = 90) -> str:
    """One line, emails masked, secret-looking tokens cut, Slack-escaped, bounded."""
    if isinstance(s, (dict, list)):
        s = json.dumps(s, sort_keys=True)
    s = " ".join(str(s or "").split())
    s = EMAIL.sub(lambda m: f"{m.group(1)}***@{m.group(2)}", s)
    s = SECRET_KV.sub(lambda m: m.group(1) + "=[redacted]", s)
    s = SECRET_SHAPES.sub("[redacted]", s)
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return s if len(s) <= n else s[: n - 1] + "…"


def collect(root: str, since: dt.datetime, until: dt.datetime):
    """Return (dirs_read, events, automated). Events are deduped god-mode records in the
    window; automated counts records excluded as automation on a god-mode human's behalf."""
    dirs = sorted(d for d in glob.glob(os.path.join(root, "*", "api-logs")) if os.path.isdir(d))
    seen: set = set()
    events = []
    automated: collections.Counter = collections.Counter()
    problems: collections.Counter = collections.Counter()
    for d in dirs:
        agent_dir = os.path.basename(os.path.dirname(d))
        paths = []
        # os.walk reports a directory it cannot list through onerror; glob would
        # silently return nothing for it, which reads as a zero.
        for top, _subdirs, files in os.walk(d, onerror=lambda e: problems.update(["unreadable_files"])):
            paths.extend(os.path.join(top, f) for f in files)
        for path in sorted(paths):
            # Audit records are .json/.jsonl, and some writers use .log (node-8
            # operations/api-logs/2026-10-08.log is a JSON record). .txt/.md files
            # there are message bodies and review drafts, not records.
            if not path.endswith(AUDIT_SUFFIXES) or not os.path.isfile(path):
                continue
            try:
                if os.path.getmtime(path) < since.timestamp():
                    continue  # nothing in a file last written before the window
            except OSError:
                problems["unreadable_files"] += 1
                continue
            for i, rec in enumerate(read_records(path, problems)):
                if not is_godmode(rec):
                    continue
                ts = _parse_ts(rec.get("timestamp") or rec.get("ts") or rec.get("created_at"))
                if ts is None:
                    # A god-mode action we cannot place in time may be in this week: the
                    # report is incomplete, never a silent skip (QA on hydra#1143).
                    if not is_automated(rec):
                        problems["undated_records"] += 1
                    continue
                if not (since <= ts < until):
                    continue
                agent = str(rec.get("agent") or agent_dir)
                cid = rec.get("correlation_id")
                # pre/result phases of one write share a correlation id: count it once.
                key = (agent, str(cid)) if cid else (path, i)
                if key in seen:
                    continue
                seen.add(key)
                if is_automated(rec):
                    automated[NAMES.get(who(rec), who(rec) or "unknown")] += 1
                    continue
                events.append({
                    "ts": ts, "agent": agent, "who": who(rec),
                    "action": action_of(rec), "target": rec.get("target") or rec.get("endpoint") or "",
                    "auth": authorization(rec),
                })
    return dirs, events, automated, problems


def render(dirs, events, since: dt.datetime, until: dt.datetime, automated=None, problems=None) -> str:
    span = f"{since:%Y-%m-%d %H:%MZ} to {until:%Y-%m-%d %H:%MZ}"
    if not dirs:
        return (f":warning: *God-mode weekly report ({span})*: no agent api-logs directory was "
                "readable, so this week's god-mode actions could NOT be counted. This is not a zero.")
    lines = [f"*God-mode actions, {span}* (from {len(dirs)} agents' audit logs; read-only report)"]
    if problems and sum(problems.values()):
        lines.append(f":warning: INCOMPLETE: {problems['unreadable_files']} log file(s) could not be read, "
                     f"{problems['malformed_records']} record(s) could not be decoded, and "
                     f"{problems['undated_records']} god-mode record(s) had no valid timestamp. The counts "
                     "below cover only what was readable and may be missing god-mode actions.")
    auto_line = ""
    if automated:
        auto_line = ("Not counted (automation on a requester's behalf, e.g. QA reviews of their PRs): "
                     + ", ".join(f"{safe(k, 30)} {n}" for k, n in automated.most_common()))
    if not events:
        lines.append("No god-mode actions were logged in this window.")
        if auto_line:
            lines.append(auto_line)
        return "\n".join(lines)
    by_who = collections.defaultdict(list)
    for e in events:
        by_who[e["who"]].append(e)
    # Nick first (the USER.md line this report replaces was about him), Aaron last.
    order = sorted(by_who, key=lambda w: (w == REPORT_TO, w != "U0AL36NADEY", -len(by_who[w]), w))
    for w in order:
        evs = by_who[w]
        name = NAMES.get(w, safe(w, 30) or "unknown requester")
        agents = collections.Counter(e["agent"] for e in evs)
        acts = collections.Counter(e["action"] for e in evs)
        lines.append("")
        lines.append(f"*{name}*: {len(evs)} action(s). By agent: "
                     + ", ".join(f"{a} {n}" for a, n in agents.most_common()))
        lines.append("Top actions: " + ", ".join(f"{safe(a, 40)} ×{n}" for a, n in acts.most_common(8)))
        if w == REPORT_TO:
            continue
        evs = sorted(evs, key=lambda e: e["ts"], reverse=True)
        for e in evs[:ITEM_LIMIT]:
            lines.append(f"• {e['ts']:%m-%d %H:%MZ} {e['agent']}: {safe(e['action'], 40)} → {safe(e['target'])}")
        if len(evs) > ITEM_LIMIT:
            lines.append(f"• …and {len(evs) - ITEM_LIMIT} more (full records: /opt/hydra/workspaces/*/api-logs/)")
    if auto_line:
        lines.append("")
        lines.append(auto_line)
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--root", default="/opt/hydra/workspaces")
    ap.add_argument("--now", default=None, help="ISO end of window (tests)")
    a = ap.parse_args(argv)
    until = _parse_ts(a.now) if a.now else dt.datetime.now(dt.timezone.utc)
    if until is None:
        print("bad --now", file=sys.stderr)
        return 2
    since = until - dt.timedelta(days=a.days)
    dirs, events, automated, problems = collect(a.root, since, until)
    print(render(dirs, events, since, until, automated, problems))
    if not dirs:
        return 1
    return 3 if sum(problems.values()) else 0


if __name__ == "__main__":
    sys.exit(main())
