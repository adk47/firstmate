#!/usr/bin/env python3
"""Move one person's open Intercom queue back to the AI queue. Nothing is closed, nothing is sent
to a customer, every move is on a ledger with its inverse.

WHY (intercom-no-human-assignment-k1, captain 2026-11-11: "clear Jan's plate ... Caroline should
respond, no human needed"): the Intercom plugin assigned every blocked reply and every escalation
to one person's admin id (`defaultInboxId`). Measured 2026-11-11: 581 open conversations on that
person, 511 put there by the plugin, 535 never answered by him, and every customer reply in them
dropped by the plugin's "human assignee" check (168 dropped in 24 h). The rule is fixed in
plugins/intercom/src/assignment-policy.ts; this tool clears what the rule already did.

WHAT IT DOES
  plan    (default, read-only) pull every OPEN conversation whose admin assignee is --from-admin,
          classify each, print the counts, write the plan rows to --out.
  apply   re-pull LIVE (never trusts an old plan), then for each `reassign` row: assign the
          conversation to Caroline, read it back, append a ledger row carrying the before-state.
          A conversation the person had replied in also gets ONE internal note (never a customer
          message) so a human can resume it.
  revert  --ledger FILE: put every conversation this run moved back on its previous assignee,
          unless somebody has moved it since (then it is left alone and reported).
  verify  (read-only) how many conversations were assigned to --from-admin in the last --hours,
          split by who assigned them, and how many are open on them now. Exit 0 only when no
          assignment was made by anyone but that person. "Could not read" is UNMEASURED, exit 1.

WHAT STAYS WHERE IT IS, each with a named reason (reported, never silently skipped):
  left_snoozed               a human snoozed it; it wakes to them
  left_restricted            banned / proof-review account (plugins/intercom/src/restricted-accounts.ts)
  left_explicit_escalation   the plugin escalated it for a reason that needs a person (legal threat,
                             security incident, abuse report, fraud complaint, public shaming). It
                             moves to the escalation queue once that queue is live:
                             apply --escalation-team TEAM_ID
  left_escalation_unread     an escalation whose reason could not be read (no ticket reference, or
                             ClickUp unreadable). Unmeasured is not "safe to hand to the bot".

IT NEVER closes, snoozes, tags, or posts a customer-visible message: the only writes are an
`assignment` part and an internal `note`, both as Caroline.

USAGE (the token is read from the environment, else from /etc/openclaw/edge.env)
  intercom-queue-reassign.py plan   --from-admin ADMIN_ID --out plan.jsonl
  intercom-queue-reassign.py apply  --from-admin ADMIN_ID --ledger run.jsonl [--cap 700]
  intercom-queue-reassign.py revert --ledger run.jsonl
  intercom-queue-reassign.py verify --from-admin ADMIN_ID [--hours 24]
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

# The posting identity for every write this tool makes: Caroline. It is also the TARGET, because
# the AI queue is "assigned to Caroline". Same variable name as scripts/intercom-ops-write.sh so
# scripts/check-intercom-reply-identity.sh keys on it.
INTERCOM_ADMIN_ID = "5763097"
INTERCOM_API = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
CLICKUP_API = "https://api.clickup.com/api/v2"
ENV_FILE = "/etc/openclaw/edge.env"
DEFAULT_CAP = 700

HANDOFF_LINE = "I'm pulling in a teammate to take this from here."
ESCALATION_TAIL = "You'll hear from us in this conversation and by email."
OUTPUT_GUARD_TAG = "ai:output-guard"
# Reasons from plugins/intercom/src/escalation.ts that keep a human seat. Everything else the
# plugin escalated for (a request for a person, a turn cap, a cancel or refund intent, a judge
# call) goes back to Caroline: the ticket it filed still carries the work.
HUMAN_SEAT_REASONS = frozenset(
    {"legal_threat", "security_incident", "abuse_report", "fraud_complaint", "public_shaming_intent"}
)
RESTRICTED_NOTE_MARKERS = ("banned fraud account", "credits under proof review")
MID_REPLY_RECENT_DAYS = 14
# Curly single quotes (code points 8216, 8217) fold to a straight one. Written as numbers because
# scripts/check-intercom-reply-identity.sh refuses escape sequences in a file that writes to Intercom.
CURLY_QUOTES = {8216: "'", 8217: "'"}


# --------------------------------------------------------------------------------------------
# plumbing


def read_env_value(name: str, env_file: str = ENV_FILE) -> str:
    val = os.environ.get(name, "").strip()
    if val:
        return val
    try:
        for line in Path(env_file).read_text(encoding="utf8").splitlines():
            m = re.match(r"^\s*(?:export\s+)?" + re.escape(name) + r"=(.*)$", line)
            if m:
                return m.group(1).strip().strip('"').strip("'")
    except OSError:
        pass
    return ""


class Api:
    """Intercom + ClickUp over urllib. A test replaces `request`."""

    def __init__(self, intercom_token: str, clickup_key: str = "", sleep=time.sleep):
        self.intercom_token = intercom_token
        self.clickup_key = clickup_key
        self.sleep = sleep

    def request(self, method: str, url: str, headers: dict, body: dict | None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read() or b"{}")

    def _retry(self, method: str, url: str, headers: dict, body: dict | None, tries: int = 5) -> dict:
        for attempt in range(tries):
            try:
                return self.request(method, url, headers, body)
            except urllib.error.HTTPError as exc:
                if exc.code in (429, 500, 502, 503, 504) and attempt < tries - 1:
                    self.sleep(2 * (attempt + 1))
                    continue
                raise
            except (urllib.error.URLError, TimeoutError):
                if attempt < tries - 1:
                    self.sleep(2 * (attempt + 1))
                    continue
                raise
        raise RuntimeError("unreachable")

    def intercom(self, method: str, path: str, body: dict | None = None) -> dict:
        headers = {
            "Authorization": "Bearer " + self.intercom_token,
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Intercom-Version": INTERCOM_VERSION,
        }
        return self._retry(method, INTERCOM_API + path, headers, body)

    def clickup_task(self, task_id: str) -> dict | None:
        """The ticket an escalation filed, or None when it cannot be read."""
        if not self.clickup_key:
            return None
        try:
            return self._retry(
                "GET",
                f"{CLICKUP_API}/task/{task_id}",
                {"Authorization": self.clickup_key, "Accept": "application/json"},
                None,
                tries=3,
            )
        except Exception:
            return None


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def text_of(body: str | None) -> str:
    """Plain text of an Intercom HTML body, curly quotes folded."""
    t = re.sub(r"<[^>]+>", " ", body or "")
    t = html.unescape(t).translate(CURLY_QUOTES)
    return re.sub(r"\s+", " ", t).strip()


# --------------------------------------------------------------------------------------------
# reading


def search_open_on(api: Api, admin_id: str) -> list[str]:
    """Ids of every conversation that is not closed and whose admin assignee is admin_id."""
    ids: list[str] = []
    for state in ("open", "snoozed"):
        cursor = None
        while True:
            pagination: dict = {"per_page": 150}
            if cursor:
                pagination["starting_after"] = cursor
            query = {
                "operator": "AND",
                "value": [
                    {"field": "admin_assignee_id", "operator": "=", "value": admin_id},
                    {"field": "state", "operator": "=", "value": state},
                ],
            }
            page = api.intercom("POST", "/conversations/search", {"query": query, "pagination": pagination})
            ids += [str(c["id"]) for c in page.get("conversations", [])]
            cursor = ((page.get("pages") or {}).get("next") or {}).get("starting_after")
            if not cursor:
                break
    return list(dict.fromkeys(ids))


def fetch_conversation(api: Api, conv_id: str) -> dict:
    return api.intercom("GET", f"/conversations/{conv_id}?display_as=plaintext")


def parts_of(conv: dict) -> list[dict]:
    return list(((conv.get("conversation_parts") or {}).get("conversation_parts")) or [])


def escalation_reason_from_ticket(task: dict | None) -> str:
    """`escalation_reason` from the JSON block the plugin writes into the ticket, or ''."""
    if not task:
        return ""
    blob = " ".join(str(task.get(k) or "") for k in ("description", "text_content", "markdown_description"))
    m = re.search(r'"escalation_reason"\s*:\s*"([A-Za-z0-9_:\-/, ]+)"', blob)
    return m.group(1).strip() if m else ""


def classify(conv: dict, source_admin: str, api: Api, restricted_contacts: frozenset[str], now_s: float) -> dict:
    """One plan row. Pure apart from the ClickUp read for an escalation's reason."""
    conv_id = str(conv.get("id"))
    admin = str(conv.get("admin_assignee_id") or "")
    team = str(conv.get("team_assignee_id") or "")
    state = str(conv.get("state") or "")
    parts = parts_of(conv)
    tags = [t.get("name") for t in ((conv.get("tags") or {}).get("tags") or [])]
    contacts = [str(c.get("id")) for c in ((conv.get("contacts") or {}).get("contacts") or [])]
    source = conv.get("source") or {}

    row: dict = {
        "id": conv_id,
        "before": {"admin_assignee_id": admin or None, "team_assignee_id": team or None, "state": state},
        "parts_seen": len(parts),
        "parts_total": (conv.get("conversation_parts") or {}).get("total_count"),
    }

    if admin != source_admin:
        return {**row, "action": "skip", "reason": "not_on_source", "mechanism": "n/a"}
    if state == "closed":
        return {**row, "action": "skip", "reason": "closed", "mechanism": "n/a"}

    # --- which rule put it on this person: the last assignment part naming them
    last_assign_idx = None
    for i, p in enumerate(parts):
        to = p.get("assigned_to") or {}
        if p.get("part_type") in ("assignment", "bulk_reassignment", "message_assignment", "default_assignment") and str(
            to.get("id") or ""
        ) == source_admin:
            last_assign_idx = i
    mechanism = "no_assignment_part"
    escalation_ref = ""
    escalation_reason = ""
    if last_assign_idx is not None:
        ap = parts[last_assign_idx]
        author = ap.get("author") or {}
        author_id = str(author.get("id") or "")
        if author_id == INTERCOM_ADMIN_ID:
            mechanism = "plugin_other"
            # the bot's customer-visible comment just before the assignment says which path it was
            window = [
                p
                for p in parts[max(0, last_assign_idx - 4) : last_assign_idx]
                if str((p.get("author") or {}).get("id") or "") == INTERCOM_ADMIN_ID and p.get("part_type") == "comment"
            ]
            bodies = [text_of(p.get("body")) for p in window]
            if any(HANDOFF_LINE in b and ESCALATION_TAIL in b for b in bodies):
                mechanism = "risk_escalation"
                for b in bodies:
                    m = re.search(r"Reference:\s*([A-Za-z0-9]+)", b)
                    if m:
                        escalation_ref = m.group(1)
                if escalation_ref:
                    escalation_reason = escalation_reason_from_ticket(api.clickup_task(escalation_ref))
            elif OUTPUT_GUARD_TAG in tags or any(b == HANDOFF_LINE for b in bodies):
                mechanism = "output_guard"
        elif author_id == source_admin:
            mechanism = "self_assigned" if ap.get("part_type") == "assignment" else "self_bulk_reassigned"
        elif author.get("type") == "bot" or ap.get("part_type") in ("message_assignment", "default_assignment"):
            mechanism = "intercom_operator_rule"
        else:
            mechanism = "other_admin"
    row["mechanism"] = mechanism
    if escalation_ref:
        row["escalation_ticket"] = escalation_ref
    if mechanism == "risk_escalation":
        row["escalation_reason"] = escalation_reason or "unread"

    # --- did the person answer the customer here (so a human may want to resume)
    start = last_assign_idx + 1 if last_assign_idx is not None else 0
    human_comments = [
        p
        for p in parts[start:]
        if p.get("part_type") == "comment" and str((p.get("author") or {}).get("id") or "") == source_admin
    ]
    src_author = source.get("author") or {}
    opened_by_source = src_author.get("type") == "admin" and str(src_author.get("id") or "") == source_admin
    last_human_at = max([int(p.get("created_at") or 0) for p in human_comments] or [0])
    if opened_by_source and last_assign_idx is None:
        last_human_at = max(last_human_at, int(conv.get("created_at") or 0))
    row["human_replied"] = bool(last_human_at)
    row["last_human_reply_at"] = last_human_at or None
    row["mid_reply_recent"] = bool(last_human_at) and (now_s - last_human_at) <= MID_REPLY_RECENT_DAYS * 86400
    customer_parts = [p for p in parts if (p.get("author") or {}).get("type") in ("user", "lead", "contact")]
    row["last_customer_at"] = max([int(p.get("created_at") or 0) for p in customer_parts] or [0]) or None

    # --- reasons to leave it where it is
    restricted = bool(set(contacts) & restricted_contacts) or any(
        p.get("part_type") == "note"
        and str((p.get("author") or {}).get("id") or "") == INTERCOM_ADMIN_ID
        and any(mk in text_of(p.get("body")).lower() for mk in RESTRICTED_NOTE_MARKERS)
        for p in parts
    )
    if state == "snoozed":
        return {**row, "action": "leave", "reason": "left_snoozed"}
    if restricted:
        return {**row, "action": "leave", "reason": "left_restricted"}
    if mechanism == "risk_escalation":
        if not escalation_reason:
            return {**row, "action": "leave", "reason": "left_escalation_unread"}
        if any(r.strip() in HUMAN_SEAT_REASONS for r in re.split(r"[,/ ]+", escalation_reason)):
            return {**row, "action": "leave", "reason": "left_explicit_escalation"}
    return {**row, "action": "reassign", "reason": "to_ai_queue"}


def load_restricted_contacts(path: str | None) -> frozenset[str]:
    """Contact ids from restricted-accounts.ts (opaque 24-hex Intercom ids)."""
    candidates = [path] if path else [str(Path(__file__).resolve().parent.parent / "plugins/intercom/src/restricted-accounts.ts")]
    for c in candidates:
        try:
            return frozenset(re.findall(r'"([0-9a-f]{24})"', Path(c).read_text(encoding="utf8")))
        except OSError:
            continue
    return frozenset()


def build_plan(api: Api, source_admin: str, restricted: frozenset[str], workers: int = 6, now_s: float | None = None) -> list[dict]:
    ids = search_open_on(api, source_admin)
    now_s = time.time() if now_s is None else now_s

    def one(conv_id: str) -> dict:
        try:
            return classify(fetch_conversation(api, conv_id), source_admin, api, restricted, now_s)
        except Exception as exc:  # an unreadable conversation is reported, never moved
            return {"id": conv_id, "action": "leave", "reason": "left_unreadable", "mechanism": "unread", "error": str(exc)[:200]}

    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        return list(pool.map(one, ids))


def summarize(rows: list[dict]) -> dict:
    def count(key_fn) -> dict:
        out: dict = {}
        for r in rows:
            k = key_fn(r)
            out[k] = out.get(k, 0) + 1
        return dict(sorted(out.items(), key=lambda kv: -kv[1]))

    reassign = [r for r in rows if r.get("action") == "reassign"]
    return {
        "total": len(rows),
        "by_action": count(lambda r: r.get("action")),
        "left_by_reason": count(lambda r: r.get("reason")) if rows else {},
        "by_mechanism": count(lambda r: r.get("mechanism")),
        "escalation_reasons": count(lambda r: r.get("escalation_reason", "-")),
        "reassign": len(reassign),
        "reassign_human_replied": sum(1 for r in reassign if r.get("human_replied")),
        "reassign_mid_reply_recent": sum(1 for r in reassign if r.get("mid_reply_recent")),
        "truncated_threads": sum(
            1 for r in rows if isinstance(r.get("parts_total"), int) and r["parts_total"] > r.get("parts_seen", 0)
        ),
    }


# --------------------------------------------------------------------------------------------
# writing


def assign(api: Api, conv_id: str, assignee_id: str, assignee_type: str = "admin") -> None:
    """An assignment part, posted as Caroline. The only state-changing call this tool makes."""
    api.intercom(
        "POST",
        f"/conversations/{conv_id}/parts",
        {"message_type": "assignment", "type": assignee_type, "admin_id": INTERCOM_ADMIN_ID, "assignee_id": assignee_id},
    )


def post_internal_note(api: Api, conv_id: str, body: str) -> None:
    """An INTERNAL note as Caroline. Never a customer-visible message: the type is fixed here."""
    api.intercom(
        "POST",
        f"/conversations/{conv_id}/reply",
        {"message_type": "note", "type": "admin", "admin_id": INTERCOM_ADMIN_ID, "body": body},
    )


def resume_note(source_name: str, last_human_reply_at: int | None) -> str:
    when = datetime.fromtimestamp(last_human_reply_at, timezone.utc).strftime("%Y-%m-%d") if last_human_reply_at else "an earlier date"
    return (
        f"Internal note (not visible to the customer). This conversation was moved from {source_name} to Caroline "
        f"(the AI queue) on {datetime.now(timezone.utc).strftime('%Y-%m-%d')} by the queue clean-up "
        f"(intercom-no-human-assignment-k1). {source_name} last replied to the customer here on {when}. "
        "Nothing was sent to the customer and nothing was closed. Caroline answers the customer's next message. "
        "To resume as a person, assign the conversation to yourself and reply."
    )


def append_ledger(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf8") as fh:
        fh.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
        fh.flush()
        os.fsync(fh.fileno())


def apply_plan(
    api: Api,
    rows: list[dict],
    source_admin: str,
    source_name: str,
    ledger: Path,
    run_id: str,
    cap: int,
    escalation_team: str = "",
    pace_s: float = 0.25,
) -> dict:
    todo = [r for r in rows if r.get("action") == "reassign"]
    if escalation_team:
        todo += [r for r in rows if r.get("reason") == "left_explicit_escalation"]
    if len(todo) > cap:
        raise SystemExit(f"REFUSED: {len(todo)} conversations to move is over the cap of {cap}. Raise --cap deliberately.")
    stats = {"moved": 0, "moved_to_escalation_team": 0, "notes": 0, "failed": 0, "changed_since_plan": 0, "closed_by_this_run": 0}
    for r in todo:
        conv_id = r["id"]
        to_team = r.get("reason") == "left_explicit_escalation"
        entry = {
            "run_id": run_id,
            "ts": now_iso(),
            "id": conv_id,
            "kind": "escalation_team" if to_team else "ai_queue",
            "before": r["before"],
            "mechanism": r.get("mechanism"),
            "human_replied": bool(r.get("human_replied")),
            "mid_reply_recent": bool(r.get("mid_reply_recent")),
            "note_posted": False,
        }
        try:
            # the before-state is on the ledger BEFORE the write, so a crash mid-call is still revertible
            append_ledger(ledger, {**entry, "phase": "intent"})
            if to_team:
                assign(api, conv_id, "0")
                assign(api, conv_id, escalation_team, "team")
            else:
                assign(api, conv_id, INTERCOM_ADMIN_ID)
            after = fetch_conversation(api, conv_id)
            got_admin = str(after.get("admin_assignee_id") or "")
            got_team = str(after.get("team_assignee_id") or "")
            ok = (got_admin == "" and got_team == escalation_team) if to_team else (got_admin == INTERCOM_ADMIN_ID)
            entry["after"] = {"admin_assignee_id": got_admin or None, "team_assignee_id": got_team or None, "state": after.get("state")}
            entry["verified"] = ok
            if after.get("state") == "closed" and r["before"].get("state") != "closed":
                stats["closed_by_this_run"] += 1  # must stay 0: this tool never closes
            if ok and r.get("human_replied") and not to_team:
                post_internal_note(api, conv_id, resume_note(source_name, r.get("last_human_reply_at")))
                entry["note_posted"] = True
                stats["notes"] += 1
            if ok:
                stats["moved_to_escalation_team" if to_team else "moved"] += 1
            else:
                stats["failed"] += 1
            append_ledger(ledger, {**entry, "phase": "done"})
        except Exception as exc:
            stats["failed"] += 1
            append_ledger(ledger, {**entry, "phase": "error", "error": str(exc)[:300]})
        api.sleep(pace_s)
    return stats


def revert(api: Api, ledger: Path, pace_s: float = 0.25) -> dict:
    """Put each moved conversation back on its previous assignee, unless someone moved it since."""
    seen: dict[str, dict] = {}
    for line in ledger.read_text(encoding="utf8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("phase") in ("intent", "done", "error"):
            seen[row["id"]] = {**seen.get(row["id"], {}), **row}
    stats = {"reverted": 0, "left_moved_since": 0, "left_never_moved": 0, "failed": 0}
    out = ledger.with_suffix(ledger.suffix + ".revert")
    for conv_id, row in seen.items():
        before = row.get("before") or {}
        prev_admin = str(before.get("admin_assignee_id") or "")
        try:
            live = fetch_conversation(api, conv_id)
            live_admin = str(live.get("admin_assignee_id") or "")
            live_team = str(live.get("team_assignee_id") or "")
            after = row.get("after") or {}
            ours = (
                live_admin == INTERCOM_ADMIN_ID
                if row.get("kind") == "ai_queue"
                else (live_admin == "" and live_team == str(after.get("team_assignee_id") or ""))
            )
            if live_admin == prev_admin:
                stats["left_never_moved"] += 1
                append_ledger(out, {"id": conv_id, "ts": now_iso(), "result": "already_on_previous_assignee"})
            elif not ours:
                stats["left_moved_since"] += 1
                append_ledger(out, {"id": conv_id, "ts": now_iso(), "result": "moved_by_someone_since", "live_admin": live_admin})
            else:
                assign(api, conv_id, prev_admin or "0")
                prev_team = str(before.get("team_assignee_id") or "")
                if row.get("kind") == "escalation_team" and prev_team:
                    assign(api, conv_id, prev_team, "team")
                stats["reverted"] += 1
                append_ledger(out, {"id": conv_id, "ts": now_iso(), "result": "reverted", "to_admin": prev_admin or None})
        except Exception as exc:
            stats["failed"] += 1
            append_ledger(out, {"id": conv_id, "ts": now_iso(), "result": "error", "error": str(exc)[:300]})
        api.sleep(pace_s)
    return stats


# --------------------------------------------------------------------------------------------
# verify: the one-shot read behind "is the queue refilling?" (not a monitor: no timer, no page;
# the paging metric is caroline-monitor's, see data/intercom-no-human-assignment-k1/metric-contract.md)

ASSIGNMENT_PART_TYPES = ("assignment", "bulk_reassignment", "message_assignment", "default_assignment")


def assignments_to(api: Api, admin_id: str, since_s: int, workers: int = 6) -> dict:
    """Every assignment part naming admin_id since since_s, split by who made it."""
    ids: list[str] = []
    cursor = None
    while True:
        pagination: dict = {"per_page": 150}
        if cursor:
            pagination["starting_after"] = cursor
        query = {"field": "updated_at", "operator": ">", "value": since_s}
        page = api.intercom("POST", "/conversations/search", {"query": query, "pagination": pagination})
        ids += [str(c["id"]) for c in page.get("conversations", [])]
        cursor = ((page.get("pages") or {}).get("next") or {}).get("starting_after")
        if not cursor:
            break
    ids = list(dict.fromkeys(ids))

    def one(conv_id: str) -> list[tuple[str, str]] | None:
        try:
            conv = fetch_conversation(api, conv_id)
        except Exception:
            return None
        out = []
        for p in parts_of(conv):
            if p.get("part_type") not in ASSIGNMENT_PART_TYPES or int(p.get("created_at") or 0) < since_s:
                continue
            if str((p.get("assigned_to") or {}).get("id") or "") != admin_id:
                continue
            author = str((p.get("author") or {}).get("id") or "")
            who = "plugin_or_caroline" if author == INTERCOM_ADMIN_ID else "self" if author == admin_id else "other:" + author
            out.append((conv_id, who))
        return out

    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        results = list(pool.map(one, ids))
    by: dict = {}
    events = 0
    for r in results:
        for _conv, who in r or []:
            by[who] = by.get(who, 0) + 1
            events += 1
    return {
        "conversations_scanned": len(ids),
        "unreadable": sum(1 for r in results if r is None),
        "assignments": events,
        "by_author": by,
        # a person assigning a thread to themself is the explicit resume path, not a default
        "assignments_not_self": events - by.get("self", 0),
    }


def verify(api: Api, admin_id: str, hours: int, workers: int = 6) -> dict:
    since = int(time.time()) - hours * 3600
    counted = assignments_to(api, admin_id, since, workers)
    open_now = len(search_open_on(api, admin_id))
    # unreadable conversations make the count a floor, not a measurement: that is not a pass
    clean = counted["assignments_not_self"] == 0 and counted["unreadable"] == 0
    return {
        "admin": admin_id,
        "window_hours": hours,
        "open_on_admin_now": open_now,
        **counted,
        "verdict": "ZERO" if clean else ("UNMEASURED" if counted["assignments_not_self"] == 0 else "NOT_ZERO"),
    }


# --------------------------------------------------------------------------------------------
# cli


def admin_name(api: Api, admin_id: str) -> str:
    try:
        for a in api.intercom("GET", "/admins").get("admins", []):
            if str(a.get("id")) == admin_id:
                return str(a.get("name") or admin_id)
    except Exception:
        pass
    return f"admin {admin_id}"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["plan", "apply", "revert", "verify"], nargs="?", default="plan")
    ap.add_argument("--hours", type=int, default=24, help="verify: look-back window (default 24)")
    ap.add_argument("--from-admin", help="Intercom admin id whose open queue is cleared")
    ap.add_argument("--out", help="plan: write the plan rows (JSONL) here")
    ap.add_argument("--ledger", help="apply / revert: the run ledger (JSONL)")
    ap.add_argument("--cap", type=int, default=DEFAULT_CAP, help=f"apply: refuse to move more than this (default {DEFAULT_CAP})")
    ap.add_argument("--escalation-team", default="", help="apply: also move left_explicit_escalation rows to this TEAM queue")
    ap.add_argument("--restricted-file", help="path to restricted-accounts.ts (default: the repo copy)")
    ap.add_argument("--workers", type=int, default=6)
    args = ap.parse_args(argv)

    token = read_env_value("MUSOAI_INTERCOM_TOKEN")
    if not token:
        print("REFUSED: no MUSOAI_INTERCOM_TOKEN in the environment or in " + ENV_FILE, file=sys.stderr)
        return 2
    api = Api(token, read_env_value("CLICKUP_API_KEY"))

    if args.command == "revert":
        if not args.ledger:
            ap.error("revert needs --ledger")
        print(json.dumps({"revert": revert(api, Path(args.ledger))}, indent=1))
        return 0

    if not args.from_admin or not re.fullmatch(r"[1-9][0-9]*", args.from_admin):
        ap.error("--from-admin must be a numeric Intercom admin id")
    if args.from_admin == INTERCOM_ADMIN_ID:
        ap.error("--from-admin is Caroline; her queue IS the AI queue")
    if args.escalation_team and not re.fullmatch(r"[1-9][0-9]*", args.escalation_team):
        ap.error("--escalation-team must be a numeric Intercom TEAM id")
    if args.command == "apply" and not args.ledger:
        ap.error("apply needs --ledger")

    if args.command == "verify":
        result = verify(api, args.from_admin, args.hours, args.workers)
        print(json.dumps({"verify": result}, indent=1))
        return 0 if result["verdict"] == "ZERO" else 1

    rows = build_plan(api, args.from_admin, load_restricted_contacts(args.restricted_file), args.workers)
    summary = summarize(rows)
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text("".join(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n" for r in rows), encoding="utf8")
    if args.command == "plan":
        print(json.dumps({"plan": summary, "clickup_readable": bool(api.clickup_key)}, indent=1))
        return 0

    run_id = "k1-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    ledger = Path(args.ledger)
    append_ledger(ledger, {"phase": "run", "run_id": run_id, "ts": now_iso(), "from_admin": args.from_admin, "plan": summary})
    stats = apply_plan(
        api, rows, args.from_admin, admin_name(api, args.from_admin), ledger, run_id, args.cap, args.escalation_team
    )
    remaining = len(search_open_on(api, args.from_admin))
    result = {"run_id": run_id, "plan": summary, "applied": stats, "still_open_on_source": remaining}
    append_ledger(ledger, {"phase": "result", "run_id": run_id, "ts": now_iso(), **result})
    print(json.dumps(result, indent=1))
    return 0 if stats["failed"] == 0 and stats["closed_by_this_run"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
