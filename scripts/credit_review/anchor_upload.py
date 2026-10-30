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


def admin_poster(script: str | None = None, timeout_s: int = 120) -> Poster:
    from . import admin as admin_api
    script = script or os.environ.get("CREDIT_REVIEW_ADMIN_SCRIPT", admin_api.DEFAULT_ADMIN_SCRIPT)

    def post(records: list[dict[str, Any]]) -> dict[str, Any]:
        env = {**os.environ, "DSP_ANCHOR_WRITER": "1", "MUSO_ADMIN_IDENTITY": IDENTITY,
               "FABLE_DECIDER": "0", "CREDIT_TRUST_DECIDE": "0", "CREDIT_TRUST_SCORE_APPROVE": "0"}
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


def anchor_key(rec: dict[str, Any]) -> tuple[str, str, str, str]:
    """The (request, role, kind, source) identity core keys an anchor on (its unique index normalizes role with
    lower(btrim()); requestId is lower-cased server-side)."""
    return (str(rec.get("requestId") or "").lower(), str(rec.get("role") or "").strip().lower(),
            str(rec.get("kind") or ""), str(rec.get("source") or ""))


def reconcile(submitted: list[dict[str, Any]], results: list[dict[str, Any]]) -> dict[str, Any]:
    """Match core's per-record results to what was SUBMITTED, key by key (QA #1497 @9088c3d9: counting result
    entries let a duplicate Spotify answer hide a missing Tidal one). A key is landed only when it is answered
    EXACTLY ONCE with a success outcome. Returns {ok:set, missing:[], duplicate:[], unexpected:[], refused:{key:reason}}."""
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
        else:
            out["refused"][k] = str(got[0].get("reason") or got[0].get("outcome"))
    out["unexpected"] = sorted(k for k in seen if k not in want)
    return out


def push(store: Any, request_ids: list[str], *, apply: bool, poster: Poster | None = None) -> dict[str, Any]:
    """Convert + (apply) post the built records for these requests. Dry run unless apply."""
    built = latest_built(store, request_ids)
    report: dict[str, Any] = {"requests": len(request_ids), "with_built_record": len(built),
                              "missing_built": sorted({r.lower() for r in request_ids} - set(built)),
                              "convert_errors": {}, "core_rows": 0, "written": 0, "refused": {}, "errors": 0,
                              "missing_results": 0, "duplicate_results": 0, "unexpected_results": 0,
                              "mode": "apply" if apply else "dry-run"}
    rows: list[tuple[str, dict[str, Any]]] = []
    for rid, b in built.items():
        try:
            for core in to_core_records(b["record"]):
                rows.append((rid, core))
        except ConvertError as exc:
            report["convert_errors"][rid] = str(exc)
    report["core_rows"] = len(rows)
    if not apply:
        return report
    if not rows:
        report["stopped"] = "incomplete: no anchor rows to upload for the requested ids"
        return report
    poster = poster or admin_poster()
    run_id = "push-" + uuid.uuid4().hex[:10]
    for i in range(0, len(rows), MAX_RECORDS):
        chunk = rows[i:i + MAX_RECORDS]
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
            store.add_anchor(run_id, rid, "written" if ok else "write_refused", kind=built[rid]["kind"],
                             ruling_id=built[rid]["ruling_id"], record=built[rid]["record"], sink_response=got)
    report["run_id"] = run_id
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
