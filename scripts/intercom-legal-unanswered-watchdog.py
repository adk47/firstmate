#!/usr/bin/env python3
"""Intercom legal / privacy request unanswered-by-a-human watchdog -> #cs_priority (Jan).
Deterministic: no LLM.
Deliberately ignores hydra-maintenance windows: it only reads Intercom and posts to Slack (both
outside the fleet), and legal/GDPR deadlines keep running during a fleet window.

Born 2026-10-17 (firstmate 766): two GDPR erasure requests (Intercom 215476269953303, received
6 Oct; 215476287244669, received 7 Oct) sat 9-10 days. Caroline replied ("passed to the team")
and the rights-holder watchdog paged once, but no HUMAN answered the customer's follow-ups, and
nothing noticed. GDPR gives us one month.

State lives in ONE ledger file (/var/lib/intercom-legal-unanswered-watchdog/seen.json):
  {"scan_from": <epoch>, "watch": {conv_id: {matched, added, checked, failures}},
   "paged": {conv_id: {episode page record}}, "retry": {conv_id: {failures, first_failed}},
   "paged_unreadable": {conv_id: {kind, last_paged, pages, failures}}}
Any other shape is a hard error: the tick exits non-zero and never overwrites the file.
The WATCH SET is what pages, not the search window, so a request nobody touches never ages out.

Every tick (hourly):
  1. DISCOVER: re-read the RETRY set (candidates an earlier tick could not read), then search
     conversations updated since `scan_from` (first run: the last LOOKBACK days, once); for
     each open/snoozed one not already watched, fetch it and match the
     subject and EVERY customer message against a legal-privacy keyword
     (scripts/data/legal-unanswered-keywords.txt, same syntax as the rights-holder list).
     Matches join the watch set. A candidate that cannot be read joins the retry set and
     leaves it once read; from UNREADABLE_TICKS failed ticks in a row it is paged as "could
     not read to check for a legal request", with REPAGE spacing.
  2. EVALUATE every watched conversation by fetching it, regardless of updated_at: drop it
     when it is closed or a HUMAN admin (any admin except Caroline; she cannot erase data)
     replied after the customer's latest message. Otherwise, once that message is older than
     THRESHOLD hours, page #cs_priority mentioning Jan: once per unanswered customer message,
     then again every REPAGE hours while it stays unanswered. All pages go in ONE message.
     A watched conversation that cannot be read stays watched (never treated as answered)
     and counts consecutive failed ticks; from UNREADABLE_TICKS on it is paged as
     "unreadable, check by hand", with the same REPAGE spacing. Unreadable pages keep their
     own record (`paged_unreadable`), so they never reset a customer message's REPAGE clock.
  3. `scan_from` advances whenever the search itself completed: failed reads are carried by
     the retry set and the watch set, never by the cursor. While either holds a failure the
     tick exits non-zero. A dropped conversation that the customer writes to again is
     updated, so discovery re-adds it.
Discovery and the watch set each have their own per-tick read cap (MAX_SCAN_FETCHES,
MAX_WATCH_FETCHES), so neither can starve the other; work left over by either cap is
reported and exits non-zero, and discovery resumes where it stopped.

Order per page, as in the rights-holder watchdog: confirmed Slack post first, then the `paged`
record. A failed post records no page, so it retries next tick. A check that cannot complete
(fetch error) is reported and exits non-zero; it is never counted as "answered".

Usage:
  python3 scripts/intercom-legal-unanswered-watchdog.py              # live tick (systemd timer)
  python3 scripts/intercom-legal-unanswered-watchdog.py --dry-run    # print what would page now
  python3 scripts/intercom-legal-unanswered-watchdog.py --dry-run --at 2026-10-17T12:00:00Z
      # --dry-run --at ignores the ledger (fresh 45-day scan as of that instant)
"""
import argparse
import html
import http.client
import importlib.util
import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.request

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))
from lib.intercom_identity import resolve_admin_id  # noqa: E402  (Caroline's admin id)


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, _HERE / filename)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Shared deterministic helpers: fetch/strip/deeplink/Slack/ledger (base) and the keyword
# matcher + list loader (rights-holder watchdog), so the two lists use one syntax.
base = _load("intercom_data_complaint_watchdog", "intercom-data-complaint-watchdog.py")
rh = _load("intercom_rights_holder_watchdog", "intercom-rights-holder-watchdog.py")

DEFAULT_KEYWORDS_FILE = str(_HERE / "data" / "legal-unanswered-keywords.txt")
DEFAULT_CHANNEL = "C0BBTAVP44X"  # #cs_priority
DEFAULT_MENTION_IDS = "U038BM16T7W"  # Jan (owner of deletions / privacy)
DEFAULT_LEDGER = "/var/lib/intercom-legal-unanswered-watchdog/seen.json"
LOOKBACK_DAYS = 45
SCAN_OVERLAP_S = 2 * 3600
MAX_SCAN_FETCHES = 400
MAX_WATCH_FETCHES = 200
UNREADABLE_TICKS = 3
UNREADABLE = "unreadable"
UNCHECKED = "unchecked"
READ_ERRORS = (urllib.error.URLError, ValueError, OSError, http.client.HTTPException)
THRESHOLD_H = 24
REPAGE_H = 48
PAGED_RETENTION_S = 60 * 86400
OPEN_STATES = ("open", "snoozed")
INBOUND = ("user", "lead", "contact")


def load_keywords():
    return rh.load_list(os.environ.get("LEGAL_UNANSWERED_KEYWORDS_FILE", DEFAULT_KEYWORDS_FILE))


_TAG_RE = re.compile(r"<[^>]*>")


def _match_text(text):
    """Customer HTML as plain text with every tag turned into a space, so adjacent paragraphs
    (`<p>…profile</p><p>Thanks`) never fuse into one word and defeat a keyword's `\\b`."""
    return " ".join(html.unescape(_TAG_RE.sub(" ", text or "")).split())


def _all_parts(detail):
    return [detail.get("source") or {}] + list(((detail.get("conversation_parts") or {})
                                                .get("conversation_parts")) or [])


def matches(detail, keywords):
    """The matched keyword, or None. Only customer-authored text is read: the subject when the
    customer opened the conversation, and every inbound message (opening one included), so a
    request made in a later message is caught and our own outbound text never pages."""
    src = detail.get("source") or {}
    inbound = (src.get("author") or {}).get("type") in INBOUND
    subject = _match_text(src.get("subject")) if inbound else ""
    bodies = [_match_text(p.get("body")) for p in _all_parts(detail)
              if (p.get("author") or {}).get("type") in INBOUND and p.get("body")]
    for body in [""] + bodies:
        rule = rh.match_keyword(subject, body, keywords)
        if rule:
            return rule
    return None


def unanswered_episode(detail, bot_admin_id):
    """(last_customer_ts, last_customer_part_id) when the customer's latest message has no
    HUMAN admin comment after it; None when a human replied after it (or there is no customer
    message). Caroline (bot_admin_id) and notes never count as an answer."""
    last_cust = None
    last_human = 0
    for i, p in enumerate(_all_parts(detail)):
        a = p.get("author") or {}
        ts = int(p.get("created_at") or (detail.get("created_at") if i == 0 else 0) or 0)
        has_content = bool(p.get("body") or p.get("attachments"))
        if a.get("type") in INBOUND and has_content:
            last_cust = (ts, str(p.get("id") or "source"))
        elif (a.get("type") == "admin" and str(a.get("id")) != str(bot_admin_id)
              and p.get("part_type", "comment") in ("comment", "assign_and_reopen", "open")
              and p.get("body")):
            last_human = max(last_human, ts)
    if not last_cust or last_human >= last_cust[0]:
        return None
    return last_cust


def should_page(cid, episode, now, paged, threshold_h=THRESHOLD_H, repage_h=REPAGE_H):
    """Page when the episode is older than the threshold and was not paged in the last
    repage_h hours (a NEW customer message is a new episode and pages after its own 24 h)."""
    ts, part_id = episode
    if now - ts < threshold_h * 3600:
        return False
    entry = paged.get(cid) or {}
    if entry.get("episode") != part_id:
        return True
    return now - int(entry.get("last_paged") or 0) >= repage_h * 3600


def unreadable_due(cid, failures, now, paged_unreadable, repage_h=REPAGE_H):
    if failures < UNREADABLE_TICKS:
        return False
    entry = paged_unreadable.get(cid) or {}
    return now - int(entry.get("last_paged") or 0) >= repage_h * 3600


RECORDS = ("watch", "paged", "retry", "paged_unreadable")


def empty_state():
    return {"scan_from": None, **{k: {} for k in RECORDS}}


def load_state(path):
    """{"scan_from", *RECORDS}; a missing file is a fresh start. Anything else that
    is not exactly that shape raises ValueError, so a ledger we do not understand is never
    silently replaced."""
    try:
        with open(path) as f:
            raw = json.load(f)
    except FileNotFoundError:
        return empty_state()
    state = empty_state()
    if not isinstance(raw, dict) or not set(raw) <= set(state):
        raise ValueError(f"unrecognised ledger shape in {path}")
    state.update(raw)
    if not isinstance(state["scan_from"], (int, type(None))) or not all(
            isinstance(state[k], dict) and all(isinstance(v, dict) for v in state[k].values())
            for k in RECORDS):
        raise ValueError(f"unrecognised ledger shape in {path}")
    return state


def render_line(conv, rule, episode, now, workspace_id):
    ts, part_id = episode
    link = base.deeplink(workspace_id, str(conv.get("id")))
    if part_id == UNREADABLE:
        return (f"• *unreadable for {conv.get('failures')} ticks*, check by hand "
                f"(`{base.slack_escape(str(rule))[:40]}`): {link}")
    if part_id == UNCHECKED:
        return (f"• *could not read to check for a legal request* ({conv.get('failures')} ticks), "
                f"check by hand: {link}")
    hours = int((now - ts) // 3600)
    subject = base._strip_html((conv.get("source") or {}).get("subject") or "") or "(no subject)"
    received = time.strftime("%d %b", time.gmtime(int(conv.get("created_at") or ts)))
    return (f"• *{hours} h* without a human reply (received {received}; `{base.slack_escape(str(rule))[:40]}`): "
            f"{base.slack_escape(subject[:110])} {link}")


def render(due, now, mention_ids, workspace_id):
    """ONE message per tick, oldest wait first, so a backlog never floods the channel."""
    mentions = " ".join(f"<@{m}>" for m in mention_ids)
    lines = [render_line(c, r, ep, now, workspace_id)
             for c, r, ep in sorted(due, key=lambda x: x[2][0])]
    return (f"{mentions} :hourglass_flowing_sand: *{len(due)} legal/privacy item(s) need a human* "
            f"(24 h+ without one; Caroline's replies don't count; GDPR gives us one month):\n" + "\n".join(lines))


def blocks_for(text, limit=2900):
    """Slack sections cap at 3000 chars: split on lines so no item is ever cut off."""
    blocks, cur = [], ""
    for line in text.split("\n"):
        if cur and len(cur) + 1 + len(line) > limit:
            blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": cur}})
            cur = ""
        cur = (cur + "\n" + line) if cur else line[:limit]
    if cur:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": cur}})
    return blocks


def fetch_conversation(token, cid):
    req = urllib.request.Request(
        f"{base.INTERCOM_API}/conversations/{cid}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                 "Intercom-Version": base.INTERCOM_VERSION})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def _read(token, cid):
    """(detail, gone, error): gone is True for a deleted conversation (404)."""
    try:
        return fetch_conversation(token, cid), False, None
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None, True, None
        return None, False, e
    except READ_ERRORS as e:
        return None, False, e


def run(args):
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        print("ERROR: MUSOAI_INTERCOM_TOKEN not set", file=sys.stderr)
        return 1
    try:
        now = int(base._epoch(args.at))
        keywords = load_keywords()
    except Exception as e:  # noqa: BLE001
        print(f"ERROR: bad --at or keyword file: {e}", file=sys.stderr)
        return 1
    bot = resolve_admin_id()
    ledger_path = os.environ.get("LEGAL_UNANSWERED_LEDGER_PATH", DEFAULT_LEDGER)
    try:
        state = empty_state() if args.dry_run and args.at else load_state(ledger_path)
    except (OSError, ValueError) as e:
        print(f"ERROR: cannot use ledger {ledger_path} (left untouched): {e}", file=sys.stderr)
        return 1
    watch, paged, retry, paged_unreadable = (state[k] for k in RECORDS)
    workspace_id = os.environ.get("INTERCOM_WORKSPACE_ID", base.DEFAULT_WORKSPACE_ID)
    mention_ids = [s.strip() for s in os.environ.get(
        "LEGAL_UNANSWERED_MENTION_IDS", DEFAULT_MENTION_IDS).split(",") if s.strip()]

    search_failed, errors, undone = False, 0, 0
    details = {}
    due = []

    # 1. discover
    scan_start = int(state["scan_from"] or (now - LOOKBACK_DAYS * 86400))
    next_scan_from = now - SCAN_OVERLAP_S
    convs = []
    try:
        # +1 h on the end: a conversation touched while this tick runs (a tag, a bot reply)
        # must not fall out of the window; its customer/human timeline is what is judged.
        convs = base.fetch_updated_between(token, scan_start, now + 3600)
    except READ_ERRORS as e:
        print(f"ERROR: Intercom search failed: {e}", file=sys.stderr)
        search_failed = True
        errors += 1
    scan = sorted((c for c in convs if base.conv_state(c) in OPEN_STATES
                   and str(c.get("id")) not in watch and str(c.get("id")) not in retry),
                  key=lambda c: int(c.get("updated_at") or 0))
    queue = ([(cid, None) for cid in sorted(retry, key=lambda k: int(retry[k].get("first_failed") or 0))]
             + [(str(c.get("id")), c) for c in scan])
    for i, (cid, c) in enumerate(queue):
        if i >= MAX_SCAN_FETCHES:
            undone += len(queue) - i
            pending = [p for _, p in queue[i:] if p is not None]
            if pending:
                next_scan_from = min(int(pending[0].get("updated_at") or 0) - 1, next_scan_from)
            break
        d, gone, err = _read(token, cid)
        if err:
            r = retry.setdefault(cid, {"failures": 0, "first_failed": now})
            r["failures"] = int(r.get("failures") or 0) + 1
            print(f"ERROR: could not read {cid} ({r['failures']} tick(s) in a row): {err}", file=sys.stderr)
            errors += 1
            if unreadable_due(cid, r["failures"], now, paged_unreadable):
                due.append(({"id": cid, "failures": r["failures"]}, None, (0, UNCHECKED)))
            continue
        retry.pop(cid, None)
        if gone:
            continue
        rule = matches(d, keywords)
        if rule:
            watch[cid] = {"matched": rule, "added": now}
            details[cid] = d

    # 2. evaluate every watched conversation
    watch_fetches = 0
    for cid in sorted(watch, key=lambda k: int(watch[k].get("checked") or 0)):
        d = details.get(cid)
        if d is None:
            if watch_fetches >= MAX_WATCH_FETCHES:
                undone += 1
                continue
            d, gone, err = _read(token, cid)
            watch_fetches += 1
            if err:
                failures = int(watch[cid].get("failures") or 0) + 1
                watch[cid]["failures"] = failures
                print(f"ERROR: could not read watched {cid} ({failures} tick(s) in a row): {err}",
                      file=sys.stderr)
                errors += 1
                if unreadable_due(cid, failures, now, paged_unreadable):
                    due.append(({"id": cid, "failures": failures}, watch[cid].get("matched"), (0, UNREADABLE)))
                continue
            if gone:
                del watch[cid]
                continue
        watch[cid].pop("failures", None)
        watch[cid]["checked"] = now
        if base.conv_state(d) not in OPEN_STATES:
            del watch[cid]
            continue
        ep = unanswered_episode(d, bot)
        if not ep:
            del watch[cid]
            continue
        if should_page(cid, ep, now, paged):
            d.setdefault("id", cid)
            due.append((d, watch[cid].get("matched"), ep))

    # 3. the cursor moves whenever the search completed; failed reads live in retry / watch
    if not search_failed:
        state["scan_from"] = next_scan_from
    rc = 2 if (errors or undone or retry) else 0
    if retry:
        print(f"ERROR: {len(retry)} candidate(s) still unread (retry set)", file=sys.stderr)
    if undone:
        print(f"ERROR: fetch caps ({MAX_SCAN_FETCHES} discovery, {MAX_WATCH_FETCHES} watch) left "
              f"{undone} conversation(s) unchecked", file=sys.stderr)

    if args.dry_run:
        for c, rule, ep in due:
            rec = {"conv_id": str(c.get("id")), "matched": rule}
            if ep[1] in (UNREADABLE, UNCHECKED):
                rec.update(kind=ep[1], failed_ticks=c.get("failures"))
            else:
                rec["hours_unanswered"] = int((now - ep[0]) // 3600)
            print(json.dumps(rec))
        print(f"dry-run: {len(convs)} convs scanned, {len(watch)} watched, {len(due)} would page, "
              f"{errors} unreadable, {undone} unchecked", file=sys.stderr)
        return rc

    if due:
        slack_token = base.resolve_slack_token()
        channel = os.environ.get("LEGAL_UNANSWERED_CHANNEL", DEFAULT_CHANNEL)
        text = render(due, now, mention_ids, workspace_id)
        try:
            if not slack_token:
                raise RuntimeError("no Slack bot token")
            base.slack_post(slack_token, channel, text[:200], blocks_for(text))
        except READ_ERRORS + (RuntimeError,) as e:
            print(f"ERROR: Slack post failed: {e}", file=sys.stderr)
            rc = 2  # no page recorded: every item retries next tick
        else:
            for c, rule, ep in due:
                cid = str(c.get("id"))
                if ep[1] in (UNREADABLE, UNCHECKED):
                    prev = paged_unreadable.get(cid) or {}
                    paged_unreadable[cid] = {"kind": ep[1], "last_paged": now, "failures": c.get("failures"),
                                             "pages": int(prev.get("pages") or 0) + 1}
                    continue
                prev = paged.get(cid) or {}
                same = prev.get("episode") == ep[1]
                paged[cid] = {"episode": ep[1], "customer_ts": ep[0], "last_paged": now,
                              "first_paged": prev.get("first_paged", now) if same else now,
                              "pages": (prev.get("pages", 0) + 1) if same else 1,
                              "received": int(c.get("created_at") or 0), "matched": rule}
    for key in ("paged", "paged_unreadable"):
        state[key] = {k: v for k, v in state[key].items()
                      if k in watch or k in retry or now - int(v.get("last_paged") or 0) < PAGED_RETENTION_S}
    try:
        base.save_ledger(ledger_path, state)
    except OSError as e:
        print(f"ERROR: could not write ledger {ledger_path}: {e}", file=sys.stderr)
        return 2
    return rc


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--at", default=None, help="evaluate as-if at this instant (iso or epoch)")
    return run(p.parse_args())


if __name__ == "__main__":
    sys.exit(main())
