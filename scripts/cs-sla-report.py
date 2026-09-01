#!/usr/bin/env python3
"""Weekly READ-ONLY SLA report of Intercom conversations, posted to #cs_chats.

The SLA denominator. Over the trailing --window-days (default 7) days of
Intercom conversations this computes:
  1. First-response time distribution (created_at -> first admin reply),
     preferring the Intercom conversation `statistics` object's
     first_admin_reply_at over fetching conversation parts. A conversation
     with no statistics object (or no first_admin_reply_at on it) is counted
     "unknown", never silently dropped.
  2. Residue >24h snapshot: currently-open conversations where the customer
     spoke last (same waiting_since / needs-human-vs-needs-customer-input
     semantics as scripts/cs-needs-human-digest.py) and waiting > 24h.
  3. Reopen rate: fraction of window conversations with >=1 admin reply that
     reopened at least once (NOT the average reopen count — a conversation
     reopened N times is one unresolved close). See reopen_rate().
  4. AI-resolved / total-inbound ratio (docs/plans/autonomous-cs-machine.md
     Sec.5's headline honesty metric): of the week's inbound conversations,
     what fraction were auto-closed by a sweep AND never reopened, versus
     closed by a human. See resolved_counts() and the caveats below.
  5. Unverified-credit queue depth: read-only via `<muso> api GET
     /admin/credit-requests/counts --json`, where <muso> is resolved
     deterministically (MUSO_CLI_BIN, else `muso` on PATH, else
     /usr/local/bin/muso; reported "unavailable" only if none exist). See
     _resolve_muso_bin() / unverified_credit_queue_depth().

THIS SCRIPT IS DELIBERATELY STANDALONE — it copies (not imports) the
Intercom client / pagination / masking / waiting_since patterns from
scripts/cs-needs-human-digest.py, per the WS1 spec. Read-only on Intercom;
its only side effects are one Slack post (--post) and one local JSON rollup
file per run.

Per-admin (Caroline bot vs human) first-response split: NOT available. The
Intercom 2.11 `conversation_statistics` schema exposes first_admin_reply_at
(a timestamp) but no admin/teammate id for that first reply — only
last_closed_by_id identifies an admin at all, and that is the closer, not
the first replier. Splitting by admin would require fetching every
conversation's parts (an N+1 scan Intercom guards against for a
weekly-cadence report), so this report emits a single combined
first-response row and documents the gap here rather than guessing.

AI-resolved / total-inbound caveats (read before trusting the number):
  1. "AI-resolved" here means "last closed by an automated sweep" (Intercom
     statistics' last_closed_by_id), NOT a per-problem fix-credit. A
     conversation Caroline fixed via muso-cli but a human later closed in
     Intercom is counted human-resolved, not AI-resolved. This is
     conservative - it can only under-count automation's share, never
     inflate it.
  2. This assumes no human admin ever acts as admin id 5763097 (Caroline's
     dedicated closer identity) - true architecturally today (Caroline has
     no close tool; see plan Sec.1), but not enforced by this script.
  3. Intercom's weekly-cadence conversation_statistics cannot attribute
     WHICH sweep closed a given conversation - only machine-vs-human. Per-
     sweep attribution is out of scope (see plan checklist item 5).
  4. This report reads CAROLINE_ADMIN_ID; the sweeps
     (close-duplicate-conversations.py, close-resolved-conversations.py,
     resolution-matcher.py) post through scripts/lib/intercom_identity.py.
     Since 2026-09-01 that resolver PINS the sweeps to 5763097 — an
     INTERCOM_ADMIN_ID override is ignored, not obeyed — so the old divergence
     hazard (sweeps closing as one id while this report checks another) can no
     longer be caused from that side. It can still be caused from THIS side:
     overriding CAROLINE_ADMIN_ID here makes the report check for an id the
     sweeps never post under, and the counts silently read as human-resolved.
  5. The ratio's population is a LAGGED ARRIVAL COHORT (inbound conversations
     created 7-14 days ago, judged as of report time), NOT "this week's
     arrivals". Judging same-week arrivals against same-week closes
     double-biases: it undercounts still-in-progress conversations AND
     inflates the youngest machine-closes, which had no time to reopen. See
     cohort_partition().
  6. Arrival-lag alone is not enough: a cohort member (created 7-14 days ago)
     can still be machine-closed the instant before the report runs, with
     zero reopen-observation time. So the numerator ALSO requires the last
     close to be at least one window old (last_close_at <= cutoff_7d); a
     more-recently-closed member stays in total_inbound but is not yet
     credited. See resolved_counts().

Env:
  MUSOAI_INTERCOM_TOKEN       required
  SLA_SKIP_HOST_GUARD         optional, "1" to run off ovh-node-8 (tests)
  SLA_HOSTNAME_OVERRIDE       optional, override perceived hostname (tests)
  SLA_SUMMARY_CHANNEL         optional, default C0ANM0PN9L5 (#cs_chats)
  SLA_SLACK_ACCOUNT           optional, default operations
  SLACK_NOTIFY_CONFIG         optional, default /root/.openclaw-main/openclaw.json
  INTERCOM_WORKSPACE_ID       optional, default dwjzhcge
  SLA_NOW                     optional, epoch override (tests)
  CS_SLA_STATE_DIR            optional, default /var/lib/cs-sla-report/
  CAROLINE_ADMIN_ID           optional, default 5763097 - the automated-sweep
                               closer identity used by the AI-resolved /
                               total-inbound ratio (last_closed_by_id ==
                               this id means machine-closed). NOT used for
                               the first-response admin/bot split - see the
                               module docstring on why that split stays
                               unavailable.
  MUSO_CLI_BIN                optional; overrides the muso CLI path for the
                               unverified-credit queue-depth read. When unset
                               the binary is resolved from PATH, else
                               /usr/local/bin/muso (see _resolve_muso_bin)

Flags:
  --post          actually post the report to Slack (default: dry-run —
                   print to stdout, post nothing)
  --window-days   trailing window size in days (default 7)
  --self-test     run the inline self-test and exit

Exit codes: 0 ok; 1 usage/env error or failed Slack delivery (--post);
            2 self-test failure.
"""
import argparse
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

INTERCOM_API = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
SLACK_API = "https://slack.com/api/chat.postMessage"
DEFAULT_SUMMARY_CHANNEL = "C0ANM0PN9L5"  # #cs_chats
DEFAULT_WORKSPACE_ID = "dwjzhcge"
DEFAULT_WINDOW_DAYS = 7
DEFAULT_STATE_DIR = "/var/lib/cs-sla-report/"
DEFAULT_CAROLINE_ADMIN_ID = "5763097"
RESIDUE_HOURS = 24


# --------------------------------------------------------------------------
# Network seam (module-level so tests monkeypatch these, never real HTTP).
# Copied from cs-needs-human-digest.py's pattern — deliberately standalone,
# see module docstring.
# --------------------------------------------------------------------------
def _retry_json(req, attempts=4):
    for a in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except urllib.error.URLError:
            if a == attempts - 1:
                raise
            time.sleep(2 * (a + 1))


def intercom_search(token, body):
    req = urllib.request.Request(
        f"{INTERCOM_API}/conversations/search",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Content-Type": "application/json", "Intercom-Version": INTERCOM_VERSION},
        method="POST")
    return _retry_json(req)


def _conv_record(c):
    stats = c.get("statistics") or {}
    return {
        "id": c.get("id"),
        "created_at": c.get("created_at") or 0,
        "lar": stats.get("last_admin_reply_at") or 0,
        "lcr": stats.get("last_contact_reply_at") or 0,
        "first_admin_reply_at": stats.get("first_admin_reply_at"),
        "count_reopens": stats.get("count_reopens") or 0,
        "has_statistics": bool(c.get("statistics")),
        "is_inbound": is_inbound_conv(c),
        "last_closed_by_id": stats.get("last_closed_by_id"),
        "last_close_at": stats.get("last_close_at") or 0,
    }


def fetch_window_convs(token, cutoff_epoch, limit=0):
    """All conversations (any state) created since cutoff_epoch — the SLA
    window's denominator for first-response time and reopen rate."""
    convs = []
    after = None
    while True:
        body = {"query": {"field": "created_at", "operator": ">", "value": cutoff_epoch},
                "pagination": {"per_page": 150}}
        if after:
            body["pagination"]["starting_after"] = after
        data = intercom_search(token, body)
        for c in data.get("conversations", []):
            convs.append(_conv_record(c))
            if limit and len(convs) >= limit:
                return convs
        nxt = (data.get("pages") or {}).get("next")
        after = nxt.get("starting_after") if isinstance(nxt, dict) else None
        if not nxt or not after:
            break
    return convs


def fetch_open_convs(token, limit=0):
    """Currently OPEN conversations (any created_at) — the residue snapshot's
    population. Mirrors cs-needs-human-digest.py's fetch_open_convs."""
    convs = []
    after = None
    while True:
        body = {"query": {"field": "state", "operator": "=", "value": "open"},
                "pagination": {"per_page": 150}}
        if after:
            body["pagination"]["starting_after"] = after
        data = intercom_search(token, body)
        for c in data.get("conversations", []):
            convs.append(_conv_record(c))
            if limit and len(convs) >= limit:
                return convs
        nxt = (data.get("pages") or {}).get("next")
        after = nxt.get("starting_after") if isinstance(nxt, dict) else None
        if not nxt or not after:
            break
    return convs


CUSTOMER_AUTHOR_TYPES = {"user", "lead", "contact"}


def is_inbound_conv(c):
    """Copied from cs-needs-human-digest.py's is_inbound_conv (see its
    docstring for the Intercom 2.11 spec citation) — deliberately duplicated,
    not imported, per the WS1 spec."""
    src = c.get("source") or {}
    delivered_as = src.get("delivered_as")
    if delivered_as:
        return delivered_as == "customer_initiated"
    au = src.get("author") or {}
    return au.get("type") in CUSTOMER_AUTHOR_TYPES


def waiting_since(c):
    """Copied from cs-needs-human-digest.py's waiting_since — the real moment
    we started owing this customer a reply: their last reply time, or (for a
    never-replied conversation) the conversation's created_at."""
    return c["lcr"] or c.get("created_at") or 0


def mask_email(email):
    """`a***@***` masking — copied from cs-needs-human-digest.py's mask_email."""
    if not email:
        return "no email"
    local = email.split("@", 1)[0]
    return f"{local[0]}***@***" if local else "***@***"


def inbound_only(convs):
    """Keep only INBOUND (customer-initiated) conversations. The SLA target is
    first action on INBOUND traffic; outbound/campaign/bot-initiated threads
    (is_inbound False) would otherwise pad the first-response and reopen
    denominators and skew the latency distribution + rate. _conv_record stamps
    is_inbound on every fetched conversation via is_inbound_conv (Intercom 2.11
    delivered_as / author-type spec)."""
    return [c for c in convs if c.get("is_inbound")]


# --------------------------------------------------------------------------
# Pure metric computations (no network — directly unit-testable).
# --------------------------------------------------------------------------
def _percentile(sorted_values, pct):
    """Linear-interpolation percentile over an already-sorted list (matches
    statistics.median at pct=50 for both odd and even-length inputs).
    pct in [0, 100]."""
    if not sorted_values:
        return None
    if len(sorted_values) == 1:
        return sorted_values[0]
    rank = pct / 100.0 * (len(sorted_values) - 1)
    lo = int(rank)
    hi = min(lo + 1, len(sorted_values) - 1)
    frac = rank - lo
    return sorted_values[lo] + (sorted_values[hi] - sorted_values[lo]) * frac


def first_response_distribution(convs):
    """created_at -> first_admin_reply_at, over `convs`. A conversation with
    no statistics object, or a statistics object with no first_admin_reply_at,
    is counted "unknown" and reported (fail-loud in the summary), never
    silently dropped. A missing/zero created_at (bad data) or a
    first_admin_reply_at earlier than created_at (inconsistent data) is also
    counted "unknown" rather than yielding a garbage or silently-clamped
    duration."""
    known = []
    unknown_count = 0
    for c in convs:
        fra = c.get("first_admin_reply_at")
        created_at = c.get("created_at") or 0
        if (not c.get("has_statistics", True) or fra is None
                or not created_at or fra < created_at):
            unknown_count += 1
            continue
        known.append(fra - created_at)
    known.sort()
    return {
        "known_count": len(known),
        "unknown_count": unknown_count,
        "median_seconds": _percentile(known, 50),
        "p90_seconds": _percentile(known, 90),
    }


def reopen_rate(convs):
    """FRACTION of replied conversations that reopened at least once — NOT the
    average reopen count. A reopen means a "close" that didn't actually resolve
    the customer, so the honest signal is how many conversations came back, not
    how many total reopen events fired: one conversation reopened 3 times is ONE
    unresolved close, not three (dividing total events by conversations would
    render 300%). A conversation nobody has replied to yet is excluded from both
    numerator and denominator (it cannot have reopened). total_reopens is kept
    as a diagnostic (the raw event count)."""
    replied = [c for c in convs if c.get("has_statistics", True)
               and c.get("first_admin_reply_at") is not None]
    reopened = [c for c in replied if (c.get("count_reopens") or 0) > 0]
    total_reopens = sum(c.get("count_reopens") or 0 for c in replied)
    if not replied:
        return {"total_reopens": total_reopens, "reopened_conversations": 0,
                "replied_conversations": 0, "rate": None}
    return {
        "total_reopens": total_reopens,
        "reopened_conversations": len(reopened),
        "replied_conversations": len(replied),
        "rate": len(reopened) / len(replied),
    }


def cohort_partition(convs, cutoff_14d, cutoff_7d):
    """Split an ALREADY-widened fetch (any created_at > cutoff_14d) into the
    two independent populations the SLA report needs:
      - trailing_7d: created_at > cutoff_7d - the EXISTING first-response /
        reopen-rate population (#721), UNCHANGED by the lagged-cohort fix.
      - cohort: cutoff_14d < created_at <= cutoff_7d - a full 7-day arrival
        cohort that is now itself at least 7 days old, used ONLY for the
        AI-resolved / total-inbound ratio (docs/plans/autonomous-cs-machine.md
        Sec.5). Judging "this week's arrivals" against "this week's closes"
        double-biases the ratio: it undercounts still-in-progress arrivals
        AND inflates the youngest machine-closes, which had zero
        reopen-observation window. Lagging the cohort by one full window
        gives every member >=7 days to be worked. (The matching >=7-day
        reopen-observation guarantee is enforced separately, on the CLOSE
        timestamp, by resolved_counts - arrival-lag alone does not bound how
        recently a cohort member was closed.)"""
    trailing_7d = [c for c in convs if c["created_at"] > cutoff_7d]
    cohort = [c for c in convs if cutoff_14d < c["created_at"] <= cutoff_7d]
    return trailing_7d, cohort


def resolved_counts(convs, close_cutoff, caroline_admin_id=DEFAULT_CAROLINE_ADMIN_ID):
    """AI-resolved / human-resolved split over `convs` - callers pass the
    lagged ARRIVAL COHORT (see cohort_partition), not the trailing-7d
    population (docs/plans/autonomous-cs-machine.md Sec.5's headline honesty
    metric). A conversation is counted toward a bucket only when ALL hold:
      - it has been CLOSED at least once (last_closed_by_id present) -
        never-closed conversations contribute to neither bucket;
      - count_reopens == 0 - a close that reopened did not actually resolve
        the customer (Sec.5: "closed is not resolved");
      - its last close is at least one observation window old
        (0 < last_close_at <= close_cutoff). Lagging the ARRIVAL by one window
        (cohort_partition) is NOT sufficient on its own: a cohort member can
        still be machine-closed the instant before the report runs, with zero
        chance to reopen, and crediting it would inflate the metric exactly as
        a same-week cohort would. The reopen-observation window is therefore
        enforced on the CLOSE timestamp, not just on arrival.
    A conversation failing any of these (never-closed, reopened, or closed too
    recently / with no close timestamp) is excluded from BOTH ai_resolved and
    human_resolved but STAYS in the caller's total_inbound denominator
    (recency/reopen-adjusting the denominator would inflate the ratio, the
    exact gaming mode Sec.5 warns against). See the module docstring's caveats
    (last_closed_by_id identifies the closer, not a per-problem fix credit;
    assumes no human ever acts as the Caroline admin id; no per-sweep
    attribution)."""
    ai_resolved = 0
    human_resolved = 0
    for c in convs:
        closer = c.get("last_closed_by_id")
        if closer is None:
            continue
        if (c.get("count_reopens") or 0) > 0:
            continue
        last_close_at = c.get("last_close_at") or 0
        # Not observably aged - missing close timestamp, or closed more
        # recently than one full window: keep in the denominator, credit
        # neither closer (conservative, can only under-count automation).
        if not 0 < last_close_at <= close_cutoff:
            continue
        if str(closer) == str(caroline_admin_id):
            ai_resolved += 1
        else:
            human_resolved += 1
    return {"ai_resolved": ai_resolved, "human_resolved": human_resolved}


def ai_resolved_ratio(resolved, total_inbound):
    """ai_resolved / total_inbound, or None if there was no inbound traffic
    this week (avoids a ZeroDivisionError and a meaningless 0% / n/a
    ambiguity)."""
    if not total_inbound:
        return None
    return resolved["ai_resolved"] / total_inbound


def residue_over_24h(convs, now_epoch):
    """Count + 3 oldest of currently-open conversations where the customer
    spoke last (same needs-human tie-break as cs-needs-human-digest.py's
    bucket_conversations: lar<=lcr is customer-last; the lar==0/lcr==0 tie
    is disambiguated by is_inbound, an outbound tie is NOT customer-last)
    and waiting > RESIDUE_HOURS."""
    stale = []
    for c in convs:
        if c["lar"] == 0 and c["lcr"] == 0:
            customer_last = c.get("is_inbound", True)
        else:
            customer_last = c["lar"] <= c["lcr"]
        if not customer_last:
            continue
        since = waiting_since(c)
        if now_epoch - since > RESIDUE_HOURS * 3600:
            stale.append(c)
    stale.sort(key=waiting_since)  # oldest (smallest waiting_since) first
    return {"count": len(stale), "oldest": stale[:3]}


def _resolve_muso_bin():
    """The sanctioned muso CLI path, resolved DETERMINISTICALLY (mirrors
    scripts/lib/slack-notify.sh:44 and clickup-muso.sh:55): explicit
    MUSO_CLI_BIN wins; else `muso` on PATH; else the deployed
    /usr/local/bin/muso. Returns None only when none of those exist — the
    metric then reports unavailable rather than invoking a guessed bad path.
    (The systemd unit does NOT export MUSO_CLI_BIN, so relying on the env var
    alone left this telemetry permanently dead in production.)"""
    explicit = os.environ.get("MUSO_CLI_BIN")
    if explicit:
        return explicit
    found = shutil.which("muso")
    if found:
        return found
    if os.access("/usr/local/bin/muso", os.X_OK):
        return "/usr/local/bin/muso"
    return None


def unverified_credit_queue_depth():
    """Read-only unverified-credit queue depth via
    `<muso> api GET /admin/credit-requests/counts --json` (the real read verb
    for pending/unverified credit requests — see skills-all/muso-cli/SKILL.md's
    `muso api GET` generic escape hatch and
    skills-all/muso-ops-credits/SKILL.md's `GET /admin/credit-requests/counts`
    — there is no dedicated `list-unverified` CLI verb). The binary is resolved
    by _resolve_muso_bin (sanctioned path, never a guess). Any subprocess/parse
    failure is reported in `note`, never raised — this metric must never crash
    the whole report."""
    bin_path = _resolve_muso_bin()
    if not bin_path:
        return {"count": None, "note": "unavailable (muso CLI not found)"}
    try:
        proc = subprocess.run(
            [bin_path, "api", "GET", "/admin/credit-requests/counts", "--json"],
            capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        return {"count": None, "note": f"subprocess error: {type(e).__name__}: {e}"}
    if proc.returncode != 0:
        return {"count": None,
                "note": f"exit {proc.returncode}: {(proc.stderr or proc.stdout).strip()[:200]}"}
    try:
        data = json.loads(proc.stdout)
    except ValueError as e:
        return {"count": None, "note": f"unparseable output: {e}"}
    # Response envelope shape is not documented for this endpoint (unlike the
    # list endpoints' .body.data.items[]/.count) — walk defensively for a
    # "pending" figure at the plausible nesting levels rather than assume one.
    body = data.get("body") if isinstance(data, dict) else None
    for candidate in (
        data,
        data.get("data") if isinstance(data, dict) else None,
        body.get("data") if isinstance(body, dict) else None,
    ):
        if isinstance(candidate, dict) and "pending" in candidate:
            try:
                return {"count": int(candidate["pending"]), "note": "ok"}
            except (TypeError, ValueError):
                continue
    return {"count": None, "note": f"unrecognized response shape: {str(data)[:200]}"}


def persist_rollup(rollup, state_dir, now_epoch):
    """Write the JSON rollup to <state_dir>/sla-<ISO-date>.json (UTC date of
    now_epoch). Returns the path written."""
    date_str = time.strftime("%Y-%m-%d", time.gmtime(now_epoch))
    pathlib.Path(state_dir).mkdir(parents=True, exist_ok=True)
    path = os.path.join(state_dir, f"sla-{date_str}.json")
    with open(path, "w") as f:
        json.dump(rollup, f, indent=2, sort_keys=True)
    return path


# --------------------------------------------------------------------------
# Slack rendering + delivery (copied pattern from cs-needs-human-digest.py).
# --------------------------------------------------------------------------
def _iso_date(epoch):
    """UTC calendar date of an epoch - used only to label the AI-resolved
    cohort window (so the report reads "cohort: created X..Y, judged Z"
    rather than an unlabeled ratio a reader could mistake for "this week")."""
    return time.strftime("%Y-%m-%d", time.gmtime(epoch))


def _fmt_seconds(seconds):
    if seconds is None:
        return "n/a"
    if seconds < 3600:
        return f"{seconds / 60:.0f}m"
    if seconds < 86400:
        return f"{seconds / 3600:.1f}h"
    return f"{seconds / 86400:.1f}d"


def render_text_report(rollup):
    fr = rollup["first_response"]
    residue = rollup["residue"]
    reopen = rollup["reopen_rate"]
    credit = rollup["credit_queue"]
    ai_metric = rollup["ai_resolved_metric"]
    lines = [
        f"CS weekly SLA report (trailing {rollup['window_days']}d)",
        f"first response: median {_fmt_seconds(fr['median_seconds'])}, "
        f"p90 {_fmt_seconds(fr['p90_seconds'])} "
        f"(known {fr['known_count']}, unknown {fr['unknown_count']})",
        "  # combined admin+bot row — Intercom's statistics object exposes no "
        "replying-admin id for first_admin_reply_at, only last_closed_by_id.",
        f"residue >24h: {residue['count']} open, customer waiting",
    ]
    now_epoch = rollup.get("now_epoch") or int(time.time())
    for c in residue["oldest"]:
        age = _fmt_seconds(now_epoch - waiting_since(c))
        lines.append(f"  {c['id']}  waiting {age}")
    cohort_label = (f"cohort: inbound created {ai_metric['cohort_start_date']}.."
                     f"{ai_metric['cohort_end_date']}, judged {ai_metric['judged_date']}")
    if ai_metric["ratio"] is None:
        lines.append(f"AI-resolved ({cohort_label}; reopen-adjusted): unavailable "
                      "(no inbound conversations in the cohort window)")
    else:
        lines.append(
            f"AI-resolved ({cohort_label}; reopen-adjusted): {ai_metric['ai_resolved']} "
            f"({ai_metric['ratio']:.1%}) of {ai_metric['total_inbound']}")
    lines.append(f"human-closed: {ai_metric['human_resolved']}")
    if reopen["rate"] is None:
        lines.append("reopen rate: unavailable (no window conversations with an admin reply)")
    else:
        lines.append(
            f"reopen rate: {reopen['rate']:.1%} "
            f"({reopen['reopened_conversations']} of {reopen['replied_conversations']} "
            f"replied conversations reopened; {reopen['total_reopens']} total reopen events)")
    lines.append(
        "  # AI-resolved = last closed by an automated sweep (last_closed_by_id) "
        "with zero reopens - not a per-problem fix credit; see script docstring caveats.")
    lines.append(
        "  # cohort is lagged one window (arrivals 7-14d old, not this week's) AND only "
        "closes >=1 window old count, so every credited member had >=7d of reopen observation.")
    if credit["count"] is None:
        lines.append(f"unverified-credit queue depth: {credit['note']}")
    else:
        lines.append(f"unverified-credit queue depth: {credit['count']}")
    return "\n".join(lines)


def build_report_blocks(rollup):
    text = render_text_report(rollup)
    return [
        {"type": "header", "text": {"type": "plain_text", "text": "CS weekly SLA report"}},
        {"type": "section", "text": {"type": "mrkdwn",
         "text": "```" + text.replace("`", "'") + "```"}},
    ]


def _read_slack_token(config_path, account):
    try:
        with open(config_path) as f:
            cfg = json.load(f)
        return cfg["channels"]["slack"]["accounts"][account]["botToken"]
    except (OSError, KeyError, ValueError, TypeError):
        return None


def post_slack_report(blocks, text, channel, config_path, account):
    """Best-effort post — NEVER raises. Returns bool. Copied pattern from
    cs-needs-human-digest.py's post_slack_digest."""
    token = _read_slack_token(config_path, account)
    if not token:
        print(f"WARN: no Slack token for account '{account}' in {config_path}; post skipped",
              file=sys.stderr)
        return False
    try:
        req = urllib.request.Request(
            SLACK_API,
            data=json.dumps({"channel": channel, "text": text, "blocks": blocks,
                             "unfurl_links": False, "unfurl_media": False}).encode(),
            headers={"Authorization": f"Bearer {token}",
                     "Content-Type": "application/json; charset=utf-8"},
            method="POST")
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.load(resp)
        if not body.get("ok"):
            print(f"WARN: Slack post failed: {body.get('error')}", file=sys.stderr)
            return False
        return True
    except Exception as e:  # noqa: BLE001 — best-effort by contract.
        print(f"WARN: Slack post error: {type(e).__name__}: {str(e)[:140]}", file=sys.stderr)
        return False


# --------------------------------------------------------------------------
# Inline self-test.
# --------------------------------------------------------------------------
def _self_test():
    c1 = conv_fixture("c1", created_at=1000, first_admin_reply_at=1100)
    c2 = conv_fixture("c2", created_at=1000, first_admin_reply_at=1300)
    fr = first_response_distribution([c1, c2])
    assert fr["known_count"] == 2 and fr["unknown_count"] == 0, fr
    assert fr["median_seconds"] == 200, fr

    unknown = conv_fixture("c3", created_at=1000, first_admin_reply_at=None,
                            has_statistics=False)
    fr2 = first_response_distribution([c1, unknown])
    assert fr2["known_count"] == 1 and fr2["unknown_count"] == 1, fr2

    zero_created = conv_fixture("c4", created_at=0, first_admin_reply_at=1_700_000_000)
    fr3 = first_response_distribution([zero_created])
    assert fr3["known_count"] == 0 and fr3["unknown_count"] == 1, fr3

    rr = reopen_rate([conv_fixture("r1", first_admin_reply_at=1, count_reopens=1),
                       conv_fixture("r2", first_admin_reply_at=1, count_reopens=0)])
    assert rr["rate"] == 0.5, rr
    # reopen_rate is the FRACTION of conversations reopened, not avg reopens:
    # one conversation reopened twice + one never = 50%, never 100%/200%.
    rr2 = reopen_rate([conv_fixture("x1", first_admin_reply_at=1, count_reopens=2),
                       conv_fixture("x2", first_admin_reply_at=1, count_reopens=0)])
    assert rr2["rate"] == 0.5 and rr2["reopened_conversations"] == 1, rr2

    now = 1_000_000
    stale = conv_fixture("STALE", lar=100, lcr=100, created_at=0)
    fresh = conv_fixture("FRESH", lar=0, lcr=now - 3600, created_at=0)
    residue = residue_over_24h([stale, fresh], now)
    assert residue["count"] == 1 and residue["oldest"][0]["id"] == "STALE", residue

    # resolved_counts: machine-close (Caroline id) aged >=1 window with no
    # reopens -> ai_resolved; human-close -> human_resolved; a machine-close
    # that reopened -> neither ("closed" is not "resolved" per plan Sec.5); a
    # machine-close more recent than close_cutoff -> neither (no reopen
    # observation yet), but it still counts in the denominator.
    cc = 1000
    ai_c = conv_fixture("ai1", last_closed_by_id="5763097", count_reopens=0, last_close_at=100)
    human_c = conv_fixture("hum1", last_closed_by_id="9999999", count_reopens=0, last_close_at=100)
    reopened_ai_c = conv_fixture("ai2", last_closed_by_id="5763097", count_reopens=1, last_close_at=100)
    recent_ai_c = conv_fixture("ai3", last_closed_by_id="5763097", count_reopens=0, last_close_at=cc + 1)
    never_closed = conv_fixture("open1", last_closed_by_id=None)
    convs = [ai_c, human_c, reopened_ai_c, recent_ai_c, never_closed]
    resolved = resolved_counts(convs, close_cutoff=cc)
    assert resolved == {"ai_resolved": 1, "human_resolved": 1}, resolved
    # recent_ai_c is excluded from the numerator but stays in total_inbound.
    assert ai_resolved_ratio(resolved, total_inbound=len(convs)) == 0.2
    assert ai_resolved_ratio(resolved, total_inbound=0) is None

    # cohort_partition: a conv created 3d ago (too recent) lands in trailing_7d
    # only, never the cohort; a conv created 10d ago (7-14d old) lands in the
    # cohort only, never trailing_7d.
    cohort_now = 20 * 86400
    cohort_cutoff_7d = cohort_now - 7 * 86400
    cohort_cutoff_14d = cohort_now - 14 * 86400
    too_recent = conv_fixture("recent", created_at=cohort_now - 3 * 86400)
    in_cohort = conv_fixture("cohort1", created_at=cohort_now - 10 * 86400)
    trailing, cohort = cohort_partition(
        [too_recent, in_cohort], cohort_cutoff_14d, cohort_cutoff_7d)
    assert [c["id"] for c in trailing] == ["recent"], trailing
    assert [c["id"] for c in cohort] == ["cohort1"], cohort

    assert mask_email("joe@example.com") == "j***@***"

    # inbound_only: outbound/campaign threads are dropped from the SLA
    # first-response + reopen population (they'd skew an INBOUND-only target).
    only_in = inbound_only([conv_fixture("IN", is_inbound=True),
                            conv_fixture("OUT", is_inbound=False)])
    assert [c["id"] for c in only_in] == ["IN"], only_in

    return True


def conv_fixture(cid, created_at=0, lar=0, lcr=0, first_admin_reply_at=None,
                  count_reopens=0, has_statistics=True, is_inbound=True,
                  last_closed_by_id=None, last_close_at=0):
    return {"id": cid, "created_at": created_at, "lar": lar, "lcr": lcr,
            "first_admin_reply_at": first_admin_reply_at,
            "count_reopens": count_reopens, "has_statistics": has_statistics,
            "is_inbound": is_inbound, "last_closed_by_id": last_closed_by_id,
            "last_close_at": last_close_at}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--post", action="store_true",
                    help="actually post the report to Slack (default: dry-run)")
    ap.add_argument("--window-days", type=int, default=DEFAULT_WINDOW_DAYS,
                    help="trailing window size in days")
    ap.add_argument("--self-test", action="store_true",
                    help="run the inline self-test and exit")
    args = ap.parse_args()

    try:
        _self_test()
    except AssertionError as e:
        print(f"cs-sla-report: SELF-TEST FAILED: {e}", file=sys.stderr)
        return 2
    if args.self_test:
        print("self-test ok")
        return 0

    hostname = os.environ.get("SLA_HOSTNAME_OVERRIDE") or socket.gethostname()
    if os.environ.get("SLA_SKIP_HOST_GUARD") != "1" and hostname != "ovh-node-8":
        print("cs-sla-report: not on ovh-node-8 — refusing "
              "(set SLA_SKIP_HOST_GUARD=1 to override)", file=sys.stderr)
        return 0

    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        print("cs-sla-report: MUSOAI_INTERCOM_TOKEN is required", file=sys.stderr)
        return 1

    now_epoch = int(os.environ.get("SLA_NOW") or time.time())
    cutoff_7d = now_epoch - args.window_days * 86400
    # Widened fetch: the AI-resolved ratio needs a LAGGED arrival cohort (see
    # cohort_partition docstring) one full window further back than the
    # existing trailing population - one Intercom fetch covers both, sliced
    # locally, rather than a second search call.
    cutoff_14d = now_epoch - 2 * args.window_days * 86400

    window_convs = fetch_window_convs(token, cutoff_14d)
    trailing_7d, cohort = cohort_partition(window_convs, cutoff_14d, cutoff_7d)
    # First-response + reopen are INBOUND-only metrics (see inbound_only) over
    # the EXISTING trailing-7d population (#721, unchanged by this fix);
    # outbound/campaign threads must not enter their denominators.
    inbound_window = inbound_only(trailing_7d)
    # The AI-resolved ratio uses the separate, lagged cohort population -
    # also inbound-only for the same reason.
    inbound_cohort = inbound_only(cohort)
    open_convs = fetch_open_convs(token)

    caroline_admin_id = os.environ.get("CAROLINE_ADMIN_ID", DEFAULT_CAROLINE_ADMIN_ID)
    total_inbound = len(inbound_cohort)
    # close_cutoff == cutoff_7d: only closes that are themselves at least one
    # window old count toward the numerator (see resolved_counts) - a cohort
    # member closed within the last window stays in total_inbound but is not
    # yet credited, so a just-closed conversation cannot inflate the ratio.
    resolved = resolved_counts(inbound_cohort, cutoff_7d, caroline_admin_id)

    rollup = {
        "window_days": args.window_days,
        "now_epoch": now_epoch,
        "first_response": first_response_distribution(inbound_window),
        "reopen_rate": reopen_rate(inbound_window),
        "ai_resolved_metric": {
            "total_inbound": total_inbound,
            "ai_resolved": resolved["ai_resolved"],
            "human_resolved": resolved["human_resolved"],
            "ratio": ai_resolved_ratio(resolved, total_inbound),
            "cohort_start_date": _iso_date(cutoff_14d),
            "cohort_end_date": _iso_date(cutoff_7d - 1),
            "judged_date": _iso_date(now_epoch),
        },
        "residue": residue_over_24h(open_convs, now_epoch),
        "credit_queue": unverified_credit_queue_depth(),
    }
    # oldest[] carries full conv dicts for rendering; keep the persisted JSON
    # rollup lean (ids + waiting age only, no PII, no rendering internals).
    persisted = dict(rollup)
    persisted["residue"] = {
        "count": rollup["residue"]["count"],
        "oldest": [{"id": c["id"], "waiting_seconds": now_epoch - waiting_since(c)}
                   for c in rollup["residue"]["oldest"]],
    }
    state_dir = os.environ.get("CS_SLA_STATE_DIR", DEFAULT_STATE_DIR)
    try:
        path = persist_rollup(persisted, state_dir, now_epoch)
        print(f"rollup persisted: {path}")
    except OSError as e:
        print(f"WARN: could not persist rollup to {state_dir}: {e}", file=sys.stderr)

    text = render_text_report(rollup)
    print(text)

    if not args.post:
        print("DRY-RUN — nothing posted. Re-run with --post to post to Slack.")
        return 0

    blocks = build_report_blocks(rollup)
    channel = os.environ.get("SLA_SUMMARY_CHANNEL", DEFAULT_SUMMARY_CHANNEL)
    cfg = os.environ.get("SLACK_NOTIFY_CONFIG", "/root/.openclaw-main/openclaw.json")
    account = os.environ.get("SLA_SLACK_ACCOUNT", "operations")
    posted = post_slack_report(blocks, text, channel, cfg, account)
    print(f"slack post: {'posted' if posted else 'skipped/failed'} -> {channel}")
    return 0 if posted else 1


if __name__ == "__main__":
    sys.exit(main())
