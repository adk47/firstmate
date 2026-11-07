#!/usr/bin/env python3
"""Build the wait-apology audience: the users who have waited with NO message from us.

Fable d2 (verify-sla-driver-fable-d2, 2026-11-05 01:4xZ) approved the copy and firstmate 772 asked for
the family. Firstmate 774 ruled the two exclusions this builder could not infer:

  legal_threat = a user with an open legal hold, or a reply tagged legal in Intercom (the support-legal
                 tag family). Where no coded source exists: exclude every user with ANY approval hold,
                 plus every conversation tagged legal / lawyer / attorney, read through the Intercom
                 tag API at build time.
  org_seat     = a user with a row in core's org seats (team_users membership, or an active roster
                 seat).

The candidate set is the paid-status pipeline's own output for a segment, which is already in d2's
order (paid first, then oldest pending first) and already carries the identity, lens and router holds
every send gate enforces. This builder adds only what an apology needs on top:

  * the WAIT bar         oldest_pending at least --wait-days old
  * the NO-RECONTACT bar no ledgered message of ANY campaign in the last 7 days, and never a
                         wait-apology note in that user's lifetime (one per user, ever)
  * legal_threat, org_seat   (774's two exclusions)
  * the batch caps       FIRST_CAP paid users on the first batch, --cap on every batch after it

INERT BY DESIGN. If any exclusion source cannot be read this exits 2, names the source, and writes NO
list: a missing source is not "nobody is excluded". The tick then has no audience and sends nothing,
which is the only honest outcome when we cannot prove a user is out of scope.

Usage:
  python3 -m credit_review.wait_apology_audience --plan-dir DIR --segment paid --out LIST.json
  python3 -m credit_review.wait_apology_audience ... --dry-run        # print the counts, write nothing
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from credit_review import comm_state, verify_ledger  # noqa: E402

CAMPAIGN = "wait-apology"
WAIT_DAYS = 7
NO_RECONTACT_DAYS = 7
FIRST_CAP = 100          # d2: the first batch is at most 100 paid users (the tick enforces it)
FULL_CAP = 250           # then 250 a tick (FULL_CAP_FROM[wait-apology], dated on the read-back)
LEGAL_TAGS = ("legal", "lawyer", "attorney", "support-legal")
BANDS_MAX_AGE_H = 6      # the fraud lens's own freshness bound for a scan used to EXCLUDE
DEFAULT_LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
# QA #1788 finding 3 (carried twice): this default used to be /var/lib/hydra/credit-review/account_bands.json, a path
# nothing writes, and the tick passes no --bands - so every build would have been INERT forever, silently, while the
# family looked wired. The fraud lens's scan has exactly ONE production location and comm_state already names it (R8
# reads the same file at send time); deriving the default from that constant means the two can never drift apart again.
DEFAULT_BANDS = comm_state.ACCOUNT_BANDS


class SourceMissing(Exception):
    """An exclusion source could not be read. The builder stays inert and names it."""


# -- the plan (paid-status's own ordering and identity holds) ----------------------------------------

def plan_rows(plan_dir: str) -> list[dict[str, Any]]:
    """The newest classify output of a paid-status segment run, in the pipeline's own order."""
    files = sorted(glob.glob(os.path.join(plan_dir, "cls", "dry-run-*.json")))
    if not files:
        raise SourceMissing(f"no classify output under {plan_dir}/cls (dry-run-*.json)")
    try:
        with open(files[-1], encoding="utf-8") as fh:
            rows = json.load(fh)
    except (OSError, ValueError) as exc:
        raise SourceMissing(f"{files[-1]} is unreadable ({type(exc).__name__})") from exc
    if not isinstance(rows, list):
        raise SourceMissing(f"{files[-1]} is not a list of classified users")
    return [r for r in rows if isinstance(r, dict)]


def segment_flags(plan_dir: str) -> dict[str, dict[str, Any]]:
    """segments.json: the pipeline's identity / lens / router holds, per user id."""
    path = os.path.join(plan_dir, "segments.json")
    try:
        with open(path, encoding="utf-8") as fh:
            rows = json.load(fh)
    except (OSError, ValueError) as exc:
        raise SourceMissing(f"the segment file {path} is unreadable ({type(exc).__name__})") from exc
    return {str(r.get("user_id")): r for r in rows if isinstance(r, dict)}


def held_by_the_pipeline(seg: dict[str, Any] | None) -> str:
    """'' when the pipeline holds this user from any note, else the reason."""
    if not seg:
        return "not_in_segments"           # absent from the run's own segment read: never messaged blind
    for key in ("msg_hold", "identity_hold", "lens_held", "cs_excluded", "forbidden"):
        if seg.get(key):
            return key
    return ""


# -- the ledger: the 7-day no-recontact bar and the once-ever bar ------------------------------------

class LedgerContact:
    """The ledger's own answer to "have we written to THIS user", per user id.

    It reuses verify_ledger._same_user - the ONE predicate the send gates use - so an account whose
    email changed, and a row written before account_id existed, both still count as contact. The
    apology must never be the second note in a week, and never the second of its own kind, ever.
    """

    def __init__(self, ledger_path: str, *, now: datetime, days: int = NO_RECONTACT_DAYS) -> None:
        if not os.path.exists(ledger_path):
            raise SourceMissing(f"the ledger {ledger_path} does not exist: cannot prove who was contacted")
        try:
            self.db = verify_ledger.connect(ledger_path)
        except Exception as exc:  # noqa: BLE001 - a missing ledger is never "nobody was contacted"
            raise SourceMissing(f"the ledger {ledger_path} is unreadable: {type(exc).__name__}") from exc
        self.since = (now - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def close(self) -> None:
        try:
            self.db.close()
        except Exception:  # noqa: BLE001
            pass

    def _one(self, uid: str, extra: str, params: tuple = ()) -> bool:
        clause, args = _ledger_user_clause(self.db, uid)
        sql = f"SELECT 1 FROM verify_messages WHERE {clause} {extra} LIMIT 1"
        try:
            return self.db.execute(sql, (*args, *params)).fetchone() is not None
        except Exception as exc:  # noqa: BLE001
            raise SourceMissing(f"the ledger cannot be read: {type(exc).__name__}") from exc

    def recent(self, uid: str) -> bool:
        """A message of ANY campaign to this user inside the no-recontact window (7 days)."""
        return self._one(uid, "AND status = 'sent' AND coalesce(sent_at, updated_at) >= ?", (self.since,))

    def ever_apologised(self, uid: str) -> bool:
        """A wait-apology note to this user at any time (one per user, ever)."""
        return self._one(uid, "AND status = 'sent' AND campaign = ?", (CAMPAIGN,))


def _ledger_user_clause(db: Any, uid: str) -> tuple[str, tuple]:
    """verify_ledger._same_user speaks in `m.` aliases; the marks query has no join, so alias the table.

    Kept as a tiny shim rather than a second predicate: two implementations of "the same user" is
    exactly how a 7-day gate silently stops matching an account that changed its email."""
    cond, params = verify_ledger._same_user(db, "", str(uid))
    return cond.replace("m.", ""), params


# -- 774's two exclusions ----------------------------------------------------------------------------

def approval_holds(bands_path: str, *, now: datetime, max_age_h: float = BANDS_MAX_AGE_H) -> set[str]:
    """Every user with ANY approval hold (774: "exclude every user with ANY approval hold").

    account_bands.json is the production fraud lens's current scan - the same file comm_state's R8
    reader trusts. Missing, unreadable, stale or future-dated is a MISSING SOURCE, never "no holds"."""
    try:
        with open(bands_path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        raise SourceMissing(f"the approval-hold scan {bands_path} is unreadable ({type(exc).__name__})") from exc
    if not isinstance(doc, dict) or not isinstance(doc.get("users"), dict):
        raise SourceMissing(f"the approval-hold scan {bands_path} carries no users map")
    try:
        generated = datetime.strptime(str(doc.get("generated_at") or ""), "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc)
    except ValueError as exc:
        raise SourceMissing(f"the approval-hold scan {bands_path} has no readable generated_at") from exc
    if generated > now + timedelta(minutes=5) or now - generated > timedelta(hours=max_age_h):
        raise SourceMissing(f"the approval-hold scan {bands_path} is stale or future-dated ({doc.get('generated_at')})")
    return {str(uid) for uid, row in doc["users"].items()
            if isinstance(row, dict) and str(row.get("decision") or "") == "hold"}


def legal_users(api: Callable[..., tuple[int, dict]], *, tags: tuple[str, ...] = LEGAL_TAGS) -> set[str]:
    """Users in an Intercom conversation tagged legal (774: read the tags at build time).

    GET /tags names the tag ids; POST /conversations/search filtered on `tag_ids` returns those
    conversations (the documented conversation-search field is `tag_ids`, and a successful search
    answers with a `conversations` array - not the `data` array the contact search uses); each
    conversation's contacts carry the external_id the send gate matches on (the account's
    professional id or Auth0 subject). Everything is returned lowercased; a failed read raises."""
    def call(method: str, path: str, body: Any = None) -> tuple[int, dict]:
        return api(method, path, body)

    status, res = call("GET", "/tags")
    if status != 200 or not isinstance(res.get("data"), list):
        raise SourceMissing(f"Intercom tags cannot be listed (HTTP {status})")
    wanted = sorted({str(t.get("id")) for t in res["data"]
                     if isinstance(t, dict) and str(t.get("name") or "").strip().lower() in tags})
    out: set[str] = set()
    for tag_id in wanted:
        cursor = None
        for _ in range(20):
            body: dict[str, Any] = {"query": {"field": "tag_ids", "operator": "=", "value": tag_id},
                                    "pagination": {"per_page": 50}}
            if cursor:
                body["pagination"]["starting_after"] = cursor
            status, found = call("POST", "/conversations/search", body)
            if status != 200 or not isinstance(found.get("conversations"), list):
                raise SourceMissing(f"Intercom conversation search for tag {tag_id} failed (HTTP {status})")
            for conv in found["conversations"]:
                if not isinstance(conv, dict):
                    continue
                for c in ((conv.get("contacts") or {}).get("contacts") or []):
                    for key in ("external_id", "id"):
                        if isinstance(c, dict) and c.get(key):
                            out.add(str(c[key]).strip().lower())
            cursor = ((found.get("pages") or {}).get("next") or {}).get("starting_after")
            if not cursor:
                break
        else:
            raise SourceMissing(f"Intercom conversation search for tag {tag_id} did not finish in 20 pages")
    return out


def org_seats(cands: list[dict[str, Any]], pids: dict[int, str], query: Callable[[str], list]) -> set[str]:
    """774: users with a row in core's org seats - team_users membership (by user id) or an active
    roster seat (by professional id). Both are returned as strings, the pids lowercased."""
    out: set[str] = set()
    ids = [int(c["user_id"]) for c in cands]
    for i in range(0, len(ids), 500):
        chunk = ids[i:i + 500]
        lit = ", ".join(str(u) for u in chunk)
        for (uid,) in query("SELECT DISTINCT CAST(userid AS varchar) FROM postgresql_core.public.team_users "
                            f"WHERE userid IN ({lit})"):
            out.add(str(uid))
    plist = sorted({p.lower() for p in pids.values() if p})
    for i in range(0, len(plist), 500):
        chunk = plist[i:i + 500]
        lit = ", ".join("'" + p.replace("'", "") + "'" for p in chunk)
        for (pid,) in query("SELECT DISTINCT lower(CAST(seatid AS varchar)) FROM postgresql_core.public.roster_seats "
                            "WHERE status IN ('active', 'paused') "
                            f"AND lower(CAST(seatid AS varchar)) IN ({lit})"):
            out.add(str(pid).lower())
    return out


# -- the build ---------------------------------------------------------------------------------------

def build(*, plan_dir: str, segment: str, ledger_path: str, bands_path: str,
          query: Callable[[str], list] | None, api: Callable[..., tuple[int, dict]] | None,
          now: datetime | None = None, wait_days: int = WAIT_DAYS, cap: int = FULL_CAP
          ) -> tuple[list[dict[str, Any]], dict[str, int]]:
    """Return (the audience in send order, a count per exclusion). Raises SourceMissing."""
    now = now or datetime.now(timezone.utc)
    rows = plan_rows(plan_dir)
    segs = segment_flags(plan_dir)
    contact = LedgerContact(ledger_path, now=now)
    holds = approval_holds(bands_path, now=now)
    if api is None:
        raise SourceMissing("the Intercom legal-tag source is not wired (no API client): refusing to build")
    legal = legal_users(api)
    if query is None:
        raise SourceMissing("the org-seat source is not wired (no replica query): refusing to build")

    counts: dict[str, int] = {}

    def bump(why: str) -> None:
        counts[why] = counts.get(why, 0) + 1

    paid_want = segment == "paid"
    wait_bar = (now - timedelta(days=wait_days)).strftime("%Y-%m-%d")
    cands: list[dict[str, Any]] = []
    for r in rows:
        if r.get("user_id") is None:
            continue
        uid = str(r["user_id"])
        if bool(r.get("paid")) is not paid_want:
            bump("other segment")
            continue
        oldest = str(r.get("oldest_pending") or "")[:10]
        if not oldest or oldest > wait_bar:
            bump("still inside the wait bar")
            continue
        why = held_by_the_pipeline(segs.get(uid))
        if why:
            bump(why)
            continue
        if contact.recent(uid):
            bump("messaged in the last 7 days")
            continue
        if contact.ever_apologised(uid):
            bump("already apologised (one per user, ever)")
            continue
        if uid in holds:
            bump("approval hold (774: any hold is excluded)")
            continue
        cands.append(r)
    contact.close()

    pids: dict[int, str] = {}
    auths: dict[int, str] = {}
    ids = sorted({int(c["user_id"]) for c in cands})
    for i in range(0, len(ids), 500):
        chunk = ids[i:i + 500]
        lit = ", ".join(str(u) for u in chunk)
        for uid, pro, auth in query("SELECT CAST(id AS varchar), lower(CAST(neptuneprofessionalid AS varchar)), "
                                    "lower(CAST(auth0userid AS varchar)) "
                                    "FROM postgresql_core.public.users " f"WHERE id IN ({lit})"):
            if pro:
                pids[int(uid)] = str(pro)
            if auth:
                auths[int(uid)] = str(auth)
    # QA #1788 finding 4: the legal-tag set holds Intercom external_id / contact ids, which are the account's
    # professional id or Auth0 subject - NOT its numeric user id. Comparing only the numeric id let a contact tagged
    # legal with external_id=pro41 through for user 41. Every identity form the send gate matches on is checked, and
    # the numeric id is still checked (a contact whose external_id IS the numeric id).
    legal_hit: set[int] = set()
    for c in cands:
        u = int(c["user_id"])
        forms = {str(u), pids.get(u, ""), auths.get(u, "")}
        if any(f and f.lower() in legal for f in forms):
            legal_hit.add(u)
    if legal_hit:
        kept = []
        for c in cands:
            if int(c["user_id"]) in legal_hit:
                bump("legal tag in Intercom (774)")
                continue
            kept.append(c)
        cands = kept
    seats = org_seats(cands, pids, query)

    audience: list[dict[str, Any]] = []
    # The tick owns the batch size (its shared FIRST_CAP / FULL_CAP_FROM machinery); this is a ceiling
    # so a mis-set plan can never hand the sender a thousand users in one go.
    limit = max(0, int(cap))
    for r in cands:
        uid = int(r["user_id"])
        pro = pids.get(uid, "")
        if str(uid) in seats or (pro and pro.lower() in seats):
            bump("org seat (774: never cold-emailed)")
            continue
        if len(audience) >= limit:
            bump("over this batch's cap")
            continue
        audience.append({"user_id": uid, "paid": bool(r.get("paid")), "skip": None,
                         "request_ids": [str(x) for x in (r.get("request_ids") or [])]})
    return audience, counts


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="build the wait-apology audience (inert unless every exclusion loads)")
    ap.add_argument("--plan-dir", required=True, help="a paid-status segment run dir (/var/lib/hydra/paid-status/<day>/<segment>)")
    ap.add_argument("--segment", default="paid", choices=("paid", "free"))
    ap.add_argument("--out", default="")
    ap.add_argument("--ledger", default=DEFAULT_LEDGER)
    ap.add_argument("--bands", default=comm_state.ACCOUNT_BANDS,
                    help="the fraud lens's current scan (default: comm_state.ACCOUNT_BANDS, the file R8 reads)")
    ap.add_argument("--cap", type=int, default=FULL_CAP, help="the most this list may carry (the tick sends fewer)")
    ap.add_argument("--wait-days", type=int, default=WAIT_DAYS)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)
    if not args.out and not args.dry_run:
        ap.error("--out is required unless --dry-run")

    api = None
    query = None
    try:
        from credit_review.verify_notify import trino as _query  # noqa: PLC0415  (the same replica seam every runner uses)
        query = _query
    except Exception:  # noqa: BLE001 - no replica seam: the build refuses (SourceMissing) rather than guess
        query = None
    try:
        from credit_review.intercom_reconcile import intercom_api  # noqa: PLC0415
        api = intercom_api()
    except Exception:  # noqa: BLE001 - no token: the build refuses, it does not exclude nobody
        api = None
    try:
        audience, counts = build(plan_dir=args.plan_dir, segment=args.segment, ledger_path=args.ledger,
                                 bands_path=args.bands, query=query, api=api, wait_days=args.wait_days,
                                 cap=args.cap)
    except SourceMissing as exc:
        print(f"INERT: {exc}", file=sys.stderr)
        return 2
    if args.dry_run:
        print(json.dumps({"would_send": len(audience), "excluded": counts}, indent=1))
        return 0
    doc = {"generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "source": f"wait-apology audience from {args.plan_dir} ({args.segment})",
           "campaign": CAMPAIGN, "users": audience}
    tmp = args.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1)
    os.replace(tmp, args.out)
    print(json.dumps({"users": len(audience), "excluded": counts}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
