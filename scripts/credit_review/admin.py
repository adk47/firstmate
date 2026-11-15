"""Read-only access to core-backend's admin API.

Production goes through the existing ``muso-admin-api.sh`` wrapper, the same
path as uvn-under30-cron.py. The wrapper owns login, the token cache and the
service credentials from the gateway env (MUSO_ADMIN_* loaded from
/etc/openclaw/main.env, provisioned from Vault), so this module never sees or
prints a credential.

This module only ever issues GETs. ``AdminClient.get`` refuses anything else,
so a credit-review run cannot change a credit request, a credit or a profile.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
from typing import Any, Protocol
from urllib.parse import urlencode

DEFAULT_ADMIN_SCRIPT = "/opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh"
SERVICE_REQUESTER = "credit-review@hydra-ops"

log = logging.getLogger(__name__)

# The approved set of ONE profile has no upper bound, and core builds every row of a page in
# memory: `status=approved&limit=500&profilesIds=<one id>` OOM-killed the core-backend-api pod
# (exit 137) on 2026-11-15 at 03:57:18Z, and the same shape ran 01:31-01:47Z. So a per-profile
# approved read is paged at APPROVED_PROFILE_PAGE_SIZE whatever limit the caller asked for, and
# it stops at APPROVED_PROFILE_MAX_PAGES pages (1,000 rows) of one profile. Past that the read
# is REFUSED with EvidenceUnbounded: the caller holds the row, it never reads a short list as
# the whole one. Raising either number is a load decision on core, not a tuning change.
APPROVED_PROFILE_PAGE_SIZE = 50
APPROVED_PROFILE_MAX_PAGES = 20
EVIDENCE_UNBOUNDED = "evidence_unbounded"


class AdminError(RuntimeError):
    pass


class EvidenceUnbounded(AdminError):
    """One profile's approved set is past the page bound, so it was not read to the end.

    It is an AdminError on purpose: every caller already treats a failed read as unknown, never
    as an empty or complete list. ``reason`` is the hold reason a caller puts on the row.
    """

    reason = EVIDENCE_UNBOUNDED

    def __init__(self, profile_id: str, pages: int, page_size: int = APPROVED_PROFILE_PAGE_SIZE):
        self.profile_id = profile_id
        self.pages = pages
        self.page_size = page_size
        super().__init__(f"{EVIDENCE_UNBOUNDED}: approved list for profile {profile_id} not read past "
                         f"{pages} pages of {page_size}")


class NotFound(AdminError):
    """HTTP 404. It does NOT prove the record is missing: core-backend's admin
    track/profile routes also answer 404 when their own catalog (industry API)
    read failed, so a caller treats it as UNKNOWN - re-read, then defer."""


class BadRequest(AdminError):
    """HTTP 400: core refused THIS request as sent. On a read scoped to one id it is a fact about that id
    and says nothing about the next one: core's admin credit-requests list validates ``profilesIds`` and
    ``trackId`` as strict RFC 4122 (assertUuidQuery.js, core-backend #10162), so a legacy-shaped id (version
    nibble outside 1-8, e.g. f8bd5f94-05c8-f52f-3129-6fa98f44e8d1) answers 400 on every read. A caller that
    walks many ids skips the one that answered 400, COUNTS it with its id and reads the rest (2026-11-15:
    one such profile aborted every score-approve run). It is never "no rows": the id was not read."""


BAD_REQUEST_REASON = "core answered HTTP 400 to the read scoped to this id (it refuses the id as sent)"


class Admin(Protocol):
    def get(self, path: str, params: dict[str, Any] | None = None) -> Any: ...


class AdminClient:
    """GET-only admin API client over the muso-admin-api.sh wrapper."""

    def __init__(self, script: str | None = None, timeout: int = 90):
        self.script = script or os.environ.get("CREDIT_REVIEW_ADMIN_SCRIPT", DEFAULT_ADMIN_SCRIPT)
        self.timeout = timeout
        self.calls = 0

    def get(self, path: str, params: dict[str, Any] | None = None) -> Any:
        if not path.startswith("/admin/"):
            raise AdminError(f"refusing non-admin path {path!r}")
        if params:
            path = f"{path}?{urlencode(params)}"
        argv = ["bash", self.script, "--requester", SERVICE_REQUESTER, "call", "GET", path]
        self.calls += 1
        try:
            proc = subprocess.run(argv, capture_output=True, text=True, timeout=self.timeout, check=False)
        except subprocess.TimeoutExpired as exc:
            raise AdminError(f"admin GET timed out: {path}") from exc
        if proc.returncode != 0:
            raise AdminError(f"admin GET failed rc={proc.returncode}: {proc.stderr.strip()[:300]}")
        try:
            envelope = json.loads(proc.stdout.strip().splitlines()[-1])
        except (json.JSONDecodeError, IndexError) as exc:
            raise AdminError(f"admin GET returned non-JSON for {path}") from exc
        status = envelope.get("http_status") if isinstance(envelope, dict) else None
        if status == 404:
            raise NotFound(f"admin GET {path} returned HTTP 404")
        if status == 400:
            raise BadRequest(f"admin GET {path} returned HTTP 400")
        if not isinstance(status, int) or not 200 <= status < 300:
            raise AdminError(f"admin GET {path} returned HTTP {status}")
        body = envelope.get("body")
        if isinstance(body, dict) and "data" in body:
            return body["data"]
        return body


def list_requests(admin: Admin, *, status: str, limit: int = 200, page: int = 1,
                  profile_ids: list[str] | None = None, track_id: str | None = None) -> list[dict[str, Any]]:
    """One page of credit requests. The endpoint returns updatedAt DESC.

    A per-profile ``approved`` read keeps the caller's ``limit``/``page`` meaning (a list shorter
    than ``limit`` is still the last page) but is fetched from core APPROVED_PROFILE_PAGE_SIZE
    rows at a time, and raises EvidenceUnbounded instead of reading past
    APPROVED_PROFILE_MAX_PAGES pages of one profile.
    """
    if status == "approved" and profile_ids:
        return _approved_for_profile(admin, limit=limit, page=page, profile_ids=profile_ids, track_id=track_id)
    return _list_page(admin, status=status, limit=limit, page=page, profile_ids=profile_ids, track_id=track_id)


def _list_page(admin: Admin, *, status: str, limit: int, page: int,
               profile_ids: list[str] | None, track_id: str | None) -> list[dict[str, Any]]:
    params: dict[str, Any] = {"status": status, "limit": limit, "page": page}
    if profile_ids:
        params["profilesIds"] = ",".join(profile_ids)
    if track_id:
        params["trackId"] = track_id
    data = admin.get("/admin/credit-requests", params)
    items = data.get("items") if isinstance(data, dict) else None
    if not isinstance(items, list):
        raise AdminError("credit-requests list has no items[]")
    return items


def _approved_for_profile(admin: Admin, *, limit: int, page: int, profile_ids: list[str],
                          track_id: str | None) -> list[dict[str, Any]]:
    """Rows [(page-1)*limit, page*limit) of a profile's approved list, read in small pages."""
    size = APPROVED_PROFILE_PAGE_SIZE
    if limit < 1 or page < 1:
        raise AdminError(f"approved list for a profile needs limit >= 1 and page >= 1, got {limit}/{page}")
    start, end = (page - 1) * limit, page * limit
    rows: list[dict[str, Any]] = []
    for n in range(start // size + 1, (end + size - 1) // size + 1):
        if n > APPROVED_PROFILE_MAX_PAGES:
            who = ",".join(profile_ids)
            log.warning("REFUSED %s: approved list for profile %s is past %d pages of %d rows; not read further",
                        EVIDENCE_UNBOUNDED, who, APPROVED_PROFILE_MAX_PAGES, size)
            raise EvidenceUnbounded(who, APPROVED_PROFILE_MAX_PAGES, size)
        items = _list_page(admin, status="approved", limit=size, page=n, profile_ids=profile_ids, track_id=track_id)
        rows += items
        if len(items) < size:
            break
    first = start - (start // size) * size
    return rows[first:first + limit]


def track_raw_credits(admin: Admin, track_id: str) -> list[dict[str, Any]]:
    data = admin.get(f"/admin/track/{track_id}/raw-credits")
    items = data.get("items") if isinstance(data, dict) else None
    if not isinstance(items, list):
        raise AdminError("raw-credits has no items[]")
    return items


def track(admin: Admin, track_id: str) -> dict[str, Any]:
    data = admin.get(f"/admin/track/{track_id}")
    if not isinstance(data, dict):
        raise AdminError("track response is not an object")
    return data


def profile(admin: Admin, profile_id: str) -> dict[str, Any]:
    data = admin.get(f"/admin/profile/{profile_id}")
    if not isinstance(data, dict):
        raise AdminError("profile response is not an object")
    return data
