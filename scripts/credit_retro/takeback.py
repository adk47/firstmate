"""Role-scoped take-back: plan (dry-run), apply, read-back, revert.

The unit is a ROW = one (credit request, role). Only roles the f1 review
proved are in the manifest: a one-person role (Mixing / Mastering /
Immersive / Remastering) that a trusted source (Spotify / Tidal / MLC /
Jaxsta) credits to a different person, with a cited public-credit URL. Every
other role on the same request is never touched here.

Captain's delete rule (2026-10-15 ~20:00Z): "Deletes must confirm the credit
was removed from spotify or tidal first or prove that it is a different
profile in our system that the credit belongs to". The live GATE below
re-proves that at run time, row by row, immediately before the write:

  G1  the user is not excluded (user 15, Jay Baumgardner, is left alone)
  G2  the credit request still exists, is APPROVED, belongs to the same user,
      profile and track, and still carries the role
  G3  the claimant is not one of the track's own artists (a self-released
      artist's mixer is often the artist's legal name: alias risk)
  G4  the claimant still holds the role on the track (a live muso credit)
  G5  a trusted source credits the role to someone else and NOT to the
      claimant (by raw-profile link, display name, known-as, legal name):
      credit_review.evidence.classify_roles == CONTRADICTED
  G6  at least one person named in the manifest's evidence is still among
      those trusted holders (the cited URL still describes today's data)

The gate also RECORDS (never skips on) whether the role is the claimant's
last live credit on the track (``last_credit_on_track``): removing it also
drops the track's feed activity, which a revert does not bring back.

A row that fails any gate is SKIPPED with the reason, recorded, and left for
the verify waves. Nothing is retried around a gate.

The write is the existing removal route
``DELETE /admin/track/:trackId/profile/:profileId/credits {credits:[role]}``.
core-backend records a credit_removal_events row for it (the orphan
reconciler then never re-adds the role) and publishes the catalog delete.
The request's status is NOT changed. A 403 from the server (#10310) is
recorded as ``refused`` with the server's errorCode. apply removes only pairs
in an approved set (``--approval``, core-backend #10597); there is no
unapproved path. Each DELETE is recorded as ``sent`` before it goes out; a
lost response (or a crash) is reconciled against live credits by apply,
readback and revert before anything is retried, reverted or reported done.

The displaced engineer's trusted credit is never written: trusted raw credits
coexist with the user claim, so "restoring" it means proving it is still
live after the removal, which the read-back does.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from credit_review.evidence import CONTRADICTED, classify_roles
from credit_review.roles import ONE_PERSON_FAMILIES, family_of, is_trusted_source, names_match

from .api import STAGE_PATH, ApiError, ReadApi
from .ledger import Ledger

EXCLUDED_USERS = frozenset({"15"})  # captain 2026-10-15 ~21:50Z: Jay Baumgardner's profile left alone
DECISION_REF = ("captain 2026-10-15 20:00Z delete rule + 22:02Z; firstmate decision 001 "
                "credit-retro-exec-r1 2026-10-15T23:09Z (role-scoped A, named-human X)")
DECISION_TAG = "credit-retro-r1 fm001"
RAW_PAGE = 200
RAW_MAX_PAGES = 10
REQUEST_SCAN_LIMIT = 100
PLAN_MAX_AGE_S = 24 * 3600
REMOVAL_KINDS = ("apply",)


# -- manifest ----------------------------------------------------------------

def load_manifest(path: str | Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if not line.strip():
                continue
            row = json.loads(line)
            for key in ("row_id", "request_id", "user_id", "profile_id", "track_id", "role", "evidence_url"):
                if not row.get(key):
                    raise ValueError(f"{path}:{n}: missing {key}")
            if family_of(row["role"]) not in ONE_PERSON_FAMILIES:
                raise ValueError(f"{path}:{n}: {row['role']!r} is not a one-person role; only those are taken back")
            if row["row_id"] in seen:
                raise ValueError(f"{path}:{n}: duplicate row_id {row['row_id']}")
            seen.add(row["row_id"])
            rows.append(row)
    return rows


def approval_ref(row: dict[str, Any], approval_id: str | None = None) -> str:
    """The full reference, kept in the ledger."""
    ref = f"{DECISION_REF} | {row['evidence_url']}"
    return f"credit-removal-approval {approval_id} | {ref}" if approval_id else ref


def header_ref(row: dict[str, Any], approval_id: str | None = None) -> str:
    """The logged X-Removal-Approval-Ref (capped at 255 by the server): approval id and
    evidence URL first, so the cap can only ever cut the short decision tag."""
    return " | ".join(([f"approval {approval_id}"] if approval_id else [])
                      + [row["evidence_url"], DECISION_TAG])


def removal_reason(row: dict[str, Any]) -> str:
    holders = ", ".join(row.get("displaced") or []) or "another person"
    return (f"credit-retro-r1 take-back {row['row_id']}: trusted sources credit {row['role']} "
            f"to {holders}; web check {row.get('web', {}).get('verdict', '?')}")


# -- live reads --------------------------------------------------------------

def find_request(api: ReadApi, row: dict[str, Any]) -> dict[str, Any] | None:
    data = api.get("/admin/credit-requests", {
        "profilesIds": row["profile_id"], "trackId": row["track_id"], "limit": REQUEST_SCAN_LIMIT})
    items = data.get("items") if isinstance(data, dict) else None
    if not isinstance(items, list):
        raise ApiError("credit-requests list has no items[]")
    return next((it for it in items if str(it.get("id")) == row["request_id"]), None)


def raw_credits(api: ReadApi, track_id: str, **filters: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for page in range(1, RAW_MAX_PAGES + 1):
        data = api.get(f"/admin/track/{track_id}/raw-credits", {**filters, "limit": RAW_PAGE, "page": page})
        items = data.get("items") if isinstance(data, dict) else None
        if not isinstance(items, list):
            raise ApiError("raw-credits has no items[]")
        out.extend(items)
        total = data.get("total")
        if not items or (isinstance(total, int) and len(out) >= total) or len(items) < RAW_PAGE:
            return out
    raise ApiError(f"raw-credits for {track_id} exceeded {RAW_MAX_PAGES} pages")


def claimant_identity(api: ReadApi, profile_id: str) -> tuple[list[str], set[tuple[str, str]], str]:
    doc = api.get(f"/admin/profile/{profile_id}")
    if not isinstance(doc, dict):
        raise ApiError("profile response is not an object")
    name = str(doc.get("name") or "")
    names = [name] + [str(a) for a in (doc.get("knownAsNames") or []) if a]
    if doc.get("legalName"):
        names.append(str(doc["legalName"]))
    if doc.get("firstName") and doc.get("lastName"):
        names.append(f"{doc['firstName']} {doc['lastName']}")
    keys = {(str(rp.get("source") or "").lower(), str(rp.get("id") or ""))
            for rp in (doc.get("rawProfiles") or []) if isinstance(rp, dict)}
    return [n for n in names if n], keys, name


def _holder(raw: dict[str, Any]) -> dict[str, str]:
    prof = raw.get("profile") or {}
    return {"source": str(prof.get("source") or "").lower(), "id": str(prof.get("id") or ""),
            "name": str(prof.get("name") or ""), "role": str(raw.get("credit") or "")}


def claimant_holds_any(raws: list[dict[str, Any]], profile_id: str) -> list[dict[str, str]]:
    return [h for h in map(_holder, raws) if h["source"] == "muso" and h["id"] == profile_id]


def claimant_holds(raws: list[dict[str, Any]], profile_id: str, family: str) -> list[dict[str, str]]:
    return [h for h in claimant_holds_any(raws, profile_id) if family_of(h["role"]) == family]


def trusted_holders(raws: list[dict[str, Any]], family: str) -> list[dict[str, str]]:
    seen: set[tuple[str, str]] = set()
    out = []
    for r in raws:
        h = _holder(r)
        if not is_trusted_source(h["source"]) or family_of(h["role"]) != family:
            continue
        if (h["source"], h["id"]) in seen:
            continue
        seen.add((h["source"], h["id"]))
        out.append(h)
    return out


# -- gate --------------------------------------------------------------------

@dataclass
class GateResult:
    ok: bool
    reason: str
    before: dict[str, Any] = field(default_factory=dict)


def gate(api: ReadApi, row: dict[str, Any]) -> GateResult:
    fam = family_of(row["role"])
    before: dict[str, Any] = {"manifest_displaced": row.get("displaced") or []}
    if str(row["user_id"]) in EXCLUDED_USERS:
        return GateResult(False, "excluded_user", before)
    try:
        req = find_request(api, row)
        if req is None:
            return GateResult(False, "request_not_found", before)
        before["request"] = {k: req.get(k) for k in ("id", "status", "userId", "profileId", "trackId",
                                                     "credits", "updatedAt", "spotifyTrackTitle")}
        if str(req.get("status")) != "approved":
            return GateResult(False, f"request_not_approved:{req.get('status')}", before)
        if str(req.get("userId")) != str(row["user_id"]):
            return GateResult(False, "user_mismatch", before)
        roles = [str(c) for c in (req.get("credits") or [])]
        if not any(c.strip().lower() == row["role"].strip().lower() for c in roles):
            return GateResult(False, "role_not_on_request", before)
        artists = [a for a in (req.get("spotifyTrackArtists") or []) if isinstance(a, dict)]
        if row["profile_id"] in {str(a.get("id")) for a in artists}:
            return GateResult(False, "claimant_is_track_artist", before)

        raws = raw_credits(api, row["track_id"], credit=row["role"])
        mine = claimant_holds(raws, row["profile_id"], fam)
        before["claimant_live"] = mine
        if not mine:
            return GateResult(False, "claimant_credit_already_gone", before)
        other = [h for h in claimant_holds_any(raw_credits(api, row["track_id"], profileId=row["profile_id"]),
                                               row["profile_id"]) if family_of(h["role"]) != fam]
        before["claimant_other_live"] = other
        before["last_credit_on_track"] = not other

        names, keys, display = claimant_identity(api, row["profile_id"])
        before["claimant_name"] = display
        # Same name as one of the track's artists (a second profile of a self-releasing
        # artist): the trusted "other" mixer is often that artist's legal name.
        if any(names_match(str(a.get("name") or ""), n) for a in artists for n in names):
            return GateResult(False, "claimant_is_track_artist", before)
        verdict = classify_roles([row["role"]], raws, names, keys)[0]
        holders = trusted_holders(raws, fam)
        before["trusted_holders"] = holders
        if verdict.status != CONTRADICTED:
            return GateResult(False, f"not_contradicted_live:{verdict.status}", before)
        displaced = [d for d in (row.get("displaced") or []) if d]
        if displaced and not any(names_match(h["name"], d) for h in holders for d in displaced):
            return GateResult(False, "evidence_holder_changed", before)
    except ApiError as exc:
        before["error"] = str(exc)
        return GateResult(False, "read_error", before)
    return GateResult(True, "pass", before)


# -- commands ----------------------------------------------------------------

def _common(row: dict[str, Any]) -> dict[str, Any]:
    return {k: row[k] for k in ("row_id", "request_id", "user_id", "profile_id", "track_id", "role")}


def plan(api: ReadApi, ledger: Ledger, rows: list[dict[str, Any]], *, manifest: str,
         argv: list[str], log: Callable[[str], None] = print) -> tuple[str, dict[str, int]]:
    run_id = ledger.start_run(kind="plan", actor=api.actor, manifest=manifest, argv=argv)
    counts: dict[str, int] = {}
    for row in rows:
        res = gate(api, row)
        outcome = "would_remove" if res.ok else "skip"
        key = outcome if res.ok else f"skip:{res.reason}"
        counts[key] = counts.get(key, 0) + 1
        last = res.ok and res.before.get("last_credit_on_track")
        if last:
            counts["would_remove_last_credit_on_track"] = counts.get("would_remove_last_credit_on_track", 0) + 1
        ledger.event(run_id, api.actor, **_common(row), action="gate", outcome=outcome, before=res.before,
                     evidence_url=row["evidence_url"], approval_ref=approval_ref(row), reason=res.reason)
        log(f"{outcome:13} {row['row_id']}  user={row['user_id']} {res.reason}"
            + (" (last credit on track)" if last else ""))
    ledger.finish_run(run_id, counts)
    return run_id, counts


def check_plan(ledger: Ledger, plan_run: str, manifest: str, *, now: float | None = None) -> None:
    """apply only executes a completed dry-run of the SAME manifest bytes."""
    from .ledger import sha256_file  # noqa: PLC0415
    run = ledger.run(plan_run)
    if run is None or run["kind"] != "plan":
        raise SystemExit(f"--plan {plan_run}: no such dry-run plan in the ledger; run `plan` first")
    if ledger.run_end(plan_run) is None:
        raise SystemExit(f"--plan {plan_run}: that dry-run did not finish")
    if run["manifest_sha256"] != sha256_file(manifest):
        raise SystemExit(f"--plan {plan_run}: the manifest changed since that dry-run; run `plan` again")
    from datetime import datetime  # noqa: PLC0415
    started = datetime.fromisoformat(run["started_at"].replace("Z", "+00:00")).timestamp()
    if (now or time.time()) - started > PLAN_MAX_AGE_S:
        raise SystemExit(f"--plan {plan_run}: older than 24h; run `plan` again")


def planned_rows(ledger: Ledger, plan_run: str, rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Only the rows the plan showed as would_remove: nothing the human never saw is removed."""
    by_id = {r["row_id"]: r for r in rows}
    return [by_id[e["row_id"]] for e in ledger.events(plan_run, "gate")
            if e["outcome"] == "would_remove" and e["row_id"] in by_id]


def _pair_key(profile_id: str, track_id: str, role: str) -> str:
    return f"{profile_id.strip().lower()}|{track_id.strip().lower()}|{role.strip().lower()}"


REASON_MAX = 2000  # core-backend #10597 normalize.js MAX_TEXT


def evidence_line(r: dict[str, Any]) -> str:
    """One pair's evidence, keyed so a reviewer can match it to the pair in the set."""
    return f"[{r['profile_id'][:8]}/{r['track_id'][:8]}/{r['role']}] {r['evidence_url']}"


def chunk_for_reasons(rows: list[dict[str, Any]], head: str, limit: int = REASON_MAX) -> list[list[dict[str, Any]]]:
    """Split rows into sets so that EVERY pair's public-credit URL fits, untruncated, in
    its set's reason (Fable: an approval alone is never enough; the evidence must be
    attached). A profile+track's roles stay in one set."""
    by_pair: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for r in rows:
        by_pair.setdefault((r["profile_id"], r["track_id"]), []).append(r)
    chunks: list[list[dict[str, Any]]] = []
    cur: list[dict[str, Any]] = []
    size = len(head)
    for group in by_pair.values():
        add = sum(len(evidence_line(r)) + 2 for r in group)
        if len(head) + add > limit:
            raise SystemExit(f"evidence for {group[0]['row_id']} does not fit a set reason ({add} chars)")
        if cur and size + add > limit:
            chunks.append(cur)
            cur, size = [], len(head)
        cur.extend(group)
        size += add
    if cur:
        chunks.append(cur)
    return chunks


def stage(api, ledger: Ledger, rows: list[dict[str, Any]], *, manifest: str, plan_run: str, argv: list[str],
          log: Callable[[str], None] = print) -> tuple[str, dict[str, Any]]:
    """Stage the plan's would-remove rows as credit-removal approval sets (core-backend
    #10597 ``POST /admin/credit-removals``) for Nick or Jan to approve. Staging writes
    nothing destructive. Every pair's public-credit URL is in its set's ``reason`` in
    full; when they do not fit one set, the rows are split over as few sets as needed."""
    from .ledger import sha256_file  # noqa: PLC0415
    check_plan(ledger, plan_run, manifest)
    passing = planned_rows(ledger, plan_run, rows)
    if not passing:
        raise SystemExit(f"{plan_run}: no row passed the gate; nothing to stage")
    head = (f"{DECISION_REF}. Trusted public credits name a different person for each one-person role "
            f"below [profile/track/role] public-credit URL: ")
    chunks = chunk_for_reasons(passing, head)
    source = f"hydra credit-retro-r1 plan {plan_run}; manifest takeback-r1.jsonl sha256 {sha256_file(manifest)}"
    run_id = ledger.start_run(kind="stage", actor=api.actor, manifest=manifest, parent_run=plan_run, argv=argv)
    approvals: list[str] = []
    counts: dict[str, int] = {}
    for n, chunk in enumerate(chunks, 1):
        pairs: dict[tuple[str, str], list[str]] = {}
        for r in chunk:
            pairs.setdefault((r["profile_id"], r["track_id"]), []).append(r["role"])
        body = {
            "kind": "credit_removal",
            "pairs": [{"profileId": p, "trackId": t, "roles": roles} for (p, t), roles in pairs.items()],
            "requestedForKind": "internal",
            "sourceRef": f"{source}; set {n}/{len(chunks)}",
            "reason": head + "; ".join(evidence_line(r) for r in chunk),
        }
        assert len(body["reason"]) <= REASON_MAX
        status, resp = api.write("POST", STAGE_PATH, body)
        data = resp.get("data") if isinstance(resp, dict) and "data" in resp else resp
        approval_id = data.get("id") if isinstance(data, dict) and 200 <= status < 300 else None
        outcome = "staged" if approval_id else ("refused" if status == 403 else "error")
        if approval_id:
            approvals.append(approval_id)
        for r in chunk:
            ledger.event(run_id, api.actor, **_common(r), action="stage", outcome=outcome, http_status=status,
                         after={"approval_id": approval_id} if approval_id else {"response": resp},
                         evidence_url=r["evidence_url"], approval_ref=approval_ref(r),
                         reason=f"credit-removal-approval {approval_id}" if approval_id else "stage failed")
        counts[outcome] = counts.get(outcome, 0) + len(chunk)
        log(f"{outcome}: set {n}/{len(chunks)}, {len(chunk)} roles as approval {approval_id or '-'} (HTTP {status})")
        if not approval_id:
            break
    counts["sets"] = len(approvals)
    ledger.finish_run(run_id, counts)
    return run_id, {"approval_ids": approvals, "counts": counts}


def approved_pairs(api: ReadApi, approval_id: str) -> set[str]:
    """The (profile|track|role) keys of an APPROVED, unexpired, unconsumed approval set."""
    from datetime import datetime, timezone  # noqa: PLC0415
    data = api.get(f"{STAGE_PATH}/{approval_id}")
    if not isinstance(data, dict) or data.get("status") != "approved":
        raise SystemExit(f"approval {approval_id} is {data.get('status') if isinstance(data, dict) else '?'}, "
                         "not approved: Nick or Jan approves it first")
    exp = data.get("expiresAt")
    if exp and datetime.fromisoformat(str(exp).replace("Z", "+00:00")) <= datetime.now(timezone.utc):
        raise SystemExit(f"approval {approval_id} expired at {exp}: stage again")
    return {_pair_key(p["profileId"], p["trackId"], p["role"]) for p in data.get("pairs") or []
            if not p.get("consumedAt")}


def live_removed(api: ReadApi, e: dict[str, Any] | Any) -> bool | None:
    """True when the claimant no longer holds the role, False when they still do,
    None when the live read fails (the result stays unknown)."""
    try:
        raws = raw_credits(api, e["track_id"], profileId=e["profile_id"])
    except ApiError:
        return None
    return not claimant_holds(raws, e["profile_id"], family_of(e["role"]))


def reconcile(api: ReadApi, ledger: Ledger, apply_run: str, log: Callable[[str], None] = print) -> list[str]:
    """Resolve every DELETE of ``apply_run`` that went out with no known result (a
    crash or a transport error after sending) against live credits, and record the
    result in THAT run, so report, revert and the waves see the removal. Returns the
    row ids still unresolved (the live read failed too)."""
    left = []
    for e in ledger.unresolved_rows(apply_run):
        gone = live_removed(api, e)
        if gone is None:
            left.append(e["row_id"])
            continue
        ledger.event(apply_run, api.actor, row_id=e["row_id"], request_id=e["request_id"], user_id=e["user_id"],
                     profile_id=e["profile_id"], track_id=e["track_id"], role=e["role"], action="remove",
                     outcome="removed" if gone else "not_removed", before=json.loads(e["before_json"] or "{}"),
                     after={"reconciled": "live read"}, evidence_url=e["evidence_url"],
                     approval_ref=e["approval_ref"], reason=f"reconciled after unknown DELETE result ({e['outcome']})")
        log(f"reconciled    {e['row_id']}  {'removed' if gone else 'not_removed'} (run {apply_run})")
    return left


def reconcile_reverts(api: ReadApi, ledger: Ledger, apply_run: str,
                      log: Callable[[str], None] = print) -> list[str]:
    """Resolve every re-add (revert/restore POST) of ``apply_run`` that went out with no
    known result against live credits, recording the result in the revert run that sent
    it. Returns the row ids still unresolved."""
    left = []
    for e in ledger.unresolved_reverts(apply_run):
        gone = live_removed(api, e)
        if gone is None:
            left.append(e["row_id"])
            continue
        ledger.event(e["run_id"], api.actor, row_id=e["row_id"], request_id=e["request_id"], user_id=e["user_id"],
                     profile_id=e["profile_id"], track_id=e["track_id"], role=e["role"], action="revert",
                     outcome="not_re_added" if gone else "re_added", before=json.loads(e["before_json"] or "{}"),
                     after={"reconciled": "live read"}, evidence_url=e["evidence_url"],
                     approval_ref=e["approval_ref"], reason=f"reconciled after unknown re-add result ({e['outcome']})")
        log(f"reconciled    {e['row_id']}  {'not_re_added' if gone else 're_added'} (revert of {apply_run})")
    return left


def require_reconciled(api: ReadApi, ledger: Ledger, apply_runs: list[str], log: Callable[[str], None] = print) -> None:
    left = {run: ids for run in apply_runs if (ids := reconcile(api, ledger, run, log))}
    left_re = {run: ids for run in apply_runs if (ids := reconcile_reverts(api, ledger, run, log))}
    if left or left_re:
        raise SystemExit(f"results still unknown (live read failed): DELETE {left}, re-add {left_re}; re-run when "
                         "the admin API answers: nothing is retried, reverted, prepared or reported as complete "
                         "until they are known")


def apply(api, ledger: Ledger, rows: list[dict[str, Any]], *, manifest: str, plan_run: str,
          argv: list[str], approvals: list[str], only: set[str] | None = None, pause_s: float = 0.5,
          log: Callable[[str], None] = print) -> tuple[str, dict[str, int]]:
    from .ledger import sha256_file  # noqa: PLC0415
    check_plan(ledger, plan_run, manifest)
    if not approvals:
        raise SystemExit("apply removes only pairs Nick or Jan approved: run `stage`, get the set approved, "
                         "then pass --approval <id>")
    covered: dict[str, str] = {}
    for aid in approvals:
        covered.update({k: aid for k in approved_pairs(api, aid)})
    # an earlier run's DELETE with no known result is resolved before anything is retried
    require_reconciled(api, ledger, ledger.apply_runs(sha256_file(manifest)), log)
    run_id = ledger.start_run(kind="apply", actor=api.actor, manifest=manifest, parent_run=plan_run, argv=argv)
    counts: dict[str, int] = {}

    def bump(key: str) -> None:
        counts[key] = counts.get(key, 0) + 1

    for row in planned_rows(ledger, plan_run, rows):
        if only and row["row_id"] not in only:
            continue
        res = gate(api, row)  # re-proved immediately before the write
        if res.ok and _pair_key(row["profile_id"], row["track_id"], row["role"]) not in covered:
            res = GateResult(False, "not_in_approval", res.before)
        ledger.event(run_id, api.actor, **_common(row), action="gate", outcome="pass" if res.ok else "skip",
                     before=res.before, evidence_url=row["evidence_url"], approval_ref=approval_ref(row),
                     reason=res.reason)
        if not res.ok:
            bump(f"skip:{res.reason}")
            log(f"skip          {row['row_id']}  {res.reason}")
            continue
        path = f"/admin/track/{row['track_id']}/profile/{row['profile_id']}/credits"
        aid = covered[_pair_key(row["profile_id"], row["track_id"], row["role"])]
        ref = approval_ref(row, aid)
        # intent first: a crash or a lost response leaves a `sent` row that reconcile resolves
        ledger.event(run_id, api.actor, **_common(row), action="remove", outcome="sent", before=res.before,
                     evidence_url=row["evidence_url"], approval_ref=ref, reason="DELETE sent")
        try:
            status, body = api.write("DELETE", path, {"credits": [row["role"]]}, headers={
                "X-Removal-Approval-Ref": header_ref(row, aid),
                "X-Removal-Reason": removal_reason(row),
                "X-Removal-Confirmed-By": api.actor,
            })
        except ApiError as exc:
            gone = live_removed(api, row)
            outcome = "indeterminate" if gone is None else ("removed" if gone else "not_removed")
            ledger.event(run_id, api.actor, **_common(row), action="remove", outcome=outcome, before=res.before,
                         after={"transport_error": str(exc)}, evidence_url=row["evidence_url"], approval_ref=ref,
                         reason=f"no DELETE response; live read: {outcome}")
            bump(outcome)
            log(f"{outcome:13} {row['row_id']}  transport error; stopping. {exc}")
            counts["stopped_on_transport_error"] = 1
            break
        if 200 <= status < 300:
            outcome = "removed"
        elif status == 403:
            outcome = "refused"
        else:
            outcome = "error"
        err = body.get("errorCode") if isinstance(body, dict) else None
        ledger.event(run_id, api.actor, **_common(row), action="remove", outcome=outcome, http_status=status,
                     before=res.before, after={"response": body if outcome != "removed" else None},
                     evidence_url=row["evidence_url"], approval_ref=ref,
                     reason=err or removal_reason(row))
        bump(outcome)
        log(f"{outcome:13} {row['row_id']}  HTTP {status} {err or ''}".rstrip())
        if outcome == "refused":
            # Every #10310 refusal is about the SESSION (agent token, stale sign-in,
            # impersonation), never the row, so every later row would be refused too.
            log("server refused the session; stopping. Sign in again (nick@/jan@) and re-run plan + apply")
            counts["stopped_on_refusal"] = 1
            break
        time.sleep(pause_s)
    ledger.finish_run(run_id, counts)
    return run_id, counts


def readback(api: ReadApi, ledger: Ledger, apply_run: str, *, argv: list[str],
             log: Callable[[str], None] = print) -> tuple[str, dict[str, int]]:
    """After an apply: the claimant's role is gone, the trusted holders remain."""
    run = ledger.run(apply_run)
    if run is None or run["kind"] not in REMOVAL_KINDS + ("revert",):
        raise SystemExit(f"{apply_run}: not an apply or revert run")
    want_present = run["kind"] == "revert"
    if want_present:
        # resolve this revert's unknown re-adds (recorded in this run) before reading back
        require_reconciled(api, ledger, [run["parent_run"]], log)
        last: dict[str, Any] = {}
        for e in ledger.events(apply_run, "revert"):
            last[e["row_id"]] = e
        done = [e for e in last.values() if e["outcome"] == "re_added"]
    else:
        require_reconciled(api, ledger, [apply_run], log)
        done = ledger.removed_rows(apply_run)
    run_id = ledger.start_run(kind="readback", actor=api.actor, parent_run=apply_run, argv=argv)
    counts: dict[str, int] = {}
    for e in done:
        before = json.loads(e["before_json"] or "{}")
        fam = family_of(e["role"])
        after: dict[str, Any] = {}
        try:
            mine = claimant_holds(raw_credits(api, e["track_id"], profileId=e["profile_id"]), e["profile_id"], fam)
            holders = trusted_holders(raw_credits(api, e["track_id"], credit=e["role"]), fam)
        except ApiError as exc:
            outcome, after = "read_error", {"error": str(exc)}
        else:
            prior = [p for p in (before.get("trusted_holders") or []) if family_of(p.get("role", "")) == fam]
            missing = [p for p in prior if not any((p["source"], p["id"]) == (h["source"], h["id"]) for h in holders)]
            after = {"claimant_live": mine, "trusted_holders": holders, "trusted_missing": missing}
            claimant_ok = bool(mine) if want_present else not mine
            if want_present:
                outcome = "re_added_live" if claimant_ok else "pending"
            elif claimant_ok and not missing:
                outcome = "removed_trusted_intact"
            elif claimant_ok:
                outcome = "removed_trusted_changed"
            else:
                outcome = "pending"  # ingestion is asynchronous; re-run readback
        counts[outcome] = counts.get(outcome, 0) + 1
        ledger.event(run_id, api.actor, row_id=e["row_id"], request_id=e["request_id"], user_id=e["user_id"],
                     profile_id=e["profile_id"], track_id=e["track_id"], role=e["role"], action="readback",
                     outcome=outcome, before=before, after=after, evidence_url=e["evidence_url"],
                     approval_ref=e["approval_ref"])
        log(f"{outcome:24} {e['row_id']}")
    ledger.finish_run(run_id, counts)
    return run_id, counts


def revert(api, ledger: Ledger, apply_run: str, *, argv: list[str], pause_s: float = 0.5,
           requests: set[str] | None = None, ref: str | None = None,
           log: Callable[[str], None] = print) -> tuple[str, dict[str, int]]:
    """Re-add exactly the roles ``apply_run`` removed and no revert re-added yet.
    ``requests`` narrows it to some credit requests: that is the RESTORE path when
    valid proof arrives after removal."""
    run = ledger.run(apply_run)
    if run is None or run["kind"] not in REMOVAL_KINDS:
        raise SystemExit(f"{apply_run}: not an apply run")
    require_reconciled(api, ledger, [apply_run], log)
    already = ledger.reverted_row_ids(apply_run)
    todo = [e for e in ledger.removed_rows(apply_run) if e["row_id"] not in already
            and (requests is None or e["request_id"] in requests)]
    if requests is not None and not todo:
        raise SystemExit(f"{apply_run}: nothing removed (and not yet restored) for {sorted(requests)}")
    ref = ref or f"revert of {apply_run}"
    run_id = ledger.start_run(kind="revert", actor=api.actor, parent_run=apply_run, argv=argv)
    counts: dict[str, int] = {"already_reverted": len(already)} if already and requests is None else {}
    for e in todo:
        path = f"/admin/track/{e['track_id']}/profile/{e['profile_id']}/credits"
        common = dict(row_id=e["row_id"], request_id=e["request_id"], user_id=e["user_id"],
                      profile_id=e["profile_id"], track_id=e["track_id"], role=e["role"], action="revert",
                      before=json.loads(e["before_json"] or "{}"), evidence_url=e["evidence_url"], approval_ref=ref)
        # intent first: a crash or a lost response leaves a `sent` re-add that reconcile resolves
        ledger.event(run_id, api.actor, **common, outcome="sent", reason=f"re-add sent ({apply_run})")
        try:
            status, body = api.write("POST", path, {"credits": [e["role"]]}, headers={"X-Removal-Approval-Ref": ref})
        except ApiError as exc:
            gone = live_removed(api, e)
            outcome = "indeterminate" if gone is None else ("not_re_added" if gone else "re_added")
            ledger.event(run_id, api.actor, **common, outcome=outcome, after={"transport_error": str(exc)},
                         reason=f"no re-add response; live read: {outcome}")
            counts[outcome] = counts.get(outcome, 0) + 1
            log(f"{outcome:13} {e['row_id']}  transport error; stopping. {exc}")
            counts["stopped_on_transport_error"] = 1
            break
        outcome = "re_added" if 200 <= status < 300 else ("refused" if status == 403 else "error")
        counts[outcome] = counts.get(outcome, 0) + 1
        ledger.event(run_id, api.actor, **common, outcome=outcome, http_status=status,
                     after={"response": body if outcome != "re_added" else None}, reason=f"revert {apply_run}")
        log(f"{outcome:13} {e['row_id']}  HTTP {status}")
        time.sleep(pause_s)
    ledger.finish_run(run_id, counts)
    return run_id, counts


def report(ledger: Ledger, run_id: str, *, script: str = "/opt/hydra/scripts/credit-retro.py") -> dict[str, Any]:
    """Counts, every row the server refused or that errored, and the revert command."""
    run = ledger.run(run_id)
    if run is None:
        raise SystemExit(f"{run_id}: no such run")
    end = ledger.run_end(run_id)
    events = ledger.events(run_id)
    out: dict[str, Any] = {
        "run_id": run_id, "kind": run["kind"], "actor": run["actor"], "parent_run": run["parent_run"],
        "started_at": run["started_at"], "finished_at": end["finished_at"] if end else None,
        "counts": json.loads(end["counts_json"]) if end else None,
        "jsonl": str(ledger.jsonl_path(run_id)),
    }
    if run["kind"] in REMOVAL_KINDS:
        results = ledger.remove_results(run_id)
        removed = [e for e in results if e["outcome"] == "removed"]
        out["removed"] = len(removed)
        out["removed_users"] = len({e["user_id"] for e in removed})
        out["last_credit_on_track"] = [e["row_id"] for e in removed
                                       if json.loads(e["before_json"] or "{}").get("last_credit_on_track")]
        out["server_refused_or_error"] = [
            {"row_id": e["row_id"], "outcome": e["outcome"], "http_status": e["http_status"], "reason": e["reason"]}
            for e in results if e["outcome"] != "removed"]
        # sent / indeterminate: the DELETE went out with no known result; readback, revert or
        # the next apply reconciles them against live credits before anything else
        out["unresolved"] = [e["row_id"] for e in ledger.unresolved_rows(run_id)]
        out["skipped"] = [{"row_id": e["row_id"], "reason": e["reason"]}
                          for e in events if e["action"] == "gate" and e["outcome"] == "skip"]
        out["revert_command"] = f"python3 {script} revert --run {run_id} --login"
    return out
