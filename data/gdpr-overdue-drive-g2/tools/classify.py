#!/usr/bin/env python3
"""What each past-date statutory request is owed, and what holds each request with no first message.

Read-only, and meant to be run on node-8 from another host:

    ssh root@<node-8> python3 - < data/gdpr-overdue-drive-g2/tools/classify.py > classify.json

It takes the past-date and no-first-message sets from the pipeline's own clock (`gdpr-pipeline.py dsar clock
--json`), joins the register through a read-only SQLite handle, and prints counts and register numbers only: no
name, address, link or message text leaves the host.
"""
import collections
import json
import sqlite3
import subprocess
import sys

ROOT = "/opt/hydra"
STORE = "/var/lib/hydra-gdpr/erasure.sqlite"
NEW_THREAD = "can only be answered by opening a new mail thread"


def route_of(r: dict) -> str:
    if (r["conversation_id"] or "").strip():
        return "intercom"
    has_addr = bool((r["requester_email"] or "").strip())
    if r["channel"] in ("notices", "legal"):
        return "new mail thread" if has_addr else "no address on file"
    if (r["gmail_thread"] or "").strip():
        return "mail thread"
    return "no thread (address on file)" if has_addr else "no thread and no address"


def oldest_open(clock: dict) -> dict:
    """The oldest open request as the clock names it, with the send ledger's free text reduced to the kind and state
    it starts with: that detail is the writer's own words and can name an address or a target."""
    out = dict(clock["oldest_open"] or {})
    held = (out.get("held") or "").strip()
    out["held"] = held.split(":", 1)[0].strip() if held else ""
    return out


def owed(r: dict, need: str, written: bool) -> str:
    cls, verdict = r["class"], r["identity_verdict"] or ""
    if cls == "privacy_access":
        if need not in ("none", ""):
            return "access: the account is not established yet (identity step first)"
        return "access: the copy of their data (cannot be built: the Art. 15 manifest has standing gaps)"
    if need == "none":
        if verdict == "GONE":
            return "erasure: the page is already off the site; the final letter for that case has no approved wording"
        return "erasure: hidden or in the hide batch; the final confirmation is owed once the checks read hidden"
    if need == "unknown":
        return "erasure: identity not decided (the thread has to be read, or a person's review)"
    who = "the requester (we asked)" if written else "Muso (nothing has reached them)"
    what = {"link": "the page link", "claim_or_authority": "a claim or proof of authority",
            "authority": "proof of authority", "account": "the account"}.get(need, need)
    return f"erasure: {what} is needed; the wait is on {who}"


def main() -> int:
    clock = json.loads(subprocess.run([sys.executable, f"{ROOT}/scripts/gdpr-pipeline.py", "dsar", "clock", "--json"],
                                      capture_output=True, text=True, timeout=120, check=True).stdout)
    db = sqlite3.connect(f"file:{STORE}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    rows = {r["register_no"]: dict(r) for r in db.execute("SELECT * FROM erasure_requests")}
    sends = collections.defaultdict(list)
    for s in db.execute("SELECT request_id, kind, state, detail FROM erasure_sends"):
        sends[s["request_id"]].append(dict(s))
    msgs = collections.defaultdict(list)
    for m in db.execute("SELECT request_id, slot, state, gate_result FROM dsar_messages"):
        msgs[m["request_id"]].append(dict(m))

    past = [a for a in clock["alarm"] if a["days_left"] < 0]
    by_owed, by_route = collections.defaultdict(list), collections.defaultdict(list)
    for a in past:
        r = rows[a["register_no"]]
        written = any(s["state"] == "sent" for s in sends[r["id"]])
        by_owed[owed(r, a.get("need") or "", written)].append(a["register_no"])
        by_route[route_of(r)].append(a["register_no"])

    no_first = collections.defaultdict(list)
    for no in clock["no_first_message"]:        # register numbers
        r = rows[no]
        ss, mm = sends[r["id"]], msgs[r["id"]]
        if any(s["state"] in ("unknown", "sending") for s in ss):
            why = "a letter may be out (send unknown): a person reconciles it"
        elif any(s["state"] == "refused" and NEW_THREAD in (s["detail"] or "") for s in ss):
            why = "new mail thread: the ladder letter was refused as unreviewed (fixed by this change)"
        elif route_of(r).startswith("no "):
            why = route_of(r)
        elif any(m["state"] == "held" for m in mm):
            why = "letter authored, waiting for the copy review"
        elif not mm:
            why = "no letter authored for it"
        else:
            why = "other"
        no_first[why].append(no)

    def table(d):
        return {k: {"n": len(v), "register_nos": sorted(v)} for k, v in sorted(d.items(), key=lambda x: -len(x[1]))}
    json.dump({"at": clock["at"], "open": clock["open"], "past_due": clock["past_due"],
               "due_within_window": clock["due_within_window"], "no_first_message": len(clock["no_first_message"]),
               "first_reply_overdue": len(clock["first_reply_overdue"]), "oldest_open": oldest_open(clock),
               "past_by_what_is_owed": table(by_owed), "past_by_route": table(by_route),
               "no_first_message_by_cause": table(no_first)}, sys.stdout, indent=1)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
