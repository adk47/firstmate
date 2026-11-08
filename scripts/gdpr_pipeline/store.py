"""The register as a machine record: `erasure_requests` (one row per REQUEST, every channel).

SQLite at GDPR_STORE (default /var/lib/hydra-gdpr/erasure.sqlite, 0600, under /var/lib so the deploy rsync never
touches it). Three tables:

  erasure_requests  one row per request: register_no (the markdown register's '#', continued from 40), channel,
                    class, received_at, due_at = received + 30 d, hide_due_at = received + 24 h, requester,
                    pages (catalog ids only), identity verdict + basis, action, ask / hide / confirmation dates.
                    Never a message body (ids and names only, like the legal-intake ledger).
  erasure_keys      row key per channel -> request (cs-systemic-c3 `register-intercom-intake-1101.md`):
                    intercom:<conversation_id>, gmail:<alias>:<thread>, clickup:<task_id>, register:<n>.
                    The key IS the idempotence test: an intake that finds its key does not add a row.
                    One request can hold several keys (the same person on Intercom + notices@ + a ticket).
  erasure_events    append-only audit: every create / merge / decide / ask / hide-pr / hidden / confirm / page.

Reconciliation (c3 handoff §5): ClickUp is a SECONDARY index. A candidate joins an existing request when it
shares a key, or when it shares a catalog id AND the requester email with an OPEN request; never on ticket id
alone. Merging keeps the EARLIEST received_at, so a merge can only bring a due date forward.
"""
from __future__ import annotations

import json
import os
import sqlite3
from datetime import datetime, timedelta, timezone

DEFAULT_PATH = os.environ.get("GDPR_STORE", "/var/lib/hydra-gdpr/erasure.sqlite")
DUE_DAYS = 30
HIDE_DUE_HOURS = 24
FIRST_NEW_REGISTER_NO = 40      # rows 1-39 are the markdown register's; new rows continue from here

SCHEMA = """
CREATE TABLE IF NOT EXISTS erasure_requests (
  id               INTEGER PRIMARY KEY,
  register_no      INTEGER UNIQUE,
  row_key          TEXT NOT NULL UNIQUE,
  channel          TEXT NOT NULL,              -- intercom | support | notices | legal | register
  class            TEXT NOT NULL,              -- privacy_erasure | legal_threat | dmca_takedown | privacy_access | not_erasure
  received_at      TEXT NOT NULL,              -- ISO-8601 Z
  due_at           TEXT NOT NULL,              -- received + 30 d (written confirmation)
  hide_due_at      TEXT NOT NULL,              -- received + 24 h
  requester_name   TEXT DEFAULT '',
  requester_email  TEXT DEFAULT '',
  contact_id       TEXT DEFAULT '',
  conversation_id  TEXT DEFAULT '',
  gmail_thread     TEXT DEFAULT '',
  clickup_ids      TEXT DEFAULT '[]',          -- JSON list
  pages            TEXT DEFAULT '[]',          -- JSON list of {"entity","id"} (full ids; prefixes marked)
  identity_verdict TEXT DEFAULT '',
  identity_basis   TEXT DEFAULT '',
  verdict_detail   TEXT DEFAULT '[]',          -- JSON list of {"id","verdict","why"}
  decided_at       TEXT DEFAULT '',
  action           TEXT DEFAULT '',
  ask_kind         TEXT DEFAULT '',
  ask_sent_at      TEXT DEFAULT '',
  ask_ref          TEXT DEFAULT '',
  hide_pr          TEXT DEFAULT '{}',          -- JSON {"hdevops": url, "pdp": url, "ids": [...]}
  hidden_at        TEXT DEFAULT '',            -- set only by a read-back (410 + noindex), never by a merge
  hidden_pages     TEXT DEFAULT '[]',          -- JSON list of the hide-eligible page ids that read back gone
  removed_outside_process TEXT DEFAULT '[]',   -- JSON list of page ids already 404 in catalog + public with no
                                               -- merge record: deleted by something other than the hide process
  confirmed_at     TEXT DEFAULT '',
  confirm_ref      TEXT DEFAULT '',
  rev              INTEGER DEFAULT 0,          -- bumped on EVERY content change; `decided_rev` says what the current
  decided_rev      INTEGER DEFAULT 0,          -- verdict was computed FROM (wall-clock comparison is not enough)
  status           TEXT DEFAULT 'open',        -- open | closed
  note             TEXT DEFAULT '',
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS erasure_sends (
  id          INTEGER PRIMARY KEY,
  request_id  INTEGER NOT NULL REFERENCES erasure_requests(id),
  kind        TEXT NOT NULL,                   -- ask | confirm | confirm-interim (the slot, not the copy)
  channel     TEXT NOT NULL,                   -- intercom | mail | none (no route)
  target      TEXT NOT NULL,                   -- conversation id / gmail thread id / empty
  body_sha    TEXT NOT NULL,                   -- sha256 of the exact approved copy that went out
  approved_by TEXT NOT NULL,                   -- the human Slack id in the allowlist
  state       TEXT NOT NULL,                   -- sending | sent | failed | refused | unknown (ambiguous, never retried)
  idem        TEXT DEFAULT '',                 -- the letter's id (request:slot:body sha), for reconciliation
  consumed_at TEXT DEFAULT '',                 -- when the WRITER consumed this claim (single-use). Set by
                                               -- intercom-ops-write.sh in the same statement that authorises the
                                               -- POST, so a replay cannot post the same letter twice; cleared by
                                               -- claim_send when a failed/refused slot is legitimately retried.
  ref         TEXT DEFAULT '',                 -- the writer's receipt (api-log line / gog output)
  detail      TEXT DEFAULT '',
  at          TEXT NOT NULL,
  UNIQUE(request_id, kind)                     -- ONE letter per request per kind, by construction
);
CREATE TABLE IF NOT EXISTS erasure_keys (
  key        TEXT PRIMARY KEY,
  request_id INTEGER NOT NULL REFERENCES erasure_requests(id)
);
CREATE TABLE IF NOT EXISTS erasure_events (
  id         INTEGER PRIMARY KEY,
  request_id INTEGER NOT NULL,
  at         TEXT NOT NULL,
  kind       TEXT NOT NULL,
  detail     TEXT DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS erasure_requests_due ON erasure_requests(status, due_at);
"""

JSON_COLS = ("clickup_ids", "pages", "verdict_detail", "hide_pr", "removed_outside_process", "hidden_pages")

# Columns added after the first deploy: CREATE TABLE IF NOT EXISTS never alters an existing store, so a live
# erasure.sqlite is migrated instead of being recreated (the rows are the legal record).
MIGRATIONS = (("removed_outside_process", "TEXT DEFAULT '[]'"), ("hidden_pages", "TEXT DEFAULT '[]'"),
              ("rev", "INTEGER DEFAULT 0"), ("decided_rev", "INTEGER DEFAULT 0"),
              # The interim confirmation is its own letter: recording it here keeps the fact visible on the row
              # without consuming `confirmed_at`, which only the FINAL letter may set (r5 finding 2).
              ("interim_confirm_at", "TEXT DEFAULT ''"), ("interim_confirm_ref", "TEXT DEFAULT ''"))


SENDS_MIGRATIONS = (("idem", "TEXT DEFAULT ''"),     # the letter's id; the ledger is the double-send guard
                    # A monotonic per-slot generation, bumped on EVERY claim. `at` cannot serve: it is a
                    # second-resolution timestamp, so two claims in the same second are indistinguishable and a
                    # stale resolution could still match a later attempt (QA #1848 r5, the ABA cycle).
                    ("attempt", "INTEGER DEFAULT 0"),
                    # The writer's single-use marker. A read-only "is there a sending row" check is not a claim:
                    # if the POST lands but the pipeline has not yet recorded `sent`, or two invocations overlap,
                    # the same check passes twice and the customer gets the letter twice. The writer now CONSUMES
                    # the claim in one conditional UPDATE and requires exactly one row to change.
                    ("consumed_at", "TEXT DEFAULT ''"))


def migrate(db: sqlite3.Connection) -> None:
    have_sends = {r[1] for r in db.execute("PRAGMA table_info(erasure_sends)")}
    for col, ddl in SENDS_MIGRATIONS:
        if col not in have_sends:
            db.execute(f"ALTER TABLE erasure_sends ADD COLUMN {col} {ddl}")
    have = {r[1] for r in db.execute("PRAGMA table_info(erasure_requests)")}
    added = set()
    for col, ddl in MIGRATIONS:
        if col not in have:
            db.execute(f"ALTER TABLE erasure_requests ADD COLUMN {col} {ddl}")
            added.add(col)
    if "decided_rev" in added:
        # Every verdict already on record was computed by the OLD rules (an admin-authored source body counted as
        # the customer's words, among others), so each decided row is marked changed exactly once and the next tick
        # re-decides it. Without this, a row decided before the migration would keep the verdict this fix exists to
        # correct until its 20-hour refresh -- and rows bitten by the same-second bug would never be revisited.
        db.execute("UPDATE erasure_requests SET decided_rev = rev - 1 WHERE decided_at != ''")
SAME_EVENT_SECONDS = 120   # two copies of one notice differ only by delivery, never by minutes

# The more RESTRICTIVE class wins, never the other way: a cancel-intent ticket that mentions deletion sends the row
# to Jan even when the register already called it an erasure (legal_threat stays on top). ONE tuple, because three
# places now have to agree on it - `upsert` (a re-ingest that escalates), `_match` (an escalation is a new request,
# not a replay) and `_fold` (a duplicate must not lose the stricter class). It was duplicated in two of them, which
# is how the fold came to drop it entirely (QA on #1735).
CLASS_RANK = ("not_erasure", "privacy_access", "privacy_erasure", "dmca_takedown",
              "cancel_intent_mentions_deletion", "legal_threat")

# ONE ROW OWES ONE STATUTORY OBLIGATION, and a thread can owe two (QA #1847 Critical). An Art. 15 access request
# and an Art. 17 erasure demand in the same conversation are two duties with two clocks: the access answer has its
# own deadline, the hide has a 24 h one. Keyed on the thread alone they merged, and whichever arrived first kept its
# receipt and its due date while the other obligation lost its own tracked answer entirely - in the deletion-after-
# access direction the erasure row also silently inherited the ACCESS receipt time. The obligation is DERIVED FROM
# THE CLASS, deliberately: no new column, no register migration, and existing rows are carried forward by the same
# rule that files new ones. `upsert` and `_match` both consult this one map so they cannot disagree.
OBLIGATION_OF_CLASS = {
    "privacy_erasure": "erasure",
    "privacy_access": "access",
}


def obligation_of(cls: str) -> str:
    """The duty a row of this class discharges, or "" when the class carries none we track separately."""
    return OBLIGATION_OF_CLASS.get(cls, "")


MAIL_CHANNELS = ("notices", "legal", "support")

# The prefix `scripts/intercom-ops-write.sh`'s `refuse()` writes to stderr before it exits 1. Every one of its call
# sites is an argument/allowlist/leak check that runs BEFORE the curl POST, so a `REFUSED:` exit is provably
# pre-send: nothing was posted and a retry is safe. `send.py` keys the retryable/ambiguous split on this string.
REFUSED_PREFIX = "REFUSED:"

# The writer has TWO pre-send failures, and both are provable: `refuse()` prints `REFUSED: <why>` and exits 1, `die()`
# prints `ERROR: <why>` and exits 2. Both are the usage/environment class and neither survives the POST — measured, not
# assumed: no `refuse()` or `die()` call exists after the curl POST (`scripts/intercom-ops-write.sh:467`). This tuple is
# the single answer to "was anything posted?", and `send.WRITER_PREFLIGHT_RC` must agree with it; a test pins the pair.
PRE_SEND_PREFIXES = (REFUSED_PREFIX, "ERROR:")


def is_writer_refusal(detail: str) -> bool:
    """True when a ledger `detail` records a writer that refused or errored BEFORE it posted anything.

    `send.deliver` wraps the writer's stderr as `<writer> exited rc N after being invoked: <stderr>`, so the refusal
    is the segment after the LAST `after being invoked: ` -- the writer's own first word, not a `REFUSED:` that
    happens to appear somewhere in the text. A detail with no wrapper is read whole, which is what a bare
    `REFUSED: ...` from a future writer would look like.
    """
    said = (detail or "").rsplit("after being invoked: ", 1)[-1].strip()
    return said.startswith(PRE_SEND_PREFIXES)


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s: str) -> datetime:
    return datetime.strptime(s[:19].replace(" ", "T"), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def due_from(received_at: str) -> tuple[str, str]:
    r = parse_iso(received_at)
    return iso(r + timedelta(days=DUE_DAYS)), iso(r + timedelta(hours=HIDE_DUE_HOURS))


class Store:
    def __init__(self, path: str = DEFAULT_PATH):
        if path != ":memory:":
            os.makedirs(os.path.dirname(path) or ".", mode=0o700, exist_ok=True)
            old = os.umask(0o077)
        self.db = sqlite3.connect(path)
        if path != ":memory:":
            os.umask(old)
        self.path = path
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        migrate(self.db)
        self.db.commit()

    # ---- reads
    def _row(self, r: sqlite3.Row | None) -> dict | None:
        if r is None:
            return None
        d = dict(r)
        for c in JSON_COLS:
            d[c] = json.loads(d.get(c) or ("{}" if c == "hide_pr" else "[]"))
        d["keys"] = [k for (k,) in self.db.execute("SELECT key FROM erasure_keys WHERE request_id=? ORDER BY key",
                                                     (d["id"],))]
        return d

    def get(self, rid: int) -> dict | None:
        return self._row(self.db.execute("SELECT * FROM erasure_requests WHERE id=?", (rid,)).fetchone())

    def by_key(self, key: str) -> dict | None:
        r = self.db.execute("SELECT request_id FROM erasure_keys WHERE key=?", (key,)).fetchone()
        return self.get(r[0]) if r else None

    def by_key_prefix(self, prefix: str, cls: str = "") -> dict | None:
        """The row whose key is `prefix` or `prefix:<suffix>`, preferring one still being worked.

        A thread that comes back after its request was answered gets a `:again:<ts>` key, so the
        new request is a NEW row (the key is the idempotence test). A caller asking "does the
        register already hold this thread?" must see that row too, or it files a duplicate for a
        thread the register is already working.

        OPEN ROWS FIRST, and that ordering is load-bearing. A thread can hold a CLOSED row (the
        customer was answered) and an OPEN one (they wrote again). Returning the newest row
        regardless would hand a caller the closed one and let it conclude the thread is handled,
        silently dropping the live request. `upsert` already treats an answered row as the start
        of a new request; this lookup has to agree with it.

        `substr` rather than `LIKE` on purpose: a key contains `_` and `%`-free text today, but a
        LIKE pattern would silently start matching wildcards the moment one does not.
        """
        # `cls` narrows to the rows of ONE class. A thread can now hold two obligations, so "does the register
        # already hold this?" has to say WHICH - otherwise a caller verifying that a DELETION landed is handed the
        # open ACCESS row for the same thread, concludes nothing was filed, and pages a human for a request that is
        # recorded (QA #1847). Ordering still applies within the class.
        cls_filter = " AND r.class=?" if cls else ""
        args = (prefix, len(prefix) + 1, prefix + ":") + ((cls,) if cls else ())
        r = self.db.execute(
            "SELECT k.request_id FROM erasure_keys k JOIN erasure_requests r ON r.id = k.request_id "
            "WHERE (k.key=? OR substr(k.key, 1, ?)=?)" + cls_filter +
            " ORDER BY (r.status='open' AND r.confirmed_at IS NULL) DESC, k.request_id DESC LIMIT 1",
            args).fetchone()
        return self.get(r[0]) if r else None

    def all(self, status: str | None = None) -> list[dict]:
        q, a = "SELECT * FROM erasure_requests", ()
        if status:
            q, a = q + " WHERE status=?", (status,)
        return [self._row(r) for r in self.db.execute(q + " ORDER BY due_at, id", a)]

    def events(self, rid: int) -> list[dict]:
        return [dict(r) for r in self.db.execute("SELECT * FROM erasure_events WHERE request_id=? ORDER BY id", (rid,))]

    # ---- writes
    def event(self, rid: int, kind: str, **detail) -> None:
        self.db.execute("INSERT INTO erasure_events(request_id, at, kind, detail) VALUES (?,?,?,?)",
                        (rid, now_iso(), kind, json.dumps(detail, sort_keys=True, default=str)))

    def _next_register_no(self) -> int:
        (m,) = self.db.execute("SELECT MAX(register_no) FROM erasure_requests").fetchone()
        return max(FIRST_NEW_REGISTER_NO, (m or 0) + 1)

    @staticmethod
    def _prefixes(pages) -> set[str]:
        """The ids a MERGE compares on. The mail ledger keeps 8-char prefixes and Intercom keeps full uuids, so the
        same page arrives spelled two ways: compared verbatim, a notice and the conversation about it never intersect
        and one customer event became two rows (found live 2026-11-04: register #376 notices@ `fc31a861` and #377
        Intercom `fc31a861-0297-...`, nine seconds apart, one person, one page)."""
        return {(p.get("id") or "")[:8].lower() for p in pages if p.get("id")}

    def _match(self, keys: list[str], email: str, page_ids: set[str], received_at: str = "",
               channel: str = "", obligation: str = "") -> dict | None:
        def owns(row: dict | None) -> dict | None:
            """A row only answers a candidate that owes the SAME obligation (QA #1847).

            Without this an erasure demand matched the open access row for the thread, was merged into it by
            `upsert`'s class escalation, and the access obligation's own receipt and deadline disappeared while the
            erasure inherited them. A cross-obligation candidate must start its own row, so its own clock exists.
            """
            if not row:
                return None
            have = obligation_of(row.get("class") or "")
            # UNKNOWN ON EITHER SIDE KEEPS TODAY'S ROUTING. `legal_threat` and `dmca_takedown` carry no separate
            # obligation of their own, and a candidate whose class we do not map must not be pushed into a second
            # row just because we cannot classify it - that would double-file the population we already handle.
            if not have or not obligation:
                return row
            return row if have == obligation else None

        for k in keys:
            # The obligation-suffixed key first: that is the deterministic key `upsert` mints for the SECOND
            # obligation on a thread, and it is what makes a replay idempotent instead of opening a third row.
            if obligation:
                hit = owns(self.by_key(f"{k}:{obligation}"))
                if hit:
                    return hit
            hit = owns(self.by_key(k))
            if hit:
                return hit
        want = {(i or "")[:8].lower() for i in page_ids if i}
        if email and want and received_at:
            t = parse_iso(received_at)
            for r in self.all("open"):
                if r["confirmed_at"]:
                    continue      # a later look-alike after a written confirmation is a NEW request, not a merge
                if obligation_of(r["class"] or "") != obligation:
                    continue      # another obligation's clock is not this one's
                if (r["requester_email"] or "").lower() != email.lower() or not (want & self._prefixes(r["pages"])):
                    continue
                # A shared page and a shared sender prove the same PERSON, not the same EVENT, so the receipt time
                # has to agree too - in BOTH directions. Without any bound this merged a request made five hours after
                # the first into the first row (QA on #1735: notices@ `fc31a861` at 01:39 and a fresh Intercom request
                # for the full uuid at 06:39 came back (1,'created') then (1,'merged')). A one-sided bound then left
                # the mirror case open: an EARLIER-dated distinct request was still swallowed, because a negative
                # difference always satisfies `<=`. Processing order is not evidence of event identity, and moving the
                # due date earlier does not preserve the second request's own reply target or watchdog.
                #
                # So the bound is symmetric, and it is the SAME window the repair scanner uses
                # (`_cross_channel_duplicates`): two deliveries of one notice differ by delivery, never by hours. The
                # live case this branch exists for was NINE SECONDS apart. A row with no received_at proves nothing,
                # so it does not match - a visible duplicate is recoverable (the scanner reports it, `merge_duplicate`
                # folds it and moves the earlier receipt forward), a silently swallowed request is not.
                if not r["received_at"]:
                    continue
                if abs((t - parse_iso(r["received_at"])).total_seconds()) <= SAME_EVENT_SECONDS:
                    return r
        # With no sender on the ledger row the only thing that can prove ONE request is a shared EVENT, never a
        # shared page set: the same notice delivered to two different mailboxes (notices@ and legal@, notices@ is
        # auto-forwarded) carries ONE Date header, so the page set AND the message time AND the other alias must all
        # agree. A 3-day window on the page set alone merged two DISTINCT support@ threads about one profile into a
        # single row, and the second request silently lost its own deadline, watchdog and reply target (QA a3e68886a;
        # reproduced with thread-a/thread-b). Two threads are two requests until something proves they are one.
        if not email and page_ids and channel in MAIL_CHANNELS and received_at:
            t = parse_iso(received_at)
            for r in self.all("open"):
                if r["confirmed_at"] or r["channel"] == channel:
                    continue
                if obligation_of(r["class"] or "") != obligation:
                    continue      # another obligation's clock is not this one's
                if r["channel"] in MAIL_CHANNELS and self._prefixes(r["pages"]) == want \
                        and abs((parse_iso(r["received_at"]) - t).total_seconds()) <= SAME_EVENT_SECONDS:
                    return r
        return None

    def upsert(self, cand: dict) -> tuple[int, str]:
        """Add or merge one intake candidate. Returns (request id, 'created' | 'merged' | 'unchanged').

        cand: keys (list, first = row key), channel, class, received_at, requester_name/email, contact_id,
        conversation_id, gmail_thread, clickup_ids, pages, register_no (only for markdown-register rows), note."""
        keys = [k for k in cand["keys"] if k]
        pages = _dedupe_pages(cand.get("pages") or [])
        email = (cand.get("requester_email") or "").strip()
        obligation = obligation_of(cand["class"])
        hit = self._match(keys, email, {p["id"] for p in pages}, cand.get("received_at", ""),
                          cand.get("channel", ""), obligation)
        # ANOTHER OBLIGATION HOLDS THIS THREAD'S KEY: mint a deterministic suffixed key so this duty gets its own
        # row, its own receipt and its own deadline while the other row keeps the plain key it already has. Only
        # when nothing of OUR obligation matched - otherwise a plain replay of the first push would look like a new
        # set of keys and report "merged" forever instead of "unchanged".
        def _taken_by_another(k: str) -> bool:
            held = self.by_key(k)
            if held is None:
                return False
            have = obligation_of(held.get("class") or "")
            return bool(have) and have != obligation

        if hit is None and obligation:
            alt = [f"{k}:{obligation}" if _taken_by_another(k) else k for k in keys]
            if alt != keys:
                keys = alt
                hit = self._match(keys, email, {p["id"] for p in pages}, cand.get("received_at", ""),
                                  cand.get("channel", ""), obligation)
        # A key another obligation already holds is not a key THIS row can claim, or a replay reports `merged`
        # forever: the plain thread key stays with the first duty while this one lives on its suffixed key.
        if hit is not None and obligation:
            keys = [k for k in keys if not _taken_by_another(k)] or [hit["row_key"]]
        ts = now_iso()
        if hit is not None and (hit["confirmed_at"] or hit["status"] != "open"):
            # ANSWERED = a written confirmation OR closed for any other reason (a markdown-register row a human closed).
            # Either way every pass filters to open rows, so merging a later page into it registers a request nothing
            # watches for: the message is a NEW request, dated by its own arrival.
            # Replaying the SAME unchanged source is not a new request: only something new (a page, a later request
            # time, a more restrictive class) starts one. Without this an unchanged ticket re-ingested by the next
            # tick would open a fresh request for a customer who has already been answered.
            fresh = {p["id"] for p in pages} - {p["id"] for p in hit["pages"]}
            escalates = (cand["class"] in CLASS_RANK and hit["class"] in CLASS_RANK
                         and CLASS_RANK.index(cand["class"]) > CLASS_RANK.index(hit["class"]))
            if not fresh and not escalates and cand["received_at"] <= hit["received_at"]:
                return hit["id"], "unchanged"
            # A WRITTEN CONFIRMATION closes that request: its 30-day watchdog SKIPS it, so merging a later page into
            # it would hide a page nobody is watching for. Every tick re-ingests the open ClickUp ticket and the
            # Intercom conversation with the row's own keys, so this path is the normal one for "the customer wrote
            # again after we confirmed". It becomes a NEW request, keyed deterministically on the reply's own time so
            # re-ingesting the same message stays idempotent.
            # Keyed on the CONFIRMED row's own canonical key, not on whichever key the caller happened to pass
            # first: the ticket replay and the conversation replay see the same customer event, and two different
            # first-keys would mint two rows for it (identical dates, two watchdogs, two confirmations).
            again = f"{hit['row_key']}:again:{cand['received_at']}"
            reuse = self.by_key(again)
            if reuse is None:
                # The SAME customer event also arrives through two different PARENTS (a markdown-register row and the
                # mail thread that row was reconciled from; a ClickUp ticket and the conversation it points at).
                # Their row keys differ, so `<parent>:again:<at>` differs too, and one reply would open two requests
                # with two deadlines and two confirmations. One event on one SOURCE is one request, whichever parent
                # saw it first: reuse the row this event already opened on the same conversation or mail thread.
                stamp = f":again:{cand['received_at']}"
                src = [(k, cand.get(k)) for k in ("conversation_id", "gmail_thread")]
                for r in self.all():
                    if r["row_key"].endswith(stamp) and any(v and r[k] == v for k, v in src):
                        reuse = r
                        break
            hit = reuse
            keys = [hit["row_key"]] if hit is not None else [again]
            # the original keys stay with the CLOSED row, never re-pointed at the new one
            cand = {**cand, "keys": keys,
                    "note": cand.get("note") or (
                        "customer wrote again after the written confirmation" if hit and hit["confirmed_at"]
                        else "customer wrote again after that request was closed")}
        if hit is None:
            due, hide_due = due_from(cand["received_at"])
            reg = cand.get("register_no") or self._next_register_no()
            cur = self.db.execute(
                "INSERT INTO erasure_requests(register_no,row_key,channel,class,received_at,due_at,hide_due_at,"
                "requester_name,requester_email,contact_id,conversation_id,gmail_thread,clickup_ids,pages,note,"
                "status,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (reg, keys[0], cand["channel"], cand["class"], cand["received_at"], due, hide_due,
                 cand.get("requester_name") or "", email, cand.get("contact_id") or "",
                 cand.get("conversation_id") or "", cand.get("gmail_thread") or "",
                 json.dumps(sorted(set(cand.get("clickup_ids") or []))), json.dumps(pages),
                 cand.get("note") or "", cand.get("status") or "open", ts, ts))
            rid = cur.lastrowid
            for k in keys:
                self.db.execute("INSERT OR IGNORE INTO erasure_keys(key, request_id) VALUES (?,?)", (k, rid))
            self.event(rid, "created", keys=keys, channel=cand["channel"], received_at=cand["received_at"])
            self.db.commit()
            return rid, "created"
        rid = hit["id"]
        changed = {}
        new_keys = [k for k in keys if k not in hit["keys"]]
        for k in new_keys:
            self.db.execute("INSERT OR IGNORE INTO erasure_keys(key, request_id) VALUES (?,?)", (k, rid))
        merged_pages = _dedupe_pages(hit["pages"] + pages)
        if merged_pages != hit["pages"]:
            changed["pages"] = json.dumps(merged_pages)
        cu = sorted(set(hit["clickup_ids"]) | set(cand.get("clickup_ids") or []))
        if cu != hit["clickup_ids"]:
            changed["clickup_ids"] = json.dumps(cu)
        if cand["received_at"] < hit["received_at"]:
            due, hide_due = due_from(cand["received_at"])
            changed.update(received_at=cand["received_at"], due_at=due, hide_due_at=hide_due)
        for col in ("requester_name", "requester_email", "contact_id", "conversation_id", "gmail_thread"):
            if cand.get(col) and not hit.get(col):
                changed[col] = cand[col]
        if (cand["class"] in CLASS_RANK and hit["class"] in CLASS_RANK
                and CLASS_RANK.index(cand["class"]) > CLASS_RANK.index(hit["class"])):
            changed["class"] = cand["class"]
        if not changed and not new_keys:
            return rid, "unchanged"
        if changed:
            changed["updated_at"] = ts
            # `rev` is the content revision, not a timestamp: two edits inside the same second must still be seen as
            # "this row changed after it was decided" (a page added at 20:00:00 to a row decided at 20:00:00 was
            # invisible to the `updated_at > decided_at` test and kept its stale verdict for 20 h).
            changed["rev"] = hit["rev"] + 1
            self.db.execute(f"UPDATE erasure_requests SET {', '.join(c + '=?' for c in changed)} WHERE id=?",
                            (*changed.values(), rid))
        self.event(rid, "merged", keys=new_keys, fields=sorted(changed))
        self.db.commit()
        return rid, "merged"

    def update(self, rid: int, kind: str, commit: bool = True, **cols) -> None:
        """Set columns on a row and audit it under `kind` (decide / ask / hide_pr / hidden / confirmed / closed).

        Every write bumps `rev`. A decision then records the revision it read (`mark_decided`), which is how the tick
        asks "has this row changed since we decided it?" without trusting second-precision wall clocks."""
        for c in JSON_COLS:
            if c in cols and not isinstance(cols[c], str):
                cols[c] = json.dumps(cols[c], sort_keys=True)
        cols["updated_at"] = now_iso()
        self.db.execute(f"UPDATE erasure_requests SET rev=rev+1, {', '.join(c + '=?' for c in cols)} WHERE id=?",
                        (*cols.values(), rid))
        self.event(rid, kind, **{k: v for k, v in cols.items() if k != "updated_at"})
        if commit:
            self.db.commit()

    def mark_decided(self, rid: int) -> None:
        """Pin `decided_rev` to the row's CURRENT revision: the verdict now describes exactly this content."""
        self.db.execute("UPDATE erasure_requests SET decided_rev = rev WHERE id=?", (rid,))
        self.db.commit()


    # ---- the send ledger (`erasure_sends`)
    def send_record(self, rid: int, kind: str) -> dict | None:
        """The ledger row for this request+kind, or None. Written BEFORE the writer runs, so `sending` means a
        letter may be out there and a human has to look."""
        r = self.db.execute("SELECT * FROM erasure_sends WHERE request_id=? AND kind=?", (rid, kind)).fetchone()
        return self._row(r)

    def begin_send(self, rid: int, kind: str, channel: str, target: str, body_sha: str, approved_by: str,
                   state: str = "sending", detail: str = "", idem: str = "") -> None:
        """Claim the one send slot for this request+kind. Raises sqlite3.IntegrityError if it is already claimed:
        that is the double-send guard, not an error to swallow."""
        self.db.execute("INSERT INTO erasure_sends(request_id, kind, channel, target, body_sha, approved_by, state,"
                        " detail, idem, at, attempt) VALUES (?,?,?,?,?,?,?,?,?,?,1)",
                        (rid, kind, channel, target, body_sha, approved_by, state, detail[:500], idem, now_iso()))
        self.db.commit()

    def claim_send(self, rid: int, kind: str, channel: str, target: str, body_sha: str, approved_by: str,
                   state: str = "sending", detail: str = "", idem: str = "") -> None:
        """Claim the slot, or REUSE it when the previous attempt never reached the customer (`failed` / `refused`).

        The distinction is the whole point: `sent` and `sending` are never overwritten (a letter may be out there),
        while a `refused` route -- a mailbox not authed yet, a non-numeric conversation id -- must be retryable once
        a human fixes it. Overwriting is done as one UPDATE so two runs cannot both insert."""
        prior = self.send_record(rid, kind)
        if prior is None:
            self.begin_send(rid, kind, channel, target, body_sha, approved_by, state, detail, idem)
            return
        if prior["state"] not in ("failed", "refused"):
            raise sqlite3.IntegrityError(f"a {kind} for row {rid} is already {prior['state']} ({prior['at']})")
        # `consumed_at` is cleared with the rest of the slot: a `failed`/`refused` attempt never reached the
        # customer, so the writer's single-use marker must not survive into the retry and refuse it.
        self.db.execute("UPDATE erasure_sends SET channel=?, target=?, body_sha=?, approved_by=?, state=?, ref='', "
                        "detail=?, idem=?, consumed_at='', at=?, attempt=COALESCE(attempt,0)+1 "
                        "WHERE request_id=? AND kind=?",
                        (channel, target, body_sha, approved_by, state, detail[:500], idem, now_iso(), rid, kind))
        self.db.commit()

    def finish_send(self, rid: int, kind: str, state: str, ref: str = "", detail: str = "") -> None:
        self.db.execute("UPDATE erasure_sends SET state=?, ref=?, detail=? WHERE request_id=? AND kind=?",
                        (state, ref[:500], detail[:500], rid, kind))
        self.db.commit()

    # The states a person may resolve. `sent` is not a question and `failed`/`refused` are already retryable, so
    # only the two "a letter may be out there" states are resolvable -- and only with a reason on the record.
    RESOLVABLE_SEND_STATES = ("unknown", "sending")

    # A `sending` row means a writer was STARTED and has not reported. Unlike `unknown` (a writer ran and the outcome
    # is lost) there is no evidence yet that it stopped, so resolving one to `failed` makes the slot retryable while
    # the original POST may still be in flight -- a second statutory letter to the same person (QA #1848 r6).
    #
    # The quiescence proof comes from the writer's own hard bound: `scripts/intercom-ops-write.sh` runs its curl under
    # `timeout 45`, so no writer it starts can outlive that by more than its own process start-up. This window is set
    # 20x above it so a slow host or a queued tick cannot be mistaken for a dead one. It is evidence, not a guess: past
    # it, any writer this claim started has exited, and the row is an orphan a person may resolve.
    SENDING_QUIESCENT_S = 900

    def stamp_sent(self, rid: int, kind: str, slot: str, ref: str, commit: bool = True) -> None:
        """Write the row-level send stamp that goes WITH a `sent` ledger row.

        `send.deliver` writes these next to the ledger record and the rest of the pipeline reads them: `confirmed_at`
        is what takes a row out of the confirmation queue, `ask_sent_at` is what arms the chase, and
        `interim_confirm_at` records the interim letter without consuming the final slot. A `sent` ledger row with no
        stamp is a letter the register believes it never sent -- so a manual resolution to `sent` must write the same
        stamp, or the row stays in the queue and a later customer message is folded into an already-answered request.

        `commit=False` lets a caller keep the stamp in the same transaction as the ledger row it belongs to.
        """
        stamp = now_iso()
        if kind == "ask":
            self.update(rid, "ask", commit=commit, ask_sent_at=stamp, ask_ref=ref)
        elif slot == "confirm":
            self.update(rid, "confirmed", commit=commit, confirmed_at=stamp, confirm_ref=ref)
        else:
            self.update(rid, "confirmed", commit=commit, interim_confirm_at=stamp, interim_confirm_ref=ref)

    def resolve_send(self, rid: int, kind: str, state: str, why: str, by: str, evidence: str = "",
                     ref: str = "", expect: tuple[str, str, int] | None = None) -> dict:
        """Resolve a send the sender could not finish, APPENDING the decision to the event ledger.

        The ledger row's state moves -- that is what unsticks the queue -- but the RECORD of why is an append: an
        `erasure_events` row carries the previous state, the new one, the evidence it was decided on and who decided
        it. A later reader can therefore tell a person's resolution from the sender's own transition, and the
        original `detail` (the writer's own words) is never overwritten by the resolution.

        `expect` is the ATTEMPT the decision was made on -- `(state, detail, attempt)` as the caller selected it. A
        caller that picked the row earlier (a batch, a dry run the operator read) must pass it, because re-reading
        here is not the same thing: between selection and this call the sender can reclaim the slot (`failed` ->
        `sending`, detail cleared), and a fresh read would then judge the NEW attempt while the decision was made on
        the OLD evidence. The write is bound to `expect`, so that case is a detectable no-op instead of a silent
        overwrite that lets the next tick send a duplicate statutory letter.

        `attempt` is the per-slot generation, not decoration. `claim_send` bumps it on every claim and `finish_send`
        leaves it alone. State and detail alone are NOT an identity: a retry that fails the same way returns the row
        to `unknown` with the same detail, so a stale selection would match again (an ABA cycle) and mark the newer
        attempt resolved. If that second POST actually delivered, the next retry sends a duplicate statutory letter.
        `at` cannot serve either -- it is a second-resolution timestamp, so two claims in one second collide.

        Refuses a `sent` row (a letter that went out is not a question) and a `failed`/`refused` one (already
        retryable, nothing to resolve). Raises `SendNotResolvable` rather than returning a flag: a caller that
        ignores the answer must not be able to write.
        """
        why = (why or "").strip()
        by = (by or "").strip()
        if not why:
            raise SendNotResolvable("a resolution needs a reason: pass --why with the evidence it was decided on")
        if not by:
            raise SendNotResolvable("a resolution needs a person: pass --by (or set GDPR_RESOLVER)")
        if state not in ("sent", "failed"):
            raise SendNotResolvable(f"{state!r} is not a resolution state (sent | failed)")
        prior = self.send_record(rid, kind)
        if prior is None:
            raise SendNotResolvable(f"row {rid} has no {kind} letter on record")
        # The attempt this decision is about. Everything below -- the resolvable check, the refusal guard and the
        # write itself -- is judged against THIS, never against a fresh read that may already be a different attempt.
        want_state, want_detail, want_attempt = (expect if expect is not None
                                                 else (prior["state"], prior.get("detail") or "",
                                                       int(prior.get("attempt") or 0)))
        if want_state not in self.RESOLVABLE_SEND_STATES:
            raise SendNotResolvable(f"the {kind} for row {rid} is {want_state}, not a state a person resolves")
        if want_state == "sending":
            # A `sending` row has no recorded outcome AND no evidence the writer stopped. Resolving it now makes the
            # slot retryable while the original POST may still be running, and the customer gets two letters. Require
            # the claim to be past the writer's own bound before it can be treated as an orphan.
            try:
                claimed = parse_iso(prior.get("at") or "")
            except (TypeError, ValueError):
                claimed = None
            age = (datetime.now(timezone.utc) - claimed).total_seconds() if claimed else None
            if age is None or age < self.SENDING_QUIESCENT_S:
                raise SendNotResolvable(
                    f"the {kind} for row {rid} is `sending` (claimed {prior.get('at')}), so a writer may still be "
                    f"running: the writer is bounded at 45s and a row is only treated as orphaned after "
                    f"{self.SENDING_QUIESCENT_S}s. Wait for it to report, or for the window to pass, then resolve.")
        if state == "sent" and is_writer_refusal(want_detail):
            # A writer REFUSAL is provably pre-send: `refuse()` in intercom-ops-write.sh exits before the curl POST.
            # Recording one as `sent` would claim a statutory letter was delivered when nothing left the host, stamp
            # the row as answered, and suppress the retry that would actually send it. The honest resolution is
            # `failed`, which makes the slot retryable again.
            raise SendNotResolvable(
                f"the {kind} for row {rid} was REFUSED by the writer before it posted anything, so it cannot be "
                f"resolved to `sent`: nothing was delivered. Resolve it to `failed` and let the sender retry.")
        # One transaction: the state, the row-level stamp and the audit event land together or not at all. A `sent`
        # row whose `send-resolved` event failed to write would be a delivered letter with no person or reason on
        # record -- exactly the unaudited write this subcommand exists to prevent.
        try:
            # Compare-and-swap on the attempt we READ, not a blind write. Between `send_record` above and this
            # statement the sender can reclaim the slot (`failed` -> `sending`) and start a retry; a blind UPDATE
            # would then overwrite that NEWER attempt with a resolution decided on the OLD evidence, and the next
            # tick could send again while the first retry is still in flight -- two statutory letters to one person.
            # `attempt` is what makes this hold across a FULL retry cycle: state and detail can return to the same
            # values (unknown + the same writer error), but `claim_send` bumps the generation on every claim, so a
            # stale selection can never match a later attempt.
            cur = self.db.execute(
                "UPDATE erasure_sends SET state=? WHERE request_id=? AND kind=? AND state=? "
                "AND COALESCE(detail,'')=? AND COALESCE(attempt,0)=?",
                (state, rid, kind, want_state, want_detail, want_attempt))
            if cur.rowcount != 1:
                raise SendNotResolvable(
                    f"the {kind} for row {rid} changed while it was being resolved (it is no longer attempt "
                    f"{want_attempt} in state {want_state} with the evidence this decision was made on). "
                    f"Re-read it and decide again.")
            if state == "sent":
                # A `sent` ledger row without its row-level stamp is a letter the register believes it never sent:
                # the row stays in the confirmation queue and a later customer message is folded into an answered
                # request.
                self.stamp_sent(rid, kind, kind, ref or f"resolved by {by}", commit=False)
            self.db.execute("INSERT INTO erasure_events(request_id, at, kind, detail) VALUES (?,?,?,?)",
                            (rid, now_iso(), "send-resolved",
                             json.dumps({"slot": kind, "from": want_state, "to": state, "why": why[:500],
                                         "by": by[:120], "attempt": want_attempt,
                                         "evidence": (evidence or want_detail or "")[:500]},
                                        sort_keys=True)))
            self.db.commit()
        except Exception:
            # The state, the stamp and the audit event land together or not at all. A `sent` row whose
            # `send-resolved` event failed to write would be a delivered letter with no person or reason on record
            # -- exactly the unaudited write this subcommand exists to prevent.
            self.db.rollback()
            raise
        return {"request_id": rid, "kind": kind, "from": prior["state"], "to": state}

    def resolvable_sends(self, kind: str = "", refused_only: bool = False) -> list[dict]:
        """The send rows a person could resolve, oldest first. `refused_only` narrows to the rows whose evidence is
        a writer REFUSAL -- provably pre-send, so one shared reason covers the whole batch."""
        sql = ("SELECT * FROM erasure_sends WHERE state IN ('unknown','sending')"
               + (" AND kind=?" if kind else "") + " ORDER BY at, id")
        rows = [self._row(r) for r in self.db.execute(sql, (kind,) if kind else ())]
        if refused_only:
            rows = [r for r in rows if is_writer_refusal(r.get("detail"))]
        return rows
    def unknown_sends(self) -> list[dict]:
        """Every ledger row in the AMBIGUOUS state, oldest first, with the request it belongs to.

        `unknown` is the state that says "a letter may be out there, a human resolves this, the pipeline will never
        retry". It is the right answer for a timeout or a dropped connection and the wrong one for a pre-flight
        refusal, so the rows have to be readable in bulk to tell the two apart."""
        return [self._row(r) for r in self.db.execute(
            "SELECT * FROM erasure_sends WHERE state='unknown' ORDER BY at, id")]

    def reclassify_send(self, rid: int, kind: str, state: str, detail: str) -> None:
        """Move a ledger row out of `unknown` when its recorded detail PROVES nothing was posted.

        The `state='unknown'` predicate is part of the UPDATE, not a read-then-write: a row that changed under us
        (a human resolved it, a retry claimed it) is left alone rather than overwritten. The original detail is
        carried into the new one, so the ledger still says what the writer actually answered."""
        self.db.execute("UPDATE erasure_sends SET state=?, detail=? "
                        "WHERE request_id=? AND kind=? AND state='unknown'",
                        (state, detail[:500], rid, kind))
        self.db.commit()

    def unsent_letters(self, kind: str = "confirm") -> list[int]:
        """Row ids whose letter has NOT gone out (no ledger row, or a failed/refused one -- a `sending` or `unknown`
        row is not a sent letter either, and an `unknown` one is a human's to resolve)."""
        done = {r[0] for r in self.db.execute(
            "SELECT request_id FROM erasure_sends WHERE kind=? AND state='sent'", (kind,))}
        return [r["id"] for r in self.all("open") if r["id"] not in done]

    def duplicate_events(self) -> list[tuple[dict, dict]]:
        """[(keep, drop)] for post-confirmation rows that are the SAME customer event opened twice.

        Every post-confirmation request is keyed `<parent row key>:again:<message time>`, and the message time is the
        event's identity. Two rows sharing a source (`conversation_id` / `gmail_thread`) and that stamp are one event:
        a tick that predated the canonical-key + source-reuse rule minted both spellings of the same key
        (`register:19:again:<at>` and `gmail:legal@…:again:<at>`), which is two deadlines, two watchdogs and two
        confirmation letters for one customer message. Reported, never repaired silently: the caller decides."""
        by_stamp: dict[tuple[str, str, str], list[dict]] = {}
        for r in self.all():
            if ":again:" not in r["row_key"]:
                continue
            stamp = ":again:" + r["row_key"].split(":again:", 1)[1]
            src = ("conversation_id", r["conversation_id"]) if r["conversation_id"] else (
                "gmail_thread", r["gmail_thread"])
            if not src[1]:
                continue
            by_stamp.setdefault((src[0], src[1], stamp), []).append(r)
        out = []
        for group in by_stamp.values():
            group.sort(key=lambda r: r["id"])
            for keep, drop in zip(group, group[1:]):
                if keep["status"] == "open" and drop["status"] == "open" and \
                        keep["received_at"] == drop["received_at"] and \
                        [q["id"] for q in keep["pages"]] == [q["id"] for q in drop["pages"]]:
                    out.append((keep, drop))
        # Request IDS, not `id()` of the dicts: `_cross_channel_duplicates` calls `self.all()` again and gets FRESH
        # dicts, so an object-identity exclusion never matched and one row could appear in two pairs - applying both
        # left a key pointing at a row the first fold had just closed (QA on #1735).
        out += self._cross_channel_duplicates({k["id"] for kd in out for k in kd})
        return sorted(out, key=lambda kd: kd[1]["id"])

    # ONE bound for both paths (QA on #1735). The repair scanner used to allow 300 s while `_match` allowed 120, so a
    # notice at 01:00 and the Intercom conversation about it at 01:04 were kept as TWO requests by intake and then
    # folded into one by `dedupe --apply` - the fold silently took away the second request's own reply target and
    # watchdog. A repair may only undo what intake would have merged, never more, so it reads the same constant.
    CROSS_CHANNEL_SECONDS = SAME_EVENT_SECONDS

    def _cross_channel_duplicates(self, taken: set[int]) -> list[tuple[dict, dict]]:
        """`taken` holds REQUEST IDS already paired by the caller, never `id()` of a dict."""
        """[(keep, drop)] for ONE customer event that arrived on two CHANNELS: a notice to notices@/legal@ (8-char
        ids) and the Intercom conversation about the same pages (full uuids), seconds apart, with no shared key. Same
        verified sender, same page, same moment = one request; a second row means two deadlines, two watchdogs and
        two letters to one customer. Keep the row that carries the full uuid (it is the one the catalog can decide)."""
        def full(row) -> int:
            return sum(1 for p in row["pages"] if len(p["id"]) > 8)

        rows = [r for r in self.all() if r["status"] == "open" and r["requester_email"]]
        out = []
        for i, a in enumerate(rows):
            for b in rows[i + 1:]:
                if a["id"] in taken or b["id"] in taken:
                    continue
                if (a["requester_email"] or "").lower() != (b["requester_email"] or "").lower():
                    continue
                # one has a conversation, the other a mail thread: two channels for one event, not two messages
                if bool(a["conversation_id"]) == bool(b["conversation_id"]):
                    continue
                # ANY shared page, not an identical page set: `_match` merges on `want & self._prefixes(r["pages"])`,
                # so a notice naming page A and the Intercom conversation about it naming A and B are ONE request to
                # intake. Requiring the sets to be equal left exactly those pre-fix rows open with two deadlines and
                # two letters (QA on #1735, reproduced: notices A, Intercom A+B nine seconds later - `_match` selects
                # the notices row while `duplicate_events()` returned []). A repair may only undo what intake would
                # have merged, so it reads the same overlap rule.
                prefixes = self._prefixes(a["pages"])
                if not prefixes or not (prefixes & self._prefixes(b["pages"])):
                    continue
                try:
                    gap = abs((parse_iso(a["received_at"]) - parse_iso(b["received_at"])).total_seconds())
                except (TypeError, ValueError):
                    continue
                if gap > self.CROSS_CHANNEL_SECONDS:
                    continue
                keep, drop = (a, b) if (full(a), -a["id"]) >= (full(b), -b["id"]) else (b, a)
                out.append((keep, drop))
                taken.add(a["id"]); taken.add(b["id"])
                break
        return out

    def merge_duplicate(self, keep: dict, drop: dict) -> None:
        """Point the duplicate's keys at the row we keep and close it, with the audit trail a person can follow.

        Two things must survive the fold, and both were found by QA on #1735 rather than by a test:

          - the SEND LEDGER. Closing the duplicate without moving its `erasure_sends` rows left the kept row with no
            record of a letter that had already gone out, so `unsent_letters()` returned it and another approved batch
            could send a SECOND statutory letter for one request. When both rows carry a record for the same slot and
            either may have reached the customer, folding them is a human's call, so this REFUSES instead of guessing;
          - the EARLIEST receipt. The kept row is chosen by key shape (a full uuid beats an 8-char prefix), not by
            time, so a duplicate that arrived first would otherwise hand the customer a LATER statutory deadline.
            `received_at` and the two dates derived from it move to the earlier of the two."""
        # ONE transaction for the whole fold. `_merge_sends` used to commit on its own and `update` committed again,
        # so a failure between them left the dropped row OPEN with its `ask:sent` record already moved onto the kept
        # row: `unsent_letters('ask')` then offered the open row for a SECOND statutory letter (QA on #1735,
        # reproduced by injecting a SQLite failure on closing the dropped row). A savepoint makes the fold all-or-
        # nothing, and the refusal path (`MergeRefused`) rolls back to it too, so a refused pair moves nothing.
        self.db.execute("SAVEPOINT fold")
        try:
            self._fold(keep, drop)
        except BaseException:
            self.db.execute("ROLLBACK TO fold")
            self.db.execute("RELEASE fold")
            raise
        self.db.execute("RELEASE fold")
        self.db.commit()

    def _fold(self, keep: dict, drop: dict) -> None:
        """The body of `merge_duplicate`, inside its savepoint. Never commits."""
        self._merge_sends(keep, drop, commit=False)
        earlier = _earlier_receipt(keep, drop)
        stamps = _merge_stamps(keep, drop)
        for k in drop["keys"]:
            # The duplicate's key must now resolve to the row we keep, so a later re-ingest of the same message lands
            # on it: this is the ONE case where re-pointing a key is right (normal merges never re-point, so the closed
            # row keeps its own history).
            self.db.execute("INSERT OR REPLACE INTO erasure_keys(key, request_id) VALUES (?,?)", (k, keep["id"]))
        pages = _dedupe_pages((keep.get("pages") or []) + (drop.get("pages") or []))
        cols = {}
        if pages != (keep.get("pages") or []):
            cols["pages"] = pages
        # The fold must not LOSE the stricter class (QA on #1735). The scanner keeps the row carrying the full uuid,
        # which is not necessarily the row carrying the more restrictive class: a notices@ `legal_threat` and the
        # Intercom `privacy_erasure` about it are one event, and folding the first into the second left the only open
        # row an erasure - so legal-threat handling (Jan, hide-first, the 24 h deadline) silently disappeared. Same
        # rule as `upsert`: the more restrictive class wins, never the other way.
        if (drop.get("class") in CLASS_RANK and keep.get("class") in CLASS_RANK
                and CLASS_RANK.index(drop["class"]) > CLASS_RANK.index(keep["class"])):
            cols["class"] = drop["class"]
        if earlier:
            cols.update(earlier)
        cols.update(stamps)
        if cols:
            self.update(keep["id"], "duplicate-merge", commit=False, **cols)
            keep = self.get(keep["id"])
        self.update(drop["id"], "duplicate", commit=False, status="duplicate",
                    note=(drop.get("note") or "") + f" | duplicate of request {keep['id']} (same customer event: "
                                                    f"same source, same message time) — reconciled, not a new request")

    def _merge_sends(self, keep: dict, drop: dict, commit: bool = True) -> None:
        """Move the duplicate's send ledger onto the kept row, or REFUSE when both rows carry a letter.

        `erasure_sends` is UNIQUE(request_id, kind) and that constraint is the double-send guard, so a fold has to
        answer for it explicitly. A record on the duplicate with no counterpart on the kept row is simply re-pointed
        (the letter went out for THIS request, and the surviving row must know). Two records for one slot is the case
        that must not be resolved by code: if either may have reached the customer, a person reconciles it."""
        rows = self.db.execute("SELECT * FROM erasure_sends WHERE request_id=?", (drop["id"],)).fetchall()
        live = ("sent", "sending", "unknown")
        # PREFLIGHT every slot before touching anything. The loop used to re-point `ask` and then raise on `confirm`,
        # so a refused fold left the dropped row OPEN with its ask slot gone: the next store update commits that
        # pending move and `unsent_letters('ask')` offers the dropped row for a second letter, while the CLI reports
        # the pair as untouched (QA 11-05). A refusal must move nothing.
        moves, collisions = [], []
        for rec in rows:
            prior = self.send_record(keep["id"], rec["kind"])
            if prior is None:
                moves.append(rec)
            elif rec["state"] in live or prior["state"] in live:
                collisions.append((rec, prior))
        if collisions:
            rec, prior = collisions[0]
            raise MergeRefused(
                f"rows {keep['id']} and {drop['id']} both carry a {rec['kind']} letter "
                f"({prior['state']} on {keep['id']}, {rec['state']} on {drop['id']}) and at least one may have "
                f"reached the customer. Folding them would leave the surviving row able to send a second "
                f"statutory letter, so a person reconciles this pair by hand")
        for rec in moves:
            self.db.execute("UPDATE erasure_sends SET request_id=? WHERE id=?", (keep["id"], rec["id"]))
        # Both retryable (failed/refused) records stay where they are: the kept row's record stands and the
        # duplicate's stays on the closed row as history. Nothing is deleted.
        if commit:
            self.db.commit()

class MergeRefused(Exception):
    """Two rows for one request each carry a letter that may have reached the customer. Not a code decision."""


class SendNotResolvable(Exception):
    """A send a person asked to resolve is not in a state a person may resolve, or the resolution carries no
    reason/person. Raised rather than returned so a caller cannot ignore it and write anyway."""


# The row-level stamps `send.deliver` writes NEXT TO the ledger record, with the ref that came with each.
STAMP_COLUMNS = (("ask_sent_at", "ask_ref"), ("confirmed_at", "confirm_ref"),
                 ("interim_confirm_at", "interim_confirm_ref"))


def _merge_stamps(keep: dict, drop: dict) -> dict:
    """The row-level send stamps to move onto the kept row: the EARLIEST of the two, per stamp.

    `send.deliver` writes these alongside the ledger row, so a fold that moved the ledger and not the stamp left the
    surviving row with a `sent` confirmation record and `confirmed_at == ''`: its confirmation watchdog stayed armed
    and a later message from that customer was folded into an already-answered request instead of opening a new one.
    The same gap suppressed `ask_sent_at` (the chase) and `interim_confirm_at` (the interim state). The stamp and its
    ref move together, and the earliest wins for the same reason the earliest receipt does."""
    out = {}
    for at, ref in STAMP_COLUMNS:
        a, b = str(keep.get(at) or ""), str(drop.get(at) or "")
        if not b or (a and a <= b):
            continue
        out[at] = b
        out[ref] = drop.get(ref) or ""
    return out


def _earlier_receipt(keep: dict, drop: dict) -> dict:
    """The columns to move when the duplicate was received EARLIER than the row we keep, else {}.

    `due_at` and `hide_due_at` are derived from `received_at` (received + 30 d / + 24 h), so they move together: taking
    the earlier receipt without its dates would leave the row claiming a deadline its own receipt contradicts."""
    a, b = str(keep.get("received_at") or ""), str(drop.get("received_at") or "")
    if not b or (a and a <= b):
        return {}
    return {"received_at": b, "due_at": drop.get("due_at") or "", "hide_due_at": drop.get("hide_due_at") or ""}


def _dedupe_pages(pages: list[dict]) -> list[dict]:
    """Unique by id; a full uuid replaces an 8-char prefix of itself."""
    out: dict[str, dict] = {}
    for p in pages:
        pid = (p.get("id") or "").lower()
        if not pid:
            continue
        ent = p.get("entity") or "profile"
        if len(pid) == 8 and any(k.startswith(pid) and len(k) > 8 for k in out):
            continue
        if len(pid) > 8 and pid[:8] in out:
            out.pop(pid[:8])
        out.setdefault(pid, {"entity": ent, "id": pid})
    return sorted(out.values(), key=lambda x: (x["entity"], x["id"]))
