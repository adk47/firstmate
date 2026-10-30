"""The ONE loader for the hand-read captain-list overrides (captain-overrides.json, next to
this file). lists.py (captain and hold lists) and send.py (eligible()) both route every
triage row through apply(), so a hand-read move can never exist in one place and not the
other (Fable review of hydra#1379 @4a57414d).

  add    {id: topic}   -> action "captain-<topic>": the captain's list, never sent by this lane
  remove {id: reason}  -> action "hold-read": a keyword misfire off the captain's list that a
                          person must read before any reply; held, never send-eligible

Fails CLOSED: a missing, unreadable or malformed file, or one without BOTH maps, raises OverridesError, and every caller
stops (send.py refuses the run; lists.py exits non-zero). An id in both maps is malformed.
"""
import json
import os
import re

DEFAULT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "captain-overrides.json")
TOPICS = ("legal", "billing", "privacy")
HOLD_READ = "hold-read"
_ID = re.compile(r"^[0-9]{3,20}$")


class OverridesError(Exception):
    pass


def load(path=DEFAULT_PATH):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise OverridesError(f"cannot read captain overrides {path}: {e}") from e
    if not isinstance(data, dict):
        raise OverridesError("captain overrides must be a JSON object")
    missing = [k for k in ("add", "remove") if k not in data]
    if missing:
        # QA: a truncated or regenerated file without a map must never load it as empty (a lost 'add' would
        # drop a captain/privacy case from the list and make it send-eligible).
        raise OverridesError(f"captain overrides lack {missing} (both 'add' and 'remove' are required, even if empty)")
    add, remove = data["add"], data["remove"]
    if not isinstance(add, dict) or not isinstance(remove, dict):
        raise OverridesError("'add' and 'remove' must be objects keyed by conversation id")
    bad = [k for k in list(add) + list(remove) if not _ID.match(str(k))]
    if bad:
        raise OverridesError(f"override keys must be numeric conversation ids: {bad}")
    wrong = {k: v for k, v in add.items() if v not in TOPICS}
    if wrong:
        raise OverridesError(f"'add' topics must be one of {TOPICS}: {wrong}")
    both = sorted(set(add) & set(remove))
    if both:
        raise OverridesError(f"ids in both 'add' and 'remove': {both}")
    return {"add": dict(add), "remove": dict(remove)}


def apply(rows, ov):
    """Return copies of the triage rows with the overrides applied to 'action'. The original
    keyword action is kept as 'triage_action' so a list can show what was overridden."""
    out = []
    for r in rows:
        r = dict(r)
        cid = str(r.get("id"))
        if cid in ov["add"]:
            r["triage_action"], r["action"] = r.get("action"), "captain-" + ov["add"][cid]
        elif cid in ov["remove"]:
            r["triage_action"], r["action"] = r.get("action"), HOLD_READ
        out.append(r)
    return out
