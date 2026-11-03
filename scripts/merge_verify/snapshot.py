"""Frozen facts from profile-merge-ops-m1's read-only pulls (2026-10-27 20:5xZ, the 235-ticket
re-read behind data/profile-merge-ops-m1/merge-states-1028.md), and the ids-only regression set
committed at scripts/merge_verify/sets/m1-1028.jsonl.gz.

`build(measure_dir, states_md)` reads m1's `.measure/` files (all_tickets.json, all_cat.jsonl,
all_claims.json, all_login.json, all_primary.json, all_pm.json, watchlist.json, ft.json,
ft_convinfo.json, d1_consolidate_dry.json) and returns one facts dict per ticket in the shape
rules.decide reads, plus m1's own state for that ticket. What m1 did not read stays None (paid
seats, claim screening flags, most same-name censuses), so a replay can never turn a missing read
into "no problem". Names are used only to compute the keep/duplicate name relation and are never
written: the committed set carries ids, counts, DSP artist ids and booleans only.
"""
from __future__ import annotations

import gzip
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable

from . import rules

SET_PATH = Path(__file__).resolve().parent / "sets" / "m1-1028.jsonl.gz"
STATE_ROW = re.compile(r"^\|\s*([0-9a-z]{9,12})\s*\|\s*([A-Za-z0-9-]+)\s*\|\s*[\d.]+\s*\|")
SAME_NAME = re.compile(r"another same-name profile \(([0-9a-f-]{36})\)")


def m1_states(md_text: str) -> dict[str, str]:
    """{ticket: m1 state} from the "Every ticket" table of merge-states-1028.md."""
    out: dict[str, str] = {}
    section = md_text.split("## Every ticket", 1)[-1]
    for line in section.splitlines():
        m = STATE_ROW.match(line)
        if m and m.group(2) != "state":
            out[m.group(1)] = m.group(2)
    return out


def _profile(p: dict | None) -> dict:
    if p is None:
        return {"found": False}
    raws = p.get("rawProfiles") or []
    spotify = {str(p["spotifyId"])} if p.get("spotifyId") else set()
    spotify |= {str(r.get("id")) for r in raws if (r.get("source") or "").lower() == "spotify" and r.get("id")}
    tidal = {str(x) for x in (p.get("tidalIds") or []) if x}
    tidal |= {str(r.get("id")) for r in raws if (r.get("source") or "").lower() == "tidal" and r.get("id")}
    names = [n for n in [p.get("name"), p.get("legalName"), *(p.get("knownAsNames") or []),
                         *[r.get("name") for r in raws]] if isinstance(n, str) and n.strip()]
    credits = p.get("creditCount")
    return {"found": True, "type": p.get("type"), "sub_type": p.get("subType"),
            "credits": credits if isinstance(credits, int) else None,
            "popularity": p.get("popularity") if isinstance(p.get("popularity"), (int, float)) else None,
            "spotify": sorted(spotify), "tidal": sorted(tidal), "names": names}


def build(measure_dir: str | Path, states_md: str | Path | None = None) -> list[dict[str, Any]]:
    d = Path(measure_dir)
    load = lambda name: json.loads((d / name).read_text())  # noqa: E731
    tickets = load("all_tickets.json")
    cat = {}
    for line in (d / "all_cat.jsonl").read_text().splitlines():
        if line.strip():
            p = json.loads(line)
            cat[p["id"].lower()] = p
    claims = defaultdict(list)
    for c in load("all_claims.json"):
        claims[c["pid"].lower()].append({"status": c.get("status"), "user_id": c.get("uid"),
                                         "team_id": c.get("team"), "flagged": None})
    identity = [{"profile_id": x["login"].lower(), "user_id": x["uid"], "kind": "login"} for x in load("all_login.json")]
    identity += [{"profile_id": x["p"].lower(), "user_id": x["uid"], "kind": "primary"} for x in load("all_primary.json")]
    merges = [{"loser": x["l"].lower(), "survivor": x["s"].lower(), "status": x["status"]} for x in load("all_pm.json")]
    wl_text = (d / "watchlist.json").read_text().lower()
    wl_doc = json.loads(wl_text)
    wl_users = {str(u) for e in wl_doc.get("entries", []) for u in e.get("user_ids") or []}
    ft = {x["ticket"]: x for x in load("ft.json")}
    convinfo = load("ft_convinfo.json")
    same_name: dict[tuple[str, str], bool] = {}
    try:
        for r in load("d1_consolidate_dry.json"):
            detail = json.dumps(r.get("result") or {})
            for loser8 in r.get("from") or []:
                same_name[(r["keep"][:8], loser8[:8])] = bool(SAME_NAME.search(detail))
    except FileNotFoundError:
        pass
    expected = m1_states(Path(states_md).read_text()) if states_md else {}

    out = []
    for t in tickets:
        keep = (t.get("keep") or "").lower() or None
        dups = [x.lower() for x in t.get("dups") or [] if x and x.lower() != keep]
        sides = ([keep] if keep else []) + dups
        profiles = {u: _profile(cat.get(u)) for u in sides}
        side_claims = {u: claims.get(u, []) for u in sides}
        users = {str(c["user_id"]) for u in sides for c in side_claims[u] if c["user_id"] is not None}
        threads = None
        if t["id"] in ft and ft[t["id"]].get("email"):
            f = ft[t["id"]]
            threads = [{"conv": c["conv"],
                        "bound": f.get("contacts") == 1 and c.get("n_contacts") == 1,
                        "named_ids": (convinfo.get(c["conv"]) or {}).get("ids") or []} for c in f.get("convs") or []]
        pairs = {}
        for loser in dups:
            kp, lp = profiles.get(keep or "", {}), profiles[loser]
            pairs[loser] = {"name_relation": rules.best_name_relation(kp.get("names") or [], lp.get("names") or []),
                            "same_name_others": same_name.get(((keep or "")[:8], loser[:8]))}
        out.append({
            "ticket": t["id"], "status": t.get("status"), "tags": t.get("tags") or [], "created_ms": t.get("created"),
            "priority": t.get("priority"), "conv": t.get("conv"), "keep": keep, "dups": dups,
            "profiles": profiles, "claims": side_claims,
            "identity": [r for r in identity if r["profile_id"] in sides],
            "merges": [m for m in merges if m["loser"] in sides or m["survivor"] in sides] if sides else [],
            "watchlist": {"profile_ids": [u for u in sides if u in wl_text],
                          "requester_hit": bool(users & wl_users)},
            "paid": None, "threads": threads, "pairs": pairs,
            "read": {"source": "m1 .measure 2026-10-27T20:5xZ", "fresh": False},
            "m1_state": expected.get(t["id"]),
        })
    # chains: a verified merge may go through a profile outside this ticket; keep every verified row
    all_verified = [m for m in merges if m["status"] == "verified"]
    for row in out:
        row["merges"] = _closure(row["merges"], all_verified, [row["keep"] or ""] + row["dups"])
    return out


def _closure(rows: list[dict], verified: list[dict], start: Iterable[str]) -> list[dict]:
    by_loser = {m["loser"]: m for m in verified}
    have = {(m["loser"], m["survivor"], m["status"]) for m in rows}
    out = list(rows)
    for pid in start:
        seen = 0
        while pid in by_loser and seen < 20:
            m = by_loser[pid]
            if (m["loser"], m["survivor"], m["status"]) not in have:
                out.append(m)
                have.add((m["loser"], m["survivor"], m["status"]))
            pid, seen = m["survivor"], seen + 1
    return out


def strip(row: dict) -> dict:
    """The committable form: no names (the pair relation is kept)."""
    r = json.loads(json.dumps(row))
    for p in r["profiles"].values():
        p.pop("names", None)
    return r


def write_set(rows: list[dict], path: Path = SET_PATH) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(path, "wt", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(strip(r), sort_keys=True) + "\n")


def load_set(path: Path = SET_PATH) -> list[dict]:
    with gzip.open(path, "rt", encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]
