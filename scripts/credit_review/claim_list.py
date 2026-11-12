"""claim_list: build, sign and install the claim list on a schedule (claim-list-build.timer), not by hand.

The claim list (/var/lib/hydra/credit-verify-outbound/claim-list.json) is what credit-verify-outbound's claim
families (claim-proof-ask, claim-status; paid and free) send from. The tick refuses a list that is not signed on
the deployed head (`list_signed_on_stale`) and the loader refuses one older than 30 h, so a list rebuilt by hand
goes stale at the next deploy and every claimant then waits on us in silence (07-12 November: five days).

This module is the hand pipeline (claim-lane-resume-c2 batches b3-b29) as one reviewed, scheduled run:

  1. the DEPLOYED core decider's dry-run lines (kubectl exec, `--no-judge`, never `--apply`): the bands;
  2. the audience rules, unchanged from the signed batches (proof ask = person claim in band B/C asked to
     `request_proof`, with a readable bound surface, never asked; status = every other pending claim; fraud-held
     accounts, the class-A reverts and the decline tray are never listed; one audience per user);
  3. the proof code of each ask (core's codeFor: HMAC-SHA256, pinned to core's own vectors in the tests);
  4. the header the loader and the tick require: `daily_check` (the placed-code check's own heartbeat) and
     `signed_on` (the deployed head this run was built and checked on);
  5. the sign-off: the deployed loader itself must accept the staged file, on the deployed head;
  6. an atomic install (backup, dot-temp on the same filesystem, sha256 verified, one rename).

Everything here is a READ except the files under STATE_DIR and the one rename of the live list. Nothing is sent:
the tick's own --check-recipients and gate decide every send (one note per claim ever).

UNMEASURED IS A FAILURE, NEVER AN EMPTY ANSWER. The hand builder read `asked`, the fraud holds and the ledger with
"stdout or nothing": an unreadable ledger meant "nobody was asked yet" and an unreadable hold file meant "nobody
is held". Unattended, that is a second ask or a note to a held account. Every read here raises `Unmeasured`; the
run then exits non-zero, the live list is left byte-for-byte as it was, and the unit's OnFailure pages.
"""
from __future__ import annotations

import fcntl
import hashlib
import hmac
import json
import os
import re
import shutil
import sqlite3
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from . import claim_proof_ask, verify_notify
from . import claim_status_list as csl
from .claim_audience import (assert_one_audience, drop_messaged_7d, drop_unreachable, one_audience_over_all_claims)
from .comm_state import ACCOUNT_HOLDS_MAX_AGE, Unknown, held_user_ids
from .evidence import parse_ts
from .verify_ledger import BLOCKING, MAX_ATTEMPTS

# -- the rules (unchanged from the signed batches b3-b29) ------------------------------------------------------------
CLASS_A_REVERTED = frozenset({217637, 1575004, 1583754})   # revocation-43-shape class A, reverted 10-30: never messaged
DECLINE_TRAY = frozenset({1604304, 1607654, 1608834, 1608918, 1609413, 1610051, 1610276, 1610840, 1614355, 1614946,
                          1617173, 1618974, 1619131, 1620572})
READABLE = (("spotify_bio:", "spotify"), ("well_known:", "website"), ("youtube_description:", "youtube"))
PLATFORMS = frozenset(p for _, p in READABLE)
SOURCE = ("scripts/claim-list-build.py (scheduled: claim-list-build.timer), read-only; bands from the deployed decider; "
          "fraud-held accounts + class-A + decline-tray claims excluded; one audience per user over all open claims, "
          "no-channel tray, messaged-7d drop")

# -- the decider read ------------------------------------------------------------------------------------------------
DECIDER_LIMIT = 5000                    # the queue was 2,045 on 11-07; a run that reaches the limit is CAPPED, not whole
DECIDER_TIMEOUT_S = 900                 # a full run measured ~70 s
DECIDER_UNREADABLE_MAX_RATIO = 0.10     # claims the decider itself could not read; above this the bands are not the queue
DECIDER_CMD = ("kubectl", "-n", "muso-prod", "exec", "deploy/core-backend-api", "--",
               "node", "scripts/claim-review-decider.js", "--no-judge", "--limit", str(DECIDER_LIMIT))
_HEADER = re.compile(r"^claim-review-decider: (\d+) pending claim\(s\) in scope \(([^)]*)\), mode=([A-Za-z-]+), ", re.M)
_ANY_CLAIM = re.compile(r"^claim (\d+) (?:PAID|free) ", re.M)
_LINE = re.compile(r"^claim (\d+) (PAID|free) (\w+) pop=\S+ age=(?:\d+|\?)d: CRS \d+ ([A-D]) (\w+)", re.M)
_WRITTEN = re.compile(r'"written":\s*true')
_DIGEST_END = "===== CLAIM REVIEW DIGEST END ====="

# -- core's proof code (src/services/claiming/claimProofChallenge.js + claimProofFlow.js codeFor) -------------------
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # no 0/O/1/I
CODE_PREFIX = "MUSO-"
CODE_LENGTH = 4
CODE_RE = re.compile(r"^MUSO-[A-HJ-NP-Z2-9]{4}$")
SECRET_MIN_LEN = 16

# -- where things live on node-8 (constants, not environment: a list that sends is not built from a caller's paths) --
LIVE_LIST = Path("/var/lib/hydra/credit-verify-outbound/claim-list.json")
STATE_DIR = Path("/var/lib/hydra/claim-list-build")           # under /var/lib, never /opt/hydra (the deploy rsyncs it)
KILL_FILE = Path("/etc/hydra/claim-list-build.disabled")
LEDGER = Path("/var/lib/hydra/credit-review/ledger.sqlite3")
HOLDS = Path("/opt/firstmate/fraud-lens/out/account_holds.jsonl")
DAILY_CHECK = Path("/var/lib/claim-proof-check/last-run.json")
CODE_SECRET = Path("/root/.config/muso/claim-proof.prod.secret")
KEEP_RUNS = 24                          # run dirs kept (a decider output is ~3 MB)
KEEP_BACKUPS = 48                       # replaced lists kept
PROFILE_BUDGET_S = 1800                 # the catalog reads; a healthy pass measured ~4 min
PROFILE_CHECK_EVERY = 50
HEAD_RETRIES = 2                        # a deploy that lands mid-build: build again on the new head, once

ROW_KEYS = ("claim_id", "user_id", "profile_id", "paid", "band", "profile_name", "profile_url", "code", "platform",
            "code_found", "filed_at", "at_risk", "audience")


class Unmeasured(RuntimeError):
    """A read or a check this run depends on did not answer. The run fails; nothing is installed."""

    def __init__(self, code: str, detail: str = ""):
        self.code = code
        self.detail = " ".join(str(detail).split())[:400]
        super().__init__(f"{code}: {self.detail}" if self.detail else code)


class HeadMoved(Unmeasured):
    """The deployed head changed while this run was building: its list is signed on a head that is gone."""


# -- 1. the decider's dry-run lines ----------------------------------------------------------------------------------

@dataclass
class Decider:
    band: dict[int, tuple[str, str, str]] = field(default_factory=dict)   # claim id -> (profile type, band, action)
    paid: dict[int, bool] = field(default_factory=dict)
    in_scope: int = 0
    unreadable: int = 0


def parse_decider(text: str, limit: int = DECIDER_LIMIT) -> Decider:
    """The decider's per-claim lines, or `Unmeasured` when the output is not ONE WHOLE DRY RUN of the queue.

    The 11-04 list was once built from a `--limit 2000` run of a 2,057-claim queue: the 57 claims past the cap had
    no line and silently got no message. A capped, cut-off or applying run is refused here, not built from."""
    heads = _HEADER.findall(text)
    if len(heads) != 1:
        raise Unmeasured("decider_no_header", f"{len(heads)} 'pending claim(s) in scope' lines (want exactly 1)")
    in_scope, scope, mode = int(heads[0][0]), heads[0][1], heads[0][2]
    if mode != "dry-run":
        raise Unmeasured("decider_not_dry_run", f"the decider ran in mode={mode}")
    if _WRITTEN.search(text):
        raise Unmeasured("decider_wrote", "the digest reports a written decision; this builder only reads dry runs")
    if scope != "paid first":
        raise Unmeasured("decider_scope", f"the run covered '{scope}', not the whole queue")
    if _DIGEST_END not in text:
        raise Unmeasured("decider_cut_off", "no digest END marker: the run did not finish")
    if in_scope < 1:
        raise Unmeasured("decider_empty", "0 pending claims in scope")
    if in_scope >= limit:
        raise Unmeasured("decider_capped", f"{in_scope} claims in scope reaches --limit {limit}: the queue is longer")
    seen = {int(c) for c in _ANY_CLAIM.findall(text)}
    if len(seen) != in_scope:
        raise Unmeasured("decider_incomplete", f"{len(seen)} claim lines for {in_scope} claims in scope")
    out = Decider(in_scope=in_scope)
    for cid, paid, ptype, band, action in _LINE.findall(text):
        out.band[int(cid)] = (ptype, band, action)
        out.paid[int(cid)] = paid == "PAID"
    out.unreadable = in_scope - len(out.band)
    if out.unreadable > in_scope * DECIDER_UNREADABLE_MAX_RATIO:
        raise Unmeasured("decider_unreadable", f"the decider could not read {out.unreadable} of {in_scope} claims")
    return out


def run_decider(cmd: tuple[str, ...] = DECIDER_CMD, timeout: int = DECIDER_TIMEOUT_S) -> tuple[str, str]:
    """(stdout, stderr) of one dry run in the deployed core image. Read-only: no --apply is ever passed, and
    `parse_decider` refuses any output whose own header does not say mode=dry-run."""
    if "--apply" in cmd:
        raise Unmeasured("decider_not_dry_run", "refusing to run the decider with --apply")
    try:
        p = subprocess.run(list(cmd), capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Unmeasured("decider_failed", f"{type(exc).__name__}: {exc}") from exc
    if p.returncode != 0:
        raise Unmeasured("decider_failed", f"rc={p.returncode}: {p.stderr[-300:]}")
    return p.stdout, p.stderr


# -- 2. the other reads (each one answers or raises) ----------------------------------------------------------------

def ledger_rows(sql: str, path: Path | None = None) -> list[tuple]:
    path = path or LEDGER
    try:
        con = sqlite3.connect(f"{Path(path).resolve().as_uri()}?mode=ro", uri=True, timeout=30)
        try:
            return con.execute(sql).fetchall()
        finally:
            con.close()
    except sqlite3.Error as exc:
        raise Unmeasured("ledger_unreadable", f"{path}: {exc}") from exc


def _claim_ids(raw: Any) -> set[int]:
    try:
        keys = json.loads(raw or "[]")
    except json.JSONDecodeError as exc:
        raise Unmeasured("ledger_unreadable", f"a claim-proof-ask row's request_ids_json does not parse ({exc})") from exc
    return {int(str(k)[6:]) for k in keys if isinstance(keys, list)
            and str(k).startswith("claim-") and str(k)[6:].isdigit()}


ASKED = BLOCKING + ("rejected",)      # a row that stops another ask: BLOCKING, or rejected at the attempt cap
DELIVERED = ("attempted", "sent")      # a row that reached the user: refused / skipped / rejected sent nothing


def _ask_rows(rows: Callable[[str], list[tuple]]) -> list[tuple[set[int], str, str]]:
    """(claim ids, account, status) of every claim-proof-ask row that counts as an ask.

    Two different questions read this: "may this claim be asked again?" (`read_asked`: the ledger's BLOCKING
    semantics, a deferred or retryable rejected row sent nothing so it is offered again) and "did this user
    receive something?" (`read_delivered` / `read_ask_users`: only an attempted or sent row did; a refused or
    skipped row is blocking but delivered nothing). `build` calls this ONCE and derives all three sets from the
    returned snapshot, so a row the outbound tick commits mid-build cannot make them disagree."""
    out: list[tuple[set[int], str, str]] = []
    for raw, status, attempts, account in rows("select request_ids_json, status, attempts, account_id "
                                               "from verify_messages where campaign='claim-proof-ask'"):
        if status in ASKED and (status != "rejected" or int(attempts or 0) >= MAX_ATTEMPTS):
            out.append((_claim_ids(raw), str(account or "").strip(), status))
    return out


def asked_claims(ask_rows: list[tuple[set[int], str, str]]) -> set[int]:
    """Claim ids that already got the code ask; a claim whose ask was only deferred is offered again."""
    asked: set[int] = set()
    for ids, _, _ in ask_rows:
        asked |= ids
    return asked


def delivered_claims(ask_rows: list[tuple[set[int], str, str]]) -> set[int]:
    """Claim ids whose ask reached the user (attempted = a send whose outcome was never recorded, so it may
    have landed). A refused or skipped ask reached nobody."""
    delivered: set[int] = set()
    for ids, _, status in ask_rows:
        if status in DELIVERED:
            delivered |= ids
    return delivered


def read_asked(rows: Callable[[str], list[tuple]] = ledger_rows) -> set[int]:
    return asked_claims(_ask_rows(rows))


def read_delivered(rows: Callable[[str], list[tuple]] = ledger_rows) -> set[int]:
    return delivered_claims(_ask_rows(rows))


def _accounts(rows: Callable[[str], list[tuple]], sql: str) -> set[str]:
    return {str(a).strip() for (a,) in rows(sql) if str(a).strip()}


def owing_accounts(pending: set[int], ask_rows: list[tuple[set[int], str, str]]) -> set[str]:
    """Accounts that OWE a code: a DELIVERED ask on a claim that is STILL pending. An ask on a claim that has
    since closed does not silence a new claim, and an ask that was refused, skipped or merely deferred is not
    delivered: nothing reached that user, so if the claim can no longer be asked (no readable surface now) its
    status line must still go out - otherwise the claimant gets neither message (QA review 5869802116 of
    hydra#1903)."""
    return {account for ids, account, status in ask_rows if account and status in DELIVERED and ids & pending}


def read_ask_users(pending: set[int], rows: Callable[[str], list[tuple]] = ledger_rows) -> set[str]:
    return owing_accounts(pending, _ask_rows(rows))


def read_forbidden(rows: Callable[[str], list[tuple]] = ledger_rows) -> set[str]:
    return _accounts(rows, "select distinct account_id from verify_messages where account_id is not null and "
                           "lower(coalesce(reason,'')||' '||coalesce(api_log,'')) like '%action_forbidden%'")


def read_messaged_7d(rows: Callable[[str], list[tuple]] = ledger_rows) -> set[str]:
    return _accounts(rows, "select distinct account_id from verify_messages where status='sent' and account_id is not null "
                           "and coalesce(sent_at, created_at) >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-7 days')")


@dataclass(frozen=True)
class Holds:
    """The fraud lens's held accounts, and which healthy case the file was in: `ok` (n held) or `empty` (valid,
    nobody held). A missing, stale or unparseable file raises instead."""
    ids: set[str]

    @property
    def state(self) -> str:
        return "ok" if self.ids else "empty"


def read_holds(path: Path | None = None, bands: Path | None = None, now: float | None = None) -> Holds:
    """Account ids the fraud lens holds, through comm_state.held_user_ids (the one reader of the ledger: the latest
    row per user wins, so a release is not a hold). Missing, stale, future-dated or unparseable is `Unmeasured`,
    never "nobody"; a valid file that currently holds nobody is a healthy empty hold set."""
    path = path or HOLDS
    now = time.time() if now is None else now
    try:
        age = now - os.path.getmtime(path)
    except OSError as exc:
        raise Unmeasured("holds_unreadable", f"{path}: {type(exc).__name__}") from exc
    if age > ACCOUNT_HOLDS_MAX_AGE:
        raise Unmeasured("holds_stale", f"{path} is {int(age // 3600)}h old (> {ACCOUNT_HOLDS_MAX_AGE // 3600}h)")
    if age < -300:
        raise Unmeasured("holds_stale", f"{path} mtime is in the future; age unknown")
    try:
        held = held_user_ids(str(path), str(bands) if bands else None, now)
    except Unknown as exc:
        raise Unmeasured("holds_unreadable", f"{path}: {exc}") from exc
    return Holds(held)


def read_profiles(profile_ids: list[str], reader: csl.ProfileReader = csl.muso_profile, *,
                  clock: Callable[[], float] = time.monotonic) -> dict[str, dict[str, Any] | None]:
    """Catalog profile per id (None = this one profile is unreadable: its claim stays a status row with no name,
    exactly as the signed batches did). A catalog that is DOWN is not a list: at a systemic unreadable share, or
    past the time budget, the run fails (the claim_status_list r3 rule, hydra #1406)."""
    out: dict[str, dict[str, Any] | None] = {}
    total, bad, started = len(profile_ids), 0, clock()
    limit = total * csl.UNREADABLE_SYSTEMIC_RATIO
    for n, pid in enumerate(profile_ids, 1):
        out[pid] = reader(pid)
        bad += out[pid] is None
        if n % PROFILE_CHECK_EVERY == 0 or n == total:
            if total and bad >= limit:
                raise Unmeasured("catalog_unreadable", f"{bad} of {total} profiles unreadable after {n} reads")
            if clock() - started > PROFILE_BUDGET_S:
                raise Unmeasured("catalog_too_slow", f"{n} of {total} profiles read in {PROFILE_BUDGET_S}s")
    return out


def read_daily_check(path: Path | None = None, now: datetime | None = None) -> dict[str, str]:
    """The placed-code check's own heartbeat ({owner, last_run_at}), written only by a check that completed.
    The ask says "we check for it every day": a list is not signed while that is untrue."""
    path = path or DAILY_CHECK
    now = now or datetime.now(timezone.utc)
    try:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise Unmeasured("daily_check_unreadable", f"{path}: {type(exc).__name__}") from exc
    owner = str(doc.get("owner") or "").strip() if isinstance(doc, dict) else ""
    ran = parse_ts(doc.get("last_run_at")) if isinstance(doc, dict) else None
    if not owner or ran is None:
        raise Unmeasured("daily_check_unreadable", f"{path} names no owner + last_run_at")
    age_h = (now - ran).total_seconds() / 3600
    if age_h > claim_proof_ask.DAILY_CHECK_MAX_AGE_H or age_h < -0.1:
        raise Unmeasured("daily_check_stale", f"the placed-code check last ran {age_h:.1f}h ago "
                                              f"(limit {claim_proof_ask.DAILY_CHECK_MAX_AGE_H}h)")
    return {"owner": owner, "last_run_at": str(doc["last_run_at"])}


def read_secret(path: Path | None = None) -> str:
    path = path or CODE_SECRET
    try:
        secret = Path(path).read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise Unmeasured("code_secret_unreadable", f"{path}: {type(exc).__name__}") from exc
    if len(secret) < SECRET_MIN_LEN:
        raise Unmeasured("code_secret_unreadable", f"{path} holds fewer than {SECRET_MIN_LEN} characters")
    return secret


def deployed_head() -> str:
    head = verify_notify.deployed_head()
    if not head:
        raise Unmeasured("deployed_head_unreadable", f"{verify_notify.DEPLOYED_SHA_PATH} is not a 40-hex sha")
    return head


# -- 3. the audience (pure) ------------------------------------------------------------------------------------------

def classify(decider: Decider, facts: csl.Facts, asked: set[int], held: set[str],
             prof: dict[str, dict[str, Any] | None],
             bound: Callable[[dict[str, Any]], Any] = csl.bound_surfaces,
             delivered: set[int] | None = None) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """One row per listed claim and the count of every group that is not. The rule set of the signed batches,
    line for line; the tests pin each branch."""
    byid = {c["id"]: c for c in facts.claims}
    delivered_set = delivered or set()
    counts: dict[str, Any] = {k: 0 for k in (
        "decider_paid", "not_pending_now", "decline_tray", "ask", "status", "status_org", "status_hold",
        "status_band_d", "status_no_readable_surface", "status_account_held", "status_already_asked",
        "status_ask_not_delivered", "status_profile_unreadable")}
    counts["decider_paid"] = sum(1 for v in decider.paid.values() if v)
    counts["decider_free"] = sum(1 for v in decider.paid.values() if not v)
    rows: list[dict[str, Any]] = []
    for cid in sorted(decider.band):
        ptype, b, action = decider.band[cid]
        c = byid.get(cid)
        if not c:
            counts["not_pending_now"] += 1
            continue
        if cid in DECLINE_TRAY or cid in CLASS_A_REVERTED:
            counts["decline_tray"] += 1
            continue
        if str(c["user_id"]) in held:        # never messaged, any audience
            counts["excluded_fraud_held"] = counts.get("excluded_fraud_held", 0) + 1
            continue
        pr = prof.get(c["profile_id"])
        base = {"claim_id": cid, "user_id": int(c["user_id"]), "profile_id": c["profile_id"], "paid": decider.paid[cid],
                "band": b, "profile_name": str((pr or {}).get("name") or "").strip(),
                "profile_url": csl.PROFILE_URL.format(c["profile_id"]), "code": "", "platform": "", "code_found": False,
                "filed_at": c["created_at"], "at_risk": c["team_id"] in facts.at_risk_teams}
        if ptype == "organization" or str((pr or {}).get("subType") or "") == "organization":
            why = "status_org"
        elif action != "request_proof" or b not in ("B", "C"):
            why = "status_hold" if action == "hold" else "status_band_d"
        elif pr is None:
            why = "status_profile_unreadable"
        elif cid in asked:
            why = "status_already_asked" if cid in delivered_set else "status_ask_not_delivered"
        else:
            surfaces = bound(pr)
            plat = next((p for pre, p in READABLE if any(s.startswith(pre) for s in surfaces)), None)
            if plat:
                rows.append({**base, "platform": plat, "audience": "proof_ask"})
                counts["ask"] += 1
                continue
            why = "status_no_readable_surface"
        counts[why] += 1
        counts["status"] += 1
        if why != "status_already_asked":
            rows.append({**base, "audience": "status"})
    return rows, counts


def apply_audience(rows: list[dict[str, Any]], counts: dict[str, Any], *, ask_users: set[str], forbidden: set[str],
                   messaged: set[str]) -> list[dict[str, Any]]:
    """p1 + r5 10-31 / p1 157: one audience per user over ALL open claims, the no-channel tray, the gate's own
    messaged-7d rule; a list that still holds a user in both audiences refuses the run (claim_audience)."""
    rows = one_audience_over_all_claims(rows, counts, ask_users)
    rows = drop_unreachable(rows, counts, forbidden)
    rows = drop_messaged_7d(rows, counts, messaged)
    assert_one_audience(rows)
    rows.sort(key=lambda r: (r["audience"] != "proof_ask", not r["at_risk"], r["filed_at"], r["claim_id"]))
    return rows


# -- 4. codes and the signature --------------------------------------------------------------------------------------

def code_for(claim_id: Any, profile_id: Any, user_id: Any, secret: str) -> str:
    """core's codeFor: 'MUSO-' + 4 characters from HMAC-SHA256(secret, 'claimId:profileId:userId'). The placed-code
    check derives the code it looks for with the same function, so a drift here is a code nobody can ever place:
    scripts/tests/test_claim_list.py pins this against vectors printed by core's own implementation."""
    if not secret:
        raise Unmeasured("code_secret_unreadable", "claim proof: secret is required")
    msg = f"{claim_id}:{profile_id}:{'' if user_id is None else user_id}".encode()
    mac = hmac.new(secret.encode(), msg, hashlib.sha256).digest()
    return CODE_PREFIX + "".join(CODE_ALPHABET[b % len(CODE_ALPHABET)] for b in mac[:CODE_LENGTH])


def sign(doc: dict[str, Any], *, head: str, daily_check: dict[str, str], secret: str) -> dict[str, Any]:
    for c in doc["claims"]:
        if c.get("audience") == "proof_ask":
            c["code"] = code_for(c["claim_id"], c["profile_id"], str(c["user_id"]), secret)
    doc["daily_check"] = dict(daily_check)
    doc["signed_on"] = head
    return doc


def assert_codes_unchanged(prev: Any, doc: dict[str, Any]) -> int:
    """A claim's code never changes: the claimant may already have it. Compared against the list being replaced
    (the same claim, profile and user); returns how many codes were compared. A changed code refuses the run."""
    old = {}
    for c in (prev.get("claims") if isinstance(prev, dict) else None) or []:
        if isinstance(c, dict) and CODE_RE.match(str(c.get("code") or "")):
            old[(c.get("claim_id"), c.get("profile_id"), c.get("user_id"))] = c["code"]
    same, moved = 0, []
    for c in doc["claims"]:
        was = old.get((c["claim_id"], c["profile_id"], c["user_id"]))
        if was is None or c["audience"] != "proof_ask":
            continue
        same += 1
        if was != c["code"]:
            moved.append(c["claim_id"])
    if moved:
        raise Unmeasured("code_changed", f"{len(moved)} claim(s) would get a different code than the installed list "
                                         f"gave them: {moved[:10]}")
    return same


def check_rows(doc: dict[str, Any], head: str) -> None:
    """The shape a list must have before the loader is even asked."""
    rows = doc.get("claims")
    if not isinstance(rows, list) or not rows:
        raise Unmeasured("empty_list", "the build produced no rows")
    if doc.get("signed_on") != head or not re.fullmatch(r"[0-9a-f]{40}", str(head)):
        raise Unmeasured("not_signed", f"signed_on {doc.get('signed_on')!r} is not the deployed head {head!r}")
    seen: set[int] = set()
    for r in rows:
        missing = [k for k in ROW_KEYS if k not in r]
        if missing:
            raise Unmeasured("bad_row", f"claim {r.get('claim_id')}: missing {missing}")
        if not isinstance(r["claim_id"], int) or not isinstance(r["user_id"], int) or r["claim_id"] in seen:
            raise Unmeasured("bad_row", f"claim {r['claim_id']!r}: id not an integer, or listed twice")
        seen.add(r["claim_id"])
        if r["audience"] == "proof_ask":
            if not CODE_RE.match(str(r["code"])) or r["platform"] not in PLATFORMS:
                raise Unmeasured("bad_row", f"claim {r['claim_id']}: a code ask without a code or a readable surface")
        elif r["audience"] == "status":
            if r["code"] or r["platform"]:
                raise Unmeasured("bad_row", f"claim {r['claim_id']}: a status row carrying a code")
        else:
            raise Unmeasured("bad_row", f"claim {r['claim_id']}: audience {r['audience']!r}")
    assert_one_audience(rows)


def loader_accepts(path: Path, head: str) -> None:
    """The sign-off: the DEPLOYED loader (the code the tick is about to run) reads the staged file - fresh, with a
    recent daily check - and binds the head this run read from the deploy record. `signed_on` therefore means what
    it says: this file, checked by this head's loader. The loader's process-wide binding is put back afterwards."""
    was = verify_notify.LIST_SIGNED_ON
    try:
        claims, why = claim_proof_ask.load_list(str(path))
        bound = verify_notify.LIST_SIGNED_ON
    finally:
        verify_notify.LIST_SIGNED_ON = was
    if why:
        raise Unmeasured("loader_refused", why)
    if not claims:
        raise Unmeasured("loader_refused", "the loader read no claims")
    if bound != head:
        raise Unmeasured("loader_refused", f"the loader bound signed_on {bound!r}, not {head}")


# -- 5. one build ----------------------------------------------------------------------------------------------------

@dataclass
class Reads:
    """Every external read of a build, injectable (the tests fake all of them; production uses the defaults)."""
    decider: Callable[[], tuple[str, str]] = run_decider
    facts: Callable[[], csl.Facts] = lambda: csl.read_facts(csl.trino)
    ledger: Callable[[str], list[tuple]] = ledger_rows
    holds: Callable[[], Holds] = read_holds
    profile: csl.ProfileReader = csl.muso_profile
    bound: Callable[[dict[str, Any]], Any] = csl.bound_surfaces
    daily_check: Callable[[], dict[str, str]] = read_daily_check
    secret: Callable[[], str] = read_secret
    head: Callable[[], str] = deployed_head


def _utc(now: datetime | None = None) -> str:
    return (now or datetime.now(timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")


def build(reads: Reads, run_dir: Path, head: str) -> dict[str, Any]:
    """Read everything, apply the rules, sign on `head`. Returns the signed document; installs nothing."""
    daily = reads.daily_check()              # the cheap refusals first: no decider run for a list that cannot be signed
    secret = reads.secret()
    out, err = reads.decider()
    (run_dir / "decider.txt").write_text(out, encoding="utf-8")
    (run_dir / "decider.err").write_text(err, encoding="utf-8")
    decider = parse_decider(out)
    try:
        facts = reads.facts()
    except Unmeasured:
        raise
    except Exception as exc:  # Trino down, transient or not: this run has no facts
        raise Unmeasured("facts_unreadable", f"{type(exc).__name__}: {exc}") from exc
    if not facts.claims:
        raise Unmeasured("facts_unreadable", "the replica returned no pending claim")
    ask_rows = _ask_rows(reads.ledger)
    asked = asked_claims(ask_rows)
    delivered = delivered_claims(ask_rows)
    holds = reads.holds()
    held = holds.ids
    byid = {c["id"]: c for c in facts.claims}
    pids = sorted({byid[c]["profile_id"] for c in decider.band
                   if c in byid and csl.UUIDISH.match(byid[c]["profile_id"])})
    prof = read_profiles(pids, reads.profile)
    rows, counts = classify(decider, facts, asked, held, prof, reads.bound, delivered)
    rows = apply_audience(rows, counts, ask_users=owing_accounts(set(byid), ask_rows),
                          forbidden=read_forbidden(reads.ledger), messaged=read_messaged_7d(reads.ledger))
    counts["decider_in_scope"] = decider.in_scope
    counts["decider_unreadable"] = decider.unreadable
    counts["holds"] = holds.state
    counts["holds_count"] = len(held)
    doc = {"generated_at": _utc(), "source": SOURCE, "counts": counts, "claims": rows}
    return sign(doc, head=head, daily_check=daily, secret=secret)


# -- 6. install ------------------------------------------------------------------------------------------------------

def sha256_file(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _prune(directory: Path, keep: int) -> None:
    entries = sorted(directory.iterdir(), key=lambda p: p.name) if directory.is_dir() else []
    for old in entries[:-keep] if keep > 0 else entries:
        if old.is_dir():
            shutil.rmtree(old, ignore_errors=True)
        else:
            old.unlink(missing_ok=True)


def install(staged: Path, live: Path, state: Path, *, stamp: str) -> tuple[str, str]:
    """Replace the live list with the staged one: backup, dot-temp on the live file's filesystem, sha256 verified,
    ONE rename. Returns (previous sha256 or '', installed sha256). The tick reads the list once per tick, so a
    reader sees the old list or the new one, never a mix."""
    want = sha256_file(staged)
    prev = ""
    if live.exists():
        prev = sha256_file(live)
        backups = state / "prev"
        backups.mkdir(mode=0o700, parents=True, exist_ok=True)
        bak = backups / f"{stamp}-claim-list.{prev[:12]}.json"
        fd = os.open(bak, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(live.read_bytes())
        if sha256_file(bak) != prev:
            raise Unmeasured("backup_failed", f"{bak} does not hash to the live list")
        _prune(backups, KEEP_BACKUPS)
    tmp = live.with_name(f".claim-list.new.{os.getpid()}")
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(staged.read_bytes())
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o600)
        if sha256_file(tmp) != want:
            raise Unmeasured("install_failed", "the copy does not hash to the staged list")
        os.replace(tmp, live)
    finally:
        tmp.unlink(missing_ok=True)
    got = sha256_file(live)
    if got != want:
        raise Unmeasured("install_failed", f"the live list hashes to {got[:12]}, staged {want[:12]}")
    return prev, got


# -- 7. the scheduled run --------------------------------------------------------------------------------------------

@dataclass
class Outcome:
    result: str                       # installed | dry_run | held | busy | failed
    reason: str = ""
    detail: str = ""
    at: str = ""
    signed_on: str = ""
    sha256: str = ""
    prev_sha256: str = ""
    rows: int = 0
    users: int = 0
    proof_ask: int = 0
    status: int = 0
    codes_compared: int = 0
    holds: str = ""
    attempts: int = 0
    seconds: float = 0.0
    run_dir: str = ""

    @property
    def rc(self) -> int:
        return 1 if self.result == "failed" else 0


def _record(state: Path, outcome: Outcome) -> None:
    """One line per run in builds.jsonl (append-only: the evidence that the schedule is building) and the last
    outcome in last-run.json. Best-effort: a full disk must not turn a good install into a failed run."""
    line = json.dumps(outcome.__dict__, sort_keys=True)
    try:
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        with open(state / "builds.jsonl", "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
        tmp = state / ".last-run.json.tmp"
        tmp.write_text(line + "\n", encoding="utf-8")
        os.replace(tmp, state / "last-run.json")
    except OSError:
        pass


def run(reads: Reads | None = None, *, live: Path | None = None, state: Path | None = None,
        kill: Path | None = None, dry_run: bool = False, now: Callable[[], datetime] | None = None) -> Outcome:
    """One scheduled build. Installs a list signed on the deployed head, or fails and installs nothing."""
    reads = reads or Reads()
    live, state, kill = live or LIVE_LIST, state or STATE_DIR, kill or KILL_FILE
    clock = now or (lambda: datetime.now(timezone.utc))
    started = time.monotonic()
    outcome = Outcome(result="failed", at=_utc(clock()))

    def done() -> Outcome:
        outcome.seconds = round(time.monotonic() - started, 1)
        _record(state, outcome)
        return outcome

    if kill.exists():
        outcome.result, outcome.reason = "held", f"kill file {kill} is present; nothing built"
        return done()
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock = open(state / "build.lock", "a")   # noqa: SIM115 - held for the whole run
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            outcome.result, outcome.reason = "busy", "another build holds the lock; nothing built"
            return done()
        stamp = clock().strftime("%Y%m%dT%H%M%SZ")
        run_dir = state / "runs" / stamp
        run_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        outcome.run_dir = str(run_dir)
        try:
            for attempt in range(1, HEAD_RETRIES + 1):
                outcome.attempts = attempt
                try:
                    _attempt(reads, live, state, run_dir, stamp, dry_run, outcome)
                    break
                except HeadMoved:
                    if attempt == HEAD_RETRIES:
                        raise
        except Unmeasured as exc:
            outcome.result, outcome.reason, outcome.detail = "failed", exc.code, exc.detail
        except SystemExit as exc:               # claim_audience.MixedAudience: a user in both audiences
            outcome.result, outcome.reason, outcome.detail = "failed", "mixed_audience", str(exc)[:400]
        except Exception as exc:                # a bug is a failed run too, and says so
            outcome.result, outcome.reason, outcome.detail = "failed", "builder_error", f"{type(exc).__name__}: {exc}"[:400]
        _prune(state / "runs", KEEP_RUNS)
        return done()
    finally:
        lock.close()


def _attempt(reads: Reads, live: Path, state: Path, run_dir: Path, stamp: str, dry_run: bool, outcome: Outcome) -> None:
    head = reads.head()
    doc = build(reads, run_dir, head)
    check_rows(doc, head)
    try:
        prev_doc = json.loads(live.read_text(encoding="utf-8")) if live.exists() else None
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        prev_doc = None                          # an unreadable old list has no codes to keep; the new one replaces it
    outcome.codes_compared = assert_codes_unchanged(prev_doc, doc)
    outcome.holds = (f"{doc['counts']['holds_count']}" +
                     (" (file valid, no account held)" if doc["counts"]["holds"] == "empty" else ""))
    staged = run_dir / "claim-list.json"
    fd = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1)
    loader_accepts(staged, head)
    rows = doc["claims"]
    outcome.signed_on, outcome.sha256, outcome.rows = head, sha256_file(staged), len(rows)
    outcome.users = len({r["user_id"] for r in rows})
    outcome.proof_ask = sum(1 for r in rows if r["audience"] == "proof_ask")
    outcome.status = len(rows) - outcome.proof_ask
    if reads.head() != head:                     # a deploy landed while this run was building
        raise HeadMoved("head_moved", f"built on {head[:12]}, deployed is now {reads.head()[:12]}")
    if dry_run:
        outcome.result, outcome.reason = "dry_run", f"staged at {staged}; the live list was not touched"
        return
    outcome.prev_sha256, installed = install(staged, live, state, stamp=stamp)
    outcome.result, outcome.reason, outcome.sha256 = "installed", "", installed


def render(outcome: Outcome) -> str:
    """One line for the journal."""
    if outcome.result in ("installed", "dry_run"):
        verb = "INSTALLED" if outcome.result == "installed" else "DRY RUN (not installed)"
        return (f"CLAIM LIST BUILD: {verb} sha256 {outcome.sha256} signed_on {outcome.signed_on} "
                f"rows {outcome.rows} users {outcome.users} proof_ask {outcome.proof_ask} status {outcome.status} "
                f"codes_unchanged {outcome.codes_compared} holds {outcome.holds} "
                f"prev_sha256 {outcome.prev_sha256 or '-'} attempts {outcome.attempts} in {outcome.seconds}s.")
    if outcome.result == "failed":
        return (f"CLAIM LIST BUILD: FAILED {outcome.reason}: {outcome.detail or '-'} "
                f"(nothing installed; the live list is unchanged; run dir {outcome.run_dir or '-'}).")
    return f"CLAIM LIST BUILD: nothing built: {outcome.reason}."
