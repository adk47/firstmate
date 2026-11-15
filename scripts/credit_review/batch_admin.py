"""Batched, hoisted reads over ``muso-admin-api.sh``.

The measured ceiling the scale plan attacks: ``muso-admin-api.sh`` did three round trips
per user (token resolve, account resolve, route) and the side window measured **1.4
minutes per user** end to end. At that cost even perfect batching tops out near
1,000/day, so the drain could never reach 1,000/min.

This module removes the per-user cost from the decision path:

  * **Token resolve: once per run.** ``call-batch`` resolves the token once in one
    process and reuses it for every request in the batch. ``get_many`` is that one
    process.
  * **Account resolve: batched.** ``resolve_accounts`` asks for N profile ids in ONE
    ``/admin/credit-requests?profilesIds=...`` call instead of N calls.
  * **Route: NOT in the decision path.** The delivery route (comment / email / in-app) is
    only needed when a note is actually sent, and the plan is explicit that the sender is
    the tail, not the head. ``route_many`` exists for the tail and reports its measured
    per-user cost so a regression is visible; the drain's decision pass never calls it.

Every request still goes through ``muso-admin-api.sh``'s gate chain. That is deliberate:
a batch client that spoke HTTP directly would be faster and would also bypass the
credit-approve, reject, removal, tier-2, pace, merge-reverse, enrich-link and
bulk-destructive gates. Speed is not worth a second ungated write path.

The wrapper is the only thing that ever sees a credential; this module never reads or
prints one.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from dataclasses import dataclass, field
from typing import Any, Iterable, Sequence

DEFAULT_ADMIN_SCRIPT = "/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
SERVICE_REQUESTER = "credit-review@hydra-ops"

#: The read pool. The decision pass is read-only, so it is safe to run wide (plan,
#: change 4). The write pool is a separate, much smaller number (``scale_drain.WRITE_POOL``).
READ_POOL = 32


class BatchAdminError(RuntimeError):
    pass


@dataclass
class BatchStats:
    """The one number the plan says to instrument: seconds per request, end to end."""
    requests: int = 0
    seconds: float = 0.0
    token_resolves: int = 0
    processes: int = 0

    @property
    def ms_per_request(self) -> float:
        return (self.seconds * 1000.0 / self.requests) if self.requests else 0.0

    def as_dict(self) -> dict[str, Any]:
        return {"requests": self.requests, "seconds": round(self.seconds, 6),
                "ms_per_request": round(self.ms_per_request, 6),
                "token_resolves": self.token_resolves, "processes": self.processes}


@dataclass
class BatchAdmin:
    """GET-only batched admin client over ``muso-admin-api.sh call-batch``.

    ``get_many`` is the hoist: ONE process, ONE token resolve, N requests, bounded
    concurrency inside the wrapper. ``stats`` carries the measured per-request cost so a
    caller can assert the plan's "< 100 ms/user" exit criterion instead of assuming it.
    """
    script: str | None = None
    pool: int = READ_POOL
    timeout: int = 300
    stats: BatchStats = field(default_factory=BatchStats)

    def __post_init__(self) -> None:
        self.script = self.script or os.environ.get("CREDIT_REVIEW_ADMIN_SCRIPT", DEFAULT_ADMIN_SCRIPT)

    # ── the hoist ───────────────────────────────────────────────────────────

    def get_many(self, items: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
        """Issue N GETs in ONE wrapper process with ONE token resolve.

        ``items`` are ``{"id": <opaque>, "path": "/admin/..."}``. The result is one dict
        per item, in the same order, each ``{"id", "http_status", "body"}``. A transport
        failure is reported per item rather than aborting the batch: one bad row must not
        cost the other 92,860.
        """
        if not items:
            return []
        for it in items:
            path = str(it.get("path") or "")
            if not path.startswith("/admin/"):
                raise BatchAdminError(f"refusing non-admin path {path!r}")
        payload = "".join(json.dumps({"id": it.get("id"), "method": "GET", "path": it["path"]},
                                     sort_keys=True) + "\n" for it in items)
        argv = ["bash", str(self.script), "--requester", SERVICE_REQUESTER,
                "call-batch", "--pool", str(self.pool)]
        t0 = time.perf_counter()
        try:
            proc = subprocess.run(argv, input=payload, capture_output=True, text=True,
                                  timeout=self.timeout, check=False)
        except subprocess.TimeoutExpired as exc:
            raise BatchAdminError(f"call-batch timed out after {self.timeout}s") from exc
        elapsed = time.perf_counter() - t0
        self.stats.requests += len(items)
        self.stats.seconds += elapsed
        self.stats.processes += 1
        self.stats.token_resolves += 1
        if proc.returncode != 0:
            raise BatchAdminError(f"call-batch failed rc={proc.returncode}: {proc.stderr.strip()[:300]}")
        out: list[dict[str, Any]] = []
        for line in proc.stdout.splitlines():
            if line.strip():
                out.append(json.loads(line))
        if len(out) != len(items):
            raise BatchAdminError(f"call-batch returned {len(out)} rows for {len(items)} requests")
        return out

    def get(self, path: str, params: dict[str, Any] | None = None) -> Any:
        """Single GET, same envelope handling as ``admin.AdminClient.get``."""
        if params:
            from urllib.parse import urlencode
            path = f"{path}?{urlencode(params)}"
        row = self.get_many([{"id": "one", "path": path}])[0]
        return _unwrap(path, row)

    # ── account resolve, batched ────────────────────────────────────────────

    def resolve_accounts(self, profile_ids: Sequence[str], *, page_size: int = 100) -> dict[str, dict[str, Any]]:
        """Resolve N profiles in ONE call per page, not one call per profile.

        ``/admin/credit-requests?profilesIds=a,b,c`` returns the requests with their
        profile embedded, so a page of 100 ids is one round trip instead of 100. The
        result is keyed by profile id; a profile the page did not return is simply absent
        (the caller treats that as UNKNOWN, never as "no account").
        """
        ids = [str(p) for p in profile_ids if p]
        out: dict[str, dict[str, Any]] = {}
        for i in range(0, len(ids), page_size):
            chunk = ids[i:i + page_size]
            data = self.get("/admin/credit-requests",
                            {"profilesIds": ",".join(chunk), "limit": len(chunk), "page": 1})
            items = data.get("items") if isinstance(data, dict) else None
            if not isinstance(items, list):
                raise BatchAdminError("credit-requests list has no items[]")
            for it in items:
                pid = str(it.get("profileId") or "")
                if pid:
                    out.setdefault(pid, it)
        return out

    # ── route, for the tail only ────────────────────────────────────────────

    def route_many(self, users: Sequence[dict[str, Any]], *, gate: str | None = None,
                   pool: int = 8) -> list[dict[str, Any]]:
        """Resolve the delivery route for a page of users, for the TAIL.

        The decision pass never calls this: the plan is explicit that the sender is the
        tail, not the head. The gate (``intercom-verify-request.sh --check-recipient``)
        is per-note, so this is a bounded pool of gate invocations in one process rather
        than a per-user round trip in the hot path. The measured cost is recorded in
        ``stats`` so a regression shows up as a number, not a surprise.
        """
        gate = gate or os.environ.get("CREDIT_VERIFY_NOTIFY_WRAPPER", "/opt/hydra/scripts/intercom-verify-request.sh")
        out: list[dict[str, Any]] = []
        t0 = time.perf_counter()
        for u in users:
            argv = ["bash", gate, "--check-recipient", "--user", str(u.get("user_id") or "")]
            try:
                proc = subprocess.run(argv, capture_output=True, text=True, timeout=self.timeout, check=False)
                out.append({"user_id": u.get("user_id"), "rc": proc.returncode,
                            "stdout": proc.stdout.strip()[:2000], "stderr": proc.stderr.strip()[:500]})
            except subprocess.TimeoutExpired:
                out.append({"user_id": u.get("user_id"), "rc": -1, "stdout": "", "stderr": "timeout"})
        self.stats.requests += len(users)
        self.stats.seconds += time.perf_counter() - t0
        self.stats.processes += len(users)
        return out


def _unwrap(path: str, row: dict[str, Any]) -> Any:
    status = row.get("http_status")
    if status == 404:
        raise BatchAdminError(f"admin GET {path} returned HTTP 404")
    if not isinstance(status, int) or not 200 <= status < 300:
        raise BatchAdminError(f"admin GET {path} returned HTTP {status}")
    body = row.get("body")
    if isinstance(body, dict) and "data" in body:
        return body["data"]
    return body


def snapshot_rows(requests: Iterable[dict[str, Any]], *, precedent_of: Any = None,
                  verdict_of: Any = None) -> list[dict[str, Any]]:
    """Turn admin credit-request rows into ``scale_drain`` snapshot rows.

    This is the seam between the batched reads and the deterministic ladder. It invents
    nothing: ``duplicate_of``, ``precedent_key`` and ``proof_verdict`` come from the
    caller's already-computed facts (the duplicate index, the precedent table, the
    doc-verify verdict), and ``expires_at`` is left to ``scale_drain.load_snapshot``.
    """
    out: list[dict[str, Any]] = []
    for r in requests:
        rid = str(r.get("id") or "")
        if not rid:
            continue
        vd = r.get("verificationData") if isinstance(r.get("verificationData"), dict) else {}
        out.append({
            "request_id": rid,
            "profile_id": str(r.get("profileId") or ""),
            "user_id": r.get("userId") or (r.get("profile") or {}).get("userId"),
            "status": str(r.get("status") or ""),
            "created_at": r.get("createdAt"),
            "duplicate_of": vd.get("duplicate_of") or r.get("duplicateOf"),
            "precedent_key": precedent_of(r) if precedent_of else None,
            "proof_verdict": verdict_of(r) if verdict_of else None,
            "proof_received_at": r.get("proofReceivedAt"),
            "proof_id": r.get("proofId"),
            # When we last asked this user. NULL means never asked, and the ladder will
            # ASK rather than record an expiry: the expiry is the record of a window the
            # customer was given and did not answer, and one we never asked has none.
            "asked_at": r.get("askedAt") or vd.get("asked_at"),
        })
    return out
