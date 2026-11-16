"""Upload the DSP verifier's built anchor records to core (POST /admin/credit-anchors), as the verifier.

Fable [key=l12-approvals-core] = option A; core #11010/#11011. The verifier (#1478) builds one `dsp-anchor/1`
record per approve-tray row into its own store (`dsp_anchors`, outcome `built`), re-computed from its own same-run
capture, never from the tray. This module converts each built record into core's per-(role, source) rows and posts
them under X-Credit-Automation-Id `dsp-evidence-verifier` on the decider's login. Core re-decides everything that
admits an approval (the role is claimed, the claimant match, freshness); nothing here can make a record match.

Conversion (one core row per role and source):
  dsp_anchor      -> kind dsp_anchor, source spotify|tidal, captureIds + capturedAt of that DSP's capture block,
                     roleHolders = every holder the capture listed {raw_id, profile_id, linked, name}
  dsp_label_line  -> kind dsp_label_line, source label_line, captureIds = the catalog read's capture request id,
                     capturedAt = the label lines' read time, labelLine = the matched ℗/©/label line
Every outcome is appended to the verifier store (`written` / `write_refused` / `write_error`, with core's answer).
"""
from __future__ import annotations

import json
import os
import subprocess
import uuid
from datetime import datetime, timezone
from typing import Any, Callable

ROUTE = "/admin/credit-anchors"
REQUESTER = "dsp-evidence-verifier@hydra-ops"
IDENTITY = "credit-decider"                 # agent-credit-decider@muso.ai: the verifier's identity, never the approver
MAX_RECORDS = 100

Poster = Callable[[list[dict[str, Any]]], dict[str, Any]]


class ConvertError(ValueError):
    pass


def to_core_records(rec: dict[str, Any]) -> list[dict[str, Any]]:
    """One built dsp-anchor/1 record -> core rows. Raises ConvertError on anything missing (never guesses)."""
    if rec.get("schema") != "dsp-anchor/1":
        raise ConvertError(f"schema {rec.get('schema')!r} is not dsp-anchor/1")
    rid, kind = rec.get("request_id"), rec.get("kind")
    ruling = (rec.get("metadata") or {}).get("ruling_id")
    roles = rec.get("roles") or []
    if not rid or not roles:
        raise ConvertError("record has no request_id or no roles")
    out: list[dict[str, Any]] = []
    if kind == "dsp_anchor":
        evidence = rec.get("role_evidence") or {}
        for role in roles:
            blocks = (evidence.get(role) or {}).get("sources") or []
            by_src = {b.get("source"): b for b in blocks}
            for src in ("spotify", "tidal"):
                b = by_src.get(src)
                if not b or not b.get("capture_ids") or not b.get("captured_at"):
                    raise ConvertError(f"{rid} {role}: no {src} capture block with ids and captured_at")
                out.append({"requestId": rid, "role": role, "kind": "dsp_anchor", "source": src,
                            "captureIds": [str(c) for c in b["capture_ids"]][:20], "capturedAt": b["captured_at"],
                            "roleHolders": [{"raw_id": h.get("raw_id"), "profile_id": h.get("catalog_profile_id"),
                                             "linked": h.get("is_claimant_linked_id") is True, "name": h.get("name")}
                                            for h in b.get("role_holders") or []][:50],
                            "rulingRef": ruling})
    elif kind == "dsp_label_line":
        lines = [x for x in rec.get("label_lines") or [] if isinstance(x, dict) and x.get("string")]
        cap = rec.get("capture_request_id")
        at = rec.get("label_lines_read_at")
        if not lines or not cap or not at:
            raise ConvertError(f"{rid}: label record without a matched line, capture request id or read time")
        for role in roles:
            out.append({"requestId": rid, "role": role, "kind": "dsp_label_line", "source": "label_line",
                        "captureIds": [str(cap)], "capturedAt": at, "labelLine": str(lines[0]["string"])[:500],
                        "rulingRef": ruling})
    else:
        raise ConvertError(f"{rid}: kind {kind!r} is not an anchor kind")
    return out


BUILD_OUTCOMES = ("built", "refused")      # the verifier's verdict on a record; written / write_* are upload outcomes


def latest_built(store: Any, request_ids: list[str]) -> dict[str, dict[str, Any]]:
    """{request id: its record} ONLY when the request's LATEST build outcome is `built` (QA #1497: a later `refused`
    means the evidence no longer stands, so the earlier record is never uploaded). Ids without one are absent."""
    latest: dict[str, dict[str, Any]] = {}
    want = {r.lower() for r in request_ids}
    for row in store.anchors():                      # ordered by id
        rid = str(row.get("request_id") or "").lower()
        if rid in want and row.get("outcome") in BUILD_OUTCOMES:
            latest[rid] = row
    return {rid: {"id": row["id"], "kind": row.get("kind"), "ruling_id": row.get("ruling_id"),
                  "record": json.loads(row["record_json"])}
            for rid, row in latest.items() if row.get("outcome") == "built" and row.get("record_json")}


MAX_REFUSALS = 3      # uploads of ONE built record that core answered with a refusal
MAX_ERRORS = 12       # uploads of ONE built record that never got an answer, or whose answer did not account for it
RETRY_COOLDOWN_S = 3600            # how long an upload-exhausted record rests before a reachable core gets it back
RETRY_GRANTED = "retry_granted"    # the append-only row that hands an exhausted record a new error budget
UNPOSTABLE_PREFIX = "convert: "    # a write_error made here, before any POST: no answer from core can cure it


def _epoch(at: Any) -> float | None:
    """The verifier store's `at` (UTC, `YYYY-MM-DDTHH:MM:SSZ`) as epoch seconds; None when it cannot be read."""
    try:
        return datetime.strptime(str(at), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def pending(store: Any) -> dict[str, Any]:
    """What the scheduled push owes core: every request whose LATEST build outcome is `built` and whose record has
    not landed since (no `written` row after that build). A record is tried at most MAX_REFUSALS times against a
    core refusal and MAX_ERRORS times against a failed upload; past either it is `exhausted` and named on every
    run. A newer build starts both counts again. A `retry_granted` row (see `cooled`) starts the ERROR count
    again and nothing else: it never clears a refusal. Oldest build first.
    Returns {pending: [request id], exhausted: {request id: why}, exhausted_at: {request id: when the error cap
    was reached}, unpostable: [request id exhausted on an error made before any POST], built: n, landed: n}."""
    state: dict[str, dict[str, Any]] = {}
    for row in store.anchor_outcomes():              # ordered by id; no record bodies
        rid = str(row.get("request_id") or "").lower()
        outcome = row.get("outcome")
        if not rid:
            continue
        if outcome in BUILD_OUTCOMES:
            state[rid] = {"built": outcome == "built" and bool(row.get("has_record")), "at": row.get("id") or 0,
                          "landed": False, "refused": 0, "errors": 0, "capped_at": None, "unpostable": False}
        elif rid in state:
            s = state[rid]
            if outcome == "written":
                s["landed"] = True
            elif outcome == "write_refused":
                s["refused"] += 1
            elif outcome == "write_error":
                s["errors"] += 1
                s["unpostable"] = str(row.get("reason") or "").startswith(UNPOSTABLE_PREFIX)
                if s["errors"] == MAX_ERRORS:  # the count passes through the cap one row at a time
                    s["capped_at"] = row.get("at")
            elif outcome == RETRY_GRANTED:
                s["errors"], s["capped_at"] = 0, None
    out: dict[str, Any] = {"pending": [], "exhausted": {}, "exhausted_at": {}, "unpostable": [], "built": 0,
                           "landed": 0}
    for rid, s in sorted(state.items(), key=lambda kv: (kv[1]["at"], kv[0])):
        if not s["built"]:
            continue
        out["built"] += 1
        if s["landed"]:
            out["landed"] += 1
        elif s["refused"] >= MAX_REFUSALS:
            out["exhausted"][rid] = f"refused_by_core_{s['refused']}_times"
        elif s["errors"] >= MAX_ERRORS:
            out["exhausted"][rid] = f"upload_failed_{s['errors']}_times"
            out["exhausted_at"][rid] = s["capped_at"]
            if s["unpostable"]:
                out["unpostable"].append(rid)
        else:
            out["pending"].append(rid)
    return out


def awaiting_retry(owed: dict[str, Any]) -> list[str]:
    """The exhausted records of `pending()` this driver still owes core an upload of: exhausted on failed uploads
    and postable. Not terminal - `cooled` hands each back once its cooldown has run out and core answers. The
    other exhausted records are terminal until the verifier builds a newer one: core REFUSED the record (core
    answered; asking again changes nothing) or it failed before any POST (`unpostable`). One whose exhaustion
    time cannot be read is still owed here, though `cooled` never hands it back: unmeasured is not terminal."""
    return sorted(rid for rid, why in owed["exhausted"].items()
                  if why.startswith("upload_failed_") and rid not in owed["unpostable"])


def cooled(owed: dict[str, Any], now_s: float, cooldown_s: int = RETRY_COOLDOWN_S) -> list[str]:
    """The upload-exhausted records of `pending()` whose cooldown has run out: the ones a reachable core gets back.
    Exhaustion is a cooldown, not a tombstone (firstmate 2026-11-15): without this a three-hour core outage cost
    every anchor built during it, because the only thing that cleared the count was the upload that could no
    longer be attempted. Never a record core REFUSED (core answered; asking again changes nothing), never one
    that failed before any POST (`unpostable`: a reachable core cannot convert it), and never one whose
    exhaustion time cannot be read."""
    out = []
    for rid in awaiting_retry(owed):
        at = _epoch(owed["exhausted_at"].get(rid))
        if at is not None and now_s - at >= cooldown_s:
            out.append(rid)
    return out


def grant_retry(store: Any, request_ids: list[str], run_id: str, owed: dict[str, Any]) -> None:
    """Append one `retry_granted` row per record: `pending()` then counts its upload errors from zero."""
    for rid in request_ids:
        store.add_anchor(run_id, rid, RETRY_GRANTED, kind=None, ruling_id=None, verdict_id=None,
                         reason=f"core reachable; exhausted at {owed['exhausted_at'].get(rid)}, "
                                f"cooldown {RETRY_COOLDOWN_S}s elapsed")


PROBE_PATH = "/admin/credit-requests?status=unverified&limit=1"


def _admin_env() -> dict[str, str]:
    return {**os.environ, "DSP_ANCHOR_WRITER": "1", "MUSO_ADMIN_IDENTITY": IDENTITY,
            "FABLE_DECIDER": "0", "CREDIT_TRUST_DECIDE": "0", "CREDIT_TRUST_SCORE_APPROVE": "0"}


def admin_probe(script: str | None = None, timeout_s: int = 30) -> Callable[[], bool]:
    """Is core reachable for the upload? ONE admin GET (a read, never a post) through the same wrapper, login and
    requester the upload uses, so it fails for the reasons an upload would: the wrapper, the login, core. It does
    not depend on any upload having worked. Measured on node-8 2026-11-15T17:23Z: HTTP 200 in 0.44 s."""
    from . import admin as admin_api
    script = script or os.environ.get("CREDIT_REVIEW_ADMIN_SCRIPT", admin_api.DEFAULT_ADMIN_SCRIPT)

    def probe() -> bool:
        try:
            proc = subprocess.run(["bash", script, "--requester", REQUESTER, "call", "GET", PROBE_PATH],
                                  capture_output=True, text=True, timeout=timeout_s, check=False, env=_admin_env())
            if proc.returncode != 0:
                return False
            code = json.loads(proc.stdout.strip().splitlines()[-1]).get("http_status")
        except (OSError, subprocess.SubprocessError, ValueError, IndexError, AttributeError):
            return False
        return isinstance(code, int) and 200 <= code < 300
    return probe


def admin_poster(script: str | None = None, timeout_s: int = 120) -> Poster:
    from . import admin as admin_api
    script = script or os.environ.get("CREDIT_REVIEW_ADMIN_SCRIPT", admin_api.DEFAULT_ADMIN_SCRIPT)

    def post(records: list[dict[str, Any]]) -> dict[str, Any]:
        env = _admin_env()
        body = json.dumps({"records": records}, separators=(",", ":"), sort_keys=True)
        proc = subprocess.run(["bash", script, "--requester", REQUESTER, "call", "POST", ROUTE, body],
                              capture_output=True, text=True, timeout=timeout_s, check=False, env=env)
        if proc.returncode != 0:
            raise RuntimeError(f"POST refused/failed rc={proc.returncode}: {proc.stderr.strip()[:400]}")
        resp = json.loads(proc.stdout)
        code = resp.get("http_status")
        if not isinstance(code, int) or not 200 <= code < 300:
            raise RuntimeError(f"POST HTTP {code}: {json.dumps(resp.get('body'))[:300]}")
        body_out = resp.get("body") or {}
        return body_out.get("data") if isinstance(body_out.get("data"), dict) else body_out
    return post


OK_OUTCOMES = ("written", "replaced", "not_fresher")
REFUSED_OUTCOMES = ("refused",)   # core judged the row; anything else is an answer that did not account for it


def anchor_key(rec: dict[str, Any]) -> tuple[str, str, str, str]:
    """The (request, role, kind, source) identity core keys an anchor on (its unique index normalizes role with
    lower(btrim()); requestId is lower-cased server-side)."""
    return (str(rec.get("requestId") or "").lower(), str(rec.get("role") or "").strip().lower(),
            str(rec.get("kind") or ""), str(rec.get("source") or ""))


def reconcile(submitted: list[dict[str, Any]], results: list[dict[str, Any]]) -> dict[str, Any]:
    """Match core's per-record results to what was SUBMITTED, key by key (QA #1497 @9088c3d9: counting result
    entries let a duplicate Spotify answer hide a missing Tidal one). A key is landed only when it is answered
    EXACTLY ONCE with a success outcome, and refused only when core says `refused`: a matching key with a missing
    or unknown outcome is an answer that did not account for the row, never a refusal (QA 2026-11-15: it was
    counted as one and exhausted the record after three runs). Returns
    {ok:set, missing:[], duplicate:[], unexpected:[], refused:{key:reason}}."""
    want = {anchor_key(r) for r in submitted}
    seen: dict[tuple, list[dict[str, Any]]] = {}
    for res in results:
        seen.setdefault(anchor_key(res), []).append(res)
    out: dict[str, Any] = {"ok": set(), "missing": [], "duplicate": [], "unexpected": [], "refused": {}}
    for k in sorted(want):
        got = seen.get(k, [])
        if not got:
            out["missing"].append(k)
        elif len(got) > 1:
            out["duplicate"].append(k)
        elif got[0].get("outcome") in OK_OUTCOMES:
            out["ok"].add(k)
        elif got[0].get("outcome") in REFUSED_OUTCOMES:
            out["refused"][k] = str(got[0].get("reason") or got[0].get("outcome"))
    out["unexpected"] = sorted(k for k in seen if k not in want)
    return out


def pack_requests(rows_by_rid: dict[str, list[tuple[str, dict[str, Any]]]],
                  order: list[str]) -> tuple[list[list[str]], dict[str, str]]:
    """Whole requests packed into POSTs of at most MAX_RECORDS rows. A request is never split across POSTs; one
    whose rows exceed the cap is not posted at all and is returned as a bad record."""
    out: list[list[str]] = []
    bad: dict[str, str] = {}
    cur: list[str] = []
    size = 0
    for rid in order:
        rows = rows_by_rid.get(rid)
        if rows is None:
            continue
        n = len(rows)
        if n > MAX_RECORDS:
            bad[rid] = f"{n} core rows exceed the {MAX_RECORDS}-row cap for one request"
            continue
        if cur and size + n > MAX_RECORDS:
            out.append(cur)
            cur, size = [], 0
        cur.append(rid)
        size += n
    if cur:
        out.append(cur)
    return out, bad


def push(store: Any, request_ids: list[str], *, apply: bool, poster: Poster | None = None) -> dict[str, Any]:
    """Convert + (apply) post the built records for these requests. Dry run unless apply."""
    built = latest_built(store, request_ids)
    report: dict[str, Any] = {"requests": len(request_ids), "with_built_record": len(built),
                              "missing_built": sorted({r.lower() for r in request_ids} - set(built)),
                              "convert_errors": {}, "core_rows": 0, "written": 0, "refused": {}, "errors": 0,
                              "missing_results": 0, "duplicate_results": 0, "unexpected_results": 0,
                              "written_requests": [], "mode": "apply" if apply else "dry-run"}
    rows_by_rid: dict[str, list[tuple[str, dict[str, Any]]]] = {}
    for rid, b in built.items():
        try:
            rows_by_rid[rid] = [(rid, core) for core in to_core_records(b["record"])]
        except ConvertError as exc:
            report["convert_errors"][rid] = str(exc)
    groups, bad = pack_requests(rows_by_rid, list(built))
    report["convert_errors"].update(bad)
    report["core_rows"] = sum(len(rows) for rows in rows_by_rid.values())
    if not apply:
        return report
    if not groups:
        if report["convert_errors"]:
            report["stopped"] = "incomplete: " + "; ".join(
                f"{rid}: {why}" for rid, why in sorted(report["convert_errors"].items()))[:300]
        else:
            report["stopped"] = "incomplete: no anchor rows to upload for the requested ids"
        return report
    poster = poster or admin_poster()
    run_id = "push-" + uuid.uuid4().hex[:10]
    for group in groups:
        chunk = [row for rid in group for row in rows_by_rid[rid]]
        try:
            ans = poster([c for _, c in chunk])
        except Exception as exc:  # noqa: BLE001 - recorded per request, then stop
            for rid in {r for r, _ in chunk}:
                store.add_anchor(run_id, rid, "write_error", kind=built[rid]["kind"], reason=str(exc)[:600],
                                 ruling_id=built[rid]["ruling_id"], verdict_id=None)
            report["errors"] += len(chunk)
            report["stopped"] = str(exc)[:300]
            return report
        results = ans.get("results") or []
        if not isinstance(results, list):
            results = []
        rec = reconcile([c for _, c in chunk], [r for r in results if isinstance(r, dict)])
        report["written"] += len(rec["ok"])
        report["missing_results"] += len(rec["missing"])
        report["duplicate_results"] += len(rec["duplicate"])
        report["unexpected_results"] += len(rec["unexpected"])
        for reason in rec["refused"].values():
            report["refused"][reason] = report["refused"].get(reason, 0) + 1
        for rid in {r for r, _ in chunk}:
            keys = {anchor_key(c) for r, c in chunk if r == rid}
            got = [res for res in results if isinstance(res, dict) and anchor_key(res)[0] == rid]
            ok = keys <= rec["ok"]          # EVERY submitted key of this request landed exactly once
            refused_keys = set(rec["refused"])
            unaccounted = (not keys <= (rec["ok"] | refused_keys)
                           or any(k[0] == rid for k in rec["unexpected"]))
            if ok and not unaccounted:
                report["written_requests"].append(rid)
                outcome, reason = "written", None
            elif not unaccounted and refused_keys & keys:
                outcome, reason = "write_refused", None
            else:
                outcome, reason = "write_error", "core answer did not account for every submitted row"
                report["errors"] += 1   # an unaccounted answer is a failed upload, never a quiet success
            store.add_anchor(run_id, rid, outcome, kind=built[rid]["kind"], reason=reason,
                             ruling_id=built[rid]["ruling_id"], record=built[rid]["record"], sink_response=got)
    report["run_id"] = run_id
    report["written_requests"].sort()
    incomplete = (report["missing_built"] or report["convert_errors"] or report["refused"]
                  or report["missing_results"] or report["duplicate_results"] or report["unexpected_results"]
                  or report["written"] != report["core_rows"])
    if incomplete:
        # QA #1497: an apply that did not land EVERY requested row is a failure, never a false success a chained
        # approval step could run on.
        report["stopped"] = (f"incomplete: {report['written']}/{report['core_rows']} rows written; "
                             f"missing_built={len(report['missing_built'])} convert_errors={len(report['convert_errors'])} "
                             f"refused={sum(report['refused'].values())} missing_results={report['missing_results']} "
                             f"duplicate_results={report['duplicate_results']} "
                             f"unexpected_results={report['unexpected_results']}")
    return report
