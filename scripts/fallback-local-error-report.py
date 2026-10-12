#!/usr/bin/env python3
"""fallback-local-error-report.py: how many model fallbacks did a LOCAL runtime error cause?

WHY: on 9 Oct 2026 all 309 `candidate_failed` fallback decisions on node-8 came from local
admission/runtime errors, and none from an OpenAI provider failure. Nothing counted that, so it
reached us as a Slack "Model Fallback" notice Nick had to ask about (MUS-6707 ask 4). This
report is the standing counter. It does NOT silence or reword that notice (CTO ruling 4.2:
count it, don't silence it).

READ-ONLY. Reads openclaw's JSON log (<log-dir>/openclaw-<profile>-<YYYY-MM-DD>.log, one
file per profile per day). Every fallback is one `model-fallback/decision` line carrying
`event: model_fallback_decision`.

CLASSIFICATION IS STRUCTURAL, NOT A LIST OF ERROR STRINGS. Local error texts churn week to
week (three turned over in 24 hours on 12 Oct), and a list reads 0% local the first week a new
one appears. A failed decision is:
  provider      its error text carries an HTTP status or a provider error code, or a
                `[model-fetch] response status=4xx/5xx` / `[model-fetch] error` line for the
                same provider+model sits just before it in the log. A provider answered.
  unclassified  a `[model-fetch] start` for the same provider+model sits just before it with no
                answer seen, or the failure has no error text. A request may have left the
                box and we cannot tell how it ended. Never counted as provider or local; its
                distinct error prefixes are printed so the rule can be improved.
  local         everything else: nothing shows a request left the box, so the failure was
                thrown locally (admission, runtime, process inspection, auth profile ...).
A `candidate_succeeded` takes the bucket of the failure that came before it in the same run.
The `[model-fetch]` lines carry no runId, so they are matched on provider+model and a short
time window (FETCH_WINDOW_S).

Alert: only when the LOCAL bucket's `candidate_failed` count for a day reaches --threshold.
The provider bucket never alerts; that is the existing notice's job.

Usage: fallback-local-error-report.py [--profile main] [--date YYYY-MM-DD ...]
       [--log-dir DIR] [--log FILE ...] [--threshold N] [--top N] [--post]
Exit: 0 report printed, no alert; 10 local bucket over threshold; 1 no log readable.
`--post` sends the alert (alert days only) through scripts/lib/slack-notify.sh; without it the
composed message is only printed (dry).
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import os
import re
import subprocess
import sys

# 9 Oct 2026 had 309 local candidate_failed (8 Oct: 114 announce failures, 9 Oct: 108), so a
# per-day floor well under 100 is noise. 12 Oct (hot-patched mid-day) had 49. 150 sits above
# any post-fix day and under half of the worst day. Tune with --threshold.
DEFAULT_THRESHOLD = 150
FETCH_WINDOW_S = 30
BUCKETS = ("local", "provider", "unclassified")

# "status 429", "HTTP 503", "status code: 401", a bare 4xx/5xx next to an HTTP word, or the
# status first ("429 Too Many Requests"). A pid or a port in a local error does not match.
HTTP_STATUS = re.compile(
    r"(?i)(?:\b(?:http|status(?:\s*code)?|response)\b[\s:=]*[\"']?[45]\d\d\b"
    r"|\b[45]\d\d\s+(?:too many requests|unauthorized|forbidden|not found|bad request|"
    r"payment required|request timeout|internal server error|bad gateway|service unavailable|"
    r"gateway timeout)\b)")
# A provider error body or code: {"error": {...}}, rate_limit_exceeded, insufficient_quota ...
PROVIDER_CODE = re.compile(
    r"(?i)(?:\"error\"\s*:\s*\{|\b(?:rate_limit|insufficient_quota|invalid_api_key|"
    r"model_not_found|context_length_exceeded|overloaded_error)\w*)")
FETCH = re.compile(r"\[model-fetch\]\s+(start|response|error)\b(.*)")
FETCH_KV = re.compile(r"\b(provider|model|status)=(\S+)")


class Decision:
    __slots__ = ("ts", "day", "decision", "run", "attempt", "provider", "model", "err", "hash", "bucket")


class Parsed:
    def __init__(self):
        self.events = []  # ("d", ts, Decision) | ("f", ts, kind, provider, model, status)
        self.decisions = []
        self.malformed = 0


def _ts(s):
    try:
        return dt.datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None


def parse_lines(lines) -> Parsed:
    p = Parsed()
    for line in lines:
        line = line.strip()
        if not line or ("model_fallback_decision" not in line and "[model-fetch]" not in line):
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            p.malformed += 1
            continue
        if not isinstance(obj, dict):
            continue
        ts = _ts((obj.get("_meta") or {}).get("date"))
        body = obj.get("1")
        if ts is None:
            p.malformed += 1
            continue
        if isinstance(body, dict) and body.get("event") == "model_fallback_decision":
            d = Decision()
            d.ts, d.day = ts, ts.strftime("%Y-%m-%d")
            d.decision = str(body.get("decision") or "")
            d.run = str(body.get("runId") or "")
            d.attempt = body.get("attempt")
            d.provider = str(body.get("candidateProvider") or "")
            d.model = str(body.get("candidateModel") or "")
            d.err = str(body.get("errorPreview") or "")
            d.hash = str(body.get("errorHash") or "")
            d.bucket = None
            p.events.append(("d", ts, d))
            p.decisions.append(d)
        elif isinstance(body, str):
            m = FETCH.search(body)
            if m:
                kv = dict(FETCH_KV.findall(m.group(2)))
                p.events.append(("f", ts, m.group(1), kv.get("provider", ""), kv.get("model", ""), kv.get("status", "")))
    return p


def _fetch_evidence(fetches, d):
    """Return 'provider', 'started' or None from the [model-fetch] lines just before d."""
    seen_start = False
    for ts, kind, prov, model, status in fetches:
        if prov != d.provider or model != d.model:
            continue
        age = (d.ts - ts).total_seconds()
        if age < 0 or age > FETCH_WINDOW_S:
            continue
        if kind == "error" or (kind == "response" and status[:1] in ("4", "5")):
            return "provider"
        if kind == "start":
            seen_start = True
        elif kind == "response":  # answered 2xx/3xx: the failure came after, locally
            seen_start = False
    return "started" if seen_start else None


def classify_all(p: Parsed):
    fetches = []
    bucket_of_run = {}
    out = []
    for ev in sorted(p.events, key=lambda e: e[1]):
        if ev[0] == "f":
            fetches.append(ev[1:])
            continue
        d = ev[2]
        if d.decision == "candidate_failed":
            ev_kind = _fetch_evidence(fetches, d)
            if HTTP_STATUS.search(d.err) or PROVIDER_CODE.search(d.err) or ev_kind == "provider":
                d.bucket = "provider"
            elif not d.err.strip() or ev_kind == "started":
                d.bucket = "unclassified"
            else:
                d.bucket = "local"
            if d.run:
                bucket_of_run[d.run] = d.bucket
        else:
            d.bucket = bucket_of_run.get(d.run, "none") if d.run else "none"
        out.append(d)
    return out


def summarise(decisions, top: int = 5):
    days = {}
    for d in decisions:
        day = days.setdefault(d.day, {
            "counts": collections.Counter(), "hashes": collections.defaultdict(collections.Counter),
            "samples": {}, "openrouter_succeeded": collections.Counter(),
            "runs": collections.defaultdict(set), "prefixes": collections.defaultdict(collections.Counter)})
        day["counts"][(d.bucket, d.decision)] += 1
        if d.bucket in BUCKETS:
            day["runs"][d.bucket].add(d.run or id(d))
        if d.decision == "candidate_failed" and d.bucket in BUCKETS:
            day["hashes"][d.bucket][d.hash or "(none)"] += 1
            day["samples"].setdefault(d.hash or "(none)", d.err)
            day["prefixes"][d.bucket][" ".join(d.err.split())[:60]] += 1
        if d.decision == "candidate_succeeded" and d.provider == "openrouter":
            day["openrouter_succeeded"][d.bucket] += 1
    return {k: {"counts": v["counts"],
                "top_hashes": {b: v["hashes"][b].most_common(top) for b in BUCKETS},
                "samples": v["samples"], "openrouter_succeeded": v["openrouter_succeeded"],
                "turns": {b: len(v["runs"][b]) for b in BUCKETS},
                "prefixes": {b: v["prefixes"][b].most_common(top) for b in BUCKETS}}
            for k, v in sorted(days.items())}


def alerts(rep, threshold: int):
    return {day: v["counts"][("local", "candidate_failed")] for day, v in rep.items()
            if v["counts"][("local", "candidate_failed")] >= threshold}


def render(rep, threshold: int = DEFAULT_THRESHOLD, profile: str = "main") -> str:
    hot = alerts(rep, threshold)
    lines = [f"*Model fallbacks by cause, profile {profile}* (read-only; local = no request left the box)"]
    for day, v in rep.items():
        c = v["counts"]
        lines.append("")
        lines.append(f"*{day}*")
        for b in BUCKETS:
            f, s = c[(b, "candidate_failed")], c[(b, "candidate_succeeded")]
            if f or s:
                lines.append(f"• {b}: candidate_failed {f} ({v['turns'][b]} turns), candidate_succeeded {s}, "
                             f"landed on openrouter {v['openrouter_succeeded'][b]}")
        for b in BUCKETS:
            for h, n in v["top_hashes"][b]:
                lines.append(f"    {b} {h} ×{n}: {' '.join(v['samples'].get(h, '').split())[:80]}")
        if v["prefixes"]["unclassified"]:
            lines.append("  unclassified error prefixes (extend the rule from these): "
                         + "; ".join(f"“{p or '(empty)'}” ×{n}" for p, n in v["prefixes"]["unclassified"]))
    if not rep:
        lines.append("No model_fallback_decision records in the logs read.")
    for day, n in sorted(hot.items()):
        lines.append("")
        lines.append(f":warning: ALERT {day}: {n} fallback decisions failed on a local runtime error "
                     f"(threshold {threshold}). Not a provider outage; see the top local hashes above.")
    return "\n".join(lines)


def _post(text: str) -> int:
    lib = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "slack-notify.sh")
    return subprocess.run(["bash", "-c", 'source "$1" && slack_notify "$2"', "_", lib, text]).returncode


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--profile", default="main")
    ap.add_argument("--date", action="append", help="YYYY-MM-DD (repeatable); default today (UTC)")
    ap.add_argument("--log-dir", default="/tmp/openclaw")  # tmp-ok: openclaw writes its logs to this fixed dir on node-8
    ap.add_argument("--log", action="append", help="explicit log file (repeatable); overrides profile/date")
    ap.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD)
    ap.add_argument("--top", type=int, default=5)
    ap.add_argument("--post", action="store_true", help="send the alert via slack-notify.sh (default: print only)")
    a = ap.parse_args(argv)
    paths = a.log or [os.path.join(a.log_dir, f"openclaw-{a.profile}-{d}.log")
                      for d in (a.date or [dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")])]
    p = Parsed()
    read = 0
    for path in paths:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                q = parse_lines(fh)
        except OSError as e:
            print(f"cannot read {path}: {e.strerror}", file=sys.stderr)
            continue
        read += 1
        p.events += q.events
        p.decisions += q.decisions
        p.malformed += q.malformed
    if not read:
        print("no log file could be read: this is not a zero.", file=sys.stderr)
        return 1
    rep = summarise(classify_all(p), a.top)
    text = render(rep, a.threshold, a.profile)
    if p.malformed:
        text += f"\n:warning: {p.malformed} log line(s) mentioned a fallback but could not be decoded."
    print(text)
    hot = alerts(rep, a.threshold)
    if hot and a.post:
        _post(text)
    return 10 if hot else 0


if __name__ == "__main__":
    sys.exit(main())
