"""One rule for merge keep conflicts, shared by every path that works merge tickets.

create_ticket (plugins/support-tools) files a merge request that overlaps an open one in
the same conversation but keeps a different profile / track as its own ticket, and tags
both `merge-keep-conflict` plus `merge-keep-conflict-with:<other id>`. A human reconciles
the pair by closing the ticket they reject and removing `merge-keep-conflict` from the one
they keep.

Held (never worked or messaged): a ticket that carries `merge-keep-conflict`, or one whose
OPEN sibling (named by either side's `merge-keep-conflict-with:` tag) still carries it. A
closed sibling never holds. A ticket tagged `merge-intake-stale` (create_ticket could not
write a follow-up's merge targets into its description) is held the same way, on its own,
until a human removes the tag.

A pair is active while either side is held by its own tag and open; a pair with no open
flagged side is resolved and is never reported again.

The same module also compares two merge intakes the way create_ticket does (same request
= they share a ref AND keep the same thing), for the TO DO dedupe.

CLI (close-merged-tickets.sh): `merge_keep_conflict.py unheld` reads JSONL ticket records
({task_id|id, tags: [names] | [{name}], status?}) on stdin and writes the unheld ones.
"""
from __future__ import annotations

import json
import sys

KEEP_CONFLICT_TAG = "merge-keep-conflict"
KEEP_CONFLICT_WITH = "merge-keep-conflict-with:"
INTAKE_STALE_TAG = "merge-intake-stale"
CLOSED_STATUS_TYPES = ("closed", "done")


def task_id(task: dict) -> str:
    return str(task.get("id") or task.get("task_id") or "").strip().lower()


def tag_names(task: dict) -> set[str]:
    return {str(t.get("name", "") if isinstance(t, dict) else t).strip().lower()
            for t in (task.get("tags") or [])}


def is_closed(task: dict) -> bool:
    status = task.get("status")
    if isinstance(status, dict):
        return str(status.get("type") or "").lower() in CLOSED_STATUS_TYPES
    return False


def siblings_named(task: dict) -> set[str]:
    return {t[len(KEEP_CONFLICT_WITH):] for t in tag_names(task) if t.startswith(KEEP_CONFLICT_WITH)} - {""}


def flagged(task: dict) -> bool:
    return KEEP_CONFLICT_TAG in tag_names(task)


def held_by_own_tag(task: dict) -> bool:
    """Held whatever its siblings say: it carries merge-keep-conflict or merge-intake-stale."""
    return bool({KEEP_CONFLICT_TAG, INTAKE_STALE_TAG} & tag_names(task))


def sibling_holds(sibling: dict) -> bool:
    """A sibling holds its pair only while it is open and still carries the tag."""
    return flagged(sibling) and not is_closed(sibling)


def analyse(tasks: list[dict]) -> tuple[set[str], dict[tuple[str, str], bool]]:
    """(ids held, {active pair: tagging complete}). A pair is complete when each side
    carries its `merge-keep-conflict-with:` tag naming the other; an inactive (resolved)
    pair is not returned."""
    by_id = {task_id(t): t for t in tasks}
    pairs = {tuple(sorted((tid, sib))) for tid, t in by_id.items() for sib in siblings_named(t)}
    held = {tid for tid, t in by_id.items() if held_by_own_tag(t)}
    active: dict[tuple[str, str], bool] = {}
    for a, b in pairs:
        ta, tb = by_id.get(a), by_id.get(b)
        holders = [x for x, t in ((a, ta), (b, tb)) if t is not None and sibling_holds(t)]
        if not holders:
            continue
        for x in (a, b):
            if x in by_id:
                held.add(x)
        active[(a, b)] = all(t is not None and f"{KEEP_CONFLICT_WITH}{other}" in tag_names(t)
                             for t, other in ((ta, b), (tb, a)))
    return held, active


def held_ids(tasks: list[dict]) -> set[str]:
    return analyse(tasks)[0]


def _lower(x) -> str:
    return str(x or "").lower()


def _all_refs(mi: dict) -> list[str]:
    refs = [mi.get("keep"), *(mi.get("others") or [])]
    for p in mi.get("pairs") or []:
        refs += [p.get("keep"), *(p.get("others") or [])]
    return [r for r in map(_lower, refs) if r]


def _targets(mi: dict) -> list[str]:
    anchor = None if mi.get("kind") == "track-merge" else _lower(mi.get("keep"))
    return [r for r in _all_refs(mi) if r != anchor]


def _track_keeps(mi: dict) -> dict[str, str]:
    keep_of: dict[str, str] = {}
    for p in mi.get("pairs") or []:
        keep = _lower(p.get("keep"))
        keep_of[keep] = keep
        for o in p.get("others") or []:
            keep_of[_lower(o)] = keep
    return keep_of


def same_merge_request(a: dict, b: dict) -> bool:
    """create_ticket's rule: the intakes share a ref and keep the same thing (for
    track-merge every track both name sits under the same kept track)."""
    refs_a, refs_b = set(_all_refs(a)), set(_all_refs(b))
    overlap = any(r in refs_b for r in _targets(a)) or any(r in refs_a for r in _targets(b))
    if not overlap:
        return False
    if a.get("kind") != "track-merge":
        return _lower(a.get("keep")) == _lower(b.get("keep"))
    keep_b = _track_keeps(b)
    return all(r not in keep_b or keep_b[r] == k for r, k in _track_keeps(a).items())


def merge_intake_of(description: str) -> dict | None:
    """details.merge_intake from a ticket description's ---ACTION-REQUEST--- block."""
    start, end = "---ACTION-REQUEST---", "---END-ACTION-REQUEST---"
    if not description or start not in description or end not in description:
        return None
    block = description.split(start, 1)[1].split(end, 1)[0].strip()
    try:
        ar = json.loads(block)
    except ValueError:
        try:
            ar = json.loads(block.replace("\\_", "_"))
        except ValueError:
            return None
    mi = ((ar or {}).get("details") or {}).get("merge_intake") if isinstance(ar, dict) else None
    return mi if isinstance(mi, dict) and isinstance(mi.get("others"), list) else None


def _unheld(lines) -> list[dict]:
    rows = [json.loads(line) for line in lines if line.strip()]
    held = held_ids(rows)
    return [r for r in rows if task_id(r) not in held]


if __name__ == "__main__":
    if sys.argv[1:] != ["unheld"]:
        sys.exit("usage: merge_keep_conflict.py unheld < tickets.jsonl")
    rows = _unheld(sys.stdin)
    for r in rows:
        r.pop("tags", None)
        r.pop("status", None)
        print(json.dumps(r))
