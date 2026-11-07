#!/usr/bin/env python3
"""L12 close path × the decline campaign: who tells the user, and who must NOT.

Authority: captain 2026-10-29 13:2xZ ("we could just say supporting information was not provided adequate enough to
earn the credit, and if they want to submit something they can submit something again") + Fable ruling
decline-copy-ruling.md §2.2 and §3.2 (muso-humans-off-fable-o1, 2026-10-29).

Two paths can tell a user their credit request was closed, and they must never both fire for one request:

  1. CORE'S OWN EMAIL - core's `credits_rejected` template, emitted by core on every `rejected` transition
     (updateStatus.js) including the L12 executor's own closes, through send-gateway into `send.messages`.
  2. HYDRA'S `decline` CAMPAIGN - scripts/intercom-verify-request.sh --campaign decline (the reason-free §1 copy).

The preferred end state is (1) alone: core's email IS the single decline, and hydra sends none. Hydra's campaign
exists for the window where core's route is off, and for a profile core has no email route for.

WHICH TEMPLATE (`--template`). A decline is about a credit or about a profile claim, and core emails those from
DIFFERENT templates with DIFFERENT routes: `credits_rejected` and `profile_claim_rejected`. Both reads below use the
one the caller names, so a claim is never judged by the credit route - if core emails credits but not claims, a
routed credit route would otherwise read as "core told this claimant" and the claimant would never get the decline
the copy promises (QA #1718, 2026-11-06). The campaign gate passes `profile_claim_rejected` for a `claim-<id>`
request and the default `credits_rejected` otherwise.

HOW "IS CORE'S EMAIL ROUTED" IS ANSWERED. Two facts, read at run time, never inferred from a campaign name:

  * MEASURED (per user): the send-gateway ledger `send.messages` rows with template_key = the chosen template for
    that user since the close. This is the same read the executor's fan-out check already makes
    (scripts/credit-fable-execute.py), so the answer is about the user in front of us, not about a config line.
    A user with NO such row after their close was NOT told by core (core's email is emitted on the `rejected`
    transition, so it can never predate the close).

    THE LEDGER CANNOT ATTRIBUTE A NOTE TO A REQUEST (QA #1718, 2026-11-06). `send.messages` carries no request id,
    so a row for this user since the close may belong to a DIFFERENT request that closed at the same time or later.
    Reading it as "core told them about THIS request" is an unsupported claim, and the cost of being wrong is the
    one forbidden outcome: a request that is never told. So a positive note is a HOLD, never a `core_email` - a
    person looks. Only the CONFIGURED fact can say `core_email` for everyone, because a routed template emails on
    every rejected transition, which is a statement about all requests rather than about one row.
  * CONFIGURED (fleet level): `MESSAGING_EMAIL_ROUTES`, a map of template/metric name -> mode word. The ruling names
    `new` and `shadow` as routed. THE VOCABULARY IS PER-CODEBASE (see the wiki: auth accepts klaviyo|shadow|new and
    treats `gateway` as a malformed map; platform-web accepts klaviyo|gateway|shadow and refuses `new`), so this word
    is read defensively here: any word we do not know makes the whole map UNKNOWN, never "off" (which would send) and
    never "routed" (which would silence a real decline silently).

Fail closed toward SILENCE, never toward a second decline: the one forbidden outcome is two decline messages for one
request, and a missed decline is visible to a person (the plan prints `hold`), while a duplicate is not.

Kill/again-safety: nothing here sends. `plan` prints decisions; the operator sends through the campaign gate, which
owns every send rule (one per user per UTC day, once per request id, 7-day cooldown, dry-run default, --limit).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Iterable

#: core's rejection template key in send-gateway (`send.messages.template_key`; core updateStatus.js).
CORE_TEMPLATE = "credits_rejected"
#: core's PROFILE-CLAIM rejection template. A claim is not a credit: core emails it from its own template, so it has
#: its own route. Judging a claim decline against the credit route would read "core emails credits" as "core told this
#: claimant" and the claimant would never get the decline the copy promises (QA #1718, 2026-11-06).
CLAIM_TEMPLATE = "profile_claim_rejected"
#: every template a decline can be about. The caller picks by request shape (`claim-<id>` vs a credit id).
TEMPLATES = (CORE_TEMPLATE, CLAIM_TEMPLATE)
#: the ruling's own word for "the gateway sends this" (`new` on auth, `gateway` on platform-web).
ROUTED_WORDS = frozenset({"new", "shadow", "gateway"})
#: words that mean "this template is not handled by the gateway" (Klaviyo is retired 2026-10-27).
OFF_WORDS = frozenset({"off", "none", "false", "disabled", "klaviyo", ""})
ROUTE_ENV = "MESSAGING_EMAIL_ROUTES"
ROUTE_FILE_ENV = "MESSAGING_EMAIL_ROUTES_FILE"
#: the same read-only messaging read the executor's fan-out check uses (belief is not evidence).
MESSAGING_PG = os.environ.get(
    "FABLE_DECIDER_MESSAGING_PG",
    "kubectl -n messaging exec -i messaging-pg-pgha-6c8n-0 -c database -- psql -U postgres -d preferences -At '-F|'")
#: psql continues past an SQL error and still exits 0 by default, so a renamed table or a lost grant prints its error
#: to stderr and returns EMPTY stdout - which reads as "no rows" and, with core's route off, would read as "core never
#: told this user". That is permission to send a second decline (QA #1718 A), so every call is strict and every
#: non-empty stderr is treated as "could not be read".
#: TWO argv elements, never one (QA #1718, 2026-11-06): psql parses `-v` with getopt, so the rest of the SAME word
#: becomes the variable assignment. `psql "-v ON_ERROR_STOP=1"` therefore asks for a variable named
#: `" ON_ERROR_STOP"` (leading space) and dies with `invalid variable name: " ON_ERROR_STOP"` - which made every
#: real read unreadable, so with core's route off every eligible decline was held and none could send.
PSQL_STRICT = ("-v", "ON_ERROR_STOP=1")
#: what one row of the grouped read looks like (`user_id|count`)
LEDGER_ROW = re.compile(r"^\d+\|\d+$")

#: plan() decisions. `hold` is a decision, not an absence: nothing is sent and a person is told why.
CORE_EMAIL = "core_email"        # core's own email is the decline: hydra sends NONE
HYDRA_DECLINE = "hydra_decline"  # core did not tell them: hydra's reason-free decline is the one message
HOLD = "hold"

NotesReader = Callable[..., Any]


# ── the configured fact: MESSAGING_EMAIL_ROUTES ──────────────────────────────────────────────────────────────
def route_map() -> tuple[dict[str, Any] | None, str]:
    """({template: word} | None, why). The map from the env var core reads, else from a file (the same JSON, so a
    host-side copy of core's manifest can be checked without exporting anything into a process environment)."""
    raw, where = os.environ.get(ROUTE_ENV, ""), ROUTE_ENV
    if not raw.strip():
        path = os.environ.get(ROUTE_FILE_ENV, "")
        if not path:
            return None, f"{ROUTE_ENV} is not set and {ROUTE_FILE_ENV} names no file"
        where = f"{ROUTE_FILE_ENV}={path}"
        try:
            with open(path, encoding="utf-8") as fh:
                raw = fh.read()
        except OSError as exc:
            return None, f"{where} unreadable: {exc.__class__.__name__}"
    try:
        doc = json.loads(raw)
    except ValueError:
        return None, f"{where} is not JSON"
    if not isinstance(doc, dict):
        return None, f"{where} is not a JSON object"
    return {str(k): v for k, v in doc.items()}, where


def _template_value(doc: dict[str, Any], template: str) -> tuple[bool, Any]:
    """(exact, value): an exact key wins, else the `*` default (core's map is keyed by template/metric name and
    carries a `*` row). A key with different case is NOT the key: a map is matched exactly, as core matches it."""
    if template in doc:
        return True, doc[template]
    if "*" in doc:
        return False, doc["*"]
    return False, None


def route_state(template: str = CORE_TEMPLATE) -> tuple[str, str]:
    """(routed | off | unknown, why) for `template`. Unknown on any word we do not know, on a non-string value, and on
    a missing map: see the module docstring (silence is the safe side, a second decline is the forbidden one)."""
    doc, where = route_map()
    if doc is None:
        return "unknown", where
    exact, value = _template_value(doc, template)
    if not exact and value is None:
        return "off", f"{where} names no {template} route and has no '*' default: the gateway does not send it"
    if not isinstance(value, str):
        return "unknown", f"{where} gives {template} a non-string value ({type(value).__name__})"
    word = value.strip().lower()
    if word in ROUTED_WORDS:
        return "routed", f"{where} routes {template} to the gateway ('{value}')"
    if word in OFF_WORDS:
        return "off", f"{where} routes {template} away from the gateway ('{value}')"
    return "unknown", f"{where} gives {template} an unrecognised mode word ('{value}')"

# ── the measured fact: what core actually sent these users ───────────────────────────────────────────────────
def core_notes(users: Iterable[int], since: str, *, template: str = CORE_TEMPLATE,
               runner: Callable[[str], Any] | None = None,
               pg: str = MESSAGING_PG) -> tuple[dict[int, int] | None, str]:
    """({user_id: notes} | None, why) from send-gateway's `send.messages` since `since` (UTC ISO). None = the ledger
    could not be read, and then NOTHING is concluded about anyone (a caller must hold, never send).

    `template` is the template the decline is about: `credits_rejected` for a credit, `profile_claim_rejected` for a
    profile claim. Reading the wrong one answers a question nobody asked."""
    ids = sorted({int(u) for u in users})
    if not ids:
        return {}, "no users"
    if template not in TEMPLATES:
        return None, f"unknown template {template!r} (expected one of {', '.join(TEMPLATES)})"
    if not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", str(since)):
        return None, f"since must be UTC YYYY-MM-DDTHH:MM:SSZ (got {since!r})"
    sql = (f"select user_id, count(*) from send.messages where template_key = '{template}' "
           f"and created_at >= '{since}' and user_id in ({','.join(str(u) for u in ids)}) group by 1;")
    if runner is not None:
        return _read_notes(runner(sql), since, len(ids), template)
    try:
        p = subprocess.run(shlex.split(pg) + list(PSQL_STRICT), input=sql, capture_output=True, text=True,
                           timeout=120, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, f"send ledger unreadable: {exc.__class__.__name__}"
    return _read_notes(p, since, len(ids), template)


def _read_notes(p: Any, since: str, n_users: int, template: str = CORE_TEMPLATE) -> tuple[dict[int, int] | None, str]:
    """A psql answer is EVIDENCE only if it is clean: rc 0, no stderr, and every line a `user_id|count` row.
    Anything else is "we could not read the ledger", which the callers turn into a HOLD, never into a send."""
    rc = getattr(p, "returncode", 0)
    err = str(getattr(p, "stderr", "") or "")
    if rc != 0:
        return None, f"send ledger unreadable rc={rc}: {err[:160]}"
    if err.strip():
        # an SQL error, a NOTICE or a connection banner: none of them is a measurement
        return None, f"send ledger unreadable: psql said {err.strip()[:160]}"
    counts: dict[int, int] = {}
    for line in str(getattr(p, "stdout", "") or "").splitlines():
        line = line.strip()
        if not line:
            continue
        if not LEDGER_ROW.match(line):
            return None, f"send ledger unreadable: unexpected output {line[:80]!r}"
        uid, n = line.split("|")
        counts[int(uid)] = int(n)
    return counts, (f"{sum(counts.values())} {template} note(s) to {len(counts)} of {n_users} user(s) "
                    f"since {since}")


# ── the decision ────────────────────────────────────────────────────────────────────────────────────────────
def plan(users: Iterable[int], since: str, *, template: str = CORE_TEMPLATE,
         route: tuple[str, str] | None = None,
         notes: tuple[dict[int, int] | None, str] | None = None) -> dict[str, Any]:
    """Per user: who tells them, and why. Nothing here sends anything.

    `template` is the template this decline is about (`credits_rejected` for a credit, `profile_claim_rejected` for a
    profile claim): BOTH the route read and the ledger read use it, so a claim is never judged by the credit route.

      * route says `routed`          -> core_email for everyone (hydra sends none: core's email is the decline)
      * route says `off`             -> no note since the close = hydra_decline (core cannot have told them);
                                        ANY note = hold, because the ledger cannot say whose request it was
      * route says `unknown`         -> hold for everyone: we cannot tell whether core's route is off or merely
                                        worded differently in that repo, and a note proves nothing about THIS request
      * the ledger is unreadable     -> hold, both ways.

    `hold` never means "we forgot": the caller prints it and a person decides."""
    ids = sorted({int(u) for u in users})
    if template not in TEMPLATES:
        raise ValueError(f"unknown template {template!r} (expected one of {', '.join(TEMPLATES)})")
    state, route_why = route if route is not None else route_state(template)
    if state == "routed":      # core's email is the decline for everyone: no per-user read can change that
        counts, notes_why = {}, "not read: core's route is on, so core's email is the decline"
    elif notes is not None:
        counts, notes_why = notes
    else:
        counts, notes_why = core_notes(ids, since, template=template)
    out: dict[str, Any] = {"since": since, "template": template,
                           "route": {"state": state, "why": route_why},
                           "core_notes": {"why": notes_why, "counts": counts}, "users": {}}
    for uid in ids:
        noted = None if counts is None else counts.get(uid, 0)
        if state == "routed":
            decision, why = CORE_EMAIL, f"core routes {template} through the gateway: core's email is the decline"
        elif noted is None:
            decision = HOLD
            why = f"the send ledger could not be read ({notes_why})"
        elif noted == 0:
            if state == "off":
                decision = HYDRA_DECLINE
                why = (f"core's route is off and the send ledger shows no {template} note for this user since "
                       f"the close, so core did not tell them")
            else:
                decision = HOLD
                why = f"core's route state is unknown ({route_why})"
        else:
            # A note exists, but `send.messages` has no request id: it may be another request's decline. Claiming
            # `core_email` here would silently leave THIS request untold (QA #1718, 2026-11-06), so a person looks.
            decision = HOLD
            why = (f"the send ledger shows {noted} {template} note(s) for this user since the close, but a "
                   f"send.messages row carries no request id, so we cannot tell whether one of them is THIS "
                   f"request's decline; a person decides")
        out["users"][str(uid)] = {"decision": decision, "why": why}
    out["decision"] = counts_of(out["users"])
    return out


def counts_of(users: dict[str, dict[str, str]]) -> dict[str, int]:
    out = {CORE_EMAIL: 0, HYDRA_DECLINE: 0, HOLD: 0}
    for row in users.values():
        out[row["decision"]] = out.get(row["decision"], 0) + 1
    return out


def hydra_users(result: dict[str, Any]) -> list[int]:
    """The users hydra must send the decline to (nobody else). The caller feeds these to the campaign gate."""
    return sorted(int(u) for u, row in result["users"].items() if row["decision"] == HYDRA_DECLINE)


ONE_USER_DAYS = 30


def core_told(user_key: str, user_id: str, request_ids: Any, since: str, *, template: str = CORE_TEMPLATE,
              route: str | None = None, notes: dict[int, int] | None = None) -> dict[str, bool] | None:
    """request_id -> True for every credit CORE's own decline email has told this user about, or None when that
    cannot be established (the caller must then hold).

    This is the removal path's half of the question the send gate asks (QA #1718, 2026-11-06): a rejected credit is
    only ever removed once its owner has been told, and with core's route ON the telling is core's email, not a hydra
    `decline` row - so a removal decision that reads only hydra's ledger holds every rejected credit forever.

    A CONFIGURED ROUTE IS NOT A DELIVERY (QA #1718 round 5, 2026-11-06). `routed` says core's pipeline handles the
    template; it does not say a message reached this person - a gateway send can fail, and an account can have no
    deliverable address. Releasing a credit on the route alone would remove it from someone who was never told, so a
    routed template must ALSO show a row in the send ledger for this user since the close. No row is None (hold), not
    a release. A route measured OFF means core told nobody and hydra's own sent `decline` row is the only telling; an
    unreadable route or ledger is None, never a guess.

    A USER-LEVEL COUNT IS NEVER PER-REQUEST EVIDENCE (QA #1718 rounds 6 and 7, 2026-11-06). `send.messages` carries
    no request id, and neither does ClickHouse `messaging.email_events` (its columns are event_time, event_type,
    source, template_key, subject, campaign_name, provider, reason, email, user_id, event_id) - so NO store we can
    read can say which credit a note was about. Counting rows cannot fix that: one credit rejected twice produces two
    notes, so a count of N does not mean N distinct requests were told, and a count of at least N does not mean every
    request was. The answer is therefore never True for a specific request while core is the teller.

    The return value says which of the three states we are in, because the human reading the hold needs to know:
      * `None` - nothing can be established (route unknown, ledger unreadable, no usable user id, or the ledger shows
        no note at all since the close). The caller holds as "not told".
      * `{rid: False, ...}` - core's route is on and the ledger DOES show a note for this user since the close, but a
        note cannot be attributed to a request, so we cannot prove THIS credit was one of them. The caller holds as
        "not attributable" and a person decides.
      * `{}` - core's route is measured OFF, so core told nobody and hydra's own sent `decline` row (which DOES name
        its request ids) is the only telling.

    A True value is never returned today. It is kept in the contract so that the day core's email carries a request
    id, only this function changes.
    """
    ids = [str(x).strip() for x in (request_ids or []) if str(x).strip()]
    if not ids:
        return {}
    if template not in TEMPLATES:
        return None
    state = route if route is not None else route_state(template)[0]
    if state == "off":
        return {}
    if state != "routed":
        return None
    try:
        uid = int(str(user_id).strip())
    except (TypeError, ValueError):
        return None
    if notes is None:
        notes, _why = core_notes([uid], since, template=template)
    if notes is None:
        return None
    # A USER-LEVEL COUNT IS NEVER PER-REQUEST EVIDENCE (QA #1718 rounds 6 and 7, 2026-11-06). No store we can read
    # carries a request id, so a note cannot be attributed to a credit: one credit rejected twice produces two notes,
    # which means a count of N does not mean N distinct requests were told and a count of at least N does not mean
    # every request was. Counting cannot close that gap, so we never answer True for a specific request. A note that
    # exists but cannot be attributed is reported as False ("not attributable") rather than None ("not told"),
    # because the two are different facts and the human reading the hold needs the right one.
    return {rid: False for rid in ids} if int(notes.get(uid, 0) or 0) > 0 else None


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Who tells a closed credit request (core's email or hydra's decline).")
    ap.add_argument("--users", help="comma-separated Muso user ids the close touched (the batch plan)")
    ap.add_argument("--user-id", help="ONE user id: the send gate's per-user ask before it sends a decline "
                                      "(exit 0 only when hydra is the teller, so an unmeasured user never sends)")
    ap.add_argument("--since", help="UTC ISO time the closes started (YYYY-MM-DDTHH:MM:SSZ)")
    ap.add_argument("--days", type=int, default=ONE_USER_DAYS,
                    help=f"with --user-id: how far back the send ledger is read (default {ONE_USER_DAYS})")
    ap.add_argument("--route", choices=["routed", "off", "unknown"], help="override the route read (a signed fact, not a default)")
    ap.add_argument("--template", choices=list(TEMPLATES), default=CORE_TEMPLATE,
                    help="the template this decline is about: credits_rejected for a credit (default), "
                         "profile_claim_rejected for a profile claim")
    args = ap.parse_args(argv)
    route = None if not args.route else (args.route, "given on the command line")
    if bool(args.users) == bool(args.user_id):
        print(json.dumps({"error": "give exactly one of --users (a batch plan) or --user-id (one send decision)"}))
        return 2
    if args.user_id:
        # THE SEND GATE'S READ (QA #1718 3): the campaign gate must never send to a user core already told, and must
        # never send while the route is unknown. Only `hydra_decline` exits 0.
        try:
            uid = int(args.user_id)
        except ValueError:
            print(json.dumps({"error": "user id must be an integer"}))
            return 2
        since = args.since or (datetime.now(timezone.utc) - timedelta(days=max(1, args.days))
                               ).strftime("%Y-%m-%dT%H:%M:%SZ")
        result = plan([uid], since, template=args.template, route=route)
        row = result["users"][str(uid)]
        print(json.dumps({"decision": row["decision"], "why": row["why"], "user_id": uid, "since": since,
                          "template": args.template, "route": result["route"]}))
        return 0 if row["decision"] == HYDRA_DECLINE else 3
    if not args.since:
        print(json.dumps({"error": "--since is required with --users"}))
        return 2
    try:
        ids = [int(x) for x in args.users.replace(" ", "").split(",") if x]
    except ValueError:
        print(json.dumps({"error": "users must be comma-separated user ids"}))
        return 2
    result = plan(ids, args.since, template=args.template, route=route)
    print(json.dumps(result, indent=2))
    # exit 0 = every user decided (send hydra's decline to hydra_users), 3 = somebody is held for a person
    return 0 if result["decision"].get(HOLD, 0) == 0 else 3


if __name__ == "__main__":
    sys.exit(_main())
