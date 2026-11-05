"""Read-only readers for every source the churn signal joins (nothing here writes).

  core replica   postgresql_core through scripts/trino-query.sh (stdin SQL, CSV out)
                 users (identity), subscriptions (plan, renewal, cancellation),
                 credit_requests (open), claiming (pending claims)
  hydra ledger   /var/lib/hydra/credit-review/ledger.sqlite3 opened mode=ro
                 verify_messages (what we told them, and when)
  proof store    /var/lib/hydra-credit-verify/proof.sqlite opened mode=ro
                 proof_intake (a document they filed)
  ClickUp        list 901000600160, GET only, paged until an EMPTY page
                 (last_page lies: a full page is returned with last_page=false)

Every reader is injectable (`run=`, `connect=`) so the tests drive them with
fakes and no network. A failure is a raised SourceError that the caller counts
and records; nothing here silently returns an empty answer that looks like "no
issue".
"""

from __future__ import annotations

import csv
import io
import json
import os
import sqlite3
import subprocess
import time
import urllib.error
import urllib.request
from typing import Any, Callable, Iterable

TRINO = os.environ.get("CHURN_TRINO", "/opt/hydra/scripts/trino-query.sh")
LEDGER = os.environ.get("CHURN_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
PROOF = os.environ.get("CHURN_PROOF", "/var/lib/hydra-credit-verify/proof.sqlite")
CLICKUP_LIST = os.environ.get("CHURN_CLICKUP_LIST", "901000600160")
TRINO_CHUNK = 500          # id lists per query: keeps the bigint IN list pushdown-friendly
CLICKUP_MAX_PAGES = 250     # a full page is 100 tasks; the measured list is ~14,100 tasks (~141 pages)


class SourceError(RuntimeError):
    pass


class Sources:
    def __init__(self, *, trino: str | None = None, ledger: str | None = None,
                 proof: str | None = None, run: Callable[..., Any] | None = None,
                 connect: Callable[..., Any] | None = None, clickup_key: str | None = None,
                 clickup_list: str = CLICKUP_LIST, sleep: Callable[[float], None] = time.sleep):
        self.trino = trino or TRINO
        self.ledger = ledger or LEDGER
        self.proof = proof or PROOF
        self.run = run or subprocess.run
        self.connect = connect or sqlite3.connect
        self.clickup_key = clickup_key
        self.clickup_list = clickup_list
        self.sleep = sleep
        self.errors: list[str] = []
        self._tells: dict[str, list[dict[str, Any]]] | None = None
        self._proof: dict[str, list[dict[str, Any]]] | None = None

    # -- core replica ------------------------------------------------------
    def query(self, sql: str) -> list[list[str]]:
        """Rows from Trino, CSV-decoded. Raises SourceError on any failure."""
        try:
            proc = self.run([self.trino], input=sql.encode(), capture_output=True, timeout=600)
        except (OSError, subprocess.SubprocessError) as exc:
            raise SourceError(f"trino-query.sh failed to run: {exc}") from exc
        out = (proc.stdout or b"").decode("utf-8", "replace")
        err = (proc.stderr or b"").decode("utf-8", "replace")
        rc = getattr(proc, "returncode", 0)
        if rc != 0:
            raise SourceError(f"trino-query.sh rc={rc}: {err.strip()[-400:]}")
        rows: list[list[str]] = []
        for line in io.StringIO(out):
            line = line.rstrip("\n")
            if not line or line.startswith("Query "):
                continue
            rows.append(next(csv.reader([line])))
        return rows

    @staticmethod
    def _chunks(ids: Iterable[int], size: int = TRINO_CHUNK) -> list[list[int]]:
        ids = sorted({int(i) for i in ids})
        return [ids[i:i + size] for i in range(0, len(ids), size)]

    def users(self, ids: Iterable[int]) -> dict[str, dict[str, Any]]:
        out: dict[str, dict[str, Any]] = {}
        for chunk in self._chunks(ids):
            literals = ",".join(str(i) for i in chunk)
            sql = f"""
SELECT CAST(u.id AS varchar), coalesce(lower(u.email), ''), coalesce(CAST(u.auth0userid AS varchar), ''),
       coalesce(CAST(u.neptuneprofessionalid AS varchar), ''), coalesce(u.fullname, '')
FROM postgresql_core.public.users u
WHERE u.id IN ({literals})
"""
            for row in self.query(sql):
                if len(row) < 5:
                    continue
                out[row[0]] = {"user_id": int(row[0]), "email": row[1], "auth0": row[2],
                               "profile": row[3], "name": row[4]}
        return out

    def open_credit_requests(self, ids: Iterable[int]) -> dict[str, list[dict[str, Any]]]:
        out: dict[str, list[dict[str, Any]]] = {}
        for chunk in self._chunks(ids):
            literals = ",".join(str(i) for i in chunk)
            sql = f"""
SELECT CAST(cr.userid AS varchar), lower(CAST(cr.id AS varchar)), CAST(cr.status AS varchar),
       CAST(cr.createdat AS varchar), CAST(cr.updatedat AS varchar),
       coalesce(json_extract_scalar(cr.metadata, '$.proofRequest.noticeSentAt'), '')
FROM postgresql_core.public.credit_requests cr
WHERE cr.deletedat IS NULL AND cr.userid IS NOT NULL AND cr.status NOT IN ('approved', 'rejected')
  AND cr.userid IN ({literals})
ORDER BY cr.createdat
"""
            for row in self.query(sql):
                if len(row) < 5:
                    continue
                out.setdefault(row[0], []).append(
                    {"request_id": row[1], "status": row[2], "created_at": row[3],
                     "updated_at": row[4], "notice_sent_at": (row[5] if len(row) > 5 else "")})
        return out

    def pending_claims(self, ids: Iterable[int]) -> dict[str, list[dict[str, Any]]]:
        out: dict[str, list[dict[str, Any]]] = {}
        for chunk in self._chunks(ids):
            literals = ",".join(str(i) for i in chunk)
            sql = f"""
SELECT CAST(c.userid AS varchar), CAST(c.id AS varchar), CAST(c.status AS varchar),
       CAST(c.createdat AS varchar), coalesce(CAST(c.profileid AS varchar), '')
FROM postgresql_core.public.claiming c
WHERE c.deletedat IS NULL AND c.userid IS NOT NULL AND c.status = 'pending'
  AND c.userid IN ({literals})
ORDER BY c.createdat
"""
            for row in self.query(sql):
                if len(row) < 4:
                    continue
                out.setdefault(row[0], []).append(
                    {"claim_id": row[1], "status": row[2], "created_at": row[3],
                     "profile_id": (row[4] if len(row) > 4 else "")})
        return out

    def subscriptions(self, ids: Iterable[int]) -> dict[str, dict[str, Any]]:
        """Live subscription per user: plan, renewal, and any pending cancellation."""
        out: dict[str, dict[str, Any]] = {}
        for chunk in self._chunks(ids):
            literals = ",".join(str(i) for i in chunk)
            sql = f"""
SELECT CAST(s.userid AS varchar), CAST(s.status AS varchar), coalesce(s.plan, ''),
       coalesce(json_extract_scalar(s.details, '$.expiresAt'), ''),
       coalesce(json_extract_scalar(s.details, '$.periodStart'), ''),
       coalesce(json_extract_scalar(s.details, '$.autoRenew'), ''),
       coalesce(json_extract_scalar(s.details, '$.cancellationDetails.reason'), ''),
       coalesce(json_extract_scalar(s.details, '$.cancellationDetails.feedback'), ''),
       coalesce(s.service, ''), CAST(s.updatedat AS varchar)
FROM postgresql_core.public.subscriptions s
WHERE s.status IN ('active', 'trialing', 'past_due') AND s.userid IN ({literals})
ORDER BY s.updatedat DESC
"""
            for row in self.query(sql):
                if len(row) < 9 or row[0] in out:
                    continue     # newest first: the first live row per user wins
                out[row[0]] = {"status": row[1], "plan": row[2], "expires_at": row[3],
                               "period_start": row[4], "auto_renew": row[5],
                               "cancel_reason": row[6], "cancel_feedback": row[7],
                               "service": row[8], "updated_at": row[9] if len(row) > 9 else ""}
        return out

    def cancel_requests(self) -> list[dict[str, Any]]:
        """Subscriptions with a cancellation SCHEDULED (the request moment).

        `details.autoRenew = false` on a live subscription is what Stripe's
        `customer.subscription.updated` (cancel_at_period_end=true) writes into the
        replica via the billing webhook, so this reads the same fact without a new
        secret and without a Stripe call. It is up to 23 days before the end - the
        window in which a save is still possible.
        """
        sql = """
SELECT CAST(s.userid AS varchar), CAST(s.id AS varchar), coalesce(s.plan, ''),
       coalesce(json_extract_scalar(s.details, '$.expiresAt'), ''),
       coalesce(json_extract_scalar(s.details, '$.currentPeriodEnd'), ''),
       CAST(s.updatedat AS varchar)
FROM postgresql_core.public.subscriptions s
WHERE s.status IN ('active', 'trialing')
  AND lower(coalesce(json_extract_scalar(s.details, '$.autoRenew'), '')) = 'false'
  AND s.userid IS NOT NULL
ORDER BY s.updatedat
"""
        out = []
        for row in self.query(sql):
            if len(row) < 5:
                continue
            out.append({"user_id": int(row[0]), "subscription_id": row[1], "plan": row[2],
                        "expires_at": row[3] or row[4], "requested_at": row[5] if len(row) > 5 else "",
                        "service": ""})
        return out

    def cancelled_since(self, since_ts: float) -> list[dict[str, Any]]:
        """Every subscription that went to cancelled since `since_ts` (UTC epoch)."""
        since = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(since_ts))
        sql = f"""
SELECT CAST(s.userid AS varchar), CAST(s.id AS varchar), coalesce(s.plan, ''),
       coalesce(json_extract_scalar(s.details, '$.expiresAt'), ''),
       coalesce(json_extract_scalar(s.details, '$.cancellationDetails.reason'), ''),
       coalesce(json_extract_scalar(s.details, '$.cancellationDetails.feedback'), ''),
       coalesce(s.service, ''), CAST(s.updatedat AS varchar)
FROM postgresql_core.public.subscriptions s
WHERE s.status = 'cancelled' AND s.updatedat >= TIMESTAMP '{since}' AND s.userid IS NOT NULL
ORDER BY s.updatedat
"""
        out = []
        for row in self.query(sql):
            if len(row) < 8:
                continue
            out.append({"user_id": int(row[0]), "subscription_id": row[1], "plan": row[2],
                        "expires_at": row[3], "reason": row[4], "feedback": row[5],
                        "service": row[6], "cancelled_at": row[7]})
        return out

    # -- hydra ledger ------------------------------------------------------
    def _ro(self, path: str) -> sqlite3.Connection:
        try:
            conn = self.connect(f"file:{path}?mode=ro", uri=True, timeout=20)
            conn.row_factory = sqlite3.Row
            return conn
        except sqlite3.Error as exc:
            raise SourceError(f"{path} is unreadable read-only: {exc}") from exc

    def tells(self) -> dict[str, list[dict[str, Any]]]:
        """What we sent them (verify_messages), keyed by the ledger's account id.

        `status` == 'sent' only: a queued-but-unsent row (`attempted`, `deferred`,
        `refused`, `rejected`) is not a note the customer saw, and this drives both
        the "no status note" test and the "we promised and did not follow up" test.
        Anything else the ledger may carry, including an empty status, is not a note
        the customer saw either: no writer records a delivered note that way.
        """
        if self._tells is not None:
            return self._tells
        conn = self._ro(self.ledger)
        try:
            rows = conn.execute(
                "SELECT coalesce(account_id, ''), coalesce(user_key, ''), coalesce(campaign, ''),"
                " coalesce(kind, ''), coalesce(created_at, ''), coalesce(contact_id, ''),"
                " coalesce(conversation_id, ''), coalesce(status, '') FROM verify_messages").fetchall()
        except sqlite3.Error as exc:
            raise SourceError(f"verify_messages unreadable: {exc}") from exc
        finally:
            conn.close()
        out: dict[str, list[dict[str, Any]]] = {}
        for r in rows:
            acct, user_key, campaign, kind, created, contact, conv, status = [r[i] for i in range(8)]
            if status != "sent":
                continue
            rec = {"at": created, "campaign": campaign, "kind": kind,
                   "contact_id": contact, "conversation_id": conv, "user_key": user_key}
            for key in {acct, user_key}:
                if key:
                    out.setdefault(str(key).lower(), []).append(rec)
        self._tells = out
        return out

    def proof_intake(self) -> dict[str, list[dict[str, Any]]]:
        if self._proof is not None:
            return self._proof
        conn = self._ro(self.proof)
        try:
            rows = conn.execute(
                "SELECT CAST(user_id AS TEXT), coalesce(received_at, ''), coalesce(source, ''),"
                " coalesce(subject, '') FROM proof_intake").fetchall()
        except sqlite3.Error as exc:
            raise SourceError(f"proof_intake unreadable: {exc}") from exc
        finally:
            conn.close()
        out: dict[str, list[dict[str, Any]]] = {}
        for r in rows:
            uid = str(r[0])
            if uid:
                out.setdefault(uid, []).append({"at": r[1], "source": r[2], "subject": r[3][:120]})
        self._proof = out
        return out

    # -- ClickUp -----------------------------------------------------------
    def _clickup_key(self) -> str:
        if self.clickup_key:
            return self.clickup_key
        env = os.environ.get("MUSOAI_CLICKUP_API_KEY") or os.environ.get("CLICKUP_API_KEY") or ""
        if env:
            return env
        for path in ("/etc/openclaw/main.env",):
            try:
                with open(path, encoding="utf-8") as fh:
                    for line in fh:
                        if line.startswith(("MUSOAI_CLICKUP_API_KEY=", "CLICKUP_API_KEY=")):
                            return line.split("=", 1)[1].strip().strip('"')
            except OSError:
                continue
        raise SourceError("no ClickUp API key (MUSOAI_CLICKUP_API_KEY, /etc/openclaw/main.env)")

    def clickup_tasks(self) -> list[dict[str, Any]]:
        """OPEN tasks of the merge/claim intake list (closed ones cannot be a dropped ball).

        Paged by PAGE NUMBER until an EMPTY page. `last_page` is not the terminator
        (measured 2026-11-03: page 3 of a 400+ task list still said last_page=false,
        and stopping on it hides every later page - the report's measurement bug).
        """
        key = self._clickup_key()
        out: list[dict[str, Any]] = []
        seen: set[str] = set()
        for page in range(CLICKUP_MAX_PAGES):
            url = (f"https://api.clickup.com/api/v2/list/{self.clickup_list}/task"
                   f"?page={page}&include_closed=false&subtasks=false&order_by=created&reverse=true")
            req = urllib.request.Request(url, headers={"Authorization": key, "Accept": "application/json"})
            payload = None
            for attempt in range(4):
                try:
                    with urllib.request.urlopen(req, timeout=60) as resp:
                        payload = json.loads(resp.read())
                    break
                except urllib.error.HTTPError as exc:
                    if exc.code in (429, 500, 502, 503, 504) and attempt < 3:
                        self.sleep(2.0 * (attempt + 1))
                        continue
                    raise SourceError(f"ClickUp list {self.clickup_list} page {page}: HTTP {exc.code}") from exc
                except (urllib.error.URLError, OSError, ValueError) as exc:
                    if attempt < 3:
                        self.sleep(2.0 * (attempt + 1))
                        continue
                    raise SourceError(f"ClickUp list {self.clickup_list} page {page}: {exc}") from exc
            tasks = (payload or {}).get("tasks") or []
            if not tasks:
                return out
            for t in tasks:
                tid = str(t.get("id"))
                if tid in seen:
                    continue
                seen.add(tid)
                out.append(self._clickup_row(t))
        # A cap hit is a PARTIAL read: the list is ordered newest-first, so what is missing
        # is the oldest - highest-risk - intake tickets. Never return it as a complete set
        # (that publishes/answers "no open issue" over a truncated walk).
        raise SourceError(f"clickup: stopped at the {CLICKUP_MAX_PAGES}-page cap")

    @staticmethod
    def _clickup_row(t: dict[str, Any]) -> dict[str, Any]:
        text = " ".join(str(x) for x in (t.get("name"), t.get("text_content"), t.get("description")) if x)
        fields = {}
        for f in t.get("custom_fields") or []:
            if not isinstance(f, dict):
                continue
            fields[str(f.get("name") or f.get("id"))] = f.get("value")
        return {"id": str(t.get("id")), "name": t.get("name") or "",
                "status": ((t.get("status") or {}) or {}).get("status") or "",
                "created": t.get("date_created"), "updated": t.get("date_updated"),
                "closed": t.get("date_closed") or t.get("date_done"),
                "text": text[:4000], "fields": fields,
                "url": t.get("url") or ""}
