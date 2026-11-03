"""Replay a verifier over a labelled set in shadow and score it.

Shadow only: the runner reads frozen items, calls a pure verifier (or reads a recorded verdict
log) and writes files under ``out_dir``. It imports no Muso client, holds no token and has no
code path that approves, declines, merges or messages anyone.
"""

from __future__ import annotations

import gzip
import hashlib
import importlib
import json
import os
import time
from pathlib import Path
from typing import Any, Callable, Iterable

from . import protections
from .schema import APPROVE, DECLINE, SEGMENTS_ORDER, STRENGTHS, UNKNOWN, WAIT, Verdict, validate_item
from .verifiers import REGISTRY

SETS_DIR = Path(__file__).resolve().parent / "sets"
KILL_SWITCH = os.environ.get("VERIFIER_EVAL_KILL_SWITCH", "/etc/hydra/verifier-eval.disabled")
# Must-be-zero safety counts. `errors` belongs here: a verifier that raises on an item is caught as
# UNKNOWN so the run survives, but a run with errors is a BROKEN verifier, not a clean one - it must
# never reach the board as `[clean]`.
MUST_BE_ZERO = ("false_approve", "approve_on_known_bad", "protection_violations", "errors")


# ── loading ──────────────────────────────────────────────────────────────────────────────

def base_set(name: str) -> str:
    """``merges@relabel-20261028`` -> ``merges``: a VARIANT is the same items under other labels."""
    return name.split("@", 1)[0]


def set_variants(base: str, sets_dir: Path | str = SETS_DIR) -> list[str]:
    """The base set plus every committed label variant ``<base>@<tag>.jsonl.gz``."""
    found = sorted(p.name[:-len(".jsonl.gz")] for p in Path(sets_dir).glob(f"{base}@*.jsonl.gz"))
    return [base, *found]


def authoritative_sets(sets_dir: Path | str = SETS_DIR) -> dict[str, str]:
    """``sets/authoritative.json``: which label set may ISSUE a readiness gate, and why.

    A gate ("the self-serve merge precondition is met") may only come from a label set whose safety
    checks were all actually read. Sensitivity variants exist to measure how much an answer depends on
    an unread gate; they may be scored and compared, but agreeing with one proves nothing about
    readiness. Keeping the list in a data file instead of an ``if`` means changing who may declare
    readiness is a reviewable diff, not a code edit buried in a metrics function.
    """
    path = Path(sets_dir) / "authoritative.json"
    if not path.exists():
        return {}
    return {str(k): str(v) for k, v in (json.loads(path.read_text(encoding="utf-8")).get("sets") or {}).items()}


def repo_recorded(sets_dir: Path | str = SETS_DIR) -> list[tuple[str, str, str]]:
    """Frozen shadow logs committed under ``sets/recorded/<set>/*.jsonl`` (a verifier's dry run kept
    for reproducibility; the nightly inbox adds live ones)."""
    out = []
    for base in ("credits", "claims", "merges"):
        for path in sorted((Path(sets_dir) / "recorded" / base).glob("*.jsonl")):
            out.append((f"log:{path.stem}", base, str(path)))
    return out


def load_set(name: str, sets_dir: Path | str = SETS_DIR) -> list[dict[str, Any]]:
    """Fail closed: a missing or empty set raises, so no verifier can score CLEAN on zero rows."""
    path = Path(sets_dir) / f"{name}.jsonl.gz"
    if not path.exists():
        raise FileNotFoundError(f"labelled set missing: {path}")
    items = []
    with gzip.open(path, "rt", encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if not line.strip():
                continue
            item = json.loads(line)
            errs = validate_item(item)
            if item.get("set") != base_set(name):
                errs.append(f"item set {item.get('set')!r} in set file {name!r}")
            if errs:
                raise ValueError(f"{path}:{n} invalid item {item.get('id')}: {errs}")
            items.append(item)
    if not items:
        raise ValueError(f"labelled set is empty: {path}")
    return items


def write_set(name: str, items: Iterable[dict[str, Any]], sets_dir: Path | str = SETS_DIR) -> int:
    """Deterministic gzip JSONL (sorted ids, mtime 0) so a rebuild with the same inputs is a no-op diff."""
    rows = sorted(items, key=lambda i: str(i["id"]))
    for it in rows:
        errs = validate_item(it)
        if errs:
            raise ValueError(f"invalid item {it.get('id')}: {errs}")
    path = Path(sets_dir) / f"{name}.jsonl.gz"
    path.parent.mkdir(parents=True, exist_ok=True)
    body = "".join(json.dumps(r, sort_keys=True, ensure_ascii=False) + "\n" for r in rows).encode()
    with open(path, "wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="") as gz:
        gz.write(body)
    return len(rows)


def load_verifier(spec: str) -> tuple[str, str, Callable[[dict[str, Any]], Verdict]]:
    """``name`` from the registry, or ``pkg.module:function`` with a ``set:`` prefix, e.g.
    ``credits:credit_verify.proof.shadow:verdict``."""
    if spec in REGISTRY:
        r = REGISTRY[spec]
        return spec, r["set"], r["fn"]
    set_name, _, target = spec.partition(":")
    mod, _, fn = target.partition(":")
    if not (set_name and mod and fn):
        raise ValueError(f"verifier {spec!r}: use a registry name or <set>:<module>:<function>")
    return spec, set_name, getattr(importlib.import_module(mod), fn)


def load_recorded(path: str) -> Callable[[dict[str, Any]], Verdict]:
    """A verifier that replays a recorded shadow log: JSONL rows {id, verdict, approved_roles?, reasons?}.
    Items the log never judged score as UNKNOWN (coverage is reported). An id judged more than once
    (re-runs, retries) scores its RISKIEST event - APPROVE > DECLINE > WAIT > UNKNOWN, approved roles
    unioned - so a later WAIT can never hide an earlier APPROVE from the false-approve count."""
    events: dict[str, list[tuple[str, dict[str, Any]]]] = {}
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if line.strip():
                row = json.loads(line)
                if "id" not in row:
                    raise ValueError(f"{path}:{n}: recorded row has no id")
                try:
                    verdict = _norm_verdict(row.get("verdict"))
                except ValueError as exc:  # fail closed, and say where
                    raise ValueError(f"{path}:{n}: {exc}") from None
                events.setdefault(str(row["id"]), []).append((verdict, row))

    def recorded(item: dict[str, Any]) -> Verdict:
        evs = events.get(str(item["id"]))
        if not evs:
            return Verdict(UNKNOWN, ["not_in_recorded_log"])
        worst = min(evs, key=lambda e: RISK_ORDER.index(e[0]))
        v, row = worst
        reasons = list(row.get("reasons") or [])
        roles = row.get("approved_roles")
        if len(evs) > 1:
            reasons.append(f"recorded_events:{len(evs)}:" + ",".join(e[0] for e in evs))
            if v == APPROVE:
                rs = [r for e in evs if e[0] == APPROVE for r in (e[1].get("approved_roles") or [])]
                roles = None if any(e[0] == APPROVE and e[1].get("approved_roles") is None for e in evs) \
                    else sorted(set(rs))
        return Verdict(v, reasons, approved_roles=roles)

    return recorded


RISK_ORDER = (APPROVE, DECLINE, WAIT, UNKNOWN)


ALIASES = {"VERIFIED": APPROVE, "PASS": APPROVE, "APPROVED": APPROVE, "ELIGIBLE": APPROVE,
           "CONTRADICTED": DECLINE, "REJECT": DECLINE, "REJECTED": DECLINE, "FAIL": DECLINE,
           "REFUSED": DECLINE, "QUEUED_REVIEW": WAIT, "ALREADY_MERGED": WAIT, "UNAVAILABLE": UNKNOWN}
# Only these take a ``<CODE>`` suffix (``refused:LOGIN_OR_PRIMARY_LOSER``, ``queued_review:LEGAL_HOLD_UNKNOWN``).
SUFFIXABLE = {"REFUSED", "QUEUED_REVIEW"}


def _norm_verdict(raw: Any) -> str:
    """Map a recorded verdict onto APPROVE / DECLINE / WAIT / UNKNOWN and RAISE on anything else.

    Fails closed on purpose. A misspelt or unsupported recorded verdict (``eligble``) is not a WAIT:
    silently scoring it as a judgement would count an invalid core result as coverage and as a binary
    match, which is exactly how the 100 %-coverage self-serve precondition could be met by a log that
    never judged the item.
    """
    parts = str(raw or "").upper().split(":")
    head, suffix = parts[0], parts[1:]
    if suffix and head not in SUFFIXABLE:
        raise ValueError(f"suffix not allowed on {raw!r}")
    v = ALIASES.get(head, head)
    if v not in RISK_ORDER:
        raise ValueError(f"unsupported recorded verdict {raw!r} (expected one of {', '.join(RISK_ORDER)} "
                         f"or an endpoint alias like ELIGIBLE / ALREADY_MERGED / REFUSED:<CODE>)")
    return v


# ── replay ───────────────────────────────────────────────────────────────────────────────

def evidence_sha(item: dict[str, Any]) -> str:
    return hashlib.sha256(json.dumps(item.get("evidence"), sort_keys=True).encode()).hexdigest()[:16]


def load_adjudications(sets_dir: Path | str = SETS_DIR) -> dict[str, dict[str, Any]]:
    path = Path(sets_dir) / "adjudications.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8")).get("items", {})


def replay(items: list[dict[str, Any]], fn: Callable[[dict[str, Any]], Verdict],
           adjudications: dict[str, dict[str, Any]] | None = None) -> list[dict[str, Any]]:
    adj = adjudications or {}
    rows = []
    for item in items:
        try:
            v = fn(item)
            err = None
        except Exception as exc:  # noqa: BLE001 - one bad row is a scored UNKNOWN, not a dead run
            v, err = Verdict(UNKNOWN, ["verifier_error"]), f"{type(exc).__name__}: {exc}"[:200]
        violations = protections.audit_approve(item, v.approved_roles) if v.verdict == APPROVE else []
        rows.append({
            "id": item["id"], "user_id": item.get("user_id"), "segment": item["segment"],
            "label": item["label"], "known_bad": bool(item.get("known_bad")),
            "label_strength": item["label_strength"], "label_source": item["label_source"],
            "label_roles": item.get("approved_roles"), "has_evidence": bool(item.get("evidence")),
            "verdict": v.verdict, "reasons": v.reasons[:6], "approved_roles": v.approved_roles,
            "violations": violations, "error": err, "evidence_sha": evidence_sha(item),
            "adjudication": (adj.get(str(item["id"])) or {}).get("finding"),
        })
    return rows


def _ratio(a: int, b: int) -> float | None:
    return round(a / b, 3) if b else None


def metrics(rows: list[dict[str, Any]]) -> dict[str, Any]:
    n = len(rows)
    lab = {k: sum(1 for r in rows if r["label"] == k) for k in (APPROVE, DECLINE, WAIT)}
    ver = {k: sum(1 for r in rows if r["verdict"] == k) for k in (APPROVE, DECLINE, WAIT, UNKNOWN)}
    appr = [r for r in rows if r["verdict"] == APPROVE]
    decl = [r for r in rows if r["verdict"] == DECLINE]
    tp_a = sum(1 for r in appr if r["label"] == APPROVE and not r["known_bad"])
    tp_d = sum(1 for r in decl if r["label"] == DECLINE)
    adj_ok = sum(1 for r in appr if r["label"] == WAIT and not r["known_bad"]
                 and str(r.get("adjudication") or "").startswith("label_"))
    role_over = 0
    for r in appr:
        if r["label"] == APPROVE and r["label_roles"] is not None:
            got = r["approved_roles"]
            if got is None or not set(got) <= set(r["label_roles"]):
                role_over += 1
    return {
        "n": n, "labels": lab, "verdicts": ver,
        "known_bad": sum(1 for r in rows if r["known_bad"]),
        "evidence_coverage": _ratio(sum(1 for r in rows if r["has_evidence"]), n),
        "approve": {"predicted": len(appr), "tp": tp_a, "precision": _ratio(tp_a, len(appr)),
                    "recall": _ratio(tp_a, lab[APPROVE]),
                    # approves the label calls WAIT but sets/adjudications.json shows to be label defects
                    "label_defects": adj_ok, "precision_adjudicated": _ratio(tp_a + adj_ok, len(appr))},
        "decline": {"predicted": len(decl), "tp": tp_d, "precision": _ratio(tp_d, len(decl)),
                    "recall": _ratio(tp_d, lab[DECLINE])},
        # Must-be-zero safety counts:
        "false_approve": sum(1 for r in appr if r["label"] == DECLINE or r["known_bad"]),
        "approve_on_known_bad": sum(1 for r in appr if r["known_bad"]),
        "protection_violations": sum(1 for r in appr if r["violations"]),
        # Reported, not zero-gated (a WAIT label means "not enough evidence", not "wrong"):
        "over_approve_vs_wait": sum(1 for r in appr if r["label"] == WAIT and not r["known_bad"]),
        "role_over_approve": role_over,
        "false_decline": sum(1 for r in decl if r["label"] == APPROVE),
        "unknown": ver[UNKNOWN], "errors": sum(1 for r in rows if r["error"]),
        "judged": n - ver[UNKNOWN],
    }


def agreement(rows: list[dict[str, Any]], cap: int | None = None, *,
              set_name: str | None = None, authoritative: dict[str, str] | None = None) -> dict[str, Any]:
    """Replay agreement of a verifier with the labels over the WHOLE set.

    ``binary`` asks the safety question - would it act (APPROVE) or not - and an item the verifier
    never judged (UNKNOWN) is a disagreement, so full coverage is part of 100 %. ``exact`` compares
    APPROVE / DECLINE / WAIT. For merges the labels are m1's queue classes, the m1 re-check and core's
    409 refusals, so this is the self-serve precondition row: binary 100 % with an empty list.
    """
    n = len(rows)
    bin_dis = [r for r in rows if r["verdict"] == UNKNOWN or (r["verdict"] == APPROVE) != (r["label"] == APPROVE)]
    exact_dis = [r for r in rows if r["verdict"] != r["label"]]

    def brief(r: dict[str, Any]) -> dict[str, Any]:
        return {"id": r["id"], "label": r["label"], "label_source": r["label_source"],
                "verdict": r["verdict"], "reasons": r["reasons"][:3]}

    # Only an AUTHORITATIVE set may issue the gate (default: nothing may, so a forgotten manifest entry
    # fails closed); a sensitivity variant reports the same agreement numbers and no gate.
    gate_set = (authoritative or {}).get(base_set(set_name or "")) == set_name
    return {"n": n, "judged": sum(1 for r in rows if r["verdict"] != UNKNOWN),
            "binary": _ratio(n - len(bin_dis), n), "exact": _ratio(n - len(exact_dis), n),
            "binary_disagreements": len(bin_dis), "exact_disagreements": len(exact_dis),
            "set": set_name, "gate_set": gate_set,
            "precondition_met": gate_set and n > 0 and not bin_dis,
            "binary_disagreement_list": [brief(r) for r in (bin_dis if cap is None else bin_dis[:cap])]}


def score(rows: list[dict[str, Any]], set_name: str | None = None,
          authoritative: dict[str, str] | None = None) -> dict[str, Any]:
    by_seg = {s: metrics([r for r in rows if r["segment"] == s]) for s in SEGMENTS_ORDER
              if any(r["segment"] == s for r in rows)}
    by_strength = {s: metrics([r for r in rows if r["label_strength"] == s]) for s in STRENGTHS
                   if any(r["label_strength"] == s for r in rows)}
    overall = metrics(rows)
    violations: dict[str, int] = {}
    for r in rows:
        for v in r["violations"]:
            key = v.split(":")[0]
            violations[key] = violations.get(key, 0) + 1
    return {"overall": overall, "by_segment": by_seg, "by_label_strength": by_strength,
            "agreement": agreement(rows, cap=None if base_set(set_name or "") == "merges" else 50,
                                   set_name=set_name, authoritative=authoritative),
            "violation_kinds": dict(sorted(violations.items(), key=lambda kv: -kv[1])),
            # zero rows examined is never clean, and neither is a run that judged nothing
            "clean": overall["n"] > 0 and overall["judged"] > 0
                     and all(overall[k] == 0 for k in MUST_BE_ZERO)}


def kill_switch_on(path: str = KILL_SWITCH) -> bool:
    return os.path.exists(path)


def run(specs: list[str], out_dir: str | Path, sets_dir: Path | str = SETS_DIR,
        recorded: list[tuple[str, str, str]] | None = None, run_id: str | None = None) -> dict[str, Any]:
    """Replay every verifier spec (+ recorded logs as (name, set, path)) and write the run files."""
    run_id = run_id or time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    cache: dict[str, list[dict[str, Any]]] = {}
    adj = load_adjudications(sets_dir)
    auth = authoritative_sets(sets_dir)
    results = []
    jobs: list[tuple[str, str, Callable[[dict[str, Any]], Verdict], str]] = []
    for spec in specs:
        name, set_name, fn = load_verifier(spec)
        jobs.append((name, set_name, fn, REGISTRY.get(spec, {}).get("kind", "external")))
    for name, set_name, path in recorded or []:
        jobs.append((name, set_name, load_recorded(path), "recorded-log"))
    # A recorded log (verdicts that do not read evidence) is also scored against every committed
    # label variant of its set; evidence-reading verifiers run on the base set only, because a
    # variant may carry a different evidence shape.
    jobs = [(n, v, fn, k) for n, base, fn, k in jobs
            for v in (set_variants(base, sets_dir) if k == "recorded-log" else [base])]
    with open(out / "verdicts.jsonl", "w", encoding="utf-8") as audit:
        for name, set_name, fn, kind in jobs:
            items = cache.setdefault(set_name, load_set(set_name, sets_dir))
            rows = replay(items, fn, adj)
            for r in rows:  # the audit row: every verdict with its evidence hash
                audit.write(json.dumps({"run_id": run_id, "verifier": name, "set": set_name, **r},
                                       ensure_ascii=False) + "\n")
            results.append({"verifier": name, "set": set_name, "kind": kind, **score(rows, set_name, auth)})
    summary = {"run_id": run_id, "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "shadow": True, "sets": {s: len(v) for s, v in cache.items()}, "results": results}
    (out / "metrics.json").write_text(json.dumps(summary, indent=1, ensure_ascii=False))
    from .report import board_json, board_line, to_markdown
    (out / "report.md").write_text(to_markdown(summary))
    (out / "board.txt").write_text(board_line(summary) + "\n")
    (out / "board.json").write_text(json.dumps(board_json(summary), indent=1))
    return summary
