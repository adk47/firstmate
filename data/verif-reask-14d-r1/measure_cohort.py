#!/usr/bin/env python3
"""READ-ONLY cohort measurement for the 14-day verification reminder (lane verif-reask-14d-r1).

Run on node-8 as root. Opens every store read-only, makes ONE replica query and a paged Intercom
conversation SEARCH (no per-user reads, no writes anywhere). Prints counts only: no email, name
or contact id reaches stdout.

Cohort = users whose LAST verification ask is >= 14 days old, with no reply since, no document
on file, and a request still waiting on them in core.
"""
from __future__ import annotations

import csv
import io
import json
import os
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone

LEDGER = "/var/lib/hydra/credit-review/ledger.sqlite3"
PROOF = "/var/lib/hydra-credit-verify/proof.sqlite"
DV = "/var/lib/hydra-credit-verify/doc-verify.sqlite"
POF = "/var/lib/credit-trust/proof-on-file.json"
TRINO = "/opt/hydra/scripts/trino-query.sh"
ENV = "/etc/openclaw/main.env"
# verify_ledger.ASK_CAMPAIGNS + the out-of-tree first ask of 2026-11-09 (an ask is an ask, whoever sent it)
ASKS = ("verify-live", "retro-past", "uvn-status", "gap-ask", "proof-need-ask", "uvn-new-rows", "decider-support",
        "first-ask-1")
CLAIMS = ("claim-proof-ask", "claim-status", "claim-proof-pending")
MIN_AGE_DAYS = int(os.environ.get("REASK_MIN_AGE_DAYS", "14"))
NOW = datetime.now(timezone.utc)
TODAY = NOW.strftime("%Y-%m-%d")
CUTOFF = (NOW - timedelta(days=MIN_AGE_DAYS)).strftime("%Y-%m-%d")
WEEK = (NOW - timedelta(days=7)).strftime("%Y-%m-%d")


def ro(path: str) -> sqlite3.Connection:
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    return db


def epoch(s: str) -> float:
    s = str(s or "").strip().replace(" UTC", "").replace(" ", "T").rstrip("Z")[:19]
    if len(s) < 19:
        return 0.0
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()


def trino(sql: str) -> list[list[str]]:
    p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=300, check=False)
    if p.returncode:
        raise SystemExit(f"replica read failed rc={p.returncode}: {p.stderr.strip()[-200:]}")
    return list(csv.reader(io.StringIO("\n".join(ln for ln in p.stdout.splitlines() if ln.startswith('"')))))


def token() -> str:
    for line in open(ENV, encoding="utf-8"):
        line = line.strip()
        if line.startswith("export "):
            line = line[7:]
        if line.startswith("MUSOAI_INTERCOM_TOKEN="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit("no Intercom token in the env file")


def intercom_search(tok: str, query: dict) -> list[dict]:
    out: list[dict] = []
    after = None
    while True:
        body: dict = {"query": query, "pagination": {"per_page": 150}}
        if after:
            body["pagination"]["starting_after"] = after
        for attempt in range(5):
            req = urllib.request.Request("https://api.intercom.io/conversations/search", data=json.dumps(body).encode(),
                                         method="POST", headers={"Authorization": f"Bearer {tok}",
                                                                 "Accept": "application/json",
                                                                 "Content-Type": "application/json",
                                                                 "Intercom-Version": "2.11"})
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    res = json.load(r)
                break
            except urllib.error.HTTPError as exc:
                if exc.code == 429 and attempt < 4:
                    time.sleep(5 * (attempt + 1))
                    continue
                raise SystemExit(f"Intercom search -> {exc.code}")
        else:
            raise SystemExit("Intercom rate-limited")
        convs = res.get("conversations")
        if not isinstance(convs, list):
            raise SystemExit("Intercom search unreadable")
        out.extend(convs)
        after = ((res.get("pages") or {}).get("next") or {}).get("starting_after")
        if not after or not convs:
            return out


def main() -> int:
    led = ro(LEDGER)
    marks = ",".join("?" * len(ASKS))
    # ---- 1. the ledger: every user's asks ------------------------------------------------------------------------
    users: dict[str, dict] = {}
    for r in led.execute(f"SELECT account_id, user_key, day, coalesce(sent_at, created_at) AS at, contact_id, campaign, "
                         f"request_ids_json FROM verify_messages WHERE kind='initial' AND status IN ('sent','attempted') "
                         f"AND campaign IN ({marks})", ASKS):
        uid = str(r["account_id"] or "").strip()
        if not uid.isdigit():
            continue
        u = users.setdefault(uid, {"last_day": "", "last_at": 0.0, "keys": set(), "contacts": set(), "reqs": set(),
                                   "last_campaign": "", "n_asks": 0})
        u["n_asks"] += 1
        u["keys"].add(r["user_key"])
        if r["contact_id"]:
            u["contacts"].add(str(r["contact_id"]))
        try:
            u["reqs"].update(str(x).lower() for x in json.loads(r["request_ids_json"] or "[]"))
        except ValueError:
            pass
        if str(r["day"]) > u["last_day"]:
            u["last_day"], u["last_campaign"] = str(r["day"]), r["campaign"]
        u["last_at"] = max(u["last_at"], epoch(r["at"]))
    print(f"measured_at={NOW.strftime('%Y-%m-%dT%H:%M:%SZ')} today={TODAY} cutoff_day<={CUTOFF} (>= {MIN_AGE_DAYS} d)")
    print(f"users ever asked (account id known): {len(users)}")
    age = Counter()
    for u in users.values():
        d = (datetime.fromisoformat(TODAY) - datetime.fromisoformat(u["last_day"])).days
        age["30+" if d >= 30 else "14-29" if d >= 14 else "7-13" if d >= 7 else "0-6"] += 1
    print("last ask age (days):", dict(sorted(age.items())))
    cand = {uid: u for uid, u in users.items() if u["last_day"] <= CUTOFF}
    print(f"A. last ask >= {MIN_AGE_DAYS} d old: {len(cand)}  by last campaign: {dict(Counter(u['last_campaign'] for u in cand.values()))}")
    key2uid: dict[str, str] = {}
    for uid, u in users.items():
        for k in u["keys"]:
            key2uid[k] = uid

    # ---- 2. every other ledger row of those users: replies, proof tags, reminders, the last 7 days --------------
    replied_led, tagged_led, msg7, reminded, other_ask_recent = set(), set(), set(), set(), set()
    for r in led.execute("SELECT account_id, user_key, campaign, kind, status, day, proof_tagged_at, last_reply_at, "
                         "extension_requested_at FROM verify_messages"):
        uid = str(r["account_id"] or "").strip() or key2uid.get(r["user_key"], "")
        if uid not in cand:
            continue
        if r["campaign"] not in CLAIMS:
            if r["proof_tagged_at"]:
                tagged_led.add(uid)
            if r["last_reply_at"] or r["extension_requested_at"]:
                replied_led.add(uid)
        if r["status"] in ("sent", "attempted"):
            if str(r["day"]) >= WEEK:
                msg7.add(uid)
            if r["kind"] != "initial" and (r["campaign"] in ASKS or r["campaign"].startswith("reminder")):
                reminded.add(uid)
    print(f"   of A: ledger proof-tagged {len(tagged_led)}, ledger reply recorded {len(replied_led)}, "
          f"already sent a reminder (any follow-up kind, incl. the 2026-11-09 reminder-1) {len(reminded)}, "
          f"any note from us in the last 7 days {len(msg7)}")

    # ---- 3. documents on file -----------------------------------------------------------------------------------
    docs_intake, docs_dv, docs_pof = set(), set(), defaultdict(set)
    pdb = ro(PROOF)
    for (u,) in pdb.execute("SELECT DISTINCT user_id FROM proof_intake WHERE subject <> 'claim'"):
        if str(u) in cand:
            docs_intake.add(str(u))
    for (u,) in ro(DV).execute("SELECT DISTINCT user_id FROM dv_outcomes"):
        if str(u) in cand:
            docs_dv.add(str(u))
    pof = json.load(open(POF, encoding="utf-8"))
    for e in pof.get("entries") or []:
        u = str(e.get("user_id"))
        if u in cand:
            docs_pof[str(e.get("source") or "?")].add(u)
    pof_any = set().union(*docs_pof.values()) if docs_pof else set()
    print(f"   of A: proof_intake {len(docs_intake)}, dv_outcomes {len(docs_dv)}, proof-on-file {len(pof_any)} "
          f"({ {k: len(v) for k, v in sorted(docs_pof.items())} }; generated {pof.get('generated_at')})")
    has_doc = docs_intake | docs_dv | pof_any | tagged_led

    # ---- 4. core: a request still waiting on the user ------------------------------------------------------------
    ids = sorted(cand, key=int)
    open_reqs: dict[str, set[str]] = defaultdict(set)
    statuses = Counter()
    for i in range(0, len(ids), 1000):
        chunk = ",".join(ids[i:i + 1000])
        for row in trino("SELECT CAST(userid AS varchar), lower(CAST(id AS varchar)), status "
                         "FROM postgresql_core.public.credit_requests WHERE deletedat IS NULL "
                         f"AND status IN ('user_verification_needed','unverified') AND userid IN ({chunk})"):
            if len(row) != 3:
                raise SystemExit("unexpected replica row shape")
            statuses[row[2]] += 1
            if row[2] == "user_verification_needed":
                open_reqs[row[0]].add(row[1])
    has_open = {u for u in cand if open_reqs.get(u)}
    asked_open = {u for u in has_open if open_reqs[u] & cand[u]["reqs"]}
    print(f"   of A: a request still user_verification_needed in core {len(has_open)} "
          f"(one the ask NAMED still open: {len(asked_open)}); open rows by status {dict(statuses)}")

    # ---- 5. Intercom: did the contact write to us after the ask? -------------------------------------------------
    tok = token()
    since = int(min(u["last_at"] for u in cand.values() if u["last_at"]) if cand else time.time())
    contact_reply: dict[str, float] = defaultdict(float)
    c1 = intercom_search(tok, {"field": "statistics.last_contact_reply_at", "operator": ">", "value": since})
    for c in c1:
        at = float((c.get("statistics") or {}).get("last_contact_reply_at") or 0)
        for k in ((c.get("contacts") or {}).get("contacts") or []):
            contact_reply[str(k.get("id"))] = max(contact_reply[str(k.get("id"))], at)
    c2 = intercom_search(tok, {"operator": "AND", "value": [
        {"field": "created_at", "operator": ">", "value": since},
        {"field": "source.author.type", "operator": "!=", "value": "admin"}]})
    for c in c2:
        if ((c.get("source") or {}).get("author") or {}).get("type") in ("user", "lead", "contact"):
            at = float(c.get("created_at") or 0)
            for k in ((c.get("contacts") or {}).get("contacts") or []):
                contact_reply[str(k.get("id"))] = max(contact_reply[str(k.get("id"))], at)
    print(f"   Intercom: {len(c1)} conversations with a contact reply and {len(c2)} contact-opened conversations since "
          f"{datetime.fromtimestamp(since, timezone.utc).strftime('%Y-%m-%d')}; {len(contact_reply)} contacts wrote")
    no_contact = {u for u, v in cand.items() if not v["contacts"]}
    replied_ic = {u for u, v in cand.items()
                  if any(contact_reply.get(c, 0) > v["last_at"] for c in v["contacts"])}
    print(f"   of A: wrote to us in Intercom after their last ask {len(replied_ic)}; no Intercom contact on the "
          f"ledger row (reply unreadable here) {len(no_contact)}")

    # ---- the cohort ---------------------------------------------------------------------------------------------
    responders = replied_led | replied_ic
    step = set(cand)
    print("FUNNEL")
    for label, drop in (("no request waiting on them in core", set(cand) - has_open),
                        ("document on file (intake / doc-verify / proof-on-file / ledger proof tag)", has_doc),
                        ("replied since the ask (ledger or Intercom)", responders),
                        ("Intercom contact unknown (cannot prove no reply)", no_contact)):
        before = len(step)
        step -= drop
        print(f"   - {label}: -{before - len(step)} -> {len(step)}")
    print(f"COHORT (last ask >= {MIN_AGE_DAYS} d, open request, no document, no reply): {len(step)}")
    named = step & asked_open
    print(f"   of which a request the ask NAMED is still open: {len(named)}")
    print(f"   of which never reminded: {len(step - reminded)}  (already got the 2026-11-09 reminder-1 or another follow-up: {len(step & reminded)})")
    print(f"   of which never reminded AND no note from us in 7 days (sendable today before the gate's own per-user re-read): "
          f"{len(step - reminded - msg7)}")
    print(f"   cohort by last-ask day: {dict(sorted(Counter(cand[u]['last_day'] for u in step).items()))}")
    print(f"   cohort by last-ask campaign: {dict(Counter(cand[u]['last_campaign'] for u in step))}")
    # what PR uvn-reminder-14 makes askable: the cohort members whose last ask is a uvn-status ask (the copy reminds of
    # that ask; a gap-ask or verify-live ask asked for something else), with a request that ask NAMED still waiting
    uvn = {u for u in step if cand[u]["last_campaign"] == "uvn-status"}
    print(f"UVN-REMINDER-14 AUDIENCE (cohort, last ask = uvn-status): {len(uvn)}")
    print(f"   a request the ask named still open: {len(uvn & asked_open)}")
    print(f"   ... and never reminded by any sender: {len((uvn & asked_open) - reminded)}")
    print(f"   ... and no note from us in the last 7 days (first-day audience): {len((uvn & asked_open) - reminded - msg7)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
