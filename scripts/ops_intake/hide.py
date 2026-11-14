#!/usr/bin/env python3
"""The operations intake for "hide this profile": one ask in, one register row + the reversible hide PRs out.

WHY THIS EXISTS (incident 2026-11-04)
The operations bot answered hide requests with `muso --env prod --requester jan … api DELETE /admin/profile/<id>`,
taught by a workspace-only skill nobody had reviewed as policy. It ran 21 times in 14 days: a one-way tombstone of
each profile AND every served credit on it (one profile went 431 served credits -> 0). There is no inverse, and legal
hold 1350 means the data is never destroyed. Both wrappers now refuse that endpoint
(`MUSO_REMOVAL_NO_SELF_APPROVE`), and `scripts/check-skill-drift.sh` fails any doctrine that names it as the hide path.

The real hide is the ONE the register already owns and it is reversible:

    ask text ──▶ this file ──▶ scripts/gdpr-pipeline.py (register `erasure_requests`, identity paths A–E)
                            ──▶ hide_batch -- the two hide-list PRs (H-DevOps HIDDEN_ENTITY_IDS + PDP
                                LEGAL_HIDDEN_ENTITY_IDS), which a PERSON merges (captain standing order)
                            ──▶ mark-hidden 410 + noindex read-back writes `hidden_at`
                            ──▶ the pipeline's own confirmation letter

Nothing here decides identity, hides anything, or sends a letter. This module is INTAKE: it parses the ask as DATA,
refuses the shapes that must never become a hide, files/attaches the register row, asks the pipeline for the identity
verdict, and prepares the reversible PRs for the pages the pipeline passed. Undo = remove the id from both lists.

WHAT THE ASK TEXT MAY AND MAY NOT DO
The ask text is DERIVED, never accepted: it is the body of the Slack message named by --channel/--message-ts, read
back from Slack, and there is no argument that supplies it. The text says WHICH pages the ask is about and, in the
requester's own words, WHY. It never establishes identity, never picks a verdict and never authorises a hide: a
requester typing "GDPR" (or "Jan said hide") is not identity, and identity is decided by the pipeline from the
Intercom contact + the core replica. If the pipeline answers UNKNOWN/ASK_*, the reply says what the pipeline will ask
the customer and NOTHING is hidden.

CLASSES (`--` the pipeline's own vocabulary; there is no new one)
  privacy_erasure   GDPR / Art. 17 / "remove me", a name removal, an objection to a public listing
  dmca_takedown     a rights complaint, a DSP/Spotify removal: a CATALOG TAKEDOWN, not a GDPR erasure, so it gets a
                    register row and the track-removal human path -- NEVER a profile hide
  legal_threat      a lawyer / a threat of action: hide first, identity after, and the CAPTAIN owns it (never this
                    pipeline's own routine batch)

USAGE
  hide.py --requester-id U038BM16T7W --channel C0OPS --message-ts 1793704998.000001 \
          [--conversation 215472...] [--apply] [--open-prs]

  There is no ask-text argument. The message named by --channel/--message-ts is read back from Slack, its author must
  be --requester-id, and its BODY is the ask: the ids and the class come from that text and nowhere else. An
  unreadable message (no token, ok:false, no message, ts mismatch, no author, no text) refuses (exit 6).

  default is a DRY RUN: it prints the register rows it would file and the PRs it would open, and writes nothing.
  --apply        file/attach the rows and let the pipeline decide identity (needs the store; node-8 only)
  --open-prs     with --apply: open the two hide-list PRs NOW for this ask's identity-PASS pages (not the next tick)
  --post-card    post the thread card to Slack (the card is always printed)
  --json         machine output (the card + the rows + the PR urls) instead of prose

Exit codes: 0 ok | 1 refused (bad ask / nothing to do) | 2 a read failed (fail closed) | 3 not staff (tier R)
            4 held (limits or the kill switch) | 5 the ask states no class we may act on
            6 the requester's identity or the ask text could not be read from the message they named
"""
from __future__ import annotations

import argparse
import ast
import contextlib
import fcntl
import importlib.util
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
CLI_PATH = SCRIPTS / "gdpr-pipeline.py"
sys.path.insert(0, str(SCRIPTS))

from gdpr_pipeline import hide_batch, sources  # noqa: E402
from gdpr_pipeline.identity import IDENTITY_PASS  # noqa: E402
from gdpr_pipeline.run import Run  # noqa: E402
from gdpr_pipeline.store import (  # noqa: E402
    DEFAULT_PATH,
    SAME_EVENT_SECONDS,
    Store,
    page_prefix,
    parse_iso,
)
from ops_intake.slack import message_author  # noqa: E402

KILL = "/etc/hydra/gdpr-pipeline.disabled"

UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
UUID_RE = re.compile(UUID, re.I)
PROFILE_URL_RE = re.compile(r"(?:credits\.|www\.)?muso\.ai/profile/(" + UUID + ")", re.I)
TRACK_URL_RE = re.compile(r"(?:credits\.|www\.)?muso\.ai/track/(" + UUID + ")", re.I)

# Limits are policy, not tuning: they bound how much one ask can move. Over the limit the ask is HELD (filed nowhere)
# and the thread says so, because a 40-id "hide these" from a staff id is exactly the shape of the old bulk DELETE.
MAX_IDS_PER_ASK = 10
MAX_IDS_PER_REQUESTER_PER_DAY = 30


@contextlib.contextmanager
def register_lock(store_path: str):
    """Serialize the daily-cap decision with the inserts that spend it.

    Read-then-write across processes is not atomic on its own: two asks arriving together each read the same count,
    each see room, and each commit -- 20 + 20 = 40 against a 30/day hold (QA 5903932382, Important). An flock on a
    sibling file serializes them without wrapping SQLite in a long transaction that the intermediate commits inside
    the filing loop would break anyway. ``LOCK_EX`` blocks, so the loser waits and re-reads a count that already
    includes the winner's rows."""
    lock_path = f"{store_path}.cap-lock"
    Path(lock_path).parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "w", encoding="utf-8") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)

ASK_CHANNEL = "slack-ops"

# The requester's own words -> the register's class. Ordered MOST RESTRICTIVE FIRST: a threat in a copyright
# complaint is a legal threat (the captain owns it, hide-first), not a routine DMCA review.
CLASS_RULES = (
    ("legal_threat", re.compile(
        r"\b(lawyer|attorney|solicitor|legal action|lawsuit|sue|suing|legal threat|court|"
        r"cease and desist|defamation|injunction)\b", re.I)),
    ("dmca_takedown", re.compile(
        r"\b(dmca|copyright|takedown|take down|infring|rights holder|removed from spotify|remove (it |the track )?"
        r"from spotify|dsp removal|no longer on spotify)\b", re.I)),
    ("privacy_erasure", re.compile(
        r"\b(gdpr|erasure|erase|right to be forgotten|article 17|art\.? ?17|privacy|personal data|"
        r"remove (me|my (profile|name|data|account))|remove (his|her|their) (profile|name|data)|"
        r"not (want|wish|wants|wishes) to be (public|listed|on (muso|the site)|searchable)|"
        r"name removal|opt out of (search|the site)|no longer (be )?(public|listed))\b", re.I)),
)

# The verb alone is NOT a reason, and the class decides which letter a customer gets and which path a page takes
# (a bare "hide" that is really a DSP takedown must never become a GDPR erasure, or the customer is told we deleted
# their data when we removed one track). So a verb-only ask is refused with the question, never guessed.
WEAK_VERB_RE = re.compile(r"\b(hide|hidden|unlist|delist|take (it )?down|remove)\b", re.I)


def cli_module():
    """The pipeline CLI, loaded as a module (it is a hyphenated script, not an importable package). One copy of
    `hidden_now`, `Store` and the approver list; never a second implementation of either."""
    spec = importlib.util.spec_from_file_location("gdpr_pipeline_cli", CLI_PATH)
    if spec is None or spec.loader is None:                      # pragma: no cover
        raise SystemExit(f"cannot load {CLI_PATH}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def staff_approvers() -> tuple[str, ...]:
    """The staff allowlist, READ OUT OF gdpr-pipeline.py's APPROVERS by AST rather than copied.

    A copied tuple silently stops matching the day the real one changes, and this gate is the difference between a
    staff ask and an injected one; an unreadable file is a refusal, never an empty allowlist (which would refuse
    everyone -- safe but confusing) and never a wildcard (which would accept everyone)."""
    try:
        tree = ast.parse(CLI_PATH.read_text())
    except OSError as exc:
        raise SystemExit(f"REFUSED: cannot read the approver list from {CLI_PATH}: {exc}") from exc
    for node in tree.body:
        if (isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name) and node.targets[0].id == "APPROVERS"):
            try:
                return tuple(ast.literal_eval(node.value))
            except ValueError as exc:                            # pragma: no cover
                raise SystemExit(f"REFUSED: APPROVERS in {CLI_PATH} is not a literal tuple: {exc}") from exc
    raise SystemExit(f"REFUSED: no APPROVERS tuple in {CLI_PATH} -- the staff allowlist moved, so nobody is staff")


class IdentityUnverified(Exception):
    """The requester id could not be bound to the message the ask names."""


def verify_requester(requester_id: str, channel: str, message_ts: str) -> str:
    """The BODY of the message this ask names, after proving its author is the requester.

    A caller-supplied --requester-id proves only that the CALLER typed a staff id, and caller-supplied ask text proves
    nothing at all, so the ask is DERIVED from the message it names: the author must be the requester and the body is
    the only text the parser ever sees. Every unreadable case is a refusal: an unmeasured identity or ask is not a
    passed check."""
    if not channel or not message_ts:
        raise IdentityUnverified("the ask names no --channel/--message-ts, so the requester cannot be verified")
    try:
        author, body = message_author(channel=channel, ts=message_ts)
    except Exception as exc:  # noqa: BLE001  -- any read failure is UNKNOWN, and UNKNOWN is a refusal
        raise IdentityUnverified(f"the message could not be read ({exc})") from exc
    if author != requester_id:
        raise IdentityUnverified(f"the message at {message_ts} in {channel} was authored by {author}, not "
                                 f"{requester_id}")
    if not (body or "").strip():
        raise IdentityUnverified(f"the message at {message_ts} in {channel} has no text to act on")
    return body


def parse_ids(text: str) -> list[tuple[str, str]]:
    """[(entity, id)] from the ask, in the order they appear, deduped. The ask is DATA: this reads ids only.

    A URL tells us the entity. A BARE uuid does not, and guessing "track" would send a profile to the track-removal
    path (and vice versa), so a bare id is filed as a PROFILE: the pipeline then reads that page from the catalog and
    answers UNKNOWN/ASK if it is not one, which hides nothing. Never the other way round."""
    out: list[tuple[str, str]] = []
    seen: set[str] = set()
    for m in PROFILE_URL_RE.finditer(text or ""):
        i = m.group(1).lower()
        if i not in seen:
            seen.add(i)
            out.append(("profile", i))
    for m in TRACK_URL_RE.finditer(text or ""):
        i = m.group(1).lower()
        if i not in seen:
            seen.add(i)
            out.append(("track", i))
    for m in UUID_RE.finditer(text or ""):
        i = m.group(0).lower()
        if i not in seen:
            seen.add(i)
            out.append(("profile", i))
    return out


def classify(text: str) -> tuple[str, str]:
    """(class, the requester's phrase that set it) or ("", "") when the ask states no reason we may act on."""
    for cls, rx in CLASS_RULES:
        m = rx.search(text or "")
        if m:
            return cls, m.group(0)
    return "", ""


def ask_key(given: str, requester_id: str, channel: str, message_ts: str) -> str:
    """The ask's own id: what the PR body and the thread card quote, and the row key's prefix (idempotence).

    The REQUESTER is part of EVERY key on purpose: the daily cap (MAX_IDS_PER_REQUESTER_PER_DAY) is counted off the
    register by requester, and a key the caller could name freely would be a per-channel counter that any staff
    member could widen for another. A caller-supplied id is a LABEL appended to the derived key, never the key."""
    stamp = (message_ts or "no-ts").replace(".", "")
    base = f"{ASK_CHANNEL}:{requester_id}:{(channel or 'dm')}:{stamp}"
    return f"{base}:{given}" if given else base


def epoch_to_iso(stamp: str, fallback: datetime) -> str:
    """A Slack ts (``1793704998.000001``) is the ask's own arrival time: the 24-hour hide clock is measured from it,
    never from whenever this ran. An unparseable/absent ts falls back to now and says so."""
    try:
        return datetime.fromtimestamp(float(stamp), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError, OSError):
        return fallback.strftime("%Y-%m-%dT%H:%M:%SZ")


def key_requester(key: str) -> str:
    """The requester a register key is charged to: the segment immediately after the channel prefix.

    Positional on purpose. A caller-supplied ask id is a LABEL appended after the requester, so a membership test
    anywhere in the split would let one staff member spend another's daily cap by naming them as the label."""
    parts = (key or "").split(":")
    if len(parts) < 2 or parts[0] != ASK_CHANNEL:
        return ""
    return parts[1]


def ids_today(store: Store, requester_id: str, day: str) -> int:
    """How many ids this requester already filed today, counted off the register itself (no second ledger).

    Counted by the REQUESTER recorded in the row's PRIMARY key, never by the key's shape: a caller-supplied ask id
    is a label, and a cap a caller can step around by naming its own key is not a cap. An attach adds a key but
    never a page, so the row's creator keeps its full count and the attacher is charged nothing for it."""
    total = 0
    for r in store.all():
        if r.get("created_at", "")[:10] != day:
            continue
        if key_requester(r.get("row_key") or "") == requester_id:
            total += len(r.get("pages") or [])
    return total


def candidate(ask: str, cls: str, ent: str, pid: str, *, received_at: str, conversation: str, ts: str,
              requester_name: str = "") -> dict:
    """One register candidate for one page of this ask (one file/attach per id, so an id that already has a row is
    ATTACHED to it and a new id opens its own row: two customers are never merged because one Slack message named
    both)."""
    return {
        "keys": [f"{ask}:{pid}"],
        "channel": ASK_CHANNEL,
        "class": cls,
        "received_at": received_at,
        "conversation_id": conversation,
        "pages": [{"entity": ent, "id": pid}],
        "note": f"ops intake {ask} (staff ask {'at ' + ts if ts else 'no message ts'}); "
                f"asked in the requester's own words, the class is set from that phrase and reviewed on the row",
        "requester_name": requester_name,
    }


def open_rows_with_page(store: Store, pid: str, cls: str) -> list[dict]:
    """Every OPEN register row that already carries this page in THIS class, newest deadline first.

    A LIST, not a single row: the register keeps one row per REQUESTER (captain, 2026-11-14, option (c)), so a page can
    legitimately sit on two open rows and each keeps its own receipt, statutory deadline and reply target -- GDPR clocks
    run per requester, and merging them hands one customer another customer's deadline. Dedupe happens downstream in
    ``hide_batch.plan``, which keys on page id, so one page still yields one hide PR no matter how many rows name it.

    The CLASS must match, because a DMCA takedown of a track is not the erasure of a profile that shares the id in the
    ask, and the row's identity verdict is never touched by a second ask reaching it."""
    return [r for r in store.all("open")
            if r.get("class") == cls
            and any(page_prefix(p.get("id")) == page_prefix(pid) for p in r.get("pages") or [])]


def same_customer_event(row: dict, conversation: str, contact: dict | None, received_at: str) -> bool:
    """Is this ask the SAME CUSTOMER's request as ``row``, or a different one?

    Only CUSTOMER evidence counts. The staff Slack id in ``row_key`` is deliberately NOT evidence: the operator who
    filed A's request is often the operator who files B's, so treating it as proof re-creates exactly the merge this
    function exists to prevent -- QA review 5903932382 (Critical), one round after the same defect was flagged. A
    staffer handling two customers' requests for one page files two requests, because the deadline and the reply
    target belong to the customer, not to whoever typed the ask.

    Evidence is the linked conversation the row was filed from, or the same Intercom contact WITHIN the register's
    same-event window (``SAME_EVENT_SECONDS``). A contact match on its own is not evidence: one customer can open a
    second, independent request for the same page weeks later, and that request needs its own receipt, deadline and
    reply target (QA 5904134453, Important). Two deliveries of one notice differ by seconds, never by days, which is
    why the window is the same one ``Store._match`` uses. A verbatim replay of the same Slack message is not this
    function's job either: it carries the same per-page key, so ``Store.upsert`` resolves it before any of this runs."""
    if conversation and str(row.get("conversation_id") or "") == str(conversation):
        return True
    contact_id = str((contact or {}).get("contact_id") or "")
    if not contact_id or str(row.get("contact_id") or "") != contact_id:
        return False
    try:
        gap = abs((parse_iso(received_at) - parse_iso(row["received_at"])).total_seconds())
    except (KeyError, TypeError, ValueError):
        return False
    return gap <= SAME_EVENT_SECONDS


def hide_for_rows(rows: list[dict], run: Run, *, ask: str, apply: bool) -> dict:
    """Prepare the reversible hide PRs for THIS ask's identity-PASS pages.

    Reuses the pipeline's own planner (the legal-threat hold, the in-flight subtraction, the one-pair-at-a-time rule,
    the editors) and feeds it the WHOLE pending set, exactly as ``gdpr-pipeline.py hide-batch`` does, because
    ``hide_batch.open_prs`` is written for that contract. Only the CARD is narrowed to this ask's rows: a batch for
    everybody's pages would name a page no one asked about in this thread, but a batch holding ONLY this ask's pages
    would make ``open_prs`` close the open pair as superseded and reopen one carrying just those pages, leaving every
    other row's page in no PR at all until the next full batch. ``--include-legal`` is never passed: a legal_threat
    page is the captain's call and this path does not make it."""
    mine = {r["id"] for r in rows if r["status"] == "open"}
    if not mine:
        return {"batch": [], "ids": [], "prs": {}, "why": "no open register row for this ask"}
    allrows = [r for r in run.store.all() if r["status"] == "open"]
    hd, pdp = sources.hidden_lists()
    my_pages = {pv["id"] for r in allrows if r["id"] in mine
                for pv in r["verdict_detail"] if pv["verdict"] in IDENTITY_PASS}
    # Two passes, the same shape as the nightly path: plan everything to learn what is in play, ask GitHub what is
    # already in an open PR for those pages, then plan again with that subtraction.
    cand = hide_batch.plan(allrows, hd, pdp, {})
    in_flight = hide_batch.in_flight_ids([c["id"] for c in cand]) if cand else {}
    planned = hide_batch.plan(allrows, hd, pdp, in_flight)
    batch = [b for b in planned if b["request_id"] in mine]
    by_id = {r["id"]: r for r in allrows}
    covered = sorted({by_id[b["request_id"]]["register_no"] for b in planned
                      if b["id"] in my_pages and b["request_id"] in by_id and b["request_id"] not in mine})
    open_pr = sorted(p for p in my_pages
                     if p in in_flight.get("hdevops", set()) or p in in_flight.get("pdp", set()))
    already_hidden = bool(my_pages) and all(p in hd and p in pdp for p in my_pages)
    if not batch:
        # A page planned under ANOTHER row is only "covered" once something is actually in flight for it. With no
        # open PR and the page on neither list, returning "that row's hide is the one in flight" claimed a hide that
        # did not exist and exited 0 without a URL -- the page reached no PR at all (QA 5904134453, Important). The
        # whole planned set goes to open_prs, exactly as the nightly path does; only the CARD narrows to this ask.
        if covered and not open_pr and not already_hidden:
            res = hide_batch.open_prs(planned, dry_run=not apply, ask=ask)
            return {"batch": [], "ids": sorted(my_pages), "prs": res, "why": ""}
        if covered:
            return {"batch": [], "ids": [], "prs": {},
                    "why": "this page is already covered by register "
                           + ", ".join(f"#{n}" for n in covered)
                           + ": that row's hide is the one in flight, so this ask opens no second PR"}
        if open_pr:
            return {"batch": [], "ids": [], "prs": {},
                    "why": "a hide PR for " + ", ".join(open_pr)
                           + " is already open, so this ask opens no second one (the in-flight lookup names the "
                             "pages, not the PR URLs)"}
        if already_hidden:
            return {"batch": [], "ids": [], "prs": {},
                    "why": "every identity-PASS profile page in this ask is already on both hide lists"}
        return {"batch": [], "ids": [], "prs": {},
                "why": "no identity-PASS profile page in this ask is eligible for a hide-list PR (not a profile "
                       "page, not PASS, or the register is holding it for a human)"}
    # The whole planned set goes to open_prs; this ask's pages are what the caller reports and cards.
    res = hide_batch.open_prs(planned, dry_run=not apply, ask=ask)
    return {"batch": batch, "ids": [b["id"] for b in batch], "prs": res, "why": ""}


def card(ask: str, ids: list[str], rows: list[dict], prs: dict, hidden: str, letter: str) -> str:
    """The thread line the ops channel gets, in the one format the lane defines."""
    regs = ", ".join(f"#{r['register_no']}" for r in rows if r.get("register_no")) or "pending"
    urls = " ".join(u for u in (prs.get("hdevops"), prs.get("pdp")) if isinstance(u, str) and u.startswith("http"))
    if not urls and prs.get("deferred"):
        urls = "deferred: " + " ".join(f"{k}={v}" for k, v in prs["deferred"].items())
    return (f"gdpr-hide · {ask} · {len(ids)} ids · register {regs} · PRs {urls or 'none yet'} · "
            f"hidden_at {hidden} · letter {letter}")


def post_card(text: str) -> bool:
    """Best effort, and never a silent success: the card is always printed to stdout too."""
    try:
        sys.path.insert(0, str(SCRIPTS))
        from lib.slack_token import _from_env_file  # noqa: PLC0415
    except ImportError:
        return False
    tok = os.environ.get("MUSO_SLACK_BOT_TOKEN_OPERATIONS") or _from_env_file(
        "MUSO_SLACK_BOT_TOKEN_OPERATIONS", "/etc/openclaw/main.env")
    if not tok:
        return False
    import urllib.request  # noqa: PLC0415
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps({"channel": os.environ.get("GDPR_HIDE_CARD_CHANNEL", ""), "text": text,
                         "unfurl_links": False}).encode(),
        headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json; charset=utf-8"})
    try:
        return bool(json.load(urllib.request.urlopen(req, timeout=30)).get("ok"))
    except Exception:  # noqa: BLE001  -- a card that could not be posted must not lose the register rows
        return False


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ask-id", default="",
                    help="a label for the ask, appended to the derived key (idempotence for a re-run of the same ask)")
    ap.add_argument("--requester-id", required=True,
                    help="the Slack user id of the person asking; verified against the message author")
    ap.add_argument("--requester-name", default="")
    ap.add_argument("--message-ts", default="",
                    help="the requester's own message ts: the identity anchor, the audit anchor and the clock")
    ap.add_argument("--channel", default="", help="the Slack channel the ask came from (identity lookup + ask id)")
    ap.add_argument("--conversation", default="", help="the Intercom conversation this ask links, if any")
    ap.add_argument("--store", default=os.environ.get("GDPR_STORE", DEFAULT_PATH))
    ap.add_argument("--apply", action="store_true", help="file/attach the rows and decide (default: dry run)")
    ap.add_argument("--open-prs", action="store_true", help="with --apply: open the hide-list PRs for this ask")
    ap.add_argument("--post-card", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--now", default="", help="testing seam: pin the clock (ISO-8601 Z)")
    a = ap.parse_args(argv)

    now = (datetime.strptime(a.now, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
           if a.now else datetime.now(timezone.utc))

    # --- who is asking (tier R) -------------------------------------------------
    allow = staff_approvers()
    if a.requester_id not in allow:
        print(f"REFUSED (tier R): {a.requester_id!r} is not staff ({', '.join(allow)}). A hide request from a "
              f"non-staff id is never acted on, and 'Jan said hide' pasted by someone else is not Jan asking. "
              f"Nothing was filed and nothing is hidden.")
        return 3

    try:
        text = verify_requester(a.requester_id, a.channel, a.message_ts)
    except IdentityUnverified as exc:
        print(f"REFUSED (identity unverified): {exc}. Nothing was filed and nothing is hidden. The requester id must "
              f"be the author of the message the ask names, and the ids and the class are read from THAT message -- "
              f"'Jan said hide' pasted by someone else is not Jan asking, and an unreadable message is not a passed "
              f"check.")
        return 6

    if a.apply and os.path.exists(KILL):
        print(f"held: gdpr-pipeline disabled ({KILL}); nothing filed, nothing hidden")
        return 4

    ids = parse_ids(text)
    if not ids:
        print("REFUSED: the ask names no profile/track id or muso.ai URL. Ask for the exact id (a UUID or a "
              "muso.ai/profile/<id> link); an ask that names no page cannot be registered.")
        return 1

    # --- the two bounds (over => HELD, filed nowhere) ---------------------------
    if len(ids) > MAX_IDS_PER_ASK:
        print(f"held: {len(ids)} ids exceeds the {MAX_IDS_PER_ASK}-id cap for one ask. Nothing filed, nothing "
              f"hidden. Split the ask (and say why a single message names {len(ids)} profiles) — a bulk list is the "
              f"shape of the old bulk DELETE.")
        return 4
    store = Store(a.store, readonly=not a.apply)
    ask = ask_key(a.ask_id, a.requester_id, a.channel, a.message_ts)
    today = now.strftime("%Y-%m-%d")

    # --- what is it (the requester's own words, never a guess) -----------------
    cls, phrase = classify(text)
    if not cls:
        verb = WEAK_VERB_RE.search(text or "")
        why = ("the ask uses only a verb (" + repr(verb.group(0)) + ")") if verb else "the ask states no reason"
        print(f"REFUSED: {why}, and the class decides both the path and the letter the customer gets (GDPR erasure / "
              f"catalog takedown / legal threat). Quote the requester's own words -- or the customer's -- in the ask; "
              f"guessing here would tell a customer we erased their data when we removed one track (or hide a page "
              f"nobody asked us to hide).")
        return 5

    received = epoch_to_iso(a.message_ts, now)

    # The conversation the ask links is how the pipeline learns WHO the customer is. Read once, here, and fail closed:
    # an ask whose conversation cannot be read would file a row nobody can identify, and the run would look green.
    contact: dict = {}
    if a.conversation:
        try:
            contact = sources.conversation(a.conversation)
        except sources.Unknown as exc:
            print(f"REFUSED: cannot read Intercom conversation {a.conversation} ({exc}); without it the register "
                  f"cannot identify the customer. Nothing filed, nothing hidden.", file=sys.stderr)
            return 2
    out = {"ask": ask, "class": cls, "phrase": phrase, "ids": [i for _, i in ids], "rows": [], "prs": {},
           "applied": a.apply}
    run = Run(store, log=lambda *_a, **_k: None)

    filed: list[dict] = []
    # The cap is decided and spent under ONE lock, so two asks arriving together cannot each read the same count and
    # each pass (QA 5903932382, Important: 20 + 20 = 40 > 30). The lock covers the count AND the inserts; the rows stay
    # filed if a later step (identity, PRs) fails, which is why the lock is not held across those.
    # A dry run takes no lock: `register_lock` creates `<store>.cap-lock` and its parent directory, so previewing a
    # fresh store path would leave both behind and a preview against a read-only store dir would fail before printing
    # anything. Nothing is spent by a preview, so there is nothing to serialize (QA 5904316216, Important).
    with (register_lock(a.store) if a.apply else contextlib.nullcontext()):
        # An exact replay of an ask already on the register is not a new ask and must not be charged again: a retry
        # after a failed PR-open would otherwise push the requester past the cap and lock them out of finishing the job
        # they already started. Keys are PER PAGE (`<ask>:<pid>`), not the bare ask, so the check has to be per page
        # too -- matching the bare ask never hit anything and the bug survived a test that only replayed before any
        # row existed. Charge only pages that are new to the register.
        seen_keys = {k for r in store.all() for k in (r.get("keys") or [])}
        fresh = [(ent, pid) for ent, pid in ids if f"{ask}:{pid}" not in seen_keys]
        already = ids_today(store, a.requester_id, today)
        if already + len(fresh) > MAX_IDS_PER_REQUESTER_PER_DAY:
            print(f"held: {a.requester_id} has already filed {already} ids today; this ask's {len(fresh)} new id(s) "
                  f"would take it to {already + len(fresh)} > {MAX_IDS_PER_REQUESTER_PER_DAY}. "
                  f"Nothing filed, nothing hidden.")
            return 4
        for ent, pid in ids:
            cand = candidate(ask, cls, ent, pid, received_at=received, conversation=a.conversation,
                             ts=a.message_ts, requester_name=a.requester_name)
            if contact:
                cand["requester_email"] = contact.get("author_email") or contact.get("contact_email") or ""
                cand["contact_id"] = str(contact.get("contact_id") or "")
                cand["requester_name"] = cand["requester_name"] or contact.get("author_name") or \
                    contact.get("contact_name") or ""
            existing = open_rows_with_page(store, pid, cls)
            replay = store.by_key(cand["keys"][0])
            same = [r for r in existing if same_customer_event(r, a.conversation, contact, received)]
            if not a.apply:
                row = replay or (same[0] if same else None)
                would = ("this exact ask is already on the register" if replay else
                         "note the ask on the customer's existing row" if same else
                         "create its own register row (a different customer holds this page)" if existing else
                         "create a register row")
                out["rows"].append({"id": pid, "entity": ent, "register_no": (row or {}).get("register_no"),
                                    "would": would})
                continue
            if replay is not None:
                # The same Slack message re-run: its per-page key is already on a row, so nothing is filed or charged.
                row = replay
                filed.append(row)
                out["rows"].append({"id": pid, "entity": ent, "register_no": row["register_no"], "how": "unchanged",
                                    "identity": row.get("identity_verdict") or "", "action": row.get("action") or ""})
                continue
            if same:
                # The same customer's request, so no second row and -- per the captain -- no MERGED row either: the ask
                # joins as a note. Copying this ask's key onto that row would re-home a request somebody else created and
                # charge its pages to both requesters; a note records the ask without touching the row's keys or pages.
                rid = same[0]["id"]
                store.event(rid, "ask_noted", ask=ask, requester=a.requester_id, page=pid, message_ts=a.message_ts)
                store.db.commit()
                row = store.get(rid)
                filed.append(row)
                out["rows"].append({"id": pid, "entity": ent, "register_no": row["register_no"], "how": "noted",
                                    "identity": row.get("identity_verdict") or "", "action": row.get("action") or ""})
                continue
            rid, how = store.upsert(cand)
            row = store.get(rid)
            filed.append(row)
            out["rows"].append({"id": pid, "entity": ent, "register_no": row["register_no"], "how": how,
                                "identity": row.get("identity_verdict") or "", "action": row.get("action") or ""})

    if a.apply and filed:
        derived = cli_module()
        run.store = store
        deferred = ""
        try:
            hidden, half = derived.hidden_now(run)
            run.decide_rows(filed, hidden, half=half)
        except (SystemExit, Exception) as exc:  # noqa: BLE001  -- the rows are already committed
            if isinstance(exc, SystemExit):
                deferred = run.errors[-1] if run.errors else "the hide lists could not be read"
            else:
                deferred = f"hide lists: {exc}"
                run.fail("hide lists", exc)
            print(f"  identity NOT decided ({deferred}): the register rows below ARE filed and stand; the daily "
                  f"tick decides them, or a human runs `scripts/gdpr-pipeline.py decide`.", file=sys.stderr)
        for r in filed:
            r.update(store.get(r["id"]) or {})
        out["rows"] = [{"id": pv["id"], "entity": next((p["entity"] for p in r["pages"] if p["id"] == pv["id"]),
                                                        "profile"),
                        "register_no": r["register_no"], "identity": r.get("identity_verdict") or "",
                        "verdict": pv["verdict"], "why": pv.get("why") or "", "action": r.get("action") or ""}
                       for r in filed for pv in (r.get("verdict_detail") or [])]
        if not out["rows"]:
            out["rows"] = [{"id": r["row_key"], "register_no": r["register_no"],
                            "identity": r.get("identity_verdict") or "", "action": r.get("action") or ""}
                           for r in filed]
        if deferred:
            out["identity_deferred"] = deferred

    # --- the hide half: only for PASS pages, and never for a catalog takedown ---
    prs: dict = {}
    if cls == "dmca_takedown":
        out["prs"] = {"why": "catalog takedown, not a profile hide: the track-removal human path "
                             "(a named human removes the DSP anchor); no hide-list PR is opened"}
    elif a.apply and a.open_prs and filed:
        try:
            res = hide_for_rows(filed, run, ask=ask, apply=True)
            prs, out["prs"] = res["prs"], {**res["prs"], "why": res["why"]}
        except sources.Unknown as exc:
            out["prs"] = {"why": f"the hide lists could not be read ({exc}); no PR opened"}
            # No PR exists, so the run did not do the job the caller asked for: exit non-zero or a caller keying on
            # status records a hide that never happened (QA 5903932382, Important). The rows stay filed; only the
            # status changes.
            run.fail("open hide PRs", exc)
        except Exception as exc:  # noqa: BLE001  -- the rows are already committed; a traceback would hide that
            out["prs"] = {"why": f"the hide PRs could not be opened ({exc}); the register rows are filed, so a human "
                                f"must run `scripts/gdpr-pipeline.py hide-batch --open-prs`"}
            run.fail("open hide PRs", exc)
    elif a.apply:
        out["prs"] = {"why": "no PR was opened by this run (--open-prs not given): the pages wait for the daily "
                            "gdpr-hide-batch timer, or a human runs `scripts/gdpr-pipeline.py hide-batch --open-prs` "
                            "now"}

    # WHO OWNS IT. Two verdicts are deliberately not ours, and saying so in the thread is the difference between "the
    # pipeline is working on it" and "nobody is". LEGAL_HIDE_FIRST / JAN_BIGNAME / JAN_REVIEW go to the captain: the
    # hide is his call, no PR is opened here, and an UNKNOWN/ASK_* page is waiting on an identity answer to the
    # customer (the fraud case: a hide request for a page the linked Intercom contact does not own is an ASK, never a
    # hide). Nothing hidden, nothing promised.
    captain = sorted({r["identity"] for r in out["rows"]
                      if r.get("identity") in ("LEGAL_HIDE_FIRST", "JAN_BIGNAME", "JAN_REVIEW")})
    asking = [] if out.get("identity_deferred") else sorted(
        {r["identity"] for r in out["rows"]
         if str(r.get("identity") or "").startswith("ASK_") or r.get("identity") == "UNKNOWN"})
    if captain:
        out["captain"] = captain
        print(f"  captain owns this: {', '.join(captain)} (big name / legal threat) -- no hide-list PR is opened by "
              f"this path; the register row and its deadline stand")
    if asking:
        out["waiting_on_identity"] = asking
        print(f"  waiting on identity: {', '.join(asking)} -- the pipeline asks the customer for the missing proof "
              f"and NO page is hidden until it answers")

    hidden = "pending"
    if filed and all(r.get("hidden_at") for r in filed):
        hidden = max(r["hidden_at"] for r in filed)
    letter = "due"
    if filed and all(store.send_record(r["id"], "confirm") for r in filed):
        letter = "sent"

    line = card(ask, [i for _, i in ids], [{"register_no": r.get("register_no")} for r in (filed or out["rows"])],
                prs, hidden, letter)
    out["card"] = line
    if a.json:
        print(json.dumps(out, indent=2, default=str))
    else:
        for r in out["rows"]:
            would = f" would={r['would']}" if r.get("would") else ""
            print(f"  {r.get('id')}: register #{r.get('register_no')} identity={r.get('identity') or '-'} "
                  f"{('verdict=' + str(r.get('verdict'))) if r.get('verdict') else ''} "
                  f"action={r.get('action') or '-'}{would}")
        if out["prs"].get("why"):
            print(f"  hide: {out['prs']['why']}")
        print(line)
    if a.post_card and a.apply:
        if not post_card(line):
            print("  card NOT posted (no Slack token / channel): the register rows above stand", file=sys.stderr)
    return 2 if run.errors else 0


if __name__ == "__main__":
    sys.exit(main())
