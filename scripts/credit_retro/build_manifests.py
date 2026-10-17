#!/usr/bin/env python3
"""Build the committed credit-retro r1 manifests from the f1 retro-review data.

Run once, by hand, against the f1 outputs (firstmate data
credit-retro-hold-docfraud-f1: tiers.csv, tiers-c.csv, and the f1 worktree
scratch rows_scored2.json, c_rows_scored.json, c_webchecks_all.json). The
outputs are committed under scripts/credit_retro/manifests/ so a run on node-8
reads the exact rows firstmate approved, and the evidence URLs survive the f1
worktree teardown.

Ids, public track/artist names and public-credit URLs only. No emails, no
claimant names, no plan names.

  manifests/takeback-r1.jsonl       one line per PROVEN role (decision 001 A): the web
                                    check read THAT role's credit, not a sibling role's
  manifests/population-r1.jsonl.gz  one line per request to VERIFY with documents:
                                    Part C HOLD / WATCH / unverifiable-small, Part A
                                    HOLD, and every unproven role of a take-back request
                                    (incl. a contradicted role with no own-role web check)
  manifests/watch-velocity-r1.jsonl one line per WATCH velocity account
"""

from __future__ import annotations

import argparse
import collections
import csv
import gzip
import json
from pathlib import Path
from urllib.parse import urlparse

EXCLUDED_USERS = {"15"}
ONE_PERSON_ROLES = {"Mixing", "Mastering", "Immersive Mixing", "Immersive Mastering", "Remastering"}
# Independent public-credit pages, best first. The cited URL recorded as the
# approval_ref is the first of these the web check read.
PREFERRED_DOMAINS = ("qobuz.com", "music.apple.com", "allmusic.com", "tidal.com", "discogs.com",
                     "musicbrainz.org", "bandcamp.com", "shazam.com", "open.spotify.com", "music.amazon")
OWN_DOMAINS = ("muso.ai",)
# WATCH velocity: accounts created 2026-09-02 -> 10-07 with a 100+/day burst (part-c §0).
VELOCITY_MIN_ACCOUNT_DATE = "2026-09-01"
EDITING_ROLES = {"Editorial", "Assembly"}  # the only claimable editing roles (replica 2026-10-15)
EDITING_MID_POP = 30
BURST_MIN_ROWS = 40
BURST_MIN_PER_DAY = 40
EDITING_LOOSE_PATHS = {"agent_batch", "declined_approved", "credit_exists", "common_collaborator",
                       "org_profile", "zero_multiplier"}
VERIFY_TIERS = {"HOLD", "WATCH_velocity", "WATCH_big_unverifiable", "KEEP_unverifiable_small"}


def best_url(urls: list[str]) -> str:
    clean = [u for u in urls if u and not any(d in urlparse(u).netloc for d in OWN_DOMAINS)]
    for dom in PREFERRED_DOMAINS:
        for u in clean:
            if dom in urlparse(u).netloc:
                return u
    return clean[0] if clean else ""


def paying(value) -> bool:
    return bool(str(value or "").strip())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tiers-a", required=True)
    ap.add_argument("--tiers-c", required=True)
    ap.add_argument("--rows-a", required=True, help="f1 scratch rows_scored2.json")
    ap.add_argument("--rows-c", required=True, help="f1 scratch c_rows_scored.json")
    ap.add_argument("--webchecks", required=True, help="f1 scratch c_webchecks_all.json")
    ap.add_argument("--editing", help="editing-role extract (replica, loose paths + agent batch), json[.gz]")
    ap.add_argument("--editing-check", help="live trusted-credit check of the editing claims (jsonl[.gz]): "
                    "whole-profile review of burst accounts + per-row verdicts")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent / "manifests"))
    args = ap.parse_args()

    tiers_c = list(csv.DictReader(open(args.tiers_c, encoding="utf-8")))
    tiers_a = list(csv.DictReader(open(args.tiers_a, encoding="utf-8")))
    rows_c = {r["id"]: r for r in json.load(open(args.rows_c, encoding="utf-8"))}
    rows_a = {r["id"]: r for r in json.load(open(args.rows_a, encoding="utf-8"))}
    webchecks = collections.defaultdict(list)
    for w in json.load(open(args.webchecks, encoding="utf-8")):
        webchecks[w["id"]].append(w)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    # -- TAKE-BACK: the proven roles only ---------------------------------
    tb_requests = {x["credit_request_id"] for x in tiers_c if x["tier"] == "TAKEBACK_candidate"}
    takeback = []
    proven_by_request: dict[str, set[str]] = collections.defaultdict(set)
    needs_own_evidence: set[str] = set()
    for rid in sorted(tb_requests):
        r = rows_c[rid]
        if str(r["uid"]) in EXCLUDED_USERS:
            continue
        checks = webchecks.get(rid, [])
        for role, verdict, _live, others, _n in r["verdicts"]:
            if verdict != "CONTRADICTED_one" or role not in ONE_PERSON_ROLES:
                continue
            same = [w for w in checks if w["role"] == role]
            if not same:
                needs_own_evidence.add(rid)
                continue
            w = same[0]
            if w["web"] != "CONTRADICTED" or w.get("alias"):
                continue
            proven_by_request[rid].add(role)
            takeback.append({
                "row_id": f"{rid}:{role}",
                "request_id": rid, "user_id": str(r["uid"]), "profile_id": r["pid"], "track_id": r["tid"],
                "role": role, "track_title": r["title"], "artist": r["artist"], "pop_now": r["pop_now"],
                "approver": r["approver"], "approved_at": r["at"], "validator_risk": r["risk"],
                "displaced": others,
                "web": {"verdict": w["web"], "confidence": w["conf"], "role_checked": w["role"],
                        "scope": "role",
                        "reason": w["reason"], "urls": w["urls"]},
                "evidence_url": best_url(w["urls"]),
                "paying": paying(r.get("paying")),
            })

    # -- VERIFY population: every not-yet-confirmed credit of the batch ---
    # Captain ~23:35Z via firstmate 002: Nick's batch approvals were trust-yet-verify; now
    # verify them. Part C tiers HOLD + WATCH_velocity + WATCH_big_unverifiable +
    # KEEP_unverifiable_small, plus Part A HOLD, plus every unproven role of a take-back
    # request. Never: KEEP_established / KEEP_web_credible (aliases) / KEEP_confirmed, user 15.
    population: dict[str, dict] = {}

    def add(tier: str, source: str, rid: str, r: dict, role: str, verdict: str, web: str) -> None:
        if str(r["uid"]) in EXCLUDED_USERS or role in proven_by_request.get(rid, set()):
            return
        h = population.setdefault(rid, {
            "request_id": rid, "user_id": str(r["uid"]), "profile_id": r["pid"], "track_id": r["tid"],
            "track_title": r["title"], "artist": r["artist"], "pop_now": r["pop_now"],
            "paying": paying(r.get("paying")), "tier": tier, "sources": [], "roles": [],
            "takeback_residual": rid in proven_by_request,
        })
        if source not in h["sources"]:
            h["sources"].append(source)
        if all(x["role"] != role for x in h["roles"]):
            role_row = {"role": role, "verdict": verdict}
            if web:
                role_row["web"] = web
            h["roles"].append(role_row)

    for x in tiers_a:
        if x["tier"] == "HOLD":
            add("A_HOLD", "A", x["credit_request_id"], rows_a[x["credit_request_id"]], x["role"],
                x["catalog_verdict"], x["web_check"])
    for x in tiers_c:
        if x["tier"] in VERIFY_TIERS:
            add(x["tier"], "C", x["credit_request_id"], rows_c[x["credit_request_id"]], x["role"],
                x["catalog_verdict"], x["web_check"])
    # residual roles tagged TAKEBACK in tiers-c (e.g. 7c8ff6be)
    for rid in sorted(set(proven_by_request) | needs_own_evidence):
        for role, verdict, *_ in rows_c[rid]["verdicts"]:
            add("HOLD", "C", rid, rows_c[rid], role, verdict, "")

    # Captain ~23:42Z via firstmate 004: editorial roles are high-risk; every editing-role
    # claim approved through a loose path or the agent batch is verified too (role-scoped:
    # only the editing roles of the request). Excludes owning_track and score-approved rows.
    if args.editing:
        opener = gzip.open if args.editing.endswith(".gz") else open
        with opener(args.editing, "rt", encoding="utf-8") as fh:
            editing = json.load(fh)
        for e in editing:
            if e["path"] not in EDITING_LOOSE_PATHS:
                continue
            r = {"uid": e["uid"], "pid": e["pid"], "tid": e["tid"], "title": e["title"], "artist": e["artist"],
                 "pop_now": e["pop"], "paying": "yes" if e.get("paying") else ""}
            existed = e["id"] in population
            for role in e["credits"]:
                if role in EDITING_ROLES:
                    add("EDITING_LOOSE", "E", e["id"], r, role, "EDITING_UNVERIFIED", "")
            if e["id"] in population:
                h = population[e["id"]]
                h["editing_path"] = e["path"]
                if not existed and h["tier"] != "EDITING_LOOSE":
                    h["tier"] = "EDITING_LOOSE"

    # -- WATCH velocity accounts ------------------------------------------
    vel = collections.defaultdict(list)
    for x in tiers_c:
        if x["tier"] == "WATCH_velocity":
            vel[x["user_id"]].append(x["credit_request_id"])
    watch = []
    for uid, rids in sorted(vel.items()):
        rids = sorted(set(rids))
        sample = rows_c[rids[0]]
        if uid in EXCLUDED_USERS or str(sample["first"]) < VELOCITY_MIN_ACCOUNT_DATE or sample["age"] > 60:
            continue
        top = sorted((rows_c[i] for i in rids), key=lambda r: (-int(r["pop_now"] or 0), r["id"]))[:3]
        watch.append({
            "user_id": uid,
            "profile_ids": sorted({rows_c[i]["pid"] for i in rids}),
            "velocity_rows": len(rids),
            "population_rows": sum(1 for h in population.values() if h["user_id"] == uid),
            "first_request": sample["first"], "max_requests_per_day": sample["maxday"],
            "trusted_credits_on_profile": sample["fp"]["raw_any"],
            "paying": paying(sample.get("paying")),
            "example_tracks": [{"request_id": r["id"], "track_id": r["tid"], "role": r["roles"][0],
                                "track_title": r["title"], "artist": r["artist"], "pop_now": r["pop_now"]}
                               for r in top],
        })

    def dump(name: str, rows: list[dict]) -> None:
        with open(out / name, "w", encoding="utf-8") as fh:
            for row in rows:
                fh.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")

    dump("takeback-r1.jsonl", sorted(takeback, key=lambda r: r["row_id"]))
    # gzip, mtime 0: byte-identical rebuilds; ~16K rows would be ~5 MB as text.
    buf = "".join(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n"
                  for r in sorted(population.values(), key=lambda r: r["request_id"]))
    with open(out / "population-r1.jsonl.gz", "wb") as raw_fh, \
            gzip.GzipFile(filename="", mode="wb", fileobj=raw_fh, mtime=0) as gz:
        gz.write(buf.encode())
    dump("watch-velocity-r1.jsonl", watch)

    # -- editing asks (firstmate 006: ask only genuine risk) ----------------
    # Burst accounts: >= BURST_MIN_ROWS loose editing claims and a peak of >= BURST_MIN_PER_DAY
    # in one day; asked ONCE per account unless the whole-profile review (8 biggest tracks)
    # found trusted sources naming them as editor on at least half. Rows of everyone else:
    # trusted source names someone else as editor (any track), or unverifiable on a mid/big
    # track; the size cut is applied at prepare time (waves.EDITING_MIN_POP).
    if args.editing and args.editing_check:
        opener = gzip.open if args.editing_check.endswith(".gz") else open
        with opener(args.editing_check, "rt", encoding="utf-8") as fh:
            checked = [json.loads(line) for line in fh if line.strip()]
        loose = [e for e in editing if e["path"] in EDITING_LOOSE_PATHS]
        by_user = collections.defaultdict(list)
        for e in loose:
            by_user[e["uid"]].append(e)
        review = collections.defaultdict(collections.Counter)
        for c in checked:
            if c.get("k") == "burst" and c.get("verdict"):
                review[c["uid"]][c["verdict"]] += 1
        verdict_of = {c["id"]: c for c in checked if c.get("k") == "row" and c.get("verdict")}
        accounts, rows_out = [], []
        for uid, es in sorted(by_user.items()):
            peak = max(collections.Counter(e["at"] for e in es).values())
            if uid in EXCLUDED_USERS:
                continue
            if len(es) >= BURST_MIN_ROWS and peak >= BURST_MIN_PER_DAY:
                rv = review.get(uid, collections.Counter())
                top = sorted(es, key=lambda e: (-int(e["pop"] or 0), e["id"]))[:3]
                accounts.append({
                    "user_id": uid, "profile_ids": sorted({e["pid"] for e in es}), "editing_rows": len(es),
                    "peak_per_day": peak, "first": min(e["at"] for e in es), "last": max(e["at"] for e in es),
                    "paying": any(e.get("paying") for e in es), "review": dict(rv),
                    "ask": rv.get("CONFIRMED", 0) * 2 < sum(rv.values()),
                    "example_tracks": [{"request_id": e["id"], "track_id": e["tid"],
                                        "role": next(r for r in e["credits"] if r in EDITING_ROLES),
                                        "track_title": e["title"], "artist": e["artist"], "pop_now": e["pop"]}
                                       for e in top],
                })
                continue
            for e in es:
                c = verdict_of.get(e["id"])
                # only rows that can ever be asked: contradicted anywhere, unverifiable on >= mid tracks
                if c and (c["verdict"] == "CONTRADICTED"
                          or (c["verdict"] == "UNVERIFIABLE" and int(e["pop"] or 0) >= EDITING_MID_POP)):
                    rows_out.append({"request_id": e["id"], "user_id": uid, "pop_now": e["pop"],
                                     "verdict": c["verdict"], "others": c.get("others") or []})
        with open(out / "editing-ask-r1.json", "w", encoding="utf-8") as fh:
            json.dump({"burst_rule": {"min_rows": BURST_MIN_ROWS, "min_peak_per_day": BURST_MIN_PER_DAY},
                       "accounts": accounts, "rows": sorted(rows_out, key=lambda r: r["request_id"])},
                      fh, ensure_ascii=False, sort_keys=True)
        print(json.dumps({"editing_burst_accounts": len(accounts),
                          "editing_burst_asked": sum(a["ask"] for a in accounts),
                          "editing_rows_checked": len(rows_out),
                          "editing_rows_by_verdict": dict(collections.Counter(r["verdict"] for r in rows_out))}))
    print(json.dumps({
        "takeback_roles": len(takeback),
        "takeback_requests": len(proven_by_request),
        "takeback_users": len({r["user_id"] for r in takeback}),
        "takeback_requests_needing_own_role_evidence": len(needs_own_evidence),
        "population_requests": len(population),
        "population_users": len({h["user_id"] for h in population.values()}),
        "population_paying_users": len({h["user_id"] for h in population.values() if h["paying"]}),
        "population_by_tier": dict(collections.Counter(h["tier"] for h in population.values())),
        "editing_requests": sum(1 for h in population.values() if "E" in h["sources"]),
        "editing_users": len({h["user_id"] for h in population.values() if "E" in h["sources"]}),
        "takeback_residual_roles": sum(len(h["roles"]) for h in population.values() if h["takeback_residual"]),
        "watch_velocity_accounts": len(watch),
    }, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
