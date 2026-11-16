"""Which parts of the credit-trust proof-on-file export make it authoritative.

THE one completeness rule for every Python reader of /var/lib/credit-trust/proof-on-file.json
(verify_notify: the verify notes; credit_retro.takeback: the take-back gate; decide: the
credit decider, which is stricter on top - integer user ids, and a readable gmail_contacts_90d
list, because an unreadable one makes proof status UNKNOWN). Caroline's support tool
(plugins/support-tools/src/tools/proof-on-file.ts)
implements the same contract in TypeScript; scripts/tests/fixtures/proof-parts-contract.json
pins both sides (scripts/tests/test_proof_parts_contract.py and the vitest suite). Parts, by their exact ``sources[].name`` (cs lane, firstmate 761/762/032/033),
ALL required for everyone:

  core         verifications / approved documents
  cs-intercom  proof sent in Intercom conversations
               (the exact legacy label "cs-systemic intercom+gmail" is read as this part:
               it was Intercom-only, so it never vouches for Gmail)
  cs-gmail     documents emailed to support@

A part is usable only when it is present once, not flagged ``stale``/``missing`` (any truthy
value), and carries its own timezone-aware ``generated_at`` no older than the age limit and
not dated in the future beyond the clock skew. ``core`` has no ``stale`` key at all, so
freshness is ALWAYS judged from the stamp, never from the absence of a flag. Any other part
flagged stale or missing makes the whole export UNKNOWN too.

While ``cs-gmail`` is unusable EVERYONE is UNKNOWN: a snapshot of
who emailed support@ cannot cover mail sent after it, so no contact list narrows the hold.
UNKNOWN never asks and never removes. The live export also carries ``gmail_contacts_90d``
({generated_at, source, user_ids[]}): completeness never depends on it (it narrows nothing),
read through ``support_contacts`` below, the one parser for it. The credit decider does not
hold on it any more (2026-11-14) and neither do the verify notes (2026-11-15): each requires
the list to be readable only, and the row keeps the ladder's verdict. The senders that still
hold every listed user for a human are ``claim_proof_ask`` (the live one),
``uvn_status`` (its stale Gmail part) and ``score_approve``.

A half-written export is UNKNOWN too: every entry must be an object with a user_id, a
request_id that is null or a string and a known kind, and ``users`` must be the number of
distinct user ids in entries[] (a malformed row may be the one user with proof on file, so
it is never skipped).

API::

    proof_parts.check(doc, now=now, max_age_h=3, max_skew_h=0.1)  # PartsError: UNKNOWN
    proof_parts.check_entries(doc)                                # PartsError: UNKNOWN
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Callable

CORE = "core"
INTERCOM = "cs-intercom"
GMAIL = "cs-gmail"
LEGACY_INTERCOM = "cs-systemic intercom+gmail"
KINDS = frozenset({"approved_doc", "pending_doc", "human_approved_after_doc"})
SUPPORT_CONTACTS = "gmail_contacts_90d"


def _is_intercom(name: str) -> bool:
    return name in (INTERCOM, LEGACY_INTERCOM)


REQUIRED: tuple[tuple[str, Callable[[str], bool]], ...] = (
    (CORE, lambda n: n == CORE),
    (INTERCOM, _is_intercom),
    (GMAIL, lambda n: n == GMAIL),
)


def _is_required(name: str) -> bool:
    return any(match(name) for _, match in REQUIRED)


def parse_ts(value: Any) -> datetime | None:
    """A timezone-aware ISO time, or None (a naive stamp is not a freshness proof)."""
    if not isinstance(value, str) or not value:
        return None
    try:
        ts = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return ts if ts.tzinfo else None


class PartsError(ValueError):
    """The export is not authoritative for anyone (a required part is unusable, or another
    part is flagged stale or missing)."""


def part_problem(src: Any, label: str, *, now: datetime, max_age_h: float, max_skew_h: float) -> str | None:
    """Why this part cannot be used, or None."""
    if not isinstance(src, dict):
        return f"part '{label}' is missing"
    if src.get("stale") or src.get("missing"):
        return f"part '{label}' is marked {'missing' if src.get('missing') else 'stale'}"
    ts = parse_ts(src.get("generated_at"))
    if ts is None:
        return f"part '{label}' has no readable timezone-aware generated_at"
    age_h = (now - ts).total_seconds() / 3600
    if age_h < -max_skew_h:
        return f"part '{label}' is dated {-age_h:.1f}h in the future"
    if age_h > max_age_h:
        return f"part '{label}' is {age_h:.1f}h old (limit {max_age_h:g}h)"
    return None


def check(doc: dict[str, Any], *, now: datetime, max_age_h: float, max_skew_h: float) -> None:
    """Raise PartsError unless every required part is usable and no other part is flagged."""
    sources = doc.get("sources")
    if not isinstance(sources, list) or not sources:
        raise PartsError("it has no sources[] (a half-written export is not authoritative)")
    named = [s for s in sources if isinstance(s, dict)]
    for label, match in REQUIRED:
        found = [s for s in named if match(str(s.get("name") or ""))]
        why = part_problem(found[0] if len(found) == 1 else None, label, now=now, max_age_h=max_age_h,
                           max_skew_h=max_skew_h)
        if len(found) > 1:
            why = f"part '{label}' appears {len(found)} times"
        if why:
            raise PartsError(why)
    # Any OTHER part the exporter flags stale or missing may hold someone's proof: no part of
    # the export is allowed to be quietly incomplete.
    flagged = [str(s.get("name") or "?") for s in sources
               if not isinstance(s, dict) or (not _is_required(str(s.get("name") or ""))
                                              and (s.get("stale") or s.get("missing")))]
    if flagged:
        raise PartsError(f"it has stale or missing part(s): {', '.join(flagged)}")


def check_entries(doc: dict[str, Any]) -> None:
    """Raise PartsError unless entries[] is a list of well-formed rows and ``users`` equals
    the distinct user ids in it."""
    entries = doc.get("entries")
    if not isinstance(entries, list):
        raise PartsError("it has no entries[]")
    uids: set[str] = set()
    for i, e in enumerate(entries):
        uid = e.get("user_id") if isinstance(e, dict) else None
        rid = e.get("request_id") if isinstance(e, dict) else None
        if (isinstance(uid, bool) or not isinstance(uid, (int, str)) or not str(uid).strip()
                or not (rid is None or isinstance(rid, str)) or not isinstance(e.get("kind"), str)
                or e["kind"] not in KINDS):
            raise PartsError(f"it has a malformed entries[{i}] (needs user_id, request_id|null and a known kind)")
        uids.add(str(uid).strip())
    users = doc.get("users")
    if not isinstance(users, int) or isinstance(users, bool) or users != len(uids):
        raise PartsError(f"it is inconsistent (users={users!r}, {len(uids)} distinct user ids in entries[]): "
                         "treated as a half-written export")


def support_contacts(doc: dict[str, Any], *, now: datetime, max_age_h: float,
                     max_skew_h: float) -> frozenset[int] | None:
    """User ids that emailed support@ in the last 90 days, from ``gmail_contacts_90d``
    ({generated_at, source, user_ids: [...]} as the cs lane publishes it). None - a sender then
    sends to nobody (anyone may have emailed support@) - when it is absent, malformed, a bare
    list with no stamp, or its OWN generated_at is unreadable, stale or in the future: the
    export and its parts can be current while this embedded snapshot is not (QA review of
    hydra#1257 @53428d0), and a user who wrote since the snapshot would be missing from it."""
    value = doc.get(SUPPORT_CONTACTS)
    if not isinstance(value, dict) or part_problem(value, SUPPORT_CONTACTS, now=now, max_age_h=max_age_h,
                                                   max_skew_h=max_skew_h):
        return None
    ids = value.get("user_ids")
    if not isinstance(ids, list):
        return None
    out: set[int] = set()
    for u in ids:
        text = "" if isinstance(u, bool) else str(u).strip()
        if not text.isdigit():
            return None
        out.add(int(text))
    return frozenset(out)
