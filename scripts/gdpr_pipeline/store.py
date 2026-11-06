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


SENDS_MIGRATIONS = (("idem", "TEXT DEFAULT ''"),)     # the letter's id; the ledger is the double-send guard


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

MAIL_CHANNELS = ("notices", "legal", "support")


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
               channel: str = "") -> dict | None:
        for k in keys:
            hit = self.by_key(k)
            if hit:
                return hit
        want = {(i or "")[:8].lower() for i in page_ids if i}
        if email and want and received_at:
            t = parse_iso(received_at)
            for r in self.all("open"):
                if r["confirmed_at"]:
                    continue      # a later look-alike after a written confirmation is a NEW request, not a merge
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
        hit = self._match(keys, email, {p["id"] for p in pages}, cand.get("received_at", ""), cand.get("channel", ""))
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
                        " detail, idem, at) VALUES (?,?,?,?,?,?,?,?,?,?)",
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
        self.db.execute("UPDATE erasure_sends SET channel=?, target=?, body_sha=?, approved_by=?, state=?, ref='', "
                        "detail=?, idem=?, at=? WHERE request_id=? AND kind=?",
                        (channel, target, body_sha, approved_by, state, detail[:500], idem, now_iso(), rid, kind))
        self.db.commit()

    def finish_send(self, rid: int, kind: str, state: str, ref: str = "", detail: str = "") -> None:
        self.db.execute("UPDATE erasure_sends SET state=?, ref=?, detail=? WHERE request_id=? AND kind=?",
                        (state, ref[:500], detail[:500], rid, kind))
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
