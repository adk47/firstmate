#!/usr/bin/env python3
"""How wrong are the rules? Measured by hand labels, never assumed.

Two readers are calibrated, because the headline rests on both:

  * the SHAPE classifier  — a stratified random sample per predicted shape, labelled blind (the
    sheet does not show what the rules said). Gives per-shape precision with a 95% interval and
    a corrected estimate of each shape's true size.
  * the OUTCOME reader    — a random sample of threads the monitor counts in the headline
    ("she said a person is coming, nobody was assigned"), checked for whether she really said
    it; and a random sample of threads it counts as NOT a hand-off, checked for a promise the
    patterns missed.

`sample` writes a labelling sheet and its key. Both hold masked customer text, so they are
scratch files: they are never committed and are deleted when the labels are scored. `score`
writes `data/caroline-monitor/calibration.json`, which holds counts only.
"""
import json
import math
import random
import re
import time

from . import metrics, rules

SHEET_TEXT_CAP = 300
_SENTENCE = re.compile(r"(?<=[.!?])\s+")


def wilson(correct, n, z=1.96):
    """95% Wilson score interval for a proportion. (None, None) when nothing was sampled."""
    if not n:
        return (None, None)
    p = correct / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return (round(max(0.0, centre - half), 4), round(min(1.0, centre + half), 4))


def allocation(populations, big=30, medium=15, small=8):
    """How many to label per predicted shape: more where more threads ride on the answer."""
    ranked = sorted(populations.items(), key=lambda kv: -kv[1])
    plan = {}
    for i, (sid, n) in enumerate(ranked):
        want = big if i == 0 else medium if i < 6 else small
        plan[sid] = min(n, want)
    return plan


def _ask_text(thread):
    view = rules.ask_view(thread)
    text = view.text[:SHEET_TEXT_CAP]
    kind = "reply to our mail" if view.outbound else view.source_type
    files = " +file" if view.attachments else ""
    return f"[{kind}{files}] subj: {view.subject[:90]} | {text}"


def sample_shapes(threads, seed, plan=None):
    """(sheet rows, key rows, populations). The sheet has no predicted shape: the label is blind."""
    by_shape = {}
    for t in threads:
        by_shape.setdefault(rules.classify(t), []).append(t)
    populations = {sid: len(rows) for sid, rows in by_shape.items()}
    plan = plan or allocation(populations)
    rng = random.Random(seed)
    picked = []
    for sid in sorted(by_shape):
        rows = sorted(by_shape[sid], key=lambda t: str(t["id"]))
        picked += [(sid, t) for t in rng.sample(rows, min(plan.get(sid, 0), len(rows)))]
    rng.shuffle(picked)
    sheet = [{"n": i + 1, "ask": _ask_text(t)} for i, (_, t) in enumerate(picked)]
    key = [{"n": i + 1, "predicted": sid} for i, (sid, _) in enumerate(picked)]
    return sheet, key, populations


def _caroline_text(thread, only_matching):
    out = []
    for part in thread.get("parts") or []:
        if (part.get("at") != "admin" or str(part.get("aid")) != rules.CAROLINE_ADMIN_ID
                or not (part.get("body") or "").strip() or part.get("t") == "note"):
            continue
        for sentence in _SENTENCE.split(rules.norm(part["body"])):
            hit = bool(rules.PERSON_PROMISE.search(rules.PERSON_PROMISE_EXCLUDE.sub(" ", sentence)))
            if hit or not only_matching:
                out.append(sentence[:160])
    seen, unique = set(), []
    for s in out:
        if s not in seen:
            seen.add(s)
            unique.append(s)
    return " || ".join(unique)[:500]


def sample_outcomes(threads, facts, seed, now, per_arm=50):
    """Two arms: threads counted in the headline, and threads Caroline answered that are counted
    as no hand-off. Each row shows Caroline's own words; the label is y/n on one question."""
    by_id = {str(t["id"]): t for t in threads}
    arms = {"headline": [], "no_handoff": []}
    for fact in facts:
        klass = metrics.outcome_class(metrics.state_at(fact["events"], now))
        if klass == metrics.HEADLINE:
            arms["headline"].append(fact["id"])
        elif klass in ("answered", "answered_awaiting", "queue_line", "refused"):
            arms["no_handoff"].append(fact["id"])
    rng = random.Random(seed)
    sheet, key = [], []
    populations = {arm: len(ids) for arm, ids in arms.items()}
    picked = []
    for arm in ("headline", "no_handoff"):
        ids = sorted(arms[arm])
        picked += [(arm, i) for i in rng.sample(ids, min(per_arm, len(ids)))]
    rng.shuffle(picked)
    for n, (arm, tid) in enumerate(picked, 1):
        text = _caroline_text(by_id[tid], only_matching=(arm == "headline"))
        sheet.append({"n": n, "question": "did Caroline tell the customer a person or the team will take this over or follow up? (y/n)",
                      "caroline": text})
        key.append({"n": n, "arm": arm})
    return sheet, key, populations


def read_labels(path):
    """`n<TAB or space>label` per line; anything after the label is a comment. # lines ignored."""
    labels = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            bits = line.split()
            labels[int(bits[0])] = bits[1]
    return labels


def score_shapes(key, labels, populations):
    """Per predicted shape: precision and interval. Per TRUE shape: the corrected size estimate
    (each stratum's labelled shares projected onto that stratum's population)."""
    strata = {}
    for row in key:
        label = labels.get(row["n"])
        if label is None:
            continue
        if label not in rules.SHAPE_IDS:
            raise ValueError(f"label {label!r} on row {row['n']} is not a shape id")
        strata.setdefault(row["predicted"], []).append(label)
    out, estimates, variances = {}, {}, {}
    labelled = correct_weighted = total_pop = 0
    for sid in rules.SHAPE_IDS:
        got = strata.get(sid) or []
        pop = populations.get(sid, 0)
        n = len(got)
        correct = sum(1 for g in got if g == sid)
        wrong = {}
        for g in got:
            if g != sid:
                wrong[g] = wrong.get(g, 0) + 1
        lo, hi = wilson(correct, n)
        out[sid] = {"population": pop, "labelled": n, "correct": correct,
                    "precision": round(correct / n, 4) if n else None, "ci95": [lo, hi],
                    "mistaken_for": dict(sorted(wrong.items(), key=lambda kv: -kv[1]))}
        labelled += n
        if n:
            total_pop += pop
            correct_weighted += pop * correct / n
            fpc = max(0.0, 1 - n / pop) if pop else 0.0
            for true in set(got):
                p = got.count(true) / n
                estimates[true] = estimates.get(true, 0.0) + pop * p
                variances[true] = variances.get(true, 0.0) + pop * pop * p * (1 - p) / n * fpc
    for sid in rules.SHAPE_IDS:
        out[sid]["estimated_true_threads"] = round(estimates.get(sid, 0.0))
        out[sid]["estimate_plus_minus"] = round(1.96 * math.sqrt(variances.get(sid, 0.0)))
    return {"shapes": out, "labelled": labelled,
            "weighted_accuracy": round(correct_weighted / total_pop, 4) if total_pop else None}


def score_outcomes(key, labels, populations):
    arms = {"headline": [], "no_handoff": []}
    for row in key:
        label = labels.get(row["n"])
        if label is None:
            continue
        if label not in ("y", "n"):
            raise ValueError(f"label {label!r} on row {row['n']} must be y or n")
        arms[row["arm"]].append(label)
    head, rest = arms["headline"], arms["no_handoff"]
    said = head.count("y")
    missed = rest.count("y")
    out = {
        "headline": {"population": populations.get("headline"), "labelled": len(head), "really_a_promise": said,
                     "precision": round(said / len(head), 4) if head else None,
                     "ci95": list(wilson(said, len(head)))},
        "no_handoff": {"population": populations.get("no_handoff"), "labelled": len(rest), "missed_promises": missed,
                       "miss_rate": round(missed / len(rest), 4) if rest else None,
                       "ci95": list(wilson(missed, len(rest)))},
    }
    if head and rest and populations.get("headline") and populations.get("no_handoff"):
        true_in_head = populations["headline"] * said / len(head)
        true_in_rest = populations["no_handoff"] * missed / len(rest)
        out["estimated_true_headline"] = round(true_in_head + true_in_rest)
        out["counted_headline"] = populations["headline"]
    return out


def write_jsonl(path, rows):
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def read_jsonl(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def calibration_record(shape_score, outcome_score, seed, window, rater):
    return {
        "_doc": "Hand-label calibration of the Caroline monitor's rules. Counts only. Written by "
                "`caroline-monitor.py calibrate score`; a rule change bumps RULES_VERSION and makes this stale.",
        "rules_version": rules.RULES_VERSION,
        "labelled_at_utc": time.strftime("%Y-%m-%d", time.gmtime()),
        "rater": rater,
        "seed": seed,
        "window": window,
        "classifier": shape_score,
        "outcome_reader": outcome_score,
    }
