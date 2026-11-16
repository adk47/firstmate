#!/usr/bin/env python3
"""The stage-2 gap split: which `need_more` classes may be asked, and with which approved copy.

Stage 2 records a `need_more` verdict per (request, role) and names the concrete gap in the row's
`reason` (`credit_verify/proof/stage2.py:gap_reason`). That prose is the only record of WHICH gap
it found, so this module reads it back into a class code and decides, per class, whether an
approved message exists today.

The split is not a preference. It is the reviewer's ruling of 2026-11-16 on the two messages the
rubric admits, and it is narrower than the first draft of that ruling, because the second verdict
withdrew the class 2 half of it:

  document ask   `policies/outbound-copy-rubric.md` "The document ask" - four parts, word for
                 word. Its opening says "on its own it isn't something we can check against an
                 outside source", which is TRUE only of a file we could not read. For every other
                 class stage 2 DID check the document and found a specific gap, so the sentence
                 would be a false statement about the person's document.
  class 2        the same rubric, "Class 2: proof-insufficiency outcomes". WITHDRAWN for this
                 population: class 2 is the message for a request that has been DECIDED, and every
                 row here is still pending. "{title} was not verified" reads as a decided outcome
                 and "Without it, the result stands" asserts a result that does not exist, so the
                 message would tell the person their request was decided when it was not (rule 7).
                 The rubric says it directly: "A request for a document, sent before anything is
                 decided, is neither class."

So exactly ONE class is admissible: `unreadable`, which goes to the document ask with need line (c)
and `{document}` reading "the file you sent on ..." (we cannot know its kind). Every other class is
HELD, and the reason is the same for all of them: the document ask is the right KIND of message for
a pending request, but its opening is only true of a file we could not read, and no admitted message
is true of a document that was read and does not cover the claim. A held class is counted and never
sent - an unmeasured or unapproved class is not a pass.

This module records a ROUTING DECISION and nothing consumes it yet: no cron is enabled, no sender
imports it, and nothing is armed to send. The admissible class is not reachable yet either, and
that is a statement about the data: the send gate needs a `proof_intake` row for the document AND a
doc-verify read of it recorded in `dv_outcomes`, and neither exists for these documents today.

Nothing here sends, renders or approves anything. It reads the store and answers two questions:
what the split is (`counts`), and which request ids a class may reach (`audience`).

`audience` is a CLASS POPULATION, not a send count: a sender that does consume these rows runs its
own gates first (a `proof_intake` row naming the conversation for that document, the request still
pending in core, the never-ask bands, the 180-day stale-filing wait, the 90-day shared ask lock, one
need per user), so how many people a class actually reaches is that sender's own check-recipients
answer, never this file.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from credit_review import stage2_verdicts  # noqa: E402

# The class codes. One per branch of `gap_reason`, in that function's own order.
UNREADABLE = "unreadable"
ISRC_OTHER_RECORDING = "isrc_other_recording"
NOT_NAMED = "not_named"
ROLE_NOT_LISTED = "role_not_listed"
ROLE_NOT_EXPRESSIBLE = "role_not_expressible"
SHARES_DO_NOT_ADD_UP = "shares_do_not_add_up"
CLAIM_TEXT_NOT_RENDERED = "claim_text_not_rendered"
CANNOT_CONFIRM = "cannot_confirm"
COVERS_OTHER_TRACKS = "covers_other_tracks"
TRACK_NOT_NAMED = "track_not_named"
UNCLASSIFIED = "unclassified"
MIXED = "mixed"

# The fixed grammar of `gap_reason`, one anchored pattern per branch, in that function's own
# order. `test_stage2_gap.py` runs every branch and fails if one is not recovered here, so a new
# branch in `gap_reason` cannot silently land in `unclassified` (which is held, never sent).
#
# ANCHORED, and the variable slots are explicit, because the reason is prose with the request's
# own track title interpolated into it. A substring search over the whole string let a title
# decide the class: a track called `“A could not be read (file type or size); for B”` made a
# held `track_not_named` row read as the armed `unreadable` class, and a sender would then have
# opened with "we could not read your file" about a file we read (QA finding on #2088).
#
# `_DOC` is the prefix `_doc()` builds - the document's KIND and its Intercom ref, never its
# content and never anything the customer typed. `_TITLE` is the one customer-controlled slot:
# a curly-quoted title, or the literal `this track` when the request has no title. A title that
# cannot be read as one quoted token (it contains `”`) matches no branch and is `unclassified`,
# which is held - the failure direction is "never sent", never "sent with the wrong words".
_DOC = r"The [A-Za-z][A-Za-z -]*? you sent(?: \(Intercom conversation …[^)]*\))?"
_TITLE = r"(?:“[^”]*”|this track)"

GRAMMAR: tuple[tuple[re.Pattern[str], str], ...] = (
    # `covers {shown}, not {title}; for ...` - the only branch with a ", not " clause.
    (re.compile(rf"^{_DOC} covers (?:{_TITLE}(?: and {_TITLE})*), not {_TITLE}; for "), COVERS_OTHER_TRACKS),
    (re.compile(rf"^{_DOC} could not be read \(file type or size\); for "), UNREADABLE),
    (re.compile(rf"^{_DOC} carries the ISRC of a different recording than "), ISRC_OTHER_RECORDING),
    (re.compile(rf"^{_DOC} names {_TITLE} but does not show your name; we need a document for "), NOT_NAMED),
    (re.compile(rf"^{_DOC} names {_TITLE} but not the role you claimed \("), ROLE_NOT_LISTED),
    (re.compile(rf"^{_DOC} names {_TITLE} but can't show the role you claimed \("), ROLE_NOT_EXPRESSIBLE),
    (re.compile(rf"^{_DOC} names {_TITLE} but its split shares do not add up to 100%; "), SHARES_DO_NOT_ADD_UP),
    (re.compile(rf"^{_DOC} names {_TITLE} only in text the rendered page does not show; "), CLAIM_TEXT_NOT_RENDERED),
    (re.compile(rf"^{_DOC} names {_TITLE} but cannot on its own confirm your "), CANNOT_CONFIRM),
    (re.compile(rf"^{_DOC} does not name {_TITLE} or its ISRC; for "), TRACK_NOT_NAMED),
)


def classify(reason: str) -> str:
    """The gap class of one `need_more` row's `reason`, or `unclassified` when it is not
    `gap_reason` prose (rows written before #1297 carry the analyzer's own reason text).

    Matched against the fixed grammar from the start of the string, so the interpolated track
    title can never select a class: it is only ever read as the `_TITLE` slot."""
    text = str(reason or "")
    for pattern, code in GRAMMAR:
        if pattern.match(text):
            return code
    return UNCLASSIFIED


@dataclass(frozen=True)
class Route:
    """Where a class goes. `campaign` is the sender that owns the copy; `copy` is the renderer key
    in `scripts/intercom-verify-request.sh`'s RENDER_JQ."""

    campaign: str
    copy: str


DOCUMENT_ASK = Route(campaign="proof-need-ask", copy="proofneed")

# class -> route, or None for HELD. A class absent from this table is held: the table is the
# allowlist, so a new class cannot be sent by being forgotten.
ROUTES: dict[str, Route | None] = {
    # the file could not be read: the document ask, need line (c), {document} = "the file you sent on ...".
    # The only class whose opening sentence is true, and the only one with a route.
    UNREADABLE: DOCUMENT_ASK,
    # HELD: the document was read and does not name the person as {role} on {title}. The document ask
    # is the right kind of message for a pending request, but its opening is false here (we DID check
    # it), and class 2 is withdrawn for a pending request.
    NOT_NAMED: None,
    TRACK_NOT_NAMED: None,
    COVERS_OTHER_TRACKS: None,
    # HELD: the rubric approves no wording for "another role" until its pair is listed
    ROLE_NOT_LISTED: None,
    ROLE_NOT_EXPRESSIBLE: None,
    # HELD: no approved true wording, and any explanation risks rules 1 and 2
    SHARES_DO_NOT_ADD_UP: None,
    CLAIM_TEXT_NOT_RENDERED: None,
    ISRC_OTHER_RECORDING: None,
    # HELD: not one of the nine gaps the reviewer ruled on
    CANNOT_CONFIRM: None,
    # HELD: unmeasured is not a pass
    UNCLASSIFIED: None,
    MIXED: None,
}

ARMED = tuple(sorted(c for c, r in ROUTES.items() if r is not None))
HELD = tuple(sorted(c for c, r in ROUTES.items() if r is None))


def request_class(roles: dict[str, stage2_verdicts.Verdict]) -> str:
    """One class per request: the class every role agrees on, else `mixed` (held)."""
    classes = {classify(v.reason) for v in roles.values()}
    return classes.pop() if len(classes) == 1 else MIXED


def split(verdicts: dict[str, dict[str, stage2_verdicts.Verdict]],
          released: Iterable[str]) -> dict[str, dict[str, Any]]:
    """{class: {requests, users, paid_requests, paid_users}} over the released request ids.

    `users` counts a person once per class they have a request in, so the per-class user counts
    overlap and do not sum to the population. `paid_*` is the same count restricted to requests
    whose stage-2 row says the account pays. Every class in ROUTES is present even with nothing
    released, so a first run prints the whole table rather than an empty one."""
    out: dict[str, dict[str, Any]] = {code: {"requests": 0, "users": 0, "paid_requests": 0, "paid_users": 0}
                                      for code in ROUTES}
    seen: dict[str, set[int]] = {}
    paid_seen: dict[str, set[int]] = {}
    for rid in sorted(released):
        roles = verdicts.get(rid)
        if not roles:
            continue
        code = request_class(roles)
        row = out.setdefault(code, {"requests": 0, "users": 0, "paid_requests": 0, "paid_users": 0})
        row["requests"] += 1
        uid = next(iter(roles.values())).user_id
        if uid is None:
            continue
        seen.setdefault(code, set()).add(int(uid))
        if any(v.paid == 1 for v in roles.values()):
            row["paid_requests"] += 1
            paid_seen.setdefault(code, set()).add(int(uid))
    for code, row in out.items():
        row["users"] = len(seen.get(code, ()))
        row["paid_users"] = len(paid_seen.get(code, ()))
        route = ROUTES.get(code)
        row["route"] = "held" if route is None else route.campaign
        row["copy"] = "" if route is None else route.copy
    return out


def audience(verdicts: dict[str, dict[str, stage2_verdicts.Verdict]], released: Iterable[str],
             classes: Iterable[str]) -> list[dict[str, Any]]:
    """The users a set of classes may reach, in the uvn_status list shape, paid first. A user is
    listed only with the request ids whose class is in `classes`; a request in a held class is
    never carried along by a sibling that is armed."""
    want = set(classes)
    users: dict[int, dict[str, Any]] = {}
    for rid in sorted(released):
        roles = verdicts.get(rid)
        if not roles or request_class(roles) not in want:
            continue
        v = next(iter(roles.values()))
        if v.user_id is None:
            continue
        u = users.setdefault(int(v.user_id), {"user_id": int(v.user_id), "paid": False, "skip": None,
                                              "request_ids": []})
        u["paid"] = u["paid"] or any(x.paid == 1 for x in roles.values())
        u["request_ids"].append(rid)
    return sorted(users.values(), key=lambda u: (not u["paid"], u["user_id"]))


def counts(path: str | None = None, version: str | None = None) -> dict[str, Any]:
    """The split over the live store, plus the totals it is a split of."""
    verdicts = stage2_verdicts.load(path, version=version)
    released = stage2_verdicts.released(verdicts, stage2_verdicts.GAP)
    rows = split(verdicts, released)
    armed = {c: rows[c] for c in rows if ROUTES.get(c) is not None}
    held = {c: rows[c] for c in rows if ROUTES.get(c) is None}
    return {
        "released_requests": len(released),
        "released_users": len({int(next(iter(verdicts[r].values())).user_id) for r in released
                               if next(iter(verdicts[r].values())).user_id is not None}),
        "classes": dict(sorted(rows.items(), key=lambda kv: -kv[1]["requests"])),
        "armed": {"classes": sorted(armed), "requests": sum(r["requests"] for r in armed.values()),
                  "users": len({u for c in armed for u in _users_of(verdicts, released, c)})},
        "held": {"classes": sorted(held), "requests": sum(r["requests"] for r in held.values()),
                 "users": len({u for c in held for u in _users_of(verdicts, released, c)})},
    }


def _users_of(verdicts: dict[str, dict[str, stage2_verdicts.Verdict]], released: Iterable[str],
              code: str) -> set[int]:
    out: set[int] = set()
    for rid in released:
        roles = verdicts.get(rid)
        if roles and request_class(roles) == code:
            uid = next(iter(roles.values())).user_id
            if uid is not None:
                out.add(int(uid))
    return out


def _write_private(path: str, text: str) -> None:
    """Write `path` at 0600 through a temp file in the same directory, then rename it over the
    target, so a reader never sees a half-written list and the mode is never the umask's."""
    target = os.path.abspath(path)
    fd, tmp = tempfile.mkstemp(prefix=".stage2-gap-", dir=os.path.dirname(target) or ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, target)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def _main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="the stage-2 gap split (read-only, JSON on stdout)")
    p.add_argument("--db", default=None, help="the proof store (default: stage2_verdicts.PROOF_DB)")
    sub = p.add_subparsers(dest="op", required=True)
    c = sub.add_parser("counts", help="the split per class, with the armed and held totals")
    c.add_argument("--out", default="")
    a = sub.add_parser("audience", help="the users a set of classes may reach")
    a.add_argument("--classes", required=True, help="comma-separated class codes")
    a.add_argument("--out", default="")
    args = p.parse_args(argv)
    try:
        if args.op == "counts":
            payload = counts(args.db)
        else:
            verdicts = stage2_verdicts.load(args.db)
            released = stage2_verdicts.released(verdicts, stage2_verdicts.GAP)
            payload = {"classes": sorted({x for x in args.classes.split(",") if x}),
                       "users": audience(verdicts, released, [x for x in args.classes.split(",") if x])}
    except stage2_verdicts.Stage2Error as exc:
        print(f"stage2-gap: {exc}", file=sys.stderr)
        return 2
    text = json.dumps(payload, indent=2, sort_keys=True)
    if getattr(args, "out", ""):
        _write_private(args.out, text + "\n")
        print(f"stage2-gap: wrote {args.out}", file=sys.stderr)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
