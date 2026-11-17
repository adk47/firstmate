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
  - NEITHER kill file is present and the registry entry is approved AND apply-enabled (re-read before every write);
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
#: [key=fable-trays] (Fable switch-on-plan row 4, firstmate 751): the file is named for the per-item TRAY input
#: that is off, not for the executor. BOTH names are honoured, new first, because the executor is the writer the
#: admin boundary refuses: if it checked only one name, a host rename would leave it reserving a batch and then
#: failing every PUT at the boundary (QA #1767) instead of stopping cleanly before it reserves anything. A rename
#: that lands on the host before this code, or a rollback, therefore never silently re-enables the executor.
KILL_FILES = (
    os.environ.get("FABLE_DECIDER_KILL_FILE", "/etc/hydra/fable-trays.disabled"),
    os.environ.get("FABLE_DECIDER_KILL_FILE_LEGACY", "/etc/hydra/fable-decider.disabled"),
)
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
# ── approvals (executor PR 2; Fable [key=l12-approvals-core] = A; core #11010/#11011 FABLE_RULED) ──
#: An approve tray approves ONLY what core's FABLE_RULED scope admits on a server-held anchor record; the executor
#: adds its own guards (account gate, watchlist, known-small) and a separate, lower cap.
APPROVE_STATUS = "approved"
APPROVABLE_FROM = ("unverified", "user_verification_needed", "rejected")   # rejected: the 880d34b3 correction
APPROVE_CAP = 50                    # Fable r3 (4): approvals <= 50/day
APPROVE_IDENTITY = "fable"          # agent-fable@muso.ai: core binds fable-decider approvals to Fable's OWN account
# The approve FILTER (Fable ruling via the captain, 2026-11-15): "a rate cap only slows how fast wrong approvals are
# written", so an approve needs more than the switch and a cap. The registry entry carries `apply_filter` beside
# `apply_enabled`, and this code holds the floor: a missing, malformed or weaker block refuses every approve.
#   outcome                        the one outcome admitted: a credit-anchored-approve row (rule ANCHORED_RULE_ID,
#                                  citing a dsp_verdicts row), which is what credit-anchored-approve.py builds
#   exclude_bands                  must hold "none": no band_hint on the request = no band = refused
#   exclude_conflict_rule_failures another user's request on the same track with an overlapping credit, approved
#                                  or awaiting verification
#   exclude_self_duplicate_groups  the same user's own other open request for the same track and credits
#   per_run_cap                    approves one run may write (1..APPROVE_CAP)
#   batch_id_required              every approve write is tagged; the audit carries the id on every line
APPLY_FILTER_OUTCOME = "credit-anchored-approve"
ANCHORED_RULE_ID = "C4:anchored/v1"            # credit_review/anchored_feed.RULE_ID (pinned equal by a test)
APPLY_FILTER_KEYS = frozenset({"outcome", "exclude_bands", "exclude_conflict_rule_failures",
                               "exclude_self_duplicate_groups", "per_run_cap", "batch_id_required"})
CONFLICT_STATUSES = ("approved", "user_verification_needed")
SELF_DUPLICATE_STATUSES = ("unverified", "user_verification_needed")
BATCH_ID_RE = re.compile(r"[a-z0-9][a-z0-9._-]{5,63}")
TRACK_ID_RE = re.compile(r"^[A-Za-z0-9]{1,64}$")
#: The send template each action's write fires (one per (user, profile) group per call).
TEMPLATE = {"reject": "credits_rejected", "approve": "credits_accepted"}
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
RULING_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:|-]{2,120}$")
BIG_POPULARITY = 60
#: A close cites either a validator rule that fired (reject_*, re-checked live) or a Fable evidence rule from
#: rules.md (e.g. R-C2(4): a one-person role credited to somebody else on a complete same-run DSP snapshot),
#: which must come with its evidence text in the tray row.
#: Tray row fields carried verbatim into the audit (doc-verify's jan-forged-bN.json contract).
AUDIT_PASSTHROUGH = ("reason_code", "proof_id", "intake_id", "fraud_pair", "signal_ids", "outcome_ids", "subject",
                     "contributors")   # contributors: every forged document behind one request (QA #1480)
FABLE_RULE_RE = re.compile(r"^(R-[A-Z0-9][A-Za-z0-9().-]{0,40}|C[0-9]{1,2}[:/][A-Za-z0-9_.:/-]{1,60})$")
#: A row's coded-rule outcome: a row id in one of the two coded deciders' append-only stores -
#:   decisions:<id>    the credit-review decider ledger's `decisions` table (C3/C5 closes, approvals)
#:   dv_outcomes:<id>  doc-verify's `dv_outcomes` (C8 fraud deny: the executing document's `forged` outcome row)
#   dsp_verdicts:<id> the V9 DSP verifier's own APPROVE verdict (ANCHORED approvals; same-run Spotify+Tidal)
CODED_OUTCOME_RE = re.compile(r"^(decisions|dv_outcomes|dsp_verdicts):[0-9]{1,12}$")
LEDGER_PATH = os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")
DOC_VERIFY_STORE = os.environ.get("CREDIT_DOC_VERIFY_STORE", "/var/lib/hydra-credit-verify/doc-verify.sqlite")
#: What the decider's decision must say for each tray action.
DECISION_FOR = {"reject": "close", "approve": "approve"}


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
    #: Captain 2026-10-29 16:0xZ: per-item decisions come from CODE (the node-8 decider), never from a Fable seat.
    #: Every row cites the coded-rule outcome that decided it: `decisions:<id>` = a row of the decider ledger's
    #: append-only `decisions` table (/var/lib/hydra/credit-review/ledger.sqlite3). Verified at run time and at the
    #: wrapper boundary: it exists, names this request, is mode 'apply', and its decision matches the tray action.
    coded_outcome: str = ""


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
    #: A coded producer whose evidence can change between decision and execution names its re-check here
    #: ('no_proof_after_ask': proof + replies re-read per batch, QA #1536). "" = none.
    recheck_evidence: str = ""


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
    #: core `claiming` has a LIVE row (not deleted; any status, any profile type) for this submitter on this
    #: request's profile (profileid or extraprofileids). None = unread = refused. Fable [key=batch0-wrong-action]
    #: 2026-10-29 03:51Z (3): every close tray excludes such rows, and the executor refuses them as a code guard
    #: (batch0 incident 880d34b3: a processed org claim = the label-credits APPROVE population).
    owns_profile: bool | None = None


@dataclass(frozen=True)
class FilterFacts:
    """What the approve filter needs to know about one request. None = could not be measured = refused."""
    band: str | None                  # verificationdata.band_hint, lower-cased; "none" when the request has none
    conflict: bool | None             # the conflict rule fails for this request
    self_duplicate: bool | None       # the request sits in a self-duplicate group


def load_tray(path: str, now: datetime | None = None) -> Tray:
    """Read and validate a tray file. Any row without a Fable ruling id refuses the WHOLE tray. A tray carrying
    `expires_at` (coded producers re-check their evidence at publication, e.g. C5 no_proof_after_ask) is refused once
    that time has passed or when it is unreadable: its evidence is stale."""
    raw = Path(path).read_bytes()
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        raise TrayError(f"tray is not JSON: {exc}") from exc
    if not isinstance(doc, dict):
        raise TrayError("tray must be a JSON object")
    if "expires_at" in doc:
        try:
            exp = datetime.fromisoformat(str(doc["expires_at"]).replace("Z", "+00:00"))
            if exp.tzinfo is None:
                raise ValueError("no timezone")
        except ValueError as exc:
            raise TrayError(f"tray expires_at unreadable: {exc}") from exc
        if (now or datetime.now(timezone.utc)) >= exp:
            raise TrayError(f"tray expired at {doc['expires_at']}: its producer's evidence is stale; re-publish it")
    action = doc.get("action")
    if action == "role_correction":
        # C9 (rules-to-code-1029): no in-place role write exists; create-then-remove is a REMOVAL -> never automated.
        raise TrayError("refused:removal_class - a role correction on approved rows is a removal (captain card), "
                        "never an executor action")
    if action not in ("reject", "approve"):
        raise TrayError(f"action {action!r} is not executable here ('reject' or 'approve')")
    expected = doc.get("expected_status")
    allowed_from = CLOSABLE_FROM if action == "reject" else APPROVABLE_FROM
    if expected not in allowed_from:
        raise TrayError(f"expected_status must be one of {allowed_from} for {action}, got {expected!r}")
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
        if action == "approve" and not FABLE_RULE_RE.match(rule):
            raise TrayError(f"row {i} ({rid}): an approval cites a Fable R- rule with evidence, never a reject_* rule")
        if not rule.startswith("reject_") and len(evidence.strip()) < 20:
            raise TrayError(f"row {i} ({rid}): Fable rule {rule} needs its evidence text in the row")
        extra = tuple((k, r[k]) for k in AUDIT_PASSTHROUGH if k in r)
        coded = r.get("coded_outcome")
        if not isinstance(coded, str) or not CODED_OUTCOME_RE.match(coded):
            raise TrayError(f"row {i} ({rid}): no coded-rule outcome id (decisions:<id> | dv_outcomes:<id>); per-item decisions come "
                            "from the decider, never a hand list - the whole tray is refused")
        rows.append(TrayRow(rid, uid, ruling, rule, bool(r.get("paid")), evidence.strip(), extra, coded))
    if doc.get("order") != "as_listed":
        rows.sort(key=lambda t: (not t.paid, t.user_id, t.request_id))   # paid first (default)
    base_cap = DAILY_CAP if action == "reject" else APPROVE_CAP
    ceiling = CAP_CEILING if action == "reject" else APPROVE_CAP
    cap, cap_ruling = base_cap, doc.get("cap_ruling_id")
    if "daily_cap" in doc:
        cap = doc.get("daily_cap")
        if not isinstance(cap, int) or isinstance(cap, bool) or not 1 <= cap <= ceiling:
            raise TrayError(f"daily_cap {cap!r} must be an integer 1..{ceiling} for {action}")
        if cap > base_cap and not (isinstance(cap_ruling, str) and RULING_RE.match(cap_ruling)):
            raise TrayError(f"daily_cap {cap} above {base_cap} needs a cap_ruling_id (a Fable ruling)")
    anchor_flag = doc.get("refuse_if_dsp_anchor", False)
    if not isinstance(anchor_flag, bool):
        raise TrayError("refuse_if_dsp_anchor must be true or false")
    if action == "approve" and anchor_flag:
        raise TrayError("refuse_if_dsp_anchor is a close guard; an approve tray cannot set it")
    recheck = doc.get("recheck_evidence", "")
    if recheck not in EVIDENCE_RECHECKS:
        raise TrayError(f"recheck_evidence {recheck!r} must be one of {EVIDENCE_RECHECKS}")
    if action == "approve" and recheck:
        raise TrayError("recheck_evidence is a close guard; an approve tray cannot set it")
    return Tray(str(path), hashlib.sha256(raw).hexdigest(), action, expected, tuple(rows), cap,
                cap_ruling if isinstance(cap_ruling, str) else None, anchor_flag, recheck)


EVIDENCE_RECHECKS = ("", "no_proof_after_ask", "validator_reject")


def coded_evidence(rows: Iterable["TrayRow"], kind: str = "no_proof_after_ask") -> dict[str, str]:
    """{request id: '' (the close still stands) | why not}, re-read at execution for a coded producer whose rule can
    change between decision and write. no_proof_after_ask: proof in our stores + Intercom documents + any reply since
    the ask. validator_reject: the cited reject rule still at 100 and current, no review_* hold, no R8 account hold
    (QA #1559; the executor's own rails cover gate / watchlist / claim / pop / V9). Never raises; unreadable = refused."""
    rows = list(rows)
    if kind == "validator_reject":
        try:
            from credit_review import validator_reject_close
            return validator_reject_close.recheck_rows(rows)
        except Exception as exc:  # noqa: BLE001 - unreadable = refused
            return {r.request_id.lower(): f"unknown:{str(exc)[:80]}" for r in rows}
    try:
        from credit_review import no_proof_close
        ids = {r.request_id.lower(): int(r.coded_outcome.split(":", 1)[1]) for r in rows
               if r.coded_outcome.startswith("decisions:")}
        out = no_proof_close.recheck_decisions(ids)
    except Exception as exc:  # noqa: BLE001 - unreadable = refused
        return {r.request_id.lower(): f"unknown:{str(exc)[:80]}" for r in rows}
    return {r.request_id.lower(): out.get(r.request_id.lower(), "unknown:no evidence row") for r in rows}


def _evidence_refusal(why: str | None) -> str | None:
    return f"evidence_changed:{why}"[:160] if why else None


def _read_store(path: str, sql: str, nums: list[int]) -> list[tuple]:
    import sqlite3
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
        try:
            return list(con.execute(sql % ",".join("?" * len(nums)), nums))
        finally:
            con.close()
    except Exception:  # noqa: BLE001 - unreadable = no outcome = refused
        return []


def ledger_outcomes(ids: Iterable[str], path: str | None = None,
                    dv_path: str | None = None) -> dict[str, dict[str, Any]]:
    """{coded outcome id: {request_id, decision, mode}} for the cited rows of either coded decider (read-only).
    decisions:<id> -> the ledger row as written; dv_outcomes:<id> -> decision 'close' only for outcome 'forged'
    (anything else = 'none'), mode 'apply' (doc-verify writes final outcomes only). Missing / unreadable = absent
    (the row is then refused). Never raises."""
    ids = list(ids)
    out: dict[str, dict[str, Any]] = {}
    dec = sorted({int(i.split(":", 1)[1]) for i in ids if CODED_OUTCOME_RE.match(i) and i.startswith("decisions:")})
    if dec:
        for i, rid, d, m in _read_store(path or LEDGER_PATH,
                                        "select id, lower(request_id), decision, mode from decisions where id in (%s)",
                                        dec):
            out[f"decisions:{i}"] = {"request_id": rid, "decision": d, "mode": m}
    vv = sorted({int(i.split(":", 1)[1]) for i in ids if CODED_OUTCOME_RE.match(i) and i.startswith("dsp_verdicts:")})
    if vv:
        out.update(dsp_verdict_outcomes(vv))
    dv = sorted({int(i.split(":", 1)[1]) for i in ids if CODED_OUTCOME_RE.match(i) and i.startswith("dv_outcomes:")})
    if dv:
        for i, rid, outcome in _read_store(dv_path or DOC_VERIFY_STORE,
                                           "select id, lower(request_id), outcome from dv_outcomes where id in (%s)", dv):
            out[f"dv_outcomes:{i}"] = {"request_id": rid, "decision": "close" if outcome == "forged" else "none",
                                       "mode": "apply"}
    return out


def dsp_verdict_outcomes(nums: list[int], path: str | None = None, version: str | None = None) -> dict[str, dict]:
    """{'dsp_verdicts:<id>': {request_id, decision, mode}} - decision 'approve' ONLY for a verdict that is APPROVE,
    of the current verifier version, from a `verify` run on this store's OWN capture for that request (the anchor
    builder's provenance, dspverify Store.latest_captured_for) AND still the request's latest such verdict (a later
    WAIT/DECLINE withdraws it). Anything else = 'none'. Unreadable = absent (refused). Never raises."""
    import sqlite3
    try:
        if version is None:
            from credit_verify.dspverify import VERSION as version
        con = sqlite3.connect(f"file:{path or DSP_STORE}?mode=ro", uri=True, timeout=10)
    except Exception:  # noqa: BLE001
        return {}
    out: dict[str, dict] = {}
    try:
        for vid in nums:
            row = con.execute("SELECT v.request_id, v.verdict, v.version, v.capture_request_id, v.packet_json, r.kind "
                              "FROM dsp_verdicts v JOIN dsp_runs r ON r.run_id = v.run_id WHERE v.id = ?",
                              (vid,)).fetchone()
            if row is None:
                continue
            rid, verdict, ver, cap, packet_json, kind = row
            rid = str(rid).lower()
            latest = con.execute("SELECT max(v.id) FROM dsp_verdicts v JOIN dsp_runs r ON r.run_id = v.run_id "
                                 "WHERE lower(v.request_id) = ? AND v.version = ? AND r.kind = 'verify'",
                                 (rid, version)).fetchone()[0]
            own = False
            if cap:
                for (ids_json,) in con.execute("SELECT request_ids_json FROM dsp_captures WHERE capture_request_id = ?",
                                               (cap,)):
                    try:
                        own = own or rid in {str(x).lower() for x in json.loads(ids_json or "[]")}
                    except ValueError:
                        pass
                try:
                    own = own and (json.loads(packet_json or "{}").get("capture") or {}).get("request_id") == cap
                except ValueError:
                    own = False
            ok = verdict == "APPROVE" and ver == version and kind == "verify" and own and latest == vid
            out[f"dsp_verdicts:{vid}"] = {"request_id": rid, "decision": "approve" if ok else "none", "mode": "apply"}
    except Exception:  # noqa: BLE001 - unreadable = absent = refused
        return {}
    finally:
        con.close()
    return out


def coded_outcome_refusal(tray: "Tray", row: TrayRow, outcomes: dict[str, dict[str, Any]]) -> str | None:
    o = outcomes.get(row.coded_outcome)
    if o is None:
        return "coded_outcome_missing"
    if o.get("request_id") != row.request_id.lower():
        return "coded_outcome_other_request"
    if o.get("mode") != "apply":
        return f"coded_outcome_not_apply:{o.get('mode')}"
    if o.get("decision") != DECISION_FOR[tray.action]:
        return f"coded_outcome_decision:{o.get('decision')}"
    return None


def target_status(tray: "Tray") -> str:
    return APPROVE_STATUS if tray.action == "approve" else CLOSE_STATUS


def batch_refusal(batch_id: Any) -> str | None:
    if not isinstance(batch_id, str) or not BATCH_ID_RE.fullmatch(batch_id):
        return f"an approve write needs a batch id matching {BATCH_ID_RE.pattern} (got {batch_id!r})"
    return None


def credit_anchored(row: Any) -> bool:
    """Is this row the anchored feed's approve (rule C4, citing one DSP verdict)? Any other approval, a
    document-verified one included, is a different outcome and the filter keeps it out."""
    return (getattr(row, "rule", None) == ANCHORED_RULE_ID
            and str(getattr(row, "coded_outcome", "") or "").startswith("dsp_verdicts:"))


def filter_refusal(row: Any, apply_filter: dict[str, Any], ff: FilterFacts | None) -> str | None:
    """Why the approve filter keeps this row out, or None. Unmeasured is its own refusal, never a pass. `row`
    is anything carrying `rule` and `coded_outcome`: the tray executor's row and the decider's are read alike."""
    if not credit_anchored(row):
        return "outcome_not_credit_anchored_approve"
    if ff is None:
        return "apply_filter_unmeasured"
    if ff.band is None:
        return "band_unmeasured"
    if ff.band in apply_filter["exclude_bands"]:
        return f"band_excluded:{ff.band}"
    if ff.conflict is None:
        return "conflict_rule_unmeasured"
    if ff.conflict:
        return "conflict_rule_failure"
    if ff.self_duplicate is None:
        return "self_duplicate_unmeasured"
    if ff.self_duplicate:
        return "self_duplicate_group"
    return None


def approve_refusal(row: TrayRow, facts: Facts | None, gate: account_gate.GateResult, expected: str,
                    apply_enabled: bool = False, apply_filter: dict[str, Any] | None = None,
                    filter_facts: FilterFacts | None = None) -> str | None:
    """Why this row must NOT be approved now, or None (the executor's own guards; core's FABLE_RULED scope then
    re-checks the anchor set, the rules and the claim inside the approving UPDATE). Fail closed: the switch, then
    a valid filter block, then the row guards, then the filter itself."""
    if not apply_enabled:
        return "approve_not_enabled"
    if apply_filter is None:
        return "apply_filter_invalid"
    if facts is None:
        return "row_not_found"
    if facts.deleted:
        return "row_deleted"
    if facts.status != expected:
        return f"status_changed:{facts.status}"
    if facts.user_id != row.user_id:
        return "user_mismatch"
    pop = facts.popularity
    if facts.metadata_source == "client" or pop is None or not 1 <= pop < BIG_POPULARITY:
        return f"big_or_unknown_popularity:{pop}"
    if not gate.allowed:
        return f"account_gate_{gate.decision}"
    watch = gate.payload.get("watch") if isinstance(gate.payload, dict) else None
    if watch or any("watchlist" in r.lower() or "deny" in r.lower() for r in gate.reasons):
        return "watchlisted_account"
    return filter_refusal(row, apply_filter, filter_facts)


def refusal_for(tray: "Tray", registry_path: str = REGISTRY, ids: Iterable[str] = (),
                filter_fn: Callable[[list[str]], dict[str, "FilterFacts"]] | None = None,
                ) -> Callable[..., str | None]:
    """The row guard for this tray. For an approve tray it binds the switch, the filter block and ONE read of the
    filter facts for `ids`; that read is made only when the switch is on and the block is valid (otherwise every
    row is refused before it would be used). A failed read leaves every row unmeasured, which refuses it."""
    if tray.action != "approve":
        return refusal
    enabled = registry_apply_enabled(registry_path)
    apply_filter, _ = registry_apply_filter(registry_path)
    measured: dict[str, FilterFacts] = {}
    ids = list(ids)
    if enabled and apply_filter is not None and ids:
        try:
            measured = {k.lower(): v for k, v in (filter_fn or approve_filter_facts)(ids).items()}
        except Exception:  # noqa: BLE001 - an unreadable filter refuses every row (apply_filter_unmeasured)
            measured = {}
    return lambda row, facts, gate, expected: approve_refusal(
        row, facts, gate, expected, enabled, apply_filter, measured.get(row.request_id.lower()))


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
    if facts.owns_profile is not False:
        return "submitter_has_claim_on_profile" if facts.owns_profile else "profile_claim_unknown"
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
                          where s.status in ('active','trialing')) as varchar),
  cast(exists (select 1 from postgresql_core.public.claiming c
               where c.userid = cr.userid and c.deletedat is null
                 and (lower(c.profileid) = lower(cast(cr.profileid as varchar))
                      or strpos(lower(coalesce(c.extraprofileids, '')), lower(cast(cr.profileid as varchar))) > 0))
       as varchar)
from postgresql_core.public.credit_requests cr
where lower(cast(cr.id as varchar)) in ({quoted})"""
    out = (run or _trino)(sql)
    facts: dict[str, Facts] = {}
    for rec in csv.reader(io.StringIO("\n".join(l for l in out.splitlines() if l.startswith('"')))):
        if len(rec) != 10:
            raise RuntimeError(f"trino row has {len(rec)} columns, expected 10")
        rid, status, uid, pop, profile_id, deleted, rules_json, source, paid, owns = rec
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
            owns_profile={"true": True, "false": False}.get(owns),
        )
    return facts


def parse_credits(text: str) -> frozenset[str] | None:
    """core stores credit_requests.credits as a Postgres array literal read back as text: `{Producer}`,
    `{"Mixing Engineer",Producer}`. The roles, lower-cased, or None when the text is not that shape."""
    text = (text or "").strip()
    if len(text) < 2 or text[0] != "{" or text[-1] != "}":
        return None
    inner = text[1:-1]
    if not inner.strip():
        return frozenset()
    try:
        cells = next(csv.reader([inner], quotechar='"', escapechar="\\", doublequote=False))
    except (csv.Error, StopIteration):
        return None
    roles = frozenset(c.strip().lower() for c in cells)
    return None if "" in roles else roles


def _quoted_rows(out: str, width: int, what: str) -> list[list[str]]:
    rows = list(csv.reader(io.StringIO("\n".join(l for l in out.splitlines() if l.startswith('"')))))
    for rec in rows:
        if len(rec) != width:
            raise RuntimeError(f"trino {what} row has {len(rec)} columns, expected {width}")
    return rows


def approve_filter_facts(ids: Iterable[str], run: TrinoRunner | None = None) -> dict[str, FilterFacts]:
    """The approve filter's facts for exactly these ids, from postgresql_core (read-only, two reads). Raises on a
    failed read. Kept out of fetch_facts on purpose: the close paths never pay for the sibling read.

    conflict        another user's non-deleted request on the same Spotify track, approved or awaiting
                    verification, with at least one credit in common (the conflict rule as measured 2026-11-15:
                    5,509 of 80,139 pending; metadata.precedent_blocked is on none of them and is not the source)
    self_duplicate  the same user's own other open request for the same track and the same credits (grouping
                    pending rows that way gives the recorded 2,441 groups; `unverified` is included here too)
    A request with no usable track id, or unreadable credits on it or on a sibling, is unmeasured (None)."""
    ids = [i.lower() for i in ids if UUID_RE.match(i)]
    if not ids:
        return {}
    quoted = ",".join(f"'{i}'" for i in ids)
    out = (run or _trino)(f"""
select cast(cr.id as varchar), cast(cr.userid as varchar), coalesce(cr.spotifytrackid, ''),
  coalesce(cast(cr.credits as varchar), ''),
  coalesce(json_extract_scalar(cr.verificationdata, '$.band_hint'), '')
from postgresql_core.public.credit_requests cr
where lower(cast(cr.id as varchar)) in ({quoted})""")
    own: dict[str, tuple[int | None, str, frozenset[str] | None, str]] = {}
    for rid, uid, track, credits, band in _quoted_rows(out, 5, "filter"):
        own[rid.lower()] = (int(uid) if uid.isdigit() else None, track, parse_credits(credits),
                            band.strip().lower() or "none")
    tracks = sorted({t for _, t, _, _ in own.values() if TRACK_ID_RE.match(t)})
    siblings: dict[str, list[tuple[str, int | None, str, frozenset[str] | None]]] = {}
    if tracks:
        statuses = ",".join(f"'{x}'" for x in sorted(set(CONFLICT_STATUSES) | set(SELF_DUPLICATE_STATUSES)))
        in_tracks = ",".join(f"'{t}'" for t in tracks)
        out = (run or _trino)(f"""
select cast(cr.id as varchar), cast(cr.userid as varchar), cr.spotifytrackid, cr.status,
  coalesce(cast(cr.credits as varchar), '')
from postgresql_core.public.credit_requests cr
where cr.spotifytrackid in ({in_tracks})
  and cr.deletedat is null and cr.status in ({statuses})""")
        for rid, uid, track, status, credits in _quoted_rows(out, 5, "sibling"):
            siblings.setdefault(track, []).append(
                (rid.lower(), int(uid) if uid.isdigit() else None, status, parse_credits(credits)))
    facts: dict[str, FilterFacts] = {}
    for rid, (uid, track, roles, band) in own.items():
        if uid is None or roles is None or not TRACK_ID_RE.match(track):
            facts[rid] = FilterFacts(band, None, None)
            continue
        conflict: bool | None = False
        dup: bool | None = False
        for sid, suid, status, sroles in siblings.get(track, []):
            if sid == rid:
                continue
            if suid is None or sroles is None:
                # a sibling we cannot read could be either: both answers are unmeasured unless already true
                conflict = conflict or None
                dup = dup or None
                continue
            if suid != uid and status in CONFLICT_STATUSES and roles & sroles:
                conflict = True
            if suid == uid and status in SELF_DUPLICATE_STATUSES and roles == sroles:
                dup = True
        facts[rid] = FilterFacts(band, conflict, dup)
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
def writes_today(path: str = AUDIT_PATH, now: datetime | None = None, action: str = "reject") -> int:
    """Rows this automation RESERVED today (UTC), from its own audit file. A reservation is written BEFORE its PUT
    (QA #1475), so a write whose final audit line was lost still counts: the cap can only over-count. Closes and
    approvals have SEPARATE caps; a line without an `action` field is a close (reject / claim decline)."""
    day = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%d")
    seen: set[str] = set()
    try:
        with open(path, encoding="utf-8") as fh:
            for n, line in enumerate(fh):
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if (rec.get("outcome") in ("reserved", "written") and str(rec.get("ts", "")).startswith(day)
                        and (rec.get("action") or "reject") == action):
                    rid = rec.get("request_id")
                    # a reservation and its final line are ONE write; a line without ids counts on its own
                    seen.add(f"{rec.get('run_id', '')}|{rid}" if rid else f"line{n}")
    except FileNotFoundError:
        return 0
    return len(seen)


def closed_today(path: str = AUDIT_PATH, now: datetime | None = None, action: str = "reject",
                 own_batch: tuple[str, Iterable[str]] | None = None) -> dict[int, str]:
    """{user id: the latest time today (UTC) a PUT of this action WROTE (or tried: not_moved) one of their rows},
    from the audit file. Fable [key=executor-one-put-per-user]: core's transition notice fires per PUT with no
    per-user daily cap, so a user who had such a PUT today gets no further one today. EVERY run counts, this one
    included, and every attempt counts - a retried request id too (QA #1553). A 'reserved' line counts as an attempt
    too (a crash after the PUT but before its final line leaves only the reservation, QA #1553): only `own_batch`
    = (run id, request ids) - the boundary's own batch, reserved right before its PUT - is not counted."""
    day = (now or datetime.now(timezone.utc)).strftime("%Y-%m-%d")
    own_run, own_ids = (own_batch[0], {str(i).lower() for i in own_batch[1]}) if own_batch else (None, set())
    out: dict[int, str] = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                ts = str(rec.get("ts", ""))
                if (rec.get("outcome") == "reserved" and rec.get("run_id") == own_run
                        and str(rec.get("request_id", "")).lower() in own_ids):
                    continue
                if (rec.get("outcome") in ("written", "not_moved", "reserved") and ts.startswith(day)
                        and (rec.get("action") or "reject") == action
                        and isinstance(rec.get("user_id"), int)):
                    out[rec["user_id"]] = max(out.get(rec["user_id"], ""), ts)
    except FileNotFoundError:
        return {}
    return out


def _eligible(tray: "Tray", rows: list["TrayRow"], facts_fn: Callable, gate_fn: Any, anchor_fn: Callable,
              outcome_fn: Callable, evidence_fn: Callable, audit_path: str, at: datetime,
              registry_path: str = REGISTRY, filter_fn: Callable | None = None) -> set[int]:
    """id() of every row that passes the full guard chain right now (the slot pre-read)."""
    facts = facts_fn([r.request_id for r in rows])
    closed = closed_today(audit_path, at, tray.action)
    gate = account_gate.Cached(gate_fn)
    anchors = anchor_fn([r.request_id for r in rows]) if tray.refuse_if_dsp_anchor else {}
    outcomes = outcome_fn([r.coded_outcome for r in rows])
    evidence = evidence_fn(rows) if tray.recheck_evidence else {}
    ok: set[int] = set()
    refuse = refusal_for(tray, registry_path, [r.request_id for r in rows], filter_fn)
    for r in rows:
        f = facts.get(r.request_id.lower())
        why = refuse(r, f, gate(r.user_id), tray.expected_status)
        if not why:
            why = same_day_refusal(r, closed)
        if not why:
            why = coded_outcome_refusal(tray, r, outcomes)
        if not why and tray.refuse_if_dsp_anchor:
            why = _anchor_refusal(anchors.get(r.request_id.lower(), "unknown"))
        if not why and tray.recheck_evidence:
            why = _evidence_refusal(evidence.get(r.request_id.lower(), "unknown"))
        if not why:
            ok.add(id(r))
    return ok


def same_day_refusal(row: "TrayRow", closed: dict[int, str]) -> str | None:
    """Fable + r5 [key=executor-one-put-per-user] FINAL: a user who already had a PUT of this action today gets no
    further one - every later row waits for tomorrow's run (day_cap_user). Enforced here, independent of core."""
    return "day_cap_user" if row.user_id in closed else None


def batch_ruling(rows: list["TrayRow"]) -> str:
    """The ruling id a one-user PUT carries: the rows' common ruling, else `user:<id>` (the boundary then checks
    every id is that user's row in the tray)."""
    rulings = {r.ruling_id for r in rows}
    return rulings.pop() if len(rulings) == 1 else f"user:{rows[0].user_id}"


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


def registry_apply_enabled(path: str = REGISTRY) -> bool:
    """The entry's apply switch, fail closed: absent, unreadable or not the literal true = off."""
    try:
        entry = json.loads(Path(path).read_text())["automations"][AUTOMATION_ID]
    except (OSError, ValueError, KeyError, TypeError):
        return False
    return entry.get("apply_enabled") is True


def registry_apply_filter(path: str = REGISTRY) -> tuple[dict[str, Any] | None, str]:
    """(the entry's approve filter, "") when it is at least the floor, else (None, why). The floor is code: a
    registry edit can tighten the filter (a lower per-run cap, more excluded bands) and cannot loosen it."""
    try:
        flt = json.loads(Path(path).read_text())["automations"][AUTOMATION_ID].get("apply_filter")
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None, "registry unreadable"
    return apply_filter_floor(flt)


def apply_filter_floor(flt: Any) -> tuple[dict[str, Any] | None, str]:
    """(the block, "") when an `apply_filter` block is at least the floor, else (None, why). Every policy block
    that can lead to an approve write is read by this one function, whichever automation it sits under."""
    if not isinstance(flt, dict):
        return None, "no apply_filter block"
    if set(flt) != APPLY_FILTER_KEYS:
        return None, f"apply_filter keys are {sorted(flt)}, not {sorted(APPLY_FILTER_KEYS)}"
    if flt["outcome"] != APPLY_FILTER_OUTCOME:
        return None, f"outcome must be {APPLY_FILTER_OUTCOME}"
    bands = flt["exclude_bands"]
    if (not isinstance(bands, list) or not all(isinstance(b, str) and b and b == b.strip().lower() for b in bands)
            or "none" not in bands):
        return None, 'exclude_bands must be a list of lower-case bands holding "none"'
    for key in ("exclude_conflict_rule_failures", "exclude_self_duplicate_groups", "batch_id_required"):
        if flt[key] is not True:
            return None, f"{key} must be true"
    cap = flt["per_run_cap"]
    if not isinstance(cap, int) or isinstance(cap, bool) or not 1 <= cap <= APPROVE_CAP:
        return None, f"per_run_cap must be an integer 1..{APPROVE_CAP}"
    return flt, ""


def approve_filter(block: Any, rows: Iterable[Any], batch_id: Any, *, written: int = 0,
                   filter_fn: Callable[[Iterable[str]], dict[str, FilterFacts]] | None = None) -> dict[str, str]:
    """request id -> why the approve filter keeps it out, for an approve writer that is not the tray executor
    (the decider's document class). A row absent from the answer may be written. The same floor, row filter,
    batch id rule and per-run cap as the executor's own path: `written` is what this run already wrote, and a
    row past the cap waits for another run. The replica is read once, and only for rows whose outcome the
    filter admits at all; a read that fails leaves them unmeasured, which refuses."""
    rows = list(rows)
    flt, _why = apply_filter_floor(block)
    if flt is None:
        return {r.request_id: "apply_filter_invalid" for r in rows}
    if batch_refusal(batch_id):
        return {r.request_id: "batch_id_missing" for r in rows}
    ids = [r.request_id for r in rows if credit_anchored(r)]
    measured: dict[str, FilterFacts] = {}
    if ids:
        try:
            measured = {k.lower(): v for k, v in (filter_fn or approve_filter_facts)(ids).items()}
        except Exception:  # noqa: BLE001 - an unread filter is unmeasured, never a pass
            measured = {}
    out: dict[str, str] = {}
    room = flt["per_run_cap"] - max(0, int(written))
    for r in rows:
        why = filter_refusal(r, flt, measured.get(r.request_id.lower()))
        if why is None:
            if room <= 0:
                why = "per_run_cap_reached"
            else:
                room -= 1
        if why is not None:
            out[r.request_id] = why
    return out


def batch_rows(batch_id: str, path: str = AUDIT_PATH) -> list[str]:
    """Request ids the audit shows WRITTEN under this batch id, in write order (read-only). Returning a batch is
    one conditional-status PUT of these ids; a person makes it, this module has no revert."""
    out: list[str] = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict) and rec.get("batch_id") == batch_id and rec.get("outcome") == "written":
                out.append(str(rec.get("request_id", "")).lower())
    return out


# ── the write ───────────────────────────────────────────────────────────────
Writer = Callable[[list[str], str, str, str, str], dict[str, Any]]
Readback = Callable[[str, list[str]], set[str]]


def admin_writer(script: str | None = None, timeout_s: int = 300) -> Writer:
    """PUT conditional-status as fable-decider. The wrapper's standing authorization checks the same registry
    entry, the kill file, the ruling id and the exact batch shape before anything leaves the host."""
    from . import admin as admin_api
    script = script or os.environ.get("CREDIT_REVIEW_ADMIN_SCRIPT", admin_api.DEFAULT_ADMIN_SCRIPT)

    def write(ids: list[str], expected: str, ruling_id: str, run_id: str, tray_path: str,
              status: str = CLOSE_STATUS) -> dict[str, Any]:
        body = json.dumps({"requestIds": ids, "status": status, "expectedStatus": expected},
                          separators=(",", ":"), sort_keys=True)
        env = {**os.environ, "FABLE_DECIDER": "1", "FABLE_RULING_ID": ruling_id,
               "FABLE_DECIDER_RUN_ID": run_id, "FABLE_DECIDER_TRAY": os.path.abspath(tray_path),
               "CREDIT_TRUST_DECIDE": "0", "CREDIT_TRUST_SCORE_APPROVE": "0", "UVN_POPULARITY_CRON": "0",
               "MUSO_ADMIN_IDENTITY": APPROVE_IDENTITY if status == APPROVE_STATUS else ADMIN_IDENTITY}
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
    batch_id: str | None = None       # approve runs only
    server_reported: int = 0          # ids the server's own answer named as updated (approve runs only)

    def as_dict(self) -> dict[str, Any]:
        out = {"tray": self.tray, "mode": self.mode, "rows": self.rows, "written": self.written,
               "written_paid": self.written_paid, "written_free": self.written - self.written_paid,
               "refused": dict(sorted(self.refused.items())), "not_moved": self.not_moved,
               "stopped": self.stopped}
        if self.batch_id is not None:
            out.update(batch_id=self.batch_id, server_reported=self.server_reported)
        return out


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


def _base(tray: Tray, run_id: str, r: TrayRow, f: Facts | None, now: datetime, mode: str,
          batch_id: str | None = None) -> dict[str, Any]:
    return {**({"batch_id": batch_id} if batch_id else {}),
            "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "run_id": run_id, "automation": AUTOMATION_ID,
            "tray": tray.path, "tray_sha256": tray.sha256, "request_id": r.request_id, "user_id": r.user_id,
            "paid": bool(f.paid) if f else r.paid, "rule": r.rule, "ruling_id": r.ruling_id,
            "before": f.status if f else None, "mode": mode, "action": tray.action,
            "coded_outcome": r.coded_outcome, **dict(r.audit_extra)}


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
        audit_path: str = AUDIT_PATH, registry_path: str = REGISTRY, kill_files: tuple[str, ...] = KILL_FILES,
        daily_cap: int | None = None, now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
        between_batches: Callable[[list[tuple[str, int, str | None]], datetime], str | None] | None = None,
        lock_path: str = WRITE_LOCK,
        anchor_fn: Callable[[list[str]], dict[str, str]] = dsp_anchors,
        readback_tries: int = 6, readback_wait_s: float = 5.0,
        sleep: Callable[[float], None] = time.sleep,
        outcome_fn: Callable[[list[str]], dict[str, dict[str, Any]]] = ledger_outcomes,
        evidence_fn: Callable[[list["TrayRow"]], dict[str, str]] | None = None,
        batch_id: str | None = None,
        filter_fn: Callable[[list[str]], dict[str, FilterFacts]] | None = None,
        ) -> Result:
    """Execute (apply) or dry-run one tray. In apply mode EVERY batch re-reads its rows' facts and the account gate
    immediately before its PUT (no fact or gate answer outlives its batch, QA #1475), under one lock from the cap
    check to the final audit, with a durable reservation line per row written BEFORE the PUT. Stops at the first
    surprise: a refused/failed write, a row the server reports not moved, a read-back failure, an unwritable audit,
    the kill file, the cap or the fan-out check.

    An APPROVE apply also needs a batch id (carried on every audit line of the run) and stops before any write
    without one; it writes at most the filter's per_run_cap rows; and the server's own count of updated ids must
    equal the count sent, or the run stops there."""
    if batch_id is not None and tray.action != "approve":
        raise ValueError("a batch id tags approve writes only")
    res = Result(tray.path, "apply" if apply else "dry-run", rows=len(tray.rows), batch_id=batch_id)
    per_run_cap: int | None = None
    if apply and tray.action == "approve":
        why = batch_refusal(batch_id)
        if why:
            res.stopped = why
            return res
        flt, _ = registry_apply_filter(registry_path)      # invalid = every row refused below, nothing written
        per_run_cap = flt["per_run_cap"] if flt else None
    evidence_fn = evidence_fn or (lambda rs: coded_evidence(rs, tray.recheck_evidence))
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
        outcomes = outcome_fn([r.coded_outcome for r in rows])
        evidence = evidence_fn(rows) if tray.recheck_evidence else {}
        closed = closed_today(audit_path, now(), tray.action)
        refuse = refusal_for(tray, registry_path, [r.request_id for r in rows], filter_fn)
        for r in rows:
            why = refuse(r, facts.get(r.request_id.lower()), gate(r.user_id), tray.expected_status)
            if not why:
                why = same_day_refusal(r, closed)
            if not why:
                why = coded_outcome_refusal(tray, r, outcomes)
            if not why and tray.refuse_if_dsp_anchor:
                why = _anchor_refusal(anchors.get(r.request_id.lower(), "unknown"))
            if not why and tray.recheck_evidence:
                why = _evidence_refusal(evidence.get(r.request_id.lower(), "unknown"))
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
    # Fable [key=executor-one-put-per-user]: ONE PUT per user per run (core's transition notice fires per PUT, with
    # no per-user daily cap). Users follow the TRAY order of their first row (paid first, or as listed); a batch is
    # every row of that user (all rulings: the PUT carries batch_ruling()), at most the day's room and BATCH_MAX. Rows
    # of a user that do not fit wait for another day, never for a second PUT today.
    # Paid-first holds ACROSS users at the cap (QA #1553): a user's batch takes only their rows inside the first `room`
    # rows still pending in tray order; their rows behind other users' pending rows wait (another day - the user has
    # had their one PUT), so [42 paid, 7 paid, 42 free] with room 2 closes 42-paid and 7-paid.
    # Slots go to ELIGIBLE rows only (QA #1553: an ineligible row ahead must not burn a slot and strand a later
    # eligible one): one pre-read of the whole tray decides the paid-first slot order; every batch still re-reads
    # fresh facts before its PUT, and a row that turned ineligible since simply leaves its slot unused.
    try:
        pre = _eligible(tray, rows, facts_fn, gate_fn, anchor_fn, outcome_fn, evidence_fn, audit_path, now(),
                        registry_path, filter_fn)
    except (OSError, TimeoutError) as exc:
        res.stopped = f"audit/lock failure: {str(exc)[:200]}"
        return res
    except Exception as exc:  # noqa: BLE001 - an unreadable pre-read sends nothing
        res.stopped = f"eligibility pre-read failed: {str(exc)[:200]}"
        return res
    remaining = list(rows)
    while remaining:
        # the next user is the owner of the first ELIGIBLE pending row (QA #1553: a user whose first row is
        # ineligible must not jump ahead of an eligible paid row of another user); with none eligible left, the
        # rest are batches of refusals only (audited, never written)
        uid = next((r.user_id for r in remaining if id(r) in pre), remaining[0].user_id)
        user_rows = [r for r in remaining if r.user_id == uid]
        remaining = [r for r in remaining if r.user_id != uid]
        ahead = user_rows + remaining              # the global pending order, this user's rows first in it
        moved_rows: list[tuple[str, int, str | None]] = []
        waiting = 0
        batch_start = now()
        try:
            with _locked(lock_path):
                for kill_file in kill_files:
                    if kill_file and os.path.exists(kill_file):
                        res.stopped = f"kill file {kill_file} present"
                        return res
                if not registry_approved(registry_path):
                    res.stopped = f"registry entry {AUTOMATION_ID} not approved"
                    return res
                room = min(BATCH_MAX, daily_cap - writes_today(audit_path, now(), tray.action))
                if room <= 0:
                    res.stopped = f"daily cap {daily_cap} reached"
                    return res
                if per_run_cap is not None:
                    left = per_run_cap - res.written - res.not_moved
                    if left <= 0:
                        res.stopped = f"per-run cap {per_run_cap} reached"
                        return res
                    room = min(room, left)
                # FRESH facts + gate for this batch only, right before the PUT. Inside the room: this user's rows
                # among the first `room` pending rows in tray order (paid first across users).
                order = {id(r): n for n, r in enumerate(rows)}
                pending = [r for r in sorted(ahead, key=lambda r: order[id(r)]) if id(r) in pre][:room]
                inside = {id(r) for r in pending}
                # this user's rows inside the room, plus their pre-read-ineligible rows (refused + audited below)
                window = [r for r in user_rows if id(r) in inside or id(r) not in pre]
                for r in user_rows:
                    if id(r) in pre and id(r) not in inside:
                        waiting += 1
                        _bump(res, "user_rows_over_room_wait_for_another_day")
                facts = facts_fn([r.request_id for r in window])
                closed = closed_today(audit_path, now(), tray.action)
                gate = account_gate.Cached(gate_fn)
                anchors = anchor_fn([r.request_id for r in window]) if tray.refuse_if_dsp_anchor else {}
                outcomes = outcome_fn([r.coded_outcome for r in window])
                evidence = evidence_fn(window) if tray.recheck_evidence else {}
                chunk: list[TrayRow] = []
                refuse = refusal_for(tray, registry_path, [r.request_id for r in window], filter_fn)
                for r in window:
                    if len(chunk) >= room:
                        waiting += 1        # never a second PUT for this user today: the rest waits a day
                        _bump(res, "user_rows_over_room_wait_for_another_day")
                        continue
                    f = facts.get(r.request_id.lower())
                    why = refuse(r, f, gate(r.user_id), tray.expected_status)
                    if not why:
                        why = same_day_refusal(r, closed)
                    if not why:
                        why = coded_outcome_refusal(tray, r, outcomes)
                    if not why and tray.refuse_if_dsp_anchor:
                        why = _anchor_refusal(anchors.get(r.request_id.lower(), "unknown"))
                    if not why and tray.recheck_evidence:
                        why = _evidence_refusal(evidence.get(r.request_id.lower(), "unknown"))
                    if why:
                        _bump(res, why)
                        audit({**_base(tray, run_id, r, f, now(), "apply", batch_id), "outcome": "refused",
                               "reason": why, "after": f.status if f else None}, audit_path)
                        continue
                    chunk.append(r)
                if not chunk:
                    continue
                ids = [r.request_id for r in chunk]
                ruling = batch_ruling(chunk)
                # durable reservation BEFORE the PUT: if this cannot be written, nothing is sent
                for r in chunk:
                    audit({**_base(tray, run_id, r, facts.get(r.request_id.lower()), now(), "apply", batch_id),
                           "outcome": "reserved"}, audit_path)
                try:
                    body = (writer(ids, tray.expected_status, ruling, run_id, tray.path, APPROVE_STATUS)
                        if tray.action == "approve" else writer(ids, tray.expected_status, ruling, run_id, tray.path))
                except Exception as exc:  # noqa: BLE001 - any refusal/failure stops the run
                    res.stopped = f"write failed: {str(exc)[:300]}"
                    body = {}
                data = body.get("data") if isinstance(body.get("data"), dict) else body
                reported = ({str(x).lower() for x in (data.get("updatedIds") or [])}
                            if isinstance(data, dict) else set())
                # Read back until every id reads rejected or the retries run out: the Trino verifier can trail
                # the primary by seconds (2026-10-29 03:50Z: 05fa5088 landed at :58.76 and read 'unverified'
                # ~1 s later). Only ids still not rejected after the last read count as not moved.
                landed: set[str] = set()
                for attempt in range(readback_tries):
                    try:
                        landed |= {x.lower() for x in readback(target_status(tray), ids)}
                    except Exception as exc:  # noqa: BLE001
                        res.stopped = (res.stopped + "; " if res.stopped else "") + f"read-back failed: {str(exc)[:200]}"
                        break
                    if len(landed) >= len({i.lower() for i in ids}) or attempt + 1 == readback_tries:
                        break
                    sleep(readback_wait_s)
                for r in chunk:
                    moved = r.request_id.lower() in landed
                    f = facts.get(r.request_id.lower())
                    audit({**_base(tray, run_id, r, f, now(), "apply", batch_id), "before": tray.expected_status,
                           "server_reported_updated": r.request_id.lower() in reported,
                           "after": target_status(tray) if moved else "unchanged_or_unknown",
                           "outcome": "written" if moved else "not_moved"}, audit_path)
                    if moved:
                        res.written += 1
                        res.written_paid += 1 if (f.paid if f else r.paid) else 0
                        moved_rows.append((r.request_id, r.user_id, f.profile_id if f else None))
                    else:
                        res.not_moved += 1
                if tray.action == "approve":
                    # the server's own count of updated rows must equal the count sent (the UPDATE's RETURNING)
                    sent = {i.lower() for i in ids}
                    res.server_reported += len(reported & sent)
                    if reported != sent and not res.stopped:
                        res.stopped = (f"server reported {len(reported)} updated id(s) for {len(sent)} sent in "
                                       f"batch {batch_id}; stopping")
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
        # the cap stop comes AFTER the fan-out read of the batch that reached it (QA #1553)
        if waiting and writes_today(audit_path, now(), tray.action) >= daily_cap:
            res.stopped = f"daily cap {daily_cap} reached; {waiting} row(s) of user {user_rows[0].user_id} wait"
            return res
    held = res.refused.get("user_rows_over_room_wait_for_another_day", 0)
    if held and writes_today(audit_path, now(), tray.action) >= daily_cap:
        res.stopped = f"daily cap {daily_cap} reached; {held} row(s) wait for another day"
    elif held and per_run_cap is not None and res.written + res.not_moved >= per_run_cap:
        res.stopped = f"per-run cap {per_run_cap} reached; {held} row(s) wait for another run"
    return res


# ── the wrapper's boundary check (QA #1475 Critical) ────────────────────────
RESERVATION_MAX_AGE_S = 600


def verify_batch(tray_path: str, ruling_id: str, run_id: str, ids: list[str], expected: str, *,
                 status: str = CLOSE_STATUS,
                 facts_fn: Callable[[list[str]], dict[str, Facts]] = fetch_facts,
                 gate_fn: Callable[[Any], account_gate.GateResult] | None = None,
                 anchor_fn: Callable[[list[str]], dict[str, str]] = dsp_anchors,
                 outcome_fn: Callable[[list[str]], dict[str, dict[str, Any]]] = ledger_outcomes,
                 evidence_fn: Callable[[list["TrayRow"]], dict[str, str]] | None = None,
                 audit_path: str = AUDIT_PATH, registry_path: str = REGISTRY,
                 now: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
                 filter_fn: Callable[[list[str]], dict[str, FilterFacts]] | None = None,
                 ) -> str | None:
    """Re-check ONE batch at the wrapper boundary, independently of the run that asked for it. None = allowed,
    else why not. The wrapper calls this for every fable-decider close, so a caller who sets the env flags and
    skips the executor still meets: a loadable tray naming every id under this ruling and status, a fresh
    'reserved' audit line per id from this run, the tray's daily cap counted over today's reservations, and every
    row guard on fresh facts + the account gate (+ the DSP-anchor guard when the tray asks for it). An approve
    batch also needs ONE valid batch id on its reservations, the run's reservations inside the filter's per-run
    cap, and every row through the approve filter on a fresh read."""
    try:
        tray = load_tray(tray_path)
    except (TrayError, OSError) as exc:
        return f"tray unusable: {exc}"
    if status != target_status(tray):
        return f"body status {status} is not what this {tray.action} tray writes ({target_status(tray)})"
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
        if ruling_id.startswith("user:"):
            if f"user:{r.user_id}" != ruling_id:
                return f"{i} is not a row of {ruling_id} in the tray"
        elif r.ruling_id != ruling_id:
            return f"{i} is not under ruling {ruling_id} in the tray"
    if len({rows[i].user_id for i in want}) != 1:
        return "one PUT per user: this batch spans several users"
    cutoff = now().timestamp() - RESERVATION_MAX_AGE_S
    reserved: set[str] = set()
    batches: dict[str, Any] = {}
    run_reserved: set[str] = set()          # every id this run reserved on this tray, at any age
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
                if rec.get("tray_sha256") != tray.sha256:
                    continue
                rid = str(rec.get("request_id", "")).lower()
                run_reserved.add(rid)
                if ts.timestamp() >= cutoff:
                    reserved.add(rid)
                    batches[rid] = rec.get("batch_id")
    except OSError as exc:
        return f"audit unreadable: {exc}"
    missing = [i for i in want if i not in reserved]
    if missing:
        return f"{len(missing)} id(s) have no fresh reservation from run {run_id} on this tray"
    if writes_today(audit_path, now(), tray.action) > tray.daily_cap:
        return f"daily cap {tray.daily_cap} exceeded by today's reservations"
    if tray.action == "approve":
        tags = {json.dumps(batches.get(i)) for i in want}
        if len(tags) != 1 or batch_refusal(batches.get(want[0])):
            return "the approve reservations do not carry one valid batch id"
        flt, _ = registry_apply_filter(registry_path)     # invalid = refused by the row guard below
        if flt is not None and len(run_reserved) > flt["per_run_cap"]:
            return f"per-run cap {flt['per_run_cap']} exceeded by the reservations of run {run_id}"
    facts = facts_fn(want)
    gate = account_gate.Cached(gate_fn)
    closed = closed_today(audit_path, now(), tray.action, own_batch=(run_id, want))
    anchors = anchor_fn(want) if tray.refuse_if_dsp_anchor else {}
    outcomes = outcome_fn([rows[i].coded_outcome for i in want])
    evidence_fn = evidence_fn or (lambda rs: coded_evidence(rs, tray.recheck_evidence))
    evidence = evidence_fn([rows[i] for i in want]) if tray.recheck_evidence else {}
    refuse = refusal_for(tray, registry_path, want, filter_fn)
    for i in want:
        r = rows[i]
        why = refuse(r, facts.get(i), gate(r.user_id), tray.expected_status)
        if not why:
            why = same_day_refusal(r, closed)
        if not why:
            why = coded_outcome_refusal(tray, r, outcomes)
        if not why and tray.refuse_if_dsp_anchor:
            why = _anchor_refusal(anchors.get(i, "unknown"))
        if not why and tray.recheck_evidence:
            why = _evidence_refusal(evidence.get(i, "unknown"))
        if why:
            return f"{i}: {why}"
    return None
