#!/usr/bin/env python3
"""The fix loop: one register row per SHAPE, and a re-measurement that says whether a fix worked.

The register is `policies/caroline-shapes.json`. It is keyed by the classifier's shape ids
(`rules.SHAPE_IDS`) and it holds, per shape, the decision about what KIND of fix the shape gets
and where that fix stands. It never holds a conversation: the loop's unit is the shape, and its
output is a table of shapes with counts. A list of individual threads would be a queue of one-off
fixes, which is the design this replaces.

The loop, per shape:
  1. classify   — `rules.classify`, the same reader the monitor counts with
  2. record     — the register row + the per-tick reading (durable, so a shape is counted again,
                  not discovered again)
  3. decide     — `fix_type`: rule | tool | copy | person | refusal (| none for residual buckets)
  4. automate   — only rule and tool rows may carry automation; copy ships as copy
  5. re-measure — `remeasure`: the shape's own rate before and after `shipped_at`, against every
                  other shape as the control. A fix that does not move its own shape did not work.
"""
import calendar
import json
import os
import re
import time

from . import commitments, metrics, rules

REGISTER_PATH = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), "policies", "caroline-shapes.json")

FIX_TYPES = ("rule", "tool", "copy", "person", "refusal", "none")
AUTOMATION_FIX_TYPES = ("rule", "tool")
STATUSES = ("open", "in_progress", "shipped", "verified", "did_not_work", "not_planned")
# Residual buckets are not shapes anybody can fix: their SIZE is the signal that a shape is
# missing from the classifier. Only these may carry fix_type "none".
RESIDUAL_SHAPES = ("other", "product_question", "thanks_empty")
# The four things Caroline never does. Each must be registered as a refusal with a reason and a
# way back, never as a hand-off and never as something automation answers on substance.
REQUIRED_EXEMPTIONS = ("legal_position", "provenance", "fraud_label", "date_promise")
ALL_SHAPES = "*"

_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
# Anything that looks like an Intercom conversation id or an inbox link. The register is about
# shapes; a thread reference in it is the wrong design showing up.
_THREAD_REF = re.compile(r"\b\d{13,}\b|inbox/conversation/|/conversations/\d")


class RegisterError(ValueError):
    pass


def load_register(path=None):
    path = path or REGISTER_PATH
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        raise RegisterError(f"cannot read the shape register {path}: {e}") from e


def parse_day(value):
    """'YYYY-MM-DD' (UTC midnight) -> epoch seconds."""
    return calendar.timegm(time.strptime(value, "%Y-%m-%d"))


def _nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def validate(register, baseline=None):
    """Every structural rule of the register. Returns a list of error strings (empty = clean)."""
    errors = []
    if register.get("rules_version") != rules.RULES_VERSION:
        errors.append(
            f"rules_version {register.get('rules_version')!r} != classifier {rules.RULES_VERSION!r}: "
            "the rules changed, so re-read every row against the new shapes and bump it")
    raw = json.dumps(register)
    if _THREAD_REF.search(raw):
        errors.append("the register names a conversation (id or inbox link): it records shapes, never threads")
    shapes = register.get("shapes") or {}
    for missing in [s for s in rules.SHAPE_IDS if s not in shapes]:
        errors.append(f"shape {missing}: no register row (every classifier shape needs a decision)")
    for unknown in [s for s in shapes if s not in rules.SHAPE_IDS]:
        errors.append(f"shape {unknown}: not a classifier shape (rules.SHAPES is the only definition)")
    for sid, row in sorted(shapes.items()):
        errors.extend(f"shape {sid}: {e}" for e in _validate_row(sid, row))
    exemptions = register.get("exemptions") or {}
    for need in REQUIRED_EXEMPTIONS:
        ex = exemptions.get(need)
        if not isinstance(ex, dict):
            errors.append(f"exemption {need}: missing (Caroline never does this; it must be registered)")
            continue
        for field in ("never", "reason", "reapply_path", "enforced_by", "measured_by"):
            if not _nonempty(ex.get(field)):
                errors.append(f"exemption {need}: `{field}` is required")
        for sid in ex.get("shapes") or []:
            if sid not in rules.SHAPE_IDS:
                errors.append(f"exemption {need}: unknown shape {sid}")
            elif need not in ((shapes.get(sid) or {}).get("exemptions") or []):
                errors.append(f"exemption {need}: shape {sid} does not list it back")
        errors.extend(f"exemption {need}: {e}" for e in _validate_ship(ex))
    for sid, row in shapes.items():
        for ex_id in (row or {}).get("exemptions") or []:
            if ex_id not in exemptions:
                errors.append(f"shape {sid}: unknown exemption {ex_id}")
            elif sid not in (exemptions[ex_id].get("shapes") or []):
                errors.append(f"shape {sid}: exemption {ex_id} does not list it back")
    for name, row in sorted((register.get("global_fixes") or {}).items()):
        errors.extend(f"global fix {name}: {e}" for e in _validate_global(row))
    errors.extend(_validate_ratchets(register, baseline))
    cap = ((register.get("monitor") or {}).get("fix_loop") or {}).get("person_share_max")
    if not isinstance(cap, (int, float)) or not (0 < cap <= 0.10):
        errors.append("monitor.fix_loop.person_share_max must be a share in (0, 0.10]: "
                      "'needs a person' has to stay rare")
    elif baseline is not None:
        share, measured = person_share(register, baseline)
        if not measured:
            errors.append("person share cannot be measured: the baseline has no per-shape counts")
        elif share > cap:
            errors.append(
                f"'needs a person' shapes are {share:.1%} of baseline threads, over the "
                f"{cap:.0%} cap: a person is the rare answer, so re-decide a row or argue the cap")
    errors.extend(commitments.validate(register, rules.SHAPE_IDS))
    return errors


def _validate_global(row):
    """A fix that cuts across every shape (a guard rule, a routing change). Same discipline as a
    shape row, measured over all shapes at once."""
    if not isinstance(row, dict):
        return ["row must be an object"]
    errors = []
    if row.get("fix_type") not in ("rule", "tool", "copy"):
        errors.append("fix_type must be rule, tool or copy")
    if row.get("status") not in STATUSES:
        errors.append(f"status {row.get('status')!r} is not one of {', '.join(STATUSES)}")
    for field in ("why", "fix"):
        if not _nonempty(row.get(field)):
            errors.append(f"`{field}` is required")
    if row.get("metric") not in metrics.OUTCOME_CLASSES and row.get("metric") not in SHAPE_EXTRAS:
        errors.append(f"metric {row.get('metric')!r} is not an outcome class the monitor measures")
    errors.extend(_validate_ship(row))
    return errors


def _validate_ratchets(register, baseline):
    """The two absolute page lines may only come DOWN from the recorded baseline. Raising one is
    how a monitor is taught to stop firing."""
    if baseline is None:
        return []
    weeks = baseline.get("matured_weeks") or []
    if not weeks:
        return ["the baseline has no matured week, so the page ceilings cannot be checked"]
    page = (register.get("monitor") or {}).get("page") or {}
    errors = []
    for key, base in (("headline_ceiling_per_week", weeks[0]["headline"]),
                      ("date_promise_max_per_week", weeks[0]["extra"]["date_promise"])):
        value = page.get(key)
        if not isinstance(value, (int, float)):
            errors.append(f"monitor.page.{key} is required (baseline {base})")
        elif value > base:
            errors.append(f"monitor.page.{key} is {value}, above the baseline {base}: it may only come down")
    return errors


def _validate_ship(row):
    errors = []
    shipped = row.get("shipped_at")
    if shipped is not None and not (isinstance(shipped, str) and _DATE.match(shipped)):
        errors.append("`shipped_at` must be null or YYYY-MM-DD (UTC)")
    status = row.get("status")
    if status in ("shipped", "verified", "did_not_work") and not shipped:
        errors.append(f"status {status} needs `shipped_at`: without the date nothing can be re-measured")
    if status in ("shipped", "verified", "did_not_work") and not _nonempty(row.get("ref")):
        errors.append(f"status {status} needs `ref` (the PR or ruling that shipped it)")
    if shipped and status in ("open", "in_progress", "not_planned"):
        errors.append(f"`shipped_at` is set but status is {status}")
    return errors


def _validate_row(sid, row):
    if not isinstance(row, dict):
        return ["row must be an object"]
    errors = []
    fix_type, status = row.get("fix_type"), row.get("status")
    if fix_type not in FIX_TYPES:
        errors.append(f"fix_type {fix_type!r} is not one of {', '.join(FIX_TYPES)}")
    if status not in STATUSES:
        errors.append(f"status {status!r} is not one of {', '.join(STATUSES)}")
    if not _nonempty(row.get("why")):
        errors.append("`why` is required: one line on what fails for this shape")
    if fix_type == "none":
        if sid not in RESIDUAL_SHAPES:
            errors.append("fix_type none is only for residual buckets; decide rule, tool, copy, person or refusal")
        if status != "not_planned":
            errors.append("fix_type none must carry status not_planned")
    elif not _nonempty(row.get("fix")):
        errors.append("`fix` is required: what the fix is, in one line")
    if fix_type == "person" and not _nonempty(row.get("person_reason")):
        errors.append("fix_type person needs `person_reason`: name why a person is genuinely needed")
    if fix_type == "refusal":
        refusal = row.get("refusal") or {}
        if not (_nonempty(refusal.get("reason")) and _nonempty(refusal.get("reapply_path"))):
            errors.append("fix_type refusal needs `refusal.reason` and `refusal.reapply_path`")
    if row.get("automation") and fix_type not in AUTOMATION_FIX_TYPES:
        errors.append(f"`automation` on a {fix_type} row: only rule and tool shapes become automation")
    metric = row.get("metric", metrics.HEADLINE)
    if metric not in metrics.OUTCOME_CLASSES and metric not in SHAPE_EXTRAS:
        errors.append(f"metric {metric!r} is not an outcome class the monitor measures")
    errors.extend(_validate_ship(row))
    return errors


SHAPE_EXTRAS = ("date_promise", "guard_blocked")


def person_share(register, baseline):
    """(share of baseline threads in fix_type person shapes, measured?)."""
    counts = (baseline or {}).get("shape_threads") or {}
    total = sum(counts.values())
    if not total:
        return 0.0, False
    person = sum(n for sid, n in counts.items()
                 if ((register.get("shapes") or {}).get(sid) or {}).get("fix_type") == "person")
    return person / total, True


def _shape_metric(measured, shape, metric):
    """(count, threads) of a metric inside one shape, or over every shape for ALL_SHAPES."""
    rows = measured["shapes"]
    if shape == ALL_SHAPES:
        picked = list(rows.values())
    else:
        picked = [rows[shape]] if shape in rows else []
    return (sum(r.get(metric, 0) for r in picked), sum(r["threads"] for r in picked))


def _others_metric(measured, shape, metric):
    picked = [r for sid, r in measured["shapes"].items() if sid != shape]
    return (sum(r.get(metric, 0) for r in picked), sum(r["threads"] for r in picked))


def _rate(pair):
    count, threads = pair
    return count / threads if threads else None


def remeasure(facts, shape, metric, shipped_at, now, cfg, oldest_fact=None):
    """Did the fix for `shape` move `metric`? Compared on RATE, with every other shape as control.

    before = the 7 days of threads that had fully matured before the fix shipped
    after  = the first 7 days of threads opened after it, once they have all matured

    Rate, not raw count, because volume is not in the fix's hands: a proof campaign triples a
    shape's threads in a week, and a raw count would call that a failed fix. The counts are
    reported next to the rates so the reader can see both.

    Verdicts: not_shipped, too_early, unmeasured, worked, fell_with_everything, did_not_work.
    `unmeasured` is never a pass: it means the window or the volume cannot support a verdict.
    """
    maturity = cfg.get("maturity_hours", 48)
    loop = cfg.get("fix_loop") or {}
    days = loop.get("window_days", 7)
    min_threads = loop.get("min_threads", 15)
    min_drop = loop.get("min_relative_drop", 0.30)
    margin = loop.get("min_margin_over_control", 0.15)
    out = {"shape": shape, "metric": metric, "shipped_at": shipped_at}
    if not shipped_at:
        out["verdict"] = "not_shipped"
        return out
    ship = parse_day(shipped_at)
    span, mature = days * metrics.DAY, maturity * metrics.HOUR
    b_start, b_end = ship - mature - span, ship - mature
    a_start, a_end = ship, ship + span
    out["windows"] = {"before": [b_start, b_end], "after": [a_start, a_end]}
    if now < a_end + mature:
        out["verdict"] = "too_early"
        out["ready_at"] = a_end + mature
        return out
    if oldest_fact is None:
        stamps = [f["created_at"] for f in facts]
        oldest_fact = min(stamps) if stamps else None
    if oldest_fact is None or oldest_fact > b_start + metrics.DAY:
        out["verdict"] = "unmeasured"
        out["reason"] = "the thread facts on hand do not reach back to the before-window"
        return out
    before = metrics.measure(facts, b_start, b_end, now, maturity)
    after = metrics.measure(facts, a_start, a_end, now, maturity)
    tb, ta = _shape_metric(before, shape, metric), _shape_metric(after, shape, metric)
    out["before"] = {"count": tb[0], "threads": tb[1], "rate": _round(_rate(tb))}
    out["after"] = {"count": ta[0], "threads": ta[1], "rate": _round(_rate(ta))}
    if tb[1] < min_threads or ta[1] < min_threads:
        out["verdict"] = "unmeasured"
        out["reason"] = f"fewer than {min_threads} threads of this shape in a window"
        return out
    rb, ra = _rate(tb), _rate(ta)
    if not rb:
        out["verdict"] = "unmeasured"
        out["reason"] = "the metric was already zero before the fix"
        return out
    drop = (rb - ra) / rb
    out["relative_drop"] = round(drop, 4)
    control_drop = None
    if shape != ALL_SHAPES:
        cb, ca = _others_metric(before, shape, metric), _others_metric(after, shape, metric)
        out["control_before"] = {"count": cb[0], "threads": cb[1], "rate": _round(_rate(cb))}
        out["control_after"] = {"count": ca[0], "threads": ca[1], "rate": _round(_rate(ca))}
        if _rate(cb):
            control_drop = (_rate(cb) - _rate(ca)) / _rate(cb)
            out["control_relative_drop"] = round(control_drop, 4)
    if drop < min_drop:
        out["verdict"] = "did_not_work"
    elif control_drop is not None and drop - control_drop < margin:
        out["verdict"] = "fell_with_everything"
    else:
        out["verdict"] = "worked"
        if shape != ALL_SHAPES and control_drop is None:
            out["note"] = "no control: the other shapes had none of this metric"
    return out


def _round(value):
    return None if value is None else round(value, 4)


DECIDED = ("worked", "did_not_work", "fell_with_everything")


def shape_precision(calibration, shape):
    """(precision, labels) the hand labels gave this shape, or (None, 0) if it was never labelled."""
    row = (((calibration or {}).get("classifier") or {}).get("shapes") or {}).get(shape) or {}
    return row.get("precision"), int(row.get("labelled") or 0)


def remeasure_all(facts, register, now, oldest_fact=None, calibration=None):
    """A verdict for every row that has shipped: shapes, then global fixes, then exemptions.

    A shape the rules pick wrongly more often than not cannot prove anything about its own fix:
    half of what was counted is some other shape. Its verdict is `unmeasured`, with the reason,
    until the rule is tightened and re-labelled. The before and after counts stay in the row.
    """
    cfg = register.get("monitor") or {}
    floor = float((cfg.get("fix_loop") or {}).get("min_shape_precision", 0.5))
    out = []
    for sid in rules.SHAPE_IDS:
        row = (register.get("shapes") or {}).get(sid) or {}
        if row.get("shipped_at"):
            result = remeasure(facts, sid, row.get("metric", metrics.HEADLINE), row["shipped_at"],
                               now, cfg, oldest_fact)
            precision, labelled = shape_precision(calibration, sid)
            if precision is not None:
                result["shape_precision"] = {"precision": precision, "labelled": labelled}
                if precision < floor and result["verdict"] in DECIDED:
                    result["measured_as"] = result["verdict"]
                    result["verdict"] = "unmeasured"
                    result["reason"] = (f"the rules pick this shape correctly {precision:.0%} of the time by hand "
                                        f"labels ({labelled} labelled), below the {floor:.0%} needed for its count "
                                        "to prove a fix. Tighten the rule and re-label first")
            result["status"] = row.get("status")
            out.append(result)
    for group, label in (("global_fixes", "global_fix"), ("exemptions", "exemption")):
        for name, row in sorted((register.get(group) or {}).items()):
            if row.get("shipped_at") and row.get("metric"):
                result = remeasure(facts, ALL_SHAPES, row["metric"], row["shipped_at"], now, cfg, oldest_fact)
                result[label] = name
                result["status"] = row.get("status")
                out.append(result)
    return out


def verdict_name(verdict):
    return verdict.get("exemption") or verdict.get("global_fix") or verdict["shape"]


def shape_table(register, week, previous=None, calibration=None):
    """The loop's output: one row per shape, biggest contributor to the headline first."""
    shapes = register.get("shapes") or {}
    rows = []
    for sid in rules.SHAPE_IDS:
        now_row = week["shapes"].get(sid) or {}
        prev_row = (previous or {}).get("shapes", {}).get(sid) or {}
        reg = shapes.get(sid) or {}
        threads = now_row.get("threads", 0)
        rows.append({
            "shape": sid,
            "title": rules.SHAPE_BY_ID[sid].title,
            "threads": threads,
            "headline": now_row.get(metrics.HEADLINE, 0),
            "headline_prev": prev_row.get(metrics.HEADLINE, 0) if previous else None,
            "headline_rate": round(now_row.get(metrics.HEADLINE, 0) / threads, 4) if threads else None,
            "resolved": now_row.get("answered", 0),
            "precision": shape_precision(calibration, sid)[0],
            "fix_type": reg.get("fix_type"),
            "status": reg.get("status"),
            "owner": reg.get("owner"),
            "shipped_at": reg.get("shipped_at"),
        })
    rows.sort(key=lambda r: (-r["headline"], -r["threads"], r["shape"]))
    return rows


def residual_share(week):
    """Share of the cohort the classifier could not name. Growth here means a shape is missing."""
    total = week["threads"]
    residual = sum((week["shapes"].get(s) or {}).get("threads", 0) for s in ("other", "product_question"))
    return (residual / total) if total else None
