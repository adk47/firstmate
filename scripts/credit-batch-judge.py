#!/usr/bin/env python3
"""credit-batch-judge: run one outbound batch through b1's coded pre-layer and t01b's judge_batch (#1586).

  credit-batch-judge.py judge --items FILE --copy-ref REF    the batch's verdict row (#1586 signature_row, with the
                                                             coded stops folded in) as JSON on stdout. SHADOW: the
                                                             tick (h2) owns writing it and calling may_apply.
  credit-batch-judge.py eval --cases FILE --ledger PATH [--model-all]
                                                             the labelled set, one batch per `case` group; per body
                                                             the final verdict vs the expected one; exit 1 on a miss.
                                                             --model-all also sends every body to the model (coded
                                                             stops included) to score the model layer on its own.
                                                             --ledger is REQUIRED: eval calls never land in the
                                                             production llm_calls ledger.

FILE: JSONL, one object per rendered body: {user_id, body_html, facts, copy_ref?} (+ case, expected for eval).
The body goes to judge_batch exactly as rendered (judge_batch builds the ID-bound section); facts must be the
RENDERER's own per-message facts.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import OrderedDict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_review import batch_judge as bj  # noqa: E402
from credit_review import batch_judge_instructions as bi  # noqa: E402


def _items(path: str) -> list[dict]:
    out = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line.strip():
            d = json.loads(line)
            d["id"] = str(d.get("id", d["user_id"]))
            d["body"] = d.get("body") or d.get("body_html") or ""
            out.append(d)
    return out


def run_batch(items: list[dict], copy_ref: str, *, provider=None, model_all: bool = False) -> tuple[dict, dict]:
    """(signature row, coded stops). Coded stops never reach the model (unless model_all, for the eval) and any
    coded stop stops the batch."""
    # ONE id form everywhere (QA #1591): a numeric JSON id and its string must be the same body for the coded map,
    # the model's rows and stop_ids alike.
    items = [{**it, "id": str(it["id"])} for it in items]
    barred = bi.barred_phrases()
    coded = bi.coded_stops(items, barred)
    batch = bj.batch_sha([{"id": it["id"], "body": it["body"]} for it in items],
                         {it["id"]: it.get("facts") for it in items}, copy_ref, barred, bi.rules_doc())
    to_model = items if model_all else [it for it in items if it["id"] not in coded]
    if to_model:
        v = bj.judge_batch(bi.instructions(to_model, copy_ref, barred), batch=batch,
                           bodies=[{"id": it["id"], "body": it["body"]} for it in to_model], provider=provider)
    else:
        v = bj.BatchVerdict(batch_sha=batch, verdict="stop")
    if coded:
        v.verdict = "stop"
        v.reasons.append(f"coded_stop:{len(coded)}")
        known = {b.id for b in v.bodies}
        for bid, (code, ev) in coded.items():
            if bid not in known:
                v.bodies.append(bj.BodyVerdict(bid, "stop", code, ev))
        v.stop_ids = sorted(set(v.stop_ids) | set(coded))
    row = v.signature_row()
    row["coded_stops"] = {k: {"reason_code": c, "evidence": e} for k, (c, e) in coded.items()}
    row["instructions_version"] = bi.INSTRUCTIONS_VERSION
    return row, coded


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    j = sub.add_parser("judge")
    j.add_argument("--items", required=True)
    j.add_argument("--copy-ref", required=True)
    e = sub.add_parser("eval")
    e.add_argument("--cases", required=True)
    e.add_argument("--model-all", action="store_true")
    e.add_argument("--ledger", required=True, help="a scratch llm_calls ledger (never the production one)")
    a = ap.parse_args(argv)
    if a.cmd == "judge":
        row, _ = run_batch(_items(a.items), a.copy_ref)
        print(json.dumps(row, default=str))
        return 0
    from credit_trust.ledger import DEFAULT_PATH, Ledger
    from credit_trust.llm import Provider
    if Path(a.ledger).resolve() == Path(DEFAULT_PATH).resolve():
        ap.error("--ledger must not be the production ledger")
    provider = Provider(Ledger(a.ledger), ladder=("codex",), codex_model=bj.CODEX_MODEL,
                        codex_fallback_model=bj.CODEX_FALLBACK_MODEL)
    cases = _items(a.cases)
    if not cases:       # an empty case file must never print a green 0/0 bar (QA #1591)
        ap.error(f"{a.cases} holds no cases; refusing to report a score")
    groups: "OrderedDict[str, list[dict]]" = OrderedDict()
    for it in cases:
        groups.setdefault(it.get("case") or "default", []).append(it)
    rows, misses, model_ok = [], 0, 0
    for case, items in groups.items():
        row, coded = run_batch(items, items[0].get("copy_ref") or case, provider=provider)
        stop = set(row["stop_ids"])
        model_rows = {b["id"]: b for b in row["bodies"]}
        if a.model_all:
            mrow, _ = run_batch(items, items[0].get("copy_ref") or case, provider=provider, model_all=True)
            model_rows = {b["id"]: b for b in mrow["bodies"]}       # every body went to the model: its own rows
        for it in items:
            final = "STOP" if it["id"] in stop else "GO"       # judge_batch names every id on a batch-level stop
            mb = model_rows.get(it["id"]) or {}
            mv = "GO" if mb.get("verdict") == "pass" else "STOP"
            ok = final == it["expected"]
            misses += not ok
            model_ok += (mv == it["expected"])
            rows.append({"case": case, "user_id": it["user_id"], "expected": it["expected"],
                         "expected_reason": it.get("expected_reason"), "final": final,
                         "coded": (coded.get(it["id"]) or (None,))[0], "model_verdict": mb.get("verdict"),
                         "model_reason": mb.get("reason_code"), "ok": ok,
                         "evidence": str(mb.get("evidence_quote") or "")[:160]})
        rows.append({"batch": case, "verdict": row["verdict"], "reasons": row["reasons"], "model": row["model"],
                     "llm_call_id": row["llm_call_id"]})
    body_rows = [r for r in rows if "expected" in r]
    summary = {"cases": len(body_rows), "final_correct": len(body_rows) - misses,
               "model_layer_correct": model_ok if a.model_all else None,
               "stops_caught": sum(r["expected"] == "STOP" and r["final"] == "STOP" for r in body_rows),
               "stops_expected": sum(r["expected"] == "STOP" for r in body_rows),
               "clean_passed": sum(r["expected"] == "GO" and r["final"] == "GO" for r in body_rows),
               "clean_total": sum(r["expected"] == "GO" for r in body_rows)}
    print(json.dumps({"instructions_version": bi.INSTRUCTIONS_VERSION, "summary": summary, "rows": rows}, indent=1))
    return 1 if misses else 0


if __name__ == "__main__":
    sys.exit(main())
