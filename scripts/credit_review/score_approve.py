"""Score approvals: execute the validator's own APPROVE verdict on held low-risk rows.

Captain, verbatim, 2026-10-20 ~11:30Z: "approve low risk credits" (firstmate 110; Fable
credit-pending-census ruling 1: 709 rows, 353 paid, validator said approve at risk 0 and nobody
executed it, because the only executor of low-risk approvals was disabled).

Scope: Fable's band-B ruling (data/credit-trust-system-fable-a1/ruling-score-approve-band-b-2026-10-20.md),
executor side. Only these rows, every other guard intact:
  * status ``user_verification_needed``, re-read from the admin API right before the decision;
  * (1) the validator approved it: ``is_approved`` and ``total_risk_percent`` < 30; no validator
    conflict, no ``reject_*`` rule, no ``review_*``/``reject_*`` rule at 100; core's guard clear.
    Band: A only while ``admit_band_b`` is false (today's core guard, mirrored); A or B, never C,
    once core's twin admitting validator-approved band B is LIVE and the flag is flipped;
  * (2) stored popularity 1-59 (0 / unknown / 60+ refused);
  * (3) one-person roles (mix, master, immersive, remaster) only with
    ``review_role_credited_to_other_at_trusted_source`` present and 0;
  * (4) burst / velocity holds refuse (they are review_* rules: conflict or at 100);
  * (5) no open proof request (the 566 stay on the proof path in phase 1);
  * no organization / label / publisher / studio role; not on the deny / fraud / hold lists;
  * the shared account gate decides last, and only a GREEN allow approves (captain 2026-11-14): an
    account the gate allows on the amber fraud watch, a released red one, and an allow that names no
    band are not approved (``account_gate.watch_refusal``). The gate's allow alone approved 28 rows of
    5 amber accounts in that day's dry run;
  * (8) caps by write time: 20 per user, 50 per profile, 2,000 fleet per UTC day, plus the
    decider's per-user approvals cap; at most ``max_per_run`` per run; paid first (paid > 24 h,
    paid < 24 h, free), then risk 0 first, then oldest;
  * (9) ledger before any write (decisions.evidence_kind = ``validator_low_risk``); writes via
    the decider's conditional PUT (expected user_verification_needed) under the shared write
    lock; outcomes per row; reversible per run (``credit-review.py revert --run RUN_ID``, named human).
    Core's ``lost_race`` answer is read again before it is recorded (settle_lost_race): a request that
    reads the same as when it was decided was refused by a core guard, is recorded as
    ``skipped:core_guard_refused`` and is not sent again for GUARD_REFUSED_COOLDOWN_H hours; one that
    changed and still carries the same decision is sent once more;
  * (10) a deterministic audit sample (10 % in week 1, then 5 %; one-person roles 10 % always)
    filed to <AUDIT_DIR>/<day>.jsonl; ``score-approve --pause REASON`` (an audit below 95 %
    precision) stops every write at once until ``--resume``; the registry flip follows by PR;
  * (11) registry ``credit-trust-score-approve`` approved with approved_by + approval_ref, else
    shadow. Kill switches: /etc/hydra/credit-trust-score-approve.disabled (and the decider's).

No message is sent from here. Core's standard "approved" notice goes out on every approval, and
(Fable band-B ruling condition 6: the approval is PROVISIONAL) these credits are verify-notify
candidates like any decider approval: one no-deadline v1 note per user, documented users never
re-asked. Fable's ruling: data/credit-trust-system-fable-a1/ruling-score-approve-band-b-2026-10-20.md.
"""

from __future__ import annotations

import csv
import io
import json
import os
import re
import subprocess
import time
import uuid
from dataclasses import dataclass, field
from types import SimpleNamespace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

from . import admin as admin_api
from .roles import is_editorial
from . import decide
from . import account_gate as account_gate_mod
from .policy import (server_approval_refusal, server_proof_reasons, validator_conflict,
                     validator_rejected_rules)
from .roles import ONE_PERSON_FAMILIES, family_of

AUTOMATION = "credit-trust-score-approve"
EVIDENCE_KIND = "validator_low_risk"
KILL_SWITCH = Path(os.environ.get("CREDIT_TRUST_SCORE_APPROVE_KILL_SWITCH",
                                  "/etc/hydra/credit-trust-score-approve.disabled"))
TRINO = os.environ.get("CREDIT_TRUST_TRINO_CMD", "/opt/hydra/scripts/trino-query.sh")
RULING = "data/credit-trust-system-fable-a1/ruling-score-approve-band-b-2026-10-20.md"
PAUSE_FILE = Path(os.environ.get("CREDIT_TRUST_SCORE_APPROVE_PAUSE", "/var/lib/hydra/credit-review/score-approve.paused"))
AUDIT_DIR = Path(os.environ.get("CREDIT_TRUST_SCORE_APPROVE_AUDIT_DIR", "/var/lib/hydra/credit-review/score-approve-audit"))
ONE_PERSON_RULE = "review_role_credited_to_other_at_trusted_source"
STAMPS_RULING = "data/credit-trust-system-fable-a1/ruling-band-hint-stamps-2026-10-20.md"
BAND_HINT_ONLY = ["validator_band_hint"]         # Fable 15:40Z (1): this stamp alone is not an open ask
REQUESTER = "credit-trust-score-approve@hydra-ops"  # muso-admin-api.sh is_credit_trust_score_approval
HELD_STATUSES = (decide.UNVERIFIED, decide.UVN)  # Fable 15:40Z: selection = unverified + UVN
READ_EXHAUSTED = "core rate-limited the reads (HTTP 429 after backoff); the rest next run"
# reread(): this many DISTINCT profiles asked, every one answered HTTP 400 and none answered rows = the read
# itself is refused (a changed parameter, a wrapper fault), which is an outage and not "a profile to skip".
# Profiles, not reads: one profile is read once per held status.
ALL_REFUSED_MIN = 2
# QA @f88ed225 (1): the per-run candidate_limit must be applied AFTER paid-first ordering, so
# the replica scan reads the whole held population (small: ~2.3k rows on 10-20) up to this
# hard cap. Hitting the cap means paid-first can no longer be guaranteed: the run fails loud.
SCAN_CAP = 50000
SCAN_CAPPED = f"candidate scan reached {SCAN_CAP} rows: paid-first not guaranteed; nothing approved this run"
AUDIT_WEEK1_END = "2026-10-27"     # Fable condition 10: 10 % in week 1, then 5 %; one-person roles 10 % always
ORG_ROLE_TERMS = ("record label", "label", "publisher", "publishing", "studio", "distributor",
                  "production company", "management", "a&r")


@dataclass
class ScorePolicy:
    enabled: bool = False
    max_total_risk: float = 30.0
    max_popularity: int = 60
    max_per_run: int = 100
    candidate_limit: int = 2000
    max_profiles_per_run: int = 150
    # Fable ruling 2026-10-20 (band-B phase 1). OFF until core's T12 twin admitting
    # validator-approved band-B rows is LIVE: while false the executor mirrors today's guard
    # (band A only) and approves nothing core would refuse.
    admit_band_b: bool = False
    per_user_per_day: int = 20          # condition 8
    per_profile_per_day: int = 50
    fleet_per_day: int = 2000

    @classmethod
    def load(cls, path: Path | None = None) -> "ScorePolicy":
        d = json.loads(Path(path or decide.POLICY).read_text(encoding="utf-8")).get("score_approve")
        if d is None:
            return cls()
        if not isinstance(d, dict):
            raise ValueError("score_approve must be an object")
        p = cls(enabled=d.get("enabled") is True,
                max_total_risk=float(d.get("max_total_risk", 30)),
                max_popularity=int(d.get("max_popularity", 60)),
                max_per_run=int(d.get("max_per_run", 100)),
                candidate_limit=int(d.get("candidate_limit", 2000)),
                max_profiles_per_run=int(d.get("max_profiles_per_run", 150)),
                admit_band_b=d.get("admit_band_b") is True,
                per_user_per_day=int(d.get("per_user_per_day", 20)),
                per_profile_per_day=int(d.get("per_profile_per_day", 50)),
                fleet_per_day=int(d.get("fleet_per_day", 2000)))
        if not (0 < p.max_total_risk <= 30):
            raise ValueError("score_approve.max_total_risk must be in (0, 30]: the captain approved < 30 only")
        if not (0 < p.max_popularity <= 60):
            raise ValueError("score_approve.max_popularity must be in (0, 60]: big tracks never auto-approve")
        if not (0 < p.per_user_per_day <= 20 and 0 < p.per_profile_per_day <= 50 and 0 < p.fleet_per_day <= 2000):
            raise ValueError("score_approve caps exceed Fable's ruling (20/user, 50/profile, 2,000 fleet per day)")
        # QA @f93c3814: 100 approvals per run is the registered ceiling; a policy cannot raise it.
        if not 0 <= p.max_per_run <= 100 or p.candidate_limit < 1:
            raise ValueError("score_approve.max_per_run / candidate_limit out of range")
        return p


def registry_approved(path: Path | None = None) -> tuple[bool, str]:
    path = path or decide.REGISTRY
    try:
        entry = json.loads(Path(path).read_text(encoding="utf-8"))["automations"][AUTOMATION]
    except (OSError, ValueError, KeyError, TypeError) as exc:
        return False, f"registry unreadable or has no {AUTOMATION} entry: {exc}"
    if entry.get("approved") is not True:
        return False, f"{AUTOMATION} is approved=false in {path}"
    if not str(entry.get("approved_by") or "").strip() or not str(entry.get("approval_ref") or "").strip():
        return False, f"{AUTOMATION} has no approved_by / approval_ref"
    return True, f"approved by {entry['approved_by']}"


Candidates = Callable[[float, int], list[tuple]]   # (request id, profile id, risk[, status[, user id]])


#: Rows ONE candidate statement asks the replica for. The read is a walk of the existing
#: ``(status, "createdAt")`` index, one closed statement per page: the old read was a single statement
#: over every held row (~102k rows with two jsonb columns each, 2026-11-15), one transaction held open
#: for the whole transfer. Measured on node-19: a page of this size is an index range scan of well
#: under a second. Raising it lengthens each statement on the customer replica; it is not a tuning knob
#: for run time (the run-time cost of a page is the ~2 s fixed cost of a trino-query.sh call).
PAGE_ROWS = 5000
#: The only reason a statement asks for more than PAGE_ROWS: more than a page of rows share ONE
#: createdAt, so a page cannot tell whether it has read all of them (largest group measured: 363).
#: The ask doubles up to this ceiling and then the read FAILS; a statement is never unbounded.
PAGE_ROWS_MAX = 40000
#: ``CAST(createdat AS varchar)`` of a ``timestamp(6) with time zone`` the replica holds in UTC. The
#: text is the walk's cursor AND the sort key, so a value in any other shape fails the read: fixed
#: width in one zone is what makes comparing the strings the same as comparing the instants.
_CREATED_AT = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6} UTC$")


def candidate_keep_sql(max_risk: float, bands: tuple[str, ...] = ("A",), band_hint_stamp_ok: bool = False) -> str:
    """The candidate rule: the SAME four predicates, in the same order, the single statement carried in
    its WHERE. No index serves a JSON extraction, so they never select what a statement reads; each
    page evaluates them over the rows the index already bounded (``candidate_page_sql``)."""
    stamp = ("(json_extract(metadata, '$.proofRequest') IS NULL OR json_format(json_extract(metadata, "
             "'$.proofRequest.reasons')) = '[\"validator_band_hint\"]')" if band_hint_stamp_ok
             else "json_extract(metadata, '$.proofRequest') IS NULL")
    return ("json_extract_scalar(verificationdata, '$.is_approved') = 'true' "
            f"AND CAST(json_extract_scalar(verificationdata, '$.total_risk_percent') AS double) < {float(max_risk)} "
            # Core's agent guard refuses an IDP band hint other than A and any row with a proof
            # request (policy.server_proof_reasons); reading those rows only spends the shared
            # 120/min list budget. The live re-read re-checks everything anyway.
            f"AND json_extract_scalar(verificationdata, '$.band_hint') IN ({','.join(repr(b) for b in bands)}) "
            "AND " + stamp)


def candidate_page_sql(status: str, since: str | None, rows: int, keep: str) -> str:
    """One page of one held status, oldest first, as ONE statement.

    The inner SELECT is the whole of what the replica is asked: an equality on ``status``, ``deletedat
    IS NULL``, a lower bound on ``createdat``, ``ORDER BY createdat LIMIT rows``. Trino pushes all of it
    down (EXPLAIN: ``constraint on [createdAt, deletedAt, status] sortOrder=[createdAt ASC] limit=N``)
    and PostgreSQL answers it from ``credit_requests_status_created_at``. A filter cannot move below a
    LIMIT, so the candidate rule (``keep``) is a projected column over those rows and can never become
    the predicate that drives the read. ``since`` is inclusive: the page before it may have stopped
    inside a group of rows sharing that createdAt, and the caller drops the ids it already holds.

    The projected risk is TRY_CAST because it is now computed for rows the rule does not keep; for a
    kept row the rule's own strict CAST has already succeeded on the same text."""
    if status not in HELD_STATUSES:
        raise ValueError(f"not a held status: {status!r}")
    if since is not None and not _CREATED_AT.match(since):
        raise ValueError(f"not a createdAt cursor: {since!r}")
    bound = f"AND createdat >= TIMESTAMP '{since}' " if since is not None else ""
    return ("SELECT CAST(id AS varchar), CAST(profileid AS varchar), "
            "TRY_CAST(json_extract_scalar(verificationdata, '$.total_risk_percent') AS double), status, "
            f"CAST(userid AS varchar), CAST(createdat AS varchar), ({keep}) "
            "FROM (SELECT id, profileid, userid, status, createdat, verificationdata, metadata "
            f"FROM postgresql_core.public.credit_requests WHERE status = '{status}' AND deletedat IS NULL "
            f"{bound}ORDER BY createdat ASC LIMIT {int(rows)})")


def _candidate_page(sql: str, deadline: float, timeout_s: int) -> list[list[str]]:
    """Run one page statement to completion and return its rows. One process, one statement, closed
    before the next is built: nothing is held open on the replica between pages. A row this cannot
    read fails the whole read (the walk's cursor is a row's createdAt, so a skipped row could skip
    every row after it)."""
    left = deadline - time.monotonic()
    if left <= 0:
        raise admin_api.AdminError(f"replica candidate query exceeded its {timeout_s}s budget")
    try:
        p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=left, check=False)
    except subprocess.TimeoutExpired as exc:
        raise admin_api.AdminError(f"replica candidate query exceeded its {timeout_s}s budget") from exc
    if p.returncode != 0:
        raise admin_api.AdminError(f"replica candidate query failed rc={p.returncode}: {p.stderr.strip()[-200:]}")
    page = list(csv.reader(io.StringIO("\n".join(ln for ln in p.stdout.splitlines() if ln.startswith('"')))))
    if page and len(page[0]) == 7 and [page[0][i] for i in (0, 1, 3, 4, 5)] == ["id", "profileid", "status", "userid", "createdat"]:
        page = page[1:]
    for row in page:
        if len(row) != 7 or not row[0] or not _CREATED_AT.match(row[5]):
            raise admin_api.AdminError(f"replica candidate page has a row it cannot place: {row[:7]!r}"[:240])
    return page


def replica_candidates(max_risk: float, limit: int, bands: tuple[str, ...] = ("A",),
                       band_hint_stamp_ok: bool = False,
                       timeout_s: int = 600) -> list[tuple[str, str, float, str, int | None]]:
    """(request id, profile id, total risk, status, user id) of held validator-approved low-risk rows
    (unverified or user_verification_needed), from the core replica (Trino; never admin
    paging). Risk ascending, oldest first. With ``band_hint_stamp_ok`` (phase 1, Fable 15:40Z
    ruling 1) a proofRequest whose reasons are exactly ["validator_band_hint"] is read too; the
    live re-read decides whether it is still an open ask (engaged users).

    The read is bounded per statement (``PAGE_ROWS``): each held status is walked oldest first along
    the ``(status, createdAt)`` index, the candidate rule is applied to each page, and the rows it
    keeps are sorted and cut to ``limit`` here, which is what ``ORDER BY r, createdat LIMIT`` did in
    the single statement. ``timeout_s`` is the budget of the WHOLE walk. Any page that fails, fails
    the read: a partial list would read as "these are all the candidates"."""
    keep = candidate_keep_sql(max_risk, bands, band_hint_stamp_ok)
    deadline = time.monotonic() + timeout_s
    seen: set[str] = set()
    kept: list[tuple[float, str, tuple[str, str, float, str, int | None]]] = []
    for status in HELD_STATUSES:
        since: str | None = None
        rows = PAGE_ROWS
        while True:
            page = _candidate_page(candidate_page_sql(status, since, rows, keep), deadline, timeout_s)
            full = len(page) >= rows
            last = max((row[5] for row in page), default=since)
            if full and since is not None and last == since:
                # Every row of a full page shares the cursor's createdAt: the group is larger than the
                # page, and which of its rows came back is not ours to assume. Ask again, wider.
                if rows >= PAGE_ROWS_MAX:
                    raise admin_api.AdminError(
                        f"replica candidate read: {PAGE_ROWS_MAX} or more {status} rows share createdAt {since}")
                rows = min(rows * 2, PAGE_ROWS_MAX)
                continue
            for row in page:
                if row[0] in seen:      # the inclusive bound re-reads the rows at ``since``
                    continue
                seen.add(row[0])
                if row[6] != "true" or not row[1] or row[3] not in HELD_STATUSES:
                    continue
                try:
                    kept.append((float(row[2]), row[5],
                                 (row[0], row[1], float(row[2]), row[3], int(row[4]) if row[4].isdigit() else None)))
                except ValueError:
                    continue
            if not full:
                break
            # A full page that ended on a later createdAt holds every row of the earlier ones.
            since, rows = last, PAGE_ROWS
    kept.sort(key=lambda k: (k[0], k[1]))
    return [k[2] for k in kept[:max(0, int(limit))]]


REREAD_COOLDOWN_H = 6
# A hold whose cause can clear by itself on the next run (an unreadable source, a pace or cap)
# is never put behind the cooldown.
TRANSIENT_HOLD = ("unreadable", "incomplete", "next run", "retried", "rate-limited", "reached", "pace", "PAUSED",
                  # QA @1340: an engagement source that could not be read (stale/missing proof-on-file
                  # export, Intercom lookup down) is retried next run, never cooled.
                  "proof on file unknown", "conversation status unknown")


def recently_held(db, now: datetime, hours: int = REREAD_COOLDOWN_H) -> set[str]:
    """Request ids (lower) this executor HELD within ``hours`` for a durable reason (firstmate 171:
    a held row is re-read at most every 6 h, so the spare read budget walks the rest of the list)."""
    since = (now - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        rows = db.execute(
            "SELECT d.request_id, d.decision, d.reason FROM decisions d JOIN (SELECT request_id, MAX(id) id FROM decisions "
            "WHERE run_id LIKE 'score-%' AND decided_at >= ? GROUP BY request_id) l ON l.id = d.id", (since,)).fetchall()
    except Exception:  # an unreadable ledger only loses the cooldown, never a guard
        return set()
    return {str(rid).lower() for rid, dec, why in rows
            if dec != "approve" and not any(t in (why or "") for t in TRANSIENT_HOLD)}


# 2026-11-15: core answers ``lost_race`` whenever its guarded approve UPDATE matches zero rows, and for this
# automation that UPDATE also carries core's own eligibility guards (engaged claimant, profile burst, cap day).
# So the word covers two different things: a row another actor rewrote while core was writing it, and a row a
# core guard refuses. Measured that day: 1,020 ``skipped:lost_race`` rows in 39 runs were 51 requests re-sent
# 15-28 times each; the 34 that lost every tick were all still in the status we read, last updated 1-4 days
# before, and 17 landed in an ordinary tick once the guard cleared. Nothing was lost and nothing was a race.
# The executor therefore reads the row again when core says ``lost_race`` (settle_lost_race) and records what
# the read shows. It never copies a core guard: which guard refused is core's to say, not ours to re-derive.
CORE_LOST_RACE = "lost_race"
#: Core refused the write and the request reads exactly as it did when it was decided: a guard, not a race.
GUARD_REFUSED = "skipped:core_guard_refused"
#: A request whose latest written outcome is GUARD_REFUSED is not sent again for this long. Keyed on the
#: recorded outcome, never on a second copy of core's rule: when the guard clears, the next send lands.
GUARD_REFUSED_COOLDOWN_H = 6
RACE_REREAD_MAX_PROFILES = 20   # profiles re-read per run to settle lost_race answers; the rest say so
RACE_READ_LIMIT = 1000          # the profile-scoped page reread() asks for; a full page may hide a row
RACE_PACE_S = 1.0               # the same shared 120 list calls a minute reread() paces for
RACE_READ_TIMEOUT_S = 20        # one settle read; the client's own 90 s would not fit the write budget


def recently_guard_refused(db, now: datetime, hours: int = GUARD_REFUSED_COOLDOWN_H) -> set[str]:
    """Request ids (lower) whose LATEST written outcome from this executor, within ``hours``, is
    GUARD_REFUSED. A shadow run writes no approval, so its ``shadow`` rows never lift the cooldown."""
    since = (now - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        rows = db.execute(
            "SELECT o.request_id, o.outcome FROM decision_outcomes o JOIN (SELECT request_id, MAX(id) id "
            "FROM decision_outcomes WHERE run_id LIKE 'score-%' AND action = 'approve' AND outcome <> 'shadow' "
            "AND at >= ? GROUP BY request_id) l ON l.id = o.id", (since,)).fetchall()
    except Exception:  # an unreadable ledger only loses the cooldown, never a guard
        return set()
    return {str(rid).lower() for rid, out in rows if out == GUARD_REFUSED}


def _canon(value: Any) -> str:
    return json.dumps(value, sort_keys=True, default=str, separators=(",", ":"))


def row_state(row: dict[str, Any]) -> tuple:
    """The request's own columns as the admin list returns them. Equal before and after = nobody touched it
    (core bumps ``updatedAt`` on every write; the other columns say the same where it is absent)."""
    return (row.get("status"), row.get("updatedAt"), row.get("userId"), row.get("profileId"), row.get("trackId"),
            row.get("spotifyPopularity"), _canon(row.get("credits")), _canon(row.get("verificationData")),
            _canon(row.get("metadata")))


def decision_inputs(row: dict[str, Any]) -> tuple:
    """What the approve decision was made on, apart from the status and the stamps in ``metadata`` (why_not
    reads those again). A row that differs here is a different decision: it is not sent again, the next run
    decides it from the start."""
    return (row.get("userId"), row.get("profileId"), row.get("trackId"), row.get("spotifyPopularity"),
            _canon(row.get("credits")), _canon(row.get("verificationData")))


def fresh_rows(admin: admin_api.Admin, lost: dict[str, str], *, sleep: Callable[[float], None],
               clock: Callable[[], float], deadline: float, spent: list[int]) -> tuple[dict[str, dict[str, Any]], dict[str, str]]:
    """The live rows of ``lost`` ({request id: profile id}), by the same profile-scoped read the decision was
    made on, in both held statuses. Returns (rows by id, {request id: why it could not be read}). An id in
    neither was read completely and is in no held status any more. Bounded: RACE_REREAD_MAX_PROFILES profiles
    a run (``spent`` carries the count across batches) and no read starts that could outlive ``deadline``:
    a client that carries a ``timeout`` is held to RACE_READ_TIMEOUT_S for these reads and given it back."""
    own_timeout = getattr(admin, "timeout", None)
    bounded = isinstance(own_timeout, (int, float)) and not isinstance(own_timeout, bool)
    read_worst = RACE_PACE_S + (min(own_timeout, RACE_READ_TIMEOUT_S) if bounded else RACE_READ_TIMEOUT_S)
    if bounded:
        admin.timeout = min(own_timeout, RACE_READ_TIMEOUT_S)
    try:
        return _fresh_rows(admin, lost, sleep, clock, deadline, spent, read_worst)
    finally:
        if bounded:
            admin.timeout = own_timeout


def _fresh_rows(admin, lost, sleep, clock, deadline, spent, read_worst):
    by_pid: dict[str, set[str]] = {}
    for rid, pid in lost.items():
        by_pid.setdefault(pid, set()).add(rid)
    rows: dict[str, dict[str, Any]] = {}
    unread: dict[str, str] = {}
    for pid, ids in by_pid.items():
        why = None
        if spent[0] >= RACE_REREAD_MAX_PROFILES:
            why = "reread_budget"
        elif clock() + len(HELD_STATUSES) * read_worst > deadline:
            why = "time_budget"
        if why is None:
            spent[0] += 1
            full_page = False
            try:
                for status in HELD_STATUSES:
                    sleep(RACE_PACE_S)
                    items = admin_api.list_requests(admin, status=status, limit=RACE_READ_LIMIT, page=1,
                                                    profile_ids=[pid])
                    full_page = full_page or len(items) >= RACE_READ_LIMIT
                    for r in items:
                        if str(r.get("id")) in ids:
                            rows[str(r["id"])] = r
            except admin_api.AdminError:
                why = "read_failed"
            else:
                why = "page_full" if full_page else None   # a full page may hide the row: absent is not "left"
        if why:
            unread.update({rid: why for rid in ids if rid not in rows})
    return rows, unread


def last_decided(db, now: datetime, days: int = 7) -> dict[str, str]:
    """{request id (lower): the latest decided_at of this executor's runs in the last ``days``}."""
    since = (now - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        return {str(rid).lower(): at for rid, at in db.execute(
            "SELECT request_id, MAX(decided_at) FROM decisions WHERE run_id LIKE 'score-%' AND decided_at >= ? "
            "GROUP BY request_id", (since,))}
    except Exception:  # an unreadable ledger only loses the rotation, never a guard
        return {}


# 2026-11-15: a profile core answers HTTP 400 for is skipped, never a run abort (reread). The skip is this
# executor's own record, one row per refused read (profile and held status) per run: who, how many requests,
# why. It is NOT a `decisions` row (every reader of that table treats a row as a credit decision, and nothing
# was decided).
# Read it with `credit-review.py score-approve --skipped-profiles`.
UNREADABLE_TABLE = "score_approve_unreadable_profiles"
UNREADABLE_REPORT_H = 24   # a profile is news once per this many hours; in between it is in run.log and the table
UNREADABLE_SHOWN = 5       # profile ids named in the summary line; the table holds all of them


def ensure_unreadable_schema(db) -> None:
    db.execute(f"CREATE TABLE IF NOT EXISTS {UNREADABLE_TABLE} (id INTEGER PRIMARY KEY AUTOINCREMENT, "
               "run_id TEXT NOT NULL, at TEXT NOT NULL, profile_id TEXT NOT NULL, status TEXT NOT NULL, "
               "requests INTEGER NOT NULL, request_ids TEXT NOT NULL, reason TEXT NOT NULL)")
    db.execute(f"CREATE INDEX IF NOT EXISTS {UNREADABLE_TABLE}_profile_at ON {UNREADABLE_TABLE} (profile_id, at)")
    db.commit()


def recently_unreadable(db, now: datetime, hours: int = UNREADABLE_REPORT_H) -> set[str]:
    """Profile ids (lower) core answered HTTP 400 for within ``hours``. Used for one thing only: a profile
    already reported in the window is not announced again. Never a reason to skip a read and never an
    ordering: a profile moved to the back of the candidates falls outside ``candidate_limit`` whenever the
    list is longer than it (12,136 candidates against 2,000 on 2026-11-15), so it would not be asked, and
    not be counted, until the window ran out."""
    since = (now - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        return {str(pid).lower() for (pid,) in db.execute(
            f"SELECT DISTINCT profile_id FROM {UNREADABLE_TABLE} WHERE at >= ?", (since,))}
    except Exception:  # an unreadable ledger only loses the dedupe, never a guard
        return set()


def record_unreadable(db, run_id: str, now: datetime, skipped: list[dict[str, Any]], known: set[str]) -> int:
    """One row per refused read (a profile holding both held statuses has two); returns how many DISTINCT
    profiles were not already reported (``known``)."""
    at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    for s in skipped:
        db.execute(f"INSERT INTO {UNREADABLE_TABLE} (run_id, at, profile_id, status, requests, request_ids, reason) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?)",
                   (run_id, at, s["profile_id"], s["status"], len(s["request_ids"]), json.dumps(s["request_ids"]),
                    s["reason"]))
    db.commit()
    return len({str(s["profile_id"]).lower() for s in skipped} - known)


def unreadable_report(db, now: datetime, days: int = 7) -> list[dict[str, Any]] | None:
    """Per profile over ``days``: how many runs skipped it, first and last time, the requests it held last.
    Read-only (it creates nothing). None when the ledger has no skip table: no run of this code has written
    to it, which is "not recorded", never "no profile was skipped"."""
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (UNREADABLE_TABLE,)).fetchone():
        return None
    since = (now - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = []
    for pid, runs, first, last in db.execute(
            f"SELECT profile_id, COUNT(DISTINCT run_id), MIN(at), MAX(at) FROM {UNREADABLE_TABLE} WHERE at >= ? "
            "GROUP BY profile_id ORDER BY MAX(at) DESC, profile_id", (since,)).fetchall():
        ids: set[str] = set()
        reason = ""
        for raw, why in db.execute(f"SELECT request_ids, reason FROM {UNREADABLE_TABLE} WHERE profile_id = ? AND at = ?",
                                   (pid, last)):
            ids.update(json.loads(raw))
            reason = why
        out.append({"profile_id": pid, "runs": runs, "first": first, "last": last, "requests": len(ids),
                    "request_ids": sorted(ids), "reason": reason})
    return out


# 2026-10-23 18:40Z/18:55Z: with 500 profiles per run (#1345) two runs hit the cron's 900 s timeout
# and wrote nothing. Every live phase now has a wall-clock budget; work past it waits for the next
# run (a transient hold, never cooled), so a run always finishes and writes what it decided.
# All measured from the RUN START (QA @1347: candidate selection counts too), against the cron's 900 s.
CANDIDATES_BUDGET_S = 240  # the whole replica candidate walk (each page statement gets what is left)
READ_BUDGET_S = 420        # reread: the profile-filtered list reads
ANCHOR_BUDGET_S = 540      # live anchors
EDITORIAL_BUDGET_S = 600   # editorial velocity: runs right after anchors, BEFORE fan-out (QA @1347: run after
                           # fan-out, its deadline had always passed and every editorial row was held)
FANOUT_BUDGET_S = 720      # live fan-out (Trino + per-track raw reads); ~180 s left for caps + writes
# QA @1347 (23:48Z): the writes are bounded too. Every batch has a worst case of two conditional PUTs (core's
# refusal re-send) plus two readbacks; a batch starts only if that worst case still ends by RUN_BUDGET_S, else
# the rest is recorded skipped:time_budget (transient, next run). Prod PUTs of 50 rows take ~4 s (20:46Z).
RUN_BUDGET_S = 870         # 30 s under the 900 s cron timeout
WRITE_PUT_TIMEOUT_S = 45
WRITE_READBACK_TIMEOUT_S = 20
WRITE_BATCH_WORST_S = 2 * (WRITE_PUT_TIMEOUT_S + WRITE_READBACK_TIMEOUT_S)   # 130: 720 + 130 <= 870


def reread(admin: admin_api.Admin, wanted: list[tuple[str, str, float]], *, max_profiles: int = 150,
           pace_s: float = 1.0, sleep: Callable[[float], None] | None = None,
           note: list[str] | None = None, deadline: float | None = None,
           clock: Callable[[], float] | None = None,
           skipped: list[dict[str, Any]] | None = None) -> dict[str, dict[str, Any]]:
    """The live rows, by profile-filtered admin reads (filtered, so never a deep scan), in the
    candidates' order. Core allows an agent identity 120 list calls a minute, shared with the
    decider (agentAdminListRateLimit), so reads are paced, at most ``max_profiles`` profiles a
    run, and a 429 backs off; a read that still fails ends the reading for this run (the rest
    wait for the next run, nothing is decided on them).

    One profile core answers HTTP 400 for is THAT profile's fact (admin.BadRequest): it is appended to
    ``skipped`` with its id, its requests and the reason, nothing is decided on its requests, and the next
    profile is read. It does not spend the ``max_profiles`` budget (it returned no rows). 2026-11-15: one
    legacy-shaped profile id aborted every run from the first read. Two things stay an abort, because
    neither is "one unreadable profile": a caller that passes no ``skipped`` list (the skip would be
    recorded nowhere), and a run where SEVERAL profiles were asked and every one answered 400 (the read
    itself is broken, not an id). "Several" counts DISTINCT profile ids, never reads: a profile is read
    once per held status, so one profile holding requests in both statuses answers 400 twice and is still
    one profile (QA + Fable on f52836298: counted by read, that profile alone aborted the run)."""
    import time as _t
    sleep = sleep or _t.sleep
    by_profile: dict[tuple[str, str], set[str]] = {}
    for c in wanted:
        rid, pid = c[0], c[1]
        status = c[3] if len(c) > 3 and c[3] in HELD_STATUSES else decide.UVN
        by_profile.setdefault((pid, status), set()).add(rid)
    rows: dict[str, dict[str, Any]] = {}
    clock = clock or _t.monotonic
    answered = 0
    refused: dict[str, None] = {}   # the DISTINCT profile ids that answered 400, in the order asked
    for n, ((pid, status), ids) in enumerate(by_profile.items()):
        if answered >= max_profiles:
            if note is not None:
                note.append(f"read {max_profiles} profiles (run budget); the rest next run")
            break
        if deadline is not None and clock() >= deadline:
            if note is not None:
                note.append(f"read {answered} profiles (time budget {READ_BUDGET_S}s); the rest next run")
            break
        items = None
        unreadable = False
        for attempt in range(3):
            if n or attempt:
                sleep(pace_s if not attempt else 20.0 * attempt)
            try:
                items = admin_api.list_requests(admin, status=status, limit=1000, page=1, profile_ids=[pid])
                break
            except admin_api.BadRequest:
                if skipped is None:
                    raise
                unreadable = True
                break
            except admin_api.AdminError as exc:
                if "HTTP 429" not in str(exc):
                    raise
        if unreadable:
            refused[str(pid)] = None
            skipped.append({"profile_id": pid, "status": status, "request_ids": sorted(ids),
                            "reason": admin_api.BAD_REQUEST_REASON})
            continue
        if items is None:
            if note is not None:
                note.append(READ_EXHAUSTED)
            break
        answered += 1
        for r in items:
            if str(r.get("id")) in ids:
                rows[str(r["id"])] = r
    if len(refused) >= ALL_REFUSED_MIN and not answered:
        raise admin_api.AdminError(
            f"every profile-scoped credit-requests read answered HTTP 400 ({len(refused)} of {len(refused)} "
            f"profiles asked, first {next(iter(refused))}): the read is refused, not one profile")
    return rows


def org_role(roles: Iterable[str]) -> bool:
    return any(t in str(r).lower() for r in roles for t in ORG_ROLE_TERMS)


def one_person_role(roles: Iterable[str]) -> bool:
    return any(family_of(str(r)) in ONE_PERSON_FAMILIES for r in roles)


def band_hint_only_stamp(row: dict[str, Any]) -> bool:
    meta = row.get("metadata") if isinstance(row.get("metadata"), dict) else {}
    pr = meta.get("proofRequest")
    return isinstance(pr, dict) and pr.get("reasons") == BAND_HINT_ONLY


def stamp_answered(row: dict[str, Any]) -> bool:
    """Fable review-core-10733 follow-up: the claimant answered the ask when the stamp carries a
    reply (repliedAt) or any attachment; an EMPTY attachments[] is still unanswered."""
    meta = row.get("metadata") if isinstance(row.get("metadata"), dict) else {}
    pr = meta.get("proofRequest")
    if not isinstance(pr, dict):
        return False
    att = pr.get("attachments")
    return bool(pr.get("repliedAt")) or (isinstance(att, list) and len(att) > 0)


def ask_time(row: dict[str, Any]) -> str:
    """When we last asked (the stamp), else when the request was made: the start of the window in
    which an Intercom conversation counts as the claimant engaging."""
    meta = row.get("metadata") if isinstance(row.get("metadata"), dict) else {}
    pr = meta.get("proofRequest")
    at = str(pr.get("at") or "") if isinstance(pr, dict) else ""
    return at or str(row.get("createdAt") or "")


ENGAGED_PREFIX = "proof path: engaged user"

# Fable ruling addendum 2026-10-22 09:30Z (firstmate 141; the band-B ruling file): the only
# anchor is a TRUSTED-source credit naming the claimant (anchor_kind "trusted": band A, no
# provisional window, no note). Otherwise the row stands on the validator's own low-risk verdict
# (anchor_kind "none": PROVISIONAL with the verify note) - UNLESS that verdict came from
# approve_credit_exists, whose path 1 (the claimant's own live Muso credit on this track) is a
# duplicate-detection signal, never evidence: such a row passed only because a Muso credit
# lifted it, so it is held for stage 2. An earlier Muso credit is never an anchor. Unreadable
# evidence = held. ``muso_earlier`` is never written.
NO_ANCHOR_PREFIX = "no independent anchor"
TRUSTED_EVIDENCE_KIND = "validator_low_risk_trusted"
APPROVE_RULE_ORDER = ("approve_owning_track", "approve_credit_exists", "approve_common_collaborator")


def validator_approving_rule(row: dict[str, Any]) -> str | None:
    """The IDP auto-approve rule that short-circuited the validator (first approve_* in the
    validator's order with risk < 30), or None (a weighted score)."""
    vd = row.get("verificationData") if isinstance(row.get("verificationData"), dict) else {}
    rules = vd.get("rule_risk_percent") if isinstance(vd.get("rule_risk_percent"), dict) else {}
    for name in APPROVE_RULE_ORDER:
        v = rules.get(name)
        if isinstance(v, (int, float)) and not isinstance(v, bool) and v < 30:
            return name
    return None


def classify_anchor(row: dict[str, Any], trusted_confirmed: set[str]) -> tuple[str | None, str | None]:
    """(anchor_kind, None) for an admitted row - "trusted" or "none" - or (None, why held)."""
    roles = [str(r).strip() for r in (row.get("credits") or []) if str(r).strip()]
    if not roles:
        # QA @23e75a95: a row with no claimed role has nothing to anchor or judge.
        return None, f"{NO_ANCHOR_PREFIX}: the request names no role: stage 2"
    if all(r.lower() in trusted_confirmed for r in roles):
        return "trusted", None
    if validator_approving_rule(row) == "approve_credit_exists":
        missing = [r for r in roles if r.lower() not in trusted_confirmed]
        return None, (f"{NO_ANCHOR_PREFIX}: the validator approved it only via the claimant's own Muso credit "
                      f"(approve_credit_exists: a duplicate signal, never evidence) and no trusted source names the "
                      f"claimant for {', '.join(missing)}: stage 2")
    return "none", None


Anchors = Callable[[list[dict[str, Any]]], dict[str, "tuple[str | None, str | None]"]]

# Fable 10-22 09:30Z item 4 (placement: executor, firstmate 143): the version-fan-out shape. A
# "such" request is one whose claimant already held their OWN live Muso credit on that track with
# the same role BEFORE the request (created >= ANCHOR_MARGIN earlier; every request also writes its
# own Muso credit in the same second, which is not the shape). >= FANOUT_MIN such requests by one
# user created in the last 7 days -> every such row is held this run as a velocity-class review
# hold, never a reject. Unreadable -> held.
ANCHOR_MARGIN = timedelta(hours=1)
FANOUT_MIN = 3
FANOUT_WINDOW = timedelta(days=7)
FANOUT_MAX_READS_PER_USER = 60
FANOUT_PREFIX = "same_anchor_requests_7d"


def own_earlier_credit(request: dict[str, Any], raw_credits: list[dict[str, Any]]) -> bool:
    """The claimant held their own live Muso credit on this track, same role, before the request."""
    from .evidence import parse_ts
    pid = str(request.get("profileId") or "").lower()
    req_at = parse_ts(request.get("createdAt"))
    roles = {str(r).strip().lower() for r in (request.get("credits") or []) if str(r).strip()}
    if req_at is None or not roles:
        return False
    for raw in raw_credits:
        prof = raw.get("profile") if isinstance(raw.get("profile"), dict) else {}
        if str(prof.get("source") or "").lower() != "muso":
            continue
        if str(prof.get("id") or "").lower().removeprefix("muso:") != pid:
            continue
        if str(raw.get("credit") or "").strip().lower() not in roles:
            continue
        at = parse_ts(raw.get("createdAt"))
        if at is not None and at < req_at - ANCHOR_MARGIN:
            return True
    return False


Fanout = Callable[[list[dict[str, Any]]], "dict[int, set[str] | None]"]


def live_fanout(admin: admin_api.Admin, now: datetime, sleep: Callable[[float], None] | None = None,
                deadline: float | None = None, clock: Callable[[], float] | None = None) -> Fanout:
    """{user id: ids of their 'such' requests created in the last 7 days | None (unreadable)} for
    the users of the given rows. Read-only: the core replica (Trino) for the user's 7-day
    requests, then each track's raw credits (cached per track)."""
    import time as _t
    sleep = sleep or _t.sleep

    def fetch(rows: list[dict[str, Any]]) -> dict[int, set[str] | None]:
        users = sorted({r["userId"] for r in rows if isinstance(r.get("userId"), int)})
        if not users:
            return {}
        since = (now - FANOUT_WINDOW).strftime("%Y-%m-%d %H:%M:%S")
        sql = ("SELECT CAST(id AS varchar), CAST(userid AS varchar), CAST(profileid AS varchar), CAST(trackid AS varchar), "
               "CAST(credits AS varchar), to_iso8601(createdat) FROM postgresql_core.public.credit_requests "
               f"WHERE deletedat IS NULL AND userid IN ({','.join(str(u) for u in users)}) "
               f"AND createdat > TIMESTAMP '{since}' ORDER BY createdat")
        now_fn = clock or _t.monotonic
        # QA @1347: bounded by the run's fan-out deadline; past it every user reads None (= held as
        # 'unreadable', a transient hold, retried next run, never cooled).
        left = 600 if deadline is None else int(deadline - now_fn())
        if left < 5:
            return {u: None for u in users}
        try:
            p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=min(600, left), check=False)
        except subprocess.TimeoutExpired:
            return {u: None for u in users}
        if p.returncode != 0:
            return {u: None for u in users}
        by_user: dict[int, list[dict[str, Any]]] = {u: [] for u in users}
        for rid, uid, pid, tid, creds, created in csv.reader(io.StringIO("\n".join(
                ln for ln in p.stdout.splitlines() if ln.startswith('"')))):
            inner = creds.strip()[1:-1] if creds.strip().startswith("{") else creds
            roles = [x.strip() for x in next(csv.reader([inner]), []) if x.strip()] if inner else []
            by_user.setdefault(int(uid), []).append({"id": rid, "profileId": pid, "trackId": tid, "credits": roles,
                                                     "createdAt": created})
        admitted = {str(r.get("id")) for r in rows}
        raw_cache: dict[str, list[dict[str, Any]]] = {}
        out: dict[int, set[str] | None] = {}
        for uid, reqs in by_user.items():
            # Admitted rows first (their own verdict is what matters), then the rest until the bar.
            reqs.sort(key=lambda q: q["id"] not in admitted)
            such: set[str] = set()
            reads, unreadable = 0, False
            checked: set[str] = set()
            for q in reqs:
                if len(such) >= FANOUT_MIN and q["id"] not in admitted:
                    break
                tid = q["trackId"]
                if tid not in raw_cache:
                    if deadline is not None and now_fn() >= deadline:
                        unreadable = True
                        break
                    if reads >= FANOUT_MAX_READS_PER_USER:
                        unreadable = True
                        break
                    reads += 1
                    sleep(0.2)
                    try:
                        raw_cache[tid] = admin_api.track_raw_credits(admin, tid)
                    except admin_api.AdminError:
                        unreadable = True
                        break
                checked.add(q["id"])
                if own_earlier_credit(q, raw_cache[tid]):
                    such.add(q["id"])
            # QA @1347: an incomplete scan never fails open. If any ADMITTED request of this user was not
            # checked (deadline, read cap or a read error), the user reads None (held, transient), even
            # when the bar was already met by others: an unchecked admitted row would otherwise pass.
            unchecked_admitted = any(q["id"] in admitted and q["id"] not in checked for q in reqs)
            out[uid] = None if unreadable and (len(such) < FANOUT_MIN or unchecked_admitted) else such
        return out
    return fetch


EditorialVelocity = Callable[[list[dict[str, Any]]], "dict[str, Any]"]


def live_editorial_velocity(admin: admin_api.Admin, sleep: Callable[[float], None] | None = None,
                            deadline: float | None = None,
                            clock: Callable[[], float] | None = None) -> EditorialVelocity:
    """Read-only: the claimant profile's request velocity (the decider's own EvidenceBuilder
    ProfileSignals, 24 h / 7 d across statuses) for editorial-role rows only. {request id:
    ProfileSignals, or None when unreadable (held)}. QA @d0f07f55: parity with the decider's
    editorial-velocity hold."""
    import time as _t
    sleep = sleep or _t.sleep

    def fetch(rows: list[dict[str, Any]]) -> dict[str, Any]:
        from .evidence import EvidenceBuilder
        builder = EvidenceBuilder(admin)
        out: dict[str, Any] = {}
        now_fn = clock or _t.monotonic
        for n, r in enumerate(rows):
            if deadline is not None and now_fn() >= deadline:
                out[str(r.get("id"))] = None          # held "could not be read ... retried" (transient)
                continue
            if n:
                sleep(0.3)
            try:
                sig = builder.profile_signals(str(r.get("profileId") or ""), {})
                builder.ensure_velocity(sig)
            except admin_api.AdminError:
                out[str(r.get("id"))] = None
                continue
            out[str(r.get("id"))] = None if getattr(sig, "velocity_error", None) else sig
        return out
    return fetch


def live_anchors(admin: admin_api.Admin, sleep: Callable[[float], None] | None = None,
                 deadline: float | None = None, clock: Callable[[], float] | None = None) -> Anchors:
    """Read-only: the decider's trusted-catalog role verdicts for each row (raw credits +
    claimant profile). Any read failure = held."""
    import time as _t
    sleep = sleep or _t.sleep

    def fetch(rows: list[dict[str, Any]]) -> dict[str, tuple[str | None, str | None]]:
        from .evidence import CONFIRMED, EvidenceBuilder, EvidenceIncomplete
        builder = EvidenceBuilder(admin)
        out: dict[str, tuple[str | None, str | None]] = {}
        now_fn = clock or _t.monotonic
        for n, r in enumerate(rows):
            rid = str(r.get("id"))
            if deadline is not None and now_fn() >= deadline:
                out[rid] = (None, f"{NO_ANCHOR_PREFIX}: not classified this run (time budget); next run")
                continue
            if n:
                sleep(0.3)
            try:
                ev = builder.build(r)
            except (admin_api.AdminError, EvidenceIncomplete) as exc:
                out[rid] = (None, f"{NO_ANCHOR_PREFIX}: evidence unreadable ({str(exc)[:80]})")
                continue
            if ev.errors:
                # QA @1dd5d112: a partial read (claimant profile, track, velocity) can still name a
                # CONFIRMED role from a fallback name; incomplete evidence is never an anchor.
                out[rid] = (None, f"{NO_ANCHOR_PREFIX}: evidence incomplete ({'; '.join(ev.errors)[:100]})")
                continue
            confirmed = {e.claimed_role.strip().lower() for e in ev.roles if e.status == CONFIRMED}
            out[rid] = classify_anchor(r, confirmed)
        return out
    return fetch


Engaged = Callable[[dict[str, Any]], "str | None"]


def admitted_refusal(row: dict[str, Any], sp: ScorePolicy, engaged: Engaged | None = None) -> list[str]:
    """What core's guard refuses for this executor. Today (admit_band_b false): the live
    guard, mirrored (policy.server_approval_refusal: proof for any band above A). Phase 1
    (Fable ruling 2026-10-20, only once core's twin is live): the validator-approved low-risk
    path - band A or B (never C), no open proof request, no other proof reason."""
    if not sp.admit_band_b:
        return server_approval_refusal(row)
    vd = row.get("verificationData") if isinstance(row.get("verificationData"), dict) else {}
    hint = vd.get("band_hint")
    out = [r for r in server_proof_reasons(row) if r != "validator_band_hint"]
    # Fable 15:40Z (1)+(3): a proofRequest whose reasons are exactly ["validator_band_hint"] is
    # core's T12 over-reach, not an open ask - unless the user engaged with it (proof on file,
    # a support email in 90 days, an Intercom conversation since the stamp): then the ask is
    # live and the row stays on the proof path. Unknown engagement = engaged (fail closed).
    if "proof_requested" in out and band_hint_only_stamp(row):
        # Not an open ask unless the claimant answered it; engagement elsewhere (proof on file,
        # support email, Intercom) is excluded for EVERY row in why_not (Fable review-core-10733).
        out.remove("proof_requested")
        if stamp_answered(row):
            out.append("proof_requested(answered)")
    # Reviewed baseline: deploy overwrites - 2026-10-27 (credit-refresh-t01b, firstmate 026): node-8 held a hand
    # edit of this file (credit-trust-llm-t01's band_hint hot patch of 2026-10-24 00:52Z, the two lines below and
    # in replica_candidates); main now carries the same two lines (from #1351) on top of #1386, so this file is
    # the reviewed text and nothing node-8 had is lost.
    # Mirror core exactly (agentApprovalGuard validatorApprovedLowRiskRefusal: band_hint must be "A" or
    # "B"; absent = band_not_a_or_b). 2026-10-23 20:36Z: 95 of 100 PUTs were refused by core for rows whose
    # re-validated verdict carries no band_hint, and each refusal used up the per-run pace.
    if hint not in ("A", "B"):
        out.append(f"band_hint_{hint if hint is not None else 'missing'}")
    if vd.get("proof_required") is True:
        out.append("proof_required_flag")
    return ["proof_required", *out] if out else []


def why_not(row: dict[str, Any], sp: ScorePolicy, policy: decide.Policy,
            engaged: Engaged | None = None) -> str | None:
    """The reason this row is not score-approved now (None = approvable). Fable's band-B
    ruling conditions 1-5 (the caps are applied by run())."""
    if row.get("status") not in HELD_STATUSES:
        return f"status is {row.get('status')!r}, not unverified / user_verification_needed"
    vd = row.get("verificationData") if isinstance(row.get("verificationData"), dict) else {}
    risk = vd.get("total_risk_percent")
    if vd.get("is_approved") is not True:
        return "the validator did not approve it"
    if not isinstance(risk, (int, float)) or isinstance(risk, bool) or not (0 <= risk < sp.max_total_risk):
        return f"total risk {risk!r} is not a number below {sp.max_total_risk:g}"
    if validator_conflict(vd):
        return "validator conflict (the server holds agent approvals of these)"
    rejected = validator_rejected_rules(vd)
    if rejected:
        return f"validator reject rule fired ({', '.join(rejected)})"
    rules = vd.get("rule_risk_percent") if isinstance(vd.get("rule_risk_percent"), dict) else {}
    held = sorted(k for k, v in rules.items() if str(k).startswith(("review_", "reject_"))
                  and isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 100)
    if held:
        return f"a hold rule at 100 ({', '.join(held)})"
    refusal = admitted_refusal(row, sp, engaged)
    if refusal:
        return f"server approval guard would refuse ({','.join(refusal)})"
    pop = row.get("spotifyPopularity")
    if not isinstance(pop, int) or isinstance(pop, bool):
        return "stored popularity unknown"
    if pop >= sp.max_popularity:
        return f"big track (popularity {pop} >= {sp.max_popularity})"
    if pop <= 0:
        # QA @389d0d62: 0, -1 or any negative value = unknown / unattributable: a human, never the writer.
        return f"stored popularity {pop} (unknown / unattributable): human"
    roles = row.get("credits") or []
    if org_role(roles):
        return "organization / label / publisher / studio role"
    if one_person_role(roles):
        v = rules.get(ONE_PERSON_RULE)
        if not isinstance(v, (int, float)) or isinstance(v, bool) or v != 0:
            return (f"one-person role without {ONE_PERSON_RULE} = 0 (the trusted-source check did not run or "
                    "found someone else): proof path")
    uid = row.get("userId")
    if isinstance(uid, int) and uid in policy.deny_user_ids:
        return "user on the decider's deny / fraud / hold list"
    if str(row.get("profileId") or "").lower() in policy.deny_profile_ids:
        return "profile on the decider's deny / fraud / hold list"
    # Fable review-core-10733 condition 1: core pins only its own documents; the executor keeps
    # every engaged claimant (proof on file from any source, a support email in 90 days, an
    # Intercom conversation since the ask) on the proof path. Unknown = engaged.
    if engaged is not None:
        e = engaged(row)
        if e:
            return f"{ENGAGED_PREFIX} ({e}): stage 2, never a provisional approval"
    return None


def intercom_conversations_since(users: dict[int, str]) -> dict[int, "bool | None"]:
    """{user id: True (an Intercom conversation updated since the stamp) | False | None
    (unknown)} for {user id: stamp ISO time}. The contact is found by the account's Intercom
    identity (users.neptuneprofessionalid, firstmate 118). Read-only; any failure is None."""
    import time as _t
    import urllib.request
    out: dict[int, bool | None] = {u: None for u in users}
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN", "")
    if not users or not token:
        return out
    sql = ("SELECT CAST(id AS varchar), CAST(neptuneprofessionalid AS varchar) FROM postgresql_core.public.users "
           f"WHERE id IN ({','.join(str(int(u)) for u in users)})")
    p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=600, check=False)
    if p.returncode != 0:
        return out
    pro = {int(a): b for a, b in csv.reader(io.StringIO("\n".join(ln for ln in p.stdout.splitlines()
                                                                   if ln.startswith('"')))) if a.isdigit() and b}

    def post(path: str, body: dict) -> dict | None:
        req = urllib.request.Request("https://api.intercom.io" + path, data=json.dumps(body).encode(), method="POST",
                                     headers={"Authorization": "Bearer " + token, "Content-Type": "application/json",
                                              "Accept": "application/json", "Intercom-Version": "2.11"})
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    return json.load(r)
            except Exception:  # noqa: BLE001 - unknown is the fail-closed answer
                _t.sleep(2 * (attempt + 1))
        return None

    for uid, since in users.items():
        ts = decide.parse_ts(since)
        if uid not in pro or ts is None:
            continue
        c = post("/contacts/search", {"query": {"field": "external_id", "operator": "=", "value": pro[uid]}})
        if c is None:
            continue
        ids = [x.get("id") for x in c.get("data") or [] if x.get("role") == "user"]
        if not ids:
            out[uid] = False
            continue
        seen: bool | None = False
        for cid in ids:
            q = {"query": {"operator": "AND", "value": [
                {"field": "contact_ids", "operator": "=", "value": cid},
                {"field": "updated_at", "operator": ">", "value": int(ts.timestamp())}]}}
            r = post("/conversations/search", q)
            if r is None:
                seen = None
                break
            if int(r.get("total_count") or 0) > 0:
                seen = True
                break
        out[uid] = seen
    return out


def engagement_checker(rows: Iterable[dict[str, Any]], now: datetime,
                       conversations: Callable[[dict[int, str]], dict[int, "bool | None"]] | None = None) -> Engaged:
    """Fable 15:40Z (3) + review-core-10733 condition 1: ``proof_on_file || support_email_90d ||
    conversation_since_ask`` keeps a row on the proof path. Built once per run for the rows that
    pass every other rule (the Intercom look-up is two API calls per user)."""
    proof, proof_why = decide.proof_on_file(now=now)
    since_of: dict[int, str] = {}
    for r in rows:
        uid = r.get("userId")
        at = ask_time(r)
        if isinstance(uid, int) and at:
            since_of[uid] = min(since_of[uid], at) if since_of.get(uid) else at
    look = {u: t for u, t in since_of.items()
            if proof is not None and u not in proof.user_ids and u not in proof.support_contacts}
    convo = (conversations or intercom_conversations_since)(look) if look else {}

    def engaged(row: dict[str, Any]) -> str | None:
        uid = row.get("userId")
        if not isinstance(uid, int):
            return "no Muso user id"
        if proof is None:
            return f"proof on file unknown: {proof_why}"[:120]
        if uid in proof.user_ids or str(row.get("id") or "").lower() in proof.request_ids:
            return "proof on file"
        if uid in proof.support_contacts:
            return "emailed support in 90 days"
        c = convo.get(uid)
        if c is None:
            return "Intercom conversation status unknown"
        return "Intercom conversation since the ask" if c else None
    return engaged


def written_today(db, day_start: str) -> tuple[dict[int, int], dict[str, int], int]:
    """Score approvals the server confirmed today (by write time): per user, per profile, fleet."""
    rows = db.execute(
        "SELECT d.user_id, d.profile_id FROM decision_outcomes o JOIN decisions d ON d.request_id = o.request_id "
        "AND d.run_id = o.run_id WHERE o.action = 'approve' AND o.outcome = 'approved' AND o.at >= ? "
        "AND d.evidence_kind IN (?, ?)", (day_start, EVIDENCE_KIND, TRUSTED_EVIDENCE_KIND)).fetchall()
    users: dict[int, int] = {}
    profiles: dict[str, int] = {}
    for uid, pid in rows:
        if uid is not None:
            users[int(uid)] = users.get(int(uid), 0) + 1
        if pid:
            profiles[str(pid)] = profiles.get(str(pid), 0) + 1
    return users, profiles, len(rows)


def audit_sampled(request_id: str, roles: Iterable[str], day: str) -> bool:
    """Condition 10: a deterministic sample (by request id) - 10 % in week 1, then 5 %;
    one-person roles 10 % always."""
    import hashlib
    rate = 10 if (day < AUDIT_WEEK1_END or one_person_role(roles)) else 5
    return int(hashlib.sha256(request_id.encode()).hexdigest()[:8], 16) % 100 < rate


def paused() -> str | None:
    """Condition 10: a precision < 95 % audit pauses the executor until Fable reviews."""
    try:
        return PAUSE_FILE.read_text(encoding="utf-8").strip() or "paused"
    except FileNotFoundError:
        return None


@dataclass
class ScoreResult:
    run_id: str
    mode: str
    candidates: int = 0
    reread: int = 0
    account_held: int = 0
    watch_held: int = 0
    approved: int = 0
    would_approve: int = 0
    held: dict[str, int] = field(default_factory=dict)
    capped: int = 0
    paid_first: int = 0
    audit_sampled: int = 0
    engaged_excluded: int = 0
    no_anchor: int = 0
    editorial_held: int = 0
    fanout_held: int = 0
    anchor_kinds: dict = field(default_factory=dict)
    read_exhausted: bool = False
    # Profiles core answered HTTP 400 for: skipped, nothing decided on their requests, the run went on.
    # Each is {profile_id, status, request_ids, reason}. unreadable_new = those not reported in the last
    # UNREADABLE_REPORT_H hours (what makes a quiet apply run print its line).
    unreadable_profiles: list[dict[str, Any]] = field(default_factory=list)
    unreadable_new: int = 0
    audit_failed: bool = False
    paused_mid_run: bool = False
    write_errors: list[str] = field(default_factory=list)
    skipped_by_server: dict[str, int] = field(default_factory=dict)
    # Core answered lost_race and the row was read again (settle_lost_race). guard_refused: it read exactly as
    # decided (also under skipped_by_server as core_guard_refused). retried: it had changed and the decision
    # still stood, so it was sent once more; retry_landed of those were approved. guard_cooling: rows not
    # sent this run because a core guard refused them within GUARD_REFUSED_COOLDOWN_H.
    guard_refused: int = 0
    retried: int = 0
    retry_landed: int = 0
    guard_cooling: int = 0
    note: str = ""

    def unreadable_note(self) -> str:
        """The skip, by count and by profile id: '' when no profile was skipped."""
        by_pid: dict[str, int] = {}
        for s in self.unreadable_profiles:
            by_pid[s["profile_id"]] = by_pid.get(s["profile_id"], 0) + len(s["request_ids"])
        if not by_pid:
            return ""
        shown = [f"{pid} ({n} request(s))" for pid, n in list(by_pid.items())[:UNREADABLE_SHOWN]]
        more = len(by_pid) - len(shown)
        return (f"SKIPPED {len(by_pid)} profile(s) core could not read (HTTP 400 on the profile-scoped read): "
                f"{sum(by_pid.values())} request(s) not read and not decided, the other profiles were processed: "
                + ", ".join(shown)
                + (f" and {more} more (score-approve --skipped-profiles lists all)" if more > 0 else ""))

    def line(self) -> str:
        top = sorted(self.held.items(), key=lambda kv: -kv[1])[:6]
        return (f"score-approve {self.mode} run {self.run_id}: {self.candidates} candidate(s), {self.reread} re-read, "
                f"{self.approved if self.mode == 'apply' else self.would_approve} "
                f"{'approved' if self.mode == 'apply' else 'would be approved'} ({self.paid_first} paid), "
                f"{self.capped} over the per-run/per-user caps, held: "
                + (", ".join(f"{k} {v}" for k, v in top) or "none")
                + (f"; {self.audit_sampled} in the audit sample" if self.audit_sampled else "")
                + f"; {self.engaged_excluded} excluded as engaged claimants (stage 2)"
                + f"; {self.no_anchor} held without an independent anchor (stage 2)"
                + (f"; {self.editorial_held} editorial-role rows held (trusted anchor under pop "
                   f"{decide.EDITORIAL_MID_POPULARITY} only)" if self.editorial_held else "")
                + f"; {self.fanout_held} held by {FANOUT_PREFIX} (velocity-class)"
                + (f"; {self.account_held} held by the account gate" if self.account_held else "")
                + (f"; {self.watch_held} not approved: account not green at the gate (fraud watch)"
                   if self.watch_held else "")
                + (f"; approved by anchor_kind {dict(sorted(self.anchor_kinds.items()))}" if self.anchor_kinds else "")
                + ("; READS INCOMPLETE (HTTP 429 or scan cap)" if self.read_exhausted else "")
                + (f"; {self.unreadable_note()}" if self.unreadable_profiles else "")
                + ("; AUDIT SAMPLE NOT FILED: PAUSED" if self.audit_failed else "")
                + (f"; server skipped {self.skipped_by_server}" if self.skipped_by_server else "")
                + (f"; {self.guard_refused} refused by a core guard (core answered lost_race; the request read the "
                   f"same before and after, so no race): not sent again for {GUARD_REFUSED_COOLDOWN_H} h"
                   if self.guard_refused else "")
                + (f"; {self.retried} changed after the read and sent once more ({self.retry_landed} landed)"
                   if self.retried else "")
                + (f"; {self.guard_cooling} not sent: a core guard refused them in the last "
                   f"{GUARD_REFUSED_COOLDOWN_H} h" if self.guard_cooling else "")
                + (f"; WRITE ERRORS: {'; '.join(self.write_errors[:3])}" if self.write_errors else "")
                + (f"; {self.note}" if self.note else ""))


def _reason_class(why: str) -> str:
    return why.split(" (")[0].split(":")[0][:60]


def run(admin: admin_api.Admin, db, *, mode: str, policy: decide.Policy, sp: ScorePolicy,
        candidates: Candidates | None = None, writer: decide.Writer | None = None,
        readback: decide.Readback | None = None, now: datetime | None = None,
        sleep: Callable[[float], None] | None = None,
        conversations: Callable[[dict[int, str]], dict[int, "bool | None"]] | None = None,
        anchors: Anchors | None = None, fanout: Fanout | None = None,
        editorial_velocity: EditorialVelocity | None = None,
        account_gate: Callable[[Any], "account_gate_mod.GateResult"] | None = None) -> ScoreResult:
    if mode not in ("shadow", "apply"):
        raise ValueError("mode must be shadow or apply")
    decide.ensure_schema(db)
    ensure_unreadable_schema(db)
    now = now or datetime.now(timezone.utc)
    res = ScoreResult(run_id="score-" + now.strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:6], mode=mode)
    gate = account_gate_mod.Cached(account_gate)
    import time as _time
    t0 = _time.monotonic()
    why_paused = paused()
    if mode == "apply" and why_paused:
        res.mode, mode, res.note = "shadow", "shadow", f"PAUSED ({why_paused[:160]}): ran as shadow, nothing written"
    if mode == "apply":
        ok, why = registry_approved()
        if not ok:
            res.mode, mode, res.note = "shadow", "shadow", f"APPLY REFUSED ({why}): ran as shadow, nothing written"
        elif not sp.enabled:
            res.mode, mode, res.note = "shadow", "shadow", "APPLY REFUSED (score_approve.enabled is not true): shadow"
    bands = ("A", "B") if sp.admit_band_b else ("A",)
    wanted = (candidates(sp.max_total_risk, SCAN_CAP) if candidates
              else replica_candidates(sp.max_total_risk, SCAN_CAP, bands, band_hint_stamp_ok=sp.admit_band_b,
                                 timeout_s=CANDIDATES_BUDGET_S))
    if len(wanted) >= SCAN_CAP:
        res.candidates, res.read_exhausted = len(wanted), True
        res.note = (res.note + "; " if res.note else "") + SCAN_CAPPED
        return res
    res.candidates = len(wanted)
    risk_of = {c[0]: c[2] for c in wanted}
    paying, _ = decide.paying_users(now=now)
    # QA @6c2a51b4: the per-run read budget (max_profiles_per_run) must be spent paid-first, or
    # 150 older free profiles crowd out a paid one. Stable sort: paid, then risk 0, then the
    # replica's own order (oldest first within a risk).
    # 2026-10-23 (35 runs 00:55-09:25Z, 0 approvals): the budget re-read the SAME 150 profiles every
    # run (all held for durable reasons) and never reached the rest of the candidates. Within the
    # paid-first order, rows this executor decided least recently go first, so the budget walks
    # the whole list across runs; never-decided rows first.
    seen = last_decided(db, now)
    # Firstmate 171: a row HELD within the last REREAD_COOLDOWN_H hours for a durable reason goes
    # behind every row that is due (paid still first among the due rows), so the spare budget reaches
    # the free tier instead of re-reading the same held paid rows every other run.
    cooling = recently_held(db, now)
    # 2026-11-15: a profile core answered HTTP 400 for keeps its place in this order. It is asked again on
    # every run that reaches it (one paced read, no profile budget), so each run counts it and a profile
    # core starts reading again is decided on that run. refused_before only decides what is announced.
    refused_before = recently_unreadable(db, now)
    wanted = sorted(wanted, key=lambda c: (str(c[0]).lower() in cooling,
                                           not (paying is not None and len(c) > 4 and c[4] in paying),
                                           seen.get(str(c[0]).lower(), ""), c[2] > 0))
    if mode == "apply":
        # 2026-11-15: a request a core guard refused is not sent again every tick. Left out before the read,
        # so it costs no profile read, takes no per-run or daily cap slot from a row that can land, and gets
        # no new decision row (nothing new was decided; the refusal on file is the record).
        parked = recently_guard_refused(db, now)
        res.guard_cooling = sum(1 for c in wanted if str(c[0]).lower() in parked)
        wanted = [c for c in wanted if str(c[0]).lower() not in parked]
    wanted = wanted[:sp.candidate_limit]
    notes: list[str] = []
    skipped: list[dict[str, Any]] = []
    rows = reread(admin, wanted, max_profiles=sp.max_profiles_per_run, sleep=sleep, note=notes,
                  deadline=t0 + READ_BUDGET_S, skipped=skipped) if wanted else {}
    if skipped:
        # Recorded before anything is decided: a run that dies later still leaves who was skipped and why.
        res.unreadable_profiles = skipped
        res.unreadable_new = record_unreadable(db, res.run_id, now, skipped, refused_before)
    if notes:
        res.note = "; ".join([res.note] + notes if res.note else notes)
    res.read_exhausted = READ_EXHAUSTED in notes
    res.reread = len(rows)
    # Pass 1 without the engagement check finds the rows worth an Intercom look-up; pass 2 (the
    # loop) applies it to every row.
    survivors = [r for r in rows.values() if why_not(r, sp, policy) is None]
    engaged = engagement_checker(survivors, now, conversations)
    # Fable 10-22 09:30Z: every admitted row is classified (trusted / none) or held (read-only).
    admitted = [r for r in survivors if why_not(r, sp, policy, engaged) is None]
    # Phase order = deadline order (anchors 540 s, editorial velocity 600 s, fan-out 720 s), so every phase
    # starts before its own deadline unless the one before it overran (then its rows read None: held, transient).
    anchor_of = (anchors or live_anchors(admin, sleep, deadline=t0 + ANCHOR_BUDGET_S))(admitted) if admitted else {}
    editorial_rows = [r for r in admitted
                      if any(is_editorial(str(x), policy.editorial_role_terms) for x in (r.get("credits") or []))]
    vel_of = ((editorial_velocity or live_editorial_velocity(admin, sleep, deadline=t0 + EDITORIAL_BUDGET_S))(editorial_rows)
              if editorial_rows else {})
    fan_of = (fanout or live_fanout(admin, now, sleep, deadline=t0 + FANOUT_BUDGET_S))(admitted) if admitted else {}
    day_start = now.strftime("%Y-%m-%dT00:00:00Z")
    today = decide.approvals_today_by_user(db, day_start)
    by_user, by_profile, fleet = written_today(db, day_start)
    # Condition 8: paid first (paid > 24 h, paid < 24 h, free), then risk 0 first, then oldest.
    order = sorted(rows.values(), key=lambda r: (decide.paid_tier(r.get("userId"), r.get("createdAt"), paying, now),
                                                  risk_of.get(str(r.get("id")), 99) > 0,
                                                  str(r.get("createdAt") or "")))
    approve: list[decide.Decision] = []
    for r in order:
        d = decide.request_decision(r)
        d.popularity = r.get("spotifyPopularity") if isinstance(r.get("spotifyPopularity"), int) else None
        d.big_track = not (isinstance(d.popularity, int) and d.popularity < sp.max_popularity)
        d.paid_priority = (None if paying is None else (isinstance(d.user_id, int) and d.user_id in paying))
        why = why_not(r, sp, policy, engaged)
        if why and why.startswith(ENGAGED_PREFIX):
            res.engaged_excluded += 1
        kind = None
        if why is None and isinstance(r.get("userId"), int):
            such = fan_of.get(r["userId"], set())
            if such is None:
                why = f"{FANOUT_PREFIX} unreadable: velocity-class hold (not a reject)"
                res.fanout_held += 1
            elif len(such) >= FANOUT_MIN and str(r.get("id")) in such:
                why = (f"{FANOUT_PREFIX}={len(such)} >= {FANOUT_MIN} (requests on the claimant's own earlier Muso "
                       "credits within 7 days): velocity-class review hold, not a reject")
                res.fanout_held += 1
        if why is None:
            kind, held = anchor_of.get(str(r.get("id")), (None, f"{NO_ANCHOR_PREFIX}: not classified"))
            if held:
                why = held
                res.no_anchor += 1
        if why is None:
            # The decider's editorial rule (captain 2026-10-15: editing/editorial roles are high risk):
            # only a trusted source naming this profile in the role approves one, and only under pop 30;
            # never the validator's verdict alone. 2026-10-22 22:40Z: 3 Producer+Editorial rows were
            # score-approved on the validator alone before this rule existed here.
            editorial = [x for x in (r.get("credits") or []) if is_editorial(str(x), policy.editorial_role_terms)]
            if editorial:
                pop = d.popularity if isinstance(d.popularity, int) else None
                if pop is None or pop >= decide.EDITORIAL_MID_POPULARITY:
                    why = (f"editorial role ({', '.join(editorial)}) on a track at pop >= "
                           f"{decide.EDITORIAL_MID_POPULARITY} (or unknown): documentation required")
                elif kind != "trusted":
                    why = (f"editorial role ({', '.join(editorial)}): only a trusted source naming this profile in "
                           "the role approves it, never the validator's verdict alone: proof path")
                else:
                    # The decider's editorial-velocity hold (pre_model): editorial weighs double against
                    # the 24 h / 7 d velocity thresholds. Velocity unreadable = held.
                    sig = vel_of.get(str(r.get("id")))
                    if sig is None:
                        why = (f"editorial role ({', '.join(editorial)}): the claimant's request velocity could "
                               "not be read this run: held, retried")
                    else:
                        velocity = decide.editorial_velocity(SimpleNamespace(profile=sig))
                        if velocity:
                            why = (f"editorial role ({', '.join(editorial)}): high velocity, editorial weighs "
                                   f"double ({velocity})")
                if why:
                    res.editorial_held += 1
        if why is None and len(approve) >= sp.max_per_run:
            why = f"per-run pace of {sp.max_per_run} reached: next run"
            res.capped += 1
        if why is None and isinstance(d.user_id, int) and today.get(d.user_id, 0) >= policy.max_approvals_per_user_per_day:
            why = f"user reached {policy.max_approvals_per_user_per_day} approvals today"
            res.capped += 1
        if why is None and isinstance(d.user_id, int) and by_user.get(d.user_id, 0) >= sp.per_user_per_day:
            why = f"user reached {sp.per_user_per_day} score approvals today"
            res.capped += 1
        if why is None and by_profile.get(d.profile_id, 0) >= sp.per_profile_per_day:
            why = f"profile reached {sp.per_profile_per_day} score approvals today"
            res.capped += 1
        if why is None and fleet >= sp.fleet_per_day:
            why = f"fleet reached {sp.fleet_per_day} score approvals today"
            res.capped += 1
        if why is None:
            # Captain 2026-10-26 23:30-23:40Z / steward 019: the shared account gate decides last; only an
            # explicit allow approves (hold / unknown / any failure = skip, no approval).
            g = gate(d.user_id)
            if not g.allowed:
                why = f"{g.why()}: no approval, proof ask"
                res.account_held += 1
            else:
                # Captain 2026-11-14: an allow is not enough. Only a green account is approved here; an
                # amber (fraud watch) one, a released red one and an unread band are not
                # (account_gate.watch_refusal). Before this the watch excluded nobody from this job.
                watch = account_gate_mod.watch_refusal(g)
                if watch:
                    why = f"{watch}: no score approval"
                    res.watch_held += 1
        if why is None:
            d.evidence_kind = TRUSTED_EVIDENCE_KIND if kind == "trusted" else EVIDENCE_KIND
            res.anchor_kinds[kind] = res.anchor_kinds.get(kind, 0) + 1
            decide._set(d, "approve", f"score approval anchor_kind={kind} "
                                      f"({'trusted-source credit: band A, no provisional window' if kind == 'trusted' else 'provisional band B, verify note'}; "
                                      f"captain 2026-10-20 'approve low risk credits'): the validator "
                                      f"approved it at total risk {r['verificationData']['total_risk_percent']:g} < "
                                      f"{sp.max_total_risk:g}; no conflict, no reject rule, server guard clear, "
                                      f"popularity {d.popularity}, no org role, not on a hold list")
            if audit_sampled(d.request_id, r.get("credits") or [], now.strftime("%Y-%m-%d")):
                d.reason += " [audit sample]"
                res.audit_sampled += 1
            approve.append(d)
            if isinstance(d.user_id, int):
                today[d.user_id] = today.get(d.user_id, 0) + 1
                by_user[d.user_id] = by_user.get(d.user_id, 0) + 1
            by_profile[d.profile_id] = by_profile.get(d.profile_id, 0) + 1
            fleet += 1
            res.paid_first += 1 if d.paid_priority else 0
        else:
            decide._set(d, "defer" if "next run" in why or "today" in why else "hold", f"score approval not now: {why}")
            res.held[_reason_class(why)] = res.held.get(_reason_class(why), 0) + 1
        decide.record_decision(db, res.run_id, mode, d, now)
    ids = [d.request_id for d in approve]
    status_of = {rid: (rows[rid].get("status") if rows[rid].get("status") in HELD_STATUSES else decide.UVN)
                 for rid in ids}
    if mode == "shadow":
        res.would_approve = len(ids)
        for rid in ids:
            decide.record_outcome(db, res.run_id, rid, "approve", "shadow", now)
        return res
    # QA @7c371efa: file any sampled approval a previous run committed but never filed (killed,
    # timed out, crashed between a write and its filing) BEFORE approving anything new.
    if not write_audit_sample(db, res, now, since=(now - timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")):
        for rid in ids:
            decide.record_outcome(db, res.run_id, rid, "approve", "skipped:audit_unwritable", now)
        return res
    # QA @f88ed225 (2): no approval may be written that its audit sample cannot follow.
    try:
        # QA @389d0d62: probe the ACTUAL daily sample file (opened for append, nothing written),
        # not a sibling, so a target that cannot take the sample stops the run before any approval.
        AUDIT_DIR.mkdir(parents=True, exist_ok=True)
        with open(AUDIT_DIR / f"{now.strftime('%Y-%m-%d')}.jsonl", "a", encoding="utf-8"):
            pass
    except OSError as exc:
        for rid in ids:
            decide.record_outcome(db, res.run_id, rid, "approve", "skipped:audit_unwritable", now)
        write_audit_sample_failed(res, now, exc)
        return res
    writer = writer or decide.admin_writer(requester=REQUESTER, automation_flag="CREDIT_TRUST_SCORE_APPROVE",
                                           timeout_s=WRITE_PUT_TIMEOUT_S)
    readback = readback or decide.status_readback(timeout_s=WRITE_READBACK_TIMEOUT_S)
    groups = [(st, [rid for rid in ids if status_of[rid] == st]) for st in HELD_STATUSES]
    who = {d.request_id: d for d in approve}
    race = SimpleNamespace(admin=admin, rows=rows, engaged=engaged, sleep=sleep or _time.sleep, spent=[0])
    try:
        _write_batches(db, res, now, policy, sp, ids, groups, who, writer, readback, paused, day_start, t0, _time,
                       race)
    except decide.WriteLockBusy:
        # QA @1347 00:02Z: the lock wait is inside the run budget. A peer holding the lock past the last moment
        # a batch can still finish = nothing written this run (transient, next run), never a cron kill.
        for rid in ids:
            decide.record_outcome(db, res.run_id, rid, "approve", "skipped:write_lock_busy", datetime.now(timezone.utc))
        res.note = (res.note + "; " if res.note else "") + "write lock busy until the write budget ran out; the rest next run"
    return res


def settle_lost_race(db, res, lost: list[str], who, policy, sp, writer, readback, t0, _time, race) -> None:
    """Core answered ``lost_race`` for ``lost``. Read each row again and record what the read shows, one
    outcome row per send:

      * it reads exactly as it did when it was decided -> GUARD_REFUSED. Nothing moved it, so a second send
        would get the same answer; recently_guard_refused() keeps it out of the next runs;
      * it changed and the same decision still stands on the new row (same decision_inputs, why_not still
        clear) -> ``skipped:lost_race:retrying``, then ONE more conditional PUT expecting the status just
        read. That send's outcome is recorded as core gave it; a second ``lost_race`` is
        ``skipped:retry_exhausted:lost_race``;
      * it changed and the decision no longer stands on it -> ``skipped:lost_race:decision_stale``: the
        next run decides it from the start;
      * it is in no held status any more -> ``skipped:lost_race:left_held``;
      * it could not be read -> ``skipped:lost_race:state_unread:<why>``. Unread is not unchanged: the row
        is neither called a guard refusal nor cooled.

    No rule is applied here that the run did not already apply: a row is sent again only when every input
    the decision was made on is byte-equal, and through the same conditional PUT and gate chain."""
    prefix = f"skipped:{CORE_LOST_RACE}"

    def final(rid: str, out: str) -> None:
        decide.record_outcome(db, res.run_id, rid, "approve", out, datetime.now(timezone.utc))
        if out == decide.APPROVED:
            res.approved += 1
        elif out.startswith("skipped:"):
            k = out.split(":", 1)[1][:60]
            res.skipped_by_server[k] = res.skipped_by_server.get(k, 0) + 1

    pending = list(lost)        # core's answer not yet on file
    resending: list[str] = []   # sent a second time, that send's answer not yet on file
    try:
        fresh, unread = fresh_rows(race.admin, {rid: who[rid].profile_id for rid in lost}, sleep=race.sleep,
                                   clock=_time.monotonic, deadline=t0 + RUN_BUDGET_S, spent=race.spent)
        again: dict[str, list[str]] = {}
        for rid in lost:
            now_row, was = fresh.get(rid), race.rows[rid]
            if now_row is None:
                out = f"{prefix}:state_unread:{unread[rid]}" if rid in unread else f"{prefix}:left_held"
            elif row_state(now_row) == row_state(was):
                out = GUARD_REFUSED
                res.guard_refused += 1
            elif (decision_inputs(now_row) != decision_inputs(was)
                  or why_not(now_row, sp, policy, race.engaged) is not None):
                out = f"{prefix}:decision_stale"
            else:
                again.setdefault(now_row["status"], []).append(rid)
                continue
            final(rid, out)
            pending.remove(rid)
        for status, chunk in again.items():
            if _time.monotonic() + WRITE_BATCH_WORST_S > t0 + RUN_BUDGET_S:
                for rid in chunk:
                    final(rid, f"{prefix}:changed_not_resent:time_budget")
                    pending.remove(rid)
                continue
            for rid in chunk:   # the first send, on the record before the second is made
                decide.record_outcome(db, res.run_id, rid, "approve", f"{prefix}:retrying", datetime.now(timezone.utc))
                pending.remove(rid)
            res.retried += len(chunk)
            resending = list(chunk)
            outs, err = decide.write_chunk(writer, readback, decide.APPROVED, chunk, status)
            if err is not None:
                res.write_errors.append(f"approve re-send of {len(chunk)}: {err}"[:200])
            for rid, out in outs.items():
                res.retry_landed += 1 if out == decide.APPROVED else 0
                final(rid, f"skipped:retry_exhausted:{CORE_LOST_RACE}" if out == prefix else out)
                resending.remove(rid)
    except Exception as exc:  # no send is left without the outcome it had
        res.write_errors.append(f"settling {len(pending) + len(resending)} lost_race answer(s): {exc}"[:200])
        for rid in pending:
            final(rid, f"{prefix}:state_unread:{type(exc).__name__}")
        for rid in resending:   # the second send may have committed: decide's word for a write nobody confirmed
            final(rid, f"error:unverified:re-send raised {type(exc).__name__}")


def _write_batches(db, res, now, policy, sp, ids, groups, who, writer, readback, paused, day_start, t0, _time,
                   race) -> None:
    lock_wait = max(0.0, t0 + RUN_BUDGET_S - WRITE_BATCH_WORST_S - _time.monotonic())
    with decide.write_lock(wait_s=lock_wait):
        for st, chunk in ((st, g[i:i + decide.BATCH]) for st, g in groups for i in range(0, len(g), decide.BATCH)):
            # QA @6c2a51b4 (4): an audit pause stops the run between batches, not just at start.
            why_paused = paused()
            out_of_time = _time.monotonic() + WRITE_BATCH_WORST_S > t0 + RUN_BUDGET_S
            if why_paused or out_of_time:
                for st2, g in groups:
                    for rid in g:
                        if not db.execute("SELECT 1 FROM decision_outcomes WHERE run_id=? AND request_id=?",
                                          (res.run_id, rid)).fetchone():
                            decide.record_outcome(db, res.run_id, rid, "approve",
                                                  "skipped:paused" if why_paused else "skipped:time_budget",
                                                  datetime.now(timezone.utc))
                if why_paused:
                    res.paused_mid_run = True
                    res.note = (res.note + "; " if res.note else "") + f"PAUSED mid-run ({why_paused[:120]}): rest not written"
                else:
                    res.note = (res.note + "; " if res.note else "") + (
                        f"write budget: no batch can finish by {RUN_BUDGET_S}s; the rest next run")
                break
            # QA @6c2a51b4 (1): caps re-read from COMMITTED outcomes (every run, every process)
            # under the lock, so two overlapping runs cannot both pass a cap.
            today = decide.approvals_today_by_user(db, day_start)
            by_user, by_profile, fleet = written_today(db, day_start)
            ok_chunk = []
            for rid in chunk:
                d = who[rid]
                over = None
                if isinstance(d.user_id, int) and today.get(d.user_id, 0) >= policy.max_approvals_per_user_per_day:
                    over = "user_daily_cap"
                elif isinstance(d.user_id, int) and by_user.get(d.user_id, 0) >= sp.per_user_per_day:
                    over = "user_score_cap"
                elif by_profile.get(d.profile_id, 0) >= sp.per_profile_per_day:
                    over = "profile_score_cap"
                elif fleet >= sp.fleet_per_day:
                    over = "fleet_score_cap"
                if over:
                    decide.record_outcome(db, res.run_id, rid, "approve", f"skipped:{over}_at_write",
                                          datetime.now(timezone.utc))
                    res.capped += 1
                    continue
                ok_chunk.append(rid)
                if isinstance(d.user_id, int):
                    today[d.user_id] = today.get(d.user_id, 0) + 1
                    by_user[d.user_id] = by_user.get(d.user_id, 0) + 1
                by_profile[d.profile_id] = by_profile.get(d.profile_id, 0) + 1
                fleet += 1
            if not ok_chunk:
                continue
            # Conditional PUT: core writes only if the row is still in the status we read.
            outs, err = decide.write_chunk(writer, readback, decide.APPROVED, ok_chunk, st)
            done = datetime.now(timezone.utc)
            if err is not None:
                res.write_errors.append(f"approve batch of {len(ok_chunk)}: {err}"[:200])
            lost = [rid for rid, out in outs.items() if out == f"skipped:{CORE_LOST_RACE}"]
            for rid, out in outs.items():
                if rid in lost:
                    continue
                decide.record_outcome(db, res.run_id, rid, "approve", out, done)
                if out == decide.APPROVED:
                    res.approved += 1
                elif out.startswith("skipped:"):
                    k = out.split(":", 1)[1][:60]
                    res.skipped_by_server[k] = res.skipped_by_server.get(k, 0) + 1
            if lost:
                # Core's lost_race is not yet an outcome: it is read again first, in this batch and under
                # the same lock, so the caps the next batch reads already hold whatever the re-send landed.
                settle_lost_race(db, res, lost, who, policy, sp, writer, readback, t0, _time, race)
            # QA @7c371efa: file this batch's sample now, not only at the end of the run.
            if not write_audit_sample(db, res, now):
                res.note = (res.note + "; " if res.note else "") + "audit filing failed: rest not written"
                break
    return


def write_audit_sample(db, res: "ScoreResult", now: datetime, since: str | None = None) -> bool:
    """The audit sample (condition 10): every server-confirmed score approval marked [audit sample]
    (any run of this automation) approved at or after ``since`` (default: this run's) that is
    not yet in an audit file is appended to <AUDIT_DIR>/<run day>.jsonl. Idempotent (keyed
    on run id + request id), so it runs at the start of every apply run (reconciling a run that
    died between a committed write and its filing, QA @7c371efa) and after every batch. False
    (and the run paused, see write_audit_sample_failed) when the sample cannot be filed."""
    try:
        if since is None:
            q, args = "d.run_id = ?", (res.run_id,)
        else:
            q, args = "o.at >= ?", (since,)
        rows = db.execute("SELECT d.request_id, d.user_id, d.profile_id, d.track_title, d.claimed_roles, d.popularity, "
                          "d.run_id, o.at FROM decisions d JOIN decision_outcomes o ON o.request_id = d.request_id AND "
                          "o.run_id = d.run_id WHERE " + q + " AND d.evidence_kind IN (?, ?) AND d.mode = 'apply' AND "
                          "o.action = 'approve' AND o.outcome = 'approved' AND d.reason LIKE '%[audit sample]'",
                          (*args, EVIDENCE_KIND, TRUSTED_EVIDENCE_KIND)).fetchall()
        if not rows:
            return True
        AUDIT_DIR.mkdir(parents=True, exist_ok=True)
        filed: set[tuple[str, str]] = set()
        oldest = (now - timedelta(days=9)).strftime("%Y-%m-%d")
        for f in sorted(AUDIT_DIR.glob("*.jsonl")):
            if f.stem >= oldest and f.is_file():
                for line in f.read_text(encoding="utf-8").splitlines():
                    try:
                        j = json.loads(line)
                        filed.add((str(j.get("run_id")), str(j.get("request_id"))))
                    except ValueError:
                        continue
        for rid, uid, pid, title, roles, pop, run_id, at in rows:
            if (str(run_id), str(rid)) in filed:
                continue
            with open(AUDIT_DIR / f"{now.strftime('%Y-%m-%d')}.jsonl", "a", encoding="utf-8") as fh:
                fh.write(json.dumps({"request_id": rid, "user_id": uid, "profile_id": pid, "track_title": title,
                                     "claimed_roles": roles, "popularity": pop, "run_id": run_id, "approved_at": at,
                                     "automation": AUTOMATION, "grade": None}) + "\n")
            filed.add((str(run_id), str(rid)))
        return True
    except OSError as exc:
        write_audit_sample_failed(res, now, exc)
        return False


def write_audit_sample_failed(res: "ScoreResult", now: datetime, exc: OSError) -> None:
    """QA @f88ed225 (2): an audit sample that cannot be filed must stop later writes, or a bad
    cohort keeps being approved with nothing for the precision check to read. Self-pause (every
    later run is shadow until `score-approve --resume`) and fail this run."""
    res.audit_failed = True
    why = f"audit sample not written ({type(exc).__name__}: {exc})"[:200]
    res.note = (res.note + "; " if res.note else "") + why + "; score-approve PAUSED"
    try:
        PAUSE_FILE.parent.mkdir(parents=True, exist_ok=True)
        PAUSE_FILE.write_text(f"{now:%Y-%m-%dT%H:%M:%SZ} {why}\n", encoding="utf-8")
    except OSError as exc2:
        res.note += f"; the pause file could not be written either ({exc2})"[:200]
