#!/usr/bin/env python3
"""Join 90 days of profile removals (admin soft-delete + hide list) to claims and the GDPR register.

Read-only: it reads the dumps `pull.sh` wrote into a work directory and writes two files.

    build_audit.py WORKDIR OUTDIR

  WORKDIR/audit_full.json   every row with profile names and requester addresses. Never commit it.
  OUTDIR/audit.csv          the same rows with ids only: no name, no address (a requester is a 10-hex hash).

What "the requester owns the profile" means here, strongest first:
  claim_account   the register's own code decided PASS_A for this page: the requesting ACCOUNT holds a processed claim
  claim_email     the address on the request equals the address of a team holding a processed claim on the page
  (nothing)       neither. This is NOT proof the requester is someone else: one person can write from two addresses.
"""
import collections
import csv
import hashlib
import json
import re
import sys
import unicodedata

FREEMAIL = {"gmail.com", "googlemail.com", "yahoo.com", "hotmail.com", "outlook.com", "icloud.com",
            "me.com", "aol.com", "proton.me", "protonmail.com", "live.com", "msn.com", "gmx.de",
            "gmx.net", "web.de", "mail.com", "yandex.ru", "mail.ru", "hotmail.co.uk", "yahoo.co.uk",
            "hotmail.fr", "yahoo.fr", "ymail.com", "pm.me", "tutanota.com", "duck.com"}
BURST = 3           # more than this many profiles by one actor in one UTC day, or by one requester in the window
KNOWN = 40          # catalog popularity from which a free-mail requester is worth a second look
NOT_A_DECISION = ("ALREADY_HIDDEN", "GONE", "HIDDEN_PENDING")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f-]{27}")
J = lambda s: json.loads(s) if s else None


def sections(path):
    out, cur = {}, None
    for line in open(path).read().splitlines():
        if line.startswith("-- "):
            cur = line[3:]
            out[cur] = []
        elif cur and line:
            if line.startswith("Query ") and " failed" in line:
                raise SystemExit(f"{path}: section {cur!r} is a failed query, not data")
            out[cur].append(line)
    return {k: list(csv.reader(v)) for k, v in out.items()}


def squash(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]", "", s)


def words(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return set(re.findall(r"[a-z0-9]{2,}", s))


def name_match(requester_name, email, profile_name):
    """A coarse text test, for sorting rows. It never proves or disproves that two names are one person."""
    p = words(profile_name)
    if not p:
        return "unknown"
    r = words(requester_name)
    if r and (p <= r or r <= p):
        return "match"
    local, joined = squash((email or "").split("@")[0]), squash(profile_name)
    if len(local) >= 4 and joined and (joined in local or local in joined):
        return "email_local_part"
    if r and (p & r):
        return "partial"
    return "no_match" if r or email else "unknown"


def h(s):
    return hashlib.sha256((s or "").lower().encode()).hexdigest()[:10] if s else ""


def build(work):
    reg = json.load(open(f"{work}/register.json"))
    e1 = sections(f"{work}/deletes_enrich2.txt")
    e2 = sections(f"{work}/hides_enrich.txt")
    team_email = {r[0]: r[1] for r in e1["teams"]}

    profile = {}
    for r in e1["matview"] + e2["matview"]:
        profile[r[0]] = {"name": r[1], "type": r[2], "popularity": int(r[3] or 0), "credits": int(r[4] or 0),
                         "is_deleted_now": r[5] == "true", "merged_to": r[6]}
    pro = {r[0] for r in e1["pro"] + e2["pro"]}
    claims = collections.defaultdict(list)
    for r in csv.reader(open(f"{work}/deletes_claims.csv")):
        claims[r[0]].append({"claim_id": r[1], "status": r[2], "created": r[5][:19], "updated": r[6][:19],
                             "email": team_email.get(r[4], "")})
    for r in e2["claims"]:
        claims[r[0]].append({"claim_id": r[1], "status": r[2], "created": r[5][:19], "updated": r[6][:19],
                             "email": r[7]})

    deletes = collections.defaultdict(list)
    for r in csv.reader(open(f"{work}/profile_deletes.csv")):
        deletes[UUID.search(r[8]).group(0)].append(
            {"at": r[1][:19], "email": r[2], "requestedby": r[3], "approvedby": r[4], "executedby": r[5],
             "service": r[6], "requestref": r[7]})

    decides = collections.defaultdict(list)
    for e in reg["events"]:
        if e["kind"] == "decide":
            decides[str(e["request_id"])].append(e)
    by_page = collections.defaultdict(list)
    for r in reg["requests"]:
        hidden = set(J(r["hidden_pages"]) or [])
        gone = set(J(r["removed_outside_process"]) or [])
        batched = {i for b in (J(r["hide_pr"]) or {}).get("batches", []) for i in b.get("ids", [])}
        for p in J(r["pages"]) or []:
            if p["entity"] == "profile":
                by_page[p["id"]].append({"req": r, "hidden": p["id"] in hidden, "gone": p["id"] in gone,
                                         "batched": p["id"] in batched})

    def verdicts(req, pid):
        """[(at, verdict)] of every decision on this page that says something about identity, oldest first."""
        out = []
        for e in sorted(decides[str(req["id"])], key=lambda x: x["at"]):
            vd = (J(e["detail"]) or {}).get("verdict_detail")
            vd = J(vd) if isinstance(vd, str) else vd
            out += [(e["at"], v["verdict"]) for v in vd or []
                    if v.get("id") == pid and v.get("verdict") not in NOT_A_DECISION]
        return out

    rows = []
    for pid in sorted(set(deletes) | set(by_page)):
        regs = by_page.get(pid, [])
        dl = sorted(deletes.get(pid, []), key=lambda x: x["at"])
        hidden_rows = [x for x in regs if x["hidden"]]
        paths = (["admin_soft_delete"] if dl else []) + (["hide_list"] if hidden_rows else [])
        if not paths and any(x["gone"] for x in regs):
            paths = ["gone_no_actor_on_record"]
        if not paths and any(x["batched"] for x in regs):
            paths = ["in_open_hide_pr_not_hidden"]
        if not paths:
            continue
        pr = profile.get(pid, {})
        cl = claims.get(pid, [])
        processed = [c for c in cl if c["status"] == "processed"]
        hidden_at = min((x["req"]["hidden_at"] for x in hidden_rows if x["req"]["hidden_at"]), default="")
        removed_at = dl[0]["at"] if dl else hidden_at[:19].replace("T", " ")
        reqs = []
        for x in regs:
            q = x["req"]
            em = (q["requester_email"] or "").lower()
            dom = em.split("@")[-1] if "@" in em else ""
            vs = verdicts(q, pid)
            cut = (removed_at or "9999").replace(" ", "T") + "Z"
            before = [v for at, v in vs if at <= cut]
            proof = ("claim_account" if any(v == "PASS_A" for _, v in vs)
                     else "claim_email" if em and any(c["email"].lower() == em for c in processed) else "")
            reqs.append({
                "register_no": q["register_no"], "class": q["class"], "channel": q["channel"],
                "received": (q["received_at"] or "")[:10], "requester_email": em, "requester_hash": h(em),
                "requester_domain_kind": "freemail" if dom in FREEMAIL else ("none" if not dom else "own_domain"),
                "requester_name": q["requester_name"] or "", "contact_id": q["contact_id"] or "",
                "conversation_id": q["conversation_id"] or "",
                "verdict_when_removed": before[-1] if before else "",
                "verdict_today": vs[-1][1] if vs else "",
                "owner_proof": proof,
                "name_match": name_match(q["requester_name"], em, pr.get("name", "")),
                "hide_pr": [b.get("hdevops") for b in (J(q["hide_pr"]) or {}).get("batches", [])
                            if pid in b.get("ids", [])],
            })
        owner = any(q["owner_proof"] for q in reqs)
        legal = any(q["class"] in ("legal_threat", "dmca_takedown") for q in reqs)
        named = any(q["name_match"] in ("match", "partial", "email_local_part")
                    or q["verdict_when_removed"] in ("PASS_B", "PASS_C") for q in reqs)
        basis = ("no_request_on_record" if not reqs else "owner_verified" if owner
                 else "legal_or_dmca_no_approver_on_record" if legal
                 else "name_only" if named else "no_tie_on_record")
        flags = []
        if processed and not owner:
            flags.append("CLAIMED_REMOVED_WITHOUT_OWNER_PROOF")
        if reqs and processed and not owner:
            flags.append("REQUESTER_IS_NOT_THE_CLAIM_HOLDER_ON_RECORD")
        if reqs and not owner and pr.get("popularity", 0) >= KNOWN \
                and all(q["requester_domain_kind"] == "freemail" for q in reqs):
            flags.append("FREEMAIL_VS_KNOWN_ARTIST")
        if pid in pro:
            flags.append("PAID_PROFILE")
        undo = []
        if "admin_soft_delete" in paths:
            undo.append("undelete the muso raw profile and re-sync (entity_deletion.md, Entity Restoration; "
                        "written for the Mongo collections, confirm against the current catalog first)")
        if "hide_list" in paths:
            undo.append("remove the id from HIDDEN_ENTITY_IDS (H-DevOps) and LEGAL_HIDDEN_ENTITY_IDS (PDP), one PR each")
        if paths == ["gone_no_actor_on_record"]:
            undo.append("no actor in action_log (90 d): find who deleted it before any restore")
        if paths == ["in_open_hide_pr_not_hidden"]:
            undo.append("nothing to restore: drop the id from the open hide PR")
        rows.append({"profile_id": pid, **pr, "paid": pid in pro, "paths": paths, "removed_at": removed_at,
                     "basis": basis, "deletes": dl, "claims": cl, "requests": reqs, "flags": flags, "undo": undo})

    day = collections.defaultdict(set)
    for x in rows:
        for d in x["deletes"][:1]:
            day[(d["at"][:10], d["requestedby"] or d["email"], d["service"])].add(x["profile_id"])
    hide_day = collections.Counter(x["removed_at"][:10] for x in rows if x["paths"] == ["hide_list"])
    bursts = {k: sorted(v) for k, v in day.items() if len(v) > BURST}
    for x in rows:
        for d in x["deletes"][:1]:
            if (d["at"][:10], d["requestedby"] or d["email"], d["service"]) in bursts:
                x["flags"].append("BURST_DAY")
    by_req = collections.defaultdict(set)
    for x in rows:
        for q in x["requests"]:
            if q["requester_email"]:
                by_req[q["requester_email"]].add(x["profile_id"])
    multi = {k: sorted(v) for k, v in by_req.items() if len(v) > BURST}
    names = {x["profile_id"]: x.get("name", "") for x in rows}
    for x in rows:
        if any(q["requester_email"] in multi for q in x["requests"]):
            x["flags"].append("REQUESTER_REMOVED_MORE_THAN_3")
    return {"rows": rows,
            "bursts": [{"day": k[0], "actor": k[1], "service": k[2], "n": len(v), "profiles": v}
                       for k, v in sorted(bursts.items())],
            "hide_list_days": dict(sorted(hide_day.items())),
            "multi_requesters": [{"requester_hash": h(k), "requester_email": k, "n": len(v),
                                  "distinct_names": len({squash(names[i]) for i in v}),
                                  "names": sorted({names[i] for i in v}), "profiles": v}
                                 for k, v in sorted(multi.items(), key=lambda kv: -len(kv[1]))]}


COLS = ["profile_id", "type", "popularity", "credits", "paid", "is_deleted_now", "paths", "removed_at", "actor",
        "service", "executed_by", "basis", "processed_claims", "other_claims", "requests", "register_nos",
        "request_classes", "requester_hashes", "requester_domain_kinds", "owner_proof", "name_match",
        "verdict_when_removed", "verdict_today", "flags", "undo"]


def flat(x):
    d = x["deletes"][0] if x["deletes"] else {}
    q = x["requests"]
    j = lambda vals: ";".join(dict.fromkeys(str(v) for v in vals if v != ""))
    return {
        "profile_id": x["profile_id"], "type": x.get("type", ""), "popularity": x.get("popularity", ""),
        "credits": x.get("credits", ""), "paid": x["paid"], "is_deleted_now": x.get("is_deleted_now", ""),
        "paths": "+".join(x["paths"]), "removed_at": x["removed_at"],
        "actor": d.get("requestedby") or d.get("email", ""), "service": d.get("service", ""),
        "executed_by": d.get("executedby", ""), "basis": x["basis"],
        "processed_claims": sum(1 for c in x["claims"] if c["status"] == "processed"),
        "other_claims": j(c["status"] for c in x["claims"] if c["status"] != "processed"),
        "requests": len(q), "register_nos": j(r["register_no"] for r in q),
        "request_classes": j(r["class"] for r in q), "requester_hashes": j(r["requester_hash"] for r in q),
        "requester_domain_kinds": j(r["requester_domain_kind"] for r in q),
        "owner_proof": j(r["owner_proof"] for r in q), "name_match": j(r["name_match"] for r in q),
        "verdict_when_removed": j(r["verdict_when_removed"] for r in q),
        "verdict_today": j(r["verdict_today"] for r in q), "flags": j(x["flags"]), "undo": " | ".join(x["undo"]),
    }


def totals(a):
    C, R = collections.Counter, a["rows"]
    done = [x for x in R if x["paths"] != ["in_open_hide_pr_not_hidden"]]
    sd = [x for x in done if "admin_soft_delete" in x["paths"]]
    out = [
        ("profiles removed, 90 d, merges excluded", len(done)),
        ("  by path", dict(C("+".join(x["paths"]) for x in done))),
        ("  by basis on record", dict(C(x["basis"] for x in done))),
        ("  basis x path", dict(C((x["basis"], "+".join(x["paths"])) for x in done))),
        ("  with a processed claim", sum(1 for x in done if any(c["status"] == "processed" for c in x["claims"]))),
        ("  paid", sum(1 for x in done if x["paid"])),
        ("  flags", dict(C(f for x in done for f in x["flags"]))),
        ("  owner proof kind", dict(C(q["owner_proof"] or "none" for x in done for q in x["requests"][:1]))),
        ("  still deleted in the catalog now", sum(1 for x in done if x.get("is_deleted_now"))),
        ("admin soft-deletes", len(sd)),
        ("  recorded request ref in action_log", sum(1 for x in sd if any(d["requestref"] for d in x["deletes"]))),
        ("  by actor/service", dict(C(((x["deletes"][0]["requestedby"] or x["deletes"][0]["email"]),
                                       x["deletes"][0]["service"]) for x in sd))),
        ("  last 30 d (from 2026-10-14)", sum(1 for x in sd if x["removed_at"] >= "2026-10-14")),
        ("actor-days over 3 soft-deletes", [(b["day"], b["actor"], b["service"], b["n"]) for b in a["bursts"]]),
        ("hide-list hides per day", a["hide_list_days"]),
        ("requesters with more than 3 profiles", [(m["requester_hash"], m["n"], m["distinct_names"])
                                                  for m in a["multi_requesters"]]),
        ("in an open hide PR, not hidden yet", len(R) - len(done)),
    ]
    return out


if __name__ == "__main__":
    work, out = sys.argv[1], sys.argv[2]
    a = build(work)
    json.dump(a, open(f"{work}/audit_full.json", "w"), indent=1)
    with open(f"{out}/audit.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        w.writeheader()
        for x in a["rows"]:
            w.writerow(flat(x))
    for k, v in totals(a):
        print(f"{k}: {v}")
