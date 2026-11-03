#!/usr/bin/env python3
"""Read today's merge facts for the verifier-eval merges set, READ-ONLY, for an independent re-label.

    python3 scripts/verifier-eval-merge-facts.py --data ~/Projects/firstmate/data \
        [--ids ids.txt] --out scripts/verifier_eval/sets/merges-facts-YYYYMMDD.json.gz

Profiles per item come from m1's own ticket file (queue-classes keep/others) and d1-batch §4 pairs,
NOT from any verifier's output. Facts:
  core read replica (n19, `pg_is_in_recovery()` asserted, `BEGIN READ ONLY`, statement_timeout):
    claiming rows, users login profile (`neptuneProfessionalId`), presented primary
    (`user_identity_resolution` is_primary AND is_confirmed AND NOT is_rejected AND tier confirmed|high:
    core's findLoginOrPrimaryLosers predicate), owner/admin workspaces of every claimant, roster seats on
    a paying subscription, in-flight profile_merges rows, staff search holds;
  catalog (industry-api GET /v1/profile/:id?return_deleted=true): forwarded id (merged), deleted,
    type, subType, creditCount, raw DSP identities.
Reached through node-1 (ssh) -> n19 for SQL and node-1 -> the industry-api ClusterIP for the
catalog; no write path. Output keeps ids, statuses and counts only (no names, e-mails, bios).
"""

from __future__ import annotations

import argparse
import base64
import gzip
import json
import re
import subprocess
import sys
import time
from pathlib import Path

NODE1 = "root@135.148.169.37"
REPLICA = "ubuntu@10.0.0.19"
INDUSTRY = "http://10.43.43.86:8000/v1"
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def ssh(cmd: str, timeout: int = 180) -> str:
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", NODE1, cmd],
                       capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"ssh failed rc={r.returncode}: {r.stderr[-400:]}")
    return r.stdout


def sql_json(query: str) -> list:
    body = ("BEGIN READ ONLY; SET statement_timeout='90s'; "
            "DO $$ BEGIN IF NOT pg_is_in_recovery() THEN RAISE EXCEPTION 'not the replica'; END IF; END $$; "
            f"SELECT coalesce(json_agg(t), '[]'::json)::text FROM ({query}) t; COMMIT;")
    b64 = base64.b64encode(body.encode()).decode()
    out = ssh(f"ssh -o BatchMode=yes -i /root/.ssh/ovh_muso {REPLICA} "
              f"'echo {b64} | base64 -d | sudo -u postgres psql -X -q -A -t -v ON_ERROR_STOP=1 core'")
    start = out.index("[")
    return json.loads(out[start:out.rindex("]") + 1])


def catalog(ids: list[str]) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for i in range(0, len(ids), 40):
        chunk = ids[i:i + 40]
        script = "; ".join(f'echo "@@{p}"; curl -s -m 20 "{INDUSTRY}/profile/{p}?return_deleted=true"; echo'
                           for p in chunk)
        raw = ssh(script, timeout=600)
        for block in raw.split("@@")[1:]:
            pid, _, body = block.partition("\n")
            pid = pid.strip()
            try:
                d = json.loads(body.strip() or "{}")
            except ValueError:
                out[pid] = {"read": "error"}
                continue
            data = d.get("data") if isinstance(d, dict) else None
            if not data:
                out[pid] = {"read": "not_found" if "Not Found" in body else "error"}
                continue
            raws = sorted({f"{r.get('source')}:{r.get('id')}" for r in data.get("rawProfiles") or []
                           if r.get("source") and r.get("source") != "muso"})
            out[pid] = {"read": "ok", "served_id": data.get("id"), "forwarded": data.get("id") != pid,
                        "merged": data.get("merged"), "deleted": data.get("deleted"),
                        "type": data.get("type"), "subType": data.get("subType"),
                        "creditCount": data.get("creditCount"), "raw_ids": raws}
    return out


def items_from_m1(data: Path) -> dict[str, dict]:
    lane = data / "profile-merge-ops-m1"
    classes = json.loads((lane / "queue-classes-1026.json").read_text())
    tickets = {str(t["id"]): t for ts in classes.values() for t in ts}
    items: dict[str, dict] = {}
    md = (lane / "d1-batch-1028.md").read_text()
    pair_tickets = set()
    unresolved: list[tuple[str, str, str, str]] = []
    for line in md.splitlines():
        c = [x.strip() for x in line.strip().strip("|").split("|")]
        if len(c) == 7 and c[1] in ("D2-login-loser", "executable-L7"):
            t = tickets.get(c[0])
            if not t:  # ticket newer than m1's 10-26 file: resolve the 8-hex ids from core below
                unresolved.append((c[0], c[3], c[4], f"{c[0]}:{c[4]}"))
                pair_tickets.add(c[0])
                continue
            pool = [t["keep"], *t.get("others", [])]
            keep = next((p for p in pool if p.startswith(c[3])), None)
            loser = next((p for p in pool if p.startswith(c[4])), None)
            if keep and loser:
                items[f"{c[0]}:{c[4]}"] = {"kind": "pair", "ticket": c[0], "keep": keep, "losers": [loser]}
                pair_tickets.add(c[0])
    if unresolved:
        prefixes = sorted({x for u in unresolved for x in (u[1], u[2])})
        cond = " OR ".join(f"p LIKE '{x}%'" for x in prefixes)
        rows = sql_json('SELECT DISTINCT p FROM (SELECT "profileId"::text AS p FROM claiming UNION '
                        'SELECT "neptuneProfessionalId"::text FROM users WHERE "neptuneProfessionalId" IS NOT NULL UNION '
                        'SELECT candidate_profile_id::text FROM user_identity_resolution UNION '
                        'SELECT survivor_profile_id::text FROM profile_merges UNION '
                        f'SELECT loser_profile_id::text FROM profile_merges) u WHERE {cond}')
        full: dict[str, list[str]] = {}
        for r in rows:
            full.setdefault(r["p"][:8], []).append(r["p"].lower())
        for tid, k8, l8, key in unresolved:
            ks, ls = full.get(k8, []), full.get(l8, [])
            items[key] = {"kind": "pair", "ticket": tid, "keep": ks[0] if len(ks) == 1 else None,
                          "losers": [ls[0]] if len(ls) == 1 else [], "resolved_from_core_prefix": True}
    for tid, t in tickets.items():
        if tid not in pair_tickets:
            items[tid] = {"kind": "ticket", "ticket": tid, "keep": t.get("keep"), "losers": list(t.get("others") or [])}
    return items


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(Path("~/Projects/firstmate/data").expanduser()))
    ap.add_argument("--ids", help="file of item ids to read (default: every item)")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    items = items_from_m1(Path(a.data).expanduser())
    if a.ids:
        want = {ln.strip() for ln in open(a.ids) if ln.strip()}
        items = {k: v for k, v in items.items() if k in want}
    pids = sorted({p.lower() for it in items.values() for p in [it["keep"], *it["losers"]] if p and UUID.match(p.lower())})
    lit = "ARRAY[" + ",".join(f"'{p}'" for p in pids) + "]::text[]"
    claims = sql_json(f'SELECT id, lower("profileId"::text) AS "profileId", "userId", "teamId"::text AS "teamId", status, '
                      f'"profileType", reason FROM claiming WHERE "deletedAt" IS NULL AND lower("profileId"::text) = ANY({lit})')
    login = sql_json(f'SELECT id::text AS "userId", lower("neptuneProfessionalId"::text) AS "profileId" FROM users '
                     f'WHERE lower("neptuneProfessionalId"::text) = ANY({lit})')
    primary = sql_json("SELECT user_id::text AS \"userId\", lower(candidate_profile_id::text) AS \"profileId\" "
                       "FROM user_identity_resolution WHERE is_primary AND is_confirmed AND NOT is_rejected "
                       f"AND confidence_tier IN ('confirmed','high') AND lower(candidate_profile_id::text) = ANY({lit})")
    users = sorted({str(c["userId"]) for c in claims if c.get("userId") is not None})
    teams = sorted({str(c["teamId"]) for c in claims if c.get("teamId")})
    ulit = "ARRAY[" + ",".join(users or ["-1"]) + "]::int[]"
    tlit = "ARRAY[" + ",".join(f"'{t}'" for t in teams or ["00000000-0000-0000-0000-000000000000"]) + "]::text[]"
    admins = sql_json(f'SELECT "userId", "teamId"::text AS "teamId" FROM team_users WHERE ("userId" = ANY({ulit}) '
                      f'OR "teamId"::text = ANY({tlit})) AND (roles ? \'owner\' OR roles ? \'admin\')')
    defaults = sql_json(f'SELECT id::text AS "userId", lower("defaultTeamId"::text) AS "teamId" FROM users WHERE id = ANY({ulit})')
    seats = sql_json(f'SELECT DISTINCT lower(rs."seatId"::text) AS "profileId", rs."teamId"::text AS "teamId" FROM roster_seats rs '
                     "JOIN subscriptions s ON s.\"teamId\" = rs.\"teamId\" WHERE rs.status IN ('active','paused') AND "
                     "(s.status IN ('active','trial') OR ((s.plan = 'vip' OR s.plan = 'custom' OR s.plan LIKE '%business%' "
                     f"OR s.plan LIKE '%pro%') AND s.status IS NULL)) AND lower(rs.\"seatId\"::text) = ANY({lit})")
    merges = sql_json("SELECT lower(survivor_profile_id::text) AS survivor, lower(loser_profile_id::text) AS loser, status, "
                      "verified_at FROM profile_merges WHERE lower(survivor_profile_id::text) = ANY(" + lit + ") "
                      f"OR lower(loser_profile_id::text) = ANY({lit})")
    # LEGAL_HOLD is a real self-merge refusal slug (core self-merge finding X1 §6), so the hold source
    # is a gate the labels depend on: a snapshot that could not read it must never let a relabel say
    # `eligible`. Candidate names are listed explicitly because the source is a core-side detail; the
    # name actually found is recorded in the snapshot so a reader can tell "no holds" from "not read".
    HOLDS = ("profile_search_visibility", "profile_legal_holds", "profile_holds")
    found = sql_json("SELECT table_name FROM information_schema.tables WHERE table_name = ANY(ARRAY["
                     + ",".join(f"'{t}'" for t in HOLDS) + "]::text[])")
    hold_table = (found[0]["table_name"] if found else None)
    holds = sql_json(f"SELECT lower(profile_id::text) AS \"profileId\" FROM {hold_table} WHERE source = 'staff' "
                     f"AND lower(profile_id::text) = ANY({lit})") if hold_table else []
    cat = catalog(pids)
    out = {"read_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "source": "n19 replica + industry-api",
           "items": items, "profiles": cat, "claims": claims, "login": login, "primary": primary,
           "admins": admins, "default_teams": defaults, "paid_seats": seats, "profile_merges": merges, "staff_holds": holds,
           "staff_hold_table_present": bool(hold_table), "staff_hold_table": hold_table}
    with gzip.open(a.out, "wt", encoding="utf-8") as fh:
        json.dump(out, fh, sort_keys=True, default=str)
    if not hold_table:
        print(f"WARNING: no legal-hold source found among {', '.join(HOLDS)} on the replica -> every merge that"
              " would otherwise be eligible is labelled queued_review:LEGAL_HOLD_UNKNOWN, never eligible",
              file=sys.stderr)
    print(json.dumps({"items": len(items), "profiles": len(pids), "claims": len(claims), "login": len(login),
                      "primary": len(primary), "admins": len(admins), "paid_seats": len(seats),
                      "profile_merges": len(merges), "staff_holds": len(holds),
                      "catalog_ok": sum(1 for v in cat.values() if v.get("read") == "ok")}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
