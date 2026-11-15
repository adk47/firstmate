"""Pre-send owed-follow-up records, read back against what the monitor derived.

`plugins/intercom/src/outbound.ts` writes one `owed_followup` row into the shared safety ledger
(`scripts/lib/injection_watch.py`'s file) BEFORE it posts a sentence that says the case was
recorded (answer-bank.ts `HONEST_FALLBACK`). The row exists before the send, so it can never be
derived from the thread the way `commitments.py` derives a commitment: it is read here instead.

Two numbers, and both can be UNKNOWN. An unreadable ledger is None, never 0 - "we could not look"
must never read as "nothing happened", the rule the monitor applies everywhere else.

`owed_followup_unbacked` counts records with a known thread and no commitment row on that
conversation at or after the record time: the customer was told we recorded it and no thread event
owed anything back. A record whose conversation is not among the threads read is UNMEASURED
(`owed_followup_unmeasured`), never unbacked and never backed: the monitor's window is by
`created_at`, so an older thread that receives the fallback today is simply not in the facts.
The reverse direction (a commitment with no pre-send record) is not built.

The comparison is at whole-second granularity. The plugin writes a millisecond ISO timestamp
(`new Date().toISOString()`) immediately before the POST, while the monitor truncates thread
event timestamps to whole seconds (`rules.read_events`), so a record and the send it precedes
land in the same second and would otherwise read as its own absence.

A record whose POST then failed is cancelled by an `owed_followup_not_sent` row the plugin writes
for that same conversation and record timestamp: the customer was never told anything, so it is
left out of every count here. A second, delivered reply in the same conversation keeps its own
record.
"""
import os
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib"))

import injection_watch  # noqa: E402

from . import commitments  # noqa: E402

KIND = "owed_followup"
NOT_SENT_KIND = "owed_followup_not_sent"


def _epoch(value):
    if isinstance(value, (int, float)):
        return float(value)
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def summarize(facts, ledger=None, now=None, hours=24):
    """{"owed_followup_24h", "owed_followup_unbacked", "owed_followup_unmeasured", "owed_followup_error"}.

    `facts` are the monitor's thread facts (the same list `backlog.build` iterates). `unbacked` is
    None when no thread was read: a record that cannot be checked against a thread is unmeasured,
    never a pass, and the total is reported either way.
    """
    now = datetime.now(timezone.utc) if now is None else now
    if isinstance(now, (int, float)):
        now = datetime.fromtimestamp(now, timezone.utc)
    path = ledger if ledger is not None else injection_watch.LEDGER_PATH
    try:
        rows = injection_watch.dedupe(
            injection_watch.read_ledger(path, since=now - timedelta(hours=hours)))
    except OSError as exc:
        return {"owed_followup_24h": None, "owed_followup_unbacked": None,
                "owed_followup_unmeasured": None,
                "owed_followup_error": f"{type(exc).__name__}: {exc}"}
    records = [r for r in rows if r.get("kind") == KIND]
    cancelled = {(r.get("source"), str(r.get("ref")), r.get("record_ts"))
                 for r in rows if r.get("kind") == NOT_SENT_KIND}
    records = [r for r in records
               if (r.get("source"), str(r.get("ref")), r.get("ts")) not in cancelled]
    promised = {}
    for f in facts or ():
        promised[str(f.get("id"))] = [int(ts) for ts, code in f.get("events", ())
                                      if code in commitments._PROMISES]
    unbacked = 0 if promised else None
    unmeasured = 0
    for r in records:
        at = _epoch(r.get("ts"))
        later = promised.get(str(r.get("ref")))
        if later is None:
            unmeasured += 1
            continue
        if at is None or not any(t >= int(at) for t in later):
            unbacked += 1
    return {"owed_followup_24h": len(records), "owed_followup_unbacked": unbacked,
            "owed_followup_unmeasured": unmeasured, "owed_followup_error": None}
