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

from claim_verify import decline_rules  # scripts/ is on sys.path for every entry point (credit-fable-execute.py, tests)

from . import account_gate
from . import fable_executor as fx

ACTION = "reject_claim"
OPEN_STATUSES = ("pending", "reverted")          # core AWAITING_REVIEW (services/claiming/statusTransitions.js)
CONTRADICTIONS = frozenset({"another_persons_profile", "impersonation", "test_account", "deceased_self_claim",
                            "individual_claims_company", "contradicted_by_own_claims"})
CREATED_BY_USER = "created by user"
MAX_ROWS = 100
# Captain 16:0xZ 2026-10-29: per-item decisions come from CODE, never a hand list. A row is admitted only when its
# ruling_id is the coded rule that produced it (claim_verify/decline_rules: '<RULES_VERSION>:<contradiction>').
CODED_RULE_PREFIXES = ("c6-decline-rules-v1",)


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
    snap_email_domain: str = ""          # from the row's facts snapshot; re-checked against the fresh core read
    snap_role: str = ""


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
    email_domain: str | None = None      # claimant's account email domain, fresh
    role: str | None = None              # verificationLinks.role, fresh


def _norm(v: Any) -> str:
    return " ".join(str(v or "").strip().lower().split())


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
        prefix, _, cls = ruling.partition(":")
        if prefix not in CODED_RULE_PREFIXES or cls != r["contradiction"]:
            raise TrayError(f"row {i}: ruling_id must be the coded rule '<{'|'.join(CODED_RULE_PREFIXES)}>:"
                            f"{r['contradiction']}' (no hand-ruled rows) - the whole tray is refused")
        ev = r.get("evidence")
        if not isinstance(ev, str) or len(ev.strip()) < 20:
            raise TrayError(f"row {i}: evidence (>= 20 chars) is required")
        pid, ptype = r.get("profile_id"), r.get("profile_type")
        if not isinstance(pid, str) or not pid or not isinstance(ptype, str) or not ptype:
            raise TrayError(f"row {i}: profile_id and profile_type are required")
        # Provenance: RE-RUN the coded rule on the row's own facts snapshot. A class the rule cannot emit, or facts
        # that do not produce this decline, refuse the whole tray (QA #1506: a string check alone admits forgeries).
        snap = r.get("facts")
        if not isinstance(snap, dict) or not isinstance(snap.get("claim"), dict):
            raise TrayError(f"row {i}: no facts snapshot - a decline must be reproducible by the coded rule")
        sc = snap["claim"]
        if (sc.get("id") != cid or str(sc.get("userId")) != str(uid)
                or str(sc.get("profileId") or "").lower() != str(r.get("profile_id") or "").lower()
                or sc.get("profileType") != r.get("profile_type")):
            raise TrayError(f"row {i}: the facts snapshot is not this claim's")
        try:
            again = decline_rules.reproduce(snap)
        except Exception as exc:  # noqa: BLE001 - an unreadable snapshot is a refusal, never a pass
            raise TrayError(f"row {i}: the facts snapshot does not run under the coded rule: {exc}") from exc
        if again.decision != "decline" or again.contradiction != r["contradiction"] or again.rule_id != ruling:
            raise TrayError(f"row {i}: the coded rule does not reproduce this decline on its facts "
                            f"(got {again.decision}/{again.contradiction}) - the whole tray is refused")
        rows.append(ClaimRow(cid, uid, pid.lower(), ptype, ruling, r["contradiction"], ev.strip()[:600],
                             str(r.get("audit_reason") or "")[:1000], _norm(sc.get("email_domain")),
                             _norm((sc.get("verificationLinks") or {}).get("role"))))
    cap = doc.get("daily_cap", fx.DAILY_CAP)
    if not isinstance(cap, int) or isinstance(cap, bool) or not 1 <= cap <= fx.DAILY_CAP:
        raise TrayError(f"daily_cap must be 1..{fx.DAILY_CAP} for claim trays")
    return ClaimTray(str(path), hashlib.sha256(raw).hexdigest(), tuple(rows), cap)


DeriveFn = Callable[[list[int]], dict[int, dict]]


def live_derive(ids: list[int]) -> dict[int, dict]:
    """Fresh trusted facts snapshots (core + catalog via Trino, the repo's deceased policy)."""
    return decline_rules.live_snapshots(ids, fx._trino)


def fresh_refusal(row: ClaimRow, derive_fn: DeriveFn) -> str | None:
    """The coded rule must reproduce THIS decline on FRESH facts. The tray's own snapshot is never trusted for the
    write (QA #1506: a self-consistent forged snapshot, e.g. a living artist marked deceased, reproduces itself)."""
    try:
        snap = derive_fn([row.claim_id]).get(row.claim_id)
    except Exception:  # noqa: BLE001 - unreadable is a refusal, never a pass
        return "fresh_facts_unreadable"
    if not snap:
        return "fresh_facts_unreadable"
    try:
        again = decline_rules.reproduce(snap)
    except Exception:  # noqa: BLE001
        return "fresh_facts_unreadable"
    if again.decision != "decline" or again.contradiction != row.contradiction or again.rule_id != row.ruling_id:
        return f"not_reproduced_on_fresh_facts:{again.decision}/{again.contradiction}"
    return None


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
    if f.email_domain is None or f.role is None:
        return "facts_unreadable"                # fail closed: the snapshot cannot be re-checked
    if _norm(f.email_domain) != row.snap_email_domain:
        return "facts_changed:email_domain"
    if _norm(f.role) != row.snap_role:
        return "facts_changed:role"
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
    sql = ("select cast(c.id as varchar), c.status, cast(c.userid as varchar), c.profileid, c.profiletype, "
           "coalesce(c.reason, ''), cast(c.deletedat is not null as varchar), "
           "coalesce(lower(split_part(u.email, '@', 2)), ''), "
           "coalesce(json_extract_scalar(c.verificationlinks, '$.role'), '') "
           "from postgresql_core.public.claiming c left join postgresql_core.public.users u on u.id = c.userid "
           f"where c.id in ({','.join(str(i) for i in ids)})")
    out = (run or fx._trino)(sql)
    facts: dict[int, ClaimFacts] = {}
    for rec in csv.reader(io.StringIO("\n".join(l for l in out.splitlines() if l.startswith('"')))):
        if len(rec) != 9:
            raise RuntimeError(f"trino row has {len(rec)} columns, expected 9")
        cid, status, uid, pid, ptype, reason, deleted, domain, role = rec
        facts[int(cid)] = ClaimFacts(status or None, int(uid) if uid.isdigit() else None, pid or None,
                                     ptype or None, reason, deleted == "true",
                                     domain or None, role)
    return facts


ClaimWriter = Callable[..., dict[str, Any]]


def reject_body(ruling_id: str, tray_sha: str, ops_reason: str) -> str:
    """The body core's decline grant requires (core #11012 claimDeclineAutomation): the coded rule id, the tray digest
    and the Ops reason, which core keeps in its audit row. There is NO `reason`/`note` key, so the customer still
    gets only the standard profile_claim_rejected template (Fable (D))."""
    return json.dumps({"rulingId": ruling_id, "traySha": tray_sha, "opsReason": (ops_reason or ruling_id)[:1000]},
                      separators=(",", ":"))


def admin_claim_writer(script: str | None = None, timeout_s: int = 120) -> ClaimWriter:
    """POST /admin/claiming/:id/reject as fable-decider with the decline-grant body (no customer-facing reason)."""
    from . import admin as admin_api
    script = script or os.environ.get("CREDIT_REVIEW_ADMIN_SCRIPT", admin_api.DEFAULT_ADMIN_SCRIPT)

    def write(claim_id: int, ruling_id: str, run_id: str, tray_path: str, tray_sha: str = "",
              ops_reason: str = "") -> dict[str, Any]:
        if not tray_sha:
            tray_sha = hashlib.sha256(open(tray_path, "rb").read()).hexdigest()
        env = {**os.environ, "FABLE_RULING_ID": ruling_id, "FABLE_DECIDER_RUN_ID": run_id,
               "FABLE_DECIDER_TRAY": os.path.abspath(tray_path),
               # Core binds the fable-decider automation ONLY to agent-fable@muso.ai (AUTOMATION_APPROVAL_SCOPES;
               # core #11012/#11013 claimDeclineCaller): the decider's credit-decider login is refused 403
               # claim_decline_automation_refused. The wrapper fails closed while /etc/openclaw/agents/fable.env is absent.
               "MUSO_ADMIN_IDENTITY": fx.APPROVE_IDENTITY}
        proc = subprocess.run(["bash", script, "--requester", fx.REQUESTER, "call", "POST",
                               f"/admin/claiming/{int(claim_id)}/reject", reject_body(ruling_id, tray_sha, ops_reason)],
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
        audit_path: str = fx.AUDIT_PATH, registry_path: str = fx.REGISTRY, kill_files: tuple[str, ...] = fx.KILL_FILES,
        lock_path: str = fx.WRITE_LOCK, now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
        readback_tries: int = 6, readback_wait_s: float = 5.0,
        after_batch: Callable[[list[tuple[int, int]], datetime], str | None] | None = None,
        sleep: Callable[[float], None] | None = None, derive_fn: DeriveFn = live_derive) -> ClaimResult:
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
            why = refusal(r, facts.get(r.claim_id), gate(r.user_id)) or fresh_refusal(r, derive_fn)
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
                killed = next((p for p in kill_files if p and os.path.exists(p)), None)
                if killed:
                    res.stopped = f"kill file {killed} present"
                    break
                if not fx.registry_approved(registry_path):
                    res.stopped = f"registry entry {fx.AUTOMATION_ID} not approved"
                    break
                if fx.writes_today(audit_path, now()) >= tray.daily_cap:
                    res.stopped = f"daily cap {tray.daily_cap} reached"
                    break
                f = facts_fn([r.claim_id]).get(r.claim_id)          # FRESH, right before this claim's POST
                why = refusal(r, f, account_gate.Cached(gate_fn)(r.user_id)) or fresh_refusal(r, derive_fn)
                if why:
                    fx._bump(res, why)
                    fx.audit({**_base(tray, run_id, r, f, now()), "outcome": "refused", "reason": why}, audit_path)
                    continue
                fx.audit({**_base(tray, run_id, r, f, now()), "outcome": "reserved"}, audit_path)
                try:
                    writer(r.claim_id, r.ruling_id, run_id, tray.path, tray.sha256, r.evidence)
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
