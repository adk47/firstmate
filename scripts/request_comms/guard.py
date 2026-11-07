#!/usr/bin/env python3
"""Who must receive NOTHING, whatever their request state says.

The ban set is read from the three places that already own the answer — this module is the one
reader, so a status driver cannot invent a fourth opinion:

  policies/fraud-lens-holds.json     messaging-only holds (the account we must not acknowledge)
  policies/credit-trust-decide.json  the decider's `deny_user_ids`
  the fraud lens's account-hold ledger + its current scan
                                     (`credit_review.comm_state.held_user_ids`, 72 h freshness,
                                     release rows confirmed against the live scan)

Fail-closed, in two steps. A hold file that is missing or unreadable is an ERROR for the whole
run (an absent ban list is not "nobody is banned"); and a lens ledger that cannot be read puts
every user in the banned set for this tick. Neither case is ever reported as a clean run.
"""
from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from datetime import date

POLICIES = "/opt/hydra/policies"


class BansUnreadable(RuntimeError):
    pass


@dataclass
class Bans:
    ids: set[str] = field(default_factory=set)
    sources: dict[str, int] = field(default_factory=dict)
    lens_unknown: str = ""            # non-empty: the lens could not be read -> everything is held

    def held(self, user_id: str) -> str:
        """'' when the user may be messaged; the reason otherwise."""
        if self.lens_unknown:
            return f"fraud_lens_unreadable:{self.lens_unknown}"
        uid = str(user_id or "").strip()
        return "messaging_ban" if uid and uid in self.ids else ""


def _read_json(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        raise BansUnreadable(f"{os.path.basename(path)}: {exc}") from exc
    if not isinstance(doc, dict):
        raise BansUnreadable(f"{os.path.basename(path)}: not a JSON object")
    return doc


def _required_list(doc: dict, key: str, name: str) -> list:
    """The key must be PRESENT and a list. An absent key is not "nobody banned".

    `doc.get(key) or []` reads a file that lost its key as an empty ban set — the tick then
    messages the very accounts that list exists to silence, and reports a clean run.
    """
    if key not in doc:
        raise BansUnreadable(f"{name}: no {key!r} key — cannot tell an empty list from a lost one")
    got = doc[key]
    if not isinstance(got, list):
        raise BansUnreadable(f"{name}: {key!r} is {type(got).__name__}, not a list")
    return got


def _required_ids(doc: dict, key: str, name: str) -> set[str]:
    """The key must be a list of account ids. A bare string is iterated PER CHARACTER.

    `{'user_ids': '12345'}` once produced the ban set {'1','2','3','4','5'} — five accounts nobody
    has ever heard of — while the account 12345 the list was written for stayed off the ban set and
    got messaged. A malformed ban list is a refusal, never a best guess.
    """
    out: set[str] = set()
    for u in _required_list(doc, key, name):
        s = str(u).strip()
        if not s.isdigit():
            raise BansUnreadable(f"{name}: {key!r} carries {u!r}, which is not an account id")
        out.add(s)
    return out


def policy_bans(policies_dir: str = POLICIES, *, today: date | None = None) -> set[str]:
    """The two policy files. An entry whose `review_by` day has passed no longer applies."""
    today = today or date.today()
    out: set[str] = set()
    holds = _read_json(os.path.join(policies_dir, "fraud-lens-holds.json"))
    for entry in _required_list(holds, "entries", "fraud-lens-holds.json"):
        if not isinstance(entry, dict):
            raise BansUnreadable("fraud-lens-holds.json: entry is not an object")
        review_by = str(entry.get("review_by") or "").strip()
        if review_by:
            try:
                if date.fromisoformat(review_by) < today:
                    continue
            except ValueError as exc:
                raise BansUnreadable(f"fraud-lens-holds.json: unreadable review_by {review_by!r}") from exc
        out |= _required_ids(entry, "user_ids", "fraud-lens-holds.json")
    decide = _read_json(os.path.join(policies_dir, "credit-trust-decide.json"))
    out |= _required_ids(decide, "deny_user_ids", "credit-trust-decide.json")
    return out


def lens_bans(now: float | None = None) -> set[str]:
    """The fraud lens's account holds, through its one reader. Unimportable/unreadable RAISES."""
    import sys
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    from credit_review import comm_state  # noqa: PLC0415  (read at tick time, like every other gate)

    try:
        return {str(u) for u in comm_state.held_user_ids(now=now or time.time())}
    except comm_state.Unknown as exc:
        raise BansUnreadable(f"fraud lens: {exc}") from exc


def load(policies_dir: str = POLICIES, *, now: float | None = None, lens: bool = True) -> Bans:
    """The whole ban set. Raises BansUnreadable only for the POLICY files (a hard error)."""
    ids = policy_bans(policies_dir)
    bans = Bans(ids=ids, sources={"policy": len(ids)})
    if lens:
        try:
            got = lens_bans(now)
        except BansUnreadable as exc:
            bans.lens_unknown = str(exc)[:200]
        else:
            bans.sources["lens"] = len(got)
            bans.ids |= got
    return bans
