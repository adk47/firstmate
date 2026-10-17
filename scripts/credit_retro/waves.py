"""Prepare (never send) the credit-retro r1 documentation-request waves.

Captain, 2026-10-15 ~23:35Z (via firstmate 002): Nick's automated approvals (the agent
batch, 09-01 -> 10-11) were trust-yet-verify; ask for documents. Narrowed 2026-10-16
~00:35Z (via firstmate 005): "how many credits were approved without documentstion i
dont want to lose users unless its obvious fraud feom tbe past". So for these PAST
credits the ask is friendly: no removal threat, no deadline language. A valid document
raises trust; silence leaves the credit on the profile, flagged unverified internally
(board / valuation basis). Only obvious, evidence-backed fraud is removed (the take-back
of proven one-person roles). Nothing here ever removes a credit.

Captain standing order (013): "make sure you arent asking for things from users that
already submitted documents and we approved. dont piss anyoen off". Nobody in
``manifests/doc-submitted-r1.json`` (an Intercom attachment in any conversation, or an
identity/upload document in the verifications table, approved or pending) is ever asked,
and no request a human (jan@/nick@) approved is asked about. When in doubt, don't send.

Firstmate 016: the take-back notice ``apply`` sends is a removed user's ONLY message. A
user with a ``sent`` take-back notice in any apply run is in no wave for 30 days after it
(NOTICE_QUIET_DAYS), and a user still owed a notice is in none either. No wave ever
restates a removal: a removed role is never listed or asked about again.

One payload file per USER, in exactly one wave:

  W-01..W-nn  ``per_day`` users a day from FIRST_SEND, ordered paid first, then by the
              user's biggest track, then by credit count

The payload is the ``--credits-file`` shape of scripts/intercom-verify-request.sh
(``user`` + ``credits[]``) plus grouped sections, the template, the reason-line class
and the silence rule. It is the user's one past-credit message: no follow-up is scheduled
(the send-time check drops anyone already asked). Nothing here posts anything.
"""

from __future__ import annotations

import gzip
import json
import os
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

from credit_review.roles import family_of

from .api import ApiError, ReadApi
from .ledger import Ledger, sha256_file
from .takeback import require_fresh, unnotified_row_ids

FIRST_SEND = date(2026, 10, 16)
PER_DAY = 200            # users per day; the send tool rate-limits within the day
UNVERIFIED_AFTER_DAYS = 30  # internal flag only: no proof by then -> "unverified" on the board
MAX_CREDITS = 200        # intercom-verify-request.sh MAX_CREDITS per message
TEMPLATE = "retro-verify-grouped"
SEND_CAMPAIGN = "retro-past"  # the send tool's past-credit campaign (credit_review/verify_ledger.py CAMPAIGNS)
VERIFY_LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"  # Caroline send ledger, read-only
NOTICE_QUIET_DAYS = 30  # firstmate 016: no wave for a user within 30 days of their take-back notice
PROOF_CHANNEL = "intercom (reply with attachments); email channel when E-IN lands"
ON_SILENCE = ("credit stays on the profile; flagged unverified internally (board / valuation basis); "
              "never removed for silence (captain 2026-10-16 ~00:35Z)")
APPROVAL_REF = ("captain 2026-10-15 ~23:35Z via firstmate 002 (ask for documents on Nick's trust-yet-verify "
                "approvals), narrowed 2026-10-16 ~00:35Z via firstmate 005 (past credits: friendly ask, no removal); "
                "sends need intercom-verify-request.sh (credit-trust-caroline-t06) and a GO")
CONTRADICTION_VERDICTS = {"CONTRADICTED_one", "CONTRADICTED_multi"}
DOC_SUBMITTED = Path(__file__).resolve().parent / "manifests" / "doc-submitted-r1.json"

GROUP_BY_FAMILY = {
    "mix": "mixing-mastering", "master": "mixing-mastering", "immersive_mix": "mixing-mastering",
    "immersive_master": "mixing-mastering", "remaster": "mixing-mastering",
    "writer": "writer-composer",
    "producer": "producer", "exec_producer": "producer",
    "engineer": "engineer-assistant", "assistant": "engineer-assistant",
}
GROUP_ORDER = ["mixing-mastering", "producer", "writer-composer", "engineer-assistant", "musician"]


def load_jsonl(path: str | Path) -> list[dict[str, Any]]:
    opener = gzip.open if str(path).endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def load_doc_submitted(path: str | Path = DOC_SUBMITTED) -> tuple[set[str], set[str]]:
    """(user ids who already submitted a document/proof, request ids a human approved)."""
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    return _doc_sets(doc)


def _doc_sets(doc: dict[str, Any]) -> tuple[set[str], set[str]]:
    return {str(u) for u in doc["users_doc_submitted"]}, {str(r) for r in doc["human_approved_requests"]}


def load_fresh_doc_submitted(path: str | Path, now: datetime) -> tuple[set[str], set[str]]:
    """``load_doc_submitted`` for send time: the list must say when it was built
    (``generated_at``) and pass ``takeback.require_fresh``. A document a user attached after the
    list was built (untagged, so not in the send ledger) is in no other source, so an older
    list, or one with no ``generated_at`` (the committed r1 snapshot), cannot clear a send."""
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    try:
        require_fresh(doc["generated_at"], now)
    except ValueError as exc:
        raise ValueError(f"{path}: {exc}; rebuild the doc-submitted list before sending") from exc
    return _doc_sets(doc)


def group_of(role: str) -> str:
    return GROUP_BY_FAMILY.get(family_of(role), "musician")


def _credit(row: dict[str, Any], role: str, kind: str, verdict: str | None = None) -> dict[str, Any]:
    return {"request_id": row["request_id"], "role": role, "track_title": row.get("track_title") or "",
            "artist_name": row.get("artist") or "", "pop_now": row.get("pop_now"), "kind": kind,
            "catalog_verdict": verdict}


def merge_unremoved(population: list[dict[str, Any]], takeback_rows: list[dict[str, Any]],
                    removed_ids: set[str]) -> list[dict[str, Any]]:
    """A take-back row that was NOT removed (gate skip, refusal, revert, or no
    apply yet) is never dropped: its role joins the verify population."""
    by_req = {h["request_id"]: {**h, "roles": list(h["roles"]), "sources": list(h["sources"])} for h in population}
    for r in takeback_rows:
        if r["row_id"] in removed_ids or str(r["user_id"]) == "15":
            continue
        h = by_req.setdefault(r["request_id"], {
            "request_id": r["request_id"], "user_id": r["user_id"], "profile_id": r["profile_id"],
            "track_id": r["track_id"], "track_title": r.get("track_title"), "artist": r.get("artist"),
            "pop_now": r.get("pop_now"), "paying": r.get("paying"), "tier": "TAKEBACK_NOT_REMOVED",
            "sources": [], "roles": [], "takeback_residual": True})
        if "TB" not in h["sources"]:
            h["sources"].append("TB")
        if all(x["role"] != r["role"] for x in h["roles"]):
            h["roles"].append({"role": r["role"], "verdict": "CONTRADICTED_one", "web": "CONTRADICTED"})
    return sorted(by_req.values(), key=lambda h: h["request_id"])


ASK_TIERS = frozenset({"HOLD", "A_HOLD", "TAKEBACK_NOT_REMOVED"})
EDITING_ROLES = frozenset({"Editorial", "Assembly"})
EDITING_MIN_POP = 30       # "mid/big" track for an unverifiable editing claim
ACCOUNT_TEMPLATE = "account-three-tracks"


def select(population: list[dict[str, Any]], watch: list[dict[str, Any]], editing_ask: dict[str, Any] | None, *,
           editing_min_pop: int = EDITING_MIN_POP, doc: tuple[set[str], set[str]] | None = None,
           ) -> tuple[list[dict[str, Any]], dict[str, list[dict[str, Any]]], list[dict[str, Any]]]:
    """Firstmate 006 (captain ~02:00Z "are you annoying people fornbackup that we shpuldnt be?"):
    ask only GENUINE risk. Returns (asked request rows, account asks by user, not-asked rows).

    Asked, per row: Part A HOLD, Part C HOLD (incl. the unproven roles of take-back
    requests), take-back roles not removed, and editing claims that a trusted source credits
    to someone else (any track) or that are unverifiable on a track of popularity >=
    ``editing_min_pop`` (only their Editorial/Assembly roles).
    Asked once per ACCOUNT: the WATCH velocity accounts and the editing burst accounts whose
    whole-profile review did not clear them; their burst rows are not listed one by one.
    Everyone else (small unverifiable claims, established / web-credible / confirmed claimants,
    ordinary small accounts) is NOT asked: flagged unverified internally only.

    ``doc`` = (users who already submitted documents, human-approved request ids): captain
    013, those users get no ask at all and those requests are never asked about."""
    doc_users, doc_requests = doc or (set(), set())
    accounts: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for w in watch:
        if str(w["user_id"]) in doc_users:
            continue
        accounts[w["user_id"]].append({"kind": "velocity", "rows": w["velocity_rows"], "paying": bool(w.get("paying")),
                                       "peak_per_day": w["max_requests_per_day"], "first": w["first_request"],
                                       "profile_ids": w["profile_ids"], "example_tracks": w["example_tracks"]})
    editing_rows: dict[str, dict[str, Any]] = {}
    if editing_ask:
        for a in editing_ask.get("accounts", []):
            if a.get("ask") and str(a["user_id"]) not in doc_users:
                accounts[a["user_id"]].append({"kind": "editing_burst", "rows": a["editing_rows"],
                                               "paying": bool(a.get("paying")),
                                               "peak_per_day": a["peak_per_day"], "first": a["first"],
                                               "profile_ids": a["profile_ids"], "review": a["review"],
                                               "example_tracks": a["example_tracks"]})
        for r in editing_ask.get("rows", []):
            if r["verdict"] == "CONTRADICTED" or int(r.get("pop_now") or 0) >= editing_min_pop:
                editing_rows[r["request_id"]] = r
    asked, not_asked = [], []
    for h in population:
        if str(h["user_id"]) in doc_users or h["request_id"] in doc_requests:
            not_asked.append(h)
            continue
        if h.get("tier") in ASK_TIERS:
            asked.append(h)
            continue
        e = editing_rows.get(h["request_id"])
        if e is not None and h["user_id"] not in accounts:
            roles = [x for x in h["roles"] if x["role"] in EDITING_ROLES]
            if roles:
                verdict = "CONTRADICTED_multi" if e["verdict"] == "CONTRADICTED" else "UNVERIFIABLE"
                asked.append({**h, "roles": [{**x, "verdict": verdict} for x in roles]})
                rest = [x for x in h["roles"] if x["role"] not in EDITING_ROLES]
                if rest:
                    not_asked.append({**h, "roles": rest})
                continue
        not_asked.append(h)
    return asked, dict(accounts), not_asked


def assemble(population: list[dict[str, Any]], watch: list[dict[str, Any]],
             editing_ask: dict[str, Any] | None = None, *, editing_min_pop: int = EDITING_MIN_POP,
             per_day: int = PER_DAY, first_send: date = FIRST_SEND,
             doc: tuple[set[str], set[str]] | None = None) -> list[dict[str, Any]]:
    """Pure: at most ONE payload per user, waves assigned. ``doc``: see ``select``."""
    asked, accounts, _ = select(population, watch, editing_ask, editing_min_pop=editing_min_pop, doc=doc)
    by_user: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for h in asked:
        by_user[h["user_id"]].append(h)

    def payload(uid: str) -> dict[str, Any]:
        rows = sorted(by_user.get(uid, []), key=lambda h: (-int(h.get("pop_now") or 0), h["request_id"]))
        verify = [_credit(h, x["role"], "verify", x.get("verdict")) for h in rows for x in h["roles"]]
        acct = accounts.get(uid, [])
        groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for c in verify:
            groups[group_of(c["role"])].append(c)
        if verify:
            template, kind = TEMPLATE, "verify"
        else:
            template, kind = ACCOUNT_TEMPLATE, acct[0]["kind"]
        p: dict[str, Any] = {
            "schema": "credit-retro-wave.v3", "status": "prepared_not_sent", "kind": kind,
            "user": {"id": uid, "email": None, "first_name": None},
            "paying": any(h.get("paying") for h in rows) or any(a.get("paying") for a in acct),
            "template": template,
            "groups": [{"group": g, "credits": groups[g]} for g in GROUP_ORDER if g in groups],
            # velocity / editing-burst: ONE ask for the whole burst, three tracks of their choice
            "account_asks": acct,
            "tiers": sorted({h.get("tier") or "" for h in rows}),
            "send_campaign": SEND_CAMPAIGN, "removal_threat": False, "deadline_language": False,
            "proof_channel": PROOF_CHANNEL, "on_silence": ON_SILENCE, "proof_effect": "raises trust (verified)",
            "credits_stay_visible": True, "approval_ref": APPROVAL_REF,
        }
        flat = [c for g in p["groups"] for c in g["credits"]]
        p["credits_total"] = len(flat)
        p["request_ids_all"] = sorted({c["request_id"] for c in flat})
        # the send tool's per-message cap; biggest tracks first so the cut drops the smallest
        p["credits"] = sorted(flat, key=lambda c: -int(c.get("pop_now") or 0))[:MAX_CREDITS]
        p["more_credits"] = max(0, len(flat) - MAX_CREDITS)
        pops = [int(c.get("pop_now") or 0) for c in flat] + [
            int(t.get("pop_now") or 0) for a in acct for t in a["example_tracks"]]
        p["max_pop"] = max(pops, default=0)
        p["big_track"] = p["max_pop"] >= 60
        p["reason_line"] = ("trusted_contradiction"
                            if any(c.get("catalog_verdict") in CONTRADICTION_VERDICTS for c in flat)
                            else "no_public_data")
        return p

    payloads = [payload(u) for u in sorted(set(by_user) | set(accounts))]
    payloads.sort(key=lambda p: (not p["paying"], -p["max_pop"], -p["credits_total"], p["user"]["id"]))
    for i, p in enumerate(payloads):
        p["wave"], p["day"] = f"W-{i // per_day + 1:02d}", i // per_day
    for p in payloads:
        send = first_send + timedelta(days=p.pop("day"))
        p["send_not_before"] = send.isoformat()
        p["flag_unverified_after"] = (send + timedelta(days=UNVERIFIED_AFTER_DAYS)).isoformat()
    return payloads


def already_engaged(verify_db: str | None) -> tuple[set[str], set[str], set[str]] | None:
    """From the Caroline send ledger: (request ids on a note with proof, account keys
    (lower-cased email) that already sent proof, account keys already sent a retro ask).
    Never re-ask someone who sent proof; at most one past-credit message per user.
    Returns None when the ledger is not available: then nothing can be proven safe to
    send, and prepare() marks every payload not sendable (it never fails open)."""
    if not verify_db or not os.path.exists(verify_db):
        return None
    import sqlite3  # noqa: PLC0415
    db = sqlite3.connect(f"file:{verify_db}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    try:
        cols = {r["name"] for r in db.execute("PRAGMA table_info(verify_messages)")}
        if not {"request_ids_json", "proof_tagged_at", "user_key", "campaign", "status", "kind"} <= cols:
            raise SystemExit(f"{verify_db}: verify_messages lacks the columns needed to avoid re-asking; refusing")
        proof_ids: set[str] = set()
        proof_users: set[str] = set()
        asked_users: set[str] = set()
        for r in db.execute("SELECT * FROM verify_messages"):
            if r["proof_tagged_at"]:
                proof_ids.update(str(i) for i in json.loads(r["request_ids_json"] or "[]"))
                proof_users.add(str(r["user_key"] or "").lower())
            if r["campaign"] == SEND_CAMPAIGN and r["kind"] == "initial" and r["status"] in ("sent", "attempted"):
                asked_users.add(str(r["user_key"] or "").lower())
        return proof_ids, proof_users, asked_users
    finally:
        db.close()


def resolve_live(api: ReadApi, payload: dict[str, Any], profiles: set[str]) -> None:
    """Fill the account email / first name from the credit requests themselves
    (never from anything a user wrote), refresh titles, and drop credits that are
    no longer approved. Mutates ``payload``."""
    uid = payload["user"]["id"]
    approved: dict[str, dict[str, Any]] = {}
    try:
        for chunk in range(0, len(sorted(profiles)), 20):
            ids = sorted(profiles)[chunk:chunk + 20]
            for page in range(1, 51):
                data = api.get("/admin/credit-requests", {"profilesIds": ",".join(ids), "status": "approved",
                                                          "limit": 200, "page": page})
                items = data.get("items") if isinstance(data, dict) else None
                if not isinstance(items, list):
                    raise ApiError("credit-requests list has no items[]")
                approved.update({str(it["id"]): it for it in items if str(it.get("userId")) == uid})
                if len(items) < 200:
                    break
    except ApiError as exc:
        # unchecked against today's approvals: never sendable as prepared
        payload["live"] = {"error": str(exc)}
        payload["status"] = "live_read_error"
        return
    user = next((it.get("user") for it in approved.values() if isinstance(it.get("user"), dict)), None)
    if user:
        payload["user"]["email"] = user.get("email")
        payload["user"]["first_name"] = (str(user.get("fullName") or "").split() or [None])[0]

    def keep(c: dict[str, Any]) -> bool:
        it = approved.get(c["request_id"])
        if it is None:
            return False
        c["track_title"] = it.get("spotifyTrackTitle") or c["track_title"]
        artists = [a.get("name") for a in (it.get("spotifyTrackArtists") or []) if isinstance(a, dict)]
        c["artist_name"] = ", ".join(a for a in artists if a) or c["artist_name"]
        return True

    before = payload["credits_total"]
    _keep_credits(payload, keep)
    payload["live"] = {"dropped_not_approved": before - payload["credits_total"],
                       "email_resolved": bool(payload["user"]["email"])}
    if not payload["credits_total"] and not payload.get("account_asks"):
        payload["status"] = "nothing_to_send"


def _keep_credits(payload: dict[str, Any], keep: Callable[[dict[str, Any]], bool]) -> None:
    """Keep only the credits ``keep`` accepts and refresh the derived lists. Mutates ``payload``."""
    for g in payload["groups"]:
        g["credits"] = [c for c in g["credits"] if keep(c)]
    payload["groups"] = [g for g in payload["groups"] if g["credits"]]
    flat = [c for g in payload["groups"] for c in g["credits"]]
    payload["credits_total"] = len(flat)
    payload["request_ids_all"] = sorted({c["request_id"] for c in flat})
    payload["credits"] = sorted(flat, key=lambda c: -int(c.get("pop_now") or 0))[:MAX_CREDITS]
    payload["more_credits"] = max(0, len(flat) - MAX_CREDITS)


def quiet_users(ledger: Ledger, apply_runs: list[str], now: datetime) -> set[str]:
    """Firstmate 016: users who got a ``sent`` take-back notice within NOTICE_QUIET_DAYS of
    ``now`` (any apply run), plus users ``apply_runs`` removed a role from and still owe a
    notice. The notice is their only message."""
    since = (now - timedelta(days=NOTICE_QUIET_DAYS)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    return ledger.takeback_notified(since) | {e["user_id"] for r in apply_runs for e in ledger.removed_rows(r)
                                               if e["row_id"] in unnotified_row_ids(ledger, r)}


class SendStateUnavailable(Exception):
    """The credit-retro ledger or the send ledger cannot be read, or the doc-submitted list
    is unreadable or not fresh: nothing can be proven safe to send."""


def send_state(ledger: Ledger, *, verify_db: str | None, now: datetime,
               doc_submitted_path: str | Path = DOC_SUBMITTED) -> dict[str, Any]:
    """Everything ``send_check`` re-checks, read once at send time. The doc-submitted list
    must be fresh (``load_fresh_doc_submitted``)."""
    try:
        engaged = already_engaged(verify_db)
        doc_users, doc_requests = load_fresh_doc_submitted(doc_submitted_path, now)
    except (SystemExit, OSError, ValueError, KeyError, TypeError) as exc:
        raise SendStateUnavailable(str(exc)) from exc
    if engaged is None:
        raise SendStateUnavailable(f"send ledger {verify_db} is not readable")
    proof_ids, proof_users, asked_users = engaged
    runs = ledger.apply_runs()
    removed: set[tuple[str, str]] = set()
    for r in runs:
        reverted = ledger.reverted_row_ids(r)
        removed |= {(e["request_id"], e["role"].strip().lower()) for e in ledger.removed_rows(r)
                    if e["row_id"] not in reverted}
    return {"quiet": quiet_users(ledger, runs, now), "doc_users": doc_users,
            "skip_requests": proof_ids | doc_requests, "proof_users": proof_users, "asked_users": asked_users,
            "removed": removed}


def send_check(state: dict[str, Any], payload: dict[str, Any]) -> tuple[str, str]:
    """Firstmate 018, the mandatory last step before any wave send: (``send`` | ``drop``,
    reason). Re-checks the take-back quiet window, proof on file, human-approved requests and
    one past-credit message per user, and filters the credits list (proof-covered,
    human-approved and removed roles go). Mutates ``payload``."""
    uid = str(payload["user"]["id"])
    key = str(payload["user"].get("email") or "").lower()
    if payload.get("status") != "prepared_not_sent":
        return "drop", f"status:{payload.get('status')}"
    if uid in state["quiet"]:
        return "drop", "takeback_notice_quiet_window"
    if uid in state["doc_users"]:
        return "drop", "doc_submitted"
    if not key:
        return "drop", "no_account_email"
    if key in state["proof_users"]:
        return "drop", "already_sent_proof"
    if key in state["asked_users"]:
        return "drop", "already_asked"
    _keep_credits(payload, lambda c: c["request_id"] not in state["skip_requests"]
                  and (c["request_id"], c["role"].strip().lower()) not in state["removed"])
    if not payload["credits_total"] and not payload.get("account_asks"):
        return "drop", "nothing_left_to_ask"
    return "send", "ok"


def send_check_file(state: dict[str, Any], path: str | Path) -> tuple[str, str]:
    """``send_check`` one payload file and write it back in place: the filtered credits when it
    may be sent, ``status: dropped_at_send_check`` with the reason when it may not."""
    with open(path, encoding="utf-8") as fh:
        payload = json.load(fh)
    verdict, reason = send_check(state, payload)
    if verdict == "drop":
        payload["status"] = "dropped_at_send_check"
    payload["send_check"] = {"verdict": verdict, "reason": reason,
                             "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1, sort_keys=True)
    return verdict, reason


def prepare(ledger: Ledger, *, population_path: str, watch_path: str, takeback_path: str, apply_run: str | None,
            out_root: Path, argv: list[str], actor: str, api: ReadApi | None = None, per_day: int = PER_DAY,
            editing_ask_path: str | None = None, editing_min_pop: int = EDITING_MIN_POP,
            verify_db: str | None = None, doc_submitted_path: str | Path = DOC_SUBMITTED,
            now: datetime | None = None, log: Callable[[str], None] = print) -> tuple[str, dict[str, Any]]:
    watch = load_jsonl(watch_path)
    editing_ask = None
    if editing_ask_path:
        with open(editing_ask_path, encoding="utf-8") as fh:
            editing_ask = json.load(fh)
    engaged = already_engaged(verify_db)
    ledger_missing = engaged is None
    proof_ids, proof_users, asked_users = engaged if engaged is not None else (set(), set(), set())
    if apply_run:
        run = ledger.run(apply_run)
        if run is None or run["kind"] != "apply":
            raise SystemExit(f"{apply_run}: not an apply run")
        takeback_path = run["manifest"]
        if sha256_file(takeback_path) != run["manifest_sha256"]:
            raise SystemExit(f"{takeback_path}: changed since {apply_run}; refusing")
    # every apply run on this manifest (canary, full run, re-runs after a stop): never re-ask a removed role
    apply_runs, removed_ids = ledger.removed_on_manifest(sha256_file(takeback_path))
    unresolved = {r: [e["row_id"] for e in rows] for r in apply_runs if (rows := ledger.unresolved_rows(r))}
    unresolved_re = {r: [e["row_id"] for e in rows] for r in apply_runs if (rows := ledger.unresolved_reverts(r))}
    if unresolved or unresolved_re:
        raise SystemExit(f"results unknown: DELETE {unresolved}, re-add {unresolved_re}: run "
                         "`readback --run <apply_run>` first")
    population = merge_unremoved(load_jsonl(population_path), load_jsonl(takeback_path), removed_ids)
    # a request already covered by submitted proof is never asked again
    population = [h for h in population if h["request_id"] not in proof_ids]
    # firstmate 016: the take-back notice is a removed user's only message (and one still owed it gets nothing first)
    quiet = quiet_users(ledger, apply_runs, now or datetime.now(timezone.utc))
    doc = load_doc_submitted(doc_submitted_path)
    before = assemble(population, watch, editing_ask, editing_min_pop=editing_min_pop, per_day=per_day,
                      doc=(quiet, set()))
    payloads = assemble(population, watch, editing_ask, editing_min_pop=editing_min_pop, per_day=per_day,
                        doc=(doc[0] | quiet, doc[1]))
    asked_ids = {i for p in payloads for i in p["request_ids_all"]}
    run_id = ledger.start_run(kind="prepare-waves", actor=actor, manifest=population_path, parent_run=apply_run,
                              argv=argv)
    out = out_root / run_id
    out.mkdir(parents=True, exist_ok=False)
    os.chmod(out, 0o700)
    profiles: dict[str, set[str]] = defaultdict(set)
    for h in population:
        profiles[h["user_id"]].add(h["profile_id"])
    for a in (editing_ask or {}).get("accounts", []):
        profiles[a["user_id"]].update(a["profile_ids"])
    for w in watch:
        profiles[w["user_id"]].update(w["profile_ids"])
    index: dict[str, Any] = {"run_id": run_id, "apply_runs": apply_runs, "status": "prepared_not_sent",
                             "send_campaign": SEND_CAMPAIGN, "removal": "never for silence (past credits)",
                             "on_silence": ON_SILENCE, "editing_min_pop": editing_min_pop,
                             "send_ledger": verify_db if not ledger_missing else f"UNAVAILABLE ({verify_db})",
                             "takeback_notice_quiet_users": len(quiet),
                             "doc_submitted": {
                                 "source": str(doc_submitted_path), "users": len(doc[0]),
                                 "human_approved_requests": len(doc[1]),
                                 "before": {"users": len(before), "paying_users": sum(int(p["paying"]) for p in before)},
                                 "after": {"users": len(payloads),
                                           "paying_users": sum(int(p["paying"]) for p in payloads)}},
                             "waves": {}}
    for n, p in enumerate(payloads, 1):
        if api is not None:
            resolve_live(api, p, profiles[p["user"]["id"]])
            key = str(p["user"].get("email") or "").lower()
            if key and key in proof_users:
                p["status"] = "skip_already_sent_proof"
            elif key and key in asked_users:
                p["status"] = "skip_already_asked"
            if n % 100 == 0:
                log(f"... {n}/{len(payloads)} users read live")
        if ledger_missing and p["status"] == "prepared_not_sent":
            # without the send ledger nobody can be proven not to have sent proof or been asked
            p["status"] = "send_ledger_unavailable"
        wdir = out / p["wave"]
        wdir.mkdir(exist_ok=True)
        fpath = wdir / f"user-{p['user']['id']}.json"
        fd = os.open(fpath, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(p, fh, ensure_ascii=False, indent=1, sort_keys=True)
        w = index["waves"].setdefault(p["wave"], {"send_not_before": p["send_not_before"],
                                                  "users": 0, "paying_users": 0, "credits": 0, "big_track_users": 0,
                                                  "account_asks": 0, "not_sendable": 0})
        w["users"] += 1
        w["account_asks"] += len(p["account_asks"])
        w["paying_users"] += int(p["paying"])
        w["credits"] += p["credits_total"]
        w["big_track_users"] += int(p["big_track"])
        w["not_sendable"] += int(p["status"] != "prepared_not_sent")
        ledger.event(run_id, actor, row_id=f"user:{p['user']['id']}", user_id=p["user"]["id"], action="prepare",
                     outcome=p["status"], after={"wave": p["wave"], "template": p["template"],
                                                 "credits_total": p["credits_total"], "file": str(fpath)},
                     reason=p["kind"])
    # Everyone not asked is left alone: flagged unverified internally only (board / valuation basis).
    flagged = 0
    fd = os.open(out / "unverified-internal.jsonl", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        for h in population:
            if h["request_id"] in asked_ids:
                continue
            fh.write(json.dumps({"request_id": h["request_id"], "user_id": h["user_id"], "tier": h.get("tier"),
                                 "roles": [x["role"] for x in h["roles"]], "flag": "unverified"}) + "\n")
            flagged += 1
    sendable = [p for p in payloads if p["status"] == "prepared_not_sent"]
    index["not_asked_flagged_internal_requests"] = flagged
    index["not_asked_flagged_internal_users"] = len({h["user_id"] for h in population}
                                                    - {p["user"]["id"] for p in payloads})
    with open(out / "index.json", "w", encoding="utf-8") as fh:
        json.dump(index, fh, indent=1, sort_keys=True)
    counts = {"users": len(payloads), "sendable_users": len(sendable),
              "credits": sum(p["credits_total"] for p in payloads),
              "account_asks": sum(len(p["account_asks"]) for p in payloads),
              "paying_users": sum(int(p["paying"]) for p in payloads), "waves": len(index["waves"]),
              "flagged_internal_requests": flagged}
    ledger.finish_run(run_id, counts)
    log(json.dumps(index["waves"], indent=1, sort_keys=True))
    log(f"prepared {len(payloads)} user payloads in {out} (NOT sent)")
    return run_id, index

