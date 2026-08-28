#!/usr/bin/env python3
"""Deduplicate ClickUp TO DO support tickets by Intercom conversation.

WHY THIS IS NOT "same conversation link -> duplicate"
-----------------------------------------------------
Sharing an Intercom conversation is NOT a duplicate signal. `create_ticket`
(plugins/support-tools/src/tools/create-ticket.ts) already dedupes on
(conversation, actionType) with a 7-day window, so a customer raising three
different asks in one thread is SUPPOSED to get three tickets.

Running the naive "same link -> move to Waiting" rule by hand buried real
customer work: of the 7 pairs it moved historically, 7/7 had DIFFERENT action
types (none were duplicates), and 29 distinct requests ended up in Waiting
against 4 genuine duplicates. Time-of-creation does not separate them either —
5 of those 7 were filed within 4 minutes of each other.

So this sweeper only auto-moves what is provably redundant:

  Tier A — same conversation AND same action type AND the same handoff-ness.
           This is exactly create_ticket's own dedupe key, so a hit means its
           dedupe was escaped (restart, race, API failure). Keep the oldest,
           move the rest. The handoff-ness half matters: create-ticket.ts:196
           deliberately excludes `intercom-auto-handoff` tickets from that
           lookup, so a real ticket sharing an action tag with an older
           auto-handoff was let through ON PURPOSE and is not a duplicate.

  Tier B — a bare `intercom-auto-handoff` escalation ticket on a conversation
           that already carries a real (non-handoff) action ticket.
           create-ticket.ts:201 DELIBERATELY refuses to dedupe against these,
           which is why they accumulate; this is the downstream cleanup.
           Never moved when the conversation has nothing but handoffs.

  Digest — everything else that merely shares a conversation. Reported to
           Slack, NEVER moved.

All writes go through the audited batch helper (clickup_batch_update.py), every
move carries an audit comment, and every move is read back — a ClickUp 200 is
not proof the status changed.
"""
import argparse
import collections
import hashlib
import json
import os
import subprocess
import sys
import traceback
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.intercom_link import conv_id_of  # noqa: E402

CLICKUP_API = "https://api.clickup.com/api/v2"
DEFAULT_LIST_ID = "901000600160"  # User Requests (support board)
SLACK_API = "https://slack.com/api/chat.postMessage"
DEFAULT_SUMMARY_CHANNEL = "C0ANM0PN9L5"  # #cs_chats
# #clio_devops. VERIFIED against the live workspace 2026-08-28: the `operations`
# bot is a member here, so a page actually lands. C0BA8QMV3ME is #prod-alerts
# (Serhii's prod error feed) and `operations` is NOT in it — posting there
# returns channel_not_found, which post_slack swallows as a WARN. A silent
# alert channel makes the circuit breaker and the crash pager decorative.
DEFAULT_ALERT_CHANNEL = "C0ADV2W76G4"
CLICKUP_TASK_URL = "https://app.clickup.com/t/{}"
HANDOFF_TAG = "intercom-auto-handoff"
# "User Email" custom field. Mirrors close-resolved-conversations.py:81.
# create_ticket keys BOTH halves of its dedupe on the customer email —
# sessionTickets.get(sessionId, actionType, customerEmail) (create-ticket.ts:354)
# and lookupOpenTicket's `User Email = customerEmail` filter (create-ticket.ts:182).
# Tier A claims a ticket escaped that dedupe, so it must group on the same key:
# two different customers in one conversation are not each other's duplicates.
USER_EMAIL_FIELD = os.environ.get(
    "CLICKUP_USER_EMAIL_FIELD_ID", "e8618c74-d065-4b75-9a5a-86d658392409")
ACTION_TAG_PREFIX = "action:"
# Historical hand-run peak was 9 moves. More than this means the rule or the
# API is misbehaving — abort with zero writes rather than bulk-move the board.
DEFAULT_MAX_MOVES = 10
# Mirrors DEDUPE_LOOKUP_WINDOW_MS in plugins/support-tools/src/tools/create-ticket.ts:125.
# That lookup only considers open tickets created inside this window: beyond it,
# create_ticket treats a same-type ask as A NEW REQUEST and files a second ticket
# on purpose (create-ticket.ts:122-124). Tier A's whole claim is "this escaped
# create_ticket's dedupe", so it may only fire where that dedupe could have
# fired. Past the window the second ticket is intended, not an escape.
TIER_A_MAX_GAP_MS = 7 * 24 * 60 * 60 * 1000
# ...but NOT for the merge actions. create-ticket.ts:365 skips lookupOpenTicket
# entirely for profile-merge and track-merge (a merged-ticket sweep auto-closes
# those keyed on the ORIGINAL description's ids, so folding a DIFFERENT merge
# request into one could close it unexecuted). Their only dedupe is the
# in-memory SessionTicketRegistry, whose TTL_MS is 24h
# (session-ticket-registry.ts:1). So a second merge request in the same
# conversation more than 24h later is a ticket the producer created ON PURPOSE,
# and burying it loses distinct merge work.
MERGE_ACTIONS = frozenset({"profile-merge", "track-merge"})
TIER_A_MERGE_GAP_MS = 24 * 60 * 60 * 1000


def tier_a_window_ms(atype):
    """The producer's dedupe reach for this action type, in ms."""
    return TIER_A_MERGE_GAP_MS if atype in MERGE_ACTIONS else TIER_A_MAX_GAP_MS
MAX_PAGES = 40
AUDIT_REQUESTER = "clickup-todo-dedupe@hydra-ops"
AUDIT_ACTION = "clickup_todo_dedupe"
# Neither the digest nor an aborted run changes anything on the board, so both
# conditions stand until a human acts. On an hourly timer that is 24 identical
# messages a day into #cs_chats / #clio_devops — the standing-finding alert
# storm this repo has already been bitten by. Re-post an unchanged message at
# most once a day; anything genuinely new has different text and posts at once.
NOTIFY_REPEAT_COOLDOWN_SEC = 24 * 3600
# Paging is on for a real (non-dry-run) invocation; main() narrows it.
_PAGING_ENABLED = True
DEFAULT_NOTIFY_STATE = "/var/lib/hydra/clickup-todo-dedupe-notify.json"
BATCH_HELPER = (Path(__file__).resolve().parent.parent / "workspaces" / "operations"
                / "skills" / "muso-clickup-ticket-sweeper" / "scripts"
                / "clickup_batch_update.py")


def clickup_token():
    tok = os.environ.get("CLICKUP_API_KEY") or os.environ.get("MUSOAI_CLICKUP_API_KEY")
    if not tok:
        sys.exit("CLICKUP_API_KEY or MUSOAI_CLICKUP_API_KEY is required")
    return tok


def fetch_status(token, list_id, status):
    """All non-closed tasks in `status`, deduped by task id.

    ClickUp has served the same task on two adjacent pages (observed
    2026-08-21: 1,458 rows / 1,457 unique ids), so counting rows over-reports.
    """
    seen, out = set(), []
    for page in range(MAX_PAGES):
        q = urllib.parse.urlencode({
            "page": page, "subtasks": "true", "include_closed": "false",
        }) + "&statuses%5B%5D=" + urllib.parse.quote(status)
        req = urllib.request.Request(f"{CLICKUP_API}/list/{list_id}/task?{q}",
                                     headers={"Authorization": token})
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.load(resp)
        batch = body.get("tasks") or []
        for t in batch:
            if t["id"] not in seen:
                seen.add(t["id"])
                out.append(t)
        if body.get("last_page") or not batch:
            break
    else:
        sys.exit(f"paged {MAX_PAGES} times without reaching last_page — refusing to act "
                 f"on a partial scan of '{status}'")
    return out


def action_type(task):
    """The `action:<type>` tag. Authoritative — the [bracket] name prefix is
    cosmetic and drifts from the tag."""
    for tag in task.get("tags") or []:
        name = tag.get("name") or ""
        if name.startswith(ACTION_TAG_PREFIX):
            return name[len(ACTION_TAG_PREFIX):]
    return None


def user_email(task):
    """The "User Email" custom field, or None. Part of Tier A's grouping key."""
    for cf in task.get("custom_fields") or []:
        if cf.get("id") == USER_EMAIL_FIELD and cf.get("value"):
            return str(cf["value"]).strip().lower() or None
    return None


def is_handoff(task):
    return any((t.get("name") or "") == HANDOFF_TAG for t in task.get("tags") or [])


def created(task):
    """Creation epoch-ms, or None when ClickUp gave us nothing orderable.

    Never default a missing value to 0: that sorts the ticket FIRST, silently
    making it the keeper for its whole group and moving the genuinely-oldest
    ticket to Waiting instead. Ordering is what decides which customer request
    survives, so an unorderable group must not be swept at all (see classify).
    """
    raw = task.get("date_created")
    if raw is None or raw == "":
        return None
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None


def classify(tasks):
    """-> (moves, digest_groups, linked_count).

    moves: [{task, keep, tier, conv}] — tickets to move to Waiting.
    digest_groups: [{conv, tasks}] — shared-conversation groups left untouched.
    linked_count: tickets carrying a resolvable conversation link. Returned from
        here rather than recomputed by the caller — conv_id_of() parses custom
        fields and description lines, so a second pass would re-parse ~1,450
        tickets an hour for a number this loop already has.
    """
    by_conv = collections.defaultdict(list)
    linked = 0
    for t in tasks:
        cid = conv_id_of(t)
        if cid:
            linked += 1
            by_conv[cid].append(t)

    moves, digest = [], []
    for conv, group in sorted(by_conv.items()):
        if len(group) < 2:
            continue
        # Fail closed: without a reliable creation order we cannot say which
        # ticket is the original, and guessing moves real customer work. Report
        # the group and move nothing.
        if any(created(t) is None for t in group):
            digest.append({"conv": conv, "tasks": group, "unorderable": True})
            continue
        group = sorted(group, key=lambda t: (created(t), t["id"]))
        moved_ids = set()
        here = []

        # Tier A — same conversation AND same action type. Bucketed by
        # handoff-ness as well as action type: create-ticket.ts:196 DELIBERATELY
        # excludes `intercom-auto-handoff` tickets from its own dedupe lookup
        # ("appending a normal action request onto a human-takeover record would
        # bury it"), so a real ticket sharing an action tag with an older
        # auto-handoff is NOT an escaped dedupe — it is the intended outcome.
        # Without the split, a genuine `support-general` ask filed after the
        # auto-handoff on the same conversation is moved to Waiting as a
        # "duplicate" of the handoff record, which is the exact burying this
        # sweeper exists to prevent. Two handoffs still dedupe against each
        # other, and two real tickets still dedupe against each other.
        by_action = collections.defaultdict(list)
        for t in group:
            by_action[(action_type(t), is_handoff(t), user_email(t))].append(t)
        for (atype, _handoff, email), same in by_action.items():
            # Fail closed on a missing email exactly as on a missing action tag:
            # without it we cannot reproduce create_ticket's key, so we cannot
            # claim its dedupe was escaped.
            if atype is None or email is None or len(same) < 2:
                continue
            # Walk the bucket oldest-first as a chain. Each ticket dedupes against
            # its immediate predecessor, because that is what create_ticket's
            # lookup would have seen (the newest OPEN same-tag ticket inside the
            # window). A gap wider than the window breaks the chain and starts a
            # new canonical — that ticket is an intended new request, not an
            # escape, so it is kept and reported rather than moved.
            keeper = same[0]
            window = tier_a_window_ms(atype)
            for prev, cur in zip(same, same[1:]):
                if created(cur) - created(prev) > window:
                    keeper = cur
                    continue
                here.append({"task": cur, "keep": keeper, "tier": "A", "conv": conv})
                moved_ids.add(cur["id"])

        # Tier B — redundant auto-handoff escalations. Only when a real
        # (non-handoff) ticket survives on this conversation to carry the work.
        survivors = [t for t in group if t["id"] not in moved_ids]
        # An untagged ticket is NOT proof that real action work survives. Tier A
        # already refuses to act on a missing `action:` tag because the tag is
        # the authority; Tier B moving a handoff on the strength of an untagged
        # sibling would assert "conversation already has action ticket X" about a
        # ticket whose action nobody established — and render it as `None` in the
        # audit comment. Same standard in both tiers.
        real = [t for t in survivors
                if not is_handoff(t) and action_type(t) is not None]
        if real:
            for t in survivors:
                if is_handoff(t):
                    here.append({"task": t, "keep": real[0], "tier": "B", "conv": conv})
                    moved_ids.add(t["id"])

        # A Tier A keeper can itself be a redundant handoff that Tier B then
        # moves — a real ticket plus h1/h2 both tagged `action:support-general`:
        # h2 is kept-by h1, and h1 is then moved too. Inherit the surviving
        # keeper AND its tier, or the audit comment and the Slack line send a
        # human chasing a ticket that is also sitting in Waiting. Inheriting the
        # tier keeps the stated reason true: h2 is itself a handoff (Tier A only
        # pairs like with like now), so the Tier B wording is the accurate one.
        # Tier B keepers are never moved, so the walk terminates; `seen` guards
        # the invariant rather than relying on it.
        keeper_of = {mv["task"]["id"]: mv for mv in here}
        for mv in here:
            seen = set()
            while mv["keep"]["id"] in moved_ids and mv["keep"]["id"] not in seen:
                seen.add(mv["keep"]["id"])
                parent = keeper_of[mv["keep"]["id"]]
                mv["keep"], mv["tier"] = parent["keep"], parent["tier"]
        moves.extend(here)

        remaining = [t for t in group if t["id"] not in moved_ids]
        if len(remaining) > 1:
            digest.append({"conv": conv, "tasks": remaining})
    return moves, digest, linked


def audit_comment(mv):
    keep, conv, tier = mv["keep"], mv["conv"], mv["tier"]
    if tier == "A":
        why = (f"duplicate of {keep['id']} — same Intercom conversation {conv} AND same "
               f"action type `{action_type(keep)}`, which is create_ticket's own dedupe key")
    else:
        why = (f"redundant auto-handoff escalation — Intercom conversation {conv} already "
               f"has action ticket {keep['id']} (`{action_type(keep)}`) carrying this work")
    return (f"clickup-todo-dedupe (Tier {tier}): moved to Waiting because it is a {why}. "
            f"Kept: {CLICKUP_TASK_URL.format(keep['id'])} . "
            f"No customer notification was sent. Reopen this ticket if the request is distinct.")


def apply_moves(moves, dry_run):
    """Write via the audited batch helper. Returns its exit code (0 when none)."""
    if not moves:
        return 0
    # requester/action are what the helper writes into its audit trail; without
    # them every hourly write is logged as requester "unknown" / the generic
    # "clickup_ticket_sweep" and is indistinguishable from an agent hand-run.
    payload = {"requester": AUDIT_REQUESTER,
               "action": AUDIT_ACTION,
               "tickets": [{"id": mv["task"]["id"], "status": "waiting",
                            "comment": audit_comment(mv)} for mv in moves]}
    if dry_run:
        print("DRY RUN — batch payload that WOULD be submitted:")
        print(json.dumps(payload, indent=2)[:4000])
        return 0
    if not BATCH_HELPER.exists():
        sys.exit(f"batch helper missing: {BATCH_HELPER}")
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(payload, fh)
        path = fh.name
    try:
        return subprocess.call([sys.executable, str(BATCH_HELPER), "--input", path])
    finally:
        os.unlink(path)


def read_back(token, moves):
    """Re-GET every moved ticket. A 200 from the write is not proof."""
    ok, bad = [], []
    for mv in moves:
        tid = mv["task"]["id"]
        try:
            req = urllib.request.Request(f"{CLICKUP_API}/task/{tid}",
                                         headers={"Authorization": token})
            with urllib.request.urlopen(req, timeout=30) as resp:
                status = (json.load(resp).get("status") or {}).get("status")
        except Exception as exc:  # noqa: BLE001 — a failed read-back is a failure.
            bad.append((tid, f"read-back error: {type(exc).__name__}"))
            continue
        if status == "waiting":
            ok.append(tid)
        else:
            bad.append((tid, status))
    return ok, bad


def _slack_escape(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _read_slack_token(config_path, account):
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        return cfg["channels"]["slack"]["accounts"][account]["botToken"]
    except (OSError, KeyError, ValueError, TypeError):
        return None


def post_slack(text, channel, config_path, account):
    """Best-effort post. NEVER raises. Returns bool."""
    token = _read_slack_token(config_path, account)
    if not token:
        print(f"WARN: no Slack token for '{account}' in {config_path}; notify skipped",
              file=sys.stderr)
        return False
    try:
        req = urllib.request.Request(
            SLACK_API,
            data=json.dumps({"channel": channel, "text": text,
                             "unfurl_links": False, "unfurl_media": False}).encode(),
            headers={"Authorization": f"Bearer {token}",
                     "Content-Type": "application/json; charset=utf-8"},
            method="POST")
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.load(resp)
        if not body.get("ok"):
            print(f"WARN: Slack post failed: {body.get('error')}", file=sys.stderr)
            return False
        return True
    except Exception as exc:  # noqa: BLE001 — best-effort by contract.
        print(f"WARN: Slack post error: {type(exc).__name__}: {str(exc)[:140]}",
              file=sys.stderr)
        return False


def notify_once(text, channel, config_path, account, state_path,
                cooldown=NOTIFY_REPEAT_COOLDOWN_SEC, now=None):
    """post_slack, but suppress a byte-identical re-post inside `cooldown`.

    Fail-open in both directions: an unreadable or unwritable state file posts
    (a missed page is worse than a repeat), and only a post Slack accepted is
    recorded, so a failed post is retried on the next fire.
    """
    now = time.time() if now is None else now
    digest_key = hashlib.sha256(text.encode()).hexdigest()
    state = {}
    try:
        with open(state_path) as f:
            loaded = json.load(f)
        state = loaded if isinstance(loaded, dict) else {}
        prev = state.get(channel)
        prev = prev if isinstance(prev, dict) else {}
        # Bounded BELOW as well as above: a future `at` (clock stepped back, or a
        # corrupt/hand-edited record) makes now-at negative, which would satisfy a
        # bare `< cooldown` and silently mute the page until that future arrives —
        # the opposite of the fail-open contract above.
        age = now - float(prev.get("at", 0))
        if prev.get("sha") == digest_key and 0 <= age < cooldown:
            print(f"notify suppressed for {channel}: unchanged message inside the "
                  f"{cooldown}s repeat cooldown", file=sys.stderr)
            return False
    except (OSError, ValueError, TypeError):
        state = {}

    if not post_slack(text, channel, config_path, account):
        return False
    state[channel] = {"sha": digest_key, "at": now}
    try:
        os.makedirs(os.path.dirname(state_path) or ".", exist_ok=True)
        with open(state_path, "w") as f:
            json.dump(state, f)
    except OSError as exc:
        print(f"WARN: could not persist notify state to {state_path}: "
              f"{type(exc).__name__}", file=sys.stderr)
    return True


def format_summary(tier_a, tier_b, digest, scanned, linked, bad, dry_run):
    lines = []
    head = "ClickUp TO DO dedupe" + (" (dry run)" if dry_run else "")
    lines.append(f"*{head}* — scanned {scanned} TO DO tickets, {linked} with a "
                 f"conversation link.")
    if tier_a:
        lines.append(f"*Tier A — true duplicates moved to Waiting ({len(tier_a)})*")
        for m in tier_a:
            # Truncate before escaping — the other order can cut an &amp; in half.
            name = _slack_escape(str(m["task"].get("name") or "")[:70])
            lines.append(f"• <{CLICKUP_TASK_URL.format(m['task']['id'])}|{m['task']['id']}> "
                         f"`{_slack_escape(action_type(m['task']))}` — "
                         f"kept {m['keep']['id']} ({name})")
    if tier_b:
        lines.append(f"*Tier B — redundant auto-handoff escalations moved ({len(tier_b)})*")
        for m in tier_b:
            lines.append(f"• <{CLICKUP_TASK_URL.format(m['task']['id'])}|{m['task']['id']}> "
                         f"— conversation already has {m['keep']['id']} "
                         f"`{_slack_escape(action_type(m['keep']))}`")
    if digest:
        lines.append(f"*Left in TO DO — shared conversation, distinct requests "
                     f"({len(digest)} group(s))*")
        for g in digest[:10]:
            types = ", ".join(sorted({_slack_escape(action_type(t)) for t in g["tasks"]}))
            ids = ", ".join(t["id"] for t in g["tasks"])
            lines.append(f"• conversation {_slack_escape(g['conv'])}: {ids} — "
                         f"`{types}` (not duplicates)")
        if len(digest) > 10:
            lines.append(f"• …and {len(digest) - 10} more group(s)")
    if bad:
        # tid/status, not the raw tuple — this is the line an operator has to act on.
        lines.append(f"*:warning: read-back FAILED for {len(bad)} ticket(s)* — "
                     + ", ".join(f"{tid} (status={status})" for tid, status in bad))
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(
        description="Move genuinely-redundant ClickUp TO DO tickets to Waiting")
    ap.add_argument("--dry-run", action="store_true",
                    help="classify and report; make no ClickUp writes")
    ap.add_argument("--max-moves", type=int, default=DEFAULT_MAX_MOVES,
                    help=f"abort with zero writes above this many moves "
                         f"(default {DEFAULT_MAX_MOVES})")
    ap.add_argument("--list-id", default=os.environ.get("CLICKUP_LIST_ID", DEFAULT_LIST_ID))
    ap.add_argument("--slack-channel",
                    default=os.environ.get("CLICKUP_DEDUPE_CHANNEL", DEFAULT_SUMMARY_CHANNEL))
    ap.add_argument("--alert-channel",
                    default=os.environ.get("CLICKUP_DEDUPE_ALERT_CHANNEL", DEFAULT_ALERT_CHANNEL))
    ap.add_argument("--no-notify", action="store_true", help="never post to Slack")
    ap.add_argument("--slack-config",
                    default=os.environ.get("SLACK_NOTIFY_CONFIG",
                                           "/root/.openclaw-main/openclaw.json"))
    ap.add_argument("--slack-account",
                    default=os.environ.get("CLICKUP_DEDUPE_SLACK_ACCOUNT", "operations"))
    ap.add_argument("--notify-state",
                    default=os.environ.get("CLICKUP_DEDUPE_NOTIFY_STATE",
                                           DEFAULT_NOTIFY_STATE),
                    help="repeat-suppression state file for Slack posts")
    args = ap.parse_args()
    # _page_unhandled runs outside main()'s scope, so record whether paging is
    # wanted at all: a --dry-run or --no-notify invocation (a human testing by
    # hand) must not page #clio_devops when it throws.
    global _PAGING_ENABLED
    _PAGING_ENABLED = not (args.no_notify or args.dry_run)

    token = clickup_token()
    cfg, account = args.slack_config, args.slack_account

    tasks = fetch_status(token, args.list_id, "to do")
    moves, digest, linked = classify(tasks)
    tier_a = [m for m in moves if m["tier"] == "A"]
    tier_b = [m for m in moves if m["tier"] == "B"]
    print(f"scanned {len(tasks)} TO DO tickets; {linked} with a conversation link")
    print(f"tier A moves: {len(tier_a)}  tier B moves: {len(tier_b)}  "
          f"digest-only groups: {len(digest)}")

    if len(moves) > args.max_moves:
        text = (f":rotating_light: *ClickUp TO DO dedupe ABORTED* — would move "
                f"{len(moves)} tickets, ceiling is {args.max_moves}. No writes were made. "
                f"Historical peak was 9; investigate before raising the ceiling.")
        print(text, file=sys.stderr)
        if not args.no_notify:
            notify_once(text, args.alert_channel, cfg, account, args.notify_state)
        return 2

    rc = apply_moves(moves, args.dry_run)
    bad = []
    if moves and not args.dry_run:
        _, bad = read_back(token, moves)
        for tid, status in bad:
            print(f"READ-BACK FAILED {tid}: status={status}", file=sys.stderr)

    # Silent on clean runs, and (via notify_once) silent on a re-report of the
    # same standing digest — an hourly timer must not spam the channel.
    if not args.no_notify and (moves or digest or bad):
        notify_once(format_summary(tier_a, tier_b, digest, len(tasks), linked, bad,
                                   args.dry_run),
                    args.slack_channel, cfg, account, args.notify_state)

    if bad:
        return 1
    return rc


# main()'s own non-zero returns are already reported: 1 = read-back failure
# (named in the Slack summary), 2 = circuit breaker (pages by itself). Every
# other non-clean exit is a fail-closed abort that nothing else announces.
_SELF_REPORTED_EXIT_CODES = (None, 0, 1, 2)


def should_page_exit(code):
    """True when a SystemExit needs a page because nothing else reported it."""
    return code not in _SELF_REPORTED_EXIT_CODES


def _page_unhandled(exc, reason=None):
    """Page #clio_devops for a crash that never reached the normal notify path.

    Without this the failure is SILENT: systemd marks the unit failed, the timer
    still reads active, and the sweep simply stops running with nobody told —
    the same "tested program that never runs" shape the wiring suite guards. The
    message deliberately carries only the exception TYPE (the traceback goes to
    stderr, i.e. journald) so an hourly crash-loop is byte-identical and gets
    collapsed by the notify cooldown instead of paging 24x/day.
    """
    if not _PAGING_ENABLED:
        print("unhandled failure; paging suppressed (--dry-run/--no-notify)",
              file=sys.stderr)
        return
    channel = os.environ.get("CLICKUP_DEDUPE_ALERT_CHANNEL", DEFAULT_ALERT_CHANNEL)
    cfg = os.environ.get("SLACK_NOTIFY_CONFIG", "/root/.openclaw-main/openclaw.json")
    account = os.environ.get("CLICKUP_DEDUPE_SLACK_ACCOUNT", "operations")
    state = os.environ.get("CLICKUP_DEDUPE_NOTIFY_STATE", DEFAULT_NOTIFY_STATE)
    what = reason or f"unhandled `{type(exc).__name__}`"
    text = (f":rotating_light: *ClickUp TO DO dedupe FAILED* — {what}; the hourly "
            f"sweep did not complete. The timer still reads active, so nothing "
            f"else will report this. Check "
            f"`journalctl -u clickup-todo-dedupe.service`.")
    try:
        notify_once(text, channel, cfg, account, state)
    except Exception as page_exc:  # noqa: BLE001 — never mask the original.
        print(f"WARN: could not page for unhandled failure: "
              f"{type(page_exc).__name__}", file=sys.stderr)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit as exc:
        # Not every SystemExit is benign. The fail-closed aborts (missing
        # ClickUp key, a partial scan, a missing batch helper) all raise it with
        # a message, and re-raising blind meant the sweep could fail EVERY HOUR
        # while the timer still read active and nobody was told — the exact hole
        # the crash pager was added to close. main()'s own non-zero returns are
        # excluded because it has already reported them: 1 = read-back failure
        # (named in the Slack summary), 2 = circuit breaker (pages by itself).
        if should_page_exit(exc.code):
            _page_unhandled(exc, reason=f"aborted: {str(exc.code)[:160]}")
        raise
    except BaseException as exc:  # noqa: BLE001 — page, then die loudly.
        traceback.print_exc()
        _page_unhandled(exc)
        raise
