"""Facts for one Intercom conversation — every one of them MEASURED, or explicitly unknown.

The card `summarize.py` prints is the whole basis of a resolution suggestion, and the suggestion is
a lookup over these values (`ops_intake.resolutions`). So a fact has two states, never three-ish:

    measured   the reader ran and returned a value (0 / False / "none" included)
    unknown    the reader could not run (no token, no replica, a store that is not on this host,
               an account that does not resolve, a malformed row)

`measured` is the authority on whether the reader ran; `value is None` is not by itself unknown.
A missing erasure store is a measured UNKNOWN (`measured=True`, `value=None`), while a reader that
ran and found no row returns a real value (`{"status": "none"}`). A value is never coerced to
0 / "none" / "no", because "0 open requests" and "I could not read the requests" map to
DIFFERENT resolutions (an answer-bank status line vs a hand-off) and a card that renders the
second as the first is exactly the failure this surface exists to stop.

Sources, one per fact (printed on the card so a reviewer can re-run the read):

    conversation   Intercom GET /conversations/{id}              (read-only)
    account        credit_review.identity_resolver, r5           (read-only; a name is never an input)
    requests       postgresql_core.public.credit_requests        (Trino replica)
    claims         postgresql_core.public.claiming               (Trino replica)
    merges         merge_verify audit store, latest run          (read-only)
    erasure        /var/lib/hydra-gdpr/erasure.sqlite            (the GDPR register; read-only)
    verify         verify_messages / verify_proof_reviews        (read-only)
    subscription   postgresql_core.public.subscriptions          (Trino replica)
    tickets        ClickUp User Requests list                    (read-only)
    messages       Intercom conversation parts                   (read-only)

Nothing here writes to any of those, and nothing here calls a model.
"""
from __future__ import annotations

import hashlib
import os
import socket
import sqlite3
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:  # the repo convention: scripts/ on the path, packages under it
    sys.path.insert(0, str(SCRIPTS))

# The fact names the policy predicates may read (`resolutions.PREDICATES`). Adding one means adding
# it here (the reader), in `Facts.data`, and in resolutions.py (the predicate) in the same PR.
FACT_NAMES = (
    "account_id", "account_matched_by",
    "requests", "request_status",
    "claims", "merges", "erasure", "verify", "subscription", "tickets",
    "last_customer_message_age_s", "last_staff_message_age_s",
    "customer_text", "customer_text_quarantined",
    "contact_external_id", "contact_email", "contact_id",
    "target_popular",
)


# ------------------------------------------------------------------------------------------------
# the value type


@dataclass(frozen=True)
class Fact:
    """One measured value. `measured` is the authority on whether the reader ran; `value is None`
    is not by itself "unmeasured" (a missing erasure store is a measured UNKNOWN)."""

    name: str
    value: Any
    source: str
    detail: str = ""
    # `measured` is explicit, not `value is not None`: an erasure read that ran and found NO row
    # is a measured "none" (a real fact, which maps to the erasure action), while a read that
    # crashed is unknown (which must fall through to the hand-off). Conflating the two is the bug
    # this surface exists to prevent.
    measured: bool = True


@dataclass
class Facts:
    """Everything the card prints, keyed by fact name."""

    conversation_id: str
    facts: dict[str, Fact] = field(default_factory=dict)
    errors: list[str] = field(default_factory=list)

    def put(self, name: str, value: Any, source: str, detail: str = "",
            measured: bool = True) -> Fact:
        f = Fact(name=name, value=value, source=source, detail=detail, measured=measured)
        self.facts[name] = f
        return f

    def get(self, name: str) -> Fact:
        return self.facts.get(name) or Fact(name=name, value=None, source="not collected", measured=False)

    def value(self, name: str) -> Any:
        return self.get(name).value

    def unknown(self, name: str) -> bool:
        return not self.get(name).measured

    # -- the shapes the predicates and the card need --------------------------------------

    @property
    def requests(self) -> list[dict[str, Any]] | None:
        v = self.value("requests")
        return v if isinstance(v, list) else None

    @property
    def open_request_statuses(self) -> list[str] | None:
        rs = self.requests
        if rs is None:
            return None
        return sorted({str(r.get("status") or "") for r in rs if r.get("status")})

    @property
    def data(self) -> dict[str, Any]:
        """The values the predicates read. Unknowns stay None so a rule cannot read them as 0."""
        return {name: self.get(name).value for name in FACT_NAMES}

    def account_hash(self) -> str:
        """`account <hash>` on the card: an account id is never printed in Slack or a log line."""
        v = self.value("account_id")
        if v is None:
            return "unresolved"
        return "acct-" + hashlib.sha256(f"ops-intake:{v}".encode()).hexdigest()[:12]

    def counts_line(self, *, redact: bool = False) -> str:
        """`facts: <k statuses / claims / merges / erasure / refund>` — spec §4, unknowns spoken.

        `redact=True` drops the GDPR register number. The staff card prints it (it is how a human
        finds the row); the JSON view does not, because `--json` output lands in a log, a ticket or
        a model prompt, and a register number is a personal-data reference.
        """
        reqs = self.requests
        parts = [
            _count("open request", len(reqs) if reqs is not None else None),
            _statuses(self.open_request_statuses),
            _count("claim", self.value("claims")),
            _count("merge", self.value("merges")),
            _erasure(self.value("erasure"), redact=redact),
            _verify(self.value("verify")),
            _subscription(self.value("subscription")),
            _count("ClickUp ticket", self.value("tickets")),
        ]
        return " / ".join(parts)


def _count(noun: str, n: Any) -> str:
    if n is None:
        return f"{noun}s unknown"
    return f"{int(n)} {noun}{'' if int(n) == 1 else 's'}"


def _statuses(statuses: list[str] | None) -> str:
    if statuses is None:
        return "statuses unknown"
    if not statuses:
        return "no open status"
    return ",".join(statuses)


def _erasure(row: Any, *, redact: bool = False) -> str:
    if row is None:
        return "erasure unknown"
    if not isinstance(row, dict) or not row.get("status"):
        return "erasure no status"
    if row["status"] == "none":
        return "erasure none"
    reg = f" #{row['register_no']}" if (row.get("register_no") and not redact) else ""
    return f"erasure {row['status']}{reg}"


def _verify(v: Any) -> str:
    if not isinstance(v, dict):
        return "verify unknown"
    asks = v.get("asks_sent")
    proof = v.get("proof_on_file")
    dv = v.get("dv_outcome")
    return " ".join([
        f"verify asks {asks}" if asks is not None else "verify asks unknown",
        "proof on file" if proof is True else ("no proof on file" if proof is False else "proof unknown"),
        f"dv {dv}" if dv else "dv unknown",
    ])


def _subscription(s: Any) -> str:
    if s is None:
        return "sub unknown"
    if isinstance(s, str):
        return f"sub {s}"
    if isinstance(s, dict):
        return f"sub {s.get('status') or 'unknown'}"
    return "sub unknown"


# ------------------------------------------------------------------------------------------------
# Intercom (read-only)


def read_conversation(conversation_id: str) -> dict[str, Any] | None:
    """Intercom GET /conversations/{id} — the same read-only token loader the proof filer uses."""
    from credit_verify.proof.intercom import intercom_token, make_fetch  # noqa: PLC0415

    tok = intercom_token()
    if not tok:
        raise RuntimeError("no MUSOAI_INTERCOM_TOKEN (edge.env)")
    return make_fetch(tok)(conversation_id)


def conversation_parts(conv: dict[str, Any]) -> list[dict[str, Any]]:
    parts: list[dict[str, Any]] = list((conv.get("conversation_parts") or {}).get("conversation_parts") or [])
    if isinstance(conv.get("source"), dict):
        parts.insert(0, conv["source"])
    return parts


def _ts_of(part: dict[str, Any]) -> int | None:
    try:
        v = part.get("created_at")
        return int(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def read_messages(conv: dict[str, Any], *, now: int | None = None) -> dict[str, Any]:
    """Customer parts, and how long ago each side last spoke.

    `customer_text` is the customer's own parts joined by a blank line — the ONE customer string
    the card may quote (`quote_customer_text` bounds and delimits it, after the injection watch).
    """
    now = int(datetime.now(timezone.utc).timestamp()) if now is None else now
    customer: list[str] = []
    cust_ts: list[int] = []
    staff_ts: list[int] = []
    for part in conversation_parts(conv):
        author = str((part.get("author") or {}).get("type") or "").lower()
        body = part.get("body") if isinstance(part.get("body"), str) else ""
        ts = _ts_of(part)
        if author == "user":
            if body.strip():
                customer.append(body)
            if ts is not None:
                cust_ts.append(ts)
        elif author == "admin" and ts is not None:
            staff_ts.append(ts)
    return {
        "customer_text": "\n\n".join(customer) if customer else None,
        "last_customer_message_age_s": (now - max(cust_ts)) if cust_ts else None,
        "last_staff_message_age_s": (now - max(staff_ts)) if staff_ts else None,
    }


def contact_of(conv: dict[str, Any]) -> dict[str, Any]:
    """The contact the conversation belongs to; `external_id` is the ONLY identity input (r5)."""
    customers = list((conv.get("contacts") or {}).get("contacts") or [])
    if not customers:
        author = (conv.get("source") or {}).get("author") or {}
        if str(author.get("type") or "").lower() == "user":
            customers = [author]
    c = customers[0] if customers else {}
    return {
        "contact_id": c.get("id"),
        "contact_external_id": c.get("external_id") or None,
        "contact_email": c.get("email") or None,
        "source": "intercom conversation contacts[]",
    }


# ------------------------------------------------------------------------------------------------
# postgres replica (read-only)


def trino_query(sql: str) -> list[list[str]]:
    """The repo's read-only core replica wrapper (scripts/trino-query.sh)."""
    from credit_review.verify_notify import trino  # noqa: PLC0415

    return trino(sql)


def read_account(external_id: str | None, query: Callable[[str], list[list[str]]]) -> dict[str, Any]:
    """r5 identity: external_id -> EXACTLY ONE account, or a refusal that says why. A name is never
    an input and more than one owner is a refusal (identity_resolver, Fable [key=x2-sample-1027])."""
    from credit_review.identity_resolver import resolve  # noqa: PLC0415

    if not external_id:
        return {"account_id": None, "account_matched_by": None,
                "why": "contact carries no external_id"}
    got = resolve([external_id], query) or {}
    r = got.get(external_id)
    if r is None:
        return {"account_id": None, "account_matched_by": None, "why": "resolver returned no verdict"}
    return {"account_id": r.account_id, "account_matched_by": r.matched_by or None, "why": r.why or None}


def read_requests(user_id: int | None, query: Callable[[str], list[list[str]]]) -> list[dict[str, Any]]:
    """Open credit requests for the account, with the status that decides the suggestion."""
    if user_id is None:
        raise RuntimeError("no resolved account")
    rows = query(
        "SELECT CAST(id AS varchar), status, CAST(profileid AS varchar), "
        "coalesce(CAST(spotifypopularity AS varchar), ''), CAST(createdat AS varchar) "
        "FROM postgresql_core.public.credit_requests "
        f"WHERE deletedat IS NULL AND userid = {int(user_id)} "
        "AND status NOT IN ('approved','rejected') ORDER BY createdat DESC")
    out = []
    for rid, status, profile, pop, created in rows:
        out.append({"id": rid, "status": status, "profile_id": profile,
                    "popularity": int(pop) if str(pop).strip().isdigit() else None,
                    "created_at": created})
    return out


def read_claims(user_id: int | None, query: Callable[[str], list[list[str]]]) -> int:
    if user_id is None:
        raise RuntimeError("no resolved account")
    rows = query("SELECT CAST(count(*) AS varchar) FROM postgresql_core.public.claiming "
                 f"WHERE deletedat IS NULL AND userid = {int(user_id)}")
    return int(rows[0][0]) if rows and rows[0] and str(rows[0][0]).strip().isdigit() else 0


def profile_ids_of(user_id: int | None, query: Callable[[str], list[list[str]]]) -> set[str]:
    if user_id is None:
        return set()
    rows = query("SELECT CAST(profileid AS varchar) FROM postgresql_core.public.claiming "
                 f"WHERE deletedat IS NULL AND userid = {int(user_id)}")
    return {str(r[0]).strip().lower() for r in rows if r and str(r[0] or "").strip()}


def read_merges(user_id: int | None, query: Callable[[str], list[list[str]]]) -> int:
    """Duplicate pairs from merge-verify's LATEST run that name this account's profiles.

    Deliberately the same verdict set merge-verify.py judges, so `merges > 0` means "merge-verify
    has something to say about this account", not a guess. A store that is not on this host is
    UNKNOWN (raise), never 0: "no duplicates" and "we never measured" map to different actions.
    """
    from merge_verify import store as mv_store  # noqa: PLC0415

    ids = profile_ids_of(user_id, query)
    if not ids:
        return 0
    path = Path(os.environ.get("MERGE_VERIFY_STORE", mv_store.DEFAULT))
    if not path.exists():
        raise RuntimeError(f"merge-verify store missing ({path})")
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        rows = db.execute(
            "SELECT lower(coalesce(keep, '')), lower(coalesce(loser, '')) FROM mv_verdicts "
            "WHERE run_id = (SELECT run_id FROM mv_runs ORDER BY finished DESC LIMIT 1)").fetchall()
    except sqlite3.Error as exc:
        raise RuntimeError(f"merge-verify store unreadable: {exc}") from exc
    finally:
        db.close()
    return sum(1 for keep, loser in rows if keep in ids or loser in ids)


def read_subscription(user_id: int | None, query: Callable[[str], list[list[str]]]) -> dict[str, Any] | None:
    """Subscription state as the app mirrors it (subscriptions.status), read-only.

    A refund or a cancellation is NOT available from this surface (W2): the card states the state
    and the policy maps `billing` to the human path with the approved refund copy.
    """
    if user_id is None:
        raise RuntimeError("no resolved account")
    rows = query(
        "SELECT DISTINCT status FROM postgresql_core.public.subscriptions "
        f"WHERE teamid IN (SELECT teamid FROM postgresql_core.public.team_users WHERE userid = {int(user_id)})")
    statuses = sorted({str(r[0]) for r in rows if r and r[0]})
    return {"status": ",".join(statuses) if statuses else "none"}


def _sql_literal(value: str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def _popular_from_rows(rows: list[list[str]] | None) -> bool | None:
    from credit_review.fraud_lens import BIG_POP  # noqa: PLC0415

    if not rows or not rows[0]:
        return None
    pop = str(rows[0][0]).strip()
    n = str(rows[0][1]).strip()
    pop_v = int(pop) if pop.isdigit() else 0
    n_v = int(n) if n.isdigit() else 0
    return pop_v >= BIG_POP or n_v >= 50


def read_target_popular(user_id: int | None, query: Callable[[str], list[list[str]]]) -> bool | None:
    """`target_popular` for the rename W2 rule: catalog pop >= 60 or >= 50 credits.

    Both thresholds are named in the dispatch spec (j2 §6 / s1 §6); BIG_POP is read from
    fraud_lens so the two lanes cannot drift to different "popular".
    """
    if user_id is None:
        return None
    return _popular_from_rows(query(
        "SELECT coalesce(CAST(max(spotifypopularity) AS varchar), '0'), CAST(count(*) AS varchar) "
        "FROM postgresql_core.public.credit_requests "
        f"WHERE userid = {int(user_id)} AND deletedat IS NULL"))


def read_profile_popular(profile_id: str | None,
                         query: Callable[[str], list[list[str]]]) -> bool | None:
    """`target_popular` measured on the RENAME TARGET profile, not the account's user id."""
    if not profile_id:
        return None
    return _popular_from_rows(query(
        "SELECT coalesce(CAST(max(spotifypopularity) AS varchar), '0'), CAST(count(*) AS varchar) "
        "FROM postgresql_core.public.credit_requests "
        f"WHERE CAST(profileid AS varchar) = {_sql_literal(profile_id)} "
        "AND deletedat IS NULL"))


# ------------------------------------------------------------------------------------------------
# local stores (read-only)


def erasure_store_path() -> Path:
    """The register path this host looked for (`GDPR_STORE` when set)."""
    from gdpr_pipeline.store import DEFAULT_PATH  # noqa: PLC0415

    return Path(os.environ.get("GDPR_STORE", DEFAULT_PATH))


def read_erasure(conversation_id: str, contact_id: str | None) -> dict[str, Any] | None:
    """The GDPR register row for this conversation (never writes, never hides).

    A missing store is UNKNOWN (`None`): absence of data is not a value, and asking a customer to
    prove an erasure again because OUR store was missing is the failure this surface exists to
    stop. A store that ran and found no row is a MEASURED none (`{"status": "none"}`).
    """
    p = erasure_store_path()
    if not p.exists():
        return None
    db = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
    try:
        db.row_factory = sqlite3.Row
        cols = ("id, register_no, class, status, due_at, hide_due_at, identity_verdict, hidden_at")
        row = None
        if contact_id:
            row = db.execute(f"SELECT {cols} FROM erasure_requests WHERE contact_id = ? "
                             "ORDER BY id DESC LIMIT 1", (contact_id,)).fetchone()
        if row is None:
            row = db.execute(f"SELECT {cols} FROM erasure_requests WHERE conversation_id = ? "
                             "ORDER BY id DESC LIMIT 1", (conversation_id,)).fetchone()
        return dict(row) if row else {"status": "none"}
    finally:
        db.close()


def read_verify(user_id: int | None) -> dict[str, Any]:
    """The verify ledger as the card states it: asks sent, proof on file, dv outcome.

    Rows are keyed by the account id (`account_id`) as well as the email `user_key`; the account id
    is what this surface has, so it uses that and never an email.
    """
    from credit_review import verify_ledger  # noqa: PLC0415

    if user_id is None:
        raise RuntimeError("no resolved account")
    path = Path(os.environ.get("CREDIT_REVIEW_LEDGER", verify_ledger.DEFAULT_PATH))
    if not path.exists():
        raise RuntimeError(f"verify ledger missing ({path})")
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        uid = str(int(user_id))
        asks = db.execute("SELECT count(*) FROM verify_messages WHERE account_id = ?", (uid,)).fetchone()[0]
        proof = db.execute(
            "SELECT count(*) FROM verify_messages WHERE account_id = ? "
            "AND (proof_tagged_at IS NOT NULL OR proof_attachments > 0)", (uid,)).fetchone()[0]
        row = db.execute(
            "SELECT r.outcome FROM verify_proof_reviews r "
            "JOIN verify_messages m ON m.id = r.family "
            "WHERE m.account_id = ? ORDER BY r.reviewed_at DESC LIMIT 1", (uid,)).fetchone()
    except sqlite3.Error as exc:
        raise RuntimeError(f"verify ledger unreadable: {exc}") from exc
    finally:
        db.close()
    return {"asks_sent": int(asks), "proof_on_file": bool(proof), "dv_outcome": (row[0] if row else None)}


def read_tickets(user_id: int | None, query: Callable[[str], list[list[str]]]) -> int | None:
    """Open ClickUp User Requests that name this account's email. Unknown (None) when ClickUp is not
    configured on this host — never 0, because "no tickets" and "not measured" are different."""
    from lib.clickup_client import ClickUp  # noqa: PLC0415

    key = os.environ.get("CLICKUP_API_KEY") or os.environ.get("MUSOAI_CLICKUP_API_KEY") or ""
    if not key:
        return None
    if user_id is None:
        raise RuntimeError("no resolved account")
    rows = query("SELECT lower(email) FROM postgresql_core.public.users " f"WHERE id = {int(user_id)}")
    email = str(rows[0][0] or "").strip().lower() if rows and rows[0] else ""
    if not email:
        return None
    import json  # noqa: PLC0415

    client = ClickUp.shared(key)
    tasks = client.list_tasks(
        os.environ.get("CLICKUP_USER_REQUESTS_LIST", "901000600160"),
        [("subtasks", "true"), ("include_closed", "false")], 40)
    return sum(1 for t in tasks if email in json.dumps(t, default=str).lower())


def read_profile_name(profile_id: str) -> str | None:
    """The profile's CURRENT name — the before-image an inverse needs. Read-only, via the admin
    wrapper. Returns None when the name is not in the response (a caller treats that as "no
    inverse", which means no rename)."""
    from credit_review import admin as admin_api  # noqa: PLC0415

    if not profile_id:
        return None
    data = admin_api.profile(admin_api.AdminClient(), profile_id)
    name = data.get("name") or data.get("profileName") or ""
    return str(name).strip() or None


# ------------------------------------------------------------------------------------------------
# the collector


@dataclass
class Readers:
    """Every seam, so a whole card is testable from frozen facts with no network and no store."""

    conversation: Callable[[str], dict[str, Any] | None] = read_conversation
    query: Callable[[str], list[list[str]]] = trino_query
    account: Callable[[str | None, Callable[[str], list[list[str]]]], dict[str, Any]] = read_account
    requests: Callable[[int | None, Callable[[str], list[list[str]]]], list[dict[str, Any]]] = read_requests
    claims: Callable[[int | None, Callable[[str], list[list[str]]]], int] = read_claims
    erasure: Callable[[str, str | None], dict[str, Any] | None] = read_erasure
    verify: Callable[[int | None], dict[str, Any]] = read_verify
    tickets: Callable[[int | None, Callable[[str], list[list[str]]]], int | None] = read_tickets
    merges: Callable[[int | None, Callable[[str], list[list[str]]]], int] = read_merges
    subscription: Callable[[int | None, Callable[[str], list[list[str]]]], dict[str, Any] | None] = read_subscription
    popular: Callable[[int | None, Callable[[str], list[list[str]]]], bool | None] = read_target_popular
    profile_popular: Callable[[str | None, Callable[[str], list[list[str]]]], bool | None] = read_profile_popular


def collect(conversation_id: str, *, readers: Readers | None = None) -> Facts:
    """Build the card's facts. A reader that raises leaves ITS facts unknown and is recorded in
    `errors` — the card says "unknown", and the resolution falls through to `unknown` (a hand-off)."""
    r = readers or Readers()
    out = Facts(conversation_id=conversation_id)

    def step(name: str, fn: Callable[[], None]) -> None:
        try:
            fn()
        except Exception as exc:  # noqa: BLE001 - an unreadable fact is UNKNOWN, never a zero
            out.errors.append(f"{name}: {type(exc).__name__}: {exc}")

    def _conversation() -> None:
        got = r.conversation(conversation_id)
        if not isinstance(got, dict) or not got:
            raise RuntimeError("conversation not found or empty")
        c = contact_of(got)
        out.put("contact_id", c["contact_id"], c["source"])
        out.put("contact_external_id", c["contact_external_id"], c["source"])
        out.put("contact_email", c["contact_email"], c["source"])
        m = read_messages(got)
        out.put("customer_text", m["customer_text"], "intercom conversation parts (author.type=user)")
        out.put("last_customer_message_age_s", m["last_customer_message_age_s"], "intercom part created_at")
        out.put("last_staff_message_age_s", m["last_staff_message_age_s"], "intercom conversation_parts")

    step("conversation", _conversation)

    def _account() -> None:
        a = r.account(out.value("contact_external_id"), r.query)
        out.put("account_id", a["account_id"], "credit_review.identity_resolver r5")
        out.put("account_matched_by", a["account_matched_by"], "credit_review.identity_resolver r5",
                detail=a.get("why") or "")
        if a["account_id"] is None and a.get("why"):
            out.errors.append(f"account: refused: {a['why']}")

    step("account", _account)
    uid = out.value("account_id")

    def _requests() -> None:
        rs = r.requests(uid, r.query)
        out.put("requests", rs, "postgresql_core.public.credit_requests")
        statuses = sorted({str(x["status"]) for x in rs if x.get("status")})
        out.put("request_status", statuses[0] if len(statuses) == 1 else ("mixed" if statuses else "none"),
                "postgresql_core.public.credit_requests")

    step("requests", _requests)

    step("claims", lambda: out.put("claims", r.claims(uid, r.query), "postgresql_core.public.claiming"))
    step("merges", lambda: out.put("merges", r.merges(uid, r.query), "merge_verify audit store (latest run)"))

    def _erasure() -> None:
        row = r.erasure(conversation_id, out.value("contact_id"))
        out.put("erasure", row, "erasure_requests (/var/lib/hydra-gdpr/erasure.sqlite)")
        if row is None:
            # UNKNOWN, not a measured none: a human restores the store; the customer is not asked
            # again. The staff line names the host and the path the read looked for.
            out.errors.append(f"erasure: store missing on {socket.gethostname()} "
                              f"({erasure_store_path()})")

    step("erasure", _erasure)
    step("verify", lambda: out.put("verify", r.verify(uid), "verify_messages / verify_proof_reviews"))
    step("subscription", lambda: out.put("subscription", r.subscription(uid, r.query),
                                         "postgresql_core.public.subscriptions (read-only)"))
    step("tickets", lambda: out.put("tickets", r.tickets(uid, r.query), "ClickUp User Requests list"))
    step("popular", lambda: out.put("target_popular", r.popular(uid, r.query),
                                    "credit_requests popularity / count"))
    return out


# ------------------------------------------------------------------------------------------------
# customer text: ONE bounded, delimited quote, after the injection watch


QUARANTINE_TEXT = "customer text quarantined"
MAX_QUOTE_CHARS = 600


@dataclass
class QuotedText:
    text: str | None
    quarantined: bool
    severity: str | None
    hits: list[dict[str, str]]
    source: str = "customer_text"


def quote_customer_text(raw: str | None, *, conversation_id: str = "", contact_id: str | None = None,
                        scan: Callable[[str], list[dict[str, str]]] | None = None,
                        record: Callable[..., Any] | None = None) -> QuotedText:
    """Run the Caroline injection watch FIRST, then bound and delimit the one customer quote.

    A HIGH hit quarantines the text: the card says `customer text quarantined`, no model ever sees
    it, and the resolution is forced to `unknown` (`resolutions.suggest` refuses a quarantined ask).
    The hit is recorded through injection_watch.record so it is reviewable after the fact.
    """
    if not raw or not raw.strip():
        return QuotedText(text=None, quarantined=False, severity=None, hits=[])
    if scan is None or record is None:
        from lib import injection_watch  # noqa: PLC0415

        scan = scan or injection_watch.scan
        record = record or injection_watch.record
    hits = list(scan(raw) or [])
    severity = _severity_of(hits)
    try:
        record(source="intercom", ref=conversation_id or "ops-summarize",
               text=raw, contact_id=contact_id)
    except Exception:  # noqa: BLE001 - recording is best effort; the quarantine below is not
        pass
    if severity == "HIGH":
        return QuotedText(text=QUARANTINE_TEXT, quarantined=True, severity=severity, hits=hits)
    body = " ".join(raw.split())
    if len(body) > MAX_QUOTE_CHARS:
        body = body[:MAX_QUOTE_CHARS].rstrip() + "…"
    return QuotedText(text=body, quarantined=False, severity=severity, hits=hits)


def _severity_of(hits: Iterable[dict[str, str]]) -> str | None:
    order = {"HIGH": 3, "MEDIUM": 2, "LOW": 1}
    best: str | None = None
    for h in hits:
        s = str(h.get("severity") or "").upper()
        if order.get(s, 0) > order.get(best or "", 0):
            best = s
    return best
