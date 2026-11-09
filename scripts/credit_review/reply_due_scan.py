"""reply_due_scan: the class-G audience builder (Fable [key=reply-due]; p1 395 / 07:38Z: "reply_due must be a FAMILY in
the #1541 timer"). The hand-run scan of 10-31 08Z (h2), made code so the outbound timer can run it.

    python3 reply_due_scan.py --out FILE [--cap N] [--max-checks N] [--budget-seconds S] [--start-entry N]

Reads (read-only): Intercom (open conversations; each thread), the core replica (who the contact is; the user's open
requests and their facts), the paying list, the doc-verify store. Writes FILE (0600, atomic) - the runner's list:

1. Intercom search: OPEN conversations whose customer last replied more than 24 h ago AND after our last reply, with
   exactly one contact.
2. Per thread, the triggering part = the customer's latest part; the DEPLOYED rule decides due:
   comm_state.reply_due() must return [] (R9 on topic, open, this user's thread, not answered, >= 24 h). Anything
   unreadable is skipped and counted, never listed. comm_state.reply_due_thread() gives the facts the gate acts on
   (assignee action, prior_note).
3. The user: the contact's external_id is the account's professional id or Auth0 subject (the gate's own mapping);
   otherwise the contact's email, matched exactly (the gate re-verifies identity, G2). Ambiguous = skipped, counted.
4. One row per user (their OLDEST waiting thread), paid first, then oldest first; user 15 never.
4b. builder == send (h2 G1 dry run 10-31 11:1xZ: 100 listed, 0 answerable): per user the DEPLOYED send-time decision,
   comm_state.check(uvn-status, reply_due_part=...) - the very call the gate makes - sorts them: answerable -> the
   runner list (users); reply_due:class_is:<X> -> by_class[X] (another campaign answers them); non_status (e.g. a part
   older than 30 days) -> handoff (a person answers); anything else held -> held, with its reasons. Nothing that the
   gate would refuse or hand off is ever a batch slot.
5. The signing header (r5 [key=k-proof-required]): per-recipient facts (request, status, proof_required, review_stage,
   dv_latest; paid, first_name_missing, assignee, prior_note, conversation, part) and replica_facts {query, sha256}.

The list rows carry reply_due {part, conversation} - uvn_status.with_reply_due hands them to the gate."""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import sqlite3
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from credit_review import comm_state  # noqa: E402

PAYING = "/var/lib/credit-trust/paying-users.json"
DV_STORE = "/var/lib/hydra-credit-verify/doc-verify.sqlite"
NEVER = frozenset({"15"})                 # firstmate standing order: user 15 is never in an automated wave
# QA #1574 (Important): the send-time check is ~35 s per user and the deployed timer called this scan UNBOUNDED - the
# measured 379 due users under a mostly-HELD audience is ~3.7 h against the tick's 6,900 s limit. So a run walks ONE
# bounded slice of the audience, stopping on whichever comes first: the accept cap, this many total gate checks (held
# and routed users included - the answerable count alone never bounds the work), or this much wall clock.
CHECK_MAX = 400
CHECK_BUDGET_S = 900.0
# firstmate 034 (A): the upstream walks and the reply work shared ONE deadline, so a walk that spent the whole budget
# left the mapping step with an expired one. 2026-11-06 14:00Z: 2,014 threads walked, 160 due, 0 mapped, 0 sent - the
# walk spent 903 s and `map_users` then skipped every thread because the deadline had already passed. The walks are
# RESUMABLE (their un-evaluated rows are carried in `pending` and re-evaluated first next run); the mapping is not, and
# neither is the check that follows it. So the walks stop at this share of the budget and the reply work always gets the
# rest. Half is deliberate: a walk that cannot finish in half a tick is a walk that needs a cursor, not more clock.
#
# QA #1828 (Important): ONE shared walk deadline let an early walk starve a later one - a search that took 500 s of a
# 900 s tick left `due_threads` an already-expired deadline, so a tick that previously found due replies produced none.
# The walks are now handed a bounded SLICE each: what is left of the walk share, divided by the number of walk stages
# still to run. Every stage gets a turn, no stage can exceed the share, and a stage that finishes early hands its
# remainder to the next one.
WALK_SHARE = 0.5
WALK_STAGES = 4   # apology_rows, due_threads(carried), candidates, due_threads(fresh)
CUSTOMER = ("user", "lead", "contact")
FACTS_QUERY = ("SELECT CAST(userid AS varchar), lower(CAST(id AS varchar)), status, "
               "CAST(coalesce(CAST(json_extract(verificationdata, '$.proof_required') AS boolean), false) AS varchar), "
               "CAST(json_extract(metadata, '$.reviewStage') IS NOT NULL AS varchar) FROM postgresql_core.public.credit_requests "
               "WHERE deletedat IS NULL AND status NOT IN ('approved','rejected') AND userid IN ({ids})")

# Fable d2 2026-11-08 (the reply check's cost): the track titles of the user's PENDING requests, read in the same
# 300-user chunks as FACTS_QUERY. With them, the deployed trigger_class rules run here on the thread the scan already
# holds, so the ~20 s full check (6-7 Trino queries + 5+ GETs per user) runs only for the parts it reads as a STATUS
# question - the 02:00Z/04:00Z ticks checked 57 users at that price and found 1. FACTS_QUERY is the signed header and
# is NOT changed by this; the status filter here is open_titles' (PENDING_STATUSES), applied again in trigger_inputs.
TITLES_QUERY = ("SELECT CAST(userid AS varchar), lower(CAST(id AS varchar)), coalesce(spotifytracktitle, '') "
                "FROM postgresql_core.public.credit_requests WHERE deletedat IS NULL "
                "AND status IN ('user_verification_needed','unverified') AND userid IN ({ids})")

Query = Callable[[str], "list[list[str]]"]
Intercom = Callable[[str, str, "dict | None"], dict]


def _q(values: list[str]) -> str:
    """A SQL IN list of quoted string literals, each quote doubled (Trino's escape): QA #1574 - a valid value with an
    apostrophe (o'brien@example.com) is matched, never dropped (a dropped sole value made the query `IN ()` and failed
    the whole scan). Callers never pass an empty list."""
    return ",".join("'" + v.replace("'", "''") + "'" for v in values)


def candidates(ic: Intercom, now: float, counts: collections.Counter | None = None,
               deadline: float | None = None,
               resume_after: str | None = None) -> tuple[list[dict[str, Any]], str | None]:
    """Open threads where the customer is waiting more than 24 h (step 1).

    r5 (1574 finding 3): the search restarted at the FIRST page every tick, so a budget-starved run that kept running out
    inside the early pages never reached the later ones - the audience-page cursor cannot fix that, because it rotates
    inside a list that preparation has already truncated. This walk returns where it stopped (`starting_after`), the
    caller persists it, and the next tick RESUMES there instead of starting over. A completed walk returns None, which
    means the next run starts from the beginning again (the rotation wraps).
    """
    out, after = [], resume_after or None
    while True:
        # r5 (1574 finding 2): the deadline exists from the first upstream call, not from the check loop
        if deadline is not None and time.monotonic() >= deadline:
            if counts is not None:
                counts["candidates_stopped_at_budget"] += 1
            return out, after
        q: dict[str, Any] = {"query": {"operator": "AND", "value": [
            {"field": "state", "operator": "=", "value": "open"},
            {"field": "statistics.last_contact_reply_at", "operator": "<", "value": int(now - comm_state.REPLY_DUE_AFTER_S)}]},
            "pagination": {"per_page": 150}}
        if after:
            q["pagination"]["starting_after"] = after
        r = ic("POST", "/conversations/search", q)
        for c in r.get("conversations") or []:
            st = c.get("statistics") or {}
            lc, la = st.get("last_contact_reply_at") or 0, st.get("last_admin_reply_at") or 0
            ct = (c.get("contacts") or {}).get("contacts") or []
            if lc and lc > la and len(ct) == 1:
                out.append({"conv": str(c["id"]), "cid": str(ct[0].get("id") or ""), "ext": str(ct[0].get("external_id") or ""),
                            "at": int(lc)})
        after = ((r.get("pages") or {}).get("next") or {}).get("starting_after")
        if not after:
            return out, None


def due_threads(cands: list[dict[str, Any]], ic: Intercom, now: float, counts: collections.Counter,
                deadline: float | None = None,
                convs: dict[str, dict[str, Any]] | None = None) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Step 2: the deployed reply_due() decides; reply_due_thread() gives the gate's facts.

    r5 (1574 finding 4): it returns the candidates it never got to. The next run EVALUATES them before it searches again -
    a candidate the search found but the deadline never reached is work in progress, not a page to skip past.
    Fable d2 2026-11-08: ONE GET per candidate. The thread is fetched here and handed to reply_due() / reply_due_thread(),
    which used to fetch it again each (3 GETs per thread; 02:00Z: ~836 threads in the 450 s walk share). `convs` keeps
    the due threads for the classifier so it never re-reads them either; it is never written to the output.
    """
    out, unevaluated = [], []
    for i, c in enumerate(cands):
        if deadline is not None and time.monotonic() >= deadline:
            counts["due_threads_stopped_at_budget"] += len(cands) - len(out) - counts["due_threads_skipped_before"]
            unevaluated = cands[i:]
            break
        try:
            conv = ic("GET", f"/conversations/{c['conv']}?display_as=plaintext", None)
            parts = [conv.get("source") or {}] + ((conv.get("conversation_parts") or {}).get("conversation_parts") or [])
            cust = [p for p in parts if (p.get("author") or {}).get("type") in CUSTOMER
                    and (p.get("part_type") or "comment") != "note" and str(p.get("id") or "").isdigit()]
            if not cust:
                counts["not_due:no_customer_part"] += 1
                continue
            part = str(cust[-1]["id"])
            counts["conversation_gets"] += 1
            why = comm_state.reply_due(c["conv"], c["cid"], part, ic, now=now, conv=conv)
            if why:
                counts.update("not_due:" + (w.split(":", 1)[1] if ":" in w else w) for w in why)
                continue
            th = comm_state.reply_due_thread(c["conv"], ic, now=now, part=part, conv=conv)
            tc = comm_state.trigger_class(conv, part, now=now)
            if convs is not None:
                convs[str(c["conv"])] = conv
        except Exception as exc:  # noqa: BLE001 - one unreadable thread is skipped and counted, never listed
            counts["skipped_unreadable:" + type(exc).__name__] += 1
            counts["due_threads_skipped_before"] += 1
            continue
        out.append({**c, "part": part, "assignee": th.get("assignee"), "prior_note": th.get("prior_note"), "trigger": tc})
    return out, unevaluated


# r5 / Fable fable-copy-1101-r5/ap1 (the /p condition, a gate in code): the backlog apology asks "Do you still need help
# with ...?", so EVERY customer reply to it is owed an answer by i1's staffed queue. The scan covers that campaign by
# itself, whatever the thread is about: a thread holding a SENT backlog-apology message is in scope with R9 (on-topic)
# and the open-state rule waived; each customer part after the apology with no support reply after it is a
# backlog_apology row (due 24 h after the first unanswered part), counted and routed to the queue, never auto-answered.
# An unreadable apology thread is listed as unreadable (never dropped). The output declares covers_campaigns.
BACKLOG_APOLOGY = "backlog-apology"
COVERS_CAMPAIGNS = (BACKLOG_APOLOGY,)


def apology_threads(ledger_path: str) -> dict[str, dict[str, Any]]:
    """{conversation: {user_id, contact_id, part, sent_at}} for every SENT backlog-apology message (the latest per thread)."""
    from credit_review import verify_ledger  # noqa: PLC0415
    db = verify_ledger.connect_ro(ledger_path)
    try:
        out: dict[str, dict[str, Any]] = {}
        for conv, uid, cid, mid, at in db.execute(
                "SELECT conversation_id, coalesce(account_id, ''), coalesce(contact_id, ''), coalesce(message_id, ''), "
                "coalesce(sent_at, created_at) FROM verify_messages WHERE campaign = ? AND status = 'sent' "
                "AND coalesce(conversation_id, '') != '' ORDER BY coalesce(sent_at, created_at), id", (BACKLOG_APOLOGY,)):
            out[str(conv)] = {"user_id": str(uid), "contact_id": str(cid), "part": str(mid), "sent_at": str(at)}
        return out
    finally:
        db.close()


def _epoch(stamp: str) -> float:
    return datetime.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()


def apology_rows(sent: dict[str, dict[str, Any]], ic: Intercom, now: float,
                 counts: collections.Counter,
                 deadline: float | None = None,
                 resume_after: str | None = None) -> tuple[list[dict[str, Any]], list[dict[str, Any]], str | None]:
    """(rows owed an answer, threads that could not be read, where the walk stopped) for the backlog-apology threads.

    r5 (1574 finding 3): sorted() makes the order stable, so a conversation id is a usable resume point - a starved run
    must not restart this walk at the first historical thread on the next tick and starve the tail forever.
    """
    rows, unreadable = [], []
    order = sorted(sent.items())
    start = 0
    if resume_after:
        start = next((i for i, (c, _) in enumerate(order) if c == resume_after), 0)
    stopped: str | None = None
    for i, (conv, a) in enumerate(order[start:], start):
        if deadline is not None and time.monotonic() >= deadline:
            counts["backlog_apology:not_checked_after_budget"] += len(order) - i
            stopped = conv
            break
        try:
            c = ic("GET", f"/conversations/{conv}?display_as=plaintext", None)
            if str(c.get("id") or "") != conv:
                raise comm_state.Unknown("conversation unreadable")
            parts = [c.get("source") or {}] + ((c.get("conversation_parts") or {}).get("conversation_parts") or [])
            # the apology itself: its ledgered part id, else the first support comment at/after its send time
            idx = next((i for i, p in enumerate(parts) if a["part"] and str(p.get("id") or "") == a["part"]), None)
            if idx is None:
                t0 = _epoch(a["sent_at"]) - 120
                idx = next((i for i, p in enumerate(parts) if (p.get("author") or {}).get("type") in comm_state.SUPPORT_AUTHORS
                            and (p.get("part_type") or "comment") != "note" and (p.get("created_at") or 0) >= t0), None)
            if idx is None:
                raise comm_state.Unknown("the apology part is not in the thread")
        except Exception as exc:  # noqa: BLE001 - listed as unreadable: a person looks, never dropped
            counts["backlog_apology:unreadable"] += 1
            unreadable.append({"conversation": conv, "user_id": a["user_id"], "why": f"{type(exc).__name__}: {exc}"[:200]})
            continue
        counts["backlog_apology:threads"] += 1
        after = parts[idx + 1:]
        last_ours = max((i for i, p in enumerate(after) if (p.get("author") or {}).get("type") in comm_state.SUPPORT_AUTHORS
                         and (p.get("part_type") or "comment") != "note"
                         and ((p.get("body") or "").strip() or p.get("attachments"))), default=-1)
        owed = [p for p in after[last_ours + 1:] if (p.get("author") or {}).get("type") in CUSTOMER
                and (p.get("part_type") or "comment") != "note" and ((p.get("body") or "").strip() or p.get("attachments"))]
        if not owed:
            counts["backlog_apology:no_reply_owed"] += 1
            continue
        first_at = min(int(p.get("created_at") or now) for p in owed)
        due_at = first_at + int(comm_state.REPLY_DUE_AFTER_S)
        counts["backlog_apology:reply_owed"] += 1
        counts["backlog_apology:overdue" if now >= due_at else "backlog_apology:within_24h"] += 1
        rows.append({"conversation": conv, "user_id": a["user_id"], "contact_id": a["contact_id"],
                     "apology_part": str(parts[idx].get("id") or ""), "part": str(owed[-1].get("id") or ""),
                     "first_reply_part": str(owed[0].get("id") or ""), "replies": len(owed), "first_reply_at": first_at,
                     "due_at": due_at, "overdue": now >= due_at, "state": str(c.get("state") or ""),
                     "route": "intercom-backlog-i1 (staffed queue; never auto-answered)"})
    rows.sort(key=lambda r: r["due_at"])
    return rows, unreadable, stopped


def map_users(due: list[dict[str, Any]], ic: Intercom, query: Query, counts: collections.Counter,
              deadline: float | None = None) -> list[dict[str, Any]]:
    """Step 3: the account behind each thread's contact - external_id (pro / Auth0), else the exact email.

    r5 (1574 finding 2, round 2): the email fallback is ONE Intercom contact GET per unmapped thread, and a real run had
    439 due threads needing it - preparation that can outlast the whole scan budget before the bounded check loop even
    starts. It reads the same deadline as everything else now, and every thread it cannot reach is COUNTED, never
    silently dropped.
    QA #1574 (4th round): the email IN-list batches that follow those GETs read the same deadline too - they are the
    slowest reads here (200 addresses at a time), and stopping between them is what keeps the whole preparation inside
    the budget instead of overrunning it by a batch.
    """
    ext = sorted({d["ext"] for d in due if d["ext"]})
    by_ext: dict[str, set[str]] = collections.defaultdict(set)
    for i in range(0, len(ext), 200):
        ch = ext[i:i + 200]
        if not ch:
            continue
        # r5 (1574 finding 5): these are the SLOW queries - three of them (401 ids, 200 per batch) ate 1,200 s against a
        # 50 s budget in the review's own simulation, after the email fallback had already been bounded. A batch that
        # cannot start leaves its threads unresolved and COUNTED, so the audience truncates instead of overrunning.
        if deadline is not None and time.monotonic() >= deadline:
            counts["map_batches_stopped_at_budget"] += 1
            counts["map_users_unresolved_at_budget"] += len(ext) - i
            break
        for uid, pro, a0 in query("SELECT CAST(id AS varchar), coalesce(neptuneprofessionalid, ''), coalesce(auth0userid, '') "
                                  f"FROM postgresql_core.public.users WHERE neptuneprofessionalid IN ({_q(ch)}) "
                                  f"OR auth0userid IN ({_q(['auth0|' + x for x in ch])}) OR auth0userid IN ({_q(ch)})"):
            for k in (pro, a0, a0.replace("auth0|", "")):
                if k:
                    by_ext[k].add(uid)
    emails: dict[str, str] = {}
    for d in due:
        if not by_ext.get(d["ext"]):
            if deadline is not None and time.monotonic() >= deadline:
                counts["map_users_stopped_at_budget"] += 1    # this thread's account cannot be resolved this run
                continue
            try:
                em = str(ic("GET", f"/contacts/{d['cid']}", None).get("email") or "").strip().lower()
            except Exception:  # noqa: BLE001 - unreadable contact: unmapped
                em = ""
            if em:
                emails[d["conv"]] = em
    by_email: dict[str, set[str]] = collections.defaultdict(set)
    em_list = sorted(set(emails.values()))
    for i in range(0, len(em_list), 200):            # (a non-empty chunk by construction: never `IN ()`)
        # QA #1574 (Important, 4th round): this was the LAST unbounded replica query in preparation. The contact GETs
        # above are bounded one by one, but the `email IN (...)` batches that follow them were not: 401 distinct fallback
        # addresses make three batches of 200, each ~500 s on the real replica, so the third STARTED after the deadline
        # had already passed and the tick overran its bounded scan window, delaying every downstream family. Read the
        # same clock as everything else; a batch that cannot start leaves its threads unresolved and COUNTED, and
        # build() carries them into `pending` so the next run decides them before it searches again.
        if deadline is not None and time.monotonic() >= deadline:
            counts["map_email_batches_stopped_at_budget"] += 1
            counts["map_emails_unqueried_at_budget"] += len(em_list) - i
            break
        for uid, em in query("SELECT CAST(id AS varchar), lower(email) FROM postgresql_core.public.users "
                             f"WHERE lower(email) IN ({_q(em_list[i:i + 200])})"):
            by_email[em].add(uid)
    rows = []
    for d in due:
        us = by_ext.get(d["ext"]) or by_email.get(emails.get(d["conv"], ""), set())
        if len(us) != 1:
            counts["skipped_user_unmapped_or_ambiguous"] += 1
            continue
        rows.append({**d, "user_id": next(iter(us)), "mapped_by": "external_id" if by_ext.get(d["ext"]) else "email"})
    return rows


# The deployed trigger_class rules decided from the thread alone, BEFORE any title / filing input: their verdict is the
# send's verdict whatever the replica says, so the (slow: ~35 s, all the user's threads) full check is not needed.
THREAD_ONLY_NON_STATUS = ("part not in thread", "not the customer's latest part", "stale part")


def trigger_decides(trigger: dict[str, Any] | None) -> bool:
    """True when the scan's own run of the deployed trigger_class already settles the part as NON-STATUS, so the slow
    full check (whose status_trigger would compute the same verdict from the same rules) is not needed to list it as a
    hand-off. Two cases: a thread-only rule (THREAD_ONLY_NON_STATUS, decided before any replica input), or a trigger
    computed with the REPLICA inputs (`inputs == "replica"`: titles / filed / other_titles from trigger_inputs). A
    thread-only trigger that says anything else never decides - the full check still runs. A STATUS verdict never
    short-circuits anything: the send-time gate is the only thing that answers."""
    if not trigger or trigger.get("class") != "non_status":
        return False
    why = str(trigger.get("why") or "")
    return trigger.get("inputs") == "replica" or why.startswith(THREAD_ONLY_NON_STATUS)


def classify(u: dict[str, Any], cid: str, checker: Callable[..., dict[str, Any]], query: Query, ic: Intercom,
             trigger: dict[str, Any] | None = None) -> tuple[str, str]:
    """(bucket, detail) from the gate's own send-time check: answer | class:<campaign> | handoff | held | unreadable."""
    if trigger_decides(trigger):
        return "handoff", "reply_due:non_status_part (handoff:product): " + str(trigger["why"])
    try:
        r = checker("uvn-status", "uvn", int(u["user_id"]), u["request_ids"], cid, conversation=u["reply_due"]["conversation"],
                    query=query, ic=ic, reply_due_part=u["reply_due"]["part"])
    except Exception as exc:  # noqa: BLE001 - unknown = never a batch slot
        return "unreadable", type(exc).__name__
    why = [str(w) for w in r.get("reasons") or []]
    if not r.get("hold"):
        return "answer", ""
    if any(w.startswith("reply_due:non_status_part") for w in why):
        return "handoff", "; ".join(why)[:300]
    cls = [w.split(":", 2)[2] for w in why if w.startswith("reply_due:class_is:")]
    if cls and len(why) == 1:
        return f"class:{cls[0]}", ""
    return "held", "; ".join(why)[:300]


def build(*, ic: Intercom = comm_state.intercom, query: Query = comm_state.trino, paying_path: str = PAYING,
          dv_store: str = DV_STORE, now: float | None = None, cap: int | None = None,
          max_checks: int | None = CHECK_MAX, budget_seconds: float | None = CHECK_BUDGET_S, start_entry: int = 0,
          walk_share: float = WALK_SHARE,
          start_after_user: int | None = None,
          checker: Callable[..., dict[str, Any]] = comm_state.check, ledger_path: str | None = None,
          upstream_resume: dict[str, Any] | None = None,
          trigger: Callable[..., dict[str, Any]] = comm_state.trigger_class,
          linked: Callable[[int, str], "set[str]"] = comm_state.linked_request_ids) -> dict[str, Any]:
    """`trigger` / `linked`: the deployed trigger_class and linked_request_ids (comm_state), injectable for tests only.
    The scan runs them over the thread it already holds plus the batched replica reads (trigger_inputs) so the full
    check is spent on STATUS parts only; the gate re-runs its own status_trigger at send time regardless."""
    now = now or time.time()
    counts: collections.Counter = collections.Counter()
    convs: dict[str, dict[str, Any]] = {}      # due thread id -> the conversation due_threads fetched (never output)
    titles: dict[tuple[str, str], str] = {}    # (user, request) -> track title of a PENDING request (TITLES_QUERY)
    # r5 (1574 finding 2): the budget started AFTER the unbounded upstream work - `apology_rows` walks every historical
    # sent-apology conversation and `candidates`/`due_threads` fetch and evaluate every candidate, so the timer only ever
    # measured the part that was already bounded. It now starts HERE, before the first upstream call, and every walk
    # checks it between pages and fetches. A run whose preparation ate the budget leaves its page un-done (page.end =
    # start), so the cursor does not advance and the next tick re-walks it instead of skipping what it never reached.
    deadline = (time.monotonic() + float(budget_seconds)) if budget_seconds else None
    # firstmate 034 (A): the walks get a SHARE of the budget, the reply work gets the whole of it. See WALK_SHARE.
    # QA #1828: and each walk stage gets a bounded slice of that share, so no early walk can starve a later one.
    walk_end = (time.monotonic() + float(budget_seconds) * float(walk_share)) if budget_seconds else None
    stages_left = WALK_STAGES

    def walk_slice() -> float | None:
        """The deadline for the NEXT walk stage: its share of what is left of the walk budget.

        Called once per stage, in order. A stage that finished early leaves more for the ones after it; a stage that
        overran its slice leaves them the remainder rather than nothing, which is the whole point - the walks are
        resumable, so a short slice defers work, while an expired deadline silently drops it.
        """
        nonlocal stages_left
        if walk_end is None:
            return None
        stages_left -= 1
        now = time.monotonic()
        remaining = walk_end - now
        if remaining <= 0:
            return now
        return now + remaining / (stages_left + 1)
    # ap1: the backlog-apology threads first - an unreadable ledger fails the scan (never a silent "nobody replied")
    sent = apology_threads(ledger_path or comm_state.LEDGER)
    resume = dict(upstream_resume or {})
    ap_rows, ap_unreadable, ap_next = apology_rows(sent, ic, now, counts, deadline=walk_slice(),
                                                   resume_after=resume.get("apology"))
    # r5 (1574 finding 4): the resume token alone was WRONG. The search advanced `starting_after` as it paged, but the
    # candidates it collected are only EVALUATED afterwards by due_threads - so a tick that died in a slow search page, or
    # inside due_threads, resumed the search PAST rows nobody had looked at, and repeated slow pages would never produce
    # an answerable user. The pending rows are carried as DATA now: they are evaluated first, and a row is consumed only
    # once due_threads has decided about it.
    pending = [p for p in (resume.get("pending") or []) if isinstance(p, dict) and p.get("conv")]
    # a reply to the apology is i1's to answer (it asked the question): never also an automatic uvn-line answer
    routed = [c for c in pending if c["conv"] in sent]
    pending = [c for c in pending if c["conv"] not in sent]
    # QA #1574 (Important, 3rd round): PENDING FIRST. The search shares this deadline, so a slow search could spend all
    # of it and leave already-owed replies unevaluated in every tick that took the same path - carried forever, never
    # decided.
    # QA #1574 (7th round, Important - carried replies starved behind a fresh search): deciding them first was only half
    # of it. Their MAPPING and the replica FACTS read (and so the send-time classification) still happened after the
    # search, so a tick whose searches ate the remaining budget re-fetched the same carried reply, decided it again,
    # never mapped it, and put it back in `pending` - a livelock in which the oldest owed reply could never reach the
    # family. Each half now runs its WHOLE preparation (due -> mapped -> facts -> classified) before the next thing that
    # can starve it: the carried half before the search, the fresh half after. A budget-staved tick therefore always
    # spends what it has on the work it already owed, and the search only ever gets what is left.
    due: list[dict[str, Any]] = []
    unevaluated: list[dict[str, Any]] = []
    by_class: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    handoff, held, answer = [], [], []
    checked = 0
    page_start, page_stop, page_total, end_user, anchor_idx = 0, 0, 0, None, None
    # shared preparation state: BOTH halves write into these, so the facts table the signer reads covers every row the
    # run decided (a carried row's facts are as much a fact for the signer as a fresh one's).
    first: dict[str, dict[str, Any]] = {}
    req: dict[str, list[str]] = collections.defaultdict(list)
    facts: dict[str, list[list[Any]]] = collections.defaultdict(list)
    lat: dict[tuple[str, str], str] = {}
    names: dict[str, str] = {}
    accts: dict[str, dict[str, str]] = {}
    paying: set[str] = set()

    def prep_and_walk(due_rows: list[dict[str, Any]], *, sliced: bool) -> None:
        """map -> facts -> one page of send-time checks, for ONE half of this run.

        `sliced` marks the half the SEARCH produced: only that half owns the positional/anchor cursor, because only that
        list is the slice the tick's search token describes. The carried half is walked from its head every time it is
        carried (it is, by definition, work this run has not finished yet).
        """
        nonlocal checked, page_start, page_stop, page_total, end_user, anchor_idx
        nonlocal first, req, facts, lat, names, accts, paying
        mapped = map_users(due_rows, ic, query, counts, deadline=deadline)
        if not sliced:
            counts["candidates_mapped_from_carry"] = len(mapped)
        for r in sorted(mapped, key=lambda r: r["at"]):
            if r["user_id"] in NEVER:
                counts["skipped_never"] += 1
                continue
            first.setdefault(r["user_id"], r)           # one answer per user per batch: their oldest waiting thread
        if not paying:
            with open(paying_path, encoding="utf-8") as fh:
                paying = {str(x) for x in (json.load(fh).get("ids") or [])}
        uids = [u for u in sorted(first, key=int) if u not in req]     # a user decided by an earlier half is not re-read
        try:
            dv = sqlite3.connect(f"file:{dv_store}?mode=ro", uri=True)
            for u, rid, o in dv.execute("SELECT user_id, lower(request_id), outcome FROM dv_outcomes WHERE user_id IS NOT NULL ORDER BY at, id"):
                lat[(str(u), rid)] = o
        except sqlite3.Error:
            counts["dv_store_unreadable"] += 1           # dv_latest is a fact for the signer, never a gate here
        for i in range(0, len(uids), 300):
            # r5 (1574 finding 2, round 2): the replica reads are chunked, not free - a slow batch must not walk past the
            # deadline. A user whose facts were never read is never answered (it is not in `uids` any more) and the count
            # makes the truncation visible to the signer.
            if deadline is not None and time.monotonic() >= deadline:
                counts["facts_stopped_at_budget"] = len(uids) - i
                uids = uids[:i]
                break
            ids = ",".join(uids[i:i + 300])
            for u, rid, st, pr, rs in query(FACTS_QUERY.format(ids=ids)):
                req[u].append(rid)
                facts[u].append([rid, st, pr == "true", rs == "true", lat.get((u, rid), "")])
            for u, rid, t in query(TITLES_QUERY.format(ids=ids)):
                titles[(str(u), str(rid).lower())] = str(t or "").strip()
            for u, fn, em, pro, a0 in query("SELECT CAST(id AS varchar), coalesce(firstname, ''), coalesce(lower(email), ''), "
                                            "coalesce(neptuneprofessionalid, ''), coalesce(auth0userid, '') "
                                            f"FROM postgresql_core.public.users WHERE id IN ({ids})"):
                names[u] = fn.strip()
                accts[u] = {"email": em.strip(), "id": u, "professional_id": pro.strip(), "auth_id": a0.strip(),
                            "first_name": fn.strip()}
        users = [{"user_id": int(u), "paid": u in paying, "skip": None, "class": "reply_due", "request_ids": sorted(req.get(u, [])),
                  "reply_due": {"part": first[u]["part"], "conversation": first[u]["conv"]},
                  "_thread": {"assignee": first[u]["assignee"], "prior_note": first[u]["prior_note"],
                              "waiting_since": first[u]["at"], "mapped_by": first[u]["mapped_by"]}} for u in uids]
        users.sort(key=lambda x: (not x["paid"], x["_thread"]["waiting_since"]))
        # Fable d2: the deployed trigger rules, run here with the replica inputs the batched reads supplied. A user whose
        # inputs could not be read keeps the thread-only trigger (the full check decides, as before); nothing here is a
        # send decision - a non_status verdict lists a hand-off, a status verdict buys the full check.
        for u in uids:
            if trigger_decides(first[u].get("trigger")):
                continue                                     # a thread-only verdict stands; no replica input changes it
            conv = convs.get(str(first[u]["conv"]))
            if conv is None:
                counts["trigger_inputs_no_thread"] += 1
                continue
            try:
                rows = [(rid, st, titles.get((u, rid), "")) for rid, st, *_ in facts.get(u, [])]
                t, f, o = comm_state.trigger_inputs(req.get(u, []), rows, linked(int(u), str(first[u]["conv"])))
                first[u]["trigger"] = {**trigger(conv, first[u]["part"], titles=t, now=now, filed=f, other_titles=o),
                                       "inputs": "replica"}
            except Exception as exc:  # noqa: BLE001 - unknown inputs: the full check decides this user, as before
                counts["trigger_inputs_unreadable:" + type(exc).__name__] += 1
        # r5 (1574 finding 6): a due thread that was EVALUATED but then dropped by a downstream budget stop (a mapping batch
        # or a facts chunk) produced no audience row - so committing the search token resumed PAST it and the reply it holds
        # would never be answered from that slice. Those threads go back into `pending`: the next run re-evaluates them first,
        # which is what makes the token safe to commit at all.
        if (counts["map_batches_stopped_at_budget"] or counts["map_users_stopped_at_budget"]
                or counts["map_email_batches_stopped_at_budget"] or counts["facts_stopped_at_budget"]):
            answered = {int(u) for u in uids}
            dropped = [d for d in due_rows if d["conv"] not in {m["conv"] for m in mapped if int(m["user_id"]) in answered}]
            upstream["pending"] = (upstream.get("pending") or []) + dropped
            counts["candidates_carried_to_next_run"] = len(upstream["pending"])
        # QA #1574 (Important): a run walks ONE page of this audience - [start_entry, end) - and stops at the first bound
        # that is reached, so the timer's cost is bounded BEFORE the checks rather than by the tick's SIGTERM. page {start,
        # end, listed} is need_asks' record (the tick's cursor starts the next run exactly where this one stopped), so a
        # head of persistently held users is walked PAST instead of being re-checked every tick.
        total = len(users)
        # QA #1574 (round 6, Important): `start_entry` is a POSITION inside the list THIS RUN built, and the list is built
        # from (pending, search token). When a slice comes back shorter than the position the tick carried - the rows ahead
        # of it were answered or closed - clamping to `total` examined NOBODY and still reported the page as finished, so the
        # cursor wrapped to 0 and every row of that slice after the position was skipped (for a one-row slice: the whole
        # slice). The position is now reset to the START of the slice instead, and the reset is counted, so the failure mode
        # is a re-check (bounded, and the ledger refuses a second note to the same user on the same day) rather than a skip.
        # QA #1574 (7th round, Important - a live audience shrinks ahead of a positional cursor): a POSITION into a list
        # that is REBUILT every tick is not a resume point. Tick 1 checks and sends the first 100 of 300; those threads are
        # answered, so the next build holds 200 and "start at 100" skipped the next 100 owed replies outright. The cursor is
        # now the IDENTITY of the last entry this run examined (`page.end_user`), and the next run resumes AFTER THAT ROW.
        # When the anchor is gone from the rebuilt list, the rows in front of it are the ones that were handled - so the
        # slice is entered at its head again (a bounded re-check; the ledger refuses a second note to the same user on the
        # same day), counted, and never a skip. `start_entry` stays as the positional fallback for a first run, for a
        # runner that does not carry an anchor yet, and for the tests that pin the positional bound.
        raw_start = int(start_entry or 0) if sliced else 0
        start = max(0, raw_start) if total else 0
        anchor_idx = None
        if sliced and start_after_user is not None and total:
            want = int(start_after_user)
            anchor_idx = next((i for i, u in enumerate(users) if u["user_id"] == want), None)
            if anchor_idx is None:
                counts["anchor_missing_reset"] = 1
                start = 0
            else:
                start = anchor_idx + 1
        elif total and start >= total:
            counts["start_entry_clamped"] = start
            start = 0
        start = min(start, total)
        stop = total
        for n, u in enumerate(users[start:], start):
            if cap is not None and len(answer) >= cap:
                counts["not_checked_after_cap"] = total - n      # the batch is full: the rest wait for the next run
                stop = n
                break
            if max_checks is not None and checked >= int(max_checks):
                counts["not_checked_after_checks"] = total - n   # the run's check budget: measured, never silent
                stop = n
                break
            if deadline is not None and time.monotonic() >= deadline:
                counts["not_checked_after_budget"] = total - n   # the run's wall-clock budget: measured, never silent
                stop = n
                break
            if n % 25 == 0:
                print(f"reply_due_scan: checked {n}/{total}, answerable {len(answer)}", file=sys.stderr, flush=True)
            tr = first[str(u["user_id"])].get("trigger")
            counts["check_skipped:trigger_non_status" if trigger_decides(tr) else "full_checks"] += 1
            bucket, detail = classify(u, first[str(u["user_id"])]["cid"], checker, query, ic, tr)
            checked += 1
            counts[f"bucket:{bucket.split(':')[0]}"] += 1
            if bucket == "answer":
                answer.append(u)
            elif bucket.startswith("class:"):
                by_class[bucket[6:]].append(u)
            elif bucket == "handoff":
                handoff.append({**u, "why": detail, "_account": accts.get(str(u["user_id"]), {})})
            else:
                held.append({**u, "why": detail or bucket})
        # `end_user` is the IDENTITY the next run resumes after (see the anchor note above the walk): the last entry this
        # slice EXAMINED. Null when the walk reached the end of the slice - the cursor then wraps and the search token may
        # move. Only the SEARCHED half publishes it: the carried half is not the slice the token describes.
        if sliced:
            end_user = users[stop - 1]["user_id"] if (stop < total and stop > start) else None
            page_start, page_stop, page_total = start, stop, total

    # QA #1574 (8th round, Important - a carried row crashed the scan when its OWN preparation hit the budget):
    # `prep_and_walk` writes `upstream["pending"]` when a mapping batch or a facts chunk stops at the deadline, and the
    # carried half runs BEFORE the search assigned that dict - so a carried reply whose facts read crossed the deadline
    # raised NameError, `_main` did not catch it, no audience file was written and the outbound tick stopped. The upstream
    # state now exists from the start; the search's cursors are MERGED INTO it rather than replacing it, so rows the
    # carried half had to drop are carried to the next run instead of silently lost.
    upstream: dict[str, Any] = {}
    if pending:
        counts["candidates_resumed"] = len(pending)
        carried_due, unevaluated = due_threads(pending, ic, now, counts, deadline=walk_slice(), convs=convs)
        if carried_due:
            prep_and_walk(carried_due, sliced=False)          # owed work first: mapped, facts read, classified
    cands, cand_next = candidates(ic, now, counts=counts, deadline=walk_slice(),
                                  resume_after=resume.get("candidates"))
    upstream["candidates"] = cand_next
    upstream["apology"] = ap_next
    counts["threads_customer_waiting"] = len(pending) + len(cands)
    routed += [c for c in cands if c["conv"] in sent]
    counts["routed_backlog_apology"] = len(routed)
    cands = [c for c in cands if c["conv"] not in sent]
    fresh_due, fresh_unevaluated = due_threads(cands, ic, now, counts, deadline=walk_slice(), convs=convs)
    due += fresh_due
    unevaluated += fresh_unevaluated
    counts["threads_due"] = len(due)
    if unevaluated:
        # keep the work: the next run evaluates these BEFORE it searches again, and this is what makes the budget a pause
        # rather than a loss. MERGED with whatever the carried half already had to drop (deduped by conversation, order
        # preserved): the half that runs first must not be overwritten by the half that runs second.
        carried: list[dict[str, Any]] = []
        seen: set[str] = set()
        for r in (upstream.get("pending") or []) + list(unevaluated):
            if r.get("conv") in seen:
                continue
            seen.add(r.get("conv"))
            carried.append(r)
        upstream["pending"] = carried
        counts["candidates_carried_to_next_run"] = len(carried)
    prep_and_walk(fresh_due, sliced=True)                     # the searched slice: this one owns the cursor
    start, stop, total = page_start, page_stop, page_total
    users = answer
    if cap is not None:
        users = users[:cap]
    table = [{"user_id": u["user_id"], "rows": sorted(facts.get(str(u["user_id"]), [])), "paid": u["paid"],
              "first_name_missing": not names.get(str(u["user_id"])), "assignee": u["_thread"]["assignee"],
              "prior_note": u["_thread"]["prior_note"], "conversation": u["reply_due"]["conversation"],
              "part": u["reply_due"]["part"]} for u in users]
    blob = json.dumps(table, separators=(",", ":"), sort_keys=True, default=str)
    gen = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    counts["listed"], counts["listed_paid"] = len(users), sum(1 for u in users if u["paid"])
    counts["checked"] = checked
    # `unwalked` names what this run left behind inside the slice it built: the tick reads it to keep the search token on
    # this slice (it may only move when end == listed, i.e. when every collected row has been walked).
    page = {"start": start, "end": stop, "listed": total, "unwalked": total - stop,   # page_next/advance_cursor read end/listed
            "end_user": end_user, "anchor": anchor_idx}
    return {"generated_at": gen, "page": page, "upstream": upstream,
            "source": "reply_due_scan: open, customer waiting > 24 h, comm_state.reply_due() = due",
            "counts": dict(counts),
            "replica_facts": {"query": FACTS_QUERY, "columns": ["request", "status", "proof_required", "review_stage", "dv_latest"],
                              "sha256": hashlib.sha256(blob.encode()).hexdigest(), "read_at": gen},
            "facts": table, "users": users, "by_class": dict(by_class), "handoff": handoff, "held": held,
            "covers_campaigns": list(COVERS_CAMPAIGNS), "backlog_apology": ap_rows,
            "backlog_apology_unreadable": ap_unreadable}


def ref_rows(doc: dict[str, Any], rows_path: str) -> int:
    """c1 577 / p1 616: the reply-ref picker's input - one JSONL row {conversation, part, credits_file, user_id} per
    PRODUCT handoff (reply_due:non_status_part), each with its own 0600 credits file in <rows_path>.d/ holding the gate's
    own input: the account (email, id, professional id, Auth0 subject, first name) and the reply's one key
    (request_id 'reply-<part>'; shape placeholders). A row without a mapped account email is not written. -> rows."""
    d = rows_path + ".d"
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)                                # QA #1574: an existing dir is corrected too
    n, lines = 0, []
    for u in doc.get("handoff") or []:
        acct, rd = u.get("_account") or {}, u.get("reply_due") or {}
        conv, part = str(rd.get("conversation") or ""), str(rd.get("part") or "")
        why = str(u.get("why") or "")
        # a product question the picker may answer: non_status_part, but never a thread-only reason (the part is not
        # in the thread / not the latest / stale) - nothing may be answered there
        if "non_status_part" not in why or any(t in why for t in THREAD_ONLY_NON_STATUS):
            continue
        if not acct.get("email") or not (conv.isdigit() and part.isdigit()):
            continue
        cf = os.path.join(d, f"{conv}-{part}.json")
        # QA #1574: each sidecar is a NEW 0600 temp file replaced into place (a reader of the published index never
        # sees an empty or half-written file); the index itself is published last, also atomically
        write_text(cf, json.dumps({"user": {k: v for k, v in acct.items() if v},
                                   "credits": [{"request_id": f"reply-{part}", "role": "-", "track_title": "-",
                                                "artist_name": "-"}]}))
        lines.append(json.dumps({"conversation": conv, "part": part, "credits_file": cf, "user_id": str(u["user_id"])}))
        n += 1
    write_text(rows_path, "".join(ln + "\n" for ln in lines))
    return n


def write_text(path: str, text: str) -> None:
    fd, tmp = tempfile.mkstemp(prefix=".reply-ref-rows-", dir=os.path.dirname(os.path.abspath(path)))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def write(path: str, doc: dict[str, Any]) -> None:
    """0600, atomic (a NEW temp file in the same directory, then replace) - never a half-written list."""
    fd, tmp = tempfile.mkstemp(prefix=".reply-due-", dir=os.path.dirname(os.path.abspath(path)))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, default=str)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="class-G reply_due audience (read-only scan)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--cap", type=int, default=None, help="list at most N users (paid first)")
    ap.add_argument("--max-checks", type=int, default=CHECK_MAX,
                    help=f"gate checks this run, held users included (default {CHECK_MAX}; 0 = unbounded)")
    ap.add_argument("--budget-seconds", type=int, default=int(CHECK_BUDGET_S),
                    help=f"wall clock for the checks (default {int(CHECK_BUDGET_S)}s; 0 = unbounded)")
    ap.add_argument("--start-entry", type=int, default=0,
                    help="first audience entry this run examines (the tick's cursor: page.end from the last run)")
    ap.add_argument("--start-after-user", type=int, default=None,
                    help="resume AFTER this user id (the last entry the previous run examined: page.end_user). A "
                         "position is not a resume point in a list that is rebuilt every run - an answered row "
                         "vanishes and shifts every position behind it; the identity cannot shift.")
    ap.add_argument("--upstream-resume", default="", metavar="JSON",
                    help="the upstream walk cursors the last starved run stopped at ({candidates, apology}); "
                         "the next run RESUMES there instead of restarting the search and the historical walk")
    ap.add_argument("--ref-rows", default="", metavar="JSONL",
                    help="also write the reply-ref picker's rows (product handoffs, each with its credits_file)")
    a = ap.parse_args(argv)
    resume: dict[str, Any] = {}
    if a.upstream_resume and os.path.exists(a.upstream_resume):
        try:
            with open(a.upstream_resume, encoding="utf-8") as fh:
                loaded = json.load(fh)
            resume = loaded if isinstance(loaded, dict) else {}
        except (OSError, ValueError):
            resume = {}                     # an unreadable cursor restarts the walk: slower, never wrong
    try:
        doc = build(cap=a.cap, max_checks=a.max_checks or None, budget_seconds=a.budget_seconds or None,
                    start_entry=a.start_entry, start_after_user=a.start_after_user,
                    upstream_resume=resume)
    except (comm_state.Unknown, OSError, ValueError, sqlite3.Error) as exc:
        print(f"REPLY DUE SCAN FAILED: {exc}; no list written", file=sys.stderr)
        return 1
    write(a.out, doc)
    if a.ref_rows:
        doc["counts"]["ref_rows"] = ref_rows(doc, a.ref_rows)
    print(json.dumps({"out": a.out, **doc["counts"], "facts_sha256": doc["replica_facts"]["sha256"][:12]}))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
