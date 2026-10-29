"""L12 claim route: Fable-ruled profile-claim DECLINES, executed as fable-decider.

Fable [key=claim-route-zero] (2026-10-29 02:39Z):
  (A) the big-name rail does not block declining a claim CONTRADICTED by evidence in the tray (another person's
      profile, impersonation, test account, deceased artist claimed as self, an individual claiming a company);
      it still blocks a decline resting on a name only or on popularity only -> every row must name one of the
      allowed contradiction classes and carry its evidence;
  (B) org-claim declines are allowed (core's reject removes the claimant's workspace public lists + seat); a
      'created by user' claim is ALWAYS refused (reject.js publishes a catalog delete for it: no-delete order);
  (C) held accounts stay held: account gate hold / unknown / watchlisted = refused, to the human tray;
  (D) reason copy = NONE: the POST carries no reason, so the customer gets only the standard
      profile_claim_rejected template; Fable's text goes to the audit row.

Per claim, on FRESH core facts (Trino postgresql_core.public.claiming, read-only): exists, not deleted, status
pending/reverted, same user, same profile, same profile type, claim reason is not 'created by user'; account gate
allow and not watchlisted. Same kill file, registry entry, daily cap, lock, reservation-before-write and audit file
as the credit closes (fable_executor), so closes and claim declines share ONE cap. One POST per claim, read back
to 'rejected', then a profile_claim_rejected fan-out read after the batch. Stops on the first surprise.
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
import os
import subprocess
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable, Iterable

from . import account_gate
from . import fable_executor as fx

ACTION = "reject_claim"
OPEN_STATUSES = ("pending", "reverted")          # core AWAITING_REVIEW (services/claiming/statusTransitions.js)
CONTRADICTIONS = frozenset({"another_persons_profile", "impersonation", "test_account", "deceased_self_claim",
                            "individual_claims_company", "contradicted_by_own_claims"})
CREATED_BY_USER = "created by user"
MAX_ROWS = 100


class TrayError(ValueError):
    pass


@dataclass(frozen=True)
class ClaimRow:
    claim_id: int
    user_id: int
    profile_id: str
    profile_type: str
    ruling_id: str
    contradiction: str
    evidence: str
    audit_reason: str = ""


@dataclass(frozen=True)
class ClaimTray:
    path: str
    sha256: str
    rows: tuple[ClaimRow, ...]
    daily_cap: int = fx.DAILY_CAP


@dataclass(frozen=True)
class ClaimFacts:
    status: str | None
    user_id: int | None
    profile_id: str | None
    profile_type: str | None
    reason: str | None
    deleted: bool


def load_claim_tray(path: str) -> ClaimTray:
    raw = open(path, "rb").read()
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        raise TrayError(f"tray is not JSON: {exc}") from exc
    if not isinstance(doc, dict) or doc.get("action") != ACTION:
        raise TrayError(f"action must be {ACTION!r}")
    items = doc.get("rows")
    if not isinstance(items, list) or not items or len(items) > MAX_ROWS:
        raise TrayError(f"rows must be a non-empty list of at most {MAX_ROWS}")
    rows, seen = [], set()
    for i, r in enumerate(items):
        if not isinstance(r, dict):
            raise TrayError(f"row {i} is not an object")
        cid, uid = r.get("claim_id"), r.get("user_id")
        if not isinstance(cid, int) or isinstance(cid, bool) or cid < 1:
            raise TrayError(f"row {i}: claim_id must be a positive integer")
        if cid in seen:
            raise TrayError(f"row {i}: duplicate claim_id {cid}")
        seen.add(cid)
        if not isinstance(uid, int) or isinstance(uid, bool) or uid < 1:
            raise TrayError(f"row {i}: user_id must be a positive integer")
        ruling = r.get("ruling_id")
        if not isinstance(ruling, str) or not fx.RULING_RE.match(ruling):
            raise TrayError(f"row {i}: no valid Fable ruling id - the whole tray is refused")
        if r.get("contradiction") not in CONTRADICTIONS:
            raise TrayError(f"row {i}: contradiction must be one of {sorted(CONTRADICTIONS)} "
                            "(a decline never rests on a name or popularity alone)")
        ev = r.get("evidence")
        if not isinstance(ev, str) or len(ev.strip()) < 20:
            raise TrayError(f"row {i}: evidence (>= 20 chars) is required")
        pid, ptype = r.get("profile_id"), r.get("profile_type")
        if not isinstance(pid, str) or not pid or not isinstance(ptype, str) or not ptype:
            raise TrayError(f"row {i}: profile_id and profile_type are required")
        rows.append(ClaimRow(cid, uid, pid.lower(), ptype, ruling, r["contradiction"], ev.strip()[:600],
                             str(r.get("audit_reason") or "")[:1000]))
    cap = doc.get("daily_cap", fx.DAILY_CAP)
    if not isinstance(cap, int) or isinstance(cap, bool) or not 1 <= cap <= fx.DAILY_CAP:
        raise TrayError(f"daily_cap must be 1..{fx.DAILY_CAP} for claim trays")
    return ClaimTray(str(path), hashlib.sha256(raw).hexdigest(), tuple(rows), cap)


def refusal(row: ClaimRow, f: ClaimFacts | None, gate: account_gate.GateResult) -> str | None:
    if f is None:
        return "claim_not_found"
    if f.deleted:
        return "claim_deleted"
    if f.status not in OPEN_STATUSES:
        return f"status_changed:{f.status}"
    if f.user_id != row.user_id:
        return "user_mismatch"
    if (f.profile_id or "").lower() != row.profile_id:
        return "profile_mismatch"
    if f.profile_type != row.profile_type:
        return f"profile_type_changed:{f.profile_type}"
    if (f.reason or "").strip().lower() == CREATED_BY_USER:
        return "created_by_user_claim"           # reject.js would publish a catalog delete: never from here
    if not gate.allowed:
        return f"account_gate_{gate.decision}"
    watch = gate.payload.get("watch") if isinstance(gate.payload, dict) else None
    if watch or any("watchlist" in r.lower() or "deny" in r.lower() for r in gate.reasons):
        return "watchlisted_account"
    return None


def fetch_claim_facts(ids: Iterable[int], run: Callable[[str], str] | None = None) -> dict[int, ClaimFacts]:
    ids = sorted({int(i) for i in ids})
    if not ids:
        return {}
    sql = ("select cast(id as varchar), status, cast(userid as varchar), profileid, profiletype, "
           "coalesce(reason, ''), cast(deletedat is not null as varchar) from postgresql_core.public.claiming "
           f"where id in ({','.join(str(i) for i in ids)})")
    out = (run or fx._trino)(sql)
    facts: dict[int, ClaimFacts] = {}
    for rec in csv.reader(io.StringIO("\n".join(l for l in out.splitlines() if l.startswith('"')))):
        if len(rec) != 7:
            raise RuntimeError(f"trino row has {len(rec)} columns, expected 7")
        cid, status, uid, pid, ptype, reason, deleted = rec
        facts[int(cid)] = ClaimFacts(status or None, int(uid) if uid.isdigit() else None, pid or None,
                                     ptype or None, reason, deleted == "true")
    return facts


ClaimWriter = Callable[[int, str, str, str], dict[str, Any]]


def admin_claim_writer(script: str | None = None, timeout_s: int = 120) -> ClaimWriter:
    """POST /admin/claiming/:id/reject with an EMPTY body (no reason: Fable (D)) as fable-decider."""
    from . import admin as admin_api
    script = script or os.environ.get("CREDIT_REVIEW_ADMIN_SCRIPT", admin_api.DEFAULT_ADMIN_SCRIPT)

    def write(claim_id: int, ruling_id: str, run_id: str, tray_path: str) -> dict[str, Any]:
        env = {**os.environ, "FABLE_RULING_ID": ruling_id, "FABLE_DECIDER_RUN_ID": run_id,
               "FABLE_DECIDER_TRAY": os.path.abspath(tray_path), "MUSO_ADMIN_IDENTITY": fx.ADMIN_IDENTITY}
        proc = subprocess.run(["bash", script, "--requester", fx.REQUESTER, "call", "POST",
                               f"/admin/claiming/{int(claim_id)}/reject", "{}"],
                              capture_output=True, text=True, timeout=timeout_s, check=False, env=env)
        if proc.returncode != 0:
            raise RuntimeError(f"POST refused/failed rc={proc.returncode}: {proc.stderr.strip()[:400]}")
        resp = json.loads(proc.stdout)
        code = resp.get("http_status")
        if not isinstance(code, int) or not 200 <= code < 300:
            raise RuntimeError(f"POST HTTP {code}: {json.dumps(resp.get('body'))[:300]}")
        return resp.get("body") or {}
    return write


@dataclass
class ClaimResult:
    tray: str
    mode: str
    rows: int = 0
    written: int = 0
    refused: dict[str, int] = field(default_factory=dict)
    not_moved: int = 0
    stopped: str = ""

    def as_dict(self) -> dict[str, Any]:
        return {"tray": self.tray, "mode": self.mode, "rows": self.rows, "written": self.written,
                "refused": dict(sorted(self.refused.items())), "not_moved": self.not_moved, "stopped": self.stopped}


def _key(cid: int) -> str:
    return f"claim:{cid}"


def _base(tray: ClaimTray, run_id: str, r: ClaimRow, f: ClaimFacts | None, now: datetime) -> dict[str, Any]:
    return {"ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "run_id": run_id, "automation": fx.AUTOMATION_ID,
            "kind": "claim_decline", "tray": tray.path, "tray_sha256": tray.sha256, "request_id": _key(r.claim_id),
            "claim_id": r.claim_id, "user_id": r.user_id, "profile_id": r.profile_id,
            "profile_type": r.profile_type, "ruling_id": r.ruling_id, "contradiction": r.contradiction,
            "evidence": r.evidence, "audit_reason": r.audit_reason, "before": f.status if f else None,
            "mode": "apply"}


def run(tray: ClaimTray, *, apply: bool, limit: int | None = None,
        facts_fn: Callable[[Iterable[int]], dict[int, ClaimFacts]] = fetch_claim_facts,
        gate_fn: Callable[[Any], account_gate.GateResult] | None = None,
        writer: ClaimWriter | None = None,
        audit_path: str = fx.AUDIT_PATH, registry_path: str = fx.REGISTRY, kill_file: str = fx.KILL_FILE,
        lock_path: str = fx.WRITE_LOCK, now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
        readback_tries: int = 6, readback_wait_s: float = 5.0,
        after_batch: Callable[[list[tuple[int, int]], datetime], str | None] | None = None,
        sleep: Callable[[float], None] | None = None) -> ClaimResult:
    import time
    sleep = sleep or time.sleep
    if limit is not None and (not isinstance(limit, int) or isinstance(limit, bool) or limit < 1):
        raise ValueError(f"limit must be a positive integer, got {limit!r}")
    res = ClaimResult(tray.path, "apply" if apply else "dry-run", rows=len(tray.rows))
    rows = list(tray.rows)[:limit] if limit is not None else list(tray.rows)
    if not apply:
        facts, gate = facts_fn([r.claim_id for r in rows]), account_gate.Cached(gate_fn)
        n = 0
        for r in rows:
            why = refusal(r, facts.get(r.claim_id), gate(r.user_id))
            if why:
                fx._bump(res, why)   # same counter shape
            else:
                n += 1
        res.refused["would_write"] = n
        return res
    writer = writer or admin_claim_writer()
    run_id = uuid.uuid4().hex[:12]
    batch_start, moved = now(), []
    try:
        for r in rows:
            with fx._locked(lock_path):
                if os.path.exists(kill_file):
                    res.stopped = f"kill file {kill_file} present"
                    break
                if not fx.registry_approved(registry_path):
                    res.stopped = f"registry entry {fx.AUTOMATION_ID} not approved"
                    break
                if fx.writes_today(audit_path, now()) >= tray.daily_cap:
                    res.stopped = f"daily cap {tray.daily_cap} reached"
                    break
                f = facts_fn([r.claim_id]).get(r.claim_id)          # FRESH, right before this claim's POST
                why = refusal(r, f, account_gate.Cached(gate_fn)(r.user_id))
                if why:
                    fx._bump(res, why)
                    fx.audit({**_base(tray, run_id, r, f, now()), "outcome": "refused", "reason": why}, audit_path)
                    continue
                fx.audit({**_base(tray, run_id, r, f, now()), "outcome": "reserved"}, audit_path)
                try:
                    writer(r.claim_id, r.ruling_id, run_id, tray.path)
                except Exception as exc:  # noqa: BLE001
                    res.stopped = f"write failed for claim {r.claim_id}: {str(exc)[:300]}"
                after = None
                for i in range(readback_tries):
                    try:
                        g = facts_fn([r.claim_id]).get(r.claim_id)
                    except Exception as exc:  # noqa: BLE001
                        res.stopped = (res.stopped + "; " if res.stopped else "") + f"read-back failed: {str(exc)[:200]}"
                        break
                    after = g.status if g else None
                    if after == "rejected":
                        break
                    if i + 1 < readback_tries:
                        sleep(readback_wait_s)
                ok = after == "rejected"
                fx.audit({**_base(tray, run_id, r, f, now()), "after": after,
                          "outcome": "written" if ok else "not_moved"}, audit_path)
                if ok:
                    res.written += 1
                    moved.append((r.claim_id, r.user_id))
                else:
                    res.not_moved += 1
                    res.stopped = res.stopped or f"claim {r.claim_id} not rejected after the POST (read {after})"
                if res.stopped:
                    break
    except (OSError, TimeoutError) as exc:
        res.stopped = (res.stopped + "; " if res.stopped else "") + f"audit/lock failure: {str(exc)[:200]}"
        return res
    if not res.stopped and after_batch is not None and moved:
        try:
            surprise = after_batch(moved, batch_start)
        except Exception as exc:  # noqa: BLE001
            surprise = f"fan-out check failed: {str(exc)[:200]}"
        if surprise:
            res.stopped = f"fan-out: {surprise}"
    return res
