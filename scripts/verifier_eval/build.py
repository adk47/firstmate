"""Build the frozen labelled sets from the firstmate data lanes (run on the Mac that holds them).

    python3 scripts/verifier-eval.py build --data ~/Projects/firstmate/data

Inputs (read-only; all produced 26-28 Oct by the review lanes):

credits
  * docs-review-prep-p1 (paid) / -p2 (free): ``raw/collect-mac.json`` (requests + validator record +
    stage-2 document verdicts), ``raw/dsp-read.json`` (same-run IDP ``helpers.fresh_capture`` per role per
    source), ``raw/gate.json`` (account gate fable-v2), ``raw/idp_hold_ids.txt``.
  * declined-review-prep-p3: ``index.csv`` (validator-declined class; request-level capture aggregate only).
  * labels: user-decisions-fable-d1 ``docs-*-approve.json`` + ``jan-docs-*.md`` bodies; -d3
    ``jan-declined-b*.md`` bodies (the org tray is NOT a label: it waits on a captain call).
  * human/audit: hydra ``scripts/credit_retro/manifests/takeback*.jsonl`` (approved credits a named human
    took back on contradicting evidence) -> DECLINE, known_bad.
claims
  * claims-review-prep-c1 (paid) / -c2 (free): ``work/claims.jsonl``, ``scored.jsonl`` (CRS), ``code-check.jsonl``,
    ``gate.json``; labels from user-decisions-fable-d2 ``jan-claims-*.md`` (declines named there, rest WAIT).
merges
  * profile-merge-ops-m1: ``queue-classes-1026.json`` (ops classification), ``d1-batch-1028.md`` §2 per-case checks.
fraud confirmations (all sets)
  * hydra ``policies/fraud-watchlist.json`` (tier fraud/review), credit-authenticity-audit-a1
    ``chart_fraud_list.csv`` T1 submitters.

Privacy: items keep ids, popularity, roles and verdict codes only - no names, e-mails, track titles,
credited-person names or document text.
"""

from __future__ import annotations

import csv
import glob
import json
import os
import re
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from .schema import APPROVE, DECLINE, WAIT

REPO = Path(__file__).resolve().parents[2]
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"


def _json(path: Path | str, default: Any = None) -> Any:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def _jsonl(path: Path | str) -> list[dict[str, Any]]:
    out = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("{"):
                    out.append(json.loads(line))
    except OSError:
        pass
    return out


def _roles(raw: Any) -> list[str]:
    if isinstance(raw, list):
        return [str(r) for r in raw]
    s = str(raw or "").strip().strip("{}")
    return [r.strip().strip('"') for r in s.split(",") if r.strip()]


# ── fraud confirmations ──────────────────────────────────────────────────────────────────

def fraud_index(data: Path) -> dict[str, dict[str, str]]:
    """user_id -> {"watchlist": tier, "fraud_account": "1"} from the watchlist + chart-fraud T1 submitters."""
    idx: dict[str, dict[str, str]] = defaultdict(dict)
    wl = _json(REPO / "policies" / "fraud-watchlist.json", {}) or {}
    for e in wl.get("entries", []):
        for uid in e.get("user_ids") or []:
            tier = e.get("tier") or "review"
            if idx[str(uid)].get("watchlist") != "fraud":
                idx[str(uid)]["watchlist"] = tier
            if tier == "fraud":
                idx[str(uid)]["fraud_account"] = "watchlist"
    cf = data / "credit-authenticity-audit-a1" / "chart_fraud_list.csv"
    if cf.exists():
        with open(cf, encoding="utf-8") as fh:
            for row in csv.DictReader(fh):
                if row.get("tier", "").startswith("T1"):
                    for uid in re.split(r"[;, ]+", row.get("submitters") or ""):
                        if uid.strip().isdigit():
                            idx[uid.strip()]["fraud_account"] = "chart_fraud_T1"
    return dict(idx)


def _flags(uid: Any, fraud: dict[str, dict[str, str]], idp_hold: set[str]) -> dict[str, Any]:
    f = fraud.get(str(uid), {})
    return {"watchlist": f.get("watchlist"), "fraud_account": bool(f.get("fraud_account")),
            "idp_hold": str(uid) in idp_hold}


def _ids(path: Path) -> set[str]:
    try:
        return {ln.strip() for ln in open(path, encoding="utf-8") if ln.strip()}
    except OSError:
        return set()


# ── credit labels ────────────────────────────────────────────────────────────────────────

def _json_blocks(md: str) -> list[dict[str, Any]]:
    out = []
    for block in re.findall(r"```json\s*(.*?)```", md, flags=re.S):
        try:
            obj = json.loads(block)
        except ValueError:
            continue
        if isinstance(obj, dict):
            out.append(obj)
    return out


def credit_labels(data: Path) -> tuple[dict[str, dict[str, Any]], list[str]]:
    """request_id -> {label, approved_roles, ref}. Later files do not silently override: a conflict
    (approve in one tray, decline in another) is recorded and the item is labelled WAIT."""
    labels: dict[str, dict[str, Any]] = {}
    conflicts: list[str] = []

    def put(rid: str, label: str, roles: list[str] | None, ref: str) -> None:
        prev = labels.get(rid)
        if prev and prev["label"] != label:
            conflicts.append(f"{rid}: {prev['label']}@{prev['ref']} vs {label}@{ref}")
            prev.update(label=WAIT, approved_roles=None, ref=prev["ref"] + "|" + ref + "|conflict")
            return
        if prev and roles and prev.get("approved_roles"):
            roles = sorted(set(prev["approved_roles"]) & set(roles)) or roles
        labels[rid] = {"label": label, "approved_roles": roles if label == APPROVE else None, "ref": ref}

    d1 = data / "user-decisions-fable-d1"
    for path in sorted(glob.glob(str(d1 / "docs-*-approve.json"))):
        obj = _json(path, {}) or {}
        edits = obj.get("role_edits_before_approval") or {}
        ref = "d1/" + os.path.basename(path)
        for rid in obj.get("approve_request_ids") or []:
            put(rid, APPROVE, edits.get(rid), ref)
        for rid in obj.get("decline_request_ids") or []:
            put(rid, DECLINE, None, ref)
    md_files = sorted(glob.glob(str(d1 / "jan-docs-*.md"))) + sorted(
        glob.glob(str(data / "user-decisions-fable-d3" / "jan-declined-b*.md")))
    for path in md_files:
        ref = path.split("/data/")[-1]
        for obj in _json_blocks(Path(path).read_text(encoding="utf-8")):
            status = obj.get("status")
            ids = obj.get("requestIds") or []
            edits = obj.get("roleEditsBeforeApproval") or {}
            for rid in ids:
                if status == "approved":
                    put(rid, APPROVE, edits.get(rid), ref)
                elif status == "rejected":
                    put(rid, DECLINE, None, ref)
    return labels, conflicts


# ── credit evidence ──────────────────────────────────────────────────────────────────────

def _src(sv: dict[str, Any]) -> dict[str, Any]:
    return {"state": sv.get("state"), "verdict": sv.get("helper_verdict"), "reason": sv.get("helper_reason"),
            "complete": bool(sv.get("complete_snapshot")), "name_match": bool(sv.get("claimant_name_match")),
            "n_credited": len(sv.get("credited_in_family") or []),
            "captured_at": sv.get("captured_at")}


def _validator(v: dict[str, Any] | None) -> dict[str, Any] | None:
    if not v:
        return None
    codes = list(v.get("hold_reason_codes") or [])
    fired = v.get("fired") or {}
    rules = [c for c in codes if c.startswith("reject_")] + [k for k in fired if str(k).startswith("reject_")]
    return {"is_approved": v.get("is_approved"), "band_hint": v.get("band_hint"), "hold_reason_codes": codes,
            "fraud_rules": sorted(set(rules)), "tier": v.get("tier"),
            "velocity_7d": (v.get("footprint") or {}).get("velocity_7d")}


def docs_prep_items(lane: Path, segment: str, labels: dict[str, dict[str, Any]],
                    fraud: dict[str, dict[str, str]]) -> list[dict[str, Any]]:
    raw = lane / "raw"
    collect = _json(raw / "collect-mac.json", {}) or {}
    dsp = _json(raw / "dsp-read.json", {}) or {}
    gate = (_json(raw / "gate.json", {}) or {}).get("users", {})
    idp = _ids(raw / "idp_hold_ids.txt")
    by_user_track: dict[tuple[str, str], dict[str, Any]] = {}
    read_at: dict[str, str] = {}
    for key, rec in dsp.items():
        uid = key.split("#")[0]
        for tid, tv in (rec.get("tracks") or {}).items():
            by_user_track[(uid, tid)] = tv
            read_at[f"{uid}:{tid}"] = rec.get("read_at")
    items = []
    for uid, u in (collect.get("users") or {}).items():
        g = gate.get(str(uid)) or {}
        for rid, req in (u.get("requests") or {}).items():
            tv = by_user_track.get((str(uid), req.get("track_id")))
            dsp_ev = None
            if tv:
                dsp_ev = {role: {"one_person": bool(rv.get("one_person")),
                                 "sources": {s: _src(sv) for s, sv in (rv.get("sources") or {}).items()}}
                          for role, rv in (tv.get("roles") or {}).items()}
            lab = labels.get(rid, {"label": WAIT, "approved_roles": None, "ref": "unlisted-in-ruled-tray=WAIT"})
            flags = _flags(uid, fraud, idp)
            items.append({
                "set": "credits", "id": rid, "segment": segment, "user_id": str(uid),
                "label": lab["label"], "approved_roles": lab["approved_roles"],
                "known_bad": bool(flags["fraud_account"]) and lab["label"] != APPROVE,
                "label_source": f"fable-d1-{lane.name}", "label_strength": "fable_handoff", "label_ref": lab["ref"],
                "evidence": {
                    "profile_id": req.get("profile_id"), "track_id": req.get("track_id"),
                    "popularity": req.get("popularity"), "roles": _roles(req.get("roles")),
                    "status": req.get("status"), "created_at": req.get("created_at"),
                    "gate": {"decision": g.get("decision"), "band": g.get("band")} if g else None,
                    "flags": flags, "validator": _validator(req.get("validator")),
                    "docs": [{"role": s.get("role"), "outcome": s.get("outcome"), "verdict": s.get("verdict"),
                              "doc_kind": s.get("doc_kind")} for s in (req.get("stage2") or [])],
                    "dsp": dsp_ev, "capture_read_at": read_at.get(f"{uid}:{req.get('track_id')}"),
                    "source_lane": lane.name},
            })
    return items


def p3_items(lane: Path, labels: dict[str, dict[str, Any]], fraud: dict[str, dict[str, str]]) -> list[dict[str, Any]]:
    path = lane / "index.csv"
    if not path.exists():
        return []
    items = []
    with open(path, encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            rid, uid = r["request_id"], r["user_id"]
            lab = labels.get(rid, {"label": WAIT, "approved_roles": None, "ref": "unlisted-in-ruled-tray=WAIT"})
            flags = _flags(uid, fraud, set())
            flags["idp_hold"] = r.get("idp_hold") == "True"
            codes = re.findall(r"'([^']+)'", r.get("hold_reason_codes") or "")
            try:
                pop = int(float(r["popularity"])) if r.get("popularity") else None
            except ValueError:
                pop = None
            items.append({
                "set": "credits", "id": rid, "segment": "paid" if r.get("paid") == "True" else "free",
                "user_id": uid, "label": lab["label"], "approved_roles": lab["approved_roles"],
                "known_bad": bool(flags["fraud_account"]) and lab["label"] != APPROVE,
                "label_source": "fable-d3-declined-p3", "label_strength": "fable_handoff", "label_ref": lab["ref"],
                "evidence": {
                    "track_id": None, "popularity": pop, "roles": _roles(r.get("roles")), "status": r.get("status"),
                    "created_at": r.get("created_at"),
                    "gate": {"decision": r.get("gate_decision") or None, "band": r.get("gate_band") or None},
                    "flags": flags,
                    "validator": {"is_approved": False, "hold_reason_codes": codes,
                                  "fraud_rules": [c for c in codes if c.startswith("reject_")],
                                  "band_hint": r.get("band_hint"), "tier": r.get("tier")},
                    "dsp": None,  # p3 kept a request-level aggregate only (first read, 17:31Z)
                    "dsp_aggregate": {k: r.get(k) for k in ("spotify_state", "spotify_verdict", "tidal_state",
                                                            "tidal_verdict")}
                    | {"spotify_name_match": r.get("spotify_name_match") == "True",
                       "tidal_name_match": r.get("tidal_name_match") == "True"},
                    "source_lane": lane.name},
            })
    return items


def takeback_items(fraud: dict[str, dict[str, str]]) -> list[dict[str, Any]]:
    items = []
    for name in ("takeback-r1.jsonl", "takeback-bigboy-r1.jsonl"):
        for r in _jsonl(REPO / "scripts" / "credit_retro" / "manifests" / name):
            rid = r.get("row_id") or f"{r.get('request_id')}:{r.get('role')}"
            web = r.get("web") or {}
            items.append({
                "set": "credits", "id": f"takeback:{rid}", "segment": "paid" if r.get("paying") else "free",
                "user_id": str(r.get("user_id")) if r.get("user_id") else None,
                "label": DECLINE, "approved_roles": None, "known_bad": True,
                "label_source": "credit-retro-takeback", "label_strength": "human",
                "label_ref": f"scripts/credit_retro/manifests/{name}",
                "evidence": {"profile_id": r.get("profile_id"), "track_id": r.get("track_id"),
                             "popularity": r.get("pop_now"), "roles": [r.get("role")] if r.get("role") else [],
                             "status": "approved", "gate": None,
                             "flags": _flags(r.get("user_id"), fraud, set()),
                             "validator": {"is_approved": None, "risk": r.get("validator_risk"),
                                           "fraud_rules": [], "hold_reason_codes": []},
                             "dsp": None, "web_audit_verdict": web.get("verdict"),
                             "source_lane": "credit-retro-r1"},
            })
    return items


def build_credits(data: Path, fraud: dict[str, dict[str, str]]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    labels, conflicts = credit_labels(data)
    items: dict[str, dict[str, Any]] = {}
    for it in (docs_prep_items(data / "docs-review-prep-p1", "paid", labels, fraud)
               + docs_prep_items(data / "docs-review-prep-p2", "free", labels, fraud)
               + p3_items(data / "declined-review-prep-p3", labels, fraud) + takeback_items(fraud)):
        if it["id"] in items:  # a request in two lanes: keep the one with per-role capture evidence
            if (items[it["id"]].get("evidence") or {}).get("dsp") and not it["evidence"].get("dsp"):
                continue
        items[it["id"]] = it
    orphan = 0
    for rid, lab in labels.items():  # ruled ids with no frozen evidence stay as label-only rows
        if rid not in items:
            orphan += 1
            items[rid] = {"set": "credits", "id": rid, "segment": "unknown", "user_id": None,
                          "label": lab["label"], "approved_roles": lab["approved_roles"], "known_bad": False,
                          "label_source": "fable-d1-d3-label-only", "label_strength": "fable_handoff",
                          "label_ref": lab["ref"], "evidence": None}
    meta = {"labels_read": len(labels), "label_conflicts": conflicts, "label_only_rows": orphan}
    return list(items.values()), meta


# ── claims ───────────────────────────────────────────────────────────────────────────────

def claim_declines(data: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for path in sorted(glob.glob(str(data / "user-decisions-fable-d2" / "jan-claims-*.md"))):
        text = Path(path).read_text(encoding="utf-8")
        ref = path.split("/data/")[-1]
        for cid in re.findall(r"/admin/claiming/(\d+)/reject", text):
            out[cid] = ref
        for cid in re.findall(r"^### (\d{6,8}) — ", text, flags=re.M):
            out[cid] = ref
    return out


def _ts(s: str | None) -> datetime | None:
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def build_claims(data: Path, fraud: dict[str, dict[str, str]]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    from .verifiers import FREE_MAIL, TEST_DOMAINS

    declines = claim_declines(data)
    rows = []
    for lane, segment in (("claims-review-prep-c1", "paid"), ("claims-review-prep-c2", "free")):
        work = data / lane / "work"
        scored = {str(r["id"]): r for r in _jsonl(work / "scored.jsonl")}
        code = {str(r["id"]): r for r in _jsonl(work / "code-check.jsonl")}
        gate = (_json(work / "gate.json", {}) or {}).get("users", {})
        idp = _ids(work / "idp_hold_ids.txt")
        for c in _jsonl(work / "claims.jsonl"):
            rows.append((lane, segment, c, scored.get(str(c["id"])), code.get(str(c["id"])), gate, idp))
    # account-level "unrelated big claims within 7 days" across BOTH lanes
    big_by_user: dict[str, list[tuple[datetime, str]]] = defaultdict(list)
    for _l, _s, c, sc, *_ in rows:
        pop = ((sc or {}).get("features") or {}).get("popularity") or 0
        t = _ts(c.get("createdAt"))
        if pop >= 80 and t:  # d2 §5 shape: Bob Gaudio (86) + Pinkfong (80) on one account
            big_by_user[str(c["userId"])].append((t, c["profileId"]))
    items = []
    for lane, segment, c, sc, cc, gate, idp in rows:
        cid, uid = str(c["id"]), str(c.get("userId"))
        f = (sc or {}).get("features") or {}
        t = _ts(c.get("createdAt"))
        big7 = len({p for (bt, p) in big_by_user.get(uid, []) if t and abs(bt - t) <= timedelta(days=7)})
        dom = (c.get("email_domain") or "").lower()
        email_class = "test" if dom in TEST_DOMAINS else ("free" if dom in FREE_MAIL else ("corporate" if dom else "unknown"))
        prior_rej = sum(1 for o in (c.get("pk_profile_other_claims") or [])
                        if o.get("status") == "rejected" and str(o.get("userId")) != uid)
        bound = (cc or {}).get("bound") or []
        g = gate.get(uid) or {}
        flags = _flags(uid, fraud, idp)
        label = DECLINE if cid in declines else WAIT
        items.append({
            "set": "claims", "id": cid, "segment": segment, "user_id": uid, "label": label,
            "approved_roles": None, "known_bad": bool(flags["fraud_account"]),
            "label_source": "fable-d2-claims", "label_strength": "fable_handoff",
            "label_ref": declines.get(cid, "ruled NEEDS-CODE (=WAIT) in d2 jan-claims trays"),
            "evidence": {
                "profile_id": c.get("profileId"), "profile_type": c.get("profileType"),
                "popularity": f.get("popularity"), "credit_count": f.get("creditCount"),
                "email_class": email_class, "org_domain_match": f.get("orgDomainMatch"),
                "company_claim_on_add": c.get("reason") == "company claim on add",
                "created_by_user_org": c.get("reason") == "created by user",
                "prior_other_user_rejections": prior_rej, "competing_users": len(f.get("competingUsers") or []),
                "name_fold": f.get("nameFold"), "pasted_url_matches_raw": bool(f.get("r1Matched")),
                "account_age_days": f.get("accountAgeDays"), "claims_last_7d": f.get("claimsLast7d"),
                "user_big_unrelated_claims_7d": big7,
                "bound_surfaces": len(bound),
                "proof": {"e1_bound_code_verified": bool((cc or {}).get("storedProof"))
                          or any(b.get("found") is True for b in bound),
                          "e3_oauth_strict": False, "second_signal": False},
                "gate": {"decision": g.get("decision"), "band": g.get("band")} if g else None,
                "flags": flags,
                "crs": {"action": (sc or {}).get("action"), "band": (sc or {}).get("band"),
                        "score": (sc or {}).get("score")} if sc else None,
                "source_lane": lane},
        })
    missing = sorted(set(declines) - {i["id"] for i in items})
    return items, {"declines_read": len(declines), "declines_without_claim_row": missing}


# ── merges ───────────────────────────────────────────────────────────────────────────────

MERGE_CLASS_LABEL = {
    "A_already_merged": APPROVE,           # executed and verified: a correct merge
    "D1_eligible_now": WAIT,               # coarse class; the m1 re-check below is the label where it exists
    "B_contested_two_workspaces": DECLINE,  # two workspaces claim the profiles: never auto-merge
    "D2_eligible_login_loser": DECLINE,    # loser is a login / primary profile: core refuses, no override
    "C_needs_claim": WAIT, "C_needs_claim_pending": WAIT, "F_no_profile_ids": WAIT,
}
# m1 d1-batch-1028 §2: eligible, threaded, every profile named by the requester, both gates pass, no
# popularity/direction/ambiguity flag -> the only owner-confirmed merges the re-check found clean.
MERGE_CLEAN_PAIRS = {"869dm4g1j:e3b98e89", "869dgnk6h:00c227cd"}
BLOCK_FACT = {"not_all_processed_claims": ("all_processed_claims_same_workspace", False),
              "login_or_primary_loser": ("no_login_or_primary_loser", False),
              "org_profile": ("no_org_profile", False)}


def _cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip("|").split("|")]


def _merge_recheck(md: str) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    """(pairs from the §4 shadow log, §2 per-pair facts, blocked tickets with reasons)."""
    pairs: dict[str, dict[str, Any]] = {}
    facts: dict[str, dict[str, Any]] = {}
    blocked: dict[str, dict[str, Any]] = {}
    for line in md.splitlines():
        c = _cells(line)
        if len(c) == 7 and c[1] in ("D2-login-loser", "executable-L7"):
            key = f"{c[0]}:{c[4]}"
            pairs[key] = {"ticket": c[0], "state": c[1], "keep": c[3], "loser": c[4],
                          "cli_gate": "PASS" if c[5].startswith("PASS") else "refused",
                          "cli_reason": "" if c[5].startswith("PASS") else c[5][:120],
                          "core": "409_login_or_primary_loser" if "409" in c[6] else "accepts"}
        elif len(c) == 9 and re.fullmatch(r"[0-9a-z]{9,12}", c[0]) and "<-" not in c[2]:
            keep_loser = re.findall(r"[0-9a-f]{8}", c[2])
            if len(keep_loser) < 2:
                continue
            pops = [int(x) for x in re.findall(r"\d+", c[4])[:2]] or [0]
            claim_parts = [p.strip() for p in c[5].split(";")]
            statuses = [p.split(":")[0] for part in claim_parts for p in part.split(",") if p]
            teams = {p.split(":")[-1] for part in claim_parts for p in part.split(",") if p}
            facts[f"{c[0]}:{keep_loser[1]}"] = {
                "all_processed_claims_same_workspace": statuses[-1:] == ["processed"] and len(teams) == 1
                and claim_parts[0].split(",")[-1].startswith("processed"),
                "max_popularity": max(pops), "survivor_has_fewer_credits": "survivor_has_fewer_credits" in c[6]}
        else:
            m = re.match(r"- ([0-9a-z]{9,12}) \([\d.]+ d, conv [^)]*\): blocked: (.*)$", line.strip())
            if m:
                reasons = [r.strip() for r in m.group(2).split(",")]
                ev: dict[str, Any] = {}
                for r in reasons:
                    for slug, (k, v) in BLOCK_FACT.items():
                        if r.startswith(slug):
                            ev[k] = v
                ev["survivor_has_fewer_credits"] = any("survivor_has_fewer" in r for r in reasons)
                ev["max_popularity"] = 60 if any("popularity>=60" in r for r in reasons) else None
                blocked[m.group(1)] = {"reasons": reasons, "facts": ev}
    return pairs, facts, blocked


def build_merges(data: Path, fraud: dict[str, dict[str, str]]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    lane = data / "profile-merge-ops-m1"
    classes = _json(lane / "queue-classes-1026.json", {}) or {}
    md = (lane / "d1-batch-1028.md").read_text(encoding="utf-8") if (lane / "d1-batch-1028.md").exists() else ""
    pairs, facts, blocked = _merge_recheck(md)
    ticket_class = {str(t["id"]): cls for cls, ts in classes.items() for t in ts}
    items: list[dict[str, Any]] = []
    paired_tickets = {p["ticket"] for p in pairs.values()}
    for key, p in pairs.items():
        ev: dict[str, Any] = {"cli_gate": p["cli_gate"], "cli_reason": p["cli_reason"],
                              "core_merge_route": p["core"], "flags": {"watchlist": None},
                              "no_login_or_primary_loser": p["core"] == "accepts",
                              "ambiguous_same_name": "same-name profile" in p["cli_reason"],
                              "no_org_profile": None, "all_processed_claims_same_workspace": None,
                              "requester_named_profiles": None}
        if "not claimed by any workspace" in p["cli_reason"] or "claimed by a different owner" in p["cli_reason"]:
            ev["all_processed_claims_same_workspace"] = False
        if key in facts:
            ev.update(facts[key])
            ev.update({"no_org_profile": True, "requester_named_profiles": True})
        if p["core"] != "accepts":
            label, src, strength = DECLINE, "core-409-login-or-primary-loser", "audit"
        elif key in MERGE_CLEAN_PAIRS:
            label, src, strength = APPROVE, "m1-recheck-clean-owner-confirmed", "ops_classification"
        else:
            label, src, strength = WAIT, "m1-recheck-needs-human-or-thread", "ops_classification"
        items.append({"set": "merges", "id": key, "segment": "unknown", "user_id": None, "label": label,
                      "approved_roles": None, "known_bad": False, "label_source": src,
                      "label_strength": strength, "label_ref": "profile-merge-ops-m1/d1-batch-1028.md",
                      "evidence": ev})
    for tid, cls in ticket_class.items():
        if tid in paired_tickets:
            continue
        ev2 = None
        label = MERGE_CLASS_LABEL.get(cls, WAIT)
        src = f"m1-queue-class:{cls}"
        if tid in blocked:
            ev2 = {"flags": {"watchlist": None}, "requester_named_profiles": None, "no_org_profile": None,
                   "all_processed_claims_same_workspace": None, "no_login_or_primary_loser": None,
                   **blocked[tid]["facts"], "blocked_reasons": blocked[tid]["reasons"]}
            label, src = WAIT, "m1-recheck-blocked"
        items.append({"set": "merges", "id": tid, "segment": "unknown", "user_id": None, "label": label,
                      "approved_roles": None, "known_bad": False, "label_source": src,
                      "label_strength": "ops_classification",
                      "label_ref": "profile-merge-ops-m1/queue-classes-1026.json + d1-batch-1028.md",
                      # The queue class is the LABEL, never evidence: unchecked tickets carry no inputs.
                      "evidence": ev2})
    return items, {"pairs_from_shadow_log": len(pairs), "blocked_tickets": len(blocked),
                   "tickets": len(ticket_class)}


def build_merges_relabel(facts_path: Path, tag: str, strict_holds: bool = True) -> dict[str, Any]:
    """``sets/merges@relabel-<tag>``: the SAME merge items labelled independently from today's facts
    (merge_relabel.py over a read-only replica + catalog snapshot). APPROVE = the self-serve merge
    should execute now; DECLINE = it must refuse; WAIT = already merged (no-op) or needs review."""
    import gzip

    from .merge_relabel import relabel_all
    from .runner import write_set

    facts = json.load(gzip.open(facts_path, "rt", encoding="utf-8"))
    wl = _json(REPO / "policies" / "fraud-watchlist.json", {}) or {}
    watch = {str(u) for e in wl.get("entries", []) for u in e.get("user_ids") or []}
    labels = relabel_all(facts, watch, strict_holds)
    items = []
    for k, lab in labels.items():
        g = lab["label"]
        label = APPROVE if g == "eligible" else (DECLINE if g.startswith("refused:") else WAIT)
        items.append({"set": "merges", "id": k, "segment": "unknown", "user_id": lab.get("requester"),
                      "label": label, "approved_roles": None, "known_bad": False,
                      "label_source": f"relabel-{tag}:{g}", "label_strength": "audit",
                      "label_ref": f"{facts_path.name} read {facts.get('read_at')} (n19 replica + industry-api)",
                      "evidence": {"relabel": g, "basis": lab["basis"], "core_admin_route": lab.get("core"),
                                   "flags": {"watchlist": None},
                                   # guard facts, as the independent read found them (a self-serve request
                                   # names its own profiles; a needed primary switch is part of eligible)
                                   "all_processed_claims_same_workspace":
                                       g not in ("refused:NOT_CLAIMED", "refused:OPEN_CLAIM"),
                                   "no_org_profile": g != "refused:ORG_PROFILE",
                                   "no_login_or_primary_loser": g != "refused:PRIMARY_PROFILE",
                                   "requester_named_profiles": True}})
    n = write_set(f"merges@relabel-{tag}", items)
    return {"items": n, "labels": dict(Counter(i["label"] for i in items)),
            "relabel": dict(Counter(lab["label"] for lab in labels.values())), "read_at": facts.get("read_at")}


def build_all(data: Path) -> dict[str, Any]:
    from .runner import write_set

    fraud = fraud_index(data)
    meta: dict[str, Any] = {"fraud_index_users": len(fraud)}
    for name, fn in (("credits", build_credits), ("claims", build_claims), ("merges", build_merges)):
        items, m = fn(data, fraud)
        meta[name] = {"items": write_set(name, items), **m,
                      "labels": dict(Counter(i["label"] for i in items)),
                      "segments": dict(Counter(i["segment"] for i in items)),
                      "known_bad": sum(1 for i in items if i["known_bad"]),
                      "with_evidence": sum(1 for i in items if i["evidence"])}
    return meta
