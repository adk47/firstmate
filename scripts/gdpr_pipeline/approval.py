"""The human (or approved-seat) approval a send actually needs, as a structured record - never as chat text.

`--approved-by` is text a caller types, so on its own it proves nothing. An earlier cut of this module accepted any
message from an allowlisted user that MENTIONED the batch digest, and Fable r5 broke it in three lines of Slack: a
refusal ("do not approve gdpr confirm <d> yet"), a question ("what does <d> cover?"), and a paste of the dry run's own
instructions all matched. A digest mention is not an approval.

The approval is therefore a grammar, not a sentiment. One top-level message, exactly this line and nothing else:

    APPROVE gdpr <kind> <digest> ruling=<ruling-id>

Parsing is exact (whole message, after collapsing runs of whitespace and stripping), so a negation, a question, a
quotation, a code block, a pasted dry run, or a chatty sentence is a non-match BY CONSTRUCTION rather than by a word
list. A threaded reply does not count either: an approval is said in the channel, not in a comment on someone else's
message.

What the gate binds, all of it required:

  - the approver: one of the allowlisted humans, or the one approved sender seat (029/031: `verify-sla-driver-fable-d2`
    posting through the DEVOPS bot, whose Slack user id we resolve with `auth.test` on that bot's token - Slack
    authenticates the poster, we never trust a name);
  - the ruling id: it must exist in the rulings ledger with the SAME kind and an unexpired `expires` (the ledger is a
    PR-reviewed file, `policies/gdpr-send-rulings.json`, so a new ruling is a reviewed commit, not an edit on a host);
  - the batch digest: sha256 over the kind and every `(register, row, sha256(body))` about to leave, so changing one
    letter, one row or the order invalidates the approval;
  - the clock: the message must be newer than `TTL_HOURS`.

FAIL CLOSED. No bot token, an unreadable history, a channel blanked to empty string, a ledger with no such ruling, an
expired ruling, an expired message: every one refuses with a sentence that says what was actually checked, because the
alternative is a statutory letter that left on a string somebody typed.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import urllib.request
from datetime import datetime, timedelta, timezone

from . import copy

CHANNEL_ENV = "GDPR_APPROVAL_CHANNEL"
LEDGER_ENV = "GDPR_RULINGS_LEDGER"
BOT_ENVS = ("MUSO_SLACK_BOT_TOKEN_OPERATIONS", "MUSO_SLACK_BOT_TOKEN_DEVOPS", "MUSO_SLACK_BOT_TOKEN_DEFAULT")
SEAT_ENV = "GDPR_APPROVER_SEAT"          # a bot user id, resolved from auth.test when unset
# The sanctioned sender seat posts THROUGH THE DEVOPS BOT (029/031), so its identity is that bot's user id. Resolving
# the seat from "whichever bot token we happen to read with" got the OPERATIONS bot (U0ANK0VS75F) while the driver
# posts as the DEVOPS bot (U0AN41ZBTRU): every approval the seat posted would have been refused as "not the seat".
SEAT_TOKEN_ENV = "MUSO_SLACK_BOT_TOKEN_DEVOPS"
# #clio_devops, where the watchdog already pages. Verified readable on node-8 by the DEVOPS / OPERATIONS / CTO /
# DEFAULT / CLIO bot tokens (conversations.history returns ok).
DEFAULT_CHANNEL = "C0ADV2W76G4"
DEFAULT_LEDGER = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                              "policies", "gdpr-send-rulings.json")
TTL_HOURS = 2
DIGEST_LEN = 16
SCAN_LIMIT = 5000                        # messages paged back through before we stop claiming to have looked

GRAMMAR = re.compile(r"^APPROVE gdpr (?P<kind>ask|confirm) (?P<digest>[0-9a-f]{%d}) ruling=(?P<ruling>\S+)$"
                     % DIGEST_LEN, re.IGNORECASE)


class Unverifiable(Exception):
    """We could not answer the approval question. Never a pass."""


def digest(kind: str, items: list[dict]) -> str:
    """The batch's identity: kind + every (register, row, body, subject) it will send, in order.

    The SUBJECT is bound only when an item HAS one, so a batch of in-thread replies hashes byte-identically to before
    and a standing approval is not disturbed by this change. For a new-thread letter it must be bound: the subject is
    customer-facing copy, and editing it changes the letter the person receives.

    The RECIPIENT (`recipient`) is bound on the same rule, and for a sharper reason (QA finding on #1749): a new-thread letter
    is addressed to the row's `requester_email`, which a later intake or a hand-edit can change. Without it in the
    hash, an approval cut for A still authorised the identical letter to B - one person's erasure request, in our
    words, delivered to somebody else. Empty for every other route, so in-thread digests are unchanged.

    The caller is responsible for passing the letter that will ACTUALLY be sent (`send.materialise` does that before
    this is called). Hashing a pre-materialisation body is the hole QA found on #1749: the approval covered bytes
    nobody was going to receive."""
    h = hashlib.sha256()
    h.update(kind.encode())
    for x in items:
        body = hashlib.sha256((x.get("text") or "").encode()).hexdigest()
        line = f"\n{x.get('register_no')}:{x.get('row')}:{body}"
        subj = x.get("subject") or ""
        if subj:
            line += ":" + hashlib.sha256(subj.encode()).hexdigest()
        to = x.get("recipient") or ""
        if to:
            line += ":" + hashlib.sha256(to.encode()).hexdigest()
        h.update(line.encode())
    return h.hexdigest()[:DIGEST_LEN]


def note(kind: str, items: list[dict]) -> str:
    """What a dry run may print: the DIGEST and nothing a caller can paste. The accept string is deliberately not
    printed (030): the pipeline must not manufacture the thing the gate accepts."""
    return (f"{len(items)} letter(s), batch digest {digest(kind, items)} "
            f"(the approval is one line, documented in docs/support/gdpr-pipeline.md; this run does not print it)")


# ------------------------------------------------------------------ slack
def _token() -> str:
    for name in BOT_ENVS:
        if os.environ.get(name):
            return os.environ[name]
    raise Unverifiable(f"no Slack bot token in the environment ({', '.join(BOT_ENVS)}): the approval cannot be read")


def _api(method: str, params: dict, token: str) -> dict:
    url = "https://slack.com/api/" + method + "?" + "&".join(f"{k}={v}" for k, v in params.items())
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        body = json.loads(urllib.request.urlopen(req, timeout=20).read())
    except Exception as exc:                                    # noqa: BLE001 - any failure is a refusal
        raise Unverifiable(f"Slack {method} failed ({type(exc).__name__}: {exc})") from exc
    if not body.get("ok"):
        raise Unverifiable(f"Slack refused {method}: {body.get('error') or 'no error given'}")
    return body


def _history(channel: str, token: str, oldest: int) -> list[dict]:
    """Every message back to `oldest`, paged with the cursor. `limit=200` alone returns the NEWEST 200 of the channel,
    so an approval could have aged out of the window while the refusal still claimed we looked (Fable r5 finding 5)."""
    out, cursor, scanned = [], "", 0
    while True:
        params = {"channel": channel, "oldest": oldest, "inclusive": "false", "limit": "200"}
        if cursor:
            params["cursor"] = cursor
        body = _api("conversations.history", params, token)
        out.extend(body.get("messages") or [])
        scanned += len(body.get("messages") or [])
        cursor = (body.get("response_metadata") or {}).get("next_cursor") or ""
        if not cursor or scanned >= SCAN_LIMIT:
            return out


def seat_id(token: str | None = None) -> str:
    """The approved sender seat's Slack user id (029). Env wins; else `auth.test` on the DEVOPS bot - Slack's word,
    not ours, and the bot the seat actually posts through."""
    if os.environ.get(SEAT_ENV):
        return os.environ[SEAT_ENV]
    body = _api("auth.test", {}, token or os.environ.get(SEAT_TOKEN_ENV) or _token())
    uid = str(body.get("user_id") or "")
    if not uid:
        raise Unverifiable("auth.test returned no user_id, so the sender seat's identity is unknown")
    return uid


# ------------------------------------------------------------------ rulings ledger
def rulings(path: str | None = None) -> dict[str, dict]:
    p = path or os.environ.get(LEDGER_ENV) or DEFAULT_LEDGER
    try:
        with open(p) as f:
            data = json.load(f)
    except FileNotFoundError as exc:
        raise Unverifiable(f"the rulings ledger {p} does not exist, so no ruling can be checked") from exc
    except (OSError, ValueError) as exc:
        raise Unverifiable(f"the rulings ledger {p} is unreadable ({exc})") from exc
    return {str(r.get("id")): r for r in (data.get("rulings") or [])}


def _instant(value, field: str, rid) -> tuple[datetime | None, str]:
    """(the instant, "" if fine else WHY not). An offset-NAIVE timestamp is REFUSED, never coerced.

    `datetime.fromisoformat("2026-11-05T21:30:00")` returns a naive datetime, and comparing it to the tick's
    UTC-aware `now` raises TypeError - which is not a refusal, it is a CRASH: the hourly unit dies before the
    letters after it and repeats the same failure every run, so the whole scheduled path stops on a typo in a
    ledger field. A ruling that does not say WHICH clock it means cannot be relied on, so it is refused by name
    (QA finding on #1779)."""
    try:
        got = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None, f"ruling {rid} has no readable `{field}`"
    if got.tzinfo is None:
        return None, (f"ruling {rid} `{field}` {value!r} carries no timezone offset, so it does not say which "
                      f"clock it means; write it as UTC (e.g. 2026-11-05T21:30:00Z)")
    return got, ""


def _ruling_ok(r: dict | None, kind: str, now: datetime, path: str | None = None) -> str:
    """("" if fine, else the reason). A ruling authorizes ONE kind of letter and it expires."""
    if r is None:
        return f"no such ruling id in {path or os.environ.get(LEDGER_ENV) or DEFAULT_LEDGER}"
    if str(r.get("kind") or "") != kind:
        return f"ruling {r.get('id')} approves {r.get('kind')!r}, not {kind!r}"
    exp, bad = _instant(r.get("expires"), "expires", r.get("id"))
    if bad:
        return f"{bad}, so it cannot be relied on"
    if exp <= now:
        return f"ruling {r.get('id')} expired at {exp.isoformat()}"
    return ""


# ------------------------------------------------------------------ the scheduled path
def _eligible_standing(kind: str, approved_by: str = "", now: datetime | None = None,
                       path: str | None = None) -> tuple[list[dict], list[str]]:
    """(the standing rulings that are FULLY eligible for this kind right now, why each other one is not).

    ONE predicate, used by BOTH the selection (`standing_classes`) and the verification (`verify_standing`). They
    disagreed once and it cost the erasure letters: selection unioned `classes` from rulings that had not passed
    their veto window and did not name the running identity, so a future-dated `legal_threat` ruling widened the
    batch, and verification then refused the WHOLE batch because no single ruling covered it - the statutory
    breaches did not send (QA finding on #1779). Selection and verification now read the same list, so they cannot
    disagree about which classes are authorised."""
    path = path or os.environ.get(LEDGER_ENV) or DEFAULT_LEDGER
    now = now or datetime.now(timezone.utc)
    try:
        ledger = rulings(path)
    except Unverifiable as exc:
        return [], [str(exc)]
    standing = [r for r in ledger.values() if r.get("standing") is True]
    if not standing:
        return [], [f"no standing ruling in {path}: the scheduled path needs one with `standing: true` "
                    f"(the interactive approval path is unaffected)"]
    ok, tried = [], []
    for r in standing:
        bad = _ruling_ok(r, kind, now, path)
        if bad:
            tried.append(bad)
            continue
        nb = r.get("not_before")
        if not nb:
            tried.append(f"standing ruling {r.get('id')} has no `not_before`: the veto window is a stated "
                         f"prerequisite, so an absent one is not 'already elapsed'")
            continue
        starts, bad = _instant(nb, "not_before", r.get("id"))
        if bad:
            tried.append(bad)
            continue
        if starts > now:
            tried.append(f"standing ruling {r.get('id')} does not start until {starts.isoformat()} "
                         f"(the veto window has not elapsed)")
            continue
        want = str(r.get("approved_by") or "")
        if not want:
            tried.append(f"standing ruling {r.get('id')} names no `approved_by`, so it cannot be bound to the "
                         f"identity running the tick")
            continue
        if want != (approved_by or ""):
            tried.append(f"standing ruling {r.get('id')} names approver {want!r}, not {approved_by!r}")
            continue
        want_copy = str(r.get("copy_sha") or "")
        if not want_copy:
            tried.append(f"standing ruling {r.get('id')} names no `copy_sha`, so it does not say which approved "
                         f"words it authorises (re-cut it with `gdpr-pipeline.py copy-sha`)")
            continue
        got_copy = copy.fingerprint()
        if want_copy != got_copy:
            tried.append(f"standing ruling {r.get('id')} was cut for copy {want_copy}, but this tree renders "
                         f"{got_copy}: the approved words changed, so the standing grant no longer covers what "
                         f"would be sent")
            continue
        want_classes = r.get("classes")
        if not isinstance(want_classes, list) or not want_classes:
            tried.append(f"standing ruling {r.get('id')} names no `classes`, so it does not say which request "
                         f"classes it authorises (a kind-only grant sent erasure words to a dmca_takedown row)")
            continue
        ok.append(r)
    return ok, tried


def standing_classes(kind: str, approved_by: str = "", now: datetime | None = None,
                     path: str | None = None) -> set[str]:
    """The request CLASSES the FULLY ELIGIBLE standing rulings for `kind` authorise, or an empty set.

    The scheduled path SELECTS with this before it verifies. Without it a batch that mixes classes is refused WHOLE,
    and refusing the erasure letters because a `dmca_takedown` row happens to share the batch would leave the
    statutory breaches unsent - the opposite of fail-closed. Selection narrows the batch; `verify_standing` still
    checks the result, and both read `_eligible_standing`, so they cannot disagree about which classes are covered.

    An empty set means "no live grant says anything", and the caller must NOT read that as "nothing is allowed":
    `verify_standing` is what refuses, and it names the missing field."""
    ok, _ = _eligible_standing(kind, approved_by, now, path)
    out: set[str] = set()
    for r in ok:
        out.update(str(c) for c in r["classes"])
    return out


def verify_standing(kind: str, items: list[dict], approved_by: str = "", now: datetime | None = None,
                    path: str | None = None) -> tuple[bool, str]:
    """("" if the pipeline may send, else WHY not) for the SCHEDULED path - the hourly tick, with no human in the loop.

    Fable decision 11-04 B26 Q1 (Aaron's 21:1xZ delegation, `data/captain-decisions-fable-d6/`): "unlock both lines;
    the register sends on its due dates". A tick cannot post a 2-hour Slack approval per batch, so the approval for
    this path is a REVIEWED LEDGER ENTRY instead of a chat message - `policies/gdpr-send-rulings.json` is PR-reviewed,
    so a standing ruling is a reviewed commit, and every refusal below names the field that was wrong.

    It is a SEPARATE function on purpose. The interactive `verify` above is unchanged and stays the default; nothing
    here can loosen it, and a ruling that is merely valid does NOT become a standing one. What is required:

      - `standing: true` - an explicit field. A ruling without it authorises NOTHING on this path, so no existing or
        future ask/confirm approval is silently promoted into "may send unattended forever";
      - `kind` equal to the letter being sent (an `ask` ruling never sends a `confirm`);
      - unexpired (`expires`) - the same clock the interactive path uses;
      - `not_before` REQUIRED and passed: the veto window. Decision 11-04 carries a 24 h veto, so a standing ruling
        says WHEN it starts instead of a human remembering to flip it; before that instant this refuses and names it.
        An ABSENT field is a refusal, not "already elapsed" (QA finding on #1779): the veto is a stated prerequisite,
        so a ruling that omits it would start sending the moment it merged;
      - `approved_by` REQUIRED and equal to the identity running the tick, so a standing ruling cannot be executed
        under somebody else's name. Absent is a refusal for the same reason;
      - `copy_sha` REQUIRED and equal to `copy.fingerprint()`: the grant names the WORDS it was cut for. A standing
        ruling runs unattended for a month, so editing an approved sentence (or flipping a copy gate) must invalidate
        it - otherwise the tick keeps sending text nobody approved, which is the failure the batch digest prevents
        one level down (QA finding on #1779);
      - `classes` REQUIRED and a superset of every item's class: the grant names the REQUESTS it authorises, not
        just the letter kind. `copy.ASK` is erasure copy and a `dmca_takedown` or `legal_threat` row reaches the same
        `ASK_LINK` verdict, so a kind-only grant would have told a rights-holder that "the deletion request you made"
        is in progress (QA finding on #1779). `run.ask_refusal` refuses those rows at the letter level too, so this
        is the second of two independent gates rather than the only one.

    The batch digest is still computed and returned to the caller, which ledgers it per letter (`erasure_sends.body_sha`
    plus the digest in `detail`): "the letter that left is a letter the approved copy renders" stays auditable even
    though no human approved this particular batch."""
    eligible, tried = _eligible_standing(kind, approved_by, now, path)
    if not eligible:
        return False, "; ".join(tried) if tried else f"no standing ruling authorises {kind!r}"
    want = {str(i.get("class") or "") for i in items}
    covered, names = set(), []
    for r in eligible:
        allowed = {str(c) for c in r["classes"]}
        if want <= allowed:
            return True, (f"standing ruling {r.get('id')} authorises {kind} batch {digest(kind, items)} "
                          f"(copy {copy.fingerprint()}, classes {sorted(allowed)})")
        covered |= allowed
        names.append(r.get("id"))
    outside = sorted(want - covered)
    if outside:
        return False, (f"no standing ruling covers {outside}: the eligible grants "
                       f"({', '.join(str(n) for n in names)}) name {sorted(covered)}")
    return True, (f"standing rulings {', '.join(str(n) for n in names)} together authorise {kind} batch "
                  f"{digest(kind, items)} (copy {copy.fingerprint()}, classes {sorted(covered)})")


# ------------------------------------------------------------------ the gate
def parse(text: str) -> dict:
    """The exact grammar, or {}. Whitespace runs collapse (Slack indents); nothing else is forgiven."""
    m = GRAMMAR.match(" ".join(str(text or "").split()))
    if not m:
        return {}
    return {"kind": m.group("kind").lower(), "digest": m.group("digest").lower(), "ruling": m.group("ruling")}


def verify(kind: str, items: list[dict], approver: str, allow: tuple[str, ...] | list[str],
           now: datetime | None = None, history=None, seat: str | None = None) -> tuple[bool, str]:
    """(ok, reason). `history`/`seat` are injectable so the tests never touch Slack."""
    now = now or datetime.now(timezone.utc)
    if not items:
        return False, "nothing to send, so there is nothing to approve"
    d = digest(kind, items)
    # An env var SET to "" is a deliberate switch-off, not "use the default" (Fable r5 finding 3).
    channel = os.environ[CHANNEL_ENV] if CHANNEL_ENV in os.environ else DEFAULT_CHANNEL
    if not channel:
        return False, f"{CHANNEL_ENV} is set to empty: the approval channel is switched off"
    # Resolve the seat ONLY when the approver is not an allowlisted human: resolving it unconditionally means a
    # real `auth.test` on every human approval, so a missing/rotated token refuses a human's approval for a reason
    # that has nothing to do with them (found by the Copy test running against a dummy token).
    if approver not in tuple(allow):
        try:
            seat = seat or seat_id()
        except Unverifiable as exc:
            return False, str(exc)
        if approver != seat:
            return False, (f"{approver!r} is neither an allowlisted human ({', '.join(allow)}) nor the sender seat "
                           f"{seat}")
    read = history or _history
    since = int((now - timedelta(hours=TTL_HOURS)).timestamp())
    try:
        ledger = rulings()
        msgs = read(channel, _token(), since)
    except Unverifiable as exc:
        return False, str(exc)
    seen, why = 0, "no message from that approver in the window"
    for m in msgs:
        if str(m.get("user") or "") != approver:
            continue
        seen += 1
        if m.get("deleted") or (m.get("thread_ts") and m.get("thread_ts") != m.get("ts")):
            why = "the approval was a deleted message or a threaded reply; it has to be said in the channel"
            continue
        got = parse(m.get("text") or "")
        if not got:
            why = "the message is not the approval grammar (a question, a refusal, a quote or a paste is not an approval)"
            continue
        if got["kind"] != kind or got["digest"] != d:
            why = f"the message approves {got['kind']} {got['digest']}, not this batch ({kind} {d})"
            continue
        bad = _ruling_ok(ledger.get(got["ruling"]), kind, now)
        if bad:
            why = bad
            continue
        return True, f"{approver} approved {kind} batch {d} under {got['ruling']} at {m.get('ts')}"
    return False, (f"{why} (scanned {len(msgs)} message(s) in {channel} back to "
                   f"{datetime.fromtimestamp(since, timezone.utc).isoformat(timespec='seconds')}; {seen} from "
                   f"{approver})")
