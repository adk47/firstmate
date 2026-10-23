#!/usr/bin/env python3
"""notices@ / legal@ intake, DRY-RUN / label-only (firstmate 906; Fable removals design §B3, package P7).

Runs on node-8 (service-account key there). Every 15 min from node-1 cron.

  legal-intake.py [--since-days N] [--label] [--ack] [--report]

--ack (captain-approved copy pack A-D, 916.3): one templated ack per NEW thread (first message after
ack-start.txt), from support@ via gog, English, never for legal_threat / spam / other, never to
@muso.ai or no-reply senders; ledgered (acked, ack_ref); a failed send is not ledgered and exits 2.

- Reads deliveredto:notices@muso.ai (mailbox kyran@) and deliveredto:legal@muso.ai (mailbox aaron@).
- Classifies each THREAD (deterministic keyword lists): dmca_takedown, privacy_erasure,
  legal_threat (regulator / counsel / formal notice / C&D), security, credit_dispute, spam, other.
- Links Muso ids (profile/track/album uuid prefixes) found in the bodies; flags any already on
  the cs removal register (dedupe by id prefix).
- Ledger: /root/fmc1-intake/ledger.json (root-only): one row per thread, first/last seen,
  class, ids, replied-by-us flag. Never stores bodies.
- --label: ADDS Gmail labels "OpenClaw/<class>" (+ "OpenClaw/unanswered" when no reply from
  @muso.ai / Intercom in the thread). Never removes labels, never archives, never marks read,
  NEVER sends anything (the ack copy pack is not approved), never touches a legal_threat
  thread beyond its label.
- Exit 2 if a mailbox cannot be read (a check that cannot complete must not look clean).
"""
import json, os, re, sys, time, base64, html, subprocess, datetime, email.utils, urllib.request
from google.oauth2 import service_account
from googleapiclient.discovery import build

KEY = "/root/.config/gogcli/sa-YUBtdXNvLmFp.json"
HOME = "/root/fmc1-intake"
LEDGER = f"{HOME}/ledger.json"
REGISTER_IDS = f"{HOME}/register-ids.txt"  # id prefixes already on the cs register (pushed by the lane)
ACK_START = f"{HOME}/ack-start.txt"   # epoch ms; only threads whose FIRST message is after it get an ack
PAGE_START = f"{HOME}/page-start.txt"  # epoch ms; only threads whose FIRST message is after it page #cs_priority
PAGE_CLASSES = ("dmca_takedown", "legal_threat", "privacy_erasure", "security")
SLACK_CHANNEL = "C0BBTAVP44X"  # #cs_priority (same channel + bot as the hydra rights-holder watchdog)
SLACK_MENTIONS = ("U0AL36NADEY", "U038BM16T7W")  # Nick, Jan
# DSP / distributor / label senders (firstmate 961): a takedown from these is a rights-holder takedown even if the
# wording misses the keyword rules. Boundary match on the sender's domain.
DSP_SENDER = re.compile(r"@(?:[\w-]+\.)*(spotify\.com|tidal\.com|apple\.com|distrokid\.com|tunecore\.com|cdbaby\.com|believe\.com|"
                        r"believedigital\.com|theorchard\.com|ingrooves\.com|awal\.com|unitedmasters\.com|amuse\.io|ditto\.fm|"
                        r"routenote\.com|symphonicdistribution\.com|emubands\.com|landr\.com|onerpm\.com|fuga\.com|repost\.network|"
                        r"vydia\.com|sonosuite\.com|ninjatune\.net)>?\s*$", re.I)
PRIVACY_SERVICES = re.compile(r"(incogni|yoursuspect|removeyourmedia|optery|deleteme|kanary|privacybee|onerep)", re.I)
NO_ACK_FROM = re.compile(r"(@muso\.ai|no-?reply|mailer-daemon|postmaster|notifications?@)", re.I)
# Copy pack APPROVED by the captain 2026-10-21 20:5xZ (firstmate 916.3): A privacy, B DMCA, C credit, D security.
# E (legal threat) only after the captain's packet, by a human; F spam/other = no ack.
ACK = {
 "privacy_erasure": "Hello,\n\nThank you for your request of {received}. We have recorded it as a request to remove your personal data and the public pages that refer to you{links}. As a first step, we are removing these pages from search on Muso, and we will complete your request and confirm in writing by {due}.\n{extra}\nMuso.AI Support",
 "dmca_takedown": "Hello,\n\nThank you for your notice of {received}{links_about}. We have recorded it and are reviewing it under our copyright process. We will reply on this thread once it has been reviewed. If you have not already included it, please add the statement that you are the rights holder or authorised to act for them, and your contact details.\n\nMuso.AI Support",
 "credit_dispute": "Hello,\n\nThank you for your message about {about}. We have passed it to our credits team, who will review it and reply on this thread. Nothing else is needed from you right now.\n\nMuso.AI Support",
 "security": "Hello,\n\nThank you for your report about \"{subject}\". We have passed it to our engineering team, who will verify it. We will let you know on this thread once it has been reviewed.\n\nMuso.AI Support",
}


def send_ack(to, subject, body):
    """gog from support@ (node-8). Returns the Gmail message id, or '' on failure."""
    os.umask(0o077)
    f = f"{HOME}/ack-body-{os.getpid()}.txt"
    open(f, "w").write(body)
    try:
        cmd = ("set -a; . /etc/openclaw/main.env; set +a; gog gmail send --account support@muso.ai --to " + json.dumps(to)
               + " --subject " + json.dumps(subject) + " --body-file " + f + " --json")
        out = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=120).stdout
        return (json.loads(out or "{}").get("messageId") or "")
    except Exception:
        return ""
    finally:
        os.unlink(f)


BOXES = [("kyran@muso.ai", "notices@muso.ai"), ("aaron@muso.ai", "legal@muso.ai")]

RULES = [
    ("legal_threat", r"\b(cnil|ico\b|data protection authority|supervisory authority|attorney|lawyer|avocat|counsel|legal action|lawsuit|court|subpoena|mise en demeure|formal notice|cease and desist|cease & desist|saisine)\b"),
    ("security", r"\b(vulnerabilit|security researcher|bug bounty|xss|csrf|session (fixation|invalidat)|exploit)"),
    ("dmca_takedown", r"\b(dmca|takedown|take down|taken down|copyright infringement|copyright-protected|infring|content removal|removed from (spotify|tidal|apple music|all stores|stores|dsps?))"),
    ("privacy_erasure", r"\b(gdpr|rgpd|lgpd|ccpa|tdpsa|erasure|effacement|right to be forgotten|article 17|art\. ?17|personal data|données personnelles|privacy|delete my (profile|data|account)|remove my (profile|name|data)|data protection)"),
    ("credit_dispute", r"\b(credit|credits|profile|merge|misattribut|wrong (artist|name))"),
    ("spam", r"\b(unsubscribe|for your (grammy|consideration)|newsletter|webinar|seo|backlinks|testflight)"),
]
ID_RE = re.compile(r"muso\.ai/(profile|track|album)/([0-9a-f]{8})[0-9a-f-]*")


def svc(subject, scope):
    c = service_account.Credentials.from_service_account_file(KEY, scopes=[f"https://www.googleapis.com/auth/{scope}"], subject=subject)
    return build("gmail", "v1", credentials=c, cache_discovery=False)


def text(p):
    if p.get("mimeType") == "text/plain" and p.get("body", {}).get("data"):
        return base64.urlsafe_b64decode(p["body"]["data"] + "==").decode("utf8", "replace")
    for q in p.get("parts") or []:
        r = text(q)
        if r:
            return r
    if p.get("mimeType") == "text/html" and p.get("body", {}).get("data"):
        return re.sub(r"<[^>]+>", " ", html.unescape(base64.urlsafe_b64decode(p["body"]["data"] + "==").decode("utf8", "replace")))
    return ""


def classify(subject, body):
    s = f"{subject}\n{body}".lower()
    for cls, rx in RULES:
        if re.search(rx, s):
            return cls
    return "other"


def slack_token():
    """The operations bot token from node-8's /etc/openclaw/main.env (never printed)."""
    for line in open("/etc/openclaw/main.env"):
        if line.startswith("MUSO_SLACK_BOT_TOKEN_OPERATIONS="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    return ""


def esc(s):
    return (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def page_text(alias, cls, h0, ids, row):
    name, addr = email.utils.parseaddr(h0.get("from", ""))
    dom = addr.split("@")[-1] if "@" in addr else "?"
    mention = " ".join(f"<@{m}>" for m in SLACK_MENTIONS)
    label = {"dmca_takedown": "Takedown / copyright", "legal_threat": "LEGAL threat (no auto-ack; captain)",
             "privacy_erasure": "Privacy / GDPR erasure", "security": "Security report"}[cls]
    ack = ("auto-ack sent" if row.get("acked") else ("no ack (legal: captain)" if cls == "legal_threat" else "no ack yet"))
    muso = ", ".join(i for i in ids[:6]) or "none linked"
    return (f"{mention}  :rotating_light: *{alias} inbound: {label}*\n"
            f"From: {esc(name)[:60]} (@{esc(dom)[:60]})\nSubject: {esc(h0.get('subject', ''))[:140]}\n"
            f"Muso ids: {esc(muso)} · on removal register: {'yes' if row.get('on_register') else 'NO'} · {ack}\n"
            f"Gmail thread `{row['thread']}` (cs-systemic intake; this mailbox does NOT reach Intercom)")


def post_page(token, text_):
    req = urllib.request.Request("https://slack.com/api/chat.postMessage",
                                 data=json.dumps({"channel": SLACK_CHANNEL, "text": text_, "unfurl_links": False}).encode(),
                                 headers={"Authorization": "Bearer " + token, "Content-Type": "application/json; charset=utf-8"})
    r = json.load(urllib.request.urlopen(req, timeout=30))
    return r.get("ts") if r.get("ok") else ""


def ensure_label(g, name, cache):
    if name in cache:
        return cache[name]
    for l in g.users().labels().list(userId="me").execute().get("labels", []):
        cache[l["name"]] = l["id"]
    if name not in cache:
        cache[name] = g.users().labels().create(userId="me", body={"name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"}).execute()["id"]
    return cache[name]


def main():
    days = int(sys.argv[sys.argv.index("--since-days") + 1]) if "--since-days" in sys.argv else 2
    do_label = "--label" in sys.argv
    do_ack = "--ack" in sys.argv
    ack_start = int(open(ACK_START).read().strip()) if os.path.exists(ACK_START) else 0
    do_page = "--page" in sys.argv
    page_start = int(open(PAGE_START).read().strip()) if os.path.exists(PAGE_START) else 0
    stok = slack_token() if do_page else ""
    if do_page and not stok:
        print("ERROR page: no Slack token")
        failed_page_token = True
    else:
        failed_page_token = False
    os.makedirs(HOME, exist_ok=True)
    os.umask(0o077)
    ledger = json.load(open(LEDGER)) if os.path.exists(LEDGER) else {}
    reg = set(open(REGISTER_IDS).read().split()) if os.path.exists(REGISTER_IDS) else set()
    failed = 0
    new = 0
    for mailbox, alias in BOXES:
        try:
            g = svc(mailbox, "gmail.modify" if do_label else "gmail.readonly")
            tids, page = set(), None
            while True:
                r = g.users().messages().list(userId="me", q=f"deliveredto:{alias} newer_than:{days}d", maxResults=100, pageToken=page).execute()
                tids.update(m["threadId"] for m in r.get("messages", []))
                page = r.get("nextPageToken")
                if not page:
                    break
            labels = {}
            for tid in sorted(tids):
                t = g.users().threads().get(userId="me", id=tid, format="full").execute()
                msgs = t["messages"]
                h0 = {x["name"].lower(): x["value"] for x in msgs[0]["payload"]["headers"]}
                bodies = " ".join(text(m["payload"]) for m in msgs)
                # "replied by us" = a message FROM us TO someone outside muso.ai. An internal forward (e.g. to
                # Jan) is not a reply: on 10-20 a DMCA forward to jan@ marked the notice answered and it was never acked.
                def _h(m):
                    return {x["name"].lower(): x["value"] for x in m["payload"]["headers"]}
                ours = any(re.search(r"@muso\.ai|intercom", _h(m).get("from", ""), re.I)
                           and re.search(r"@(?!muso\.ai)[\w-]+\.", _h(m).get("to", "") + "," + _h(m).get("cc", ""), re.I)
                           for m in msgs[1:])
                cls = classify(h0.get("subject", ""), bodies)
                if cls not in ("legal_threat", "dmca_takedown") and DSP_SENDER.search(h0.get("from", "")) and \
                        re.search(r"\b(remov|take ?down|taken down|withdraw|delete|copyright)", h0.get("subject", "") + " " + bodies[:3000], re.I):
                    cls = "dmca_takedown"
                ids = sorted({f"{k}:{v}" for k, v in ID_RE.findall(bodies)})
                key = f"{alias}:{tid}"
                row = ledger.get(key) or {"first_seen": time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime())}
                if key not in ledger:
                    new += 1
                row.update({"alias": alias, "thread": tid, "class": cls, "msgs": len(msgs), "replied_by_us": ours,
                            "first_msg": msgs[0].get("internalDate"), "last_msg": msgs[-1].get("internalDate"),
                            "ids": ids, "on_register": any(i.split(":")[1] in reg for i in ids),
                            "last_seen": time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime())})
                # One ack + one page per REQUEST, not per thread: the same sender writing to notices@ AND legal@
                # (notices@ is also auto-forwarded to aaron@) or sending twice within 3 days is one request.
                # 2026-10-23: a DMCA sender got 4 identical acks + 4 pages before this key existed.
                sender_addr = email.utils.parseaddr(h0.get("from", ""))[1].lower()
                req_key = f"{sender_addr}|{cls}"
                fm = int(msgs[0].get("internalDate", 0))
                sibling = next((r for k, r in ledger.items() if k != key and r.get("req_key") == req_key
                                and abs(int(r.get("first_msg") or 0) - fm) < 3 * 86400000), None)
                row["req_key"] = req_key
                if sibling is not None:
                    if sibling.get("acked") and not row.get("acked"):
                        row["acked"] = True; row["ack_ref"] = "dup-of:" + str(sibling.get("ack_ref"))
                    if sibling.get("paged") and not row.get("paged"):
                        row["paged"] = "dup-of:" + str(sibling.get("paged"))
                if do_ack and not row.get("acked") and cls in ACK and ack_start and int(msgs[0].get("internalDate", 0)) > ack_start:
                    frm = h0.get("from", "")
                    to = (re.findall(r"[\w.+-]+@[\w-]+\.[\w.]+", frm) or [""])[0]
                    if to and not NO_ACK_FROM.search(frm):
                        rec = datetime.datetime.utcfromtimestamp(int(msgs[0]["internalDate"]) / 1000)
                        due = (rec + datetime.timedelta(days=30)).strftime("%-d %B %Y")
                        links = ", ".join("https://muso.ai/" + i.replace(":", "/") + "…" for i in ids[:6])
                        extra = ("\nBecause you are writing on behalf of someone else, please send us their written authorisation to act for them.\n"
                                 if PRIVACY_SERVICES.search(frm + " " + bodies[:2000]) else
                                 ("\nSo we act on the right pages, please reply with the link(s) to the Muso page(s) concerned.\n" if not ids else ""))
                        body = ACK[cls].format(received=rec.strftime("%-d %B %Y"), due=due, links=(" (" + links + ")") if ids else "",
                                               extra=extra, links_about=(" about " + links) if ids else "",
                                               about=links if ids else "your Muso profile", subject=h0.get("subject", "")[:120])
                        subj = h0.get("subject", "")
                        mid = send_ack(to, subj if subj.lower().startswith("re:") else "Re: " + subj, body)
                        row["acked"] = bool(mid); row["ack_ref"] = mid
                        print(f"ACK {'sent' if mid else 'FAILED'} {alias.split('@')[0]} {tid} {cls} {mid}")
                        if not mid:
                            failed += 1
                if (do_page and stok and not row.get("paged") and cls in PAGE_CLASSES and page_start
                        and int(msgs[0].get("internalDate", 0)) > page_start
                        and not re.search(r"@muso\.ai", h0.get("from", ""), re.I)):  # DSP noreply senders DO page
                    try:
                        ts = post_page(stok, page_text(alias, cls, h0, ids, {**row, "thread": tid}))
                    except Exception:
                        ts = ""
                    if ts:
                        row["paged"] = ts  # only a CONFIRMED post is ledgered; a failed one retries next run
                        print(f"PAGE sent {alias.split('@')[0]} {tid} {cls}")
                    else:
                        failed += 1
                        print(f"PAGE FAILED {alias.split('@')[0]} {tid} {cls}")
                if do_label:
                    want = [ensure_label(g, f"OpenClaw/{cls}", labels)]
                    if not ours:
                        want.append(ensure_label(g, "OpenClaw/unanswered", labels))
                    g.users().threads().modify(userId="me", id=tid, body={"addLabelIds": want}).execute()
                    row["labelled"] = True
                ledger[key] = row
        except Exception as e:
            failed += 1
            print(f"ERROR {alias}: {str(e)[:160]}")
    if failed_page_token:
        failed += 1
    json.dump(ledger, open(LEDGER, "w"))
    if "--report" in sys.argv or new:
        from collections import Counter
        c = Counter((r["alias"].split("@")[0], r["class"]) for r in ledger.values())
        un = Counter((r["alias"].split("@")[0], r["class"]) for r in ledger.values() if not r["replied_by_us"])
        offreg = sum(1 for r in ledger.values() if r["class"] in ("privacy_erasure", "dmca_takedown", "legal_threat") and not r["on_register"])
        print(f"intake: {len(ledger)} threads ({new} new); by class {dict(c)}; unanswered {dict(un)}; removal/legal threads NOT on register: {offreg}; labels={'on' if do_label else 'off'}")
    sys.exit(2 if failed else 0)


if __name__ == "__main__":
    main()
