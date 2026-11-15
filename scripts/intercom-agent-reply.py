#!/usr/bin/env python3
"""Send ONE reply an agent composed for ONE Intercom conversation, on the copy gate's signed verdict.

WHY THIS EXISTS. `scripts/intercom-ops-write.sh reply --agent <id> --gate-campaign agent-reply` (hydra#1998)
can post a reply no person approved: the reviewer's signed verdict on the exact bytes is the approval, and the
record names the agent. What it cannot do is claim the shared ledger's one-message-per-person-per-UTC-day slot
(`verify_ledger.capped`), because that rule belongs to the ledger and the writer does not read it. So the first
reply that cleared the gate (conversation 215476322440709, verdict ocv-216dea6bf6f2eb59, 2026-11-15 06:25Z) was
NOT posted: a hand post would have been invisible to every other sender, and the next campaign could have
messaged the same person the same day. This is the caller that closes that gap, and it is the only one.

WHAT IT DOES, IN THIS ORDER (each step can stop the send, and a stop before the POST gives the claim back):
  1. the ledger's own pre-checks, read-only: this conversation already answered (by this campaign or by
     `backlog-reply`, which uses the same `conv-<id>` key), or this person already has a message today;
  2. the copy gate, asked about the exact bytes (`sendgate.require_verdict`, campaign `agent-reply`): no signed
     approve, no claim and no POST. A pending review is a HOLD (exit 3), not a failure;
  3. `verify_ledger.claim` - the atomic claim of the person's day and of this conversation, stamped with the
     verdict that authorized it (`approver_kind=copy-gate`, `approval_id=<verdict id>`);
  4. the one POST, through `intercom-ops-write.sh reply --agent ... --gate-campaign agent-reply` (which asks the
     gate again itself, so the bytes that leave are the bytes that were approved);
  5. `verify_ledger.finalize` with the verdict id, its sha256 and `copy_review=approved`, or - when nothing was
     posted - `hold_copy_review`, which gives the claim back as a `deferred` LOG so the next run may try again.

WHAT IT DOES NOT DO. It composes no copy: the body is the caller's, and the caller answers for whether it is
true for this customer and this thread. It decides nothing about credits, claims or merges. It never posts a
note (that is `intercom-ops-write.sh note`), never closes a conversation, and never sends to a person it cannot
name: an empty identity is a refusal, because a claim with no user key cannot enforce the day cap.

ONE REPLY PER CONVERSATION, EVER. The request id is `conv-<conversation id>`, the same key `backlog-reply`
uses, and both campaigns are checked before the claim. A thread that needs a second agent reply is a decision
for a person, not something this tool does quietly.

Usage (node-8, root):
  set -a; . /etc/openclaw/main.env; set +a
  python3 scripts/intercom-agent-reply.py --conversation 215476322440709 --body-file reply.txt \
      --user-key someone@example.com [--contact-id 65f...] [--user-id 12345] [--agent caroline] [--apply]

Exit codes: 0 sent or deliberately skipped (the JSON says which) · 1 refused (nothing posted; a ledger a
pre-check could not read is one of these) · 2 usage/environment error (a ledger that cannot be opened, or a dry run
that could not read it) · 3 HELD: the copy gate has no signed verdict on these bytes yet · 4 UNCERTAIN: the POST
may have landed, the claim stays held.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from credit_review import verify_ledger  # noqa: E402  the shared message ledger
from outbound_copy import sendgate  # noqa: E402  the ONE caller side of the copy gate

CAMPAIGN = verify_ledger.AGENT_REPLY
GATE_CAMPAIGN = "agent-reply"
# The writer is the only path to the POST. A constant, not a flag: a caller that could point it elsewhere could
# post without the writer's own gate ask, its leak refusal and its api-log-before-POST ordering.
OPS_WRITE = "/opt/hydra/scripts/intercom-ops-write.sh"
LEDGER = verify_ledger.DEFAULT_PATH
CONTACT_KEY_PREFIX = "intercom-contact:"
POSTED_RE = re.compile(r"^POSTED comment conversation=(\d+) part=(\S+)\s*$", re.M)
AGENT_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{1,39}$")


# The claim's day must be the day the reply lands on. A claim at 23:59:59 and a POST at 00:00:01 record a reply on
# a day the customer did not get it and leave the day it did arrive unclaimed, so a second message that day was
# allowed (QA 2026-11-15, carried-forward finding 2). A boundary this close is waited out, so claim and POST land on
# the same day; a boundary further away is not waited for, it is claimed on the day the reply will land on.
MIDNIGHT_GUARD_S = 10


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def seconds_to_midnight(now: datetime) -> float:
    midnight = (now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    return (midnight - now).total_seconds()


def conv_key(conversation_id: str) -> str:
    return f"conv-{conversation_id}"


def user_key_of(user_key: str, contact_id: str) -> str:
    """The person this message counts against. An account email is the key every other campaign uses; a contact
    id is the fallback for a thread with no account, and it is namespaced so it can never collide with an email."""
    key = (user_key or "").strip().lower()
    if key:
        return key
    cid = (contact_id or "").strip()
    return CONTACT_KEY_PREFIX + cid if cid else ""


def already_answered(db, conversation_id: str) -> str:
    """The campaign that already answered this conversation, or ''. Both reply campaigns use `conv-<id>`, so a
    thread the backlog drain answered is not answered again here (and the reverse is true of its own check)."""
    row = db.execute(
        "SELECT campaign FROM verify_requests WHERE request_id=? AND campaign IN (?,?) "
        "AND status IN ('attempted','sent') LIMIT 1",
        (conv_key(conversation_id), CAMPAIGN, verify_ledger.BACKLOG_REPLY)).fetchone()
    return str(row[0]) if row is not None else ""


# No second message to one person within a day of the last one, whatever day the last one is recorded on. The
# per-day cap alone is not enough: a reply claimed at 23:59:45 whose POST is accepted at 00:00:02 is recorded on
# yesterday and the customer receives it today, and a second conversation for that person today would then pass the
# day check (QA 2026-11-15). Measured from the row's own created_at, so a late POST still holds the next day.
REPLY_INTERVAL_HOURS = 24
# The reason prefix of a pre-check that could not read the ledger. Not a skip: nothing was measured.
UNREADABLE = "ledger_unreadable:"


def precheck(db, conversation_id: str, user_key: str, user_id: str, day: str, now: datetime | None = None) -> str:
    """Why this reply must not be claimed ('' when it may). Read-only: nothing is written by a dry run.

    A ledger that cannot be read answers `ledger_unreadable:<error>` from EVERY read here, not only the last one:
    the first two reads used to sit outside the guard, so a ledger missing a table ended the run in a traceback
    instead of a named refusal (reviewer note on 05924c452). `send` turns that reason into `refused`, never
    `skipped`: "could not read whether this person was messaged today" is not "they were"."""
    try:
        answered = already_answered(db, conversation_id)
        if answered:
            return f"conversation_already_answered:{answered}"
        if verify_ledger.capped(db, user_key=user_key, day=day, user_id=user_id):
            return "daily_cap:this_person_already_has_a_message_today"
        since = ((now or utcnow()) - timedelta(hours=REPLY_INTERVAL_HOURS)).strftime("%Y-%m-%dT%H:%M:%SZ")
        row = db.execute(
            "SELECT 1 FROM verify_messages WHERE user_key=? AND status IN ('attempted','sent') AND created_at >= ? "
            "LIMIT 1", (user_key, since)).fetchone()
    except Exception as exc:  # an unreadable ledger is not a reason to send
        return f"{UNREADABLE}{type(exc).__name__}"
    if row is not None:
        return f"recent_reply:this_person_had_a_message_within_{REPLY_INTERVAL_HOURS}h"
    return ""


def post_reply(conversation_id: str, body: str, agent: str, claim, copy: str = "",
               validate: bool = False) -> dict:
    """The ONE customer POST of this file. No signed approval on these exact bytes, no POST.

    The order is the guarantee: the gate is asked about the bytes, the ledger CLAIMS the person's day, and only then
    can the writer POST. Claiming after the POST would let two runs for one person both post and only one of them
    record it (QA 2026-11-15, finding 1). `claim` is called with the permit and returns the ledger's answer."""
    # The writer reads the body with `BODY="$(cat "$BODY_FILE")"`, and a command substitution strips trailing
    # newlines, so a newline-terminated file would be gated on one sha and posted as another: the writer's own ask
    # would find no verdict for the trimmed bytes and hold the reply forever. Normalize here, before the first ask,
    # so the verdict, the writer's ask and the ledger row all name the bytes that are posted (QA 2026-11-15).
    body = body.rstrip("\n")
    permit = sendgate.require_verdict(body, family="agent-reply", campaign=GATE_CAMPAIGN, copy=copy,
                                       message_type="comment", ref=conv_key(conversation_id))
    if not permit.verdict_id:
        # agent-reply is an always-enforced campaign, so an observed permit cannot happen; if the gate's table
        # ever changed, an unapproved send is still not a send here.
        raise sendgate.NotApproved("observed", "agent_reply_needs_a_signed_verdict")
    claimed = claim(permit)
    if claimed.get("result") != "claimed":
        # The gate approved but the ledger will not claim: nothing is posted, and the reason is the ledger's.
        return {"claimed": claimed, "posted": None, "permit": permit}
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".txt", encoding="utf8") as f:
        f.write(body)
        path = f.name
    try:
        argv = [OPS_WRITE, "reply", "--conversation", str(conversation_id), "--agent", agent,
                "--gate-campaign", GATE_CAMPAIGN, "--customer-facing", "--body-file", path]
        if copy:
            argv += ["--gate-copy", copy]
        if validate:
            argv.append("--validate")
        p = subprocess.run(argv, capture_output=True, text=True, check=False)
    finally:
        os.unlink(path)
    return {"claimed": claimed, "permit": permit,
            "posted": {"rc": p.returncode, "stdout": p.stdout or "", "stderr": p.stderr or "",
                       "verdict_id": permit.verdict_id, "verdict_sha256": permit.verdict_sha256,
                       "body_sha256": permit.body_sha256}}


def send(db, *, conversation_id: str, body: str, agent: str, user_key: str, contact_id: str = "",
         user_id: str = "", copy: str = "", day: str = "", now: datetime | None = None) -> dict:
    """Claim, post, finalize. Returns a result dict; `result` is the one word a caller branches on."""
    now = now or utcnow()
    # The claim's day is only a candidate here: it is FIXED at claim time, immediately before the POST, because the
    # copy gate's answer can arrive after midnight and a day fixed before it would leave the day the reply actually
    # went out unclaimed (QA 2026-11-15, carried-forward finding 2). A caller that pins `day` still pins it.
    pinned_day = day
    day = day or now.strftime("%Y-%m-%d")
    key = user_key_of(user_key, contact_id)
    if not key:
        return {"result": "refused", "reason": "no_identity:pass --user-key or --contact-id"}
    why = precheck(db, conversation_id, key, user_id, day, now)
    if why:
        return {"result": "refused" if why.startswith(UNREADABLE) else "skipped", "reason": why}

    def claim(permit) -> dict:
        nonlocal day
        if not pinned_day:
            wait = seconds_to_midnight(utcnow())
            if wait <= MIDNIGHT_GUARD_S:
                time.sleep(wait + 0.2)
        day = pinned_day or utcnow().strftime("%Y-%m-%d")
        return verify_ledger.claim(
            db, user_key=key, day=day, request_ids=[conv_key(conversation_id)], message_type="comment",
            approved_by=permit.verdict_id, approval_ref=f"copy-gate:{permit.verdict_id}",
            contact_id=contact_id, campaign=CAMPAIGN, user_id=user_id, conversation=str(conversation_id),
            copy_ref=copy, approver_kind=verify_ledger.APPROVER_COPY_GATE, approval_id=permit.verdict_id,
            template_sha256=verify_ledger.template_identity_sha256(
                campaign=CAMPAIGN, kind="initial", copy_ref=copy, variant=""),
            # the rolling interval is enforced INSIDE the claim's transaction, so two runs that both passed the
            # precheck cannot both post (QA 2026-11-15)
            min_interval_hours=REPLY_INTERVAL_HOURS)

    try:
        out = post_reply(conversation_id, body, agent, claim, copy)
    except sendgate.NotApproved as exc:
        # Nothing was claimed, so there is nothing to give back. A pending review is a hold, not a refusal.
        return {"result": "held" if exc.result == "pending" else "refused",
                "reason": f"copy_gate:{exc.result}:{exc.reason}"}
    if out["posted"] is None:
        c = out["claimed"]
        return {"result": "skipped", "reason": f"ledger:{c.get('result')}:{c.get('reason', '')}".rstrip(":")}
    posted = out["posted"]
    row = int(out["claimed"]["message_row"])
    if posted["rc"] == 0:
        m = POSTED_RE.search(posted["stdout"])
        if m is None:
            # The writer exited 0 without its POSTED line: the reply may have landed, so the day stays held.
            verify_ledger.finalize(db, message_row=row, status="attempted", conversation_id=str(conversation_id),
                                   reason="posted_line_unreadable", body_sha256=posted["body_sha256"],
                                   copy_verdict_id=posted["verdict_id"],
                                   copy_verdict_sha256=posted["verdict_sha256"], copy_review="approved", now=utcnow())
            return {"result": "uncertain", "reason": "writer_exit_0_without_POSTED_line", "message_row": row}
        verify_ledger.finalize(db, message_row=row, status="sent", message_id=m.group(2),
                               conversation_id=str(conversation_id), body_sha256=posted["body_sha256"],
                               copy_verdict_id=posted["verdict_id"],
                               copy_verdict_sha256=posted["verdict_sha256"], copy_review="approved", now=utcnow())
        return {"result": "sent", "part": m.group(2), "message_row": row,
                "verdict_id": posted["verdict_id"]}
    if posted["rc"] == 4:
        # The POST may have landed (a dropped connection, a wrong part_type): the day stays held, never retried blind.
        verify_ledger.finalize(db, message_row=row, status="attempted", conversation_id=str(conversation_id),
                               reason="post_failed_or_wrong_part_type", body_sha256=posted["body_sha256"],
                               copy_verdict_id=posted["verdict_id"],
                               copy_verdict_sha256=posted["verdict_sha256"], copy_review="approved", now=utcnow())
        return {"result": "uncertain", "reason": "writer_rc4_post_may_have_landed", "message_row": row}
    # 1 (refused), 2 (usage/environment) or 3 (held): the writer posted nothing, so give the claim back.
    # ONLY those three: any other code (a signal, a crash, an exit the writer does not document) means it may have
    # posted before it died, and a released claim there is a second reply to the same person on the same day
    # (QA 2026-11-15, carried-forward finding 1).
    if posted["rc"] not in (1, 2, 3):
        verify_ledger.finalize(db, message_row=row, status="attempted", conversation_id=str(conversation_id),
                               reason=f"writer_rc{posted['rc']}_post_may_have_landed",
                               body_sha256=posted["body_sha256"], copy_verdict_id=posted["verdict_id"],
                               copy_verdict_sha256=posted["verdict_sha256"], copy_review="approved", now=utcnow())
        return {"result": "uncertain", "reason": f"writer_rc{posted['rc']}_post_may_have_landed",
                "message_row": row}
    verify_ledger.hold_copy_review(db, message_row=row,
                                   reason=f"copy_review:writer_rc{posted['rc']}",
                                   body_sha256=posted["body_sha256"])
    return {"result": "held" if posted["rc"] == 3 else "refused",
            "reason": f"writer_rc{posted['rc']}:{(posted['stderr'] or posted['stdout']).strip()[:300]}",
            "message_row": row}


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Send one agent-composed Intercom reply on the copy gate's signed verdict.")
    p.add_argument("--conversation", required=True, help="Intercom conversation id")
    p.add_argument("--body-file", required=True, help="the reply text, exactly as it will be posted")
    p.add_argument("--agent", default="caroline", help="the agent that composed it (recorded, never an approval)")
    p.add_argument("--user-key", default="", help="the person's account email (the ledger's day-cap key)")
    p.add_argument("--contact-id", default="", help="Intercom contact id, when there is no account email")
    p.add_argument("--user-id", default="", help="Muso account id, when known")
    p.add_argument("--copy", default="", help="the frame/line key the gate reviews these bytes under")
    p.add_argument("--ledger", default=LEDGER)
    p.add_argument("--apply", action="store_true", help="actually claim and post (default: read-only dry run)")
    p.add_argument("--json", action="store_true", help="print the result as one JSON object")
    a = p.parse_args(argv)

    if not str(a.conversation).isdigit():
        print("ERROR: --conversation must be an Intercom conversation id (digits)", file=sys.stderr)
        return 2
    if not AGENT_RE.match(a.agent or ""):
        print("ERROR: --agent must be a lower-case agent/job name (2-40 chars: a-z 0-9 . _ -)", file=sys.stderr)
        return 2
    try:
        with open(a.body_file, encoding="utf8") as f:
            body = f.read()
    except OSError as exc:
        print(f"ERROR: cannot read --body-file: {type(exc).__name__}", file=sys.stderr)
        return 2
    if not body.strip():
        print("ERROR: the body is empty; nothing to send", file=sys.stderr)
        return 2
    key = user_key_of(a.user_key, a.contact_id)
    if not key:
        print("ERROR: pass --user-key (the account email) or --contact-id: a claim with no identity cannot "
              "enforce the one-message-per-person-per-day rule", file=sys.stderr)
        return 2

    day = utcnow().strftime("%Y-%m-%d")  # the dry run reads the day the run is in; --apply lets the claim decide
    try:
        db = verify_ledger.connect(a.ledger) if a.apply else verify_ledger.connect_ro(a.ledger)
    except (sqlite3.Error, verify_ledger.ReadOnlyLedgerError, OSError) as exc:
        print(f"ERROR: cannot open the ledger: {type(exc).__name__}", file=sys.stderr)
        return 2
    if not a.apply:
        why = precheck(db, a.conversation, key, a.user_id, day)
        unread = why.startswith(UNREADABLE)
        out = {"result": "dry_run", "would_send": not why, "reason": why, "user_key": key,
               "conversation": a.conversation, "body_sha256": hashlib.sha256(body.encode("utf-8")).hexdigest()}
        said = "would send" if not why else ("not measured: " if unread else "would skip: ") + why
        print(json.dumps(out, sort_keys=True) if a.json else
              f"DRY-RUN {said} conversation={a.conversation} user_key={key} body_sha256={out['body_sha256']}")
        return 2 if unread else 0  # a ledger nobody could read is an environment error, never "would skip"

    out = send(db, conversation_id=a.conversation, body=body, agent=a.agent, user_key=a.user_key,
               contact_id=a.contact_id, user_id=a.user_id, copy=a.copy, day="")
    out.update({"conversation": a.conversation, "user_key": key, "agent": a.agent})
    if a.json:
        print(json.dumps(out, sort_keys=True))
    else:
        print(f"{out['result'].upper()} conversation={a.conversation} user_key={key} "
              f"reason={out.get('reason', '')}".rstrip())
    return {"sent": 0, "skipped": 0, "held": 3, "refused": 1, "uncertain": 4}.get(out["result"], 1)


if __name__ == "__main__":
    sys.exit(main())
