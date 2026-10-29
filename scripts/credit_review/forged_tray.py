"""jan-forged-bN.json (doc-verify fraud-deny tray) -> fable-decider executor trays.

Fable [key=l11-registry-fraud-close] + r5 on #1470 (doc-verify -> t01b 074):
  * the ONLY input acted on is each row's `executable` flag (doc-verify sets it: ruling confirm AND a positive
    signal pair AND a unique ruling id); every other row is reported, never closed;
  * if the rulings file parses to ZERO rulings while jan-forged rows are present, the WHOLE batch is refused and
    reported - never 'nothing confirmed, carry on';
  * a ruling counts only as a complete standalone line `ruling: forged-<sha8> confirm|not`, outside any fenced
    code block (the same grammar as docverify.tray.parse_rulings: case-insensitive, flexible spaces/tabs);
  * one request named by several confirmed forged documents is ONE tray row: the lowest ruling id is its
    executing ruling; EVERY contributing document (ruling, proof, intake, signal pair, outcome id) is kept in the
    structured `contributors` audit field, and evidence is never truncated (an overlong one refuses) (QA #1480);
  * an executable row the rulings file does not CONFIRM (missing or 'not') is a contradiction: whole batch refused;
  * subject=claim rows wait for the claim route (reported, not closed here);
  * a request no longer unverified / user_verification_needed is skipped (not open).
The output trays still go through every executor and wrapper guard (held / watchlisted / big stay refused and go to
the human tray with their forged-<sha8> ruling attached).
"""
from __future__ import annotations

import json
import re
from typing import Any, Callable, Iterable

#: Byte-for-byte the grammar of docverify.tray._RULING (hydra #1470 @979a9a15): full line, case-insensitive,
#: flexible spaces/tabs. Parity is pinned by test_parser_parity_with_upstream_grammar (QA #1480).
RULING_LINE = re.compile(r"ruling:[ \t]*(forged-[0-9a-f]{8})[ \t]+(confirm|not)[ \t]*", re.I)
FENCE = re.compile(r"^[ \t]*(```|~~~)")
OPEN = ("unverified", "user_verification_needed")


class BatchRefused(Exception):
    """The whole jan-forged batch is refused; the message is the report line."""


def parse_rulings(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    fenced = False
    for line in (text or "").replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if FENCE.match(line):
            fenced = not fenced
            continue
        m = None if fenced else RULING_LINE.fullmatch(line)
        if m:
            out[m.group(1).lower()] = m.group(2).lower()
    return out


def _signal_families(sigs: Any) -> str:
    if isinstance(sigs, dict):
        return ", ".join(sorted(sigs))
    return ", ".join(sorted({str(e.get("family")) for e in sigs or [] if isinstance(e, dict) and e.get("family")}))


def build(doc: dict[str, Any], rulings_text: str | None,
          status_of: Callable[[Iterable[str]], dict[str, dict[str, Any]]]) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    """-> ({expected_status: tray doc}, report). status_of(ids) -> {request id lower: {status, user_id}}."""
    rows = doc.get("rows") if isinstance(doc, dict) else None
    if not isinstance(rows, list):
        raise BatchRefused("jan-forged file has no rows[] list")
    if rows and rulings_text is None:
        raise BatchRefused(f"{len(rows)} jan-forged rows but no rulings file given")
    rulings = parse_rulings(rulings_text or "")
    if rows and not rulings:
        raise BatchRefused(f"rulings file parses to ZERO rulings while {len(rows)} jan-forged rows are present")
    report: dict[str, Any] = {"rows": len(rows), "executable": 0, "not_executable": 0, "claim_waits": 0,
                              "not_open": 0, "requests": 0, "contradictions": []}
    picked: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for d in rows:
        if d.get("executable") is not True:
            report["not_executable"] += 1
            continue
        rid = str(d.get("ruling_id", "")).lower()
        if rulings.get(rid) != "confirm":
            report["contradictions"].append(f"{rid}: executable but the rulings file says {rulings.get(rid) or 'nothing'}")
            continue
        report["executable"] += 1
        if (d.get("subject") or "credit") == "claim":
            report["claim_waits"] += 1
            continue
        for q in d.get("requests") or []:
            picked.append((d, q))
    if report["contradictions"]:
        raise BatchRefused("executable rows not confirmed by the rulings file: " + "; ".join(report["contradictions"]))
    facts = status_of([q["request_id"] for _, q in picked]) if picked else {}
    # one row per request: several confirmed documents naming the same request aggregate, never duplicate
    by_req: dict[str, list[tuple[dict[str, Any], dict[str, Any]]]] = {}
    for d, q in picked:
        by_req.setdefault(str(q["request_id"]).lower(), []).append((d, q))
    trays: dict[str, dict[str, Any]] = {}
    for rid in sorted(by_req):
        hits = sorted(by_req[rid], key=lambda h: (str(h[0].get("ruling_id")).lower(), str(h[0].get("proof_id"))))
        users = {int(d["user_id"]) for d, _ in hits}
        if len(users) != 1:
            raise BatchRefused(f"request {rid} is named by forged documents of different users {sorted(users)}")
        f = facts.get(rid) or {}
        st = f.get("status")
        if st not in OPEN:
            report["not_open"] += 1
            continue
        d, q = hits[0]
        evidence = (f"forged document proof {d.get('proof_id')} (intake {d.get('intake_id')}); signal pair "
                    f"{', '.join(d.get('signal_ids') or [])}; families {_signal_families(d.get('fraud_signals'))}")
        # EVERY contributing document, structured, in the executor audit (never in truncatable text, QA #1480)
        contributors = [{"ruling_id": o.get("ruling_id"), "proof_id": o.get("proof_id"),
                         "intake_id": o.get("intake_id"), "signal_ids": o.get("signal_ids"),
                         "fraud_pair": o.get("fraud_pair"), "outcome_id": x.get("outcome_id")} for o, x in hits]
        if len(hits) > 1:
            evidence += f"; {len(hits) - 1} more confirmed forged document(s), listed in contributors"
            report["aggregated"] = report.get("aggregated", 0) + 1
        if len(evidence) > 600:
            raise BatchRefused(f"request {rid}: evidence of its executing document is {len(evidence)} chars (> 600); "
                               "refusing rather than truncating")
        outcomes = [x.get("outcome_id") for _, x in hits]
        t = trays.setdefault(st, {"action": "reject", "expected_status": st, "rows": [],
                                  "source": "doc-verify jan-forged (Fable l11-registry-fraud-close)"})
        t["rows"].append({"request_id": q["request_id"], "user_id": users.pop(), "ruling_id": d["ruling_id"],
                          "rule": "R-FRAUD-DOC", "evidence": evidence, "reason_code": "fraud_document",
                          "proof_id": d.get("proof_id"), "intake_id": d.get("intake_id"),
                          "fraud_pair": d.get("fraud_pair"), "signal_ids": d.get("signal_ids"),
                          "outcome_ids": outcomes, "contributors": contributors, "subject": "credit"})
        report["requests"] += 1
    return trays, report


def main(argv: list[str] | None = None) -> int:
    import argparse
    import sys
    from . import fable_executor as fx
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("forged_json")
    ap.add_argument("--rulings", required=True, help="Fable's rulings file (lines 'ruling: forged-<sha8> confirm|not')")
    ap.add_argument("--out-prefix", required=True)
    a = ap.parse_args(argv)
    doc = json.load(open(a.forged_json, encoding="utf-8"))
    text = open(a.rulings, encoding="utf-8").read()

    def status_of(ids):
        return {k: {"status": v.status, "user_id": v.user_id} for k, v in fx.fetch_facts(list(ids)).items()}
    try:
        trays, report = build(doc, text, status_of)
    except BatchRefused as exc:
        print(json.dumps({"refused": str(exc)}))
        return 3
    for st, t in trays.items():
        with open(f"{a.out_prefix}-{st}.json", "w", encoding="utf-8") as fh:
            json.dump(t, fh, indent=1)
    print(json.dumps({**report, "trays": {st: len(t["rows"]) for st, t in trays.items()}}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
