#!/usr/bin/env python3
"""Reader alarm for the armed claim-proof-ask family.

Why this exists (p1 rule 8, QA on hydra#1758 Important 1, driver 17:5xZ): the 30-hour freshness gate in
`claim_proof_ask.load_list(require_daily_check=True)` refuses NEW asks once the daily code check is stale.
It says nothing about the asks already out - if the reader stops, those claimants' replies are never read,
their codes are never verified on any surface, and nobody is paged. This is that page, and it is why the
family may carry a date at all.

WHAT IT MEASURES (the reader's own artefacts, never a sender's prose):
  last-run.json   last_run_at / asked / owner - the reader's heartbeat and the population it is reading
  digest          the newest proof-check-*-digest.json - the claim ids the reader actually looked at
  ledger          verify_messages, campaign=claim-proof-ask, sent_at not null - the asks that went out

ALARMS (one line each, exit 1):
  missing    last-run.json is absent or unparseable. Fail closed: a reader that cannot say it ran has not run.
  stale      the reader's last_run_at is older than --limit-h (default 30 = DAILY_CHECK_MAX_AGE_H).
  future     a timestamp is more than FUTURE_SKEW_S in the FUTURE (QA #1758 Important 2). A future-dated
             heartbeat or digest yields a NEGATIVE age, so a clock-skewed artefact would read as permanently fresh
             and suppress this alarm until the clock caught up. A timestamp we cannot have produced is not a
             measurement, so it is an alarm in the same voice as stale - never freshness.
  digest     the newest digest is older than --limit-h, or it names zero asks (a reader reading nothing).
  untracked  asks in the ledger that the newest digest never looked at, sent more than --unread-h ago.
             This is the "reply unread" class made measurable: nothing in the ledger records a reply or a
             code read for this campaign (last_reply_at / proof_checked_at / proof_tagged_at are NULL on
             every sent row today), so the one honest statement of "unread" is "the reader did not look".

SIGNATURE: every run prints one last line `SIGNATURE <16 hex>` over the STABLE part of the verdict - the alarm
categories plus the identity of each affected ask - and over nothing that moves on its own. The caller pages on
this, not on the text (QA #1758 Important 1): the text carries ages and counts, so hashing it made the repeat
cooldown dead - a persistent outage changed the digest every tick and paged every two hours. Two ticks of the
SAME outage now share a signature; a changed alarm set (one more unread ask, a category appearing) does not,
and still pages at once.

HEALTHY: exit 0 with one OK line carrying the numbers, so the caller's log holds the state on every run and
a silent tick can be told apart from a healthy one.

EXIT 2: something it needs could not be read (state dir, digest, ledger). An alarm that cannot measure is
not a healthy system, so the caller pages this too.

Read-only. No network. No writes.
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone

DEFAULT_STATE_DIR = "/var/lib/claim-proof-check"
DEFAULT_LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
CAMPAIGN = "claim-proof-ask"
# How far ahead of `now` a timestamp may sit before it is a clock problem rather than a measurement. Writers on this
# fleet stamp in UTC from the same clock; a few minutes of NTP slew is ordinary, hours of it is a broken writer.
FUTURE_SKEW_S = 300


def parse_utc(s):
    """Every writer in this repo emits one of these two forms; anything else is not a time."""
    if not s:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%MZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def read_last_run(state_dir):
    """(owner, last_run_at datetime, asked) - or (None, None, None) when the heartbeat is unusable."""
    path = os.path.join(state_dir, "last-run.json")
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return None, None, None
    if not isinstance(d, dict):
        return None, None, None
    when = parse_utc(d.get("last_run_at"))
    asked = d.get("asked")
    if when is None or not isinstance(asked, int):
        return None, None, None
    return d.get("owner"), when, asked


def read_digest(state_dir):
    """(batch, generatedAt datetime, {claim id: status}) from the newest digest, or None."""
    best = None
    for path in glob.glob(os.path.join(state_dir, "proof-check-*-digest.json")):
        try:
            with open(path, encoding="utf-8") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(d, dict):
            continue
        when = parse_utc(d.get("generatedAt"))
        if when is None:
            continue
        if best is None or when > best[1]:
            claims = {}
            for c in d.get("claims") or []:
                if isinstance(c, dict) and isinstance(c.get("id"), int):
                    claims[c["id"]] = c.get("status")
            best = (d.get("batch"), when, claims)
    return best


def read_asks(ledger):
    """{claim id: earliest sent_at datetime} for every claim this campaign has actually sent an ask for.

    A held row (sent_at NULL) is not an ask and never enters this map - the same rule the sender's own
    counters use. The claim ids come from request_ids_json, which is what the message was about.
    """
    con = sqlite3.connect("file:%s?mode=ro" % ledger, uri=True)
    try:
        rows = con.execute(
            "select request_ids_json, sent_at from verify_messages"
            " where campaign = ? and sent_at is not null and sent_at <> ''",
            (CAMPAIGN,),
        ).fetchall()
    finally:
        con.close()
    asks = {}
    for raw, sent in rows:
        when = parse_utc(sent)
        if when is None:
            continue
        try:
            ids = json.loads(raw or "[]")
        except ValueError:
            continue
        for rid in ids if isinstance(ids, list) else []:
            if isinstance(rid, str) and rid.startswith("claim-"):
                try:
                    cid = int(rid[6:])
                except ValueError:
                    continue
                if cid not in asks or when < asks[cid]:
                    asks[cid] = when
    return asks


def hours(delta):
    return delta.total_seconds() / 3600.0

def is_future(delta):
    """True when an artefact is dated beyond ordinary clock skew (a negative age that must not read as fresh)."""
    return delta.total_seconds() < -FUTURE_SKEW_S

def signature(basis):
    """16 hex over the stable part of the verdict: categories and identities, never ages or counts."""
    return hashlib.sha256("\n".join(sorted(basis)).encode("utf-8")).hexdigest()[:16]


def evaluate(state_dir, ledger, limit_h, unread_h, now):
    """(alarms, ok_line) - alarms is a list of str, empty when healthy. Raises OSError/ValueError on
    something it could not read (the caller turns that into exit 2)."""
    owner, last_run, asked = read_last_run(state_dir)
    if last_run is None:
        return ["missing: %s/last-run.json is absent or unparseable - the daily code check cannot say it ran,"
                " so every ask already sent has an unread reply and nobody is being told"
                % state_dir.rstrip("/")], None, signature(["missing"])
    alarms = []
    basis = []   # the stable half: what is wrong and about which ask, never how long it has been wrong
    age = hours(now - last_run)
    who = owner or "unknown owner"
    if is_future(now - last_run):
        basis.append("future-heartbeat")
        alarms.append("future: the daily code check's last_run_at is %.1fh in the FUTURE (skew limit %ds) - a"
                      " timestamp we cannot have produced proves nothing about the reader, and it would read as"
                      " fresh until the clock caught up (owner %s)" % (-age, FUTURE_SKEW_S, who))
    elif age > limit_h:
        basis.append("stale")
        alarms.append("stale: the daily code check last ran %.1fh ago (limit %dh) - %d asked codes have unread"
                      " replies from now on (owner %s)" % (age, limit_h, asked, who))
    digest = read_digest(state_dir)
    if digest is None:
        basis.append("digest-unreadable")
        alarms.append("digest: no readable proof-check-*-digest.json in %s - the reader has no record of looking"
                      " at any ask (owner %s)" % (state_dir.rstrip("/"), who))
        claims = {}
    else:
        batch, generated, claims = digest
        dage = hours(now - generated)
        if is_future(now - generated):
            basis.append("future-digest")
            alarms.append("future: the newest digest (%s) is generated %.1fh in the FUTURE (skew limit %ds) - a"
                          " clock-skewed digest would suppress this alarm while the reader is stopped (owner %s)"
                          % (batch, -dage, FUTURE_SKEW_S, who))
        elif dage > limit_h:
            basis.append("digest-stale")
            alarms.append("digest: the newest digest (%s) was generated %.1fh ago (limit %dh) - the reader has"
                          " not looked at any ask since (owner %s)" % (batch, dage, limit_h, who))
        if not claims:
            basis.append("digest-empty")
            alarms.append("digest: the newest digest (%s) names no asks - a reader reading nothing is not"
                          " healthy (owner %s)" % (batch, who))
    asks = read_asks(ledger)
    untracked = sorted(cid for cid, sent in asks.items()
                       if cid not in claims and hours(now - sent) > unread_h)
    if untracked:
        basis.extend("untracked-%d" % c for c in untracked)
        sample = ", ".join("claim-%d" % c for c in untracked[:5])
        alarms.append("untracked: %d ask(s) sent more than %dh ago that the newest digest never looked at"
                      " (%s%s) - those replies are unread" % (
                          len(untracked), unread_h, sample,
                          ", ..." if len(untracked) > 5 else ""))
    skewed = sorted(cid for cid, sent in asks.items() if is_future(now - sent))
    if skewed:
        basis.extend("future-ask-%d" % c for c in skewed)
        alarms.append("future: %d ask(s) carry a sent_at in the FUTURE (skew limit %ds, %s%s) - their age cannot"
                      " be measured, so they cannot be called read" % (
                          len(skewed), FUTURE_SKEW_S, ", ".join("claim-%d" % c for c in skewed[:5]),
                          ", ..." if len(skewed) > 5 else ""))
    ok = ("reader ran %.1fh ago (limit %dh), asked %d, %d ledger ask(s), %d claim(s) in the newest digest,"
          " %d untracked (owner %s)" % (age, limit_h, asked, len(asks), len(claims), len(untracked), who))
    return alarms, ok, signature(basis)


def in_maintenance():
    """True during a planned fleet maintenance window (scripts/hydra-maintenance.sh).

    The daily code check is a fleet job: a window can pause it ON PURPOSE, and paging that the reader is stale
    while the fleet is down on purpose is the false page the maintenance flag exists to prevent
    (model-chain-watchdog's precedent). The guard can only ever SUPPRESS, and only on a positive verdict - a
    helper that is missing, unrunnable or answers anything else means "not in maintenance", so a broken guard
    can never silence the alarm.
    """
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hydra-maintenance.sh")
    try:
        return subprocess.run(
            ["bash", helper, "is-active"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False,
        ).returncode == 0
    except Exception:  # noqa: BLE001 - fail-safe: any error => not in maintenance
        return False


def main(argv=None):
    ap = argparse.ArgumentParser(description="Reader alarm for the armed claim-proof-ask family")
    ap.add_argument("--state-dir", default=DEFAULT_STATE_DIR)
    ap.add_argument("--ledger", default=DEFAULT_LEDGER)
    ap.add_argument("--limit-h", type=float, default=30.0,
                    help="staleness limit for the reader's heartbeat and its newest digest (default 30 = "
                         "claim_proof_ask.DAILY_CHECK_MAX_AGE_H)")
    ap.add_argument("--unread-h", type=float, default=24.0,
                    help="an ask older than this that the reader never looked at is an unread reply (default 24)")
    ap.add_argument("--now", default=None, help="ISO instant, for tests only")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    now = parse_utc(a.now) if a.now else datetime.now(timezone.utc)
    if now is None:
        print("cannot measure: --now %r is not a time" % a.now)
        return 2
    if in_maintenance():
        # A state line, not silence: the tick's log must show why no verdict was reached.
        print("SKIPPED maintenance window active: the daily code check may be paused on purpose this window")
        return 0
    try:
        alarms, ok, sig = evaluate(a.state_dir, a.ledger, a.limit_h, a.unread_h, now)
    except (OSError, ValueError, sqlite3.Error) as e:
        print("cannot measure: %s: %s" % (type(e).__name__, e))
        return 2
    if a.json:
        print(json.dumps({"alarms": alarms, "ok": ok, "signature": sig}, indent=1))
    else:
        for line in alarms:
            print("ALARM " + line)
        if ok:
            # On an alarm run the summary is a STATE line, not an OK line: "ALARM stale: ... 40.0h ago" followed by
            # "OK reader ran 40.0h ago" reads as a healthy verdict on a run whose rc is 1 - the reader's state, not
            # its health, is what that line reports (r5 on #1758, the same asymmetry as "quiet is not healthy").
            print(("STATE " if alarms else "OK ") + ok)
        # LAST line on purpose: the caller's repeat cooldown reads this and nothing else (the text above moves every
        # tick - it carries ages and counts - so a digest over it paged the same outage again every two hours).
        print("SIGNATURE " + sig)
    return 1 if alarms else 0


if __name__ == "__main__":
    sys.exit(main())
