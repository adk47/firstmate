"""L12 executor: carries out Fable-ruled credit-request CLOSES (status rejected) from tray files.

Authority: captain 2026-10-28 21:3xZ "move credits and profiles along ..." and 21:4xZ "yes approve all if
Fable confirms" (data/captain.md:586; approval_ref captain-1028-213x). Contract:
data/verify-program-lead-fable-l1/exec-plan-captain-1028-213x.md section (a). Registry:
policies/credit-approval-automation.json "fable-decider".

This version CLOSES only (unverified / user_verification_needed -> rejected). Approvals need a core automation
scope (agentApprovalGuard AUTOMATION_APPROVAL_SCOPES) and land in a separate change; an "approve" tray is
refused here.

Every row passes, at write time, against FRESH server facts (Trino on postgresql_core, read-only):
  - the tray carries a Fable ruling id on EVERY row (else the whole tray is refused);
  - the row exists, is not deleted, still has the tray's expected status, and still belongs to the tray's user;
  - a reject_* rule the ruling relies on still fires in verificationData (a close never invents a reason);
  - the track is known NOT big: server popularity 1..59 and not client-supplied metadata (unknown = big = refused);
  - the account gate answers allow (hold / unknown / timeout = refused) and the account is not watchlisted;
  - the kill file is absent and the registry entry is approved (re-read before every write);
  - the daily cap (100 writes/day, counted from the audit file) is not exhausted.
Every write goes through muso-admin-api.sh PUT /admin/credit-requests/conditional-status with expectedStatus
(the compare-and-set fence), is read back from Postgres, and writes one audit line per row (request id, user,
rule, ruling id, tray file + sha256, before/after). Nothing is ever deleted; a rejected row can be restored by a
named human (core: rejected -> user_verification_needed / approved).
"""
from __future__ import annotations

import contextlib
import csv
import fcntl
import hashlib
import io
import json
import os
import re
import subprocess
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

from . import account_gate

AUTOMATION_ID = "fable-decider"
REQUESTER = "fable-decider@hydra-ops"
ADMIN_IDENTITY = "credit-decider"          # the automation login the wrapper knows; core binds by header
CONDITIONAL_PATH = "/admin/credit-requests/conditional-status"
REGISTRY = os.environ.get("CREDIT_APPROVAL_REGISTRY", "/opt/hydra/policies/credit-approval-automation.json")
KILL_FILE = os.environ.get("FABLE_DECIDER_KILL_FILE", "/etc/hydra/fable-decider.disabled")
AUDIT_PATH = os.environ.get("FABLE_DECIDER_AUDIT", "/var/lib/hydra/credit-review/fable-decider-audit.jsonl")
TRINO = os.environ.get("FABLE_DECIDER_TRINO", "/opt/hydra/scripts/trino-query.sh")
DAILY_CAP = 100
CAP_CEILING = 400          # Fable 2026-10-28 21:29Z: 400/day ruled for the 364-row reject tray only
BATCH_MAX = 100
#: One lock from the cap check through reservation, PUT, read-back and final audit (QA #1475: two concurrent runs
#: must not both read the same count). Same file as the decider's credit-status write lock, so the executor
#: never writes concurrently with any other credit-status writer on the host either.
WRITE_LOCK = os.environ.get("CV_CREDIT_WRITE_LOCK_PATH", "/var/lib/hydra/credit-status-writes.lock")
CLOSE_STATUS = "rejected"
CLOSABLE_FROM = ("unverified", "user_verification_needed")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
RULING_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:|-]{2,120}$")
BIG_POPULARITY = 60
#: A close cites either a validator rule that fired (reject_*, re-checked live) or a Fable evidence rule from
#: rules.md (e.g. R-C2(4): a one-person role credited to somebody else on a complete same-run DSP snapshot),
#: which must come with its evidence text in the tray row.
#: Tray row fields carried verbatim into the audit (doc-verify's jan-forged-bN.json contract).
AUDIT_PASSTHROUGH = ("reason_code", "proof_id", "intake_id", "fraud_pair", "signal_ids", "outcome_ids", "subject",
                     "contributors")   # contributors: every forged document behind one request (QA #1480)
FABLE_RULE_RE = re.compile(r"^R-[A-Z0-9][A-Za-z0-9().-]{0,40}$")


class TrayError(ValueError):
    """The tray as a whole is unusable; nothing in it is executed."""


@dataclass(frozen=True)
class TrayRow:
    request_id: str
    user_id: int
    ruling_id: str
    rule: str
    paid: bool = False
    evidence: str = ""
    #: Copied VERBATIM into every audit line of this row (Fable [key=l11-registry-fraud-close]: a fraud_document
    #: close carries its two signals with where they sit, so a take-back is judged without re-reading the file).
    audit_extra: tuple[tuple[str, Any], ...] = ()


@dataclass(frozen=True)
class Tray:
    path: str
    sha256: str
    action: str
    expected_status: str
    rows: tuple[TrayRow, ...]
    daily_cap: int = DAILY_CAP
    cap_ruling_id: str | None = None
    #: Fable [key=junk-b1]: refuse a row whose request has a same-run DSP anchor (it belongs to the approve path);
    #: re-read from the V9 verifier store before each batch. No verdict / unreadable store = UNKNOWN = refused.
    refuse_if_dsp_anchor: bool = False


@dataclass(frozen=True)
class Facts:
    """What the server says about one request right now."""
    status: str | None
    user_id: int | None
    popularity: int | None
    deleted: bool
    rules: dict[str, float]
    metadata_source: str | None
    paid: bool
    profile_id: str | None = None


def load_tray(path: str) -> Tray:
    """Read and validate a tray file. Any row without a Fable ruling id refuses the WHOLE tray."""
    raw = Path(path).read_bytes()
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        raise TrayError(f"tray is not JSON: {exc}") from exc
    if not isinstance(doc, dict):
        raise TrayError("tray must be a JSON object")
    action = doc.get("action")
    if action != "reject":
        raise TrayError(f"action {action!r} is not executable here (this executor closes only: 'reject')")
    expected = doc.get("expected_status")
    if expected not in CLOSABLE_FROM:
        raise TrayError(f"expected_status must be one of {CLOSABLE_FROM}, got {expected!r}")
    rows_in = doc.get("rows")
    if not isinstance(rows_in, list) or not rows_in:
        raise TrayError("tray has no rows")
    rows, seen = [], set()
    for i, r in enumerate(rows_in):
        if not isinstance(r, dict):
            raise TrayError(f"row {i} is not an object")
        rid, uid, ruling, rule = r.get("request_id"), r.get("user_id"), r.get("ruling_id"), r.get("rule")
        if not isinstance(rid, str) or not UUID_RE.match(rid):
            raise TrayError(f"row {i}: request_id {rid!r} is not a UUID")
        if rid.lower() in seen:
            raise TrayError(f"row {i}: duplicate request_id {rid}")
        seen.add(rid.lower())
        if isinstance(uid, str) and uid.isdigit():
            uid = int(uid)
        if not isinstance(uid, int) or isinstance(uid, bool) or uid <= 0:
            raise TrayError(f"row {i}: user_id {r.get('user_id')!r} is not a positive integer")
        if not isinstance(ruling, str) or not RULING_RE.match(ruling):
            raise TrayError(f"row {i} ({rid}): no valid Fable ruling id; the whole tray is refused")
        evidence = r.get("evidence") if isinstance(r.get("evidence"), str) else ""
        if not isinstance(rule, str) or not (rule.startswith("reject_") or FABLE_RULE_RE.match(rule)):
            raise TrayError(f"row {i} ({rid}): rule {rule!r} is neither a validator reject_* rule nor a Fable R- rule")
        if not rule.startswith("reject_") and len(evidence.strip()) < 20:
            raise TrayError(f"row {i} ({rid}): Fable rule {rule} needs its evidence text in the row")
        extra = tuple((k, r[k]) for k in AUDIT_PASSTHROUGH if k in r)
        rows.append(TrayRow(rid, uid, ruling, rule, bool(r.get("paid")), evidence.strip(), extra))
    if doc.get("order") != "as_listed":
        rows.sort(key=lambda t: (not t.paid, t.user_id, t.request_id))   # paid first (default)
    cap, cap_ruling = DAILY_CAP, doc.get("cap_ruling_id")
    if "daily_cap" in doc:
        cap = doc.get("daily_cap")
        if not isinstance(cap, int) or isinstance(cap, bool) or not 1 <= cap <= CAP_CEILING:
            raise TrayError(f"daily_cap {cap!r} must be an integer 1..{CAP_CEILING}")
        if cap > DAILY_CAP and not (isinstance(cap_ruling, str) and RULING_RE.match(cap_ruling)):
            raise TrayError(f"daily_cap {cap} above {DAILY_CAP} needs a cap_ruling_id (a Fable ruling)")
    anchor_flag = doc.get("refuse_if_dsp_anchor", False)
    if not isinstance(anchor_flag, bool):
        raise TrayError("refuse_if_dsp_anchor must be true or false")
    return Tray(str(path), hashlib.sha256(raw).hexdigest(), action, expected, tuple(rows), cap,
                cap_ruling if isinstance(cap_ruling, str) else None, anchor_flag)


def _num(v: Any) -> float | None:
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def refusal(row: TrayRow, facts: Facts | None, gate: account_gate.GateResult, expected: str) -> str | None:
    """Why this row must NOT be closed now, or None. Fail closed on anything unreadable."""
    if facts is None:
        return "row_not_found"
    if facts.deleted:
        return "row_deleted"
    if facts.status != expected:
        return f"status_changed:{facts.status}"
    if facts.user_id != row.user_id:
        return "user_mismatch"
    if row.rule.startswith("reject_"):
        score = facts.rules.get(row.rule)
        if score is None or score < 1:
            return f"rule_not_firing:{row.rule}"
    pop = facts.popularity
    if facts.metadata_source == "client" or pop is None or not 1 <= pop < BIG_POPULARITY:
        return f"big_or_unknown_popularity:{pop}"
    if not gate.allowed:
        return f"account_gate_{gate.decision}"
    watch = gate.payload.get("watch") if isinstance(gate.payload, dict) else None
    if watch or any("watchlist" in r.lower() or "deny" in r.lower() for r in gate.reasons):
        return "watchlisted_account"
    return None


# ── server facts (read-only) ────────────────────────────────────────────────
TrinoRunner = Callable[[str], str]


def _trino(sql: str) -> str:
    p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=600, check=False)
    if p.returncode != 0:
        raise RuntimeError(f"trino failed rc={p.returncode}: {p.stderr.strip()[-300:]}")
    return p.stdout


def fetch_facts(ids: Iterable[str], run: TrinoRunner | None = None) -> dict[str, Facts]:
    """Fresh facts for exactly these ids from postgresql_core. Raises on a failed read (caller writes nothing)."""
    ids = [i for i in ids if UUID_RE.match(i)]
    if not ids:
        return {}
    quoted = ",".join(f"'{i.lower()}'" for i in ids)
    sql = f"""
select cast(cr.id as varchar), cr.status, cast(cr.userid as varchar), cast(cr.spotifypopularity as varchar),
  cast(cr.profileid as varchar),
  cast(cr.deletedat is not null as varchar),
  coalesce(json_format(json_extract(cr.verificationdata, '$.rule_risk_percent')), '{{}}'),
  coalesce(json_extract_scalar(cr.metadata, '$.source'), ''),
  cast(cr.workspaceid in (select s.teamid from postgresql_core.public.subscriptions s
                          where s.status in ('active','trialing')) as varchar)
from postgresql_core.public.credit_requests cr
where lower(cast(cr.id as varchar)) in ({quoted})"""
    out = (run or _trino)(sql)
    facts: dict[str, Facts] = {}
    for rec in csv.reader(io.StringIO("\n".join(l for l in out.splitlines() if l.startswith('"')))):
        if len(rec) != 9:
            raise RuntimeError(f"trino row has {len(rec)} columns, expected 9")
        rid, status, uid, pop, profile_id, deleted, rules_json, source, paid = rec
        try:
            rules_raw = json.loads(rules_json) if rules_json else {}
        except ValueError:
            rules_raw = None
        rules = {}
        for k, raw_v in ((rules_raw or {}).items() if isinstance(rules_raw, dict) else []):
            num = _num(raw_v)
            if num is not None:
                rules[str(k)] = num
        facts[rid.lower()] = Facts(
            status=status or None,
            user_id=int(uid) if uid.isdigit() else None,
            popularity=int(float(pop)) if _num(pop) is not None else None,
            deleted=deleted == "true",
            rules=rules,
            metadata_source=source or None,
            paid=paid == "true",
            profile_id=profile_id or None,
        )
    return facts


DSP_STORE = os.environ.get("CREDIT_DSP_VERIFY_STORE", "/var/lib/hydra-credit-verify/dsp-verify.sqlite")


def dsp_anchors(ids: Iterable[str], path: str | None = None) -> dict[str, str]:
    """{request id: 'anchor' | 'no_anchor' | 'unknown'} from the V9 DSP verifier's latest verdict per request
    (read-only). 'anchor' = its latest verdict is APPROVE or has a single/both DSP anchor; 'unknown' = no verdict
    or the store cannot be read. Never raises."""
    import sqlite3
    ids = [i.lower() for i in ids]
    out = {i: "unknown" for i in ids}
    store = path or DSP_STORE
    if not ids or not os.path.exists(store):
        return out
    try:
        con = sqlite3.connect(f"file:{store}?mode=ro", uri=True, timeout=10)
        try:
            q = ("select lower(request_id), verdict, anchor from dsp_verdicts d where lower(request_id) in (%s) "
                 "and id = (select max(id) from dsp_verdicts e where lower(e.request_id) = lower(d.request_id))"
                 % ",".join("?" * len(ids)))
            for rid, verdict, anchor in con.execute(q, ids):
                out[rid] = "anchor" if (verdict == "APPROVE" or anchor in ("both", "single")) else "no_anchor"
        finally:
            con.close()
    except Exception:  # noqa: BLE001 - unreadable = unknown for every row
        return {i: "unknown" for i in ids}
    return out


# ── audit + cap ─────────────────────────────────────────────────────────────
def writes_today(path: str = AUDIT_PATH, now: datetime | None = None) -> int:
    """Rows this automation RESERVED today (UTC), from its own audit file. A reservation is written BEFORE its PUT
    (QA #1475), so a write whose final audit line was lost still counts: the cap can only over-count."""
    day = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%d")
    seen: set[str] = set()
    try:
        with open(path, encoding="utf-8") as fh:
            for n, line in enumerate(fh):
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("outcome") in ("reserved", "written") and str(rec.get("ts", "")).startswith(day):
                    rid = rec.get("request_id")
                    # a reservation and its final line are ONE write; a line without ids counts on its own
                    seen.add(f"{rec.get('run_id', '')}|{rid}" if rid else f"line{n}")
    except FileNotFoundError:
        return 0
    return len(seen)


def audit(rec: dict[str, Any], path: str = AUDIT_PATH) -> None:
    """Append one audit line; raises if it cannot (the caller then stops)."""
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, sort_keys=True, separators=(",", ":")) + "\n")


def registry_approved(path: str = REGISTRY) -> bool:
    try:
        entry = json.loads(Path(path).read_text())["automations"][AUTOMATION_ID]
    except (OSError, ValueError, KeyError, TypeError):
        return False
    return bool(entry.get("approved") is True and str(entry.get("approved_by") or "").strip()
                and str(entry.get("approval_ref") or "").strip())


# ── the write ───────────────────────────────────────────────────────────────
Writer = Callable[[list[str], str, str, str, str], dict[str, Any]]
Readback = Callable[[str, list[str]], set[str]]


def admin_writer(script: str | None = None, timeout_s: int = 300) -> Writer:
    """PUT conditional-status as fable-decider. The wrapper's standing authorization checks the same registry
    entry, the kill file, the ruling id and the exact batch shape before anything leaves the host."""
    from . import admin as admin_api
    script = script or os.environ.get("CREDIT_REVIEW_ADMIN_SCRIPT", admin_api.DEFAULT_ADMIN_SCRIPT)

    def write(ids: list[str], expected: str, ruling_id: str, run_id: str, tray_path: str) -> dict[str, Any]:
        body = json.dumps({"requestIds": ids, "status": CLOSE_STATUS, "expectedStatus": expected},
                          separators=(",", ":"), sort_keys=True)
        env = {**os.environ, "FABLE_DECIDER": "1", "FABLE_RULING_ID": ruling_id,
               "FABLE_DECIDER_RUN_ID": run_id, "FABLE_DECIDER_TRAY": os.path.abspath(tray_path),
               "CREDIT_TRUST_DECIDE": "0", "CREDIT_TRUST_SCORE_APPROVE": "0", "UVN_POPULARITY_CRON": "0",
               "MUSO_ADMIN_IDENTITY": ADMIN_IDENTITY}
        proc = subprocess.run(["bash", script, "--requester", REQUESTER, "call", "PUT", CONDITIONAL_PATH, body],
                              capture_output=True, text=True, timeout=timeout_s, check=False, env=env)
        if proc.returncode != 0:
            raise RuntimeError(f"PUT refused/failed rc={proc.returncode}: {proc.stderr.strip()[:400]}")
        resp = json.loads(proc.stdout)
        code = resp.get("http_status")
        if not isinstance(code, int) or not 200 <= code < 300:
            raise RuntimeError(f"PUT HTTP {code}: {json.dumps(resp.get('body'))[:300]}")
        return resp.get("body") or {}
    return write


@dataclass
class Result:
    tray: str
    mode: str
    rows: int = 0
    written: int = 0
    written_paid: int = 0
    refused: dict[str, int] = field(default_factory=dict)
    not_moved: int = 0
    stopped: str = ""

    def as_dict(self) -> dict[str, Any]:
        return {"tray": self.tray, "mode": self.mode, "rows": self.rows, "written": self.written,
                "written_paid": self.written_paid, "written_free": self.written - self.written_paid,
                "refused": dict(sorted(self.refused.items())), "not_moved": self.not_moved,
                "stopped": self.stopped}


@contextlib.contextmanager
def _locked(path: str, wait_s: float = 600):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a+", encoding="utf-8") as fh:
        deadline = time.monotonic() + wait_s
        while True:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise TimeoutError(f"credit write lock {path} busy")
                time.sleep(1)
        try:
            yield
        finally:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


def _base(tray: Tray, run_id: str, r: TrayRow, f: Facts | None, now: datetime, mode: str) -> dict[str, Any]:
    return {"ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "run_id": run_id, "automation": AUTOMATION_ID,
            "tray": tray.path, "tray_sha256": tray.sha256, "request_id": r.request_id, "user_id": r.user_id,
            "paid": bool(f.paid) if f else r.paid, "rule": r.rule, "ruling_id": r.ruling_id,
            "before": f.status if f else None, "mode": mode, **dict(r.audit_extra)}


def _anchor_refusal(state: str) -> str | None:
    if state == "anchor":
        return "dsp_anchor_present"     # Fable junk-b1: belongs to the approve path, never rejected here
    if state != "no_anchor":
        return "dsp_anchor_unknown"     # UNKNOWN never removes
    return None


def _bump(res: "Result", why: str) -> None:
    key = why.split(":")[0]
    res.refused[key] = res.refused.get(key, 0) + 1


def run(tray: Tray, *, apply: bool, limit: int | None = None,
        facts_fn: Callable[[list[str]], dict[str, Facts]] = fetch_facts,
        gate_fn: Callable[[Any], account_gate.GateResult] | None = None,
        writer: Writer | None = None, readback: Readback | None = None,
        audit_path: str = AUDIT_PATH, registry_path: str = REGISTRY, kill_file: str = KILL_FILE,
        daily_cap: int | None = None, now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
        between_batches: Callable[[list[tuple[str, int, str | None]], datetime], str | None] | None = None,
        lock_path: str = WRITE_LOCK,
        anchor_fn: Callable[[list[str]], dict[str, str]] = dsp_anchors,
        ) -> Result:
    """Execute (apply) or dry-run one tray. In apply mode EVERY batch re-reads its rows' facts and the account gate
    immediately before its PUT (no fact or gate answer outlives its batch, QA #1475), under one lock from the cap
    check to the final audit, with a durable reservation line per row written BEFORE the PUT. Stops at the first
    surprise: a refused/failed write, a row the server reports not moved, a read-back failure, an unwritable audit,
    the kill file, the cap or the fan-out check."""
    res = Result(tray.path, "apply" if apply else "dry-run", rows=len(tray.rows))
    daily_cap = tray.daily_cap if daily_cap is None else daily_cap
    run_id = uuid.uuid4().hex[:12]
    if limit is not None and (not isinstance(limit, int) or isinstance(limit, bool) or limit < 1):
        raise ValueError(f"limit must be a positive integer, got {limit!r}")
    rows = list(tray.rows)[:limit] if limit is not None else list(tray.rows)
    if not apply:
        gate = account_gate.Cached(gate_fn)
        facts = facts_fn([r.request_id for r in rows])
        n = 0
        anchors = anchor_fn([r.request_id for r in rows]) if tray.refuse_if_dsp_anchor else {}
        for r in rows:
            why = refusal(r, facts.get(r.request_id.lower()), gate(r.user_id), tray.expected_status)
            if not why and tray.refuse_if_dsp_anchor:
                why = _anchor_refusal(anchors.get(r.request_id.lower(), "unknown"))
            if why:
                _bump(res, why)
            else:
                n += 1
        res.refused["would_write"] = n
        return res
    writer = writer or admin_writer()
    if readback is None:
        from .decide import status_readback
        readback = status_readback()
    # Batches follow the TRAY order (paid first, or as listed): a batch is a run of consecutive rows sharing one
    # ruling id (the wrapper stamps one ruling per call), so a ruling change never pushes a paid row behind free
    # rows of another ruling at the cap (QA #1475).
    queue = list(rows)
    while queue:
        ruling = queue[0].ruling_id
        moved_rows: list[tuple[str, int, str | None]] = []
        batch_start = now()
        try:
            with _locked(lock_path):
                if os.path.exists(kill_file):
                    res.stopped = f"kill file {kill_file} present"
                    return res
                if not registry_approved(registry_path):
                    res.stopped = f"registry entry {AUTOMATION_ID} not approved"
                    return res
                room = min(BATCH_MAX, daily_cap - writes_today(audit_path, now()))
                if room <= 0:
                    res.stopped = f"daily cap {daily_cap} reached"
                    return res
                # FRESH facts + gate for this batch only, right before the PUT
                window = []
                for r in queue:
                    if r.ruling_id != ruling or len(window) >= room * 2:
                        break
                    window.append(r)
                facts = facts_fn([r.request_id for r in window])
                gate = account_gate.Cached(gate_fn)
                anchors = anchor_fn([r.request_id for r in window]) if tray.refuse_if_dsp_anchor else {}
                chunk: list[TrayRow] = []
                consumed = 0
                for r in window:
                    if len(chunk) >= room:
                        break
                    consumed += 1
                    f = facts.get(r.request_id.lower())
                    why = refusal(r, f, gate(r.user_id), tray.expected_status)
                    if not why and tray.refuse_if_dsp_anchor:
                        why = _anchor_refusal(anchors.get(r.request_id.lower(), "unknown"))
                    if why:
                        _bump(res, why)
                        audit({**_base(tray, run_id, r, f, now(), "apply"), "outcome": "refused",
                               "reason": why, "after": f.status if f else None}, audit_path)
                        continue
                    chunk.append(r)
                del queue[:consumed]
                if not chunk:
                    continue
                ids = [r.request_id for r in chunk]
                # durable reservation BEFORE the PUT: if this cannot be written, nothing is sent
                for r in chunk:
                    audit({**_base(tray, run_id, r, facts.get(r.request_id.lower()), now(), "apply"),
                           "outcome": "reserved"}, audit_path)
                try:
                    body = writer(ids, tray.expected_status, ruling, run_id, tray.path)
                except Exception as exc:  # noqa: BLE001 - any refusal/failure stops the run
                    res.stopped = f"write failed: {str(exc)[:300]}"
                    body = {}
                data = body.get("data") if isinstance(body.get("data"), dict) else body
                reported = ({str(x).lower() for x in (data.get("updatedIds") or [])}
                            if isinstance(data, dict) else set())
                try:
                    landed = {x.lower() for x in readback(CLOSE_STATUS, ids)}
                except Exception as exc:  # noqa: BLE001
                    res.stopped = (res.stopped + "; " if res.stopped else "") + f"read-back failed: {str(exc)[:200]}"
                    landed = set()
                for r in chunk:
                    moved = r.request_id.lower() in landed
                    f = facts.get(r.request_id.lower())
                    audit({**_base(tray, run_id, r, f, now(), "apply"), "before": tray.expected_status,
                           "server_reported_updated": r.request_id.lower() in reported,
                           "after": CLOSE_STATUS if moved else "unchanged_or_unknown",
                           "outcome": "written" if moved else "not_moved"}, audit_path)
                    if moved:
                        res.written += 1
                        res.written_paid += 1 if (f.paid if f else r.paid) else 0
                        moved_rows.append((r.request_id, r.user_id, f.profile_id if f else None))
                    else:
                        res.not_moved += 1
        except (OSError, TimeoutError) as exc:
            res.stopped = (res.stopped + "; " if res.stopped else "") + f"audit/lock failure: {str(exc)[:200]}"
            return res
        if res.stopped:
            return res
        if res.not_moved:
            res.stopped = f"{res.not_moved} row(s) not moved after a 2xx; stopping on the first surprise"
            return res
        if between_batches is not None and moved_rows:
            try:
                surprise = between_batches(moved_rows, batch_start)
            except Exception as exc:  # noqa: BLE001 - an unreadable fan-out is a surprise
                surprise = f"fan-out check failed: {str(exc)[:200]}"
            if surprise:
                res.stopped = f"fan-out: {surprise}"
                return res
    return res


# ── the wrapper's boundary check (QA #1475 Critical) ────────────────────────
RESERVATION_MAX_AGE_S = 600


def verify_batch(tray_path: str, ruling_id: str, run_id: str, ids: list[str], expected: str, *,
                 facts_fn: Callable[[list[str]], dict[str, Facts]] = fetch_facts,
                 gate_fn: Callable[[Any], account_gate.GateResult] | None = None,
                 anchor_fn: Callable[[list[str]], dict[str, str]] = dsp_anchors,
                 audit_path: str = AUDIT_PATH, now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
                 ) -> str | None:
    """Re-check ONE batch at the wrapper boundary, independently of the run that asked for it. None = allowed,
    else why not. The wrapper calls this for every fable-decider close, so a caller who sets the env flags and
    skips the executor still meets: a loadable tray naming every id under this ruling and status, a fresh
    'reserved' audit line per id from this run, the tray's daily cap counted over today's reservations, and every
    row guard on fresh facts + the account gate (+ the DSP-anchor guard when the tray asks for it)."""
    try:
        tray = load_tray(tray_path)
    except (TrayError, OSError) as exc:
        return f"tray unusable: {exc}"
    if expected != tray.expected_status:
        return f"expectedStatus {expected} is not the tray's {tray.expected_status}"
    rows = {r.request_id.lower(): r for r in tray.rows}
    want = [i.lower() for i in ids]
    if not want or len(set(want)) != len(want):
        return "empty or duplicate id list"
    for i in want:
        r = rows.get(i)
        if r is None:
            return f"{i} is not in the tray"
        if r.ruling_id != ruling_id:
            return f"{i} is not under ruling {ruling_id} in the tray"
    cutoff = now().timestamp() - RESERVATION_MAX_AGE_S
    reserved: set[str] = set()
    try:
        with open(audit_path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if rec.get("outcome") != "reserved" or rec.get("run_id") != run_id:
                    continue
                try:
                    ts = datetime.strptime(str(rec.get("ts")), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                except ValueError:
                    continue
                if ts.timestamp() >= cutoff and rec.get("tray_sha256") == tray.sha256:
                    reserved.add(str(rec.get("request_id", "")).lower())
    except OSError as exc:
        return f"audit unreadable: {exc}"
    missing = [i for i in want if i not in reserved]
    if missing:
        return f"{len(missing)} id(s) have no fresh reservation from run {run_id} on this tray"
    if writes_today(audit_path, now()) > tray.daily_cap:
        return f"daily cap {tray.daily_cap} exceeded by today's reservations"
    facts = facts_fn(want)
    gate = account_gate.Cached(gate_fn)
    anchors = anchor_fn(want) if tray.refuse_if_dsp_anchor else {}
    for i in want:
        r = rows[i]
        why = refusal(r, facts.get(i), gate(r.user_id), tray.expected_status)
        if not why and tray.refuse_if_dsp_anchor:
            why = _anchor_refusal(anchors.get(i, "unknown"))
        if why:
            return f"{i}: {why}"
    return None
