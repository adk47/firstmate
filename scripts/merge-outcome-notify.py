#!/usr/bin/env python3
"""Tell the customer, in their own thread, how their merge request ended
(Fable ops-takeover 2026-10-19 §4 step 4, firstmate 045).

The merge executor (cmux-credit-system-lane) works profile-merge / unmerge-request /
track-merge tickets and records the result on the ClickUp ticket with exactly ONE tag:

  merge-outcome:merged          done (what changed; reply here if it looks wrong)
  merge-outcome:needs-evidence  we need something before we can do it
  merge-outcome:not-merged      we looked and couldn't confirm it (or these appear to
                                be two recordings / not a wrong merge)

and, with it, the day the outcome was recorded: `merge-outcome-at:<YYYY-MM-DD>` (UTC).
ClickUp's API exposes no tag-add history, so that tag is the outcome's age. An outcome
with no readable date, or older than 7 days, is never messaged: it is listed in the run
summary as "stale outcome, for a human". Age is counted from the START of that UTC day,
so a date can only make an outcome look older, never fresher.

First run (no state file): every ticket whose outcome is older than 24h is recorded as
seen ("seeded") without a message, and listed; outcomes newer than that are sent
normally. A dry run prints the seed but writes nothing.

Nothing is dropped silently. Every ticket this notifier will never message (seeded at
unlock, or skipped for good: no conversation, no email, a ticket email that differs from
the conversation's author, outcome older than 7 days, undated, or an ambiguous/unknown
outcome) is, in the same run, recorded as "seeded" / "skipped" / "skipped-tags" in the
state file and tagged `merge-outcome-notifier-skipped`. An undated, stale or ambiguous
outcome is only skipped once the ticket's date_updated is more than 30 minutes old
(ClickUp tags land one POST at a time); before that it is left for the next run. A
"skipped-tags" ticket whose tags later become valid (one outcome, a fresh date) has its
skip cleared (state only after the ClickUp untag succeeded) and is sent normally, but only
if it was never posted to #cs_priority: a flagged ticket is never auto-sent later; it is
listed once more in the run summary as "flagged earlier, left with the human" and its
skip becomes permanent. An attempted or sent ticket is never re-marked. The
legacy 'merge complete' path (scripts/dedup/sweeps/notify-merged-customers.py) then
handles skipped profile-merge/merged ones at once (never an email-mismatch one: that note
would message the mismatched address): it defers only to an outcome this notifier has
sent or still will send (owns_outcome). Each such ticket is posted to Slack #cs_priority
once (ids + kind/outcome + skip reason, no emails; posted ids and each ticket's skip reason
are kept in the state file). A failed Slack post or skip tag fails the run (exit 3); the
Slack post is retried next run with the same reason.

Keep conflicts: when create_ticket (support-tools, edge) files a merge request that overlaps
an open one in the same conversation but keeps a different profile / track, it tags BOTH
tickets `merge-keep-conflict` and `merge-keep-conflict-with:<other id>` (the edge gateway holds
no Slack token). The hold rule is scripts/lib/merge_keep_conflict.py: a ticket carrying the tag,
or whose OPEN sibling still does, is held here (never messaged, nothing recorded); a closed
sibling never holds. A human reconciles by closing the rejected ticket and removing the tag
from the kept one. Each active pair is posted to #cs_priority once (pair ids kept in the
state file; a failed post fails the run and is retried), flagged "tagging incomplete" when a
side lacks its `-with:` tag; a resolved pair is never listed again. When create_ticket could
not hold a keep conflict it spools a record (MERGE_KEEP_CONFLICT_SPOOL, default
/var/lib/hydra/merge-intake/keep-conflict-unflagged): nothing was filed, and (left_held) any
ticket the failed filing tagged and could not release stays held, for a human to check. When it
could not write a follow-up's merge targets into an open ticket's description it tags that ticket
`merge-intake-stale` (held here like `merge-keep-conflict`) and spools an intake_unwritten record
(held: whether the tag landed). Each record is
posted to #cs_priority once (naming every ticket in it), recorded in the state file, and
removed only after the post succeeded.

This posts the FIXED copy for that (kind, outcome) as Caroline, then tags the ticket
`merge-outcome-notified`. One message per (ticket, outcome), and exactly one follow-up
transition: a ticket whose only sent note was the needs-evidence ask may later get its
merged or not-merged note once (never after it was posted to #cs_priority). Every other
repeat stays blocked. The outcomes sent per ticket are kept in the state file (a ticket
recorded before that has none, so it gets no follow-up). At most one message per customer
email per UTC day; a later one waits for the next day. The copy has no placeholders (no
names, no ids, no dates), so nothing a customer or the executor typed can reach the
message.

Delivery: an admin reply in the SAME Intercom thread the ticket was filed from. A reply
to a closed or snoozed conversation reopens it, so a closed/snoozed thread is not a skip
reason here; there is no separate email.

MERGE_OUTCOME_COPY_APPROVED gates --apply: when False, --apply is refused and the
default dry run lists exactly what would be sent.

Safety (same gates as resolve-notify.py, whose helpers this reuses):
  - exactly one action:<merge kind> tag and exactly one merge-outcome:* tag;
  - the conversation id from the ticket's Intercom link; the ticket's customer_email
    must equal the conversation's source author email (wrong-customer guard);
  - never a conversation assigned to a human, one where a human admin spoke last, or
    one with a blocked tag (closed/snoozed is fine: the reply reopens it);
  - the ticket is recorded "attempted" (fsync'd) BEFORE the single-attempt POST and
    "sent" after it; an attempted ticket is never posted again, a sent one only for the
    single needs-evidence follow-up above. A failed or timed-out POST may have been
    delivered, so it is reported (attempted-unconfirmed) for a human, never retried;
  - never a ticket the customer was already told about ("already-told"): one tagged
    customer-outcome:complete, or a profile-merge/merged ticket whose conversation already
    holds Caroline's legacy 'merge complete' note (from
    scripts/dedup/sweeps/notify-merged-customers.py) posted after the ticket was created;
  - one run at a time (lock next to the state file), at most one post per
    conversation per run, per-run cap;
  - paid-first, oldest-first: ClickUp priority (the executor sets urgent/high for paid),
    then ticket creation time.

Env: CLICKUP_API_KEY, MUSOAI_INTERCOM_TOKEN (required); CLICKUP_LIST_ID (default
901000600160); MERGE_OUTCOME_STATE (default /var/lib/merge-outcome-notify/notified.json);
MERGE_OUTCOME_MAX (default 25). Scheduled by merge-outcome-notify.timer
(scripts/install-aux-units.sh, every 15 min, --apply).
MERGE_OUTCOME_SLACK_CHANNEL (default C0BBTAVP44X, #cs_priority); MERGE_OUTCOME_SLACK_ACCOUNT
(default operations); SLACK_NOTIFY_CONFIG (default /root/.openclaw-main/openclaw.json).
Exit codes: 0 ok; 1 usage/env error or refused; 3 at least one post (Intercom or Slack)
failed.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import itertools
import json
import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from lib import clickup_client, merge_keep_conflict as mkc  # noqa: E402
_spec = importlib.util.spec_from_file_location("resolve_notify", HERE / "resolve-notify.py")
rn = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rn)  # type: ignore[union-attr]

# Approved: firstmate 2026-10-19 ~20:45Z (inbox 057), under the captain's standing order
# of 2026-10-19 17:24Z (Caroline talks to users, AI orchestrates, no per-message human
# gate for these templated outcomes; free-text replies keep the intercom-ops-write gate).
MERGE_OUTCOME_COPY_APPROVED = True
KINDS = ("profile-merge", "unmerge-request", "track-merge")
OUTCOMES = ("merged", "needs-evidence", "not-merged")
NOTIFIED_TAG = "merge-outcome-notified"
SKIPPED_TAG = "merge-outcome-notifier-skipped"
CUSTOMER_COMPLETE_TAG = "customer-outcome:complete"
OUTCOME_AT_PREFIX = "merge-outcome-at:"
KEEP_CONFLICT_TAG = mkc.KEEP_CONFLICT_TAG
KEEP_CONFLICT_WITH = mkc.KEEP_CONFLICT_WITH
INTAKE_STALE_TAG = mkc.INTAKE_STALE_TAG
DEFAULT_SPOOL = "/var/lib/hydra/merge-intake/keep-conflict-unflagged"
MAX_OUTCOME_AGE_S = 7 * 86400
SEED_AGE_S = 86400
SETTLE_S = 30 * 60
DEFAULT_SLACK_CHANNEL = "C0BBTAVP44X"  # #cs_priority
LEGACY_DONE_TEXT = "just confirming your profile merge request is done"
DEFAULT_STATE = "/var/lib/merge-outcome-notify/notified.json"

# Fixed copy, reviewed as a set (data/credit-trust-caroline-t06/copy-merge-outcomes-1019.md).
# No em dashes, no dates, no promises, no placeholders. Each message is an in-thread
# Intercom reply that reopens a closed/snoozed conversation; no separate email is sent.
ATTEMPTED, SENT, SEEDED, SKIPPED, TAGS_SKIPPED = "attempted", "sent", "seeded", "skipped", "skipped-tags"
FOR_GOOD = {"seeded": "seeded", "no-conv": "no conversation", "no-email": "no email",
            "ambiguous-outcome": "ambiguous outcome"}
SETTLING = ("stale-outcome", "ambiguous-outcome")
NEEDS_EVIDENCE = "needs-evidence"
FOLLOW_UPS = ("merged", "not-merged")
COPY = {
    ("profile-merge", "merged"): (
        "Hi! Your profiles are now merged: the credits from the duplicate profile now show on your "
        "main profile. If this isn't what you wanted, just reply here and we'll take another look."),
    ("profile-merge", "needs-evidence"): (
        "Hi! Before we can merge these profiles, we need one thing that shows the other profile is "
        "also you. Any one of these works: a link from your Spotify for Artists or Apple Music for "
        "Artists account showing it, a release page or credit listing that names you on it, or a "
        "message from your label or distributor. Just reply here with it."),
    ("profile-merge", "not-merged"): (
        "Hi! We looked at both profiles carefully, and we couldn't confirm both profiles belong to "
        "you, so we haven't merged them. If they are both yours, reply here with something that "
        "shows it, for example a Spotify for Artists or Apple Music for Artists link, and we'll take "
        "another look."),
    ("unmerge-request", "merged"): (
        "Hi! We've separated the profiles again, so each one has its own credits back. If anything "
        "still looks mixed up, just reply here and we'll take another look."),
    ("unmerge-request", "needs-evidence"): (
        "Hi! To separate these profiles we need to know which credits belong to the other artist. A "
        "link to their artist page on Spotify or Apple Music, or a few track titles that aren't "
        "yours, is enough. Just reply here with it."),
    ("unmerge-request", "not-merged"): (
        "Hi! We looked into this and the credits on your profile appear to be yours, so we've left it "
        "as it is. If something still looks wrong, reply here with the track titles that aren't "
        "yours and we'll take another look."),
    ("track-merge", "merged"): (
        "Hi! The duplicate listings of your track are now merged into one, with their credits and "
        "stats combined. If this isn't what you wanted, just reply here and we'll take another look."),
    ("track-merge", "needs-evidence"): (
        "Hi! Before we merge these tracks, we need one thing that shows they're the same recording, "
        "for example the ISRC of each, or links to both on Spotify or Apple Music. Just reply here "
        "with it."),
    ("track-merge", "not-merged"): (
        "Hi! We looked at both tracks carefully and they appear to be different recordings, so we've "
        "kept them separate. If we've got that wrong, reply here with the ISRC of each and we'll "
        "take another look."),
}
assert set(COPY) == {(k, o) for k in KINDS for o in OUTCOMES}
assert not any("—" in v or "–" in v for v in COPY.values())


def _tags(task: dict) -> set[str]:
    return {str(t.get("name", "")).strip().lower() for t in (task.get("tags") or [])}


def outcome_at(tags: set[str]) -> float | None:
    """Epoch of the start of the UTC day in the single merge-outcome-at:<YYYY-MM-DD> tag."""
    dates = [t[len(OUTCOME_AT_PREFIX):] for t in tags if t.startswith(OUTCOME_AT_PREFIX)]
    if len(dates) != 1:
        return None
    try:
        day = datetime.strptime(dates[0], "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    return day.timestamp()


def outcome_fresh(tags: set[str], now: float) -> bool:
    """Exactly one readable merge-outcome-at date, within MAX_OUTCOME_AGE_S."""
    at = outcome_at(tags)
    return at is not None and now - at <= MAX_OUTCOME_AGE_S


def owns_outcome(task: dict, now: float | None = None, state_path: str | None = None) -> bool:
    """This notifier has sent, or still has a pending sendable outcome for, this ticket."""
    if NOTIFIED_TAG in _tags(task):
        return True
    try:
        state = load_state(state_path or os.environ.get("MERGE_OUTCOME_STATE", DEFAULT_STATE)) or State()
    except SystemExit:
        state = State()
    if state.done.get(str(task.get("id") or "")) in (ATTEMPTED, SENT):
        return True
    c, _ = candidate(task, state, time.time() if now is None else now)
    return c is not None


def keep_conflicts(tasks: list[dict]) -> tuple[set[str], dict[tuple[str, str], bool]]:
    """(ids held, {active pair: tagging complete}): scripts/lib/merge_keep_conflict.py."""
    return mkc.analyse(tasks)


def candidate(task: dict, state: "State", now: float, seeding: bool = False,
              held: set[str] | frozenset[str] = frozenset()) -> tuple[dict | None, str | None]:
    """(candidate, None) when the TICKET-side gates pass, else (None, reason)."""
    done, flagged = state.done, state.flagged
    tags = _tags(task)
    if "hydra-action-request" not in tags:
        return None, "not-action-request"
    kinds = sorted(t.split(":", 1)[1] for t in tags if t.startswith("action:"))
    if len(kinds) != 1 or kinds[0] not in KINDS:
        return None, "action-type"
    tid = str(task.get("id") or "")
    if KEEP_CONFLICT_TAG in tags or INTAKE_STALE_TAG in tags or tid.lower() in held:
        return None, "keep-conflict-held"
    outcomes = sorted(t.split(":", 1)[1] for t in tags if t.startswith("merge-outcome:"))
    if not outcomes:
        return None, "no-outcome"
    st = done.get(tid)
    if st == ATTEMPTED:
        return None, "attempted-unconfirmed"
    follow_up = (st == SENT and state.outcomes.get(tid) == [NEEDS_EVIDENCE] and tid not in flagged
                 and len(outcomes) == 1 and outcomes[0] in FOLLOW_UPS)
    if (NOTIFIED_TAG in tags or st == SENT) and not follow_up:
        return None, "already-notified"
    if CUSTOMER_COMPLETE_TAG in tags:
        return None, "already-told"
    if st == SEEDED or (st != TAGS_SKIPPED and (st == SKIPPED or SKIPPED_TAG in tags)):
        return None, "notifier-skipped"
    if len(outcomes) != 1 or outcomes[0] not in OUTCOMES:
        return None, "notifier-skipped" if st == TAGS_SKIPPED else "ambiguous-outcome"
    at = outcome_at(tags)
    if seeding and at is not None and now - at > SEED_AGE_S:
        return None, "seeded"
    if not outcome_fresh(tags, now):
        return None, "notifier-skipped" if st == TAGS_SKIPPED else "stale-outcome"
    if st == TAGS_SKIPPED and tid in flagged:
        return None, "flagged-earlier"
    conv = rn.conv_id_of(task)
    if not conv:
        return None, "no-conv"
    ar = rn.parse_action_request(task.get("description") or task.get("text_content") or "")
    email = str((ar or {}).get("customer_email") or "").strip().lower()
    if not email:
        return None, "no-email"
    try:
        prio = int(((task.get("priority") or {}).get("orderindex")) or 4)
    except (TypeError, ValueError):
        prio = 4
    return {"ticket_id": tid, "conv_id": conv, "email": email, "kind": kinds[0], "outcome": outcomes[0],
            "message": COPY[(kinds[0], outcomes[0])], "priority": prio,
            "created": int(task.get("date_created") or 0), "was_skipped": st == TAGS_SKIPPED,
            "follow_up": follow_up}, None


def legacy_note_in(conv: dict, since: float) -> bool:
    """Caroline posted the legacy 'merge complete' note in this conversation at or after `since`."""
    parts = (conv.get("conversation_parts") or {}).get("conversation_parts") or []
    return any((p.get("author") or {}).get("type") == "admin"
               and str((p.get("author") or {}).get("id")) == rn.CAROLINE_ADMIN_ID
               and LEGACY_DONE_TEXT in str(p.get("body") or "").lower()
               and int(p.get("created_at") or 0) >= since
               for p in parts)


def order(cands: list[dict]) -> list[dict]:
    """Paid-first (the executor sets ClickUp priority urgent/high for paid), then oldest."""
    return sorted(cands, key=lambda c: (c["priority"], c["created"], c["ticket_id"]))


STATES = (ATTEMPTED, SENT, SEEDED, SKIPPED, TAGS_SKIPPED)


class State:
    def __init__(self) -> None:
        self.done: dict[str, str] = {}
        self.flagged: set[str] = set()
        self.reasons: dict[str, str] = {}
        self.outcomes: dict[str, list[str]] = {}
        self.users: dict[str, str] = {}
        self.conflict_pairs: set[str] = set()
        self.spool_posted: set[str] = set()


def user_key(email: str) -> str:
    return hashlib.sha256(email.strip().lower().encode()).hexdigest()[:24]


def utc_day(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d")


def load_state(path: str) -> State | None:
    """None when there is no state file yet. Each ticket entry is {"state", "reason"?,
    "outcomes"?} (outcomes: the notes sent or attempted, in order); an older plain-string
    entry is read as {"state": <string>}. "users" maps a hashed customer email to the UTC
    day it was last messaged."""
    unreadable = f"{path}: unreadable state; refusing (it is what stops a second message)"
    try:
        data = json.loads(Path(path).read_text())
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        data = None
    tickets = data.get("tickets") if isinstance(data, dict) else None
    if not isinstance(tickets, dict):
        raise SystemExit(unreadable)
    state = State()
    for k, v in tickets.items():
        entry = {"state": v} if isinstance(v, str) else v
        if not isinstance(entry, dict) or entry.get("state") not in STATES:
            raise SystemExit(unreadable)
        outcomes = entry.get("outcomes", [])
        if not isinstance(outcomes, list) or any(o not in OUTCOMES for o in outcomes):
            raise SystemExit(unreadable)
        state.done[str(k)] = entry["state"]
        if outcomes:
            state.outcomes[str(k)] = list(outcomes)
        if isinstance(entry.get("reason"), str) and entry["reason"]:
            state.reasons[str(k)] = entry["reason"]
    flagged, users = data.get("flagged", []), data.get("users", {})
    pairs, spooled = data.get("keep_conflict_pairs", []), data.get("spool_posted", [])
    if not all(isinstance(x, list) for x in (flagged, pairs, spooled)) or not isinstance(users, dict):
        raise SystemExit(unreadable)
    state.conflict_pairs = {str(x) for x in pairs}
    state.spool_posted = {str(x) for x in spooled}
    state.flagged = {str(t) for t in flagged}
    state.users = {str(u): str(d) for u, d in users.items()}
    return state


def save_state(path: str, state: State) -> None:
    today = utc_day(time.time())
    tickets = {tid: {"state": st,
                     **({"reason": state.reasons[tid]} if tid in state.reasons else {}),
                     **({"outcomes": state.outcomes[tid]} if state.outcomes.get(tid) else {})}
               for tid, st in sorted(state.done.items())}
    users = {u: d for u, d in sorted(state.users.items()) if d == today}
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=p.parent, prefix=".notified-")
    with os.fdopen(fd, "w") as fh:
        json.dump({"tickets": tickets, "flagged": sorted(state.flagged), "users": users,
                   "keep_conflict_pairs": sorted(state.conflict_pairs),
                   "spool_posted": sorted(state.spool_posted)}, fh)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, p)
    dfd = os.open(p.parent, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def post_reply_once(conv_id: str, message: str, token: str) -> None:
    """One POST, never retried: a timeout may still have been delivered."""
    s, body = rn.http("POST", f"{rn.INTERCOM_API}/conversations/{conv_id}/reply", rn._ic_headers(token),
                      body={"message_type": "comment", "type": "admin",
                            "admin_id": rn.CAROLINE_ADMIN_ID, "body": message}, attempts=1)
    if s not in (200, 201):
        raise RuntimeError(f"intercom reply {conv_id} -> {s}: {body}")


def fetch_merge_tasks(key: str, list_id: str) -> list[dict]:
    """Only the three merge action tags (server-side tag filter), open and closed."""
    cu = clickup_client.shared(key, rn.CLICKUP_API)
    tasks, seen = [], set()
    for kind in KINDS:
        for t in cu.list_tasks(list_id, [("archived", "false"), ("include_closed", "true"), ("subtasks", "false"),
                                         ("order_by", "created"), ("tags[]", f"action:{kind}")], rn.MAX_PAGES):
            if t.get("id") not in seen:
                seen.add(t.get("id"))
                tasks.append(t)
    return tasks


def add_tag(key: str, task_id: str, tag: str) -> None:
    s, _ = clickup_client.shared(key, rn.CLICKUP_API).request("POST", f"/task/{task_id}/tag/{tag}", body={})
    if s not in (200, 201, 204):
        raise RuntimeError(f"clickup tag {task_id} -> {s}")


def remove_tag(key: str, task_id: str, tag: str) -> None:
    s, _ = clickup_client.shared(key, rn.CLICKUP_API).request("DELETE", f"/task/{task_id}/tag/{tag}")
    if s not in (200, 204):
        raise RuntimeError(f"clickup untag {task_id} -> {s}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--apply", action="store_true", help="actually post (refused while the copy is locked)")
    ap.add_argument("--limit", type=int, default=int(os.environ.get("MERGE_OUTCOME_MAX", "25")))
    a = ap.parse_args(argv)
    if a.apply and not MERGE_OUTCOME_COPY_APPROVED:
        print("REFUSED: the merge-outcome copy is not approved for sending yet (MERGE_OUTCOME_COPY_APPROVED "
              "= False). It needs Fable's copy GO and firstmate's approval, landed in a PR that flips it; "
              "the dry run lists what would be sent.")
        return 1
    key, token = os.environ.get("CLICKUP_API_KEY"), os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not key or not token:
        print("CLICKUP_API_KEY and MUSOAI_INTERCOM_TOKEN are required", file=sys.stderr)
        return 1
    state_path = os.environ.get("MERGE_OUTCOME_STATE", DEFAULT_STATE)
    lock = rn._acquire_state_lock(state_path)
    if lock is None:
        print(f"another merge-outcome-notify run holds {state_path}.lock; exiting", file=sys.stderr)
        return 1
    try:
        return _run(a, key, token, state_path)
    finally:
        lock.close()


def _kind_outcome(task: dict) -> str:
    tags = _tags(task)
    kind = ",".join(sorted(t.split(":", 1)[1] for t in tags if t.startswith("action:")))
    outcome = ",".join(sorted(t.split(":", 1)[1] for t in tags if t.startswith("merge-outcome:")))
    return f"{kind}/{outcome}"


LEGACY_FITS = "profile-merge/merged"
EMAIL_MISMATCH = "email mismatch"
FOLLOW_UP = "follow-up after needs-evidence"
NO_LEGACY = (EMAIL_MISMATCH, f"{FOLLOW_UP}, stale", f"{FOLLOW_UP}, undated")


def for_a_human_text(items: list[tuple[str, str, str]]) -> str:
    lines = [f"• <https://app.clickup.com/t/{tid}|{tid}> {ko} ({why}): "
             + ("legacy merge-complete note" if ko == LEGACY_FITS and why not in NO_LEGACY
                else "for a human reply")
             for tid, ko, why in items]
    return (f":warning: merge-outcome-notify: {len(items)} merge outcome(s) were NOT messaged to the "
            f"customer and need a human (seeded = recorded before the notifier went live; stale = "
            f"outcome older than 7 days; undated = no single readable merge-outcome-at tag). They are "
            f"tagged {SKIPPED_TAG}. Only {LEGACY_FITS} ones get the legacy 'merge complete' note from "
            f"scripts/dedup/sweeps/notify-merged-customers.py (it no longer defers them); unmerge, "
            f"track-merge and every other outcome need a human reply (the legacy note does not fit "
            f"them). An {EMAIL_MISMATCH} ticket never gets the legacy note, whatever its kind: it "
            f"would message the mismatched address. Nor does a {FOLLOW_UP} ticket (not tagged: its "
            f"needs-evidence ask was already sent here, so the legacy path defers to this notifier).\n" + "\n".join(lines))


def keep_conflict_text(pairs: list[tuple[str, str]], complete: dict[tuple[str, str], bool],
                       kinds: dict[str, str]) -> str:
    link = lambda tid: f"<https://app.clickup.com/t/{tid}|{tid}>"  # noqa: E731
    lines = [f"• two merge requests with different "
             f"{'tracks' if kinds.get(a) == 'track-merge' else 'profiles'} to keep in one conversation: "
             f"{link(a)}, {link(b)}"
             + ("" if complete.get((a, b)) else f" (tagging incomplete: tag both {KEEP_CONFLICT_TAG} by hand)")
             for a, b in pairs]
    return (f":warning: merge-outcome-notify: {len(pairs)} merge keep conflict(s). Both tickets of each pair "
            f"are held (tag {KEEP_CONFLICT_TAG}): neither is worked or messaged until a human reconciles "
            f"them with the customer: close the ticket you reject and remove {KEEP_CONFLICT_TAG} from the "
            f"one you keep.\n" + "\n".join(lines))


def read_spool(spool: Path) -> list[tuple[Path, dict]]:
    """Keep-conflict records create_ticket spooled because it could not flag the pair in
    ClickUp (it filed nothing). An unreadable record is listed under its file name."""
    out = []
    for f in sorted(spool.glob("*.json")) if spool.is_dir() else []:
        try:
            rec = json.loads(f.read_text())
        except (OSError, ValueError):
            rec = {}
        out.append((f, rec if isinstance(rec, dict) else {}))
    return out


def spool_text(records: list[tuple[Path, dict]]) -> str:
    link = lambda tid: f"<https://app.clickup.com/t/{tid}|{tid}>"  # noqa: E731
    lines = []
    for f, rec in records:
        ids = [str(x) for x in (rec.get("ticket_ids") or []) if str(x).isalnum()]
        conv = str(rec.get("conversation_id") or "?")
        conv = conv if conv.isalnum() else "?"
        if rec.get("intake_unwritten"):
            hold = (f"held for a human ({INTAKE_STALE_TAG})" if rec.get("held") is True
                    else f"NOT held: tag it {INTAKE_STALE_TAG} by hand")
            lines.append(f"• ticket {', '.join(map(link, ids)) or '?'}: the follow-up's merge targets could not be "
                         f"written to the description; {hold}, conversation {conv} ({f.stem})")
            continue
        left = [str(x) for x in (rec.get("left_held") or []) if str(x).isalnum()]
        others = [i for i in ids if i not in left]
        parts = []
        if left:
            parts.append(f"ticket {', '.join(map(link, left))} left held ({KEEP_CONFLICT_TAG}) by a failed "
                         f"merge filing, please check")
        if others or not left:
            parts.append(f"keep-conflict could not be flagged in ClickUp: tickets "
                         f"{', '.join(map(link, others)) or '?'} and the customer's new request (not filed)")
        held = "; held for a human" if others or not left else ""
        lines.append("• " + "; ".join(parts) + f", conversation {conv}{held} ({f.stem})")
    return (f":warning: merge-outcome-notify: {len(records)} merge request(s) create_ticket could not "
            f"file or hold in ClickUp. Reconcile with the customer in the conversation.\n" + "\n".join(lines))


def post_cs_priority(text: str) -> bool:
    return rn.post_slack(text,
                         os.environ.get("MERGE_OUTCOME_SLACK_CHANNEL", DEFAULT_SLACK_CHANNEL),
                         os.environ.get("SLACK_NOTIFY_CONFIG", "/root/.openclaw-main/openclaw.json"),
                         os.environ.get("MERGE_OUTCOME_SLACK_ACCOUNT", "operations"))


def post_for_a_human(items: list[tuple[str, str, str]]) -> bool:
    return post_cs_priority(for_a_human_text(items))


def drain_spool(a: argparse.Namespace, state: State, state_path: str, seeding: bool) -> bool:
    """Post every spooled keep conflict not yet posted (one #cs_priority message), record it
    and remove its file. Runs before any ClickUp read: it depends on Slack only. False when
    the post failed (the records stay for the next run). A first (seeding) run records the
    posted ids with its own state save, never creating the state file early."""
    spool = Path(os.environ.get("MERGE_KEEP_CONFLICT_SPOOL", DEFAULT_SPOOL))
    spooled = [(f, r) for f, r in read_spool(spool) if f.stem not in state.spool_posted]
    if not spooled:
        return True
    text = spool_text(spooled)
    if not a.apply:
        print(f"WOULD FLAG UNFLAGGED KEEP CONFLICTS (Slack): {text}")
        return True
    if not post_cs_priority(text):
        print(f"FAILED: could not post {len(spooled)} spooled keep conflict(s) to Slack; retried next run",
              file=sys.stderr)
        return False
    state.spool_posted.update(f.stem for f, _ in spooled)
    if not seeding:
        save_state(state_path, state)
    for f, _ in spooled:
        try:
            f.unlink()
        except OSError:
            pass
    return True


def _run(a: argparse.Namespace, key: str, token: str, state_path: str) -> int:
    loaded = load_state(state_path)
    seeding = loaded is None
    state = loaded or State()
    done, flagged, reasons = state.done, state.flagged, state.reasons
    now = time.time()
    today = utc_day(now)
    users_today = {u for u, d in state.users.items() if d == today}
    skipped: dict[str, int] = {}
    cands, seeded, stale, to_tag, left_with_human = [], [], [], [], []
    newly_skipped: dict[str, str] = {}
    new_reasons: dict[str, str] = {}
    for_human: list[tuple[str, str, str]] = []
    spool_ok = drain_spool(a, state, state_path, seeding)
    try:
        tasks = fetch_merge_tasks(key, os.environ.get("CLICKUP_LIST_ID", rn.DEFAULT_LIST_ID))
    except Exception as exc:  # noqa: BLE001
        print(f"FAILED: could not read the merge tickets from ClickUp: {str(exc)[:200]}", file=sys.stderr)
        return 3
    held, pair_complete = keep_conflicts(tasks)
    for t in tasks:
        c, why = candidate(t, state, now, seeding, held)
        if c:
            cands.append(c)
            continue
        tid = str(t.get("id") or "")
        if why == "flagged-earlier":
            left_with_human.append(tid)
            continue
        if why in SETTLING and now - int(t.get("date_updated") or 0) / 1000 <= SETTLE_S:
            skipped["settling"] = skipped.get("settling", 0) + 1
            continue
        if why == "stale-outcome" and done.get(tid) == SENT:
            stale.append(tid)
            for_human.append((tid, _kind_outcome(t),
                              f"{FOLLOW_UP}, {'undated' if outcome_at(_tags(t)) is None else 'stale'}"))
            continue
        if why == "stale-outcome":
            stale.append(tid)
            label = "undated" if outcome_at(_tags(t)) is None else "stale"
        elif why in FOR_GOOD:
            label = FOR_GOOD[why]
        else:
            if why == "notifier-skipped":
                if tid not in flagged:
                    for_human.append((tid, _kind_outcome(t), reasons.get(tid)
                                      or (SEEDED if done.get(tid) == SEEDED else SKIPPED)))
                if SKIPPED_TAG not in _tags(t):
                    to_tag.append(tid)
            skipped[why] = skipped.get(why, 0) + 1
            continue
        if why == "seeded":
            seeded.append(tid)
        elif why != "stale-outcome":
            skipped[why] = skipped.get(why, 0) + 1
        newly_skipped[tid] = SEEDED if why == "seeded" else TAGS_SKIPPED if why in SETTLING else SKIPPED
        new_reasons[tid] = label
        for_human.append((tid, _kind_outcome(t), label))
    if seeding:
        print(f"{'SEEDED' if a.apply else 'WOULD SEED'} (first run, outcome older than 24h, not messaged): "
              f"{len(seeded)} {json.dumps(sorted(seeded))}")
    sent, failed, convs = 0, int(not spool_ok), set()
    if newly_skipped and not a.apply:
        print(f"WOULD MARK {SKIPPED_TAG}: {json.dumps(sorted(newly_skipped))}")
    cleared = [c for c in cands if c["was_skipped"]]
    if a.apply:
        for c in cleared:
            try:
                remove_tag(key, c["ticket_id"], SKIPPED_TAG)
            except Exception as exc:  # noqa: BLE001
                failed += 1
                cands.remove(c)
                print(f"FAILED to untag {c['ticket_id']} {SKIPPED_TAG}; skip kept, retried next run: "
                      f"{str(exc)[:200]}", file=sys.stderr)
                continue
            done.pop(c["ticket_id"], None)
            reasons.pop(c["ticket_id"], None)
        for tid, value in newly_skipped.items():
            if done.get(tid) not in (ATTEMPTED, SENT):
                done[tid] = value
                reasons[tid] = new_reasons[tid]
        for tid in left_with_human:
            done[tid] = SKIPPED
        if seeding or newly_skipped or cleared or left_with_human:
            save_state(state_path, state)
        for tid in sorted(set(newly_skipped) | set(to_tag)):
            try:
                add_tag(key, tid, SKIPPED_TAG)
            except Exception as exc:  # noqa: BLE001
                failed += 1
                print(f"FAILED to tag {tid} {SKIPPED_TAG}: {str(exc)[:200]}", file=sys.stderr)
    for c in order(cands):
        if sent >= a.limit:
            skipped["cap"] = skipped.get("cap", 0) + 1
            continue
        if c["conv_id"] in convs:
            skipped["same-conv-this-run"] = skipped.get("same-conv-this-run", 0) + 1
            continue
        user = user_key(c["email"])
        if user in users_today:
            skipped["same-user-today"] = skipped.get("same-user-today", 0) + 1
            continue
        try:
            conv = rn.get_conversation(c["conv_id"], token)
            why = (rn.conversation_suppressed({**conv, "state": "open"}, c["email"], rn.CAROLINE_ADMIN_ID)
                   or ("already-told" if f"{c['kind']}/{c['outcome']}" == LEGACY_FITS
                       and legacy_note_in(conv, c["created"] / 1000) else None))
            if why:
                skipped[why] = skipped.get(why, 0) + 1
                if why == "email-mismatch":
                    for_human.append((c["ticket_id"], f"{c['kind']}/{c['outcome']}", EMAIL_MISMATCH))
                    if c["follow_up"]:
                        continue
                    if not a.apply:
                        print(f"WOULD MARK {SKIPPED_TAG}: {c['ticket_id']} (email mismatch)")
                        continue
                    done[c["ticket_id"]] = SKIPPED
                    reasons[c["ticket_id"]] = EMAIL_MISMATCH
                    save_state(state_path, state)
                    add_tag(key, c["ticket_id"], SKIPPED_TAG)
                continue
            convs.add(c["conv_id"])
            users_today.add(user)
            if not a.apply:
                print(f"WOULD POST ticket={c['ticket_id']} conv={c['conv_id']} {c['kind']}/{c['outcome']}: {c['message']}")
                sent += 1
                continue
            done[c["ticket_id"]] = ATTEMPTED
            state.outcomes[c["ticket_id"]] = state.outcomes.get(c["ticket_id"], []) + [c["outcome"]]
            state.users[user] = today
            save_state(state_path, state)
            try:
                post_reply_once(c["conv_id"], c["message"], token)
            except Exception as exc:  # noqa: BLE001
                failed += 1
                print(f"UNCONFIRMED ticket={c['ticket_id']} conv={c['conv_id']}: the post may have been "
                      f"delivered and is never retried automatically; a human checks the thread "
                      f"({str(exc)[:200]})", file=sys.stderr)
                continue
            done[c["ticket_id"]] = SENT
            save_state(state_path, state)
            sent += 1
            add_tag(key, c["ticket_id"], NOTIFIED_TAG)
        except Exception as exc:  # noqa: BLE001 - one ticket's failure never stops the run
            failed += 1
            print(f"FAILED ticket={c['ticket_id']}: {str(exc)[:200]}", file=sys.stderr)
    new_pairs = sorted(p for p in pair_complete if "|".join(p) not in state.conflict_pairs)
    if new_pairs:
        kinds = {str(t.get("id") or "").lower(): _kind_outcome(t).split("/")[0] for t in tasks}
        text = keep_conflict_text(new_pairs, pair_complete, kinds)
        if not a.apply:
            print(f"WOULD FLAG KEEP CONFLICTS (Slack): {text}")
        elif post_cs_priority(text):
            state.conflict_pairs.update("|".join(p) for p in new_pairs)
            save_state(state_path, state)
        else:
            failed += 1
            print(f"FAILED: could not post {len(new_pairs)} merge keep conflict(s) to Slack; retried next run",
                  file=sys.stderr)
    new_for_human = sorted(i for i in for_human if i[0] not in flagged)
    if new_for_human:
        if not a.apply:
            print(f"WOULD FLAG FOR A HUMAN (Slack): {for_a_human_text(new_for_human)}")
        elif post_for_a_human(new_for_human):
            flagged.update(i[0] for i in new_for_human)
            save_state(state_path, state)
        else:
            failed += 1
            print(f"FAILED: could not post {len(new_for_human)} merge outcome(s) for a human to Slack; "
                  f"retried next run", file=sys.stderr)
    verb = "posted" if a.apply else "would post"
    print(f"merge-outcome-notify: {verb} {sent}, failed {failed}, skipped {json.dumps(skipped, sort_keys=True)}, "
          f"stale outcome, for a human: {json.dumps(sorted(stale))}, "
          f"flagged earlier, left with the human: {json.dumps(sorted(left_with_human))}, "
          f"keep-conflict held: {json.dumps(sorted(held))}, "
          f"keep-conflict tagging incomplete: {json.dumps(['|'.join(p) for p in sorted(pair_complete) if not pair_complete[p]])}")
    return 3 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
