"""Prepare (never send) the credit-retro r1 documentation-request waves.

Captain, 2026-10-15 ~23:35Z (via firstmate 002): Nick's automated approvals (the agent
batch, 09-01 -> 10-11) were trust-yet-verify; ask for documents. Narrowed 2026-10-16
~00:35Z (via firstmate 005): "how many credits were approved without documentstion i
dont want to lose users unless its obvious fraud feom tbe past". So for these PAST
credits the ask is friendly: no removal threat, no deadline language. A valid document
raises trust; silence leaves the credit on the profile, flagged unverified internally
(board / valuation basis). Only obvious, evidence-backed fraud is removed (the take-back
of proven one-person roles). Nothing here ever removes a credit.

One payload file per USER, in exactly one wave:

  T-01        take-back users (first day): the roles any apply run on the take-back
              manifest removed and no revert re-added (proven fraud evidence), plus a
              friendly ask for their other credits
  W-01..W-nn  everybody else, ``per_day`` users a day from FIRST_SEND, ordered paid
              first, then by the user's biggest track, then by credit count

The payload is the ``--credits-file`` shape of scripts/intercom-verify-request.sh
(``user`` + ``credits[]``) plus grouped sections, the template, the reason-line class,
an optional friendly follow-up date and the silence rule. Nothing here posts anything.
"""

from __future__ import annotations

import gzip
import json
import os
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path
from typing import Any, Callable

from credit_review.roles import family_of

from .api import ApiError, ReadApi
from .ledger import Ledger, sha256_file

FIRST_SEND = date(2026, 10, 16)
PER_DAY = 200            # users per day; the send tool rate-limits within the day
FOLLOW_UP_DAYS = 14     # one friendly follow-up, no deadline (optional; the sender may skip it)
UNVERIFIED_AFTER_DAYS = 30  # internal flag only: no proof by then -> "unverified" on the board
MAX_CREDITS = 200        # intercom-verify-request.sh MAX_CREDITS per message
TEMPLATE = "retro-verify-grouped"
FOLLOW_UP_TEMPLATE = "retro-follow-up"
SEND_CAMPAIGN = "retro-past"  # the send tool's past-credit campaign (credit_review/verify_ledger.py CAMPAIGNS)
VERIFY_LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"  # Caroline send ledger, read-only
TAKEBACK_TEMPLATE = "takeback-mixing-mastering"
PROOF_CHANNEL = "intercom (reply with attachments); email channel when E-IN lands"
ON_SILENCE = ("credit stays on the profile; flagged unverified internally (board / valuation basis); "
              "never removed for silence (captain 2026-10-16 ~00:35Z)")
APPROVAL_REF = ("captain 2026-10-15 ~23:35Z via firstmate 002 (ask for documents on Nick's trust-yet-verify "
                "approvals), narrowed 2026-10-16 ~00:35Z via firstmate 005 (past credits: friendly ask, no removal); "
                "sends need intercom-verify-request.sh (credit-trust-caroline-t06) and a GO")
CONTRADICTION_VERDICTS = {"CONTRADICTED_one", "CONTRADICTED_multi"}

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
           editing_min_pop: int = EDITING_MIN_POP) -> tuple[list[dict[str, Any]], dict[str, list[dict[str, Any]]],
                                                             list[dict[str, Any]]]:
    """Firstmate 006 (captain ~02:00Z "are you annoying people fornbackup that we shpuldnt be?"):
    ask only GENUINE risk. Returns (asked request rows, account asks by user, not-asked rows).

    Asked, per row: Part A HOLD, Part C HOLD (incl. the unproven roles of take-back
    requests), take-back roles not removed, and editing claims that a trusted source credits
    to someone else (any track) or that are unverifiable on a track of popularity >=
    ``editing_min_pop`` (only their Editorial/Assembly roles).
    Asked once per ACCOUNT: the WATCH velocity accounts and the editing burst accounts whose
    whole-profile review did not clear them; their burst rows are not listed one by one.
    Everyone else (small unverifiable claims, established / web-credible / confirmed claimants,
    ordinary small accounts) is NOT asked: flagged unverified internally only."""
    accounts: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for w in watch:
        accounts[w["user_id"]].append({"kind": "velocity", "rows": w["velocity_rows"], "paying": bool(w.get("paying")),
                                       "peak_per_day": w["max_requests_per_day"], "first": w["first_request"],
                                       "profile_ids": w["profile_ids"], "example_tracks": w["example_tracks"]})
    editing_rows: dict[str, dict[str, Any]] = {}
    if editing_ask:
        for a in editing_ask.get("accounts", []):
            if a.get("ask"):
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


def assemble(population: list[dict[str, Any]], watch: list[dict[str, Any]], removed: list[dict[str, Any]],
             editing_ask: dict[str, Any] | None = None, *, editing_min_pop: int = EDITING_MIN_POP,
             per_day: int = PER_DAY, first_send: date = FIRST_SEND) -> list[dict[str, Any]]:
    """Pure: at most ONE payload per user, waves assigned. ``removed`` = take-back rows
    an apply run actually removed (empty before the run)."""
    asked, accounts, _ = select(population, watch, editing_ask, editing_min_pop=editing_min_pop)
    by_user: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for h in asked:
        by_user[h["user_id"]].append(h)
    removed_by_user: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for r in removed:
        removed_by_user[r["user_id"]].append(r)

    def payload(uid: str) -> dict[str, Any]:
        rows = sorted(by_user.get(uid, []), key=lambda h: (-int(h.get("pop_now") or 0), h["request_id"]))
        verify = [_credit(h, x["role"], "verify", x.get("verdict")) for h in rows for x in h["roles"]]
        taken = [_credit(r, r["role"], "takeback", "CONTRADICTED_one") for r in removed_by_user.get(uid, [])]
        acct = accounts.get(uid, [])
        groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for c in verify:
            groups[group_of(c["role"])].append(c)
        if taken:
            template, kind = TAKEBACK_TEMPLATE, "takeback"
        elif verify:
            template, kind = TEMPLATE, "verify"
        else:
            template, kind = ACCOUNT_TEMPLATE, acct[0]["kind"]
        p: dict[str, Any] = {
            "schema": "credit-retro-wave.v3", "status": "prepared_not_sent", "kind": kind,
            "user": {"id": uid, "email": None, "first_name": None},
            "paying": (any(h.get("paying") for h in rows) or any(r.get("paying") for r in removed_by_user[uid])
                       or any(a.get("paying") for a in acct)),
            "template": template,
            "takeback_credits": taken,
            "groups": [{"group": g, "credits": groups[g]} for g in GROUP_ORDER if g in groups],
            # velocity / editing-burst: ONE ask for the whole burst, three tracks of their choice
            "account_asks": acct,
            "tiers": sorted({h.get("tier") or "" for h in rows}),
            "send_campaign": SEND_CAMPAIGN, "removal_threat": False, "deadline_language": False,
            "proof_channel": PROOF_CHANNEL, "on_silence": ON_SILENCE, "proof_effect": "raises trust (verified)",
            "credits_stay_visible": True, "approval_ref": APPROVAL_REF,
        }
        flat = taken + [c for g in p["groups"] for c in g["credits"]]
        p["credits_total"] = len(flat)
        p["request_ids_all"] = sorted({c["request_id"] for c in flat})
        # the send tool's per-message cap; biggest tracks first so the cut drops the smallest
        p["credits"] = sorted(flat, key=lambda c: (c["kind"] != "takeback", -int(c.get("pop_now") or 0)))[:MAX_CREDITS]
        p["more_credits"] = max(0, len(flat) - MAX_CREDITS)
        pops = [int(c.get("pop_now") or 0) for c in flat] + [
            int(t.get("pop_now") or 0) for a in acct for t in a["example_tracks"]]
        p["max_pop"] = max(pops, default=0)
        p["big_track"] = p["max_pop"] >= 60
        p["reason_line"] = ("trusted_contradiction"
                            if any(c.get("catalog_verdict") in CONTRADICTION_VERDICTS for c in flat)
                            else "no_public_data")
        return p

    users = set(by_user) | set(removed_by_user) | set(accounts)
    t_users = sorted(removed_by_user)
    payloads = [payload(u) for u in t_users]
    others = [payload(u) for u in sorted(users - set(t_users))]
    others.sort(key=lambda p: (not p["paying"], -p["max_pop"], -p["credits_total"], p["user"]["id"]))
    for p in payloads:
        p["wave"], p["day"] = "T-01", 0
    for i, p in enumerate(others):
        p["wave"], p["day"] = f"W-{i // per_day + 1:02d}", i // per_day
    payloads += others
    for p in payloads:
        send = first_send + timedelta(days=p.pop("day"))
        p["send_not_before"] = send.isoformat()
        p["follow_up_on"] = (send + timedelta(days=FOLLOW_UP_DAYS)).isoformat()
        p["follow_up_template"] = FOLLOW_UP_TEMPLATE
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
            return c["kind"] == "takeback"
        c["track_title"] = it.get("spotifyTrackTitle") or c["track_title"]
        artists = [a.get("name") for a in (it.get("spotifyTrackArtists") or []) if isinstance(a, dict)]
        c["artist_name"] = ", ".join(a for a in artists if a) or c["artist_name"]
        return True

    before = payload["credits_total"]
    payload["takeback_credits"] = [c for c in payload["takeback_credits"] if keep(c)]
    for g in payload["groups"]:
        g["credits"] = [c for c in g["credits"] if keep(c)]
    payload["groups"] = [g for g in payload["groups"] if g["credits"]]
    flat = payload["takeback_credits"] + [c for g in payload["groups"] for c in g["credits"]]
    payload["credits_total"] = len(flat)
    payload["request_ids_all"] = sorted({c["request_id"] for c in flat})
    payload["credits"] = sorted(flat, key=lambda c: (c["kind"] != "takeback", -int(c.get("pop_now") or 0)))[:MAX_CREDITS]
    payload["more_credits"] = max(0, len(flat) - MAX_CREDITS)
    payload["live"] = {"dropped_not_approved": before - len(flat), "email_resolved": bool(payload["user"]["email"])}
    if not flat and not payload.get("account_asks"):
        payload["status"] = "nothing_to_send"


def prepare(ledger: Ledger, *, population_path: str, watch_path: str, takeback_path: str, apply_run: str | None,
            out_root: Path, argv: list[str], actor: str, api: ReadApi | None = None, per_day: int = PER_DAY,
            editing_ask_path: str | None = None, editing_min_pop: int = EDITING_MIN_POP,
            verify_db: str | None = None,
            log: Callable[[str], None] = print) -> tuple[str, dict[str, Any]]:
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
    removed = [r for r in load_jsonl(takeback_path) if r["row_id"] in removed_ids]
    population = merge_unremoved(load_jsonl(population_path), load_jsonl(takeback_path),
                                 {r["row_id"] for r in removed})
    # a request already covered by submitted proof is never asked again
    population = [h for h in population if h["request_id"] not in proof_ids]
    payloads = assemble(population, watch, removed, editing_ask, editing_min_pop=editing_min_pop, per_day=per_day)
    asked_ids = {i for p in payloads for i in p["request_ids_all"]}
    run_id = ledger.start_run(kind="prepare-waves", actor=actor, manifest=population_path, parent_run=apply_run,
                              argv=argv)
    out = out_root / run_id
    out.mkdir(parents=True, exist_ok=False)
    os.chmod(out, 0o700)
    profiles: dict[str, set[str]] = defaultdict(set)
    for h in population:
        profiles[h["user_id"]].add(h["profile_id"])
    for r in removed:
        profiles[r["user_id"]].add(r["profile_id"])
    for a in (editing_ask or {}).get("accounts", []):
        profiles[a["user_id"]].update(a["profile_ids"])
    for w in watch:
        profiles[w["user_id"]].update(w["profile_ids"])
    index: dict[str, Any] = {"run_id": run_id, "apply_runs": apply_runs, "status": "prepared_not_sent",
                             "send_campaign": SEND_CAMPAIGN, "removal": "never for silence (past credits)",
                             "on_silence": ON_SILENCE, "editing_min_pop": editing_min_pop,
                             "send_ledger": verify_db if not ledger_missing else f"UNAVAILABLE ({verify_db})",
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

