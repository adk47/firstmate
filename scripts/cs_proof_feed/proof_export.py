#!/usr/bin/env python3
"""Export the proof-on-file scan to credit-system's input (firstmate 715). READ-ONLY on all sources.

Reads OUT/intercom-proof.jsonl (proof-scan.py) [+ OUT/gmail-proof.jsonl if present], resolves
Intercom contact -> email -> core user id (read-only replica), and writes credit-system's format:
  {generated_at, entries:[{user_id:int, request_id:null, kind, source, ref}]}
kind: 'pending_doc' by default; 'human_approved_after_doc' when a human teammate replied in that
conversation (we cannot see per-credit approval, so this is a hint, not a verdict; over-includes).
Emails are only used in memory for the join; the output and caches hold ids only
(the contact->email cache stores a salted hash, never the email).

Request-level links (firstmate 1003, documentation-readiness gap 3): when an Intercom conversation is
the customer's reply to one of OUR notes (Caroline's send ledger, node-8 credit-review ledger.sqlite3
verify_messages: message_id -> request_ids), every proof part posted after that note also yields one
entry per request id ({request_id: <id>, via: 'verify_messages:<campaign>:<message_id>'}), so the
document lands on the requests it proves. The whole-user entry (request_id null) is KEPT: consumers
read a null entry as 'matches every row of the user', so dropping it would narrow the do-not-ask
exclusion. Linking fails closed: if the ledger or a conversation cannot be read, no request entry is
emitted for it (the whole-user entry still is).

Installs atomically: write <target>.tmp-<pid> next to the target, re-read it as JSON, then rename over
/var/lib/credit-trust/inputs/cs-proofs.json (the credit-trust decider's input).

Runs on node-8 from scripts/cs-proof-feed.sh (moved off the captain's Mac 2026-10-26, ops-to-ovh-m1;
originally cs-systemic-issues-lane-c1 scripts/cs-systemic/proof-export.py @2b37ceb338). The only
changes: the ledger is read locally (sqlite, read-only URI) instead of over ssh, the contact -> user
join goes through the Trino postgresql_core passthrough (replica.py) instead of psql on node-1, and the
install is a local rename instead of scp + ssh.
Usage: MUSOAI_INTERCOM_TOKEN=... proof_export.py OUT_DIR [--no-install]
"""
import calendar, json, os, sqlite3, sys, time, urllib.request, urllib.error, concurrent.futures as cf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import replica  # noqa: E402

TARGET = os.environ.get("CS_PROOF_TARGET", "/var/lib/credit-trust/inputs/cs-proofs.json")
LEDGER_DB = os.environ.get("CS_PROOF_LEDGER_DB", "/var/lib/hydra/credit-review/ledger.sqlite3")


def _epoch(iso):
    try:
        return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        return None


def request_links(recs, ledger, conv_source):
    """Map (conv, part) -> [(request_id, via)] for proof parts that answer one of our ledger notes.

    recs: intercom-proof records {conv, part, created (epoch str/int), contact}.
    ledger: verify_messages rows {message_id, conversation_id, contact_id, request_ids_json, created_at, campaign}.
    conv_source: conv id -> the conversation's source (first message) id; a conv missing here is unknown.
    A part links to a note only when the conversation IS that note's thread (its source id is the note's
    message id, or the ledger recorded that conversation id), the contact matches, and the part was
    posted at or after the note was sent.
    """
    by_msg, by_conv = {}, {}
    for row in ledger:
        try:
            rids = [str(x) for x in json.loads(row.get("request_ids_json") or "[]") if x]
        except ValueError:
            continue
        sent = _epoch(row.get("created_at") or "")
        if not rids or sent is None:
            continue
        note = (rids, sent, str(row.get("contact_id") or ""), f"verify_messages:{row.get('campaign')}:{row.get('message_id')}")
        if row.get("message_id"):
            by_msg.setdefault(str(row["message_id"]), []).append(note)
        if row.get("conversation_id"):
            by_conv.setdefault(str(row["conversation_id"]), []).append(note)
    out = {}
    for r in recs:
        conv = str(r.get("conv") or "")
        notes = list(by_conv.get(conv, []))
        src = conv_source.get(conv)
        if src:
            notes += by_msg.get(str(src), [])
        try:
            created = int(r.get("created"))
        except (TypeError, ValueError):
            continue
        links = []
        for rids, sent, contact, via in notes:
            if contact and contact != str(r.get("contact") or ""):
                continue
            if created < sent:
                continue
            links += [(rid, via) for rid in rids]
        if links:
            out[(conv, str(r.get("part")))] = sorted(set(links))
    return out


H = {"Authorization": "Bearer " + os.environ.get("MUSOAI_INTERCOM_TOKEN", ""), "Intercom-Version": "2.11", "Accept": "application/json"}


def read_ledger(db=None):
    """Caroline's send ledger rows (sent notes only), opened read-only. None = could not read (fail closed)."""
    q = ("SELECT message_id, conversation_id, contact_id, request_ids_json, created_at, campaign "
         "FROM verify_messages WHERE status='sent' AND request_ids_json IS NOT NULL")
    try:
        con = sqlite3.connect(f"file:{db or LEDGER_DB}?mode=ro", uri=True, timeout=30)
        try:
            con.row_factory = sqlite3.Row
            return [dict(r) for r in con.execute(q)]
        finally:
            con.close()
    except sqlite3.Error:
        return None


def conv_source(cid):
    for i in range(4):
        try:
            c = json.load(urllib.request.urlopen(urllib.request.Request(f"https://api.intercom.io/conversations/{cid}", headers=H), timeout=30))
            return cid, str((c.get("source") or {}).get("id") or "")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return cid, ""
            time.sleep(3 * (i + 1))
        except Exception:
            time.sleep(2 * (i + 1))
    return cid, None  # unknown: not linked this run, retried next run


def jl(p):
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []


def contact_email(cid):
    for i in range(5):
        try:
            k = json.load(urllib.request.urlopen(urllib.request.Request(f"https://api.intercom.io/contacts/{cid}", headers=H), timeout=30))
            return cid, (k.get("email") or "").strip().lower()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return cid, ""
            time.sleep(3 * (i + 1))
        except Exception:
            time.sleep(2 * (i + 1))
    return cid, None  # unknown: retry next run


def iso_epoch(v):
    """Intercom part `created` (epoch seconds, int or str) -> ISO 8601 UTC, or None if unreadable."""
    try:
        t = int(v)
    except (TypeError, ValueError):
        return None
    if t <= 0:
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def iso_gmail(v):
    """gog message `date` ("YYYY-MM-DD HH:MM", UTC) -> ISO 8601 UTC, or None if unreadable.
    gog gives minute precision, so the stamp is the LAST second of that minute: readers compare a
    request's full-precision createdAt <= proof_at, and rounding down would release a request created
    in the same minute before the mail arrived (H-DevOps #4519 QA, same rule as proof_core.js)."""
    try:
        return time.strftime("%Y-%m-%dT%H:%M:59Z", time.strptime(str(v), "%Y-%m-%d %H:%M"))
    except ValueError:
        return None


UNDATED = "undated"  # sticky marker while merging parts; never written to the feed


def newer(a, b):
    """proof_at of two merged parts: the later one (ISO UTC strings sort by time). If EITHER part is
    undated the result is undated (QA #1391): the undated part might be the newer proof, so its entry
    must keep the reader's whole-user cover rather than borrow another part's date."""
    if a in (None, UNDATED) or b in (None, UNDATED):
        return UNDATED
    return max(a, b)


def emails_to_users(emails):
    return replica.users_by_email(emails)  # raises RuntimeError when unreadable (fail closed)


NEG_TTL_H = 24
NEG_BATCH = 2000


def stale_negatives(cache, neg, contacts, now_epoch, ttl_h=NEG_TTL_H, batch=NEG_BATCH):
    """Contacts cached as "no account" whose check is older than ttl_h (or was never recorded), that
    still have proof parts, oldest check first, at most `batch`."""
    def checked(cid):
        try:
            return calendar.timegm(time.strptime(neg[cid], "%Y-%m-%dT%H:%M:%SZ"))
        except (KeyError, TypeError, ValueError):
            return 0
    due = [c for c in contacts if c and c in cache and cache[c] is None and now_epoch - checked(c) >= ttl_h * 3600]
    return sorted(due, key=lambda c: (checked(c), c))[:batch]


def install(local, target=None):
    """Atomic local install: same-directory temp file, JSON re-read, rename."""
    target = target or TARGET
    tmp = f"{target}.tmp-cspf-{os.getpid()}"
    with open(local) as src, open(tmp, "w") as dst:
        dst.write(src.read())
    try:
        json.load(open(tmp))
        os.chmod(tmp, 0o644)
        os.replace(tmp, target)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print("installed", target, os.path.getsize(target), "bytes")


def main():
    OUT = sys.argv[1]
    CACHE = os.path.join(OUT, "contact-user-cache.json")  # contact id -> core user id (or null)
    NEG = os.path.join(OUT, "contact-negative-checked.json")  # contact id -> last "no account" check (ISO)
    SRC_CACHE = os.path.join(OUT, "conv-source-cache.json")  # conv id -> source (first message) id
    recs = jl(os.path.join(OUT, "intercom-proof.jsonl"))
    grecs = jl(os.path.join(OUT, "gmail-proof.jsonl"))  # {msg, thread, created, email_hash?, user_id}
    cache = json.load(open(CACHE)) if os.path.exists(CACHE) else {}
    neg = json.load(open(NEG)) if os.path.exists(NEG) else {}  # contact -> when "no account" was last checked
    todo = sorted({r["contact"] for r in recs if r.get("contact") and r["contact"] not in cache})
    # QA #1391: "no Muso account" is not forever (a customer can send proof first and sign up later),
    # so negative mappings are re-checked after NEG_TTL_H, oldest first, at most NEG_BATCH per run.
    # A legacy null without a check time counts as never checked. Bound: a customer who registers
    # after sending proof is attributed within NEG_TTL_H (+ the batch backlog), never "never".
    recheck = stale_negatives(cache, neg, {r.get("contact") for r in recs}, time.time())
    emails, unresolved = {}, []
    with cf.ThreadPoolExecutor(8) as ex:
        for cid, em in ex.map(contact_email, todo):
            if em is not None:
                emails[cid] = em
            else:
                unresolved.append(cid)  # Intercom kept failing: NOT "no account", unknown
        rechecked = {}
        for cid, em in ex.map(contact_email, recheck):
            if em is not None:
                rechecked[cid] = em
            else:
                # QA #1391: a due re-check that Intercom would not answer is unknown too (the contact may
                # have registered): the part is marked stale this run, the old stamp kept, retried next run.
                unresolved.append(cid)
    umap = emails_to_users(set(emails.values()) | {e for e in rechecked.values() if e})
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    for cid, em in list(emails.items()) + list(rechecked.items()):
        cache[cid] = umap.get(em)  # None = no Muso account for that email (re-checked after NEG_TTL_H)
        if cache[cid] is None:
            neg[cid] = stamp
        else:
            neg.pop(cid, None)
    json.dump(cache, open(CACHE + ".tmp", "w")); os.replace(CACHE + ".tmp", CACHE)
    json.dump(neg, open(NEG + ".tmp", "w")); os.replace(NEG + ".tmp", NEG)
    print(f"contacts: new {len(todo)}, negatives re-checked {len(rechecked)}/{len(recheck)}, "
          f"newly attributed {sum(1 for c in rechecked if cache.get(c))}")

    # proof_at (proof-loop lead, [key=pof-user-scope], hydra #1420): when the customer sent the
    # document, ISO 8601 UTC. A whole-user entry carries the NEWEST proof part of that conversation /
    # message; a request-scoped entry the newest part linked to that request. An unreadable time is
    # left out (an undated entry keeps the reader's whole-user cover: unknown never releases anyone).
    entries, seen, by_key = [], set(), {}
    for r in recs:
        uid = cache.get(r.get("contact"))
        if not uid:
            continue
        kind = "human_approved_after_doc" if r.get("human_reviewed") else "pending_doc"
        key = (uid, r["conv"])
        at = iso_epoch(r.get("created"))
        if key in seen:
            e = by_key[key]
            e["proof_at"] = newer(e.get("proof_at"), at)
            continue
        seen.add(key)
        e = {"user_id": uid, "request_id": None, "kind": kind, "source": "intercom", "ref": r["conv"], "proof_at": at or UNDATED}
        by_key[key] = e
        entries.append(e)
    for g in grecs:
        if g.get("user_id") and (g["user_id"], g["msg"]) not in seen:
            seen.add((g["user_id"], g["msg"]))
            entries.append({"user_id": g["user_id"], "request_id": None, "kind": "pending_doc", "source": "gmail",
                            "ref": g["msg"], "proof_at": iso_gmail(g.get("created"))})

    # Request-level links (gap 3): extra entries, the whole-user ones above stay.
    ledger = read_ledger()
    n_linked = 0
    if ledger is None:
        print("request links: ledger unreadable, no request-level entries this run")
    else:
        lcontacts = {str(x.get("contact_id")) for x in ledger if x.get("contact_id")}
        src = json.load(open(SRC_CACHE)) if os.path.exists(SRC_CACHE) else {}
        need = sorted({r["conv"] for r in recs if str(r.get("contact")) in lcontacts and r["conv"] not in src})
        with cf.ThreadPoolExecutor(8) as ex:
            for cid, sid in ex.map(conv_source, need):
                if sid is not None:
                    src[cid] = sid
        json.dump(src, open(SRC_CACHE + ".tmp", "w")); os.replace(SRC_CACHE + ".tmp", SRC_CACHE)
        links = request_links([r for r in recs if str(r.get("contact")) in lcontacts], ledger, src)
        for r in recs:
            lk = links.get((str(r["conv"]), str(r.get("part"))))
            uid = cache.get(r.get("contact"))
            if not lk or not uid:
                continue
            kind = "human_approved_after_doc" if r.get("human_reviewed") else "pending_doc"
            for rid, via in lk:
                at = iso_epoch(r.get("created"))
                if (uid, r["conv"], rid) in seen:
                    e = by_key[(uid, r["conv"], rid)]
                    e["proof_at"] = newer(e.get("proof_at"), at)
                    continue
                seen.add((uid, r["conv"], rid))
                e = {"user_id": uid, "request_id": rid, "kind": kind, "source": "intercom", "ref": r["conv"], "via": via,
                     "proof_at": at or UNDATED}
                by_key[(uid, r["conv"], rid)] = e
                entries.append(e)
                n_linked += 1
        print(f"request links: ledger notes {len(ledger)}, convs checked {len(need)}, request-level entries {n_linked}")

    # Honest parts (firstmate 762). A part is listed only when it really exists; `stale` is computed
    # from that part's own last successful refresh (> 3 h = stale). cs-gmail is REQUIRED by consumers:
    # while it is missing or stale they must treat every user in gmail_contacts_90d as UNKNOWN (and,
    # if that list is missing too, everyone).
    MAX_AGE = 3 * 3600
    def _stamp(path):
        try:
            return open(path).read().strip() or None
        except OSError:
            return None
    def _age(stamp):
        try:
            import calendar
            return time.time() - calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ"))
        except Exception:
            return None
    sources = []
    ist = _stamp(os.path.join(OUT, "intercom-last-success"))
    ia = _age(ist) if ist else None
    intercom = {"name": "cs-intercom", "generated_at": ist, "stale": ia is None or ia > MAX_AGE,
                "count": sum(1 for e in entries if e["source"] == "intercom"),
                "coverage": "Intercom conversations 2021-01 onward (customer attachments + proof mentions)"}
    if unresolved:
        # QA #1391: a contact Intercom would not return has proof parts we could not attribute to
        # a user. Dropping them while the part looked fresh would let the decider ask a user who
        # already sent a document. The part is marked stale (readers then treat the whole export
        # as UNKNOWN: never ask, never remove) and the contacts are retried next run (not cached).
        intercom["stale"] = True
        intercom["unresolved_contacts"] = len(unresolved)
    sources.append(intercom)
    gstate = json.load(open(os.path.join(OUT, "gmail-state.json"))) if os.path.exists(os.path.join(OUT, "gmail-state.json")) else {}
    contacts = json.load(open(os.path.join(OUT, "gmail-contacts.json"))) if os.path.exists(os.path.join(OUT, "gmail-contacts.json")) else None
    if gstate.get("full_done_at"):
        ga = _age(gstate.get("last_success_at") or "")
        sources.append({"name": "cs-gmail", "generated_at": gstate.get("last_success_at"), "stale": ga is None or ga > MAX_AGE,
                        "count": sum(1 for e in entries if e["source"] == "gmail"),
                        "coverage": "support@muso.ai inbound messages with attachments, last 400 days"})
    doc = {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "sources": sources, "entries": entries}
    if contacts is not None and gstate.get("last_success_at"):
        # Agreed shape (credit-trust proof_parts.py, firstmate 767): {generated_at, source, user_ids}.
        # generated_at = the last successful Gmail refresh (readers require <= 24 h, tz-aware).
        doc["gmail_contacts_90d"] = {
            "generated_at": gstate["last_success_at"],
            "source": "support@muso.ai inbound messages, last 90 days (cs-systemic gmail-proof.py)",
            "user_ids": sorted({v["user_id"] for v in contacts.values() if v.get("user_id")}),
        }
    for e in entries:
        if e.get("proof_at") in (None, UNDATED):
            e.pop("proof_at", None)
    local = os.path.join(OUT, "cs-proofs.json")
    json.dump(doc, open(local + ".tmp", "w")); os.replace(local + ".tmp", local)
    users = len({e["user_id"] for e in entries})
    print(f"parts {[(x['name'], x['stale']) for x in sources]} entries {len(entries)} users {users} (intercom parts {len(recs)}, contacts unresolved/no-account {sum(1 for r in recs if not cache.get(r.get('contact')))})")

    if "--no-install" not in sys.argv:
        install(local)
    if unresolved:
        print(f"INCOMPLETE: {len(unresolved)} Intercom contact(s) unreadable after retries; cs-intercom marked stale",
              file=sys.stderr, flush=True)
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())
