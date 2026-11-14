#!/usr/bin/env python3
"""READ-ONLY collector for the 21-profile repair report (firstmate gdpr-tombstone-repair-21, 2026-11-04).

Runs ON node-8 as root (it reads the register, the ops audit log, the two hide lists via `gh`, the admin API for the
admin tombstone, and Trino for the served associations). It WRITES NOTHING: every read is a GET / SELECT / file read,
no `muso` write, no register update, no PR.

Emits one JSON object per id on stdout:

  id, deletes[]           every live `DELETE /admin/profile/<id>` in /var/log/muso-ops/audit.jsonl
                          {ts, requester, confirmed_by, approval_ref}   (approval_ref = Jan's Slack message ts)
  tombstone               the admin API's deleted-inclusive answer: {deleted_at, deleted_by, creditCount_before,
                          popularity, is_claimed, merged}   or null when the admin list does not return it.
                          The display name is deliberately NOT collected: ids only, no names
                          (scripts/gdpr_pipeline/hide_batch.py:8).
  profile_api             the public /api/w/v3/profile/<id> status (404 gone / 410 hidden)
  public_page             the canonical https://muso.ai/profile/<id> status
  register[]              every erasure_requests row carrying this id: {register_no, class, status,
                          identity_verdict, verdict, removed_outside_process, hidden_at, note}
  hidden_lists            {hdevops, pdp} membership (an id is "hidden" only when BOTH hold it)
  served_now              matvw_profile_credit rows for the id (0 = no served association left)
  served_before           tombstone creditCount (the count at delete time; the column is denormalised and survives)

Usage (from the worktree):  ssh -J root@135.148.169.37 root@10.0.0.8 'python3 -' < collect-21.py > capture.json
"""
import json
import re
import subprocess
import sys
import urllib.request

sys.path.insert(0, "/opt/hydra/scripts")

AUDIT = "/var/log/muso-ops/audit.jsonl"
STORE = "/var/lib/hydra-gdpr/erasure.sqlite"
ADMIN = "/opt/hydra/skills-all/muso-ops-admin/scripts/muso-admin-api.sh"
TRINO = "/opt/hydra/scripts/trino-query.sh"
RX = re.compile(r"/admin/profile/([0-9a-f-]{36})/?$", re.I)
PUBLIC = "https://api.muso.ai/api/w/v3/profile/"
CANON = "https://muso.ai/profile/"


def deletes():
    """Every non-dry-run DELETE /admin/profile/<id> the ops wrapper's muso-CLI audit recorded."""
    out: dict[str, list[dict]] = {}
    with open(AUDIT, errors="replace") as f:
        for line in f:
            if "admin/profile" not in line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if str(r.get("method")).upper() != "DELETE" or r.get("dry_run"):
                continue
            m = RX.search(str(r.get("path") or ""))
            if not m:
                continue
            pid = m.group(1).lower()
            rec = {"ts": r.get("ts"), "requester": r.get("requester"),
                   "confirmed_by": r.get("confirmed_by"), "approval_ref": r.get("approval_ref")}
            lst = out.setdefault(pid, [])
            if not any(x["ts"] == rec["ts"] for x in lst):     # the audit log writes a pre-write and a result row
                lst.append(rec)
    return out


def admin_get(path: str) -> dict:
    p = subprocess.run(["bash", ADMIN, "call", "GET", path], capture_output=True, text=True, timeout=120)
    try:
        return json.loads(p.stdout)
    except ValueError:
        return {}


def tombstone(pid: str) -> dict | None:
    d = admin_get(f"/admin/profile?includeDeleted=true&limit=1&ids={pid}")
    items = ((d.get("body") or {}).get("data") or {}).get("items") or []
    if not items:
        return None
    it = items[0]
    return {"creditCount_before": it.get("creditCount"),
            "popularity": it.get("popularity"), "is_claimed": it.get("isClaimed"),
            "merged": bool(it.get("merged")),
            "deleted_at": (it.get("deleted") or {}).get("date"),
            "deleted_by": (it.get("deleted") or {}).get("deletedBy")}


def status(url: str) -> int:
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except Exception:                                   # noqa: BLE001 - a network failure is UNKNOWN, not a verdict
        return -1


def register(pid: str) -> list[dict]:
    import sqlite3
    db = sqlite3.connect(f"file:{STORE}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    out = []
    for r in db.execute("SELECT * FROM erasure_requests ORDER BY register_no"):
        vd = json.loads(r["verdict_detail"] or "[]")
        for pv in vd:
            if str(pv.get("id")).lower() == pid:
                out.append({"register_no": r["register_no"], "row_key": r["row_key"], "class": r["class"],
                            "status": r["status"], "identity_verdict": r["identity_verdict"],
                            "verdict": pv.get("verdict"), "why": pv.get("why"),
                            "removed_outside_process": pv.get("verdict") in ("GONE", "ALREADY_HIDDEN")
                            or "removed outside" in str(pv.get("why") or "").lower(),
                            "hidden_at": r["hidden_at"], "note": (r["note"] or "")[:200]})
    return out


def hidden_lists() -> tuple[set, set]:
    from gdpr_pipeline import sources
    return sources.hidden_lists()


def served_now(pid: str) -> int | None:
    sql = (f"SELECT count(*) FROM postgresql_catalog.public.matvw_profile_credit "
           f"WHERE profile_id = '{pid}'")
    p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=600)
    for line in p.stdout.splitlines():
        line = line.strip().strip('"')
        if re.fullmatch(r"-?\d+", line or ""):
            return int(line)
    return None


def main() -> int:
    dl = deletes()
    ids = sorted(dl, key=lambda i: min(x["ts"] for x in dl[i]))
    hd, pdp = hidden_lists()
    for pid in ids:
        rec = {"id": pid, "deletes": sorted(dl[pid], key=lambda x: x["ts"]),
               "tombstone": tombstone(pid),
               "profile_api": status(PUBLIC + pid),
               "public_page": status(CANON + pid),
               "register": register(pid),
               "hidden_lists": {"hdevops": pid in hd, "pdp": pid in pdp},
               "served_now": served_now(pid)}
        rec["served_before"] = (rec["tombstone"] or {}).get("creditCount_before")
        print(json.dumps(rec))
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
