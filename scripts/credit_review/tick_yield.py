#!/usr/bin/env python3
"""What each family's walk bought this tick, read from the tick's own check files.

Run by `credit-verify-outbound.sh` at the end of every tick (`tick_yield` there). It reads the
`<family>-<segment>-check.json` files the tick just wrote, and nothing else: no ledger, no replica, no Intercom.

Why it exists. On 2026-11-13 the tick walked 2,299 free and 953 paid uvn-status users and accepted 1 and 0. The
cause (1,685 of 2,732 gate calls answered by one rule) was in the tick's own check files the whole time, and was
found only because somebody ran a census over them by hand (`data/rapid-verif-final-h3/tools/tick_census.py`). On
2026-11-15 the same shape was back on other families (r1 paid and free: 120 to 174 gate calls a tick, 0 accepted,
most of them `r1_receipted_in_thread`; uvn-status paid: 43 to 82 calls, 0 accepted) and nothing said so. A family
that is never reached has a page (`not_reached`). A family that is reached, spends the tick's time on gate calls
and sends nobody had none. This is that page.

The rule, per `<family>-<segment>`:

  spent     this tick the check made at least MIN_CALLS gate calls and accepted at most 1 in 100 of them
  page      on the STREAK_TO_PAGE-th consecutive spent tick, and again every REPAGE_EVERY spent ticks after that
  clear     a tick that accepted more than 1 in 100 ends the streak
  neither   a walk shorter than MIN_CALLS that accepted nobody (a cut page, a short list) says nothing either
            way: the streak stands, and is dropped after IDLE_TO_DROP such ticks in a row

A gate call is an outcome row that reached the gate, plus every accepted user. `run_size`, `daily_cap` and
`apply_budget` rows are users the walk stopped before, so they are not gate calls.

Three things it will not do:

  - A tick that did not reach a family, or wrote a check file this cannot read, neither extends nor ends the
    streak. Not measured is not "fine" and not "spent"; an unreadable file is named in the tick log.
  - It never marks a page as sent. `record` says a page is owed; only `paged`, which the tick runs after Slack
    confirmed the post, starts the repeat window. An undelivered page is owed again next tick.
  - It holds no user: the state file carries counts and reason codes only.

It decides nothing about a send and changes no list, cap or gate. What to do about a spent family is in the page:
the users the gate turns away every tick belong out of the list at build time (as `[key=class-c-precheck]` did for
class C), or the rule that holds them is armed on purpose.

  tick_yield.py record --out <tick dir> --state <file>     one tick; prints log lines, and `PAGE: <text>` if owed
  tick_yield.py paged  --state <file>                      the owed page was delivered
  tick_yield.py report [--state <file>]                    the standing streaks, for a person
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
import tempfile

MIN_CALLS = 40         # a walk shorter than this costs under ~3 minutes of a tick (about 4 s a gate call)
MAX_ACCEPT_PCT = 1     # 1 accepted of 249 gate calls (2026-11-13 10:00Z, uvn-status free) is still a spent walk
STREAK_TO_PAGE = 3     # one empty walk is a quiet hour; three in a row is a list the gate keeps turning away
REPAGE_EVERY = 24      # spent ticks between repeats of the same page (about a day of hourly ticks)
IDLE_TO_DROP = 24      # short empty walks in a row after which a standing streak is forgotten
VERSION = 1
STATE = "/var/lib/hydra/credit-verify-outbound/tick-yield.json"   # the tick passes its own $STATE path

# rows for users the walk stopped BEFORE the gate (the runner's own cap / budget stops)
NOT_A_GATE_CALL = frozenset({"run_size", "daily_cap", "apply_budget"})
_VERDICT_WORD = frozenset({"DEFERRED", "HELD", "REFUSED", "SKIPPED", "UNMEASURED"})
# a reason code is snake_case with at least one underscore (comm_state, r1_receipted_in_thread) or a numbered
# gate rule (G2, G5); anything else ("the", "credits", "rc", "POST") is prose and is counted as `other`
_CODE = re.compile(r"^(?:[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)+|[A-Z][0-9]{1,3})$")
_SUFFIX = "-check.json"


def code_of(reason: object, result: object = "") -> str:
    """The reason CODE of one outcome row: the gate's or the runner's own word for why, never the sentence."""
    words = str(reason or "").split()
    while words and words[0] in _VERDICT_WORD:
        words = words[1:]
    head = re.split(r"[:=(]", words[0], maxsplit=1)[0] if words else ""
    if _CODE.match(head):
        return head
    res = str(result or "")
    return res if not words and _CODE.match(res) else "other"


class Unreadable(Exception):
    """A check file this cannot measure. Never read as an empty walk."""


def measure(path: str) -> dict:
    """One check file -> {gate_calls, accepted, codes}. Raises Unreadable; an unreadable file is not zero."""
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        raise Unreadable(type(exc).__name__) from exc
    if not isinstance(doc, dict) or not isinstance(doc.get("outcomes"), list):
        raise Unreadable("no outcomes list")
    acc = doc.get("accepted")
    if isinstance(acc, list):
        accepted = len(acc)
    elif acc is None:
        accepted = 0           # a runner that accepted nobody writes no accepted set
    else:
        raise Unreadable("accepted is not a list")
    codes: dict[str, int] = {}
    for row in doc["outcomes"]:
        if not isinstance(row, dict):
            raise Unreadable("an outcome row is not an object")
        code = code_of(row.get("reason"), row.get("result"))
        if code in NOT_A_GATE_CALL:
            continue
        codes[code] = codes.get(code, 0) + 1
    return {"gate_calls": sum(codes.values()) + accepted, "accepted": accepted, "codes": codes}


def sends(m: dict) -> bool:
    """More than MAX_ACCEPT_PCT in 100 gate calls were accepted: the walk bought something."""
    return m["accepted"] * 100 > m["gate_calls"] * MAX_ACCEPT_PCT


def spent(m: dict) -> bool:
    return m["gate_calls"] >= MIN_CALLS and not sends(m)


def load_state(path: str) -> tuple[dict, str]:
    """(state, why-it-restarted). A missing file is a first run; an unreadable one restarts the streaks and says so
    (that delays a page by STREAK_TO_PAGE ticks, it never silences one)."""
    empty = {"v": VERSION, "segments": {}, "owed": []}
    if not os.path.exists(path):
        return empty, ""
    try:
        with open(path, encoding="utf-8") as fh:
            st = json.load(fh)
        if not (isinstance(st, dict) and st.get("v") == VERSION and isinstance(st.get("segments"), dict)
                and isinstance(st.get("owed"), list)):
            raise ValueError("shape")
        for seg in st["segments"].values():
            if not (isinstance(seg, dict) and all(isinstance(seg.get(k), int) for k in
                                                  ("streak", "gate_calls", "accepted", "paged_at", "idle"))
                    and isinstance(seg.get("codes"), dict)):
                raise ValueError("segment shape")
        return st, ""
    except (OSError, ValueError) as exc:
        return empty, f"the state file could not be read ({type(exc).__name__}); streaks restart"


def save_state(path: str, state: dict) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tick-yield.", dir=os.path.dirname(os.path.abspath(path)))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, sort_keys=True)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _top(codes: dict) -> tuple[str, int]:
    return max(sorted(codes.items()), key=lambda kv: kv[1]) if codes else ("", 0)


def _line(tag: str, seg: dict) -> str:
    code, n = _top(seg["codes"])
    answers = sum(seg["codes"].values())
    share = f", {round(100 * n / answers)}% {code}" if answers else ""
    return (f"{tag} {seg['streak']} ticks, {seg['gate_calls']} gate calls, "
            f"{seg['accepted']} accepted{share}")


def record(out_dir: str, state_path: str) -> dict:
    """Count one tick. Returns {lines, page}; `page` is the text owed to a person, or ''."""
    state, restarted = load_state(state_path)
    segs = state["segments"]
    lines = [f"tick yield: {restarted}"] if restarted else []
    measured, unreadable, spent_now = 0, [], []
    for path in sorted(glob.glob(os.path.join(out_dir, "*" + _SUFFIX))):
        tag = os.path.basename(path)[:-len(_SUFFIX)]
        try:
            m = measure(path)
        except Unreadable as exc:
            unreadable.append(f"{tag} ({exc})")
            continue                      # not measured: the streak neither grows nor ends
        measured += 1
        if sends(m):
            segs.pop(tag, None)
            continue
        if not spent(m):                  # a short walk that sent nobody: no evidence either way
            if tag in segs:
                segs[tag]["idle"] += 1
                if segs[tag]["idle"] >= IDLE_TO_DROP:
                    del segs[tag]
            continue
        seg = segs.setdefault(tag, {"streak": 0, "gate_calls": 0, "accepted": 0, "codes": {}, "paged_at": 0,
                                    "idle": 0})
        seg["streak"] += 1
        seg["idle"] = 0
        seg["gate_calls"] += m["gate_calls"]
        seg["accepted"] += m["accepted"]
        for code, n in m["codes"].items():
            seg["codes"][code] = seg["codes"].get(code, 0) + n
        spent_now.append(tag)
    owed = [t for t in spent_now if segs[t]["streak"] >= STREAK_TO_PAGE
            and (segs[t]["paged_at"] == 0 or segs[t]["streak"] - segs[t]["paged_at"] >= REPAGE_EVERY)]
    state["owed"] = owed
    save_state(state_path, state)
    lines.append(f"tick yield: {measured} check(s) measured, {len(spent_now)} spent"
                 + (": " + "; ".join(_line(t, segs[t]) for t in spent_now) if spent_now else ""))
    if unreadable:
        lines.append("tick yield UNMEASURED for " + ", ".join(unreadable)
                     + " (the check file could not be read; its streak is unchanged)")
    page = ""
    if owed:
        page = (f"outbound tick: {len(owed)} segment(s) keep spending the tick on gate calls and sending nobody "
                f"({STREAK_TO_PAGE}+ ticks in a row, {MIN_CALLS}+ gate calls, at most {MAX_ACCEPT_PCT} in 100 "
                "accepted): " + "; ".join(_line(t, segs[t]) for t in owed)
                + ". The gate turns the same users away every tick: drop them at list build, or arm the rule that "
                "holds them. Standing streaks: python3 /opt/hydra/scripts/credit_review/tick_yield.py report")
    return {"lines": lines, "page": page}


def paged(state_path: str) -> int:
    """The owed page was DELIVERED: start its repeat window. Returns how many segments it covered."""
    state, _ = load_state(state_path)
    n = 0
    for tag in state["owed"]:
        seg = state["segments"].get(tag)
        if seg:
            seg["paged_at"] = seg["streak"]
            n += 1
    state["owed"] = []
    save_state(state_path, state)
    return n


def report(state_path: str) -> list[str]:
    state, restarted = load_state(state_path)
    if restarted:
        return [restarted]
    if not os.path.exists(state_path):
        return ["no tick has been counted yet (no state file)"]
    segs = state["segments"]
    if not segs:
        return ["no family is on a spent streak"]
    return [_line(t, segs[t]) + (f" (paged at tick {segs[t]['paged_at']})" if segs[t]["paged_at"] else " (not paged)")
            for t in sorted(segs)]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("mode", choices=("record", "paged", "report"))
    ap.add_argument("--out", help="the tick's run directory (record)")
    ap.add_argument("--state", default=STATE)
    a = ap.parse_args(argv)
    if a.mode == "record":
        if not a.out or not os.path.isdir(a.out):
            print(f"tick yield UNMEASURED: no tick directory at {a.out!r}")
            return 2
        res = record(a.out, a.state)
        for line in res["lines"]:
            print(line)
        if res["page"]:
            print("PAGE: " + res["page"])
        return 0
    if a.mode == "paged":
        print(f"tick yield: page delivered for {paged(a.state)} segment(s)")
        return 0
    for line in report(a.state):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
