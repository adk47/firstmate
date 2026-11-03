#!/usr/bin/env python3
"""Zero-read for a credit-verify batch, from DURABLE sources only (no pod-log buffers).

After a batch of verify-gate messages (Intercom asks / status notes), confirm no OTHER sender messaged
the same users over [start, end]:
  1. email      ClickHouse messaging.email_events (kubectl exec into send-gateway with its own env)
  2. bell/push  Loki {namespace="messaging", app=~".*notify-gateway.*"}: requests naming the user,
                classified read-only (/route probe, push-token registration, profile upsert) vs anything else
  3. core       Loki {namespace="muso-prod", app=~"core-backend-(api|worker)"}: trackEvent /
                executeNotificationProcedure lines carrying the user id
  4. why        replica credit_requests rows of those users updated in the window
Each source carries a positive control (its total volume). A source that cannot be read is
UNMEASURED, never zero. Loki keeps lines long after the pods' own buffers rotate (checked 2026-10-30:
14:35Z lines queryable at 17:15Z), so this can run any time after the tick.

CREDIT-CLASS vs OTHER (proof-loop-lead-fable-p1, 2026-10-30): only a credit-class message can collide
with our ask (an email template or core event about credit requests, claims or credit status). Other
messages (a payment receipt, a password reset) are REPORTED, never fatal. A credit-class message is
still expected, and not a STOP, when it is core's approval notice (credits_accepted /
backend_profile_credit_requests_approved) for a request the user CREATED in the window and the
validator approved: a new request auto-approved after our ask, which leaves the ask true.

Verdict and exit code: OK 0, STOP 1 (an unexplained credit-class message), UNMEASURED 2 (a source could
not be read). The caller (credit-verify-outbound.sh) fails closed on 1 and 2.

Usage (node-8, root: kubectl with exec rights, trino-query.sh, the hydra ledger):
  zero_read.py --ledger-ids 5445-5620 [--start 2026-10-30T14:35:00Z] [--end now] [--out DIR]
  zero_read.py --users 111413,362793 --start ... --end ...
Writes <out>/zero-read-<range>-<end>.json and prints one verdict line.

Test seam: ZR_FIXTURE_DIR=<dir> reads each source from <dir>/{email,bell,core,replica}.json instead
(the source's report dict as JSON); the ledger from CVO_LEDGER / ZR_LEDGER.
"""
import argparse, base64, csv, datetime as dt, io, json, os, re, socket, sqlite3, subprocess, sys, time, urllib.parse, urllib.request

LEDGER_PATH = os.environ.get("ZR_LEDGER") or os.environ.get("CVO_LEDGER") or "/var/lib/hydra/credit-review/ledger.sqlite3"
FIXTURES = os.environ.get("ZR_FIXTURE_DIR")
TRINO = os.environ.get("ZR_TRINO", "/opt/hydra/scripts/trino-query.sh")
EXPECTED_READONLY = ("GET /internal/v1/users/N/route", "POST /internal/v1/users/N/push-tokens", "PUT /v1/users/N",
                     "GET /v1/users/N/preferences")
# Credit-class: messages that can collide with a verify-gate ask. Everything else is reported only.
# QA #1545 finding 4 (CRITICAL): the vocabulary was anchored to our OWN names, so core's email template
# `backend_profile_credit_requests_approved` - an APPROVAL notice - classified "not credit-class" BEFORE
# APPROVAL_TEMPLATES was consulted, and an uncorrelated approval email read OK. Classification is fail-closed: an
# approval template is credit-class BY MEMBERSHIP (see credit_template()), and the prefix set tolerates the
# backend_/profile_ names core actually emits. (A false credit-class costs a STOP/UNMEASURED; a false "other" costs
# the gate, so the asymmetry always resolves toward failing closed.)
# Fable/r5 answer 2026-11-03 (the credit-class policy question): `platform_platform_credits_low` and
# `platform_platform_credits_exhausted` are NOT credit-class, and this is a DECISION, not an oversight - they are
# billing/quota notices about platform SPEND, not about a credit request, a claim or a credit status, so the collision
# this reader exists to catch cannot happen through them. Classifying them would turn a routine quota notice into a
# whole-run auto-kill inside a paid batch. MEASURED on prod 2026-11-03 (messaging.email_events, 3 days): 46 rows
# (exhausted 41, low 5) - reported, never fatal. A future template earns its own census line here when it is added.
CREDIT_TEMPLATE_RE = re.compile(r"^(?:backend_)?(?:profile_)?(?:credits?_|credit_status_|credit_request_|profile_claim_|claim_)", re.I)
CREDIT_EVENT_RE = re.compile(r"(credit_request|credits?_|credit_status|claim)", re.I)
# Fable ruling 2026-11-03 (A): an approval notice is exempted ONLY when correlated to a request id IT NAMES - never by
# (user, window). These are the templates/events that ARE an approval notice.
APPROVAL_TEMPLATES = ("credits_accepted", "backend_profile_credit_requests_approved", "credit_request_approved")
APPROVAL_EVENTS = ("backend_profile_credit_requests_approved", "credits_accepted", "credit_request_approved")
# QA #1545 round 13: the approvers whose decision EXPLAINS a credit-class notice. Only the validator's own approval is
# the system reasoning about a request; `admin` and `ops_label_pline` are human/ops actions on the same rows, and an
# approval by them is reported (and stays uncorrelated) rather than used to excuse a message.
EXEMPTING_APPROVERS = ("validator",)


# MEASURED on prod 2026-11-03 (3 days, messaging.email_events GROUP BY event_type): sent 4132, delivered 4122,
# skipped 397, clicked 214, opened 96, deferred 15, bounced 10. `opened`/`clicked` are lifecycle on a message that
# was sent EARLIER (its own `sent` row is what carries the send), so they are reported, never fatal:
# QA #1545 finding 6 - an old credit email OPENED during the batch was read as a new sender, the run exited 1, and the
# caller wrote the global kill file. Everything else (sent, delivered, skipped, deferred, bounced, and any word we do
# not know) stays send evidence: the asymmetry fails closed.
EMAIL_ENGAGEMENT_EVENTS = ("opened", "clicked", "open", "click")


def email_engagement(e):
    """True for an engagement event on an EARLIER send - never evidence that a new message went out."""
    et = (e.get("event_type") or "").strip().lower()
    return et in EMAIL_ENGAGEMENT_EVENTS or et.endswith("_opened") or et.endswith("_clicked")


def credit_template(t):
    """True when an EMAIL template is credit-class: it can collide with our ask, OR it IS an approval notice."""
    t = (t or "").strip()
    return t in APPROVAL_TEMPLATES or bool(CREDIT_TEMPLATE_RE.search(t))


def template_unreadable(t):
    """True when the row does not tell us WHAT was sent - blank, whitespace, or not a string at all.

    Fable ruling (l1 684 §3(ii), the arming bar): a blank template_key is NOT "no credit template", it is "cannot
    tell what this was". `credit_template("")` answers False, so an unclassifiable row used to be reported as
    "(not credit-class)" and the run could still read OK - a fail-open on the one surface whose whole job is to
    decide whether a credit-class message went out. MEASURED on prod 2026-11-03 (3 days): 0 rows with a blank or
    NULL template_key, so this costs nothing today; it exists so that the day one appears it fails closed.
    """
    return not isinstance(t, str) or not t.strip()


def credit_event(ev):
    """True when a CORE event is credit-class - same rule, same fail-closed asymmetry."""
    ev = (ev or "").strip()
    return ev in APPROVAL_EVENTS or bool(CREDIT_EVENT_RE.search(ev))


def fixture(name):
    """The fixture report for a source, or None outside tests."""
    if not FIXTURES:
        return None
    p = os.path.join(FIXTURES, f"{name}.json")
    return json.load(open(p)) if os.path.exists(p) else {"state": "unmeasured", "error": f"no fixture {name}.json"}


def utc(s):
    if s in (None, "now"):
        return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(dt.timezone.utc)


def batch_users(args):
    """The users this batch ATTEMPTED to message, and the window their rows define.

    QA #1545 round 8 (Critical): the cohort was `status = 'sent'` only. A mixed apply leaves 'attempted' rows - the
    gateway was called and the outcome is unknown - so a user whose message may well have gone out was in NO source
    query, and a credit-class message to them read OK. The outbound tick already counts `status IN ('sent',
    'attempted')` for its own cap and spike reads; the zero-read must examine the same cohort or it measures a
    strictly smaller world than the one it is supposed to clear.
    """
    if args.users:
        users = sorted({u.strip() for u in args.users.split(",") if u.strip()})
        return users, None, None, {"explicit": len(users)}
    lo, hi = (int(x) for x in args.ledger_ids.split("-"))
    db = sqlite3.connect(f"file:{LEDGER_PATH}?mode=ro", uri=True)
    rows = db.execute("select account_id, status, coalesce(sent_at, created_at) from verify_messages "
                      "where id between ? and ? and status in ('sent','attempted')", (lo, hi)).fetchall()
    users = sorted({str(r[0]) for r in rows if r[0]})
    times = sorted(r[2] for r in rows if r[2])
    sent = {str(r[0]) for r in rows if r[1] == "sent" and r[0]}
    attempted = {str(r[0]) for r in rows if r[1] == "attempted" and r[0]}
    cohort = {"sent": len(sent), "attempted": len(attempted), "attempted_only": len(attempted - sent)}
    return users, (times[0] if times else None), (times[-1] if times else None), cohort


KUBECTL_TIMEOUT = int(os.environ.get("ZR_KUBECTL_TIMEOUT", "180"))


def kubectl(*a, inp=None, timeout=None):
    """A kubectl call whose TIMEOUT is a returncode, never an escaping exception.

    QA #1545 round 8 (Important): `subprocess.run(..., timeout=...)` raises TimeoutExpired, which escaped every caller,
    left Python with a traceback and exit 1 - and the outbound tick reads exit 1 as a CONFIRMED STOP and writes the
    global kill file. A transient cluster timeout must read as "we could not look" (UNMEASURED, exit 2), never as
    "a credit-class message was seen". Every caller here already maps a nonzero returncode to an unmeasured source.
    """
    t = KUBECTL_TIMEOUT if timeout is None else timeout
    try:
        return subprocess.run(["kubectl", *a], input=inp, capture_output=True, text=True, timeout=t)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(["kubectl", *a], 124, "",
                                           f"kubectl timed out after {t}s: {' '.join(str(x) for x in a)[:160]}")
    except OSError as exc:
        return subprocess.CompletedProcess(["kubectl", *a], 125, "", f"kubectl could not run: {exc}")


def email_events(users, start, end):
    if FIXTURES:
        return fixture('email')
    ids = ",".join("'%s'" % u for u in users if u.isdigit())
    sql = ("SELECT user_id, template_key, class, event_type, toString(event_time) FROM messaging.email_events "
           f"WHERE event_time >= '{start:%Y-%m-%d %H:%M:%S}' AND event_time <= '{end:%Y-%m-%d %H:%M:%S}' AND user_id IN ({ids}) "
           "FORMAT JSONEachRow;\n"
           f"SELECT count() AS n FROM messaging.email_events WHERE event_time >= '{start:%Y-%m-%d %H:%M:%S}' "
           f"AND event_time <= '{end:%Y-%m-%d %H:%M:%S}' FORMAT JSONEachRow")
    js = ("const q=Buffer.from(process.argv[1],'base64').toString().split(';\\n');"
          "const h={Authorization:'Basic '+Buffer.from(process.env.CLICKHOUSE_USER+':'+process.env.CLICKHOUSE_PASSWORD).toString('base64')};"
          "Promise.all(q.map(s=>fetch(process.env.CLICKHOUSE_URL+'/',{method:'POST',headers:h,body:s}).then(async r=>{if(!r.ok)throw new Error(r.status+' '+await r.text());return r.text()})))"
          ".then(r=>console.log(JSON.stringify(r))).catch(e=>{console.error(e.message);process.exit(3)})")
    p = kubectl("-n", "messaging", "exec", "deploy/send-gateway", "--", "node", "-e", js, base64.b64encode(sql.encode()).decode())
    if p.returncode:
        return {"state": "unmeasured", "error": p.stderr[-300:]}
    rows_txt, ctl_txt = json.loads(p.stdout)
    rows = [json.loads(l) for l in rows_txt.splitlines() if l.strip()]
    # QA #1545 round 11 (Critical): bell() and core() both fail closed when their positive control is zero; email did
    # not, so a ClickHouse INGEST GAP read "measured, no events" and the run exited OK - the one source that can see an
    # approval notice was the one that could not notice it saw nothing at all. MEASURED on prod 2026-11-03: 273
    # email_events rows in a 170-minute window, so a zero is an anomaly, never a quiet period.
    control = json.loads(ctl_txt.strip() or '{"n":0}')["n"]
    if not control:
        return {"state": "unmeasured", "control": 0, "events": [],
                "error": "ClickHouse returned 0 email_events rows for the whole window (ingest gap?)"}
    return {"state": "measured", "control": control, "events": rows}


class Loki:
    def __enter__(self):
        self.pf = None
        if FIXTURES:
            return self
        s = socket.socket(); s.bind(("127.0.0.1", 0)); self.port = s.getsockname()[1]; s.close()
        self.pf = subprocess.Popen(["kubectl", "-n", "monitoring", "port-forward", "svc/loki", f"{self.port}:3100"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(30):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{self.port}/ready", timeout=2)
                return self
            except Exception:
                time.sleep(0.5)
        raise RuntimeError(f"the Loki port-forward on 127.0.0.1:{self.port} never became ready (15s)")

    def __exit__(self, *a):
        if self.pf:
            self.pf.terminate()

    MAX_PAGES = 2000

    def query(self, logql, start, end, limit=5000):
        out, cur_ns, skip = [], int(start.timestamp() * 1e9), 0
        for _ in range(self.MAX_PAGES):
            q = urllib.parse.urlencode({"query": logql, "start": cur_ns, "end": int(end.timestamp() * 1e9),
                                        "limit": limit, "direction": "forward"})
            d = json.load(urllib.request.urlopen(f"http://127.0.0.1:{self.port}/loki/api/v1/query_range?{q}", timeout=120))
            raw = sorted((int(ts), l) for s in d["data"]["result"] for ts, l in s["values"])
            if not raw:
                return out
            # QA #1545 finding 7 (CRITICAL): the old cursor was `last_ts + 1us`, which DROPPED every other entry that
            # shares the boundary nanosecond - a saturated page could hide a credit notification and the reader still
            # said OK. The next page now starts AT the boundary, and the entries already emitted at exactly that
            # nanosecond are skipped BY COUNT (text repeats legitimately, so identity is not the discriminator).
            page = raw if not skip else ([v for v in raw if v[0] == cur_ns][skip:] + [v for v in raw if v[0] > cur_ns])
            out += page
            if len(raw) < limit:
                return out
            boundary = raw[-1][0]
            skip = sum(1 for v in raw if v[0] == boundary)
            cur_ns = boundary
            if not page:
                # every line on the page has ONE timestamp, so no cursor can move past it: the window cannot be read
                # completely, and a short list here would be a false OK. Fail closed - the callers report UNMEASURED.
                raise RuntimeError(f"Loki page saturated at {boundary} ns ({limit} lines at one timestamp): the window "
                                   f"cannot be paginated without losing lines")
        raise RuntimeError(f"Loki pagination did not converge in {self.MAX_PAGES} pages ({logql[:80]})")

    def count(self, logql, start, end):
        secs = max(60, int((end - start).total_seconds()))
        q = urllib.parse.urlencode({"query": f"sum(count_over_time({logql}[{secs}s]))", "time": int(end.timestamp())})
        d = json.load(urllib.request.urlopen(f"http://127.0.0.1:{self.port}/loki/api/v1/query?{q}", timeout=120))
        return int(float(d["data"]["result"][0]["value"][1])) if d["data"]["result"] else 0


def _json_obj(line):
    """The JSON object inside a Loki line, whatever the prefix around it, or None.

    QA #1545 finding 2: the old gateway parse assumed the literal adjacency `"method":"X","url":"Y"`. A
    line that carried the same two fields in the other order - or with any other key between them - was
    silently skipped, and since the positive control came from a different selector it still said
    "measured". Parsing the object means key ORDER cannot decide whether a request is seen.
    """
    line = line.strip()
    try:
        d = json.loads(line)
        return d if isinstance(d, dict) else None
    except ValueError:
        pass
    i, j = line.find("{"), line.rfind("}")
    if i < 0 or j <= i:
        return None
    for cand in (line[i:j + 1],):
        try:
            d = json.loads(cand)
            return d if isinstance(d, dict) else None
        except ValueError:
            return None
    return None


def parse_gateway_line(line):
    """(method, path) for a notify-gateway request line, in any key order; None when unparseable.

    Nested shapes are searched too (a logger may wrap the request): `{"req": {"method": .., "url": ..}}`.
    """
    def walk(d, depth=0):
        if not isinstance(d, dict) or depth > 3:
            return None
        m, u = d.get("method"), d.get("url")
        if isinstance(m, str) and isinstance(u, str):
            return m.upper().strip(), u.split("?")[0].split("#")[0]
        for v in d.values():
            got = walk(v, depth + 1)
            if got:
                return got
        return None
    d = _json_obj(line)
    return walk(d) if d else None


# What a notification payload calls its template, most specific first; `type`/`event` are the fallbacks (finding 5).
NOTIFICATION_TEMPLATE_KEYS = ("template", "templateKey", "template_key", "templateName", "notificationTemplate")
NOTIFICATION_TYPE_KEYS = ("notificationType", "type", "event")


def _payload_field(line, key):
    """One payload field in EITHER shape - "k":"v" (JSON) or k=v (logfmt) - and never a prefix of another key."""
    m = (re.search(r'"%s"\s*:\s*"([^"]+)"' % re.escape(key), line)
         or re.search(r'(?<![\w".])%s=(?:"([^"]+)"|([^\s,&}\]]+))' % re.escape(key), line))
    if not m:
        return None
    return (m.group(1) or (m.group(2) if m.lastindex and m.lastindex > 1 else None) or "").strip()


def parse_core_line(line):
    """(kind, user, event) for a core-backend line, for BOTH log formats.

    QA #1545 finding 1 (CRITICAL): `executeNotificationProcedure` lines were selected by the LogQL filter
    but parsed with a `trackEvent` regex only, so a credit NOTIFICATION came through as event=None, was
    classified "not credit-class", and the run could return OK with an unrelated trackEvent keeping the
    positive control nonzero. A notification is the more dangerous of the two - it is a message that
    actually reached the user - so it is parsed, and when its template cannot be read it is marked
    `unclassified` (which fails the run UNMEASURED) rather than passing as "other".
    """
    u = re.search(r'"userId"\s*:\s*"?(\d+)', line)
    user = u.group(1) if u else None
    m = (re.search(r'trackEvent[^{}]*\{\s*"event"\s*:\s*"([A-Za-z_][A-Za-z0-9_]*)"', line)
         or re.search(r"trackEvent[^:{}]*:\s*([A-Za-z_][A-Za-z0-9_]*)", line))
    if m:
        return "trackEvent", user, m.group(1)
    if "executeNotificationProcedure" in line:
        # QA #1545 finding 5 (CRITICAL): the key was picked by a single alternation, i.e. by TEXTUAL ORDER, so a
        # `type=request` that happened to precede `template=credits_more_info_needed` won and the notification
        # classified "not credit-class" - a false OK. Read the fields by PRIORITY instead: the template decides what
        # the message IS; the generic type/event only speaks when no template is named.
        for key in NOTIFICATION_TEMPLATE_KEYS + NOTIFICATION_TYPE_KEYS:
            v = _payload_field(line, key)
            if v:
                return "notification", user, v
        return "notification", user, None
    return None, user, None


# Fable ruling 2026-11-03 (data/verify-program-lead-fable-l1/ruling-zero-read-fail-closed-1103.md), (A): a notice is
# exempted ONLY when it is correlated to a REQUEST ID IT NAMES. An exemption by (user, window) is PROHIBITED: an old
# request's credits_accepted notice delayed into the window was excused by a DIFFERENT request that user had approved
# minutes earlier. `request_ids` reads the ids the notice itself carries; no id = no natural key, and the caller fails
# closed (UNMEASURED), never "exempt".
#
# MEASURED on prod 2026-11-03 (Loki 6 h window + Trino): a real executeNotificationProcedure credit line carries the
# credit_requests UUID under "id" (3 of 5 sampled UUIDs resolve in postgresql_core.public.credit_requests with the
# named user). The 32-hex "requestId" values in the same payload are DSP capture ids, NOT ours - so only UUID-shaped
# values are candidates, and a match must still resolve to an APPROVED row of THAT user created in the window.
_UUID_RE = re.compile(r'"id"\s*:\s*"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"')
_CRID_RE = re.compile(r'"(?:creditRequestId|credit_request_id)"\s*:\s*"([0-9a-fA-F-]{8,36})"')

def request_ids(text):
    """The credit-request ids a line/event names: [] = no natural key (the caller fails closed)."""
    return sorted(set(_UUID_RE.findall(text or "")) | {x for x in _CRID_RE.findall(text or "") if len(x) >= 8})


def bell(loki, users, start, end):
    if FIXTURES:
        return fixture('bell')
    alt = "|".join(u for u in users if u.isdigit())
    sel = '{namespace="messaging", app=~".*notify-gateway.*"}'
    try:
        lines = loki.query(f'{sel} |~ "users/({alt})[/?\\"]"', start, end)
        control = loki.count(sel, start, end)
    except Exception as e:
        return {"state": "unmeasured", "error": str(e)[:300]}
    kinds, unexpected, unclassified = {}, [], []
    for ts, l in lines:
        got = parse_gateway_line(l)
        if not got:
            # QA #1545 finding 2: the line MATCHED the selector (it names one of our users) but its request
            # could not be read. "Not counted" is how an unread request becomes an OK verdict.
            unclassified.append({"t": dt.datetime.fromtimestamp(ts / 1e9, dt.timezone.utc).isoformat(), "line": l[:300]})
            continue
        method, path = got
        k = f"{method} {re.sub(r'/users/[0-9]+', '/users/N', path)}"
        kinds[k] = kinds.get(k, 0) + 1
        if k not in EXPECTED_READONLY:
            unexpected.append({"t": dt.datetime.fromtimestamp(ts / 1e9, dt.timezone.utc).isoformat(), "req": k, "line": l[:300]})
    if control == 0:
        return {"state": "unmeasured", "error": "Loki returned 0 notify-gateway lines for the window (ingest gap?)"}
    if unclassified:
        return {"state": "unmeasured", "control": control, "kinds": kinds, "unexpected": unexpected,
                "error": f"{len(unclassified)} notify-gateway line(s) named a user but could not be parsed as a request "
                         f"(first: {unclassified[0]['line'][:200]})"}
    return {"state": "measured", "control": control, "kinds": kinds, "unexpected": unexpected}


def core(loki, users, start, end):
    if FIXTURES:
        return fixture('core')
    alt = "|".join(u for u in users if u.isdigit())
    sel = '{namespace="muso-prod", app=~"core-backend-(api|worker)"}'
    try:
        # QA #1545 finding 9: the matcher required the exact bytes `"userId":"12"`, while parse_core_line() accepts
        # `"userId": "12"` - a valid notification written with a space was never FETCHED, so an unrelated trackEvent
        # made control>0 and the source read "measured" with no events (a false OK). A raw backtick string keeps the
        # regex readable and tolerates the whitespace core actually emits.
        # QA #1545 round 10: `parse_core_line()` accepts a NUMERIC json id (`"userId":12`) while this matcher required
        # the quoted form, so a notification logged without quotes was never FETCHED - and with any unrelated trackEvent
        # keeping the positive control nonzero the run read OK. Both forms must match; the optional quotes can over-match
        # (fetching 123 for user 12), which is the safe direction: core() discards a line whose id is not in the cohort.
        # the id must be followed by the optional closing quote and then a JSON delimiter, or `12` would match a
        # `123` prefix and pull a FOREIGN user's notice into the cohort (a false STOP for the whole run).
        lines = loki.query(f'{sel} |~ "trackEvent|executeNotificationProcedure" |~ `"userId"\\s*:\\s*"?({alt})"?\\s*[,}}]`', start, end)
        control = loki.count(f'{sel} |= "trackEvent"', start, end)
    except Exception as e:
        return {"state": "unmeasured", "error": str(e)[:300]}
    # (A): the ids are kept ON THE NOTICE THAT NAMED THEM - never merged across notices. Two notices of the same
    # kind/event for one user at different times are TWO notices: an old request's notice must not inherit the id of a
    # different request that a later line names, or the old one would pass exempt() and the window would read OK.
    seen, unclassified = {}, []
    for ts, l in lines:
        kind, user, event = parse_core_line(l)
        t = dt.datetime.fromtimestamp(ts / 1e9, dt.timezone.utc).isoformat()
        if kind is None:
            unclassified.append({"t": t, "line": l[:300]})
            continue
        if kind == "notification" and not event:
            # a notification to one of our users whose template we cannot read: UNMEASURED, never "other"
            unclassified.append({"t": t, "line": l[:300]})
            continue
        # QA #1545 finding 8 (CRITICAL): the notice's identity is its LINE. Two DIFFERENT notices can share a Loki
        # nanosecond (same user, same kind, same event), and keying on (user, kind, event, t) merged them into one
        # record that carried BOTH requests' ids - so an old notice inherited a newly approved request's id and
        # exempt() excused it. Identical lines still collapse, which is correct: they are the same notice logged twice.
        rec = seen.setdefault((user, kind, event, t, l),
                              {"user": user, "kind": kind, "event": event, "t": t, "ids": set()})
        rec["ids"].update(request_ids(l))
    if control == 0:
        return {"state": "unmeasured", "error": "Loki returned 0 core trackEvent lines for the window (ingest gap?)"}
    return {"state": "measured", "control": control, "unclassified": unclassified,
            "events": [{"user": r["user"], "event": r["event"], "kind": r["kind"], "t": r["t"], "ids": sorted(r["ids"])}
                       for _, r in sorted(seen.items(), key=lambda x: (x[1]["t"], sorted(x[1]["ids"]), x[1]["kind"]))]}


def replica_changes(users, start):
    if FIXTURES:
        return fixture('replica')
    ids = ",".join(u for u in users if u.isdigit())
    sql = ("select cast(userid as varchar), cast(id as varchar), status, cast(createdat as varchar), cast(updatedat as varchar), "
           "coalesce(json_extract_scalar(metadata,'$.approval.via'),''), coalesce(json_extract_scalar(metadata,'$.approvedNotice.noticeSentAt'),''), "
           "coalesce(json_extract_scalar(metadata,'$.proofRequest.noticeSentAt'),''), coalesce(json_extract_scalar(metadata,'$.infoRequest.at'),'') "
           f"from postgresql_core.public.credit_requests where userid in ({ids}) and deletedat is null "
           f"and updatedat >= timestamp '{start:%Y-%m-%d %H:%M:%S}' order by updatedat")
    try:
        p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=900)
    except subprocess.TimeoutExpired:
        return {"state": "unmeasured", "error": "the Trino replica read timed out after 900s"}
    except OSError as exc:
        return {"state": "unmeasured", "error": f"the Trino replica read could not run: {exc}"}
    if p.returncode:
        return {"state": "unmeasured", "error": p.stderr[-300:]}
    keys = ["user", "id", "status", "created", "updated", "approvalVia", "approvedNoticeSentAt", "proofNoticeSentAt", "infoRequestAt"]
    rows = [dict(zip(keys, r)) for r in csv.reader(io.StringIO("\n".join(l for l in p.stdout.splitlines() if l.startswith('"'))))]
    return {"state": "measured", "rows": rows}


def _t(v):
    try:
        return utc(str(v).replace(" UTC", "Z").replace(" ", "T"))
    except Exception:
        return None


def exempt_with(approved_new, u, when, ids):
    """True only when one of the ids the notice NAMES is an in-window approval of that same user at or before it.

    Module-level (rather than a closure in main()) so the invariant "a notice is excused only by an id IT named" is
    directly testable: the caller passes the ids of ONE notice record.
    """
    w = _t(when)
    if w is None:
        return False
    for i in ids or []:
        at = approved_new.get((str(u), str(i)))
        if at is not None and w >= at:
            return True
    return False


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--ledger-ids")
    g.add_argument("--users")
    ap.add_argument("--start")
    ap.add_argument("--end", default="now")
    ap.add_argument("--out", default="/var/lib/verify-zero-reads")
    args = ap.parse_args()
    try:
        users, first, last, cohort = batch_users(args)
    except sqlite3.Error as exc:
        print(f"UNMEASURED: the ledger could not be read for this batch ({exc})"); sys.exit(2)
    if not users:
        print("UNMEASURED: no sent or attempted users for the batch (nothing to check)"); sys.exit(2)
    start = utc(args.start) if args.start else utc(first) - dt.timedelta(minutes=5)
    end = utc(args.end)
    report = {"at": utc("now").isoformat(), "window": [start.isoformat(), end.isoformat()], "users": len(users),
              "ledger": args.ledger_ids, "firstSend": first, "lastSend": last, "cohort": cohort}
    # QA #1545 round 8 (Important): a reader that RAISES is a source we could not read - UNMEASURED - never a crash that
    # exits 1 and is read by the tick as a confirmed STOP (which writes the global kill file).
    def source(name, fn, *a):
        try:
            return fn(*a)
        except Exception as exc:                     # noqa: BLE001 - a reader failure is an unreadable source
            return {"state": "unmeasured", "error": f"the {name} reader failed: {type(exc).__name__}: {exc}"}
    report["email"] = source("email", email_events, users, start, end)
    try:
        with Loki() as loki:
            report["bell"] = source("bell", bell, loki, users, start, end)
            report["core"] = source("core", core, loki, users, start, end)
    except Exception as exc:                         # noqa: BLE001 - the port-forward itself failed
        err = f"the Loki reader failed: {type(exc).__name__}: {exc}"
        report["bell"] = report.get("bell") or {"state": "unmeasured", "error": err}
        report["core"] = report.get("core") or {"state": "unmeasured", "error": err}
    report["replica"] = source("replica", replica_changes, users, start)
    # Verdict: only an unexplained CREDIT-CLASS message stops; other templates/events are reported.
    # QA #1545 finding 3: the exemption was "any approved request created after start, for this user, excuses
    # EVERY approval notice about them". Two holes: no upper bound (an approval after our window excused a
    # notice inside it) and no correlation to a time (a later approval excused an OLDER notice). It is now
    # {user: earliest approval instant} for requests CREATED INSIDE [start, end], and an event is exempted
    # only when the event happened AT OR AFTER that instant - the notice is then explained by that approval.
    # Fable ruling 2026-11-03 (A): keyed by (user, REQUEST ID) - never by user alone. An approval excuses a notice only
    # when the notice names THAT request and the request is an approved one created inside this window, at or before it.
    approved_new, out_of_window, other_approver = {}, [], []
    for r in report["replica"].get("rows", []):
        # QA #1545 round 13 (Important): the exemption admitted ANY non-empty `approval.via`, so a request created in
        # the window and ADMIN-approved carried the same explanatory weight as the validator's own decision. The
        # exemption means "the validator decided this while we were looking", and it is the only approver whose
        # decision the invariant treats as the system's own reasoning. A different approver is reported and stays
        # uncorrelated (UNMEASURED), never exempt. MEASURED on prod 2026-11-03 (postgresql_core.public.credit_requests,
        # 120 days, status=approved, GROUP BY approval.via): none 302,302 | validator 36,143 | admin 679 |
        # ops_label_pline 24 - so restricting to the validator leaves the exempt path intact for 98% of the approvals
        # that carry a via at all, and the remaining ~6/day page with the approver named instead of passing silently.
        via = str(r.get("approvalVia") or "").strip()
        if r.get("status") != "approved" or not via:
            continue
        if via not in EXEMPTING_APPROVERS:
            other_approver.append(f"approved request {r.get('id')} of {r.get('user')} approved by {via}, not by the validator")
            continue
        created, updated = _t(r.get("created")), _t(r.get("updated"))
        if created is None or not (start <= created <= end):
            # unreadable or outside the window: NOT evidence about this window, whatever its timestamps claim
            out_of_window.append(f"approved request {r.get('id')} of {r.get('user')} created {r.get('created')} (outside the window)")
            continue
        at = updated if (updated and updated >= created) else created
        key = (str(r["user"]), str(r.get("id")))
        prev = approved_new.get(key)
        approved_new[key] = at if prev is None or at < prev else prev
    stops, reported, uncorrelated = [], [], []
    def exempt(u, when, ids):
        return exempt_with(approved_new, u, when, ids)

    unknown_template = []
    for e in report["email"].get("events", []):
        t, u = e.get("template_key"), e.get("user_id")
        if email_engagement(e):
            reported.append(f"email {t} {e.get('event_type')} -> {u} (engagement on an earlier send, not a new message)")
            continue
        # l1 684 §3(ii) / the arming bar: an unreadable template is not "other" - it is unmeasurable. Checked BEFORE
        # credit_template(), which would answer False for "" and let an unclassifiable send read OK.
        if template_unreadable(t):
            unknown_template.append(f"email {t!r} -> {u} (template_key blank or unreadable: cannot tell what was sent)")
        elif not credit_template(t):
            reported.append(f"email {t} -> {u} (not credit-class)")
        elif t in APPROVAL_TEMPLATES:
            # read the ids from the RAW fields as well as the dumped row: a JSON detail is a STRING, and its inner
            # quotes are escaped by json.dumps (so "id":"<uuid>" would never match the escaped form)
            raw = " ".join(str(e.get(k) or "") for k in ("detail", "subject", "reason", "campaign_name", "template_key"))
            if exempt(u, e.get("event_time") or e.get("t"), request_ids(raw + " " + json.dumps(e, default=str))):
                reported.append(f"email {t} -> {u} (the request it NAMES was approved in the window, at or before the notice)")
            else:
                # no id in the notice row (MEASURED: messaging.email_events has no request-id column), or an id that is
                # not an in-window approval of THIS user: we cannot explain it -> UNMEASURED, never exempt, never "other"
                uncorrelated.append(f"email {t} -> {u} (approval notice with no in-window approval it names)")
        else:
            stops.append(f"email {t} -> {u}")
    cohort = {str(u) for u in users}
    for e in report["core"].get("events", []):
        ev, u = e.get("event") or "", e.get("user")
        # QA #1545 round 10: the reader's subject is THIS batch's cohort. A line for anyone else is a fetch artifact (or a
        # future widening of the selector), so it is reported and never fatal - a foreign user's notice must not be able
        # to kill the whole run.
        if str(u) not in cohort:
            reported.append(f"core {e.get('kind') or 'event'} {ev} -> {u} (user not in this batch's cohort)")
            continue
        if not credit_event(ev):
            reported.append(f"core {e.get('kind') or 'event'} {ev} -> {u} (not credit-class)")
        elif ev in APPROVAL_EVENTS:
            if exempt(u, e.get("t"), e.get("ids") or []):
                reported.append(f"core {ev} -> {u} (the request it NAMES was approved in the window, at or before the notice)")
            else:
                uncorrelated.append(f"core {e.get('kind') or 'event'} {ev} -> {u} (approval notice with no in-window approval it names)")
        else:
            stops.append(f"core {e.get('kind') or 'event'} {ev} -> {u}")
    stops += [f"notify-gateway {x['req']}" for x in report["bell"].get("unexpected", [])]
    reported += out_of_window + other_approver
    unmeasured = [k for k in ("email", "bell", "core", "replica") if report[k]["state"] != "measured"]
    if unknown_template:
        unmeasured.append("email rows with a blank/unreadable template_key (%d)" % len(unknown_template))
        reported += unknown_template
    # (A): a credit-class APPROVAL notice we cannot correlate is UNMEASURED - we may not claim the window was explained
    if uncorrelated:
        unmeasured.append("approval notices with no correlated request id (%d)" % len(uncorrelated))
        reported += uncorrelated
    # QA #1545: an unparsed line cannot be read as "some other message" - it fails the run closed
    if report["core"].get("unclassified") and "core" not in unmeasured:
        unmeasured.append("core (unparsed lines naming a user)")
    report["verdict"] = "STOP" if stops else ("UNMEASURED" if unmeasured else "OK")
    report["stops"], report["reported"], report["unmeasured"] = stops, reported, unmeasured
    report["uncorrelated"] = uncorrelated
    report["unknown_template"] = unknown_template
    os.makedirs(args.out, exist_ok=True)
    path = f"{args.out}/zero-read-{args.ledger_ids or 'users'}-{end:%Y%m%dT%H%M%SZ}.json"
    json.dump(report, open(path, "w"), indent=1)
    # the caller logs this one line: a source's own ERROR is what tells an operator whether a page or a cluster timeout
    # produced the UNMEASURED, so it travels with the verdict instead of only inside the JSON
    errs = "; ".join(f"{k}: {report[k]['error']}" for k in ("email", "bell", "core", "replica")
                     if isinstance(report.get(k), dict) and report[k].get("error"))[:300] or "no reader errors"
    print(f"{report['verdict']}: {len(users)} users {start:%H:%MZ}-{end:%H:%MZ} | email {len(report['email'].get('events', []))} "
          f"(ctl {report['email'].get('control')}) | notify-gw unexpected {len(report['bell'].get('unexpected', []))} "
          f"(ctl {report['bell'].get('control')}) | core {len(report['core'].get('events', []))} (ctl {report['core'].get('control')}) | "
          f"stops {stops} | reported {reported} | unmeasured {unmeasured} | {errs} | {path}")
    sys.exit(1 if stops else (2 if unmeasured else 0))


if __name__ == "__main__":
    # QA #1545 round 8 (Important): exit 1 means "confirmed STOP" to the outbound tick, so a traceback must never be
    # allowed to carry that code. Anything the reader could not finish is reported as UNMEASURED (2) in the one line
    # the caller reads.
    try:
        main()
    except SystemExit:
        raise
    except BaseException as exc:                     # noqa: BLE001 - the exit code is a safety contract
        print(f"UNMEASURED: the zero-read could not complete ({type(exc).__name__}: {exc})")
        sys.exit(2)
