"""Markdown report + one-line board summary for a verifier-eval run."""

from __future__ import annotations

from typing import Any


def _p(x: float | None) -> str:
    return "-" if x is None else f"{x:.3f}"


def _seg_row(seg: str, m: dict[str, Any]) -> str:
    a, d = m["approve"], m["decline"]
    return (f"| {seg} | {m['n']} | {m['labels']['APPROVE']}/{m['labels']['DECLINE']}/{m['labels']['WAIT']} "
            f"| {m['known_bad']} | {a['predicted']} | {_p(a['precision'])} | {_p(a['recall'])} "
            f"| **{m['false_approve']}** | **{m['protection_violations']}** | {m['over_approve_vs_wait']} "
            f"| {m['role_over_approve']} | {d['predicted']} | {_p(d['precision'])} | {_p(d['recall'])} "
            f"| {m['false_decline']} | {m['unknown']} | {_p(m['evidence_coverage'])} |")


HEADER = ("| class | n | labels A/D/W | known-bad | approve | approve P | approve R | false-approve | "
          "guard violations | approve on WAIT | role over-approve | decline | decline P | decline R | "
          "false-decline | UNKNOWN | evidence |\n" + "|---" * 17 + "|")


def to_markdown(summary: dict[str, Any]) -> str:
    out = [f"# Verifier eval {summary['run_id']} (shadow; nothing written to Muso)", "",
           f"Generated {summary['generated_at']}. Set sizes: "
           + ", ".join(f"{k} {v}" for k, v in summary["sets"].items()) + ".", "",
           "Must be 0 before a verifier is put to the captain: **false-approve** (approved a DECLINE-labelled "
           "or known-bad item), **approve on known-bad**, **guard violations** (an approve that fails the account "
           "gate / same-run Spotify+Tidal id anchor / big-common-flagged guard / UNKNOWN-never-approves). "
           "Classes are listed paid first.", ""]
    for r in summary["results"]:
        o = r["overall"]
        flag = "CLEAN" if r["clean"] else "NOT CLEAN"
        out += [f"## {r['verifier']} ({r['set']}, {r['kind']}) — {flag}", "", HEADER]
        for seg, m in r["by_segment"].items():
            out.append(_seg_row(seg, m))
        out.append(_seg_row("**all**", o))
        out += ["", "By label strength (how much to trust the label):", "", HEADER]
        for s, m in r["by_label_strength"].items():
            out.append(_seg_row(s, m))
        if any(x["approve"]["label_defects"] for x in r["by_segment"].values()):
            out += ["", "Approve precision after adjudicated label defects (sets/adjudications.json): "
                    + ", ".join(f"{seg} {_p(m['approve']['precision_adjudicated'])}"
                                for seg, m in r["by_segment"].items())]
        ag = r["agreement"]
        out += ["", f"Replay agreement with the labels: binary (act / not act, UNKNOWN = disagree) "
                f"{_p(ag['binary'])} ({ag['binary_disagreements']} disagreements), exact {_p(ag['exact'])}; "
                f"judged {ag['judged']}/{ag['n']}"
                + (" - **self-serve precondition MET**" if ag["precondition_met"] else "")
                + (" - sensitivity variant: no readiness gate" if r["set"].split("@", 1)[0] == "merges"
                   and not ag["gate_set"] else "")]
        if r["set"].startswith("merges") and ag["binary_disagreement_list"] and ag["binary_disagreements"] <= 20:
            out += ["", "Binary disagreements: " + "; ".join(
                f"`{x['id']}` label {x['label']} ({x['label_source']}) vs {x['verdict']}"
                for x in ag["binary_disagreement_list"])]
        if r["violation_kinds"]:
            out += ["", "Guard violation kinds: " + ", ".join(f"`{k}` {v}" for k, v in r["violation_kinds"].items())]
        out.append("")
    return "\n".join(out)


def board_json(summary: dict[str, Any]) -> dict[str, Any]:
    """Machine-readable per-verifier P/R/FA (paid first) for the l1 board's build: line."""
    out = []
    for r in summary["results"]:
        segs = {}
        for seg, m in list(r["by_segment"].items()) + [("all", r["overall"])]:
            a, d = m["approve"], m["decline"]
            segs[seg] = {"n": m["n"], "approve": a["predicted"], "approve_precision": a["precision"],
                         "approve_precision_adjudicated": a["precision_adjudicated"],
                         "approve_recall": a["recall"], "false_approve": m["false_approve"],
                         "approve_on_known_bad": m["approve_on_known_bad"],
                         "guard_violations": m["protection_violations"], "decline": d["predicted"],
                         "decline_precision": d["precision"], "decline_recall": d["recall"],
                         "false_decline": m["false_decline"], "unknown": m["unknown"],
                         "evidence_coverage": m["evidence_coverage"]}
        out.append({"verifier": r["verifier"], "set": r["set"], "kind": r["kind"], "clean": r["clean"],
                    "segments": segs, "agreement": r["agreement"]})
    return {"run_id": summary["run_id"], "generated_at": summary["generated_at"], "shadow": True,
            "sets": summary["sets"], "verifiers": out}


def board_line(summary: dict[str, Any]) -> str:
    """One line for the l1 board: per reference/recorded verifier, paid first."""
    parts = []
    for r in summary["results"]:
        if r["kind"] == "control":
            ok = (not r["clean"])
            parts.append(f"{r['verifier']} {'catches' if ok else 'HARNESS-BROKEN'}")
            continue
        seg = r["by_segment"]
        bits = []
        segs = [s for s in ("paid", "free") if s in seg] or list(seg)
        for s in segs:
            m = seg[s]
            bits.append(f"{s} n={m['n']} A {m['approve']['predicted']} P={_p(m['approve']['precision'])} "
                        f"R={_p(m['approve']['recall'])} FA={m['false_approve']} GV={m['protection_violations']} "
                        f"D {m['decline']['predicted']} P={_p(m['decline']['precision'])}")
        tail = ""
        name = r["verifier"] + ("" if "@" not in r["set"] else "@" + r["set"].split("@", 1)[1])
        if r["set"].split("@", 1)[0] == "merges":
            ag = r["agreement"]
            tail = (f" agree={ag['n'] - ag['binary_disagreements']}/{ag['n']}"
                    + (" PRECONDITION-MET" if ag["precondition_met"]
                       else (" no-gate" if not ag["gate_set"] else "")))
        parts.append(f"{name} [{'clean' if r['clean'] else 'NOT CLEAN'}] " + " / ".join(bits) + tail)
    return f"eval: {summary['run_id']} shadow | " + " | ".join(parts)
