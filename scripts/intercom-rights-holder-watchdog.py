#!/usr/bin/env python3
"""Intercom rights-holder / urgent-inbound watchdog -> #cs_priority. Deterministic: no LLM.

Born from the 2026-10-09 Sony Music Labels (artist: natori) miss: a name-correction
request with a 24 h deadline reached Intercom (conv 215476320739784), was auto-assigned
to Caroline, and alerted nobody — no tag, `priority: not_priority`, no Slack post. It never
produced a ClickUp ticket, so ClickUp-sourced watchdogs (ads-inquiry-watchdog.sh) are
structurally blind to it. The source here is Intercom itself.

Every tick: read conversations UPDATED in the window (so an old thread touched today is
scanned), and fire when
  (a) the opening sender's domain is on the rights-holder list (boundary match), OR
  (b) the subject/opening body carries a listed keyword.
Both lists are DATA files (scripts/data/rights-holder-{domains,keywords}.txt, env
override) — adding a label or a word is a config change, not a code change.

Per match, in this order (CTO ruling R6 — same as ads-inquiry-watchdog.sh:20-22):
  1. Slack post to #cs_priority as the `operations` bot, mentioning Nick + Jan;
  2. only after a CONFIRMED post: Intercom tag `priority-pinged` on the conversation;
  3. only then: the ledger entry.
A failed post therefore leaves the conversation untagged and the ledger unwritten, so it
retries next tick and is never suppressed by its own dedupe marker. A failed tag after a
confirmed post still writes the ledger (the page went out; never re-page it).
The tag is a conversation TAG (POST /conversations/{id}/tags), not a conversation part,
so scripts/intercom-ops-write.sh (which gates parts/replies) does not apply.

Usage:
  python3 scripts/intercom-rights-holder-watchdog.py                    # live tick (cron)
  python3 scripts/intercom-rights-holder-watchdog.py --dry-run          # print matches only
  python3 scripts/intercom-rights-holder-watchdog.py --dry-run --window-hours 168
  python3 scripts/intercom-rights-holder-watchdog.py --dry-run --at 2026-10-09T12:00:00Z

Flags (env fallbacks):
  --dry-run          print matches as JSON; no Slack, no tag, no ledger, no lockfile
  --at <iso|epoch>   evaluate as-if at that instant (backtest)
  --window-hours N   scan conversations updated in the last N h   (default 6, WATCHDOG_WINDOW_HOURS)
  --grace-minutes N  end the window N min ago                      (default 2, WATCHDOG_GRACE_MINUTES)

Env:
  MUSOAI_INTERCOM_TOKEN          required — Intercom Bearer token
  MUSO_SLACK_BOT_TOKEN_OPERATIONS / SLACK_BOT_TOKEN / openclaw config — Slack token
                                 (operations bot preferred: devops is NOT a member of
                                 #cs_priority and 404s channel_not_found)
  RIGHTS_HOLDER_CHANNEL          default C0BBTAVP44X (#cs_priority)
  RIGHTS_HOLDER_MENTION_IDS      default U0AL36NADEY,U038BM16T7W (Nick, Jan)
  RIGHTS_HOLDER_DOMAINS_FILE     default scripts/data/rights-holder-domains.txt
  RIGHTS_HOLDER_KEYWORDS_FILE    default scripts/data/rights-holder-keywords.txt
  RIGHTS_HOLDER_LEDGER_PATH      default /var/lib/intercom-rights-holder-watchdog/seen.json
  RIGHTS_HOLDER_LOCKFILE         default /var/run/intercom-rights-holder-watchdog.lock
  RIGHTS_HOLDER_SKIP_HOST_GUARD  1 = skip the ovh-node-8 host guard (tests)
  CLICKUP_API_KEY, CLICKUP_LIST_ID  optional — look up the ticket Caroline filed
  INTERCOM_WORKSPACE_ID          default dwjzhcge

Exit codes: 0 ran cleanly · 1 usage/env · 2 Intercom/Slack error (a failed post retries next tick)
"""
import argparse
import fcntl
import importlib.util
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))
from lib.intercom_identity import resolve_admin_id  # noqa: E402

# Reuse the deterministic halves of the data-complaint watchdog (fetch, strip, escape,
# deeplink, Slack token + post, ledger io). Its AI-clustering half is not touched.
_spec = importlib.util.spec_from_file_location(
    "intercom_data_complaint_watchdog", _HERE / "intercom-data-complaint-watchdog.py")
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)

DEFAULT_DOMAINS_FILE = str(_HERE / "data" / "rights-holder-domains.txt")
DEFAULT_KEYWORDS_FILE = str(_HERE / "data" / "rights-holder-keywords.txt")
DEFAULT_CHANNEL = "C0BBTAVP44X"  # #cs_priority
DEFAULT_MENTION_IDS = "U0AL36NADEY,U038BM16T7W"  # Nick, Jan (scripts/intercom-ops-write.sh:67,79)
DEFAULT_LEDGER = "/var/lib/intercom-rights-holder-watchdog/seen.json"
DEFAULT_LOCKFILE = "/var/run/intercom-rights-holder-watchdog.lock"
DEFAULT_CLICKUP_LIST = "901000600160"
DEDUPE_TAG = "priority-pinged"
LEDGER_RETENTION_S = 30 * 86400
HOST = "ovh-node-8"


# ── configurable lists ───────────────────────────────────────────────────────
def load_list(path):
    """One entry per line; blank lines and `#` comments dropped."""
    with open(path, encoding="utf-8") as f:
        lines = (ln.strip() for ln in f)
        return [ln for ln in lines if ln and not ln.startswith("#")]


def load_domains():
    return load_list(os.environ.get("RIGHTS_HOLDER_DOMAINS_FILE") or DEFAULT_DOMAINS_FILE)


def load_keywords():
    return load_list(os.environ.get("RIGHTS_HOLDER_KEYWORDS_FILE") or DEFAULT_KEYWORDS_FILE)


# ── matchers ─────────────────────────────────────────────────────────────────
def _domain_re(entry):
    """`sonymusic.*` -> any suffix; anything else is the exact domain. Both anchor
    on a label boundary (start of host, or a `.`), never a bare substring."""
    entry = entry.strip().lower()
    if entry.endswith(".*"):
        return re.compile(r"(?:^|\.)" + re.escape(entry[:-2]) + r"\.[a-z0-9.\-]+$")
    return re.compile(r"(?:^|\.)" + re.escape(entry) + r"$")


def match_domain(email, entries):
    """The first domain entry the sender's host matches, else None."""
    host = (email or "").rpartition("@")[2].strip().lower()
    if not host or "@" not in (email or ""):
        return None
    for e in entries:
        if e.startswith("#") or not e.strip():
            continue
        if _domain_re(e).search(host):
            return e
    return None


def _keyword_re(entry):
    if entry.startswith("re:"):
        return re.compile(entry[3:], re.IGNORECASE)
    pat = re.escape(entry)
    if entry[:1].isascii() and entry[:1].isalnum():
        pat = r"(?<![A-Za-z0-9])" + pat
    if entry[-1:].isascii() and entry[-1:].isalnum():
        pat = pat + r"(?![A-Za-z0-9])"
    return re.compile(pat, re.IGNORECASE)


def match_keyword(subject, body, entries):
    """The first keyword entry found in subject/body, else None."""
    for e in entries:
        subject_only = e.startswith("subject:")
        entry = e[len("subject:"):] if subject_only else e
        rx = _keyword_re(entry)
        if rx.search(subject or "") or (not subject_only and rx.search(body or "")):
            return e
    return None


def sender(conv):
    author = (conv.get("source") or {}).get("author") or {}
    return (author.get("name") or "").strip(), (author.get("email") or "").strip().lower()


INBOUND_AUTHOR_TYPES = ("user", "lead", "contact")


def classify(conv, domains, keywords):
    """{'kind': 'domain'|'keyword', 'rule': <list entry>} or None. Domain wins."""
    # Only inbound: our own admin/bot outbound ("we reply within 24 hours") must never page.
    if ((conv.get("source") or {}).get("author") or {}).get("type") not in INBOUND_AUTHOR_TYPES:
        return None
    _, email = sender(conv)
    d = match_domain(email, domains)
    if d:
        return {"kind": "domain", "rule": d}
    src = conv.get("source") or {}
    subject = base._strip_html(src.get("subject") or "")
    k = match_keyword(subject, base.customer_text(conv), keywords)
    if k:
        return {"kind": "keyword", "rule": k}
    return None


def already_handled(conv, ledger):
    return DEDUPE_TAG in base.conv_tag_names(conv) or str(conv.get("id")) in ledger


# ── ClickUp lookup (which ticket did Caroline file?) ─────────────────────────
def find_ticket(conv, api_key=None, list_id=None, fetch=None):
    """('found', id) | ('none', None) | ('unknown', None). 'none' is claimed ONLY when
    the lookup succeeded and no task references the conversation; a missing key or a
    failed call is 'unknown' so the alert never asserts NO TICKET FILED falsely."""
    api_key = api_key or os.environ.get("CLICKUP_API_KEY")
    if not api_key:
        return ("unknown", None)
    list_id = list_id or os.environ.get("CLICKUP_LIST_ID", DEFAULT_CLICKUP_LIST)
    cid = str(conv.get("id"))
    since_ms = max(0, int(conv.get("created_at") or 0) - 86400) * 1000
    fetch = fetch or _clickup_get
    try:
        page = 0
        while page < 40:
            q = urllib.parse.urlencode({"include_closed": "true", "page": page,
                                        "date_created_gt": since_ms})
            tasks = fetch(f"/list/{list_id}/task?{q}", api_key).get("tasks", [])
            for t in tasks:
                if cid in (t.get("text_content") or "") or cid in (t.get("description") or ""):
                    return ("found", t.get("id"))
            if len(tasks) < 100:
                return ("none", None)
            page += 1
    except (urllib.error.URLError, ValueError, OSError):
        pass
    return ("unknown", None)


def _clickup_get(path, api_key):
    req = urllib.request.Request(
        os.environ.get("CLICKUP_API", "https://api.clickup.com/api/v2") + path,
        headers={"Authorization": api_key})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


# ── render ───────────────────────────────────────────────────────────────────
def render_alert(conv, match, ticket, mention_ids, workspace_id):
    """Slack mrkdwn text. Every interpolated field goes through slack_escape; the only
    live pings are the trusted mention ids; the link is rebuilt from the numeric id."""
    esc = base.slack_escape
    mention = " ".join(f"<@{m}>" for m in mention_ids if re.fullmatch(r"[A-Za-z0-9]+", m))
    name, email = sender(conv)
    who = esc(f"{name} <{email}>" if name else email) if email else "unknown sender"
    subject = esc(base._strip_html((conv.get("source") or {}).get("subject") or "")) or "(no subject)"
    cid = str(conv.get("id") or "")
    link = base.deeplink(workspace_id, cid) if re.fullmatch(r"[0-9]+", cid) else "(no link)"
    kind, tid = ticket
    if kind == "found":
        ticket_line = f"ClickUp ticket: {esc(str(tid))}"
    elif kind == "none":
        ticket_line = "*NO TICKET FILED*"
    else:
        ticket_line = "ClickUp ticket: unknown (lookup failed)"
    rule = f"sender domain `{esc(match['rule'])}`" if match["kind"] == "domain" \
        else f"keyword `{esc(match['rule'])}`"
    return (f"{mention + '  ' if mention else ''}:rotating_light: *Rights-holder / urgent inbound*\n"
            f"From: {who}\nSubject: {subject}\nMatched: {rule}\n{ticket_line}\n"
            f"<{link}|Open in Intercom>")


# ── Intercom write: tag ──────────────────────────────────────────────────────
def intercom_tag(token, conv_id, tag_name=DEDUPE_TAG, admin_id=None):
    """POST /tags (idempotent create-or-fetch by name) then attach by id."""
    admin_id = admin_id or resolve_admin_id()

    def call(path, body):
        req = urllib.request.Request(
            f"{base.INTERCOM_API}{path}", data=json.dumps(body).encode(), method="POST",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                     "Content-Type": "application/json",
                     "Intercom-Version": base.INTERCOM_VERSION})
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)

    tag_id = call("/tags", {"name": tag_name}).get("id")
    if not tag_id:
        raise RuntimeError(f"tag {tag_name!r} resolved without an id")
    call(f"/conversations/{conv_id}/tags", {"id": str(tag_id), "admin_id": str(admin_id)})


# ── the ordered write ────────────────────────────────────────────────────────
def alert_one(conv, match, ticket, *, post, tag, ledger, save_ledger, now, mention_ids,
              workspace_id):
    """post -> tag -> ledger. Returns True when the page was confirmed sent.

    A raising `post` aborts before any dedupe marker exists (retry next tick). A raising
    `tag` is reported but the ledger is still written — the page already went out."""
    cid = str(conv.get("id"))
    try:
        post(render_alert(conv, match, ticket, mention_ids, workspace_id))
    except (urllib.error.URLError, RuntimeError, ValueError, OSError) as e:
        print(f"ERROR: Slack post failed for {cid}: {e}", file=sys.stderr)
        return False
    try:
        tag(cid)
    except (urllib.error.URLError, RuntimeError, ValueError, OSError) as e:
        print(f"WARN: paged {cid} but tagging failed (ledger still written): {e}", file=sys.stderr)
    ledger[cid] = now
    try:
        save_ledger(ledger)
    except OSError as e:
        print(f"WARN: could not write ledger for {cid}: {e}", file=sys.stderr)
    return True


# ── run ──────────────────────────────────────────────────────────────────────
def run(args):
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        print("ERROR: MUSOAI_INTERCOM_TOKEN not set", file=sys.stderr)
        return 1
    try:
        at_ts = base._epoch(args.at)
        domains, keywords = load_domains(), load_keywords()
    except Exception as e:  # noqa: BLE001 — clean usage error
        print(f"ERROR: bad --at or list file: {e}", file=sys.stderr)
        return 1
    end_ts = int(at_ts - args.grace_minutes * 60)
    start_ts = int(end_ts - args.window_hours * 3600)
    try:
        convs = base.fetch_updated_between(token, start_ts, end_ts)
    except (urllib.error.URLError, ValueError) as e:
        print(f"ERROR: Intercom API failed: {e}", file=sys.stderr)
        return 2

    ledger_path = os.environ.get("RIGHTS_HOLDER_LEDGER_PATH", DEFAULT_LEDGER)
    ledger = {} if args.dry_run and args.at else base.load_ledger(ledger_path)
    hits = []
    for c in convs:
        m = classify(c, domains, keywords)
        if m:
            hits.append((c, m))
    workspace_id = os.environ.get("INTERCOM_WORKSPACE_ID", base.DEFAULT_WORKSPACE_ID)

    if args.dry_run:
        for c, m in hits:
            name, email = sender(c)
            print(json.dumps({
                "conv_id": str(c.get("id")), "sender": email, "name": name,
                "subject": base._strip_html((c.get("source") or {}).get("subject") or ""),
                "matched": m, "already_handled": already_handled(c, ledger),
                "deeplink": base.deeplink(workspace_id, str(c.get("id")))}, ensure_ascii=False))
        print(f"dry-run: {len(convs)} convs in window → {len(hits)} match "
              f"(no Slack, no tag, no ledger)", file=sys.stderr)
        return 0

    fresh = [(c, m) for c, m in hits if not already_handled(c, ledger)]
    print(f"{len(convs)} convs in window → {len(hits)} match, {len(fresh)} not yet paged",
          file=sys.stderr)
    if not fresh:
        return 0
    slack_token = base.resolve_slack_token()
    if not slack_token:
        print("ERROR: no Slack bot token (MUSO_SLACK_BOT_TOKEN_OPERATIONS or SLACK_BOT_TOKEN)",
              file=sys.stderr)
        return 2  # matches exist and cannot be paged: loud, retried next tick
    channel = os.environ.get("RIGHTS_HOLDER_CHANNEL", DEFAULT_CHANNEL)
    mention_ids = [s.strip() for s in os.environ.get(
        "RIGHTS_HOLDER_MENTION_IDS", DEFAULT_MENTION_IDS).split(",") if s.strip()]
    now = int(time.time())
    ledger = {k: v for k, v in ledger.items()
              if isinstance(v, (int, float)) and v >= now - LEDGER_RETENTION_S}
    failed = 0
    for c, m in fresh:
        ok = alert_one(
            c, m, find_ticket(c),
            post=lambda text: base.slack_post(slack_token, channel, text[:200], _blocks(text)),
            tag=lambda cid: intercom_tag(token, cid),
            ledger=ledger, save_ledger=lambda l: base.save_ledger(ledger_path, l),
            now=now, mention_ids=mention_ids, workspace_id=workspace_id)
        failed += 0 if ok else 1
    return 2 if failed else 0


def _blocks(text):
    return [{"type": "section", "text": {"type": "mrkdwn", "text": text}}]


def _maintenance_active():
    """True iff a planned maintenance window is active. Delegates to
    scripts/hydra-maintenance.sh so the fail-safe expiry logic lives in one place
    (same shape as intercom-intake-watchdog.py). Any failure => False: a broken
    guard must never suppress a rights-holder page."""
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "hydra-maintenance.sh")
    try:
        return subprocess.run(
            ["bash", helper, "is-active"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=10,
        ).returncode == 0
    except Exception:  # noqa: BLE001 — fail-safe: any error => not in maintenance
        return False


def main():
    ap = argparse.ArgumentParser(description="Intercom rights-holder / urgent inbound watchdog")
    ap.add_argument("--dry-run", action="store_true",
                    help="print matches; no Slack, no tag, no ledger write")
    ap.add_argument("--at", default=None, help="evaluate as-if at this instant (epoch or ISO8601)")
    ap.add_argument("--window-hours", type=float,
                    default=float(os.environ.get("WATCHDOG_WINDOW_HOURS", "6")))
    ap.add_argument("--grace-minutes", type=float,
                    default=float(os.environ.get("WATCHDOG_GRACE_MINUTES", "2")))
    args = ap.parse_args()

    if args.dry_run:
        return run(args)
    # Live path posts and tags: stand down during a planned maintenance window.
    if _maintenance_active():
        print("maintenance window active - skipping rights-holder watchdog", file=sys.stderr)
        return 0
    if os.environ.get("RIGHTS_HOLDER_SKIP_HOST_GUARD") != "1" and socket.gethostname() != HOST:
        print(f"not on {HOST} — refusing to run (set RIGHTS_HOLDER_SKIP_HOST_GUARD=1 to override)",
              file=sys.stderr)
        return 0
    lock_path = os.environ.get("RIGHTS_HOLDER_LOCKFILE", DEFAULT_LOCKFILE)
    lock = open(lock_path, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(f"another run holds {lock_path} — exiting", file=sys.stderr)
        return 0
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
