#!/usr/bin/env python3
"""paid-wave-runner-p2 EMAIL ROUTE: the approved credit-status copy (status-doc-received queued / status-team-review
B0 / uvn-status ask) by EMAIL through send-gateway, to the account's OWN confirmed core address, for paid users the
Intercom gate cannot reach because the Intercom contact for that email is not matched to the account (identity refusal)
or Intercom refuses the contact (action_forbidden, Fable Ruling A5). Firstmate inbox 003/004, captain 2026-10-26.

Runs on node-8 (core replica via Trino, hydra ledger, Intercom read token). DRY RUN by default: reads only, writes
plan files under OUT (ids only). --mode apply also needs --approved <dry-run json> (sends only users that were
`send` there and still are), claims each note in the hydra verify ledger BEFORE the send (same table the Intercom gate
uses, so one note per user per campaign ever, 7-day no-recontact and 1/user/day are shared with every lane), and POSTs
/v1/send inside the send-gateway pod (kubectl exec; the pod's own `admin` caller token; nothing leaves the pod).

Per user, live, right before the send (apply) / at plan time (dry run):
  - not in the Fable messaging holds, lens-held, cs-excluded, or support@-held (a human answered in 7 d)  [input lists]
  - core account: email present, emailconfirmed = true, no other account holds the address (case-insensitive)
  - Intercom (read only): every contact for the address; if ANY external_id names ANOTHER live Muso account
    (professional id, Auth0 subject or users.id of a different user) -> A3, excluded (Fable Ruling A "not chosen" i)
  - Intercom 7-day no-recontact over EVERY contact for the address (the gate's recently_messaged rule);
    the ask also skips anyone with documents in Intercom (credit-proof tag or a user attachment) or on proof-on-file
  - email side 7 d: any credit* email to this user/address in messaging.email_events -> defer
  - ledger: uvn_user_done (one per user per campaign ever, 7 d any note, 90-day ask lock), capped (1/user/day),
    blocked_ids (already noted); refusal holds of OTHER kinds are respected; only the Intercom-identity /
    action_forbidden holds are bypassed (they are about the Intercom recipient, which this route does not use)
  - fresh replica rows -> uvn_status.plan (bad rows left out; nothing showable = held), <= 1000 credits
  - the gate's leak check on the rendered subject + text
"""
import argparse, csv, fcntl, hashlib, io, json, os, re, sqlite3, subprocess, sys, time, urllib.request
from collections import Counter
from datetime import datetime, timedelta, timezone

sys.path.insert(0, "/opt/hydra/scripts")
from credit_review import identity_resolver, uvn_status, verify_ledger, verify_notify  # noqa: E402

TRINO = "/opt/hydra/scripts/trino-query.sh"
STACK = "/opt/hydra/scripts/muso-stack-read.sh"
KEY = {"status-doc-received": "credit_status_doc_received", "status-team-review": "credit_status_team_review",
       "uvn-status": "credit_status_uvn_ask"}
WORDING = {"status-doc-received": "queued", "status-team-review": "no-ask", "uvn-status": ""}
MAX_LISTED, MAX_CREDITS = 3, 1000
IDENTITY_RE = re.compile(r"external_id|Intercom users|Intercom user|not linked", re.I)
FORBIDDEN_RE = re.compile(r"action_forbidden", re.I)
APPROVAL_REF = ("paid-wave-runner-p2 email route: approved copy (firstmate 060/092/106) by email via send-gateway to the "
                "account's confirmed core address; firstmate inbox 003/004 + Fable GO [key=p2-email-route]")
GATE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "intercom-verify-request.sh")
# The gate's own outbound-sanitizer word list (one source of truth; never a copy).
_m = re.search(r'^readonly SANITIZER_WORDS="([^"]+)"', open(GATE).read(), re.M)
if not _m:
    raise SystemExit("cannot read SANITIZER_WORDS from the gate script; refusing to send")
SANITIZER = _m.group(1)
INTERCOM = "https://api.intercom.io"
TOKEN = os.environ.get("MUSOAI_INTERCOM_TOKEN", "")


# ---------- copy variables, ported from the gate's jq (scripts/intercom-verify-request.sh:783-790, 976-1034)
FN_RE = re.compile(r"^[^\W\d_](?:[^\W\d_]|['.-]){0,39}$")
QT_RE = re.compile(r"^[\"“”„«»'‘’‚].*[\"“”„«»'‘’‚]$")


def andjoin(xs):
    return (xs[0] if xs else "") if len(xs) <= 1 else ", ".join(xs[:-1]) + " and " + xs[-1]


def qt(s):
    return s if QT_RE.match(s) else '"' + s + '"'


def role_credits(role):
    r = [x.strip() for x in role.split(",") if x.strip()]
    return andjoin(r) + " credits" if len(r) > 1 else role + " credit"


def first_name(raw):
    w = (raw or "").split(" ")[0]
    return w if FN_RE.match(w) else "there"


def variables(campaign, fn_raw, credits):
    c = [{k: uvn_status._gate_clean(str(v or "")) for k, v in x.items()} for x in credits]
    n, fn = len(c), first_name(uvn_status._gate_clean(fn_raw or ""))
    t = [qt(x["track_title"]) for x in c[:MAX_LISTED]]
    if campaign == "uvn-status":
        if n == 1:
            return {"single": True, "first_name": fn, "track_title": qt(c[0]["track_title"]),
                    "artist_name": c[0]["artist_name"], "role_credits": role_credits(c[0]["role"])}
        return {"single": False, "first_name": fn,
                "titles": andjoin(t) + (f" (and {n - MAX_LISTED} more)" if n > MAX_LISTED else "")}
    return {"first_name": fn, "request_word": "request" if n == 1 else "requests",
            "titles": andjoin(t) + (f" and {n - MAX_LISTED} more" if n > MAX_LISTED else "")}


def render_text(campaign, v):
    """The text the user reads (subject, body), for the leak check and the sample; the send-gateway template renders
    the same sentences (templates.patch test asserts them word for word)."""
    if campaign == "status-doc-received":
        return (f"Your Muso credit {v['request_word']}: an update",
                f"Hi {v['first_name']}, a quick update on your credit {v['request_word']} for {v['titles']}: we have the "
                "document you sent, and it's in our review queue. We'll message you here as soon as it's checked - no need "
                "to send anything else.\n\nMuso Support")
    if campaign == "status-team-review":
        return (f"Your Muso credit {v['request_word']}: an update",
                f"Hi {v['first_name']}, a quick update on your credit {v['request_word']} for {v['titles']}: they're with "
                "our team for review. Nothing else is needed from you right now.\n\nMuso Support")
    lst = ("Any one of these works (a link, photo or PDF is fine):\n\n- A public link where the credit is listed: Tidal, Genius, "
           "Discogs, AllMusic, ASCAP or BMI.\n- Documentation of the work: a project or session file, a message with "
           "the artist, a contract or split sheet, or anything else that shows you worked on it.")
    if v["single"]:
        head = (f"Hi {v['first_name']}, a quick status update on your credit request for {v['track_title']} by "
                f"{v['artist_name']}: it's waiting on one thing from you, something that shows your {v['role_credits']}.")
        see = "You will see the credit on your profile"
    else:
        head = (f"Hi {v['first_name']}, a quick status update on your credit requests for {v['titles']}: they're waiting "
                "on one thing from you, something that shows your role on each.")
        see = "You will see each credit on your profile"
    return (f"Your Muso credit request{'' if v['single'] else 's'}: one thing we still need",
            f"{head}\n\n{lst}\n\nJust reply to this message with it. {see} as soon as "
            "it is approved, and we will let you know here if anything else is needed.\n\nThank you,\n\nCaroline, Muso Support")


def leak_reason(subject, text):
    flat = re.sub(r"\s+", " ", subject + " " + text)
    if re.search(r"github\.com/|gitlab\.com/|issues? +(#|[0-9]{3,})|#[0-9]{3,}|<@U[A-Z0-9]+>", flat, re.I):
        return "issue link / number / Slack mention"
    if re.search(r"(^|[^A-Za-z0-9_])(Ops resolution|admin[ _]?id)([^A-Za-z0-9_]|$)", flat, re.I):
        return "internal wording"
    if re.search(rf"(^|[^A-Za-z0-9_])({SANITIZER})([^A-Za-z0-9_]|$)", flat, re.I):
        return "sanitizer word"
    if chr(8212) in subject + " " + text:  # an em dash, by code point (as the gate: explode | index([8212]))
        return "em dash"
    return ""


# ---------- reads
def trino(sql):
    p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=900)
    if p.returncode != 0:
        sys.exit("trino failed: " + p.stderr[-300:])
    return list(csv.reader(io.StringIO("\n".join(l for l in p.stdout.splitlines() if l.startswith('"')))))


def ic(method, path, body=None):
    for t in range(4):
        req = urllib.request.Request(INTERCOM + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                     headers={"Authorization": f"Bearer {TOKEN}", "Accept": "application/json",
                                              "Content-Type": "application/json", "Intercom-Version": "2.11"})
        try:
            with urllib.request.urlopen(req, timeout=45) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code == 429 or e.code >= 500:
                time.sleep(10 * (t + 1)); continue
            raise
    raise RuntimeError(f"intercom {path} failed")


def intercom_contacts(email):
    d = ic("POST", "/contacts/search", {"query": {"field": "email", "operator": "=", "value": email}})
    if not isinstance(d.get("data"), list):
        raise RuntimeError("contact search not verified")
    return [c for c in d["data"] if (c.get("email") or "").strip().lower() == email]


def recently_messaged(cid, since):
    d = ic("POST", "/conversations/search", {"query": {"operator": "AND", "value": [
        {"field": "contact_ids", "operator": "=", "value": cid}, {"field": "updated_at", "operator": ">", "value": since}]},
        "pagination": {"per_page": 50}})
    convs = d.get("conversations")
    if not isinstance(convs, list):
        raise RuntimeError("recent-contact check not verified")
    if (d.get("total_count") or len(convs)) > 50:
        return "more than 50 conversations in 7 days"
    if any((c.get("source", {}).get("author", {}).get("type") in ("admin", "bot", "team")) and (c.get("created_at") or 0) > since
           for c in convs):
        return "we started a conversation in 7 days"
    for c in convs:
        full = ic("GET", f"/conversations/{c['id']}?display_as=plaintext")
        for p in (full.get("conversation_parts") or {}).get("conversation_parts") or []:
            if (p.get("author", {}).get("type") in ("admin", "bot", "team") and p.get("part_type") != "note"
                    and (p.get("created_at") or 0) > since and (p.get("body") or "")):
                return "we replied in 7 days"
    return ""


def docs_in_intercom(cid):
    after, total = "", 0
    while True:
        body = {"query": {"field": "contact_ids", "operator": "=", "value": cid}, "pagination": {"per_page": 50}}
        if after:
            body["pagination"]["starting_after"] = after
        d = ic("POST", "/conversations/search", body)
        convs = d.get("conversations")
        if not isinstance(convs, list):
            raise RuntimeError("document check not verified")
        for c in convs:
            if any((t.get("name") or "").lower() == "credit-proof" for t in (c.get("tags") or {}).get("tags") or []):
                return "tagged credit-proof"
            if c.get("source", {}).get("author", {}).get("type") == "user" and (c.get("source", {}).get("attachments") or []):
                return "user opened a conversation with an attachment"
        total += len(convs)
        if total > 150:
            return "more than 150 conversations (counted as documented)"
        for c in convs:
            full = ic("GET", f"/conversations/{c['id']}?display_as=plaintext")
            if any(p.get("author", {}).get("type") == "user" and (p.get("attachments") or [])
                   for p in (full.get("conversation_parts") or {}).get("conversation_parts") or []):
                return "user attached a document"
        after = ((d.get("pages") or {}).get("next") or {}).get("starting_after") or ""
        if not after:
            return ""


def email_side_7d(users):
    """{user_id} with any credit* email (core credits_* or ours) in the last 7 days, by user id or sha256(address)."""
    if not users:
        return set()
    by_hash = {hashlib.sha256(e.encode()).hexdigest(): u for u, e in users.items()}
    ids = ",".join(f"'{u}'" for u in users)
    hs = ",".join(f"'{h}'" for h in by_hash)
    sql = ("SELECT user_id, lower(hex(SHA256(email))) FROM messaging.email_events WHERE event_time >= now() - INTERVAL 7 DAY "
           "AND template_key LIKE 'credit%' AND event_type IN ('sent','delivered','received','opened','clicked','unconfirmed') "
           f"AND (user_id IN ({ids}) OR lower(hex(SHA256(email))) IN ({hs})) GROUP BY 1, 2")
    p = subprocess.run(["bash", STACK, "ch", sql], capture_output=True, text=True, timeout=180)
    if p.returncode != 0:
        sys.exit("email history read failed (fail closed): " + p.stderr[-300:])
    hit = set()
    for line in p.stdout.splitlines()[1:]:
        uid, h = (line.split("\t") + [""])[:2]
        if uid.isdigit() and int(uid) in users:
            hit.add(int(uid))
        if h in by_hash:
            hit.add(by_hash[h])
    return hit


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lists", required=True, help="json {campaign: [{user_id, request_ids}]} (ids only)")
    ap.add_argument("--out", default=os.path.join(os.environ.get("PWR_DIR", ""), "email") if os.environ.get("PWR_DIR") else None, required=not os.environ.get("PWR_DIR"))
    ap.add_argument("--mode", default="dry-run", choices=["dry-run", "apply"])
    ap.add_argument("--approved", help="apply: the dry-run plan json firstmate/Fable approved")
    ap.add_argument("--max-users", type=int, default=0)
    ap.add_argument("--pace", type=float, default=2.0)
    a = ap.parse_args()
    if not TOKEN:
        sys.exit("MUSOAI_INTERCOM_TOKEN is not set (source /etc/openclaw/main.env); nothing read or sent")
    if a.mode == "apply" and not a.approved:
        sys.exit("--mode apply needs --approved <dry-run plan json>")
    approved = {}
    if a.approved:
        approved = {(r["user_id"], r["campaign"]): r for r in json.load(open(a.approved))["rows"] if r["decision"] == "send"}
    os.makedirs(a.out, mode=0o700, exist_ok=True)
    now = datetime.now(timezone.utc)
    day, since7 = now.strftime("%Y-%m-%d"), int((now - timedelta(days=7)).timestamp())
    lists = json.load(open(a.lists))
    todo = [(c, u) for c in ("status-doc-received", "status-team-review", "uvn-status") for u in lists.get(c, [])]
    uids = sorted({int(u["user_id"]) for _, u in todo})
    # core: account, confirmed, sole owner of the address; identities of every account (for A3)
    acct = uvn_status.accounts_of(uids) if uids else {}
    conf = {int(r[0]): r[1] == "true" for r in trino(
        f"select cast(id as varchar), cast(emailconfirmed as varchar) from postgresql_core.public.users where id in ({','.join(map(str, uids))})")} if uids else {}
    emails = sorted({x["email"] for x in acct.values() if x["email"]})
    owners = Counter()
    for i in range(0, len(emails), 300):
        lit = ",".join("'" + e.replace("'", "''") + "'" for e in emails[i:i + 300])
        for e, n in trino(f"select lower(trim(email)), cast(count(*) as varchar) from postgresql_core.public.users "
                          f"where lower(trim(email)) in ({lit}) group by 1"):
            owners[e] = int(n)
    proof = verify_notify.load_proof_on_file(None)
    email_hits = email_side_7d({u: acct[u]["email"] for u in uids if acct.get(u, {}).get("email")})
    db = verify_ledger.connect(verify_ledger.DEFAULT_PATH) if a.mode == "apply" else \
        sqlite3.connect(f"file:{verify_ledger.DEFAULT_PATH}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    lock = None
    if a.mode == "apply":
        lock = open(f"{verify_ledger.DEFAULT_PATH}.p2-email-route.run.lock", "a+")
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    rows, counts, sent, failed = [], Counter(), 0, 0
    ext_cache = {}
    for campaign, u in todo:
        uid = int(u["user_id"]); a_ = acct.get(uid) or {}; email = a_.get("email", "")
        row = {"user_id": uid, "campaign": campaign, "key": KEY[campaign]}

        def done(decision, why=""):
            row.update(decision=decision, why=why); counts[(campaign, decision, why.split(":")[0])] += 1; rows.append(row)

        if a.mode == "apply" and (uid, campaign) not in approved:
            continue
        if a.max_users and sent >= a.max_users:
            done("left", "run size"); continue
        if not email:
            done("hold", "no account email"); continue
        if not conf.get(uid):
            done("hold", "email not confirmed"); continue
        if owners.get(email, 0) != 1:
            done("hold", "another account holds the address"); continue
        if campaign == "uvn-status" and str(uid) in proof:
            done("skip", "documents on file (proof-on-file)"); continue
        # ledger (same rules the Intercom gate uses)
        listed = [str(r) for r in u.get("request_ids") or []]
        if listed and verify_ledger.blocked_ids(db, listed, campaign) >= set(listed):
            done("skip", "already noted (ledger)"); continue
        other = other_refusal_hold(db, campaign, email, uid, now)
        if other is not None:
            done("hold", "other refusal hold: " + other[:60]); continue
        why = verify_ledger.uvn_user_done(db, email, now=now, campaign=campaign, user_id=str(uid))
        if why:
            done("defer" if why in verify_ledger.DEFER_REASONS else "skip", "ledger: " + why); continue
        # send-gateway already answered for this user + campaign (suppressed / unsubscribed / bounced / opted out):
        # its idempotency key returns that same skip forever, so do not offer them again (in-app only).
        prior = gateway_declined_before(db, campaign, uid, email)
        if prior is not None:
            done("skip", "send-gateway skipped earlier (in-app only): " + prior[:60]); continue
        if verify_ledger.capped(db, user_key=email, day=day, user_id=str(uid)):
            done("defer", "ledger: already messaged today (1/user/day)"); continue
        if uid in email_hits:
            done("defer", "credit email in the last 7 days (send-gateway / core)"); continue
        # Intercom, read only
        try:
            contacts = intercom_contacts(email)
            mine = {acct[uid]["professional_id"], acct[uid]["auth_id"], "auth0|" + acct[uid]["auth_id"], str(uid)} - {"", "auth0|"}
            exts = {str(c.get("external_id")) for c in contacts if c.get("external_id")} - mine
            if exts:
                key_ = tuple(sorted(exts))
                if (uid, key_) not in ext_cache:
                    lit = ",".join("'" + x.replace("'", "''") + "'" for x in key_)
                    ids = {r[0] for r in trino(
                        "select cast(id as varchar) from postgresql_core.public.users where neptuneprofessionalid in "
                        f"({lit}) or auth0userid in ({lit}) or ('auth0|' || auth0userid) in ({lit}) or cast(id as varchar) in ({lit})")}
                    # r5 (Fable [key=x2-sample-1027]): a presented profile (processed claim / representation,
                    # what the mobile app logs into Intercom with) names its owner(s) too; a profile another
                    # account had a reverted claim on names that account as well.
                    own, rev = identity_resolver.facts(key_, trino)
                    pres = {x: {str(u) for u, how in own.get(x, {}).items() if identity_resolver.PRESENTED_PROFILE in how}
                            | {str(u) for u in rev.get(x, set())} for x in key_}
                    ext_cache[(uid, key_)] = (ids | {u for us in pres.values() for u in us},
                                              all(us == {str(uid)} for us in pres.values()))
                owners, all_presented = ext_cache[(uid, key_)]
                others = owners - {str(uid)}
                if others:
                    done("exclude", "A3: an Intercom contact for this email names another live Muso account"); continue
                row["intercom_class"] = ("presented profile (mobile app identity)" if all_presented
                                         else "A2 orphan id" if len(contacts) == 1 else "A4 several contacts, none another account")
            else:
                row["intercom_class"] = "A1 empty id / no contact" if contacts else "no Intercom contact"
            rm = next((w for c in contacts for w in [recently_messaged(c["id"], since7)] if w), "")
            if rm:
                done("defer", "Intercom: " + rm); continue
            if campaign == "uvn-status":
                dw = next((w for c in contacts for w in [docs_in_intercom(c["id"])] if w), "")
                if dw:
                    done("skip", "documents in Intercom: " + dw); continue
        except Exception as e:  # fail closed
            done("hold", f"Intercom read failed: {type(e).__name__}"); continue
        # fresh replica rows -> what the note may show
        fresh = uvn_status.uvn_requests([uid], statuses=uvn_status.PENDING_STATUSES[campaign]).get(uid, [])
        why, live = uvn_status.plan(set(listed), fresh, campaign == "uvn-status")
        if why or not live:
            done("hold" if why in uvn_status.HOLDS else "skip", why or "nothing pending now"); continue
        if len(live) > MAX_CREDITS:
            done("hold", f"{len(live)} credits > {MAX_CREDITS}"); continue
        v = variables(campaign, a_.get("first_name", ""), live)
        subj, text = render_text(campaign, v)
        lk = leak_reason(subj, text)
        if lk:
            done("hold", "leak check: " + lk); continue
        row.update(n_credits=len(live), request_ids=[c["request_id"] for c in live],
                   body_sha256=hashlib.sha256(text.encode()).hexdigest())
        if a.mode == "dry-run":
            row["vars_shape"] = sorted(v)
            if not [r for r in rows if r.get("decision") == "send" and r["campaign"] == campaign]:
                row["sample"] = {"subject": subj, "text": text.replace(f"Hi {v['first_name']},", "Hi <first name>,", 1)}
            done("send"); continue
        # ---- apply: claim in the hydra ledger, then send inside the send-gateway pod
        # last re-check (another lane may have messaged them while the Intercom reads ran)
        why = verify_ledger.uvn_user_done(db, email, now=now, campaign=campaign, user_id=str(uid))
        if why or verify_ledger.capped(db, user_key=email, day=day, user_id=str(uid)):
            done("defer", "ledger at claim: " + (why or "already messaged today")); continue
        c = verify_ledger.claim(db, user_key=email, day=day, request_ids=row["request_ids"], message_type="email",
                                approved_by="firstmate+fable", approval_ref=APPROVAL_REF, campaign=campaign,
                                refs=[{"request_id": x["request_id"], "profile_id": x["profile_id"], "track_id": x["track_id"]} for x in live],
                                enforce_cap=False, user_id=str(uid))
        if c.get("result") != "claimed":
            done("skip", "ledger claim: " + c.get("result", "?")); continue
        payload = {"key": KEY[campaign], "to": {"email": email, "user_id": str(uid)}, "data": {"event": v},
                   "idempotency_key": f"credit-status:{campaign}:{uid}"}
        res = send_in_pod(payload)
        st = res.get("status")
        outcome = classify_send(res)
        verify_ledger.finalize(db, message_row=c["message_row"], status=outcome["status"],
                               # message_id stays NULL: the Intercom proof sweep (verify_ledger.awaiting_proof ->
                               # verify_notify.py:867) looks every non-null message_id up in Intercom; the
                               # send-gateway id lives in api_log instead.
                               message_id="", reason=f"send-gateway {st} {res.get('reason') or res.get('gate') or ''}"[:200],
                               body_sha256=row["body_sha256"], api_log=f"{outcome['log']}:{res.get('id') or ''}")
        sent += st == "sent"
        done("sent" if st == "sent" else "failed", f"send-gateway {st} {res.get('reason') or res.get('gate') or ''}".strip())
        failed += outcome["status"] != "sent"
        row["message_id"] = res.get("id")
        time.sleep(a.pace)
    stamp_ = now.strftime("%Y%m%dT%H%MZ")
    out = {"generated_at": now.isoformat(timespec="seconds"), "mode": a.mode, "rows": rows,
           "counts": [{"campaign": k[0], "decision": k[1], "why": k[2], "n": n} for k, n in sorted(counts.items())]}
    path = f"{a.out}/{a.mode}-{stamp_}.json"
    with open(path, "w") as fh:
        json.dump(out, fh, indent=1)
    os.chmod(path, 0o600)
    print(path)
    print(json.dumps(Counter(r["decision"] for r in rows)), json.dumps({f"{k[0]}|{k[1]}|{k[2]}": n for k, n in sorted(counts.items())}, indent=1))
    # A send that did not land is a failed run (QA on #1384): daily.sh stops on it instead of reporting done.
    if failed:
        print(f"{failed} send(s) not confirmed sent (see {path})", file=sys.stderr)
        sys.exit(4)


POD_JS = r"""
let s='';process.stdin.on('data',d=>s+=d).on('end',async()=>{
 const tok=(process.env.INTERNAL_TOKENS||'').split(',').map(x=>x.trim()).find(x=>x.startsWith('admin:'));
 if(!tok){console.log(JSON.stringify({status:'failed',reason:'no admin caller token in the pod'}));return;}
 try{const r=await fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/v1/send',{method:'POST',
  headers:{'content-type':'application/json',authorization:'Bearer '+tok.slice(6)},body:s});
  const b=await r.json().catch(()=>({}));console.log(JSON.stringify({http:r.status,id:b.id,status:b.status,gate:b.gate,reason:b.reason||b.error}));}
 catch(e){console.log(JSON.stringify({status:'failed',reason:'fetch '+e.message}));}});
"""


def other_refusal_hold(db, campaign, email, uid, now):
    """The reason of a live refusal hold of THIS campaign that this route must respect, or None. Only this
    campaign's holds count (QA on #1384): a silent hold on the status notes (verify_ledger.hold_silent) must
    never block the uvn-status ask. Intercom-identity / action_forbidden holds are about the Intercom recipient,
    which this route does not use, so they are bypassed."""
    holds = db.execute("SELECT reason, next_recheck_at, flagged_at FROM verify_refusal_holds WHERE campaign=? "
                       "AND (user_key=? OR user_id=?)", (campaign, email, str(uid))).fetchall()
    other = [h for h in holds if (h["flagged_at"] or h["next_recheck_at"] > verify_ledger.stamp(now))
             and not IDENTITY_RE.search(h["reason"] or "") and not FORBIDDEN_RE.search(h["reason"] or "")]
    return (other[0]["reason"] or "") if other else None


def gateway_declined_before(db, campaign, uid, email):
    """The reason send-gateway TERMINALLY declined this user + campaign before (suppressed / unsubscribed /
    bounced / opted out: its idempotency key returns that same skip forever), or None. A transport failure is
    recorded as send-gateway-transport:... and stays retryable (QA/Fable on #1384); rows written before that
    split carry reason 'send-gateway failed ...' (our side, no gateway answer) and are never terminal either."""
    row = db.execute("SELECT reason FROM verify_messages WHERE campaign=? AND (account_id=? OR user_key=?) "
                     "AND api_log LIKE 'send-gateway:%' AND status='rejected' "
                     "AND coalesce(reason,'') NOT LIKE 'send-gateway failed%' LIMIT 1",
                     (campaign, str(uid), email)).fetchone()
    return str(row[0] or "") if row else None


def classify_send(res):
    """The ledger outcome of one send-gateway call (QA/Fable on #1384: a transient failure must never
    become permanent silence).
      sent                                   -> status sent
      unconfirmed / sent_unrecorded          -> attempted (may have been delivered: never re-sent automatically)
      the gateway ANSWERED 2xx and declined  -> rejected, api_log send-gateway: (terminal: suppressed,
                                                unsubscribed, bounced or opted out; the next run skips the user)
      anything else (no pod, no token, fetch error, non-2xx, unparseable)
                                             -> rejected, api_log send-gateway-transport: (retryable: the ledger
                                                re-offers a rejected row up to verify_ledger.MAX_ATTEMPTS times)"""
    st = res.get("status")
    if st == "sent":
        return {"status": "sent", "log": "send-gateway"}
    if st in ("unconfirmed", "sent_unrecorded"):
        return {"status": "attempted", "log": "send-gateway"}
    http = res.get("http")
    if isinstance(http, int) and 200 <= http < 300 and st and st != "failed":
        return {"status": "rejected", "log": "send-gateway"}
    return {"status": "rejected", "log": "send-gateway-transport"}


def send_in_pod(payload):
    """One /v1/send inside the send-gateway pod. 'failed' = nothing reached the gateway as far as we can tell
    (retryable: classify_send); 'unconfirmed' = the pod ran but its answer is unreadable (may have been sent).
    A retry is safe either way: the payload's idempotency_key makes the gateway answer a repeat with the first
    result instead of sending again."""
    try:
        g = subprocess.run(["kubectl", "-n", "messaging", "get", "pod", "-l", "app.kubernetes.io/name=send-gateway",
                            "--field-selector=status.phase=Running", "-o", "name"], capture_output=True, text=True,
                           timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"status": "failed", "reason": f"kubectl get pod: {type(exc).__name__}"}
    pod = g.stdout.split() if g.returncode == 0 else []
    if not pod:
        return {"status": "failed", "reason": f"no running send-gateway pod (kubectl rc={g.returncode})"}
    try:
        p = subprocess.run(["kubectl", "-n", "messaging", "exec", "-i", pod[0], "--", "node", "-e", POD_JS],
                           input=json.dumps(payload), capture_output=True, text=True, timeout=90)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"status": "failed", "reason": f"kubectl exec: {type(exc).__name__}"}
    return pod_answer(p.returncode, p.stdout, p.stderr)


def pod_answer(rc, stdout, stderr=""):
    """The pod script's last JSON line, whatever kubectl's exit code. Without one: a nonzero kubectl exec
    exit is a failure before (or instead of) the send (QA/Fable on #1384: an exec that never started Node
    must stay retryable, not 'attempted'); a zero exit with an unreadable answer is 'unconfirmed'."""
    for line in reversed((stdout or "").strip().splitlines()):
        try:
            ans = json.loads(line)
        except ValueError:
            continue
        if isinstance(ans, dict):
            return ans
    if rc != 0:
        return {"status": "failed", "reason": f"kubectl exec rc={rc}: {(stderr or '').strip()[-120:]}"}
    return {"status": "unconfirmed", "reason": "no parseable answer from the pod"}


if __name__ == "__main__":
    main()
