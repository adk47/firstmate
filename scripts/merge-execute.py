#!/usr/bin/env python3
"""Coded profile-merge executor, `dup-dsp-absorb` class (ruling l7-1030; scripts/merge_execute/absorb.py).

  shadow  build every duplicate-with-DSP-id pair from the DSP verifier store, read the facts fresh
          (replica, catalog, fraud gate), decide with the pure rule, and write one JSONL line per pair
          (+ the run id) to --out. Writes nothing else. This is what Fable / verifier-eval label.
  run     execute ELIGIBLE rows of a shadow file, one at a time:
            kill file absent -> per-day cap (25) -> facts re-read and the rule re-decided NOW (must
            still be eligible) -> the decider record for THIS merge appended to
            <muso config>/merge-decisions.jsonl (muso-cli#64 binds the approval to it) ->
            `muso profiles merge --into <claimed survivor> --from <source>` with
            --approval-ref '<ref>|captain-<id>|decider-<run>|l7-1030' -> READ-BACK (polled): source
            forwards to the survivor, survivor credits >= max(before), ledger row not failed.
          ANY read-back != expected: the kill file is written (stops every later run), the row is
          recorded `surprise`, exit 4. Dry run by default; --apply executes.
Every action is one append-only JSONL line in /var/lib/hydra/merge-executor/ledger.jsonl.

Inputs are CONSTANTS (r5 [key=unattended], #1556 @6b205e35) and the only argument is the captain's approval ref:
`--apply` requires it (e.g. captain-1030-131x). Nothing else about THIS run - not the kill file, not the state dir that
holds the day cap and the one-at-a-time lock, not the evidence store, not the binary that performs the merge, not the
read-back window, not the confirmer/requester written into the approval ref - can be moved by a shell: this file reads
NO environment variable at all (QA #1556 critical). Tests rebind the constants below IN PROCESS (they import this
module); a caller can only choose arguments, and the arguments are checked.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from merge_execute import absorb  # noqa: E402

# r5 [key=unattended] (NO-GO @6b205e35, the #1541 / credit-verify-outbound.sh cfg() shape): every gate input is a
# CONSTANT and this file reads NO environment variable, so a shell cannot mount an empty evidence store, a kill file
# that does not exist, or a fresh state dir (which would re-merge pairs already absorbed and forget the 25/day cap).
# QA #1556 (critical): the previous version trusted caller-set bats markers (BATS_TEST_TMPDIR + BATS_TEST_FILENAME +
# BATS_VERSION) as "the test harness" - an ordinary shell can set all three, so the seam was forgeable in production.
# The seam is now IN PROCESS ONLY: a test imports this module and rebinds the constants below. Nothing an invocation
# can supply - argv, environment, cwd - reaches them (see test_merge_execute.py: forged marker set + AST scan).
KILL = "/etc/hydra/merge-executor.disabled"
STATE_DIR = Path("/var/lib/hydra/merge-executor")
STORE = "/var/lib/hydra-credit-verify/dsp-verify.sqlite"
MUSO = "muso"
MUSO_CONFIG = Path("/root/.config/muso")
DAY_CAP = 25
READBACK_S = 1800
# The identity claims are CALL PARAMETERS with constants as their defaults: no env var reaches them at all.
CONFIRMER = "fable-decider"
REQUESTER = "merge-executor@muso.ai"
POLL_S = 30
IN_FLIGHT = ("requested", "enqueued", "callback_received", "pending", "processing")


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ledger(row: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(STATE_DIR / "ledger.jsonl", "a") as fh:
        fh.write(json.dumps({"at": now_iso(), **row}, sort_keys=True) + "\n")


def executed_today() -> int:
    """Merges SENT today (UTC), from the ledger; the day cap counts attempts, not only successes."""
    p = STATE_DIR / "ledger.jsonl"
    if not p.exists():
        return 0
    day, n = now_iso()[:10], 0
    for ln in p.read_text().splitlines():
        if ln.strip():
            r = json.loads(ln)
            n += r.get("event") == "merge_sent" and str(r.get("at", ""))[:10] == day
    return n


# ── facts ───────────────────────────────────────────────────────────────────────────────────────

def store_pairs(store: str = STORE) -> list[dict]:
    """(user, presented profile, source) pairs + the same-run readings for THAT presented profile.

    QA #1556 (critical): evidence was pooled per USER, so a pair harvested while presenting one claimed profile
    inherited every reading of every other request by that user. With three genuine ties for claimed profile A and a
    separate one-track request for claimed profile B naming the same holder, (B, source) inherited A's three ties and
    could be marked eligible - absorbing the unclaimed copy into the WRONG claimed profile. A tie is evidence about
    ONE presented profile, so the pool is now (user, presented profile); a reading is still only a tie when it was
    captured after ITS OWN request (`same_run`, computed per row).
    """
    st = sqlite3.connect(f"file:{store}?mode=ro", uri=True)
    rows = st.execute("""SELECT v.request_id, v.user_id, v.profile_id, v.track_id, v.paid, v.packet_json, v.reason_class
        FROM dsp_verdicts v
        JOIN dsp_runs r ON r.run_id = v.run_id AND r.kind = 'verify'
        WHERE v.id IN (SELECT MAX(id) FROM dsp_verdicts WHERE version='dsp-1' GROUP BY request_id) AND v.packet_json IS NOT NULL""").fetchall()
    by_pair: dict[tuple, dict] = {}
    for rid, uid, pid, tid, paid, pj, cls in rows:
        p = json.loads(pj)
        cap = p.get("capture") or {}
        q = by_pair.setdefault((str(uid), pid), {"user_id": uid, "paid": paid, "profile_id": pid,
                                                 "person": cap.get("person_name"), "collisions": [],
                                                 "readings": [], "raw_by_holder": {}, "holders": set(),
                                                 "request_ids": set()})
        q["request_ids"].add(str(rid))
        q["collisions"].append(p.get("name_collisions"))
        for role, rr in (cap.get("roles") or {}).items():
            for dsp, R in ((rr or {}).get("sources") or {}).items():
                if not R:
                    continue
                same_run = (R.get("captured_at") or "") > (cap.get("requested_at") or "")
                cred = [[n, c, raw, h] for n, c, _linked, raw, h in (R.get("credited_in_family") or [])]
                q["readings"].append({"track": tid, "req": str(rid), "captured": R.get("state") == "CAPTURED",
                                      "same_run": same_run, "credited": cred})
                for n, c, raw, h in cred:
                    if h and raw:
                        q["raw_by_holder"].setdefault(h, set()).add(raw)
                    if (cls == "needs_profile_link" and R.get("state") == "CAPTURED" and same_run and raw and h and h != pid
                            and absorb.fold(n) == absorb.fold(cap.get("person_name"))):
                        q["holders"].add(h)
    out = []
    for (uid, pid) in sorted(by_pair, key=lambda k: (k[0], k[1] or "")):
        q = by_pair[(uid, pid)]
        coll = [c for c in q["collisions"] if c is not None]
        for h in sorted(q["holders"]):
            out.append({"user_id": q["user_id"], "paid": q["paid"], "survivor": pid, "source": h,
                        "person_name": q["person"],
                        "name_collisions": (max(coll) if coll and len(coll) == len(q["collisions"]) else None),
                        "readings": q["readings"], "source_raw_ids": sorted(q["raw_by_holder"].get(h, set())),
                        "request_ids": sorted(q["request_ids"])})
    return out


def trino(sql: str) -> list[dict]:
    p = subprocess.run([MUSO, "--env", "prod", "query", "--format", "json", "-"], input=sql, capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        raise RuntimeError(f"trino exit {p.returncode}")
    return [json.loads(x) for x in p.stdout.splitlines() if x.strip()]


def catalog(ids: list[str]) -> dict[str, dict]:
    args = [MUSO, "--env", "prod", "--json", "api", "GET", "/admin/profile", "--query", "includeDeleted=true",
            "--query", f"limit={len(ids)}"]
    for i in ids:
        args += ["--query", f"ids={i}"]
    p = subprocess.run(args, capture_output=True, text=True, timeout=90)
    if p.returncode != 0:
        raise RuntimeError(f"catalog exit {p.returncode}")
    body = json.loads(p.stdout)
    items = (body.get("data") or body).get("items", [])
    return {str(x["id"]).lower(): {"sub_type": x.get("subType"), "merged_to": (x.get("merged") or {}).get("mergedToId"),
                                   "deleted": x.get("deleted") is not None, "credits": x.get("creditCount")} for x in items}


def holds(uid: int) -> list[str]:
    sys.path.insert(0, "/opt/hydra/scripts")
    from credit_review import comm_state as cs  # noqa: PLC0415
    return cs.fraud_facts(int(uid), cs.trino)


def facts(pair: dict, q: Callable = trino, cat: Callable = catalog, hold: Callable = holds) -> dict:
    """The rule's input for one pair, every read fresh; a failed read leaves the field None."""
    f = dict(pair)
    sv, so, uid = pair["survivor"], pair["source"], int(pair["user_id"])
    ids = f"'{sv}', '{so}'"
    try:
        cl = q("SELECT profileid AS p, status, CAST(userid AS varchar) AS u, CAST(teamid AS varchar) AS t FROM "
               f"postgresql_core.public.claiming WHERE deletedat IS NULL AND profileid IN ({ids})")
        f["survivor_claims"] = [{"status": r["status"], "user_id": r.get("u"), "team_id": r.get("t")} for r in cl if r["p"] == sv]
        f["source_claims"] = [{"status": r["status"]} for r in cl if r["p"] == so]
        f["requester_teams"] = [r["t"] for r in q("SELECT CAST(teamid AS varchar) AS t FROM postgresql_core.public.team_users "
                                                  f"WHERE userid = {uid}")]
        f["source_identity"] = [r["u"] for r in q(
            "SELECT CAST(id AS varchar) AS u FROM postgresql_core.public.users WHERE CAST(neptuneprofessionalid AS varchar) = "
            f"'{so}' UNION ALL SELECT CAST(user_id AS varchar) FROM postgresql_core.public.user_identity_resolution WHERE "
            f"is_primary AND is_confirmed AND NOT is_rejected AND CAST(candidate_profile_id AS varchar) = '{so}'")]
        f["in_flight"] = bool(q("SELECT status FROM postgresql_core.public.profile_merges WHERE status IN ("
                                + ", ".join(f"'{s}'" for s in IN_FLIGHT) + f") AND (CAST(loser_profile_id AS varchar) IN ({ids}) "
                                f"OR CAST(survivor_profile_id AS varchar) IN ({ids}))"))
    except Exception:  # noqa: BLE001
        for k in ("survivor_claims", "source_claims", "requester_teams", "source_identity", "in_flight"):
            f.setdefault(k, None)
    try:
        c = cat([sv, so])
        f["survivor_profile"], f["source_profile"] = c.get(sv), c.get(so)
    except Exception:  # noqa: BLE001
        f["survivor_profile"] = f["source_profile"] = None
    try:
        f["holds"] = hold(uid)
    except Exception:  # noqa: BLE001
        f["holds"] = None
    return f


# ── execution ───────────────────────────────────────────────────────────────────────────────────

def merge_cmd(row: dict, run: str, captain: str, *, confirmer: str = CONFIRMER,
              requester: str = REQUESTER) -> list[str]:
    ref = f"user-{row['user_id']}|captain-{captain.removeprefix('captain-')}|decider-{run}|{absorb.RULING_ID}"
    return [MUSO, "--env", "prod", "profiles", "merge", "--into", row["survivor"], "--from", row["source"],
            "--requester", requester, "--yes", "--confirmed-by", confirmer, "--approval-ref", ref]


def readback(row: dict, before: dict, q: Callable, cat: Callable, sleep: Callable = time.sleep,
             budget_s: int = READBACK_S) -> tuple[bool, str]:
    sv, so = row["survivor"], row["source"]
    floor = max(int(before[sv]["credits"] or 0), int(before[so]["credits"] or 0))
    waited, last = 0, "not read"
    while waited <= budget_s:
        try:
            c = cat([sv, so])
            led = q("SELECT status FROM postgresql_core.public.profile_merges WHERE "
                    f"CAST(loser_profile_id AS varchar) = '{so}' AND CAST(survivor_profile_id AS varchar) = '{sv}'")
        except Exception as e:  # noqa: BLE001
            last = f"read failed ({type(e).__name__})"
        else:
            st = [r["status"] for r in led]
            if any(s in ("failed", "unverified") for s in st):
                return False, f"ledger {st}"
            src, sur = c.get(so) or {}, c.get(sv) or {}
            # QA #1556 (important): "done" is the LEDGER, not the catalogue. An empty profile_merges read plus a
            # redirected source and moved credits used to be reported as merged; that is an unverified outcome, and
            # only status='verified' is proof (captain's rule: a merge is done when profile_merges says verified).
            if "verified" not in st:
                last = (f"no verified ledger row yet (ledger {st or 'empty'}); source merged_to={src.get('merged_to')} "
                        f"survivor credits={sur.get('credits')} floor={floor}")
            elif str(src.get("merged_to") or "").lower() != sv or int(sur.get("credits") or 0) < floor:
                # the ledger is the authority, so this is a CONTRADICTION, not something to wait out
                return False, (f"ledger verified but the catalogue disagrees: source merged_to={src.get('merged_to')} "
                               f"survivor credits={sur.get('credits')} floor={floor}")
            else:
                return True, f"ledger verified; source forwards to survivor; survivor credits {sur.get('credits')} >= {floor}"
        sleep(POLL_S)
        waited += POLL_S
    return False, f"read-back timed out: {last}"


EVIDENCE_KEYS = ("person_name", "name_collisions", "readings", "source_raw_ids")


def kill(why: str) -> None:
    Path(KILL).parent.mkdir(parents=True, exist_ok=True)
    Path(KILL).write_text(f"merge-executor stopped {now_iso()}: {why}\n")


def run(rows: list[dict], run_id: str, apply: bool, captain: str, q: Callable = trino, cat: Callable = catalog,
        hold: Callable = holds, sh: Callable = subprocess.run, sleep: Callable = time.sleep,
        pairs: Callable = store_pairs) -> int:
    """One executor at a time (QA #1556): an exclusive flock on <state>/run.lock is held for the whole run, so the kill
    file check, the day-cap count, the reservation and the send are serialized across processes."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lock = open(STATE_DIR / "run.lock", "a+")
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(json.dumps({"event": "stopped", "reason": "another merge-executor run holds the lock"}))
        lock.close()
        return 0
    try:
        return _run(rows, run_id, apply, captain, q, cat, hold, sh, sleep, pairs)
    finally:
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        lock.close()


def _run(rows, run_id, apply, captain, q, cat, hold, sh, sleep, pairs) -> int:
    rows = sorted([r for r in rows if r.get("verdict") == "eligible"], key=lambda r: (not r.get("paid"), str(r["user_id"])))
    for row in rows:
        if os.path.exists(KILL):
            print(json.dumps({"event": "stopped", "reason": f"kill file {KILL}"}))
            return 0
        if executed_today() >= DAY_CAP:
            print(json.dumps({"event": "stopped", "reason": f"day cap {DAY_CAP} reached"}))
            return 0
        # QA #1556 (critical): the DSP evidence is re-read from the store immediately before EACH pair's decision,
        # never taken from the shadow row and never reused from an earlier row of this run (a previous merge's
        # read-back can take up to 30 min, during which a contributor link may be corrected)
        key = {"user_id": row["user_id"], "survivor": row["survivor"], "source": row["source"], "run": run_id}
        try:
            fresh_pairs = {(str(p["user_id"]), p["survivor"], p["source"]): p for p in pairs()}
        except Exception as e:  # noqa: BLE001
            print(json.dumps({"event": "stopped", "reason": f"DSP store unreadable ({type(e).__name__})"}))
            return 0
        ev = fresh_pairs.get((str(row["user_id"]), row["survivor"], row["source"]))
        if ev is None:
            ledger({"event": "evidence_gone", **key})
            print(json.dumps({"event": "skip", **key, "verdict": "unavailable", "code": "EVIDENCE_GONE"}))
            continue
        f = facts({"user_id": row["user_id"], "paid": row.get("paid"), "survivor": row["survivor"], "source": row["source"],
                   **{k: ev.get(k) for k in EVIDENCE_KEYS}}, q, cat, hold)
        v = absorb.decide(f)
        if v["verdict"] != "eligible":
            ledger({"event": "re_decided_not_eligible", **key, "verdict": v["verdict"], "code": v["code"]})
            print(json.dumps({"event": "skip", **key, "verdict": v["verdict"], "code": v["code"]}))
            continue
        cmd = merge_cmd(row, run_id, captain)
        if not apply:
            print(json.dumps({"event": "would_merge", **key, "cmd": " ".join(cmd)}))
            continue
        before = {row["survivor"]: f["survivor_profile"], row["source"]: f["source_profile"]}
        MUSO_CONFIG.mkdir(parents=True, exist_ok=True)
        with open(MUSO_CONFIG / "merge-decisions.jsonl", "a") as fh:
            fh.write(json.dumps({"run": run_id, "into": row["survivor"], "from": [row["source"]],
                                 "rule_version": absorb.RULE_VERSION}) + "\n")
        ledger({"event": "merge_sent", **key, "cmd": " ".join(cmd), "before": before})
        try:
            p = sh(cmd, capture_output=True, text=True, timeout=120)
        except Exception as e:  # noqa: BLE001  QA #1556: a timeout may have been ACCEPTED - uncertain, fail closed
            ok, why = False, f"uncertain: {type(e).__name__} running the merge (it may have been accepted)"
        else:
            if p.returncode != 0:
                ok, why = False, f"muso exit {p.returncode}: {(p.stderr or '')[-300:]}"
            else:
                ok, why = readback(row, before, q, cat, sleep)
        if not ok:
            kill(f"{row['source']} -> {row['survivor']}: {why}")
            ledger({"event": "surprise", **key, "why": why})
            print(json.dumps({"event": "surprise", **key, "why": why}))
            return 4
        ledger({"event": "merged", **key, "readback": why})
        print(json.dumps({"event": "merged", **key, "readback": why}))
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("shadow")
    s.add_argument("--out", required=True)
    r = sub.add_parser("run")
    r.add_argument("--shadow", required=True)
    r.add_argument("--apply", action="store_true")
    # The captain's approval ref is an ARGUMENT, never an environment variable: it is the signature on this run.
    r.add_argument("--captain-ref", default="", dest="captain_ref",
                   help="required with --apply, e.g. captain-1030-131x")
    a = ap.parse_args(argv)
    if os.path.exists(KILL):
        print(f"merge-executor: disabled ({KILL})")
        return 0
    if a.cmd == "shadow":
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-absorb"
        n = 0
        with open(a.out, "w") as fh:
            for pair in store_pairs():
                v = absorb.decide(facts(pair))
                fh.write(json.dumps({"run": run_id, **{k: pair[k] for k in ("user_id", "paid", "survivor", "source")},
                                     **v, **{k: pair[k] for k in ("person_name", "name_collisions", "readings", "source_raw_ids")}},
                                    default=list) + "\n")
                n += 1
        print(f"merge-executor shadow {run_id}: {n} pairs -> {a.out}")
        return 0
    rows = [json.loads(x) for x in Path(a.shadow).read_text().splitlines() if x.strip()]
    captain = (a.captain_ref or "").strip()
    if a.apply and not captain:
        print("REFUSED: --apply needs --captain-ref (<id>, e.g. captain-1030-131x)", file=sys.stderr)
        return 1
    if a.apply and not captain.startswith("captain-"):
        print("REFUSED: --captain-ref must start with captain-", file=sys.stderr)
        return 1
    runs = {r.get("run") for r in rows}
    if len(runs) != 1:
        print("REFUSED: the shadow file must hold exactly one run", file=sys.stderr)
        return 1
    return run(rows, runs.pop(), a.apply, captain or "captain-unset")


if __name__ == "__main__":
    sys.exit(main())
