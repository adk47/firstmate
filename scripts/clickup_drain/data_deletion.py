#!/usr/bin/env python3
"""Close the ClickUp `action:data-deletion` ticket on the register's WRITTEN CONFIRMATION.

WHY THIS EXISTS
---------------
Captain 2026-10-29 13:2xZ: *"make sure the GDPR profile removals work end to end"*.
Measured on the live register (2026-11-03): 374 rows / 372 open, 159 past the
statutory 30-day date, `ask_sent_at` on zero rows, `confirmed_at` on one — plus
156 OPEN `action:data-deletion` ClickUp tickets (249 with `include_closed=false`,
of which 93 already sit in `resolved`) that nobody closes even after the erasure
completes. The register is the legal record; the board is the work queue. Nothing
joined them, so the queue rotted and the two numbers could disagree in public.

THE ONE RULE THAT MATTERS: CLOSE ON THE CONFIRMATION, NEVER ON THE HIDE
----------------------------------------------------------------------
`outcomeChannelFor("data-deletion") = erasure` — the customer-visible outcome for
an erasure request is the register's own written confirmation (`confirmed_at`,
backed by an `erasure_sends` row of kind `confirm`), NOT a ClickUp status line
and NOT the hide. Hiding is step 3 of 5 (`hidden_at`: 410 + noindex read back);
the letter is step 5. Telling the board — and through it, everyone reading the
board — that a removal is done because the page is down is precisely the false
statement the register exists to prevent. So:

  `confirmed_at` set                  -> `customer-outcome:complete` (close)
  `hidden_at` set, no confirmation    -> NOTHING, reported as hidden-not-confirmed
  `status='closed'`, no confirmation  -> NOTHING (a markdown-register row a human
                                         closed is not evidence a letter went out)
  past `due_at`, no confirmation      -> reported as OVERDUE, never tagged

THE `status='closed'` CONJUNCT (a correction, with evidence)
-----------------------------------------------------------
The dispatch spec asked for rows with `status = 'closed'` AND `confirmed_at`.
Verified against the register's own code, those two fields are not both written
on a completion: `gdpr_pipeline/run.py` `confirmations()` iterates
`store.all("open")` and skips rows that already carry `confirmed_at`, i.e. a
confirmed row deliberately STAYS `open` in `status`, and the only writer of
`status='closed'` is the markdown register's COMPLETED marker
(`run.py:160-161`, `intake.py:279-290`). Requiring both would select zero rows
forever — a drainer that can never close a ticket. Live 2026-11-03 proves both
directions of the mismatch: row 13 is `closed` with no `confirmed_at`, row 19 is
`confirmed_at` (markdown `CONFIRMATION SENT`) with no ticket and `status='open'`.
So the completion test is `confirmed_at` (the letter), and a CLOSED row without
one is reported, never closed. If the register ever starts closing confirmed
rows, this rule still holds unchanged.

THE TWO HARD VETOES
-------------------
1. `class in (legal_threat, dmca_takedown)` NEVER closes on a tag: those go out
   by letter from counsel. Their open tickets get `customer-outcome:blocked` with
   the register row id in the digest, so the board stops pretending the queue is
   normal work. A legal row that ALREADY carries a confirmation is not tagged at
   all — `blocked` would be a false statement about a case that was answered —
   and is reported for counsel's owner.
2. A row past `due_at` without `confirmed_at` is OVERDUE. This drainer is the
   only place a ticket can show the legal clock, so each run emits the overdue
   count and the tickets behind it in the same digest line as the board numbers.
   An overdue row is never tagged `complete` and never `not-applicable`.

THE MESSAGE IS THE LETTER
-------------------------
`data-deletion` is absent from `resolve-notify.py`'s allowlist, and that is
correct: the register's `erasure_sends` confirmation is the customer's only
message. The ticket close is therefore SILENT toward the customer and only moves
the board. This module holds no send capability at all: it does not import
`gdpr_pipeline` (let alone `gdpr_pipeline.send`), has no Intercom or Gmail code
path, and `tests/test_clickup_drain_data_deletion.py` asserts both.

WHAT "CLOSE" MEANS (two writes, in this order)
---------------------------------------------
`customer_outcome.customer_complete()` is true only for a ticket that is BOTH
terminal and carries `customer-outcome:complete`, so labelling without closing
would leave every ticket open — the complaint that started this work. A confirmed
row therefore does two writes: the outcome tag, then the status `resolved`. Tag
first, status second: if the process dies between them, the ticket is honestly
labelled and still open, never closed and unlabelled — and the NEXT run finishes
it, because a `complete` tag on a non-terminal ticket is a half-state, not a
no-op ("already tagged" must not make an interrupted completion permanent). An outcome tag is also
REPLACED, never added: `customer_outcome_of()` answers None for a ticket with two
outcome tags (ambiguity fails closed), so `POST`-ing a second one would silently
unset the outcome of somebody else's writer (see
`uvn-under30-cron.py:replace_customer_outcome_tag`).

THE RECONCILER, AND WHY THIS CLOSES AT ALL
------------------------------------------
`scripts/clickup-reconcile.py` (PR #1706) is the default closer: it reads a
terminal marker off the ticket and writes `resolved` + an audit comment. It
cannot DECIDE this close, because the fact the close rests on — the register's
written confirmation — is in a sqlite file, not on the board. So the close is a
drainer's specialization, not a second writer of somebody else's decision, and it
keeps the reconciler's two hard shapes: label first, close second, and leave the
reason as an internal comment naming the record (`notify_all: false`, so nobody
is emailed). With the reconciler merged the two converge: whichever runs first
wins the status write, and neither closes on evidence it did not read.

TICKET -> REGISTER BACK-LINK
----------------------------
A ticket that is open and has NO register row is a hole in the register's own
intake (the register's hourly `tick` re-ingests every open data-deletion ticket,
so a ticket the register still does not know after a tick means that intake read
failed or the ticket arrived after the run). This drainer writes NOTHING to that
ticket and creates NO register row — identity verdicts and the hide decision live
in exactly one place. It emits one work item per ticket to the register's intake
(`<state>/intake-gaps.jsonl`, with the `gdpr-pipeline.py` command that owns the
retry) and reports the count; a gap that survives `--gap-runs` runs pages, because
then the register's own retry is not fixing it.

A ticket whose CONVERSATION already has a row but which is missing from that
row's `clickup_ids` is `link-pending`, not a gap: the register's next tick writes
the link and this drainer closes the ticket on the confirmation after it.

SAFETY
------
`--dry-run` is the default (`--apply` writes) and covers everything except the
writes. 200 outcome writes per run, hard-capped (a completion also costs one
`PUT` for the status). Kill file
`/etc/hydra/clickup-drain-data-deletion.disabled` refuses every write and every
page. Every write is ledgered before it is made and read back after it
(`/var/lib/hydra/clickup-drain/data-deletion.jsonl`), and `--revert <ledger>`
removes exactly the tags that ledger recorded. The register is opened with
SQLite `mode=ro`, so this module cannot write a register row even by accident.

USAGE
  ./scripts/clickup_drain/data_deletion.py                    # dry run, human report
  ./scripts/clickup_drain/data_deletion.py --json             # dry run, machine report
  ./scripts/clickup_drain/data_deletion.py --apply
  ./scripts/clickup_drain/data_deletion.py --revert /var/lib/hydra/clickup-drain/data-deletion.jsonl
  ./scripts/clickup_drain/data_deletion.py --probe 869abc123  # add+read-back+remove one tag
  ./scripts/clickup_drain/data_deletion.py --board-json dump.json   # offline board scan

ENV
  CLICKUP_API_KEY / MUSOAI_CLICKUP_API_KEY  token (required for a live scan/write)
  CLICKUP_DRAIN_LIST                        list id (default 901000600160)
  GDPR_STORE                                the register (default
                                            /var/lib/hydra-gdpr/erasure.sqlite)
  CLICKUP_DRAIN_DATA_DELETION_STATE         state dir (default
                                            /var/lib/hydra/clickup-drain)
  CLICKUP_DRAIN_DATA_DELETION_CHANNEL       digest channel (default #cs_chats)
  CLICKUP_DRAIN_DATA_DELETION_DISABLED      kill file override (tests)

EXIT
  0 ok (including "nothing to do"), 2 a read failed so NOTHING was written,
  4 the kill file refused the run, 5 a write did not land (POST/DELETE/PUT
  errored, or did not read back — the unit is OnFailure-wired, so this is what
  fires the page when the best-effort Slack alert does not), 6 `--revert` could
  not undo everything it recorded.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]          # scripts/
sys.path.insert(0, str(SCRIPT_DIR))

LIST_ID = os.environ.get("CLICKUP_DRAIN_LIST", "901000600160")
DEFAULT_REGISTER = os.environ.get("GDPR_STORE", "/var/lib/hydra-gdpr/erasure.sqlite")
DEFAULT_STATE_DIR = os.environ.get(
    "CLICKUP_DRAIN_DATA_DELETION_STATE", "/var/lib/hydra/clickup-drain")
KILL_FILE = os.environ.get(
    "CLICKUP_DRAIN_DATA_DELETION_DISABLED", "/etc/hydra/clickup-drain-data-deletion.disabled")
# #cs_chats — the CS ops channel where board numbers are reported. The legal
# clock is Jan's (#cs_priority) and the register pages there itself; this is the
# board side of the same fact, in the channel that owns the board.
DEFAULT_CHANNEL = os.environ.get("CLICKUP_DRAIN_DATA_DELETION_CHANNEL", "C0ANM0PN9L5")
DEFAULT_SLACK_CONFIG = str(SCRIPT_DIR.parent / "openclaw-main.json")
DEFAULT_ALERT_CHANNEL = "C0ADV2W76G4"     # #clio_devops — a hydra bug, not a customer fact

# ClickUp workflow statuses that mean the ticket is still live work. `resolved`
# and `impossible` are terminal on this board; `include_closed=false` still
# returns `resolved` tickets (measured 2026-11-03: 249 returned, 93 `resolved`),
# so open-ness is decided by NAME here and never by the API flag.
OPEN_STATUSES = frozenset({"to do", "in progress", "waiting"})
TERMINAL_STATUSES = frozenset({"resolved", "impossible", "user updated"})

# The customer-outcome contract (scripts/lib/customer_outcome.py): these two
# names are the only tags this module writes. Written as literals so the module
# imports no register code and holds no send capability; a test pins them equal
# to the shared contract whenever that module is present.
TAG_COMPLETE = "customer-outcome:complete"
TAG_BLOCKED = "customer-outcome:blocked"
VALID_OUTCOME_TAGS = frozenset({
    TAG_COMPLETE, TAG_BLOCKED,
    "customer-outcome:partial",
    "customer-outcome:needs-customer",
    "customer-outcome:verification-required",
    "customer-outcome:not-applicable",
})
ACTION_TAG_PREFIX = "action:"
OUTCOME_TAG_PREFIX = "customer-outcome:"
CLICKUP_TASK_URL = "https://app.clickup.com/t/{}"

# Counsel's classes: never closed on a tag (dispatch §2, veto 1).
VETO_CLASSES = frozenset({"legal_threat", "dmca_takedown"})
# The classes the register's own watchdog watches; used only to break the
# overdue count down, never to filter it out of the report.
WATCHDOG_CLASSES = ("privacy_erasure", "legal_threat", "dmca_takedown", "privacy_access")

# The run's blast radius, counted in API MUTATIONS (a tag delete, a tag add, a
# status PUT, a comment) — NOT in tickets. One completion over a conflicting
# outcome tag is FOUR mutations, so a per-ticket cap of 200 could issue 800
# requests while the runbook promised a bound of 200.
MAX_WRITES_HARD = 200
DEFAULT_MAX_WRITES = 200
DEFAULT_GAP_RUNS = 3                       # a row-less ticket reported N runs -> page
DIGEST_TICKET_IDS = 12                     # ids named inline in the digest line
# How far a ticket's own close time may sit past the ledger's close record before
# the close is read as somebody else's. The record is written around the PUT, so
# the two are seconds apart; five minutes absorbs clock skew and a slow request
# without ever swallowing a human re-resolving the ticket later.
CLOSE_SLACK_MS = 5 * 60 * 1000


class MutationBudget:
    """How many API mutations this run may issue, spent before each one.

    Spent in MUTATIONS, not tickets: `customer-outcome:blocked` -> `complete` on a
    ticket that also needs closing is DELETE + POST + PUT + comment. A per-ticket
    count would let `--max-writes 200` issue 800 requests, which is not the bound
    the runbook promises.
    """

    def __init__(self, limit: int):
        self.limit = max(0, int(limit))
        self.used = 0

    def can_spend(self, n: int = 1) -> bool:
        return self.used + n <= self.limit

    def spend(self, n: int = 1) -> bool:
        if not self.can_spend(n):
            return False
        self.used += n
        return True


class RegisterUnavailable(RuntimeError):
    """The register could not be read. NOT "the register has no rows"."""


# ───────────────────────── the register (read-only) ─────────────────────────


def open_register(path: str) -> sqlite3.Connection:
    """Open the register read-only at the CONNECTION level.

    `mode=ro` is the guarantee that this drainer can never create or edit a
    register row (dispatch: identity verdicts and the hide decision live in one
    place). A missing file is a failed read, never an empty register: reporting
    "0 overdue" because a path moved is the green-run-that-covered-nothing
    failure the register was built to end.
    """
    if not os.path.exists(path):
        raise RegisterUnavailable(f"register not found at {path}")
    uri = "file:" + urllib.parse.quote(os.path.abspath(path)) + "?mode=ro"
    db = sqlite3.connect(uri, uri=True)
    db.row_factory = sqlite3.Row
    return db


def _json_list(raw) -> list:
    if not raw:
        return []
    try:
        value = json.loads(raw)
    except (TypeError, ValueError):
        return []
    return value if isinstance(value, list) else []


def load_register(path: str = DEFAULT_REGISTER) -> dict:
    """Every register row + the two join indexes this drainer needs.

    Read-only, one pass, no ORM. `by_clickup` / `by_conv` come from BOTH the row
    columns and `erasure_keys` (the idempotence table the intake writes): the two
    are written together, and a mismatch between them must not be the reason a
    real completion never closes its ticket.
    """
    db = open_register(path)
    try:
        try:
            raw_rows = db.execute(
                "SELECT id, register_no, status, class, confirmed_at, due_at, hide_due_at, hidden_at,"
                " clickup_ids, conversation_id, note FROM erasure_requests ORDER BY id").fetchall()
            raw_keys = db.execute("SELECT key, request_id FROM erasure_keys").fetchall()
        except sqlite3.DatabaseError as exc:
            raise RegisterUnavailable(f"register at {path} is not readable as the erasure schema: {exc}") from exc
    finally:
        db.close()

    rows = {}
    for r in raw_rows:
        d = dict(r)
        d["clickup_ids"] = [str(i) for i in _json_list(d.get("clickup_ids"))]
        d["confirmed_at"] = (d.get("confirmed_at") or "").strip()
        d["hidden_at"] = (d.get("hidden_at") or "").strip()
        d["status"] = (d.get("status") or "").strip() or "open"
        d["class"] = (d.get("class") or "").strip()
        d["keys"] = []
        rows[d["id"]] = d
    by_key = {}
    for k in raw_keys:
        key, rid = str(k["key"]), k["request_id"]
        by_key[key] = rid
        if rid in rows:
            rows[rid]["keys"].append(key)

    by_clickup, by_conv = {}, {}
    for rid, r in rows.items():
        for tid in r["clickup_ids"]:
            by_clickup.setdefault(tid, set()).add(rid)
        if r.get("conversation_id"):
            by_conv.setdefault(str(r["conversation_id"]), set()).add(rid)
    # The keys table is the idempotence record, so it fills in a missing column
    # value (never overrides a present one).
    for key, rid in by_key.items():
        if rid not in rows:
            continue
        if key.startswith("clickup:"):
            by_clickup.setdefault(key.split(":", 1)[1], set()).add(rid)
        elif key.startswith("intercom:"):
            by_conv.setdefault(key.split(":", 1)[1], set()).add(rid)
    return {"rows": rows, "by_key": by_key, "by_clickup": by_clickup, "by_conv": by_conv}


# ───────────────────────── ClickUp I/O ─────────────────────────


def _client():
    """The shared throttled client (lib/clickup_client.py). Imported lazily so a
    missing dependency is a clear runtime refusal, not an import-time crash in an
    unrelated test."""
    try:
        from lib import clickup_client
    except ImportError as exc:            # pragma: no cover - exercised on a dep-less tree
        raise RegisterUnavailable(
            "lib/clickup_client.py is missing (hydra PR #1706 / #1629 must land first)") from exc
    key = os.environ.get("CLICKUP_API_KEY") or os.environ.get("MUSOAI_CLICKUP_API_KEY") or ""
    if not key:
        raise RegisterUnavailable("CLICKUP_API_KEY or MUSOAI_CLICKUP_API_KEY is required")
    return clickup_client.shared(key)


def scan_board(client, list_id: str = LIST_ID) -> dict:
    """Every `action:data-deletion` ticket on the list, open and closed -> {id: task}.

    `include_closed=true` on purpose: a ticket the register is about to close may
    already be resolved by a human, and "which ticket ids exist" must not depend
    on a status this drainer does not control. `list_tasks` raises rather than
    returning a partial scan, which is what makes the "no register row" claim
    safe. `subtasks=true` mirrors the register's own intake query.
    """
    tasks = client.list_tasks(
        list_id,
        [("tags[]", "action:data-deletion"), ("include_closed", "true"), ("subtasks", "true")],
        60)
    out = {}
    for t in tasks:
        tid = str(t.get("id") or "")
        if tid:
            out[tid] = t
    return out


def tag_names(task: dict) -> list:
    """Every tag name on a task, lowercased — ClickUp names are compared
    case-insensitively by scripts/lib/customer_outcome.py, so they are here too."""
    return [str(x.get("name") or "").strip().lower()
            for x in (task or {}).get("tags") or [] if isinstance(x, dict)]


def outcome_tags_of(task: dict) -> set:
    """Every `customer-outcome:*` tag, mirroring lib/customer_outcome.py.

    The shared module's `customer_outcome_of()` answers None for two or more
    outcome tags (ambiguity fails closed), which is why a writer must REPLACE an
    outcome tag rather than add one.
    """
    return {n for n in tag_names(task) if n.startswith(OUTCOME_TAG_PREFIX)}


def status_of(task: dict) -> str:
    return str(((task or {}).get("status") or {}).get("status") or "").strip().lower()


def is_open(task: dict) -> bool:
    return status_of(task) in OPEN_STATUSES


def has_action_tag(task: dict) -> bool:
    return "action:data-deletion" in tag_names(task)


# ───────────────────────── selection ─────────────────────────


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s: str) -> datetime | None:
    s = (s or "").strip()
    if not s:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(s[:len(fmt) + 2 if fmt.endswith("Z") else len(s)], fmt).replace(
                tzinfo=timezone.utc) if fmt != "%Y-%m-%d" else datetime.strptime(s[:10], fmt).replace(
                    tzinfo=timezone.utc)
        except ValueError:
            continue
    try:
        return parse_iso(s[:19].replace(" ", "T") + "Z") if len(s) >= 19 and "T" in s else None
    except RecursionError:                # pragma: no cover - defensive
        return None


def confirmed(row: dict) -> bool:
    """A WRITTEN CONFIRMATION went out (the customer-visible erasure outcome).

    `confirmed_at` is only ever written by an approved `confirm --send` (or the
    markdown register's own `CONFIRMATION SENT` column), and it is not derived
    from any ClickUp or hide state.
    """
    return bool(row.get("confirmed_at"))


def complete_eligible(row: dict) -> bool:
    """May this row's ticket be tagged `customer-outcome:complete`?

    The confirmation, and nothing else. A `duplicate` row is out: its keys were
    re-pointed at the row we keep, so it is not the record of a completion.
    """
    return confirmed(row) and row["status"] != "duplicate" and row["class"] not in VETO_CLASSES


def select(register: dict, board: dict, now: datetime, *, conv_reader=None) -> dict:
    """Everything this run knows, split by what may be written and what is only reported.

    -> {complete, blocked, legal_confirmed, overdue, attention, link_pending,
        no_register_row, already_terminal, conflicting}

    `conv_reader` is the ticket -> Intercom conversation parser; it defaults to the
    canonical `lib.intercom_link.conv_id_of` and exists as a parameter only so a
    test can supply one on a tree where that dependency has not landed.
    """
    conv_reader = conv_reader or _conv_id_of
    rows = register["rows"]
    complete, blocked, legal_confirmed, overdue, attention = [], [], [], [], []
    for rid, r in sorted(rows.items()):
        tids = sorted(set(r["clickup_ids"]) | {
            k.split(":", 1)[1] for k in r["keys"] if k.startswith("clickup:")})
        due = parse_iso(r.get("due_at"))

        # 0. the legal clock, for EVERY class. Counsel's rows carry a due date too
        #    and the register's own watchdog counts them, so leaving them out here
        #    would publish a smaller number than the register and put the two
        #    systems back where they started. Computed before the veto branch
        #    below, which `continue`s.
        if r["status"] == "open" and due is not None and due < now and not confirmed(r):
            overdue.append({"register_no": r["register_no"], "row": rid, "due_at": r["due_at"],
                            "class": r["class"], "clickup_ids": tids,
                            "hidden_at": r.get("hidden_at") or "",
                            "counsel": r["class"] in VETO_CLASSES,
                            "days_past": max((now - due).days, 0)})

        # 0b. a SUPERSEDED row is not a live decision. `status=duplicate` means the
        #     register re-pointed this request's keys at the surviving row, and the
        #     old row can keep its ClickUp id: letting it reach the counsel branch
        #     would replace a live ticket's outcome with `blocked` on the strength of
        #     a row the register itself has retired. Skip before any decision.
        if r["status"] == "duplicate":
            if tids:
                attention.append({"register_no": r["register_no"], "row": rid,
                                  "why": (f"register row is a `duplicate` with NO written "
                                          f"confirmation — its keys were re-pointed at the row "
                                          f"we keep, so it is not a completion record and the "
                                          f"drainer writes nothing on its say-so"),
                                  "clickup_ids": tids, "due_at": r.get("due_at"),
                                  "past_due": bool(due is not None and due < now)})
            continue

        # 1. veto classes never close on a tag
        if r["class"] in VETO_CLASSES:
            if confirmed(r):
                legal_confirmed.append({"register_no": r["register_no"], "row": rid,
                                        "class": r["class"], "clickup_ids": tids,
                                        "why": "counsel's letter is on record; the board is "
                                               "left for the letter's owner, never tagged"})
            else:
                for tid in tids:
                    blocked.append({"task_id": tid, "tag": TAG_BLOCKED, "kind": "blocked",
                                    "request_id": rid, "register_no": r["register_no"],
                                    "why": f"class `{r['class']}` goes out by letter from counsel "
                                           f"(register row {rid}); never closed on a tag"})
            continue

        # 2. the completion: the written confirmation
        if complete_eligible(r):
            if not tids:
                attention.append({"register_no": r["register_no"], "row": rid,
                                  "why": "confirmed (the letter went out) but the row carries no "
                                         "ClickUp ticket — nothing on the board to close",
                                  "confirmed_at": r["confirmed_at"],
                                  "due_at": r.get("due_at"), "past_due": False})
            for tid in tids:
                complete.append({"task_id": tid, "tag": TAG_COMPLETE, "kind": "complete",
                                 "request_id": rid, "register_no": r["register_no"],
                                 "confirmed_at": r["confirmed_at"],
                                 "why": f"register row {rid} carries a written confirmation "
                                        f"({r['confirmed_at']})"})
            continue

        # 3. closed WITHOUT a confirmation: a human closed the register row, which
        #    is not evidence that the customer was told. Report, never close.
        if r["status"] != "open" and not confirmed(r) and tids:
            attention.append({"register_no": r["register_no"], "row": rid,
                              "why": (f"register row is a `{r['status']}` with NO written "
                                      f"confirmation — its keys were re-pointed at the row we "
                                      f"keep, so it is not a completion record"
                                      if r["status"] == "duplicate" else
                                      f"register row is `{r['status']}` with NO written "
                                      f"confirmation — a closed row is not a letter, so its "
                                      f"{len(tids)} ticket(s) stay open"),
                              "clickup_ids": tids,
                              # The register's OWN watchdog iterates store.all("open"), so a
                              # closed row past its date is invisible to it. OVERDUE stays
                              # the register's number (two systems must not disagree); this
                              # flag is how the excluded population still gets named.
                              "due_at": r.get("due_at"),
                              "past_due": bool(due is not None and due < now)})
    overdue.sort(key=lambda o: (o["due_at"], o["register_no"]))

    # CONFLICTING DECISIONS: one ticket, two register rows, two different outcomes.
    # The register links a ticket to whichever requests it saw, so a re-created or
    # re-pointed request can leave one ticket standing in for a confirmed erasure AND
    # an open counsel row. Writing either label is a claim about the other row, and
    # writing both leaves two `customer-outcome:*` tags — which the shared reader
    # answers None for, i.e. the ticket stops saying anything at all. Fail closed:
    # decide nothing for that ticket and hand it to a human.
    decisions = {}
    for w in complete + blocked:
        decisions.setdefault(w["task_id"], []).append(w)
    conflicting = []
    for tid, ws in sorted(decisions.items()):
        kinds = sorted({w["kind"] for w in ws})
        if len(kinds) < 2:
            continue
        conflicting.append({
            "task_id": tid, "kinds": kinds, "tags": sorted({w["tag"] for w in ws}),
            "register_nos": sorted({w.get("register_no") for w in ws if w.get("register_no")}),
            "why": f"this ticket carries {len(kinds)} different decisions from the register "
                   f"({', '.join(kinds)}) — refusing to write either, because each label is a "
                   f"claim about the other row and two outcome tags make the ticket unreadable",
        })
    conflicting_ids = {c["task_id"] for c in conflicting}
    complete = [w for w in complete if w["task_id"] not in conflicting_ids]
    blocked = [w for w in blocked if w["task_id"] not in conflicting_ids]

    # the board side
    link_pending, no_register_row, already_terminal = [], [], []
    register_clickup = set(register["by_clickup"])
    for tid, task in sorted(board.items()):
        if not has_action_tag(task):
            continue
        if not is_open(task):
            already_terminal.append({"task_id": tid, "status": status_of(task)})
            continue
        if tid in register_clickup:
            continue
        conv = conv_reader(task) or ""
        conv_rows = register["by_conv"].get(conv) if conv else None
        if conv_rows:
            row = rows[min(conv_rows)]
            link_pending.append({
                "task_id": tid, "conversation_id": conv, "row": row["id"],
                "register_no": row["register_no"],
                "confirmed_at": row["confirmed_at"],
                "why": ("its conversation's register row is confirmed; the register's next tick "
                        "writes this ticket into `clickup_ids` and the run after that closes it"
                        if confirmed(row) else
                        "its conversation's register row is the request; no link on the row yet")})
            continue
        no_register_row.append({"task_id": tid, "conversation_id": conv,
                                "name": str(task.get("name") or "")[:80],
                                "status": status_of(task)})
    return {"complete": complete, "blocked": blocked, "legal_confirmed": legal_confirmed,
            "overdue": overdue, "attention": attention, "link_pending": link_pending,
            "no_register_row": no_register_row, "already_terminal": already_terminal,
            "conflicting": conflicting}


def _conv_id_of(task: dict) -> str:
    """The Intercom conversation a ticket points at, via the canonical parser."""
    try:
        from lib.intercom_link import conv_id_of
    except ImportError:                   # pragma: no cover - dep-less tree
        return ""
    try:
        return conv_id_of(task) or ""
    except Exception:                     # noqa: BLE001 - a bad field is not a crash
        return ""


# ───────────────────────── writes ─────────────────────────


def _now_iso() -> str:
    return iso(datetime.now(timezone.utc))


def _epoch_ms(value) -> int | None:
    """A ClickUp timestamp (ms-epoch string) or a ledger ISO stamp, as epoch ms.

    ClickUp reports `date_closed`/`date_done` as a string of milliseconds; the ledger
    stores ISO seconds. Both are compared in one unit so a close time can be ordered
    against the record of the close that produced it.
    """
    s = str(value or "").strip()
    if not s:
        return None
    if s.isdigit():
        return int(s)
    dt = parse_iso(s)
    return int(dt.timestamp() * 1000) if dt else None


def append_ledger(path: str, record: dict) -> None:
    os.makedirs(os.path.dirname(path) or ".", mode=0o700, exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(record, sort_keys=True) + "\n")


class LedgerUnreadable(RegisterUnavailable):
    """The ledger cannot be trusted, so nothing may be claimed about undoing it."""


def read_ledger(path: str) -> list:
    """Every record, or a raise — never a silently short list.

    A missing, unreadable, or crash-truncated ledger must not read as "nothing to
    undo": that is a `--revert` that reports success while every tag it was asked
    to remove is still on the board. One bad line poisons the whole revert, because
    the line that failed to parse may be the one describing the write in question.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError as exc:
        raise LedgerUnreadable(f"ledger not found at {path}") from exc
    except OSError as exc:
        raise LedgerUnreadable(f"ledger unreadable at {path}: {exc}") from exc
    out, bad = [], []
    for i, line in enumerate(lines, 1):
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            bad.append(i)
    if bad:
        raise LedgerUnreadable(
            f"ledger has {len(bad)} unparseable line(s) at {path} "
            f"(first: line {bad[0]}) — the record of what was written is incomplete, "
            f"so a revert cannot be trusted")
    return out


def add_tag(client, task: dict, tag: str, ledger_path: str, *, mode: str = "apply",
            extra: dict | None = None) -> dict:
    """POST one outcome tag and confirm it with a fresh GET. Ledgered both ways.

    The ledger record is written BEFORE the request (a write that happened and was
    not recorded cannot be reverted) and again after it. Confirmation is a second
    GET rather than the POST's response body: ClickUp echoes the request, and an
    accepted POST is not a tag on the ticket.
    """
    tid = str(task.get("id"))
    if tag not in VALID_OUTCOME_TAGS:
        raise ValueError(f"refusing to write a tag outside the customer-outcome contract: {tag}")
    record = {"at": _now_iso(), "mode": mode, "action": "add", "task_id": tid, "tag": tag,
              "before": tag_names(task), "result": "attempted"}
    record.update({k: v for k, v in (extra or {}).items() if v is not None})
    append_ledger(ledger_path, record)

    def _done(result: str, **kw) -> dict:
        append_ledger(ledger_path, {**record, "at": _now_iso(), "result": result,
                                    **{k: v for k, v in kw.items() if k != "at"}})
        return {"task_id": tid, "tag": tag, "action": "add", "result": result, **kw}

    try:
        status, _ = client.request("POST", f"/task/{tid}/tag/{urllib.parse.quote(tag, safe='')}")
        post_error = ""
    except Exception as exc:                # noqa: BLE001 - ledgered, then reported
        status, post_error = 0, f"{type(exc).__name__}: {str(exc)[:200]}"
    if post_error or status >= 500:
        # A LOST RESPONSE IS NOT EVIDENCE THE TAG IS ABSENT. ClickUp may have applied
        # the POST and then dropped the connection (or answered 5xx after committing),
        # so the only honest way to resolve the ambiguity is to read the ticket. This
        # used to return `failed` here, which let a caller conclude "nothing was
        # written" about a tag that was in fact on the ticket — the probe then left
        # `customer-outcome:blocked` behind on a live ticket it had just damaged.
        try:
            gstatus, fresh = client.request("GET", f"/task/{tid}")
        except Exception as exc:            # noqa: BLE001
            return _done("readback_missing", after=[],
                         error=f"{post_error or f'HTTP {status}'}; GET after it: "
                               f"{type(exc).__name__}")
        if gstatus != 200:
            return _done("readback_missing", after=[],
                         error=f"{post_error or f'HTTP {status}'}; GET after it: HTTP {gstatus}")
        after = tag_names(fresh)
        if tag in after:
            return _done("written", after=after, error=post_error or f"HTTP {status}")
        return _done("failed", error=post_error or f"HTTP {status}")
    if status != 200:
        return _done("failed", error=f"HTTP {status}")
    try:
        gstatus, fresh = client.request("GET", f"/task/{tid}")
        after = tag_names(fresh if gstatus == 200 else {})
    except Exception as exc:                # noqa: BLE001
        return _done("readback_missing", after=[], error=f"GET after POST: {type(exc).__name__}")
    if tag not in after:
        return _done("readback_missing", after=after)
    return _done("written", after=after)


def remove_tag(client, task_id: str, tag: str, ledger_path: str, *,
               mode: str = "revert", extra: dict | None = None) -> dict:
    """DELETE one tag and confirm it is gone with a fresh GET. Ledgered both ways."""
    tid = str(task_id)
    record = {"at": _now_iso(), "mode": mode, "action": "remove", "task_id": tid, "tag": tag,
              "result": "attempted"}
    record.update({k: v for k, v in (extra or {}).items() if v is not None})
    append_ledger(ledger_path, record)

    def _done(result: str, **kw) -> dict:
        append_ledger(ledger_path, {**record, "at": _now_iso(), "result": result,
                                    **{k: v for k, v in kw.items() if k != "at"}})
        return {"task_id": tid, "tag": tag, "action": "remove", "result": result, **kw}

    try:
        status, _ = client.request("DELETE", f"/task/{tid}/tag/{urllib.parse.quote(tag, safe='')}")
        del_error = ""
    except Exception as exc:                # noqa: BLE001
        status, del_error = 0, f"{type(exc).__name__}: {str(exc)[:200]}"
    if del_error or status >= 500:
        # Same ambiguity as `add_tag`: the DELETE may have been applied before the
        # response was lost. Read the ticket and let the read decide, so a caller is
        # never told "failed" about a removal that actually happened (or the reverse).
        try:
            gstatus, fresh = client.request("GET", f"/task/{tid}")
        except Exception as exc:            # noqa: BLE001
            return _done("still_present", after=[],
                         error=f"{del_error or f'HTTP {status}'}; GET after it: "
                               f"{type(exc).__name__}")
        if gstatus != 200:
            return _done("still_present", after=[],
                         error=f"{del_error or f'HTTP {status}'}; GET after it: HTTP {gstatus}")
        after = tag_names(fresh)
        if tag in after:
            return _done("still_present", after=after, error=del_error or f"HTTP {status}")
        return _done("removed", after=after, error=del_error or f"HTTP {status}")
    if status != 200:
        return _done("failed", error=f"HTTP {status}")
    try:
        gstatus, fresh = client.request("GET", f"/task/{tid}")
    except Exception as exc:                # noqa: BLE001
        return _done("still_present", after=[], error=f"GET after DELETE: {type(exc).__name__}")
    if gstatus != 200:
        # An unreadable read-back is not a confirmation. `tag_names({})` is [], and
        # "the tag is not in []" would report a removal nobody observed.
        return _done("still_present", after=[], error=f"read-back GET -> {gstatus}")
    after = tag_names(fresh)
    if tag in after:
        return _done("still_present", after=after)
    return _done("removed", after=after)


def replace_outcome(client, task: dict, desired: str, ledger_path: str, *,
                    mode: str = "apply", extra: dict | None = None) -> dict:
    """Make `desired` the ticket's ONLY outcome tag.

    `customer_outcome.customer_outcome_of()` returns None when a ticket carries
    two outcome tags ("missing/invalid/ambiguous" — consumers fail closed), so a
    writer that ADDS a tag can silently unset the outcome it came to set. Every
    stale outcome tag is therefore removed first, exactly as
    scripts/uvn-under30-cron.py:replace_customer_outcome_tag does.
    """
    tid = str(task.get("id"))
    if desired not in VALID_OUTCOME_TAGS:
        raise ValueError(f"refusing to write a tag outside the customer-outcome contract: {desired}")
    existing = outcome_tags_of(task)
    stale = sorted(existing - {desired})
    extra = {**(extra or {}), "replaces": stale or None}
    for tag in stale:
        res = remove_tag(client, tid, tag, ledger_path, mode=f"{mode}-replace", extra=extra)
        if res["result"] != "removed":
            return {"task_id": tid, "tag": desired, "action": "replace",
                    "result": res["result"] if res["result"] == "failed" else "readback_missing",
                    "error": res.get("error"), "stale_removal_failed": tag}
    if desired in existing and not stale:
        return {"task_id": tid, "tag": desired, "action": "replace", "result": "already_tagged",
                "after": sorted(existing)}
    res = add_tag(client, task, desired, ledger_path, mode=mode, extra=extra)
    if res["result"] != "written":
        return {**res, "action": "replace"}
    # the contract's own reader must agree: exactly one outcome tag, and it is ours
    held = outcome_tags_of({"tags": [{"name": n} for n in res.get("after") or []]})
    if held != {desired}:
        return {"task_id": tid, "tag": desired, "action": "replace",
                "result": "readback_missing", "after": res.get("after"),
                "error": f"outcome tags after the write: {sorted(held)}"}
    return {**res, "action": "replace"}


CLOSE_COMMENT = (
    "Automated closure by clickup-drain-data-deletion — the GDPR erasure register records "
    "this request's customer-visible outcome as SENT (register row {row}, confirmed {when}). "
    "Closing on that written confirmation, never on the page being hidden; the register "
    "(`/var/lib/hydra-gdpr/erasure.sqlite`, row {row}) is the legal record and is not "
    "modified by this job.")


def comment_close(client, task_id: str, ledger_path: str, *, register_no, confirmed_at: str,
                  mode: str = "apply") -> dict:
    """Leave the reason on the ticket itself, so a closed row can be audited without us.

    A ticket that closes with no trace is the same rot in a smaller form: the next
    person to look at it cannot tell an automated close from a human's. This is an
    INTERNAL comment (`notify_all: false` — nobody is emailed, the customer least of
    all); the customer's only message stays the register's own confirmation.

    Best effort by design: a close that landed is a fact, so a comment that did not
    is recorded and reported, never retried into the close path.
    """
    tid = str(task_id)
    body = CLOSE_COMMENT.format(row=register_no if register_no is not None else "?",
                                when=(confirmed_at or "")[:10] or "?")
    record = {"at": _now_iso(), "mode": mode, "action": "comment", "task_id": tid,
              "tag": "", "register_no": register_no, "confirmed_at": confirmed_at or "",
              "result": "attempted"}
    append_ledger(ledger_path, record)
    try:
        status, _ = client.request("POST", f"/task/{tid}/comment",
                                   {"comment_text": body, "notify_all": False})
    except Exception as exc:                # noqa: BLE001
        append_ledger(ledger_path, {**record, "at": _now_iso(), "result": "failed",
                                    "error": f"{type(exc).__name__}: {str(exc)[:200]}"})
        return {"task_id": tid, "action": "comment", "result": "failed"}
    landed = status in (200, 201)
    append_ledger(ledger_path, {**record, "at": _now_iso(),
                                "result": "written" if landed else "failed",
                                "status": status})
    return {"task_id": tid, "action": "comment",
            "result": "written" if landed else "failed", "status": status}


def resolve_task(client, task_id: str, ledger_path: str, *, task, before_status: str = "",
                 before_outcome: str = "", mode: str = "apply",
                 register_no=None, confirmed_at: str = "") -> dict:
    """Close the ticket (`resolved`), because the WORK is over: the letter went out.

    A `customer-outcome:complete` tag on an open ticket is not "customer complete"
    — `customer_outcome.customer_complete()` also requires a terminal status. So
    the confirmation both labels and closes, in that order (tag first, status
    second: if the process dies between them the ticket is honestly labelled and
    still open, never closed and unlabelled).

    `before_status` / `before_outcome` are ledgered so `--revert` can put the
    ticket back exactly as it was found.

    **The OPEN gate lives HERE, not at the call sites.** Three QA rounds in a row found
    the one close path that had forgotten to re-check the ticket's status, so the check
    moved into the only function that can PUT `resolved`: a ticket must be handed over
    in one of OPEN_STATUSES, observed on the read that took this decision. An
    `archived`/custom/terminal status returns `not_open` and writes nothing.
    """
    tid = str(task_id)
    if not is_open(task):
        return {"task_id": tid, "action": "resolve", "result": "not_open",
                "status": status_of(task)}
    record = {"at": _now_iso(), "mode": mode, "action": "resolve", "task_id": tid,
              "tag": "", "before_status": before_status or None,
              "before_outcome": before_outcome or None,
              "register_no": register_no, "confirmed_at": confirmed_at or "",
              "result": "attempted"}
    append_ledger(ledger_path, record)

    def _done(result: str, **kw) -> dict:
        append_ledger(ledger_path, {**record, "at": _now_iso(), "result": result,
                                    **{k: v for k, v in kw.items() if k != "at"}})
        return {"task_id": tid, "action": "resolve", "result": result, **kw}

    try:
        status, _ = client.request("PUT", f"/task/{tid}", {"status": "resolved"})
        put_error = ""
    except Exception as exc:                # noqa: BLE001
        status, put_error = 0, f"{type(exc).__name__}: {str(exc)[:200]}"
    if put_error or status >= 500:
        # A LOST RESPONSE IS NOT EVIDENCE THE CLOSE DID NOT LAND. ClickUp may have
        # applied the PUT and then dropped the connection. Reporting `failed` here was
        # a real bug: `comment_debt()` reads `failed` as "no close, the next run's write
        # path owns it", but the ticket was in fact `resolved` — and an hourly scan
        # skips a terminal ticket, so the audit comment was never posted and nothing
        # was left to retry. Read the ticket; the read decides.
        try:
            gstatus, fresh = client.request("GET", f"/task/{tid}")
        except Exception as exc:            # noqa: BLE001
            return _done("readback_missing",
                         error=f"{put_error or f'HTTP {status}'}; GET after it: "
                               f"{type(exc).__name__}")
        if gstatus != 200:
            return _done("readback_missing",
                         error=f"{put_error or f'HTTP {status}'}; GET after it: HTTP {gstatus}")
        if status_of(fresh) != "resolved":
            return _done("failed", error=put_error or f"HTTP {status}")
        now_status = "resolved"
    elif status != 200:
        return _done("failed", error=f"HTTP {status}")
    else:
        try:
            gstatus, fresh = client.request("GET", f"/task/{tid}")
            now_status = status_of(fresh) if gstatus == 200 else ""
        except Exception as exc:            # noqa: BLE001
            return _done("readback_missing", error=f"GET after PUT: {type(exc).__name__}")
        if now_status != "resolved":
            return _done("readback_missing", status=now_status)
    note = comment_close(client, tid, ledger_path, register_no=register_no,
                         confirmed_at=confirmed_at, mode=mode)
    return _done("resolved", status=now_status, comment=note["result"])


def comment_debt(ledger_path: str) -> dict:
    """{task_id: {register_no, confirmed_at}} for closes whose audit comment never landed.

    The comment is best effort IN THE CLOSE PATH: a close that landed is a fact, so
    a failed comment must never undo it or block the run's other work. But it is NOT
    best effort forever — the drainer's direct close is only justified if the ticket
    says why it closed, so a missing comment is a debt the next run settles. The debt
    lives in the ledger (the durable record) rather than in memory, so a crash between
    the close and the retry is just another debt.
    """
    if not os.path.exists(ledger_path):
        return {}                            # a first run has no debt to settle
    events = read_ledger(ledger_path)        # a malformed ledger raises: see the caller
    debt = {}
    for ev in events:
        if ev.get("action") == "resolve":
            # The status PUT was accepted but the read-back never confirmed it. The
            # close MAY have landed — and if it did, `resolve_task()` returned before
            # the audit comment, so no comment row exists to fail. Without this the
            # ticket is `resolved` with no note and nothing left to retry (an hourly
            # scan skips a terminal ticket).
            if ev.get("result") in ("readback_missing", "attempted"):
                debt[str(ev.get("task_id") or "")] = {
                    "register_no": ev.get("register_no"),
                    "confirmed_at": ev.get("confirmed_at") or "",
                    "why": ("close was attempted and never confirmed; the note was never "
                            "posted" if ev.get("result") == "readback_missing" else
                            "close was attempted and the process died before recording its "
                            "result; the note was never posted")}
            elif ev.get("result") == "failed":
                # The PUT itself failed: no close, and the next run's write path owns
                # that ticket. Not comment debt.
                debt.pop(str(ev.get("task_id") or ""), None)
            continue
        if ev.get("action") == "restore-status":
            # A revert put the ticket back where it was found: the close it undid owes
            # no audit comment, so a settled revert retires the debt with it. ONLY a
            # settled one. `attempted` is the crash window — the PUT may never have
            # landed, leaving the ticket closed with no note — and `failed` means the
            # PUT errored, so the close is still there and still owes its note. The
            # retry re-reads the ticket anyway, so a debt whose restore DID land is
            # skipped there rather than posted onto a reopened ticket.
            if ev.get("result") == "restored":
                debt.pop(str(ev.get("task_id") or ""), None)
            continue
        if ev.get("action") != "comment":
            continue
        tid = str(ev.get("task_id") or "")
        if not tid:
            continue
        if ev.get("result") == "written":
            debt.pop(tid, None)              # a later success settles it
        elif ev.get("result") == "failed":
            debt[tid] = {"register_no": ev.get("register_no"),
                         "confirmed_at": ev.get("confirmed_at") or "",
                         "why": "the audit comment POST failed"}
    return debt


def retry_comments(client, debt: dict, ledger_path: str, *, board: dict, budget=None) -> dict:
    """Re-post the audit comment for closes whose comment failed, and only those.

    The ticket is re-read first: a comment is a claim that THIS ticket closed on a
    register confirmation, so posting it onto a ticket that has since been reopened
    or relabelled would assert something false. Only a terminal ticket that still
    carries our outcome tag gets the note; anything else is left for a human, because
    only a human knows why it moved.
    """
    out = {"written": [], "failed": [], "skipped": []}
    for tid, info in sorted(debt.items()):
        if tid not in board:
            out["skipped"].append({"task_id": tid, "why": "not on the board any more"})
            continue
        if budget is not None and not budget.spend(1):
            out["skipped"].append({"task_id": tid, "why": "mutation budget spent"})
            continue
        try:
            status, fresh = client.request("GET", f"/task/{tid}")
        except Exception as exc:            # noqa: BLE001
            out["skipped"].append({"task_id": tid,
                                   "why": f"could not re-read the ticket ({type(exc).__name__})"})
            continue
        if status != 200:
            out["skipped"].append({"task_id": tid, "why": f"re-read got HTTP {status}"})
            continue
        held = outcome_tags_of(fresh)
        if status_of(fresh) not in TERMINAL_STATUSES or held != {TAG_COMPLETE}:
            out["skipped"].append({"task_id": tid,
                                   "why": f"ticket is `{status_of(fresh) or '?'}` with outcome "
                                          f"{sorted(held) or 'none'} — no longer the close this "
                                          f"comment describes"})
            continue
        note = comment_close(client, tid, ledger_path,
                             register_no=info.get("register_no"),
                             confirmed_at=info.get("confirmed_at") or "", mode="apply")
        (out["written"] if note["result"] == "written" else out["failed"]).append(
            {"task_id": tid, "result": note["result"], "status": note.get("status")})
    return out


def _label_cost(before_outcome: str) -> int:
    """Mutations to put one outcome tag on a ticket: one DELETE per stale outcome
    tag, plus the POST.

    PER STALE TAG, not "one if any": `replace_outcome()` removes every outcome tag
    that is not the desired one (two tags make `customer_outcome_of()` return None,
    so the others must go), and a ticket can carry more than one — `blocked` and
    `partial` together, for instance. Reserving one DELETE for a ticket with two
    stale tags undercounts the budget by one, per stale tag, forever.
    """
    stale = [t for t in (before_outcome or "").split(",") if t.strip()]
    return 1 + len(stale)


def _close_cost() -> int:
    """Mutations to close a ticket after labelling it: the PUT, then the comment."""
    return 2


def execute(client, writes: list, board: dict, ledger_path: str, *, budget=None,
            max_writes: int) -> dict:
    """Write at most `max_writes` outcomes, skipping tickets this cannot help.

    A ticket already in a TERMINAL status is skipped, not written: `resolved`
    already says the work stopped, and this drainer has nothing to add to a
    ticket a human finished (the `blocked` tag on a resolved counsel ticket would
    be a second outcome tag, which is exactly the ambiguity `replace_outcome`
    exists to avoid).
    """
    results = {"written": [], "already_tagged": [], "skipped_terminal": [],
               "skipped_untagged": [], "unreadable": [], "failed": [],
               "readback_missing": [], "retagged": [], "skipped_closed": [],
               "capped_out": 0, "resolved": [],
               "resolve_failed": [], "mutations": 0}
    budget = budget or MutationBudget(min(int(max_writes), MAX_WRITES_HARD))
    for w in writes:
        tid = w["task_id"]
        # RE-READ EVERY TICKET IMMEDIATELY BEFORE MUTATING, never trust the scan.
        # The board was read up to a minute ago and a human can retag or reopen a
        # ticket in between: a stale snapshot would let this drainer label and CLOSE
        # a ticket that is no longer `action:data-deletion` at all. The read is not a
        # mutation, so it costs the budget nothing; the scan stays authoritative for
        # WHAT to consider, and this read decides whether it is still true.
        try:
            gstatus, task = client.request("GET", f"/task/{tid}")
        except Exception as exc:            # noqa: BLE001
            results["unreadable"].append(
                {**w, "why": f"GET /task/{tid} failed: {type(exc).__name__}"})
            continue
        if gstatus != 200 or not isinstance(task, dict):
            # NOT `skipped_terminal`: nobody observed a terminal status. A linked
            # ticket we could not read is an open ticket with a confirmed register
            # row behind it, and the run must say so.
            results["unreadable"].append({**w, "why": f"GET /task/{tid} -> {gstatus}"})
            continue
        if not has_action_tag(task):
            # The register links a ticket that no longer carries the action tag —
            # reclassified, retagged, or moved to another queue. Writing to it
            # would label (and for a completion, CLOSE) a ticket about something
            # else entirely, on evidence that says nothing about this request.
            # Report it: the register's link is stale, and that is a fact for a
            # human, not a write.
            results["skipped_untagged"].append(
                {**w, "why": f"ticket no longer carries `action:data-deletion` "
                             f"(tags: {', '.join(sorted(tag_names(task))) or 'none'})"})
            continue
        before_status = status_of(task)
        before_outcome = ",".join(sorted(outcome_tags_of(task)))
        if before_outcome == w["tag"]:
            results["already_tagged"].append(w)
            # ...but the label is only half of a completion. A previous run that
            # died between the tag and the close leaves a labelled, still-open
            # ticket, and "already tagged" must not make that permanent: finish
            # it (bounded by the same budget, because it is still a write).
            if w["tag"] == TAG_COMPLETE and before_status not in TERMINAL_STATUSES:
                if not is_open(task):
                    # The label is already there and the ticket is in a status this job
                    # does not write to (archived/custom). Finishing "the interrupted
                    # completion" would close a ticket nobody asked us to close, on
                    # evidence that predates whatever moved it.
                    results["skipped_closed"].append(
                        {**w, "why": f"ticket already carries `{w['tag']}` but its status is "
                                     f"`{before_status}`, which is not one the drainer "
                                     f"writes to ({', '.join(sorted(OPEN_STATUSES))})"})
                    continue
                if not budget.spend(_close_cost()):
                    results["capped_out"] += 1
                    continue
                closed = resolve_task(client, tid, ledger_path, task=task,
                                      before_status=before_status,
                                      before_outcome=before_outcome,
                                      register_no=w.get("register_no"),
                                      confirmed_at=w.get("confirmed_at") or "")
                if closed["result"] == "not_open":
                    results["skipped_closed"].append({**w, "why": closed.get("status")})
                    continue
                (results["resolved"] if closed["result"] == "resolved"
                 else results["resolve_failed"]).append({**w, "result": closed})
            continue
        if before_status in TERMINAL_STATUSES:
            results["skipped_terminal"].append({**w, "why": f"ticket is `{before_status}`"})
            continue
        if not is_open(task):
            # Not one of the three statuses we know means "finished" and not one of the
            # three we know mean "live" — an archived/custom/malformed status. A closed
            # ticket must not be relabelled or closed again on the strength of a register
            # row, so the write is refused and named: an unrecognized status on a ticket
            # this job is about to write is an anomaly, not a detail.
            results["skipped_closed"].append(
                {**w, "why": f"ticket status is `{before_status}` and is not one the drainer "
                             f"writes to ({', '.join(sorted(OPEN_STATUSES))})"})
            continue
        # DELETE the stale outcome (if any) + POST the new one + PUT + comment.
        cost = _label_cost(before_outcome) + (_close_cost() if w["tag"] == TAG_COMPLETE else 0)
        if not budget.spend(cost):
            results["capped_out"] += 1
            continue
        res = replace_outcome(client, task, w["tag"], ledger_path, extra={
            "request_id": w.get("request_id"), "register_no": w.get("register_no"),
            "why": w.get("why"), "kind": w.get("kind")})
        bucket = {"written": "written", "readback_missing": "readback_missing",
                  "failed": "failed", "already_tagged": "already_tagged"}[res["result"]]
        results[bucket].append({**w, "result": res})
        if w["tag"] != TAG_COMPLETE or res["result"] != "written":
            continue
        # the tag landed; now close. A close that fails leaves the ticket honestly
        # labelled and open, which is the safe half-state.
        closed = resolve_task(client, tid, ledger_path, task=task,
                              before_status=before_status,
                              before_outcome=before_outcome,
                              register_no=w.get("register_no"),
                              confirmed_at=w.get("confirmed_at") or "")
        if closed["result"] == "not_open":
            results["skipped_closed"].append({**w, "why": closed.get("status")})
            continue
        (results["resolved"] if closed["result"] == "resolved"
         else results["resolve_failed"]).append({**w, "result": closed})
    results["mutations"] = budget.used
    return results


def verify_pending(client, items: list, ledger_path: str) -> tuple:
    """Re-check, one GET each, the writes whose own confirmation failed.

    An accepted POST is not a tag on the ticket, and neither is a failed
    confirmation GET evidence that the tag is absent. So the re-check reads the
    ticket again and only what is STILL unconfirmed pages: a page that fires when
    the write actually landed spends a human's attention on a non-event, and the
    next run would find the tag anyway.

    "Landed" means the contract's OWN test — exactly one outcome tag and it is the
    one we wrote. `tag in tags` is not that: a stale tag whose DELETE failed leaves
    two, `customer_outcome_of()` answers None for two, and confirming here would
    close a ticket that no consumer can read.
    """
    confirmed, missing = [], []
    for w in items:
        tid = w.get("task_id")
        try:
            status, task = client.request("GET", f"/task/{tid}")
        except Exception as exc:            # noqa: BLE001
            missing.append({**w, "maybe_landed": True,
                            "why": f"GET /task/{tid} failed: {type(exc).__name__}"})
            continue
        after = tag_names(task if status == 200 and isinstance(task, dict) else {})
        # The invariant is "exactly ONE outcome tag, and it is ours", not "ours is
        # somewhere in there". A stale tag the DELETE failed to remove leaves two,
        # `customer_outcome_of()` returns None for that, and closing the ticket on
        # this check would resolve a request whose outcome consumers cannot read.
        held = outcome_tags_of(task) if status == 200 and isinstance(task, dict) else set()
        if status == 200 and held == {w.get("tag")}:
            # Hand the FRESH task back with the confirmation: the caller closes the
            # ticket, and closing it on the scan snapshot would skip the queue/status
            # revalidation this very read just performed.
            confirmed.append({**w, "after": after, "_fresh": task})
            append_ledger(ledger_path, {"at": _now_iso(), "mode": "verify", "action": "add",
                                        "task_id": tid, "tag": w.get("tag"), "after": after,
                                        "result": "written"})
        elif status == 200 and w.get("tag") in held:
            missing.append({**w, "maybe_landed": True,
                            "why": f"ambiguous after GET /task/{tid}: outcome tags are "
                                   f"{sorted(held)} — `customer-outcome:*` must be exactly "
                                   f"one before this can close"})
        else:
            # Only a 200 that showed no tag is EVIDENCE OF ABSENCE. Anything else is
            # "could not read it", and the page must not turn that into a fact.
            missing.append({**w, "maybe_landed": status != 200,
                            "why": f"still absent after GET /task/{tid} ({status})"})
    return confirmed, missing


def revert(client, ledger_path: str) -> dict:
    """Undo what a ledger recorded: remove THIS drainer's outcome tags, restore
    the status it changed.

    Three rules, all from the ledger rather than from the current board state:
      * only `action: add` records with `result: written` are removals, and only
        for tags this drainer writes (`customer-outcome:complete|blocked`) — a
        `-replace` removal of someone else's stale outcome tag is not re-added,
        because re-adding a tag we did not own would be inventing a claim;
      * `action: resolve` records restore the `before_status` the ticket had, so a
        reverted completion does not leave a resolved ticket with no outcome —
        but ONLY while the ticket still sits at the `resolved` this drainer wrote.
        A ticket a human has since moved is reported `left_for_human` and left
        alone: a revert that reaches past its own write undoes somebody's work;
      * a task/tag pair whose removal was CONFIRMED is not touched twice, and a
        pair whose read-back could not be read is not counted as removed;
      * a ticket whose outcome tag could not be removed keeps the status it has:
        reopening it would make the next apply run close it again;
      * an `attempted` record with no result is the crash window (the line is
        written before the request), so the ticket is read before it is touched:
        the tag is removed only if it is really there, and the status restored only
        if the ticket really is `resolved`.

    A revert is a bookkeeping repair, never a customer action: it sends nothing.
    """
    records = read_ledger(ledger_path)
    # REPLAY the ledger IN ORDER. A set of "pairs ever removed" is wrong the moment
    # the tag is written again: add -> revert (confirmed removed) -> apply adds it
    # again -> revert would find the pair in that set, skip it, and report success
    # with the tag on the board. So walk the events and keep what is still true.
    live, resolved_state, reverted_before = {}, {}, set()
    # Tickets with a restore-status PUT that was in flight when a revert died. The
    # close debt stays live (the PUT may not have landed) until a GET proves the
    # target, at which point the debt is paid — see the `already_at_target` branch.
    pending_restore = set()
    for r in records:
        key = (r.get("task_id"), r.get("tag"))
        action, result = r.get("action"), r.get("result")
        if action == "add" and result == "attempted" \
                and r.get("tag") in VALID_OUTCOME_TAGS and r.get("mode") != "revert":
            # CRASH WINDOW: the record is written BEFORE the POST, so an
            # `attempted` add with no result record means the process died on the
            # wrong side of an unknown POST. The tag may be on the ticket. Kept as
            # uncertain: the revert reads the ticket before touching it, because
            # a blind DELETE would claim a removal that may never have happened.
            live[key] = {**r, "_uncertain": True}
        elif action == "add" and result in ("written", "readback_missing") \
                and r.get("tag") in VALID_OUTCOME_TAGS and r.get("mode") != "revert":
            # `readback_missing`: the POST was accepted but the confirmation GET
            # did not prove it. It may be on the ticket, so a revert must try.
            live[key] = r
        elif action == "add" and result == "failed" and r.get("mode") != "revert":
            # A DEFINITIVE failure RETIRES the pair. `add_tag` only reports `failed`
            # after a read proved the tag is not on the ticket (a lost response is
            # resolved by reading, never assumed), so our write did not land and
            # there is nothing of ours to undo. Leaving the `attempted` record live
            # let a LATER writer's `customer-outcome:complete` look like ours, and
            # `--revert` DELETEd it — a rollback reaching past its own write. Only
            # `failed` retires: `readback_missing` and a bare `attempted` stay live
            # because the tag may really be there.
            live.pop(key, None)
        elif action == "remove" and result == "removed":
            # ONLY a confirmed removal retires a pair. `still_present` means the
            # DELETE ran but the read-back still showed the tag (or the read-back
            # itself failed) — treating that as undone is a rollback reporting
            # success with the tag still on the board.
            live.pop(key, None)
            reverted_before.add(key)
        elif action == "resolve" and result == "attempted" and r.get("before_status"):
            # Same crash window on the close: the PUT may have landed.
            resolved_state[r["task_id"]] = {**r, "_uncertain": True}
        elif action == "resolve" and result in ("resolved", "readback_missing") \
                and r.get("before_status"):
            # `readback_missing` is included on purpose: the PUT may have landed
            # and only the confirmation GET failed, which would leave a ticket
            # `resolved` with no outcome tag — the one state consumers read as
            # "terminal, outcome unknown". `failed` (the PUT itself errored) is
            # not restored: nothing changed, and a no-op PUT would be noise.
            resolved_state[r["task_id"]] = r
        elif action == "restore-status" and result == "attempted":
            pending_restore.add(r.get("task_id"))
        elif action == "restore-status" and result == "restored":
            resolved_state.pop(r.get("task_id"), None)     # that debt is paid
            pending_restore.discard(r.get("task_id"))
    out = {"removed": [], "still_present": [], "failed": [], "skipped": [],
           "reopened": [], "already_at_target": [], "reopen_failed": [],
           "left_for_human": [], "status_kept": [], "absent": [],
           "outcome_restored": [], "outcome_not_restored": [], "outcome_kept": []}
    for key, src in sorted(live.items(), key=lambda kv: kv[1].get("at") or "", reverse=True):
        if src.get("_uncertain"):
            # Look before deleting: an `attempted`-only record does not say whether
            # the POST landed, and a DELETE would report `removed` either way.
            try:
                gstatus, task = client.request("GET", f"/task/{key[0]}")
            except Exception as exc:        # noqa: BLE001
                out["failed"].append({"task_id": key[0], "tag": key[1],
                                      "error": f"GET while resolving a crash window: "
                                               f"{type(exc).__name__}"})
                continue
            if gstatus != 200:
                out["failed"].append({"task_id": key[0], "tag": key[1],
                                      "error": f"GET while resolving a crash window -> {gstatus}"})
                continue
            if key[1] not in tag_names(task):
                out["absent"].append({"task_id": key[0], "tag": key[1],
                                      "why": "the interrupted write never landed"})
                continue
        res = remove_tag(client, key[0], key[1], ledger_path, mode="revert",
                         extra={"reverted_source_at": src.get("at")})
        out[{"removed": "removed", "still_present": "still_present",
             "failed": "failed"}[res["result"]]].append(res)
    # A ticket whose outcome tag could not be removed must NOT be reopened: the
    # next apply run would see a `complete` tag on an open ticket and close it
    # again — a reopen/close churn loop, and a status write that undoes nothing.
    confirmed_gone = {(r["task_id"], r["tag"]) for r in out["removed"]}
    # A tag the read proved ABSENT is gone too: an `attempted`-only record that never
    # landed must not make the ticket look like it still carries our outcome, or the
    # prior tag is never put back (nothing would be "safe" to restore).
    proven_absent = {(r["task_id"], r["tag"]) for r in out["absent"]}
    still_tagged = {k[0] for k in live
                    if k not in confirmed_gone and k not in proven_absent}
    for tid, entry in resolved_state.items():
        want = entry["before_status"]
        if want.lower() in ("resolved", "impossible", "user updated"):
            continue                        # nothing to restore: it was already terminal
        if tid in still_tagged:
            out["status_kept"].append(
                {"task_id": tid, "restored_to": want,
                 "why": "the outcome tag is still on the ticket — reopening it would make the "
                        "next run close it again"})
            continue
        try:
            gstatus, before = client.request("GET", f"/task/{tid}")
            was = status_of(before) if gstatus == 200 else ""
            if gstatus != 200:
                out["reopen_failed"].append({"task_id": tid, "restored_to": want,
                                             "why": f"GET -> {gstatus}"})
                continue
            if was == want.lower():
                out["already_at_target"].append({"task_id": tid, "restored_to": want,
                                                 "was": was, "status": was})
                if tid in pending_restore:
                    # SETTLE THE CRASH WINDOW. A restore whose PUT landed and whose
                    # result record was lost leaves the close debt live, and a later
                    # revert would then reopen a decision a human made after it. The
                    # GET above proves the target, so the debt is paid here.
                    append_ledger(ledger_path, {"at": _now_iso(), "mode": "revert",
                                                "action": "restore-status", "task_id": tid,
                                                "tag": "", "status": was, "result": "restored"})
                continue
            # AN INTERRUPTED RESTORE IS NOT OURS TO FINISH. A previous revert wrote
            # `attempted` and died before its result, so we cannot tell whether the
            # ticket is `resolved` because OUR restore never landed or because a human
            # re-resolved it after ours did. The close-time guard below cannot separate
            # those either: a human re-resolving inside the five-minute slack looks
            # exactly like our own close. Refuse, and say why — reopening a human's
            # decision is the one mistake this path must never make.
            if tid in pending_restore:
                out["left_for_human"].append(
                    {"task_id": tid, "restored_to": want, "was": was,
                     "why": "a restore was interrupted and this ticket has been closed "
                            "since — cannot tell our restore from a human's, left alone"})
                continue
            # ONLY a ticket still sitting where OUR write put it. Reaching into a
            # ticket a human has since moved would make `--revert` a time machine
            # that undoes their work: revert once, let someone set it `in
            # progress`, run revert again, and their change disappears.
            if was != "resolved":
                out["left_for_human"].append({"task_id": tid, "restored_to": want, "was": was,
                                              "why": f"status is `{was}`, not the `resolved` this "
                                                     f"drainer wrote — left alone"})
                continue
            # ... AND still closed by OUR close. `resolved` alone cannot tell our own
            # close apart from a human RE-resolving a ticket we already reopened, so
            # order the ticket's own close time against the close record's. Without
            # this, a revert run after a human re-resolved the ticket reopens their
            # decision — the same time machine the `was` guard above exists to stop.
            closed_ms = _epoch_ms(before.get("date_closed") or before.get("date_done"))
            ours_ms = _epoch_ms(entry.get("at"))
            if closed_ms and ours_ms and closed_ms > ours_ms + CLOSE_SLACK_MS:
                out["left_for_human"].append(
                    {"task_id": tid, "restored_to": want, "was": was,
                     "why": "closed again after this drainer's close — left alone"})
                continue
            # LEDGERED BEFORE THE PUT. A restore that lands and then loses its result
            # record would leave the close looking active, so a later revert could
            # reopen a decision made after it. The `attempted` line is the record that
            # the write was in flight; replay keeps the debt (the PUT may not have
            # landed) and the next revert retires it from a GET that shows the target.
            append_ledger(ledger_path, {"at": _now_iso(), "mode": "revert",
                                        "action": "restore-status", "task_id": tid, "tag": "",
                                        "status": "", "result": "attempted"})
            client.request("PUT", f"/task/{tid}", {"status": want})
            gstatus, fresh = client.request("GET", f"/task/{tid}")
            now_status = status_of(fresh) if gstatus == 200 else ""
        except Exception as exc:            # noqa: BLE001
            out["reopen_failed"].append({"task_id": tid, "restored_to": want,
                                        "error": f"{type(exc).__name__}"})
            append_ledger(ledger_path, {"at": _now_iso(), "mode": "revert",
                                        "action": "restore-status", "task_id": tid, "tag": "",
                                        "status": "", "result": "failed"})
            continue
        rec = {"task_id": tid, "restored_to": want, "was": was, "status": now_status}
        (out["reopened"] if now_status == want.lower() else out["reopen_failed"]).append(rec)
        append_ledger(ledger_path, {"at": _now_iso(), "mode": "revert", "action": "restore-status",
                                    "task_id": tid, "tag": "", "status": now_status,
                                    "result": "restored" if now_status == want.lower() else "failed"})
    out["skipped"] = sorted(k for k in reverted_before if k not in live)
    # THE PRIOR OUTCOME. A completion REPLACED someone else's outcome tag, so removing
    # ours and reopening the ticket leaves it with no outcome at all — a state every
    # consumer reads as "unknown", reported as a clean undo. Restore what was there, but
    # never over a newer decision: if the ticket carries an outcome tag now, that tag is
    # somebody else's answer to the same question and this revert is not entitled to it.
    # The prior outcome comes from the ADD RECORD of what this revert removed, via its
    # `before` snapshot — not from the close records, because a `blocked` replacement
    # never closes anything and still replaces an outcome tag.
    prior_by_ticket = {}
    for key in confirmed_gone:
        src = live.get(key) or {}
        for tag in src.get("before") or []:
            if tag in VALID_OUTCOME_TAGS and tag != key[1]:
                bucket = prior_by_ticket.setdefault(key[0], [])
                if tag not in bucket:
                    bucket.append(tag)
    # A replacement that DELETED the old outcome and then FAILED to write the new one
    # leaves the ticket with no outcome and nothing of ours to remove, so the loop above
    # finds no prior tag. `replace_outcome()` records what it replaced on the add record
    # (`replaces`), so a failed tail add is the other way a hole gets made — and the
    # revert is the only thing that can fill it.
    last_apply_add = {}
    for r in records:
        if r.get("action") == "add" and r.get("mode") == "apply" \
                and r.get("tag") in VALID_OUTCOME_TAGS:
            last_apply_add[r.get("task_id")] = r
    for tid, r in last_apply_add.items():
        landed = r.get("result") == "written" and r.get("tag") in (r.get("after") or [])
        if landed:
            continue                        # the ticket carries an outcome of ours
        for tag in r.get("replaces") or []:
            if tag in VALID_OUTCOME_TAGS:
                bucket = prior_by_ticket.setdefault(tid, [])
                if tag not in bucket:
                    bucket.append(tag)
    for tid, prior in prior_by_ticket.items():
        if tid in still_tagged:
            continue
        try:
            gstatus, task = client.request("GET", f"/task/{tid}")
        except Exception as exc:            # noqa: BLE001
            out["outcome_not_restored"].append(
                {"task_id": tid, "prior_outcome": prior,
                 "why": f"GET failed: {type(exc).__name__}"})
            continue
        if gstatus != 200:
            out["outcome_not_restored"].append(
                {"task_id": tid, "prior_outcome": prior, "why": f"GET -> {gstatus}"})
            continue
        held = outcome_tags_of(task)
        if held == set(prior):
            out["outcome_restored"].append({"task_id": tid, "prior_outcome": prior,
                                            "why": "already back"})
            continue
        if held:
            out["outcome_kept"].append(
                {"task_id": tid, "prior_outcome": prior, "kept": sorted(held),
                 "why": f"the ticket now carries {sorted(held)}, which is a newer decision — "
                        f"`{', '.join(prior)}` was NOT put back"})
            continue
        ok = True
        for tag in prior:
            res = add_tag(client, task, tag, ledger_path, mode="revert",
                          extra={"restored_after_revert": True})
            if res["result"] not in ("written", "already_tagged"):
                ok = False
                out["outcome_not_restored"].append(
                    {"task_id": tid, "prior_outcome": prior, "tag": tag,
                     "why": f"re-add did not land: {res['result']}"})
        if not ok:
            continue
        try:
            gstatus, fresh = client.request("GET", f"/task/{tid}")
            now = outcome_tags_of(fresh) if gstatus == 200 else set()
        except Exception:                   # noqa: BLE001
            now = set()
        if now == set(prior):
            out["outcome_restored"].append({"task_id": tid, "prior_outcome": prior,
                                            "why": "restored"})
        else:
            out["outcome_not_restored"].append(
                {"task_id": tid, "prior_outcome": prior, "now": sorted(now),
                 "why": f"after re-adding, the ticket reads {sorted(now) or 'no outcome tag'} — "
                        f"repair `{', '.join(prior)}` by hand"})
    return out


def probe(client, task_id: str, ledger_path: str, *, board: dict | None = None) -> dict:
    """Prove the write path on ONE live ticket: add, read back, remove — same run.

    This replaces the "one confirmed row -> one ticket" canary the dispatch
    expected, which does not exist on the live board (the only confirmed register
    row carries no ClickUp id) and cannot be invented without lying about a
    register row. It exercises the same primitives production uses (`add_tag` /
    `remove_tag`), so it proves the endpoint, the encoding, the throttle, the
    read-back and the ledger.

    It writes `customer-outcome:blocked`, NOT `complete`, on purpose: if this
    process dies between the write and the revert, the ticket must not be left
    saying the erasure is done. "blocked" is the weaker of the two true claims.
    Both halves are ledgered, so `--revert` still cleans up a crash.
    """
    tid = str(task_id)
    task = (board or {}).get(tid)
    if task is None:
        status, task = client.request("GET", f"/task/{tid}")
        if status != 200 or not isinstance(task, dict):
            raise RegisterUnavailable(f"GET /task/{tid} -> {status}")
    held = outcome_tags_of(task)
    if held:
        raise RegisterUnavailable(
            f"task {tid} already carries {sorted(held)}; pick a ticket with no outcome tag")
    if status_of(task) in TERMINAL_STATUSES:
        raise RegisterUnavailable(f"task {tid} is `{status_of(task)}`; pick a live ticket")
    res = add_tag(client, task, TAG_BLOCKED, ledger_path, mode="probe",
                  extra={"why": f"--probe: add + read back + remove canary ({_now_iso()})"})
    if res["result"] == "failed":
        # `add_tag` only reports `failed` after a READ showed the tag is not on the
        # ticket (a lost response is resolved by reading, never assumed), so this is
        # the one branch where "nothing was written" is a measured fact.
        return {"probe": res, "reverted": None,
                "note": "the POST failed and a read confirmed the tag is not on the "
                        "ticket; nothing was written"}
    if res["result"] != "written":
        # The POST was accepted but its confirmation GET failed. It may be ON the
        # ticket, so cleaning up is not optional: a canary that leaves
        # `customer-outcome:blocked` behind has damaged the board it was testing.
        rev = remove_tag(client, tid, TAG_BLOCKED, ledger_path, mode="probe-revert",
                         extra={"why": "--probe cleaning up after an unconfirmed add"})
        return {"probe": res, "reverted": rev,
                "note": "the add did not read back; cleanup was attempted anyway"}
    rev = remove_tag(client, tid, TAG_BLOCKED, ledger_path, mode="probe-revert",
                     extra={"why": "--probe reverting its own write"})
    return {"probe": res, "reverted": rev}


# ───────────────────────── intake gaps ─────────────────────────


def record_intake_gaps(state_dir: str, gaps: list, *, now: datetime) -> list:
    """Emit one work item per ticket the register does not know, and age the gap.

    The register's intake owns these (its hourly `tick` re-scans every open
    data-deletion ticket and its Intercom conversations). This drainer therefore
    records the item — with the command that owns the retry — and never creates a
    row itself. A gap that survives N runs is not "the next tick will get it".
    """
    path = os.path.join(state_dir, "intake-gaps.json")
    state = {}
    try:
        with open(path) as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}
    if not isinstance(state, dict):
        state = {}
    current = {g["task_id"] for g in gaps}
    for g in gaps:
        prior = state.get(g["task_id"]) if isinstance(state.get(g["task_id"]), dict) else {}
        g["runs"] = int(prior.get("runs") or 0) + 1
        g["first_seen"] = prior.get("first_seen") or iso(now)
        g["item"] = {
            "kind": "register-intake-gap",
            "at": iso(now), "clickup_id": g["task_id"],
            "conversation_id": g.get("conversation_id") or "",
            "reason": "open action:data-deletion ticket with no register row after a register tick",
            "owns_retry": "gdpr-pipeline.py tick",
            "note": "This drainer creates no register row on purpose: identity verdicts and "
                    "the hide decision live in the register. The register's own intake must "
                    "pick this request up, after which this drainer closes the ticket on its "
                    "written confirmation.",
        }
        state[g["task_id"]] = {"runs": g["runs"], "first_seen": g["first_seen"],
                               "conversation_id": g.get("conversation_id") or "",
                               "last_seen": iso(now)}
    for tid in list(state):
        if tid not in current:
            state.pop(tid, None)       # the register picked it up: the gap closed itself
    os.makedirs(state_dir, mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, path)
    if gaps:
        spool = os.path.join(state_dir, "intake-gaps.jsonl")
        for g in gaps:
            append_ledger(spool, g["item"])
    return gaps


# ───────────────────────── reporting ─────────────────────────


def counts(selected: dict, register: dict, board: dict, results: dict | None) -> dict:
    rows = register["rows"]
    closed_past_due = [a for a in selected["attention"] if a.get("past_due")]
    overdue_by_class = {}
    for o in selected["overdue"]:
        overdue_by_class[o["class"]] = overdue_by_class.get(o["class"], 0) + 1
    return {
        "register_rows": len(rows),
        "register_open": sum(1 for r in rows.values() if r["status"] == "open"),
        "register_confirmed": sum(1 for r in rows.values() if confirmed(r)),
        "register_confirmed_unticketed": sum(
            1 for r in rows.values() if confirmed(r) and not (
                r["clickup_ids"] or [k for k in r["keys"] if k.startswith("clickup:")])),
        "register_closed_no_confirmation": sum(
            1 for r in rows.values() if r["status"] != "open" and not confirmed(r)),
        "register_hidden_not_confirmed": sum(
            1 for r in rows.values() if r["hidden_at"] and not confirmed(r)),
        "board_tickets": len(board),
        "board_open": sum(1 for t in board.values() if is_open(t)),
        "complete_writes": len(selected["complete"]),
        "blocked_writes": len(selected["blocked"]),
        "legal_confirmed": len(selected["legal_confirmed"]),
        "overdue": len(selected["overdue"]),
        "overdue_by_class": overdue_by_class,
        "closed_past_due": len(closed_past_due),
        "conflicting": len(selected.get("conflicting") or []),
        "comments_retried": len((results or {}).get("comment_retry", {}).get("written", [])),
        "comments_still_failed": len((results or {}).get("comment_retry", {}).get("failed", [])),
        # A retry that never happened leaves the ticket exactly as sound as a retry
        # that failed: closed, with no note saying why. Both are unresolved.
        "comments_unresolved": len((results or {}).get("comment_retry", {}).get("failed", []))
                                + len((results or {}).get("comment_retry", {}).get("skipped", [])),
        "attention": len(selected["attention"]),
        "link_pending": len(selected["link_pending"]),
        "no_register_row": len(selected["no_register_row"]),
        "writes_written": len((results or {}).get("written") or []),
        "writes_already_tagged": len((results or {}).get("already_tagged") or []),
        "writes_skipped_terminal": len((results or {}).get("skipped_terminal") or []),
        "writes_skipped_untagged": len((results or {}).get("skipped_untagged") or []),
        "writes_unreadable": len((results or {}).get("unreadable") or []),
        "writes_failed": len((results or {}).get("failed") or []),
        "writes_readback_missing": len((results or {}).get("readback_missing") or []),
        "writes_retagged": len((results or {}).get("retagged") or []),
        "writes_skipped_closed": len((results or {}).get("skipped_closed") or []),
        "writes_capped_out": (results or {}).get("capped_out", 0),
        "tickets_resolved": len((results or {}).get("resolved") or []),
        "tickets_resolve_failed": len((results or {}).get("resolve_failed") or []),
        "closes_commented": sum(1 for r in (results or {}).get("resolved") or []
                                if (r.get("result") or {}).get("comment") == "written"),
        "closes_without_comment": sum(1 for r in (results or {}).get("resolved") or []
                                      if (r.get("result") or {}).get("comment") != "written"),
    }


def _ids(seq, key="task_id", limit=DIGEST_TICKET_IDS) -> str:
    ids = [str(x.get(key)) for x in seq if x.get(key)]
    shown = ids[:limit]
    more = len(ids) - len(shown)
    return ", ".join(shown) + (f" (+{more} more)" if more > 0 else "")


def digest_line(c: dict, *, mode: str) -> str:
    """ONE line: the board numbers and the legal clock, side by side.

    The two used to be reported by different systems on different days, which is
    how "138 open tickets" and "159 overdue requests" could both be true and read
    as unrelated. They are the same population seen from the two ends.
    """
    parts = [
        f"*data-deletion drainer* ({mode})",
        f"register {c['register_rows']} rows / {c['register_open']} open / "
        f"{c['register_confirmed']} confirmed ({c['register_confirmed_unticketed']} with no ticket) / "
        f"{c['register_hidden_not_confirmed']} hidden-not-confirmed / "
        f"{c['register_closed_no_confirmation']} closed-no-confirmation",
        f"board {c['board_tickets']} tickets / {c['board_open']} open",
        f"OVERDUE {c['overdue']}" + (
            " (" + ", ".join(f"{k} {v}" for k, v in sorted(c["overdue_by_class"].items())) + ")"
            if c["overdue_by_class"] else ""),
        f"→{TAG_COMPLETE} {c['complete_writes']} / →{TAG_BLOCKED} {c['blocked_writes']} / "
        f"legal-confirmed-human {c['legal_confirmed']} / link-pending {c['link_pending']} / "
        f"no-register-row {c['no_register_row']} / closed-no-letter {c['attention']}"
        + (f" / CONFLICTING {c['conflicting']}" if c["conflicting"] else ""),
        f"writes {c['writes_written']} written, {c['writes_already_tagged']} already tagged, "
        f"{c['writes_skipped_terminal']} terminal, {c['writes_skipped_untagged']} off-queue, "
        f"{c['writes_failed']} failed, {c['writes_unreadable']} unreadable, "
        f"{c['writes_readback_missing']} readback-missing, "
        f"{c['writes_skipped_closed']} not-open, {c['writes_capped_out']} capped · "
        f"closed on confirmation {c['tickets_resolved']}"
        + (f" ({c['closes_commented']} with the register row noted on the ticket)"
           if c["tickets_resolved"] else "")
        + (f" ({c['tickets_resolve_failed']} close failed)" if c["tickets_resolve_failed"] else ""),
    ]
    return " · ".join(parts)


def overdue_line(selected: dict) -> str:
    ov = selected["overdue"]
    closed_past_due = [a for a in selected["attention"] if a.get("past_due")]
    # The register's own watchdog counts OPEN rows only, so a row a human closed
    # without a letter disappears from the legal clock. OVERDUE keeps the register's
    # number — two systems publishing different totals is how the board and the
    # register drifted apart in the first place — and the excluded rows are NAMED
    # here instead, with the reason they are not in the count.
    tail = (""
            if not closed_past_due else
            f" · ALSO PAST ITS DATE, and outside that count because the register's own "
            f"watchdog reads only open rows: {len(closed_past_due)} row(s) CLOSED WITH NO "
            f"WRITTEN LETTER (rows "
            f"{', '.join(f'#{a['register_no']}' for a in closed_past_due[:DIGEST_TICKET_IDS])}"
            f"{f' (+{len(closed_past_due) - DIGEST_TICKET_IDS} more)' if len(closed_past_due) > DIGEST_TICKET_IDS else ''})"
            f" — a closed row is not a letter, and their tickets stay open")
    if not ov:
        return ("overdue: none — every open request is inside its statutory date" + tail)
    tickets = [{"task_id": t} for o in ov for t in o["clickup_ids"]]
    notick = [o for o in ov if not o["clickup_ids"]]
    rows = ", ".join(f"#{o['register_no']}" for o in ov[:DIGEST_TICKET_IDS])
    more = len(ov) - min(len(ov), DIGEST_TICKET_IDS)
    return (f"overdue {len(ov)} requests past the 30-day date with no written confirmation "
            f"(rows {rows}{f' (+{more} more)' if more > 0 else ''}) · tickets behind them: "
            f"{_ids(tickets) or 'none linked'}"
            + (f" · {len(notick)} of those rows have no ticket on the board at all" if notick else "")
            + " · the letter is the message; none of these are tagged complete or not-applicable"
            + tail)


def blocked_line(selected: dict) -> str:
    """The counsel tickets this run labels, with the register row behind each one.

    The row id is what makes the tag auditable by a human who has the register
    open: "blocked" alone says nothing about WHY, and the reason lives in a
    register row this drainer must not write.
    """
    blocked = selected["blocked"]
    if not blocked:
        return "counsel: no open legal-threat/DMCA ticket needs a `blocked` label"
    shown = ", ".join(f"{b['task_id']}=row {b['register_no']}" for b in blocked[:DIGEST_TICKET_IDS])
    more = len(blocked) - min(len(blocked), DIGEST_TICKET_IDS)
    return (f"counsel {len(blocked)} ticket(s) labelled {TAG_BLOCKED} (never closed here — "
            f"counsel's letter is the outcome): {shown}{f' (+{more} more)' if more > 0 else ''}")


# ───────────────────────── Slack ─────────────────────────


def post_slack(text: str, channel: str, config_path: str = DEFAULT_SLACK_CONFIG,
               account: str = "default") -> bool:
    """Best-effort post. NEVER raises (a digest is not worth a failed unit)."""
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        from lib.slack_token import resolve_secret
        token = resolve_secret(cfg["channels"]["slack"]["accounts"][account]["botToken"])
    except (OSError, KeyError, ValueError, TypeError, ImportError):
        print(f"WARN: no Slack token for '{account}' in {config_path}; digest not posted",
              file=sys.stderr)
        return False
    if not token:
        return False
    try:
        req = urllib.request.Request(
            "https://slack.com/api/chat.postMessage",
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
    except Exception as exc:                # noqa: BLE001 - best-effort by contract
        print(f"WARN: Slack post error: {type(exc).__name__}: {str(exc)[:140]}",
              file=sys.stderr)
        return False


# ───────────────────────── main ─────────────────────────


def _load_board_json(path: str) -> dict:
    with open(path) as f:
        data = json.load(f)
    tasks = data.get("tasks") if isinstance(data, dict) else data
    if not isinstance(tasks, list):
        raise RegisterUnavailable(f"{path} is not a ClickUp task list/dump")
    return {str(t.get("id")): t for t in tasks if isinstance(t, dict) and t.get("id")}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Close ClickUp action:data-deletion tickets on the register's written "
                    "confirmation (never on the hide), and report the legal clock.")
    ap.add_argument("--apply", action="store_true",
                    help="write tags (default is a dry run)")
    ap.add_argument("--json", action="store_true", help="machine-readable report")
    ap.add_argument("--examples", type=int, default=5, help="items named per section (default 5)")
    ap.add_argument("--max-writes", type=int, default=DEFAULT_MAX_WRITES,
                    help=f"API mutations per run — a label add/remove, a status PUT, a "
                         f"comment (default/hard cap {MAX_WRITES_HARD})")
    ap.add_argument("--register", default=DEFAULT_REGISTER, help="the erasure register sqlite")
    ap.add_argument("--list-id", default=LIST_ID, help="ClickUp list id")
    ap.add_argument("--board-json", help="read the board from a saved dump instead of the API")
    ap.add_argument("--state-dir", default=DEFAULT_STATE_DIR, help="state + ledger directory")
    ap.add_argument("--ledger", help="ledger path (default <state-dir>/data-deletion.jsonl)")
    ap.add_argument("--revert", metavar="LEDGER",
                    help="remove the tags the given ledger recorded, then exit")
    ap.add_argument("--probe", metavar="TASK_ID",
                    help="add+read-back+remove the blocked tag on one live ticket (proves the "
                         "write path without ever claiming a removal), then exit")
    ap.add_argument("--slack-channel", default=DEFAULT_CHANNEL, help="digest channel")
    ap.add_argument("--slack-config", default=DEFAULT_SLACK_CONFIG)
    ap.add_argument("--no-notify", action="store_true", help="never post to Slack")
    ap.add_argument("--notify-dry-run", action="store_true",
                    help="post the digest even though nothing was written (a scheduled dry "
                         "run must stay silent; a human preview has to ask)")
    ap.add_argument("--gap-runs", type=int, default=DEFAULT_GAP_RUNS,
                    help="page after this many runs with the same row-less ticket (default 3)")
    ap.add_argument("--kill-file", default=KILL_FILE)
    args = ap.parse_args(argv)

    state_dir = args.state_dir
    ledger = args.ledger or os.path.join(state_dir, "data-deletion.jsonl")
    now = datetime.now(timezone.utc)
    killed = os.path.exists(args.kill_file)

    # --revert first, and on its own: it needs the ledger and the API, not a board
    # scan (5,000 tasks of paging to answer a question the ledger already answers).
    if args.revert:
        try:
            out = revert(_client(), args.revert)
        except RegisterUnavailable as exc:
            print(f"FAIL (nothing reverted): {exc}", file=sys.stderr)
            return 2
        print(json.dumps(out, indent=1) if args.json else
              f"revert: {len(out['removed'])} removed, {len(out['still_present'])} still present, "
              f"{len(out['failed'])} failed, {len(out['skipped'])} already reverted, "
              f"{len(out['reopened'])} reopened, {len(out['already_at_target'])} already at "
              f"target, {len(out['left_for_human'])} left as a human set them, "
              f"{len(out['reopen_failed'])} reopen failed, "
              f"{len(out['outcome_restored'])} prior outcome(s) restored, "
              f"{len(out['outcome_kept'])} prior outcome(s) left to the newer decision")
        incomplete = (out["still_present"] or out["failed"] or out["reopen_failed"]
                      or out["outcome_not_restored"])
        if incomplete and not args.json:
            print(f"REVERT INCOMPLETE: {len(incomplete)} item(s) not undone — see the JSON with "
                  f"--json; nothing else was attempted", file=sys.stderr)
        return 6 if incomplete else 0

    if killed:
        # HONOURED BEFORE THE READS. The kill switch promises no write AND no page, so
        # it cannot be checked after the board/register reads: a ClickUp or register
        # outage while the switch is on would exit 2 and page through the unit's
        # OnFailure — a kill switch that pages about the very thing it was switched
        # off for, every hour, until someone notices. `--revert` above is the one
        # exception: an emergency rollback must stay available.
        print(f"kill file {args.kill_file} is present: refusing every write", file=sys.stderr)
        return 4

    try:
        # --probe needs the live API even when a board dump was supplied for a scan.
        client = _client() if (args.probe or not args.board_json) else None
        board = _load_board_json(args.board_json) if args.board_json else scan_board(
            client, args.list_id)
        register = load_register(args.register)
    except RegisterUnavailable as exc:
        print(f"FAIL (nothing written): {exc}", file=sys.stderr)
        return 2

    if args.probe:
        try:
            out = probe(client, args.probe, ledger, board=board)
        except RegisterUnavailable as exc:
            print(f"FAIL (nothing written): {exc}", file=sys.stderr)
            return 2
        print(json.dumps(out, indent=1) if args.json else
              f"probe: {out['probe']['result']} on {args.probe}; revert: "
              f"{(out.get('reverted') or {}).get('result', 'nothing to revert')}")
        cleaned = (out.get("reverted") or {}).get("result") == "removed"
        proven = out["probe"]["result"] == "written"
        if not cleaned and not args.json:
            print(f"PROBE LEFT A TAG BEHIND on {args.probe}: "
                  f"{(out.get('reverted') or {}).get('result', 'no revert attempted')} — remove "
                  f"`{out['probe']['tag']}` by hand, or `--revert {ledger}`", file=sys.stderr)
        elif not proven and not args.json:
            print(f"PROBE UNPROVEN on {args.probe}: the add answered "
                  f"`{out['probe']['result']}` (cleanup: "
                  f"{(out.get('reverted') or {}).get('result', 'not attempted')}) — the write path "
                  f"is not confirmed", file=sys.stderr)
        return 0 if (proven and cleaned) else 5

    selected = select(register, board, now)
    # ONE budget for the whole run. `--max-writes` promises a bound on API
    # mutations per run, not per phase: a fresh budget for the comment retries
    # would let an armed hourly job issue 2x the documented number.
    run_budget = MutationBudget(min(int(args.max_writes), MAX_WRITES_HARD))
    # ONLY a run that is allowed to write may age the gap state. A dry run is a
    # preview and a killed run wrote nothing, so neither may advance a counter that
    # decides when a human gets paged: two previews plus one real run would page on
    # the third run's "gap survived 3 runs" after a single real hour.
    if args.apply:
        record_intake_gaps(state_dir, selected["no_register_row"], now=now)
    writes = selected["complete"] + selected["blocked"]

    mode = "apply" if args.apply else "dry run"
    results = None
    if args.apply and writes:
        # THE LEDGER MUST BE READABLE BEFORE THE FIRST WRITE. `execute()` appends to
        # it, and a crash-truncated line makes `read_ledger()` refuse the whole file —
        # so writing first and discovering the damage afterwards leaves the new
        # closes recorded in a ledger `--revert` will not read, i.e. unrevertible by
        # the one path that promises to undo them. Refuse before mutating anything.
        if os.path.exists(ledger):          # a first run has no ledger yet, which is fine
            try:
                read_ledger(ledger)
            except LedgerUnreadable as exc:
                print(f"FAIL (nothing written): the ledger is unreadable ({exc}) — writing into "
                      f"it would make these writes unrevertible; repair or move it first",
                      file=sys.stderr)
                return 2
        try:
            results = execute(client, writes, board, ledger, max_writes=args.max_writes,
                              budget=run_budget)
        except RegisterUnavailable as exc:
            print(f"FAIL (nothing written): {exc}", file=sys.stderr)
            return 2

    # Audit-comment debt from an earlier close: retried here, on a ticket that must
    # still be the close the comment describes. Bounded by the same mutation budget.
    comment_retry = {"written": [], "failed": [], "skipped": []}
    comment_ledger_bad = False
    if args.apply:
        try:
            debt = comment_debt(ledger)
        except LedgerUnreadable as exc:
            # The closes and the writes still have to happen — the ledger is the
            # record of what was attempted, not the register. But the debt it holds
            # is now unreadable, so the run is not green and says so.
            print(f"LEDGER UNREADABLE ({exc}): closing continues, audit-comment debt for "
                  f"earlier runs cannot be settled", file=sys.stderr)
            debt = {}
            comment_ledger_bad = True
        else:
            comment_ledger_bad = False
        if debt:
            comment_retry = retry_comments(client, debt, ledger, board=board,
                                           budget=run_budget)

    # A write whose own confirmation failed is re-checked once. Only what is still
    # unconfirmed (or whose write errored outright) pages: nothing else here is
    # worth a human's attention, and an hourly page that fires on non-events is a
    # page nobody reads.
    # The retry outcome belongs to the run's counts even when nothing else was
    # written — an unsettled note is the whole reason this run is not green.
    results = results if results is not None else {}
    results["comment_retry"] = comment_retry
    unconfirmed = (results or {}).get("readback_missing") or []
    if unconfirmed:
        ok, missing = verify_pending(client, unconfirmed, ledger)
        results["written"].extend(ok)
        results["readback_missing"] = missing
        for w in ok:
            if w.get("tag") != TAG_COMPLETE:
                continue
            # The verification GET is the freshest read there is; use it, not the
            # scan snapshot. `execute()` refuses to write to a ticket that left
            # `action:data-deletion`, and this recovery path must refuse for exactly
            # the same reason — otherwise a retag between scan and recovery closes a
            # ticket that is no longer this drainer's to close.
            task = w.pop("_fresh", None) or board.get(w["task_id"]) or {}
            if not has_action_tag(task):
                # The tag itself DID land (that is what verification confirmed), on a
                # ticket that has since left the queue. Nothing to roll back here — a
                # revert is a human's decision — but the run is not green: a label was
                # put on a ticket this job no longer owns, and a person needs to see it.
                results["retagged"].append(
                    {**w, "why": f"ticket no longer carries `action:data-deletion` "
                                 f"(tags: {', '.join(sorted(tag_names(task))) or 'none'}) — "
                                 f"`{w.get('tag')}` WAS written, closing is not this job's call"})
                continue
            if status_of(task) in TERMINAL_STATUSES or not is_open(task):
                # A ticket that is no longer open is not waiting for this drainer: the
                # close already happened, or a human moved it somewhere this job does
                # not understand. Either way a second PUT adds nothing.
                continue
            closed = resolve_task(client, w["task_id"], ledger, task=task,
                                  before_status=status_of(task),
                                  before_outcome=",".join(sorted(outcome_tags_of(task))),
                                  register_no=w.get("register_no"),
                                  confirmed_at=w.get("confirmed_at") or "")
            (results["resolved"] if closed["result"] == "resolved"
             else results["resolve_failed"]).append({**w, "result": closed})
    # Three DIFFERENT failures, and the page must not blur them: a write that did not
    # reach the board (not labelled), a label that landed without its close (labelled,
    # still open), and a label that landed on a ticket that has since left the queue
    # (labelled, not ours any more). Telling an operator "NOT labelled" when the tag is
    # sitting on the ticket sends them away from the thing they have to look at.
    unverified = [m for m in ((results or {}).get("readback_missing") or [])
                  if m.get("maybe_landed")]
    unlanded = ((results or {}).get("failed") or []) + \
               [m for m in ((results or {}).get("readback_missing") or [])
                if not m.get("maybe_landed")]
    unclosed = (results or {}).get("resolve_failed") or []
    offqueue = (results or {}).get("retagged") or []
    stuck = unlanded + unverified + unclosed + offqueue
    failed_posts = []

    def deliver(text: str, channel: str) -> None:
        """Post, and REMEMBER a failure.

        A dropped report is not a detail. The hourly unit is the only thing that
        puts the register's overdue count in front of a human, and it reports
        health through its exit code (`OnFailure` + the cron watchdog read that,
        not Slack). Swallowing a failed post would mean the legal clock can stop
        being reported while every run exits 0 — so a post the run was asked to
        deliver either goes out or the run fails.
        """
        if not post_slack(text, channel, args.slack_config):
            failed_posts.append(channel)

    conflicting = selected.get("conflicting") or []
    if conflicting:
        print(f"\nCONFLICTING DECISIONS (nothing written for these): {len(conflicting)} ticket(s) "
              f"the register wants two different outcomes for")
        for it in conflicting[:max(args.examples, 0)]:
            print(f"  · {it['task_id']}: {it['why']} [register rows "
                  f"{', '.join(str(n) for n in it['register_nos']) or '?'}]")
        if not args.no_notify:
            deliver(
                f":warning: data-deletion drainer: {len(conflicting)} ClickUp ticket(s) have "
                f"CONFLICTING decisions from the register — {_ids(conflicting)}  "
                f"(register rows "
                f"{', '.join(sorted({str(n) for it in conflicting for n in it['register_nos']}))}). "
                f"Nothing was written for them: two register rows point at one ticket with "
                f"different outcomes, and writing either label would be a claim about the other "
                f"row. One of the links is wrong — this is a human's call, not the drainer's.",
                DEFAULT_ALERT_CHANNEL)
    c = counts(selected, register, board, results)
    if stuck and not args.no_notify:
        lines = []
        if unlanded:
            lines.append(f"{len(unlanded)} outcome write(s) did NOT LAND — "
                         f"{_ids(unlanded)}. These tickets are NOT labelled.")
        if unverified:
            # Two failed reads are NOT evidence of absence: the POST was accepted and
            # both confirmations 503'd. Telling an operator "not labelled" during a
            # ClickUp read outage points them away from a tag that may well be there.
            lines.append(f"{len(unverified)} outcome write(s) could NOT BE CONFIRMED — "
                         f"{_ids(unverified)}. ClickUp accepted the write but this job "
                         f"could not read the ticket back, so the tag MAY be on those "
                         f"tickets; check before re-running or reverting.")
        if unclosed:
            lines.append(f"{len(unclosed)} ticket(s) were labelled but NOT closed — "
                         f"{_ids(unclosed)}. They still carry the new outcome tag and are "
                         f"still open; the next run finishes them.")
        if offqueue:
            lines.append(f"{len(offqueue)} ticket(s) DID get the outcome tag but have LEFT "
                         f"`action:data-deletion` since — {_ids(offqueue)}. The tag is ON "
                         f"those tickets and they were not closed: check what they are "
                         f"about now before reverting.")
        deliver(
            f":rotating_light: data-deletion drainer: {len(stuck)} ticket(s) need a human. "
            + " ".join(lines) +
            f" Ledger: {ledger}. Revert with `{Path(__file__).name} --revert {ledger}`.",
            DEFAULT_ALERT_CHANNEL)

    gaps_over = [g for g in selected["no_register_row"] if g.get("runs", 0) >= args.gap_runs]
    digest = digest_line(c, mode=mode)
    report = {"at": iso(now), "mode": mode, "killed": killed, "counts": c,
              "digest": digest, "overdue_line": overdue_line(selected),
              "blocked_line": blocked_line(selected),
              "selected": selected, "results": results}
    if args.json:
        print(json.dumps(report, indent=1, default=str))
    else:
        print(digest)
        print(overdue_line(selected))
        if selected["blocked"]:
            print(blocked_line(selected))
        for section in ("complete", "blocked", "legal_confirmed", "attention",
                        "link_pending", "no_register_row"):
            items = selected[section]
            print(f"\n{section}: {len(items)}")
            for it in items[:max(args.examples, 0)]:
                who = it.get("task_id") or f"register row {it.get('row')}"
                link = f" [{CLICKUP_TASK_URL.format(it['task_id'])}]" if it.get("task_id") else ""
                print(f"  · {who}: {it.get('why', '')}{link}")
        closed_status = (results or {}).get("skipped_closed") or []
        if closed_status:
            print(f"\nNOT OPEN (not written): {len(closed_status)} ticket(s) are in a status "
                  f"this drainer does not write to")
            for it in closed_status[:max(args.examples, 0)]:
                print(f"  · {it['task_id']}: {it.get('why', '')}")
        retagged = (results or {}).get("retagged") or []
        if retagged:
            print(f"\nRETAGGED MID-RUN: {len(retagged)} ticket(s) left `action:data-deletion` "
                  f"between the scan and the write; the outcome tag landed, nothing was closed")
            for it in retagged[:max(args.examples, 0)]:
                print(f"  · {it['task_id']}: {it.get('why', '')}")
        unreadable = (results or {}).get("unreadable") or []
        if unreadable:
            print(f"\nUNREADABLE (not written): {len(unreadable)} ticket(s) the register links "
                  f"could not be read, so their state is unknown:")
            for it in unreadable[:max(args.examples, 0)]:
                print(f"  · {it['task_id']}: {it.get('why', '')} [register row "
                      f"{it.get('register_no')}]")
        skipped_untagged = (results or {}).get("skipped_untagged") or []
        if skipped_untagged:
            print(f"\nPOSITIVELY SKIPPED (not written): {len(skipped_untagged)} ticket(s) the "
                  f"register links but which no longer carry `action:data-deletion`")
            for it in skipped_untagged[:max(args.examples, 0)]:
                print(f"  · {it['task_id']}: {it.get('why', '')} [register row "
                      f"{it.get('register_no')}]")
        retry_state = (results or {}).get("comment_retry") or {}
        unsettled = (retry_state.get("failed") or []) + (retry_state.get("skipped") or [])
        if unsettled:
            print(f"\nAUDIT COMMENT UNSETTLED for {len(unsettled)} closed ticket(s): the note "
                  f"saying which register row closed it is NOT on the ticket")
            for it in unsettled:
                print(f"  · {it['task_id']}: {it.get('why') or it.get('result') or 'failed'}")
        if gaps_over:
            print(f"\nINTAKE GAP PERSISTS for {len(gaps_over)} ticket(s) across "
                  f">={args.gap_runs} runs: {_ids(gaps_over)} — the register's own tick is not "
                  f"picking them up; work items are in {state_dir}/intake-gaps.jsonl")

    # A dry run is silent unless asked: the hourly unit always runs `--apply`, so
    # the only dry runs are human previews, and a preview that pings #cs_chats is
    # noise. This is also what the runbook promises ("no writes, no messages").
    if not args.no_notify and (args.apply or args.notify_dry_run):
        deliver(digest, args.slack_channel)
        if c["overdue"] or c["closed_past_due"]:
            deliver(overdue_line(selected), args.slack_channel)
        if args.apply and c["blocked_writes"]:
            deliver(blocked_line(selected), args.slack_channel)
        closed_status = (results or {}).get("skipped_closed") or []
        if closed_status:
            print(f"\nNOT OPEN (not written): {len(closed_status)} ticket(s) are in a status "
                  f"this drainer does not write to")
            for it in closed_status[:max(args.examples, 0)]:
                print(f"  · {it['task_id']}: {it.get('why', '')}")
        retagged = (results or {}).get("retagged") or []
        if retagged:
            print(f"\nRETAGGED MID-RUN: {len(retagged)} ticket(s) left `action:data-deletion` "
                  f"between the scan and the write; the outcome tag landed, nothing was closed")
            for it in retagged[:max(args.examples, 0)]:
                print(f"  · {it['task_id']}: {it.get('why', '')}")
        unreadable = (results or {}).get("unreadable") or []
        if unreadable:
            print(f"\nUNREADABLE (not written): {len(unreadable)} ticket(s) the register links "
                  f"could not be read, so their state is unknown:")
            for it in unreadable[:max(args.examples, 0)]:
                print(f"  · {it['task_id']}: {it.get('why', '')} [register row "
                      f"{it.get('register_no')}]")
        skipped_untagged = (results or {}).get("skipped_untagged") or []
        if skipped_untagged:
            print(f"\nPOSITIVELY SKIPPED (not written): {len(skipped_untagged)} ticket(s) the "
                  f"register links but which no longer carry `action:data-deletion`")
            for it in skipped_untagged[:max(args.examples, 0)]:
                print(f"  · {it['task_id']}: {it.get('why', '')} [register row "
                      f"{it.get('register_no')}]")
        if gaps_over:
            deliver(
                f":warning: data-deletion drainer: {len(gaps_over)} open `action:data-deletion` "
                f"ticket(s) still have no register row after >={args.gap_runs} hourly runs "
                f"({_ids(gaps_over)}). The register's intake is not picking them up, so no "
                f"legal clock exists for them. This drainer will not create a register row.",
                DEFAULT_ALERT_CHANNEL)
    if (c["writes_readback_missing"] or c["writes_failed"] or c["tickets_resolve_failed"]
            or c["writes_unreadable"] or c["conflicting"] or c["writes_retagged"]
            or c["comments_unresolved"] or comment_ledger_bad):
        # A 403/500 on the tag POST leaves the confirmed ticket open, and a linked
        # ticket we could not even read is an open ticket with a confirmed row
        # behind it. Exiting 0 there means the timer looks healthy, OnFailure never
        # fires, and the only trace is a ledger line nobody reads. The page is best
        # effort; the exit code is not. A conflict counts too: a confirmed erasure
        # that was deliberately NOT closed is not a healthy run.
        return 5
    if failed_posts:
        print(f"REPORT NOT DELIVERED: {len(failed_posts)} Slack message(s) did not go out "
              f"({', '.join(sorted(set(failed_posts)))}). The writes are fine; the report a "
              f"human was supposed to see is not, so this run is not green.", file=sys.stderr)
        return 7
    return 0


if __name__ == "__main__":
    sys.exit(main())
