#!/usr/bin/env python3
"""GDPR erasure pipeline (Fable `gdpr-ruling-for-jan.md` §3 as code). Runs on node-8.

  gdpr-pipeline.py backfill --register FILE [--gmail-ledger F] [--support-ledger F] [--out FILE]
      intake every channel (markdown register rows, open data-deletion + data-export tickets and their Intercom
      conversations, the notices@/legal@ and support@ ledgers) + decide identity + write the backfill table
  gdpr-pipeline.py tick [--register FILE] [--page]       hourly: intake (tickets, ledgers, Intercom last 3 h)
      + decide + 410 read-back + watchdog (pages #cs_priority / Jan at most once a day with --page)
  gdpr-pipeline.py intake --candidate FILE|-            record ONE request pushed by another pipeline (the intake
      contract: keys/channel/class/received_at/pages; ids only). Prints the register number and whether the row was
      created, merged into an existing request, or refused for an unknown class. Used by the notices@/legal@ reader
      so a mailbox-request reaches the register instead of stopping at someone's inbox.
  gdpr-pipeline.py decide                               re-decide every open row
  gdpr-pipeline.py report [--out FILE]                  the register table (id, received, due, verdict, action)
  gdpr-pipeline.py hide-batch [--open-prs]              the daily reversible-hide batch (H-DevOps HIDDEN_ENTITY_IDS
      + PDP sitemap legal_hidden); default prints the diffs, --open-prs opens the two PRs (a person merges)
  gdpr-pipeline.py mark-hidden                          410 + noindex read-back -> hidden_at
  gdpr-pipeline.py ask [--send --approved-by SLACKUID] [--limit N]
      identity asks with the approved lines; without --send it renders (the default). Sends need the compiled unlock
      (copy.PIPELINE_SENDS_APPROVED) AND an allowlisted human's --approved-by; one ledgered letter per request.
  gdpr-pipeline.py confirm [--sitemap] [--send --approved-by SLACKUID] [--limit N]
      written confirmations due within 3 d (or hidden), S/P/M lines only from this run's checks; OLDEST deadline first
  gdpr-pipeline.py watchdog [--page]                    due_at - 3 d without confirmation; ASK > 7 d unanswered

Never deletes: there is no DELETE /api/v3/admin/profile and no muso-cli delete in this pipeline. Store:
GDPR_STORE (default /var/lib/hydra-gdpr/erasure.sqlite). Exit 2 when any read failed (fail closed).
Kill switch: /etc/hydra/gdpr-pipeline.disabled (every step that writes or pages refuses to run).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gdpr_pipeline import approval, copy, hide_batch, send, sources  # noqa: E402
from gdpr_pipeline import intake as intake_core  # noqa: E402
from gdpr_pipeline.run import JAN, Run, backfill_table, page_chunks, page_text, SLACK_CHANNEL  # noqa: E402
from gdpr_pipeline.store import DEFAULT_PATH, Store  # noqa: E402

KILL = "/etc/hydra/gdpr-pipeline.disabled"
GMAIL_LEDGER = "/root/fmc1-intake/ledger.json"
SUPPORT_LEDGER = "/root/fmc1-intake/support-ledger.json"


def _load_json(path: str) -> dict:
    if not path or not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)


def load_ledger(run: Run, path: str) -> dict:
    """A configured mail ledger that is missing or unreadable FAILS the run (exit 2): a moved path must never turn
    into a green tick that silently skipped a whole mailbox. Pass --gmail-ledger '' to skip a source on purpose."""
    if not path:
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError) as exc:
        run.fail(f"mail ledger {path}", exc)
        return {}
    if not isinstance(data, dict):
        run.fail(f"mail ledger {path}", ValueError("not a JSON object"))
        return {}
    return data


def hidden_now(run: Run) -> set[str]:
    try:
        hd, pdp = sources.hidden_lists()
    except sources.Unknown as exc:
        run.fail("hide lists", exc)
        raise SystemExit(2)
    return hd & pdp


INTERCOM_MAX_LOOKBACK_DAYS = 30


def _state_path(store_path: str, name: str) -> str:
    """A sidecar next to the store. `store_path` is normally the DB FILE, whose directory is the state dir; a
    directory is accepted too so a caller (a test, an operator) can point both at one place — the parent of the
    DB is never the right state dir, and a state file written one level up once silenced a whole day of pages."""
    d = store_path if os.path.isdir(store_path) else (os.path.dirname(store_path) or ".")
    return os.path.join(d, name)


def intercom_since(store_path: str, hours: int, now: datetime) -> int:
    """Start of the Intercom search window: `hours` back, or further back when the previous run failed (its cursor
    never advanced). Capped at INTERCOM_MAX_LOOKBACK_DAYS so a long outage cannot ask Intercom for years.

    With NO cursor the window is the whole lookback: nothing has been searched yet, so "the last `hours`" is not
    evidence about anything older. A customer who asked to be erased on Intercom two days ago with no ClickUp ticket,
    no mail-ledger row and no markdown-register row is only findable here, and skipping them left the request with no
    24-hour hide alert and no 30-day watchdog. The cursor is still written ONLY after a complete scan."""
    since = int((now - timedelta(hours=hours)).timestamp())
    floor = int((now - timedelta(days=INTERCOM_MAX_LOOKBACK_DAYS)).timestamp())
    try:
        cur = _load_json(_state_path(store_path, "intercom-cursor.json")).get("last_ok_epoch")
    except (OSError, ValueError):
        cur = None
    if not isinstance(cur, int):
        return floor
    if cur < since:
        since = max(cur, floor)
    return since


def save_intercom_cursor(store_path: str, now: datetime) -> None:
    path = _state_path(store_path, "intercom-cursor.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"last_ok_epoch": int(now.timestamp()), "at": now.strftime("%Y-%m-%dT%H:%M:%SZ")}, f)
    os.replace(tmp, path)


def do_intake(run: Run, a, intercom_hours: int | None, now: datetime | None = None) -> None:
    if getattr(a, "register", None):
        run.intake_register(Path(a.register).read_text())
    run.intake_gmail(load_ledger(run, a.gmail_ledger), load_ledger(run, a.support_ledger))
    for action in ("data-deletion", "data-export"):
        try:
            run.intake_clickup(sources.clickup_tasks(action))
        except sources.Unknown as exc:
            run.fail(f"clickup {action}", exc)
    if intercom_hours:
        now = now or datetime.now(timezone.utc)
        since = intercom_since(a.store, intercom_hours, now)
        started = int(now.timestamp())
        if run.intake_intercom(since):
            save_intercom_cursor(a.store, datetime.fromtimestamp(started, timezone.utc))
        else:
            print(f"intercom window {datetime.fromtimestamp(since, timezone.utc):%Y-%m-%dT%H:%M}Z was NOT advanced "
                  f"(a read failed); the next tick retries it")


# The intake contract for a request pushed by another pipeline. `class` must be one the register can ACT on: a lane
# that invents its own kind (a notices@ "objection", a "name_removal") would create a row every pass then filters out,
# which is worse than a refusal - the lane would believe the request is registered and watched. So an unknown class is
# a hard refusal here, with the known list in the message, exactly like an unknown CLI flag.
CANDIDATE_CLASSES = intake_core.ERASURE_CLASSES + ("privacy_access", "not_erasure",
                                                   "cancel_intent_mentions_deletion")
CANDIDATE_FIELDS = ("keys", "channel", "class", "received_at", "requester_name", "requester_email", "contact_id",
                    "conversation_id", "gmail_thread", "clickup_ids", "pages", "note")
CANDIDATE_CHANNELS = ("intercom", "support", "notices", "legal", "register")
ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def read_candidate(path: str) -> list[dict]:
    """Read one candidate object (or a JSON list of them) from a file, or '-' for stdin."""
    raw = sys.stdin.read() if path == "-" else Path(path).read_text()
    try:
        data = json.loads(raw)
    except ValueError as exc:
        raise SystemExit(f"candidate is not valid JSON: {exc}")
    items = data if isinstance(data, list) else [data]
    out = []
    for i, c in enumerate(items):
        if not isinstance(c, dict):
            raise SystemExit(f"candidate {i}: not a JSON object")
        unknown = sorted(set(c) - set(CANDIDATE_FIELDS))
        if unknown:
            raise SystemExit(f"candidate {i}: unknown field(s) {unknown}; known: {list(CANDIDATE_FIELDS)}")
        if not c.get("received_at") or not ISO_RE.match(str(c["received_at"])):
            raise SystemExit(f"candidate {i}: received_at must be the EMAIL's own date, ISO-8601 Z "
                             f"(e.g. 2026-11-01T09:14:00Z), got {c.get('received_at')!r} - the 30-day clock and the "
                             f"24-hour hide deadline are both measured from it")
        if c.get("class") not in CANDIDATE_CLASSES:
            raise SystemExit(f"candidate {i}: class {c.get('class')!r} is not one the register can act on. Known: "
                             f"{list(CANDIDATE_CLASSES)}. Map the lane's own kind onto one of these (a name-removal "
                             f"or an objection to a public listing is privacy_erasure; a data-export is "
                             f"privacy_access) - a new class is a copy/identity decision, not a field value")
        if c.get("channel") not in CANDIDATE_CHANNELS:
            raise SystemExit(f"candidate {i}: channel {c.get('channel')!r} not in {list(CANDIDATE_CHANNELS)}")
        keys = [k for k in (c.get("keys") or []) if k]
        if not keys:
            raise SystemExit(f"candidate {i}: keys is empty. The FIRST key is the row key and the idempotence test: "
                             f"gmail:<alias>:<thread>, intercom:<conversation_id>, clickup:<task_id>, register:<n>")
        for k in keys:
            if not isinstance(k, str) or ":" not in k:
                raise SystemExit(f"candidate {i}: key {k!r} must look like gmail:notices@muso.ai:<thread>")
        c["keys"] = keys
        c.setdefault("pages", [])
        out.append(c)
    return out


def cmd_intake(run: Run, a) -> int:
    """Record pushed candidates. Decides each new/merged row immediately, so the lane that pushed it learns the
    identity verdict and what happens next in the same call instead of waiting up to an hour for a tick."""
    cands = read_candidate(a.candidate)
    rows = []
    for c in cands:
        rid, how = run.store.upsert(c)
        r = run.store.get(rid)
        rows.append((rid, how, r))
        print(f"{c['keys'][0]}: {how} -> register #{r['register_no']} ({r['class']}, received {r['received_at'][:10]}, "
              f"due {r['due_at'][:10]}, hide due {r['hide_due_at'][:10]})")
        if how != "unchanged":
            run.log(f"{c['keys'][0]}: {how} (row {rid})")
    if rows and not getattr(a, "no_decide", False):
        run.decide_rows([r for _, how, r in rows if how != "unchanged"], hidden_now(run))
        for rid, how, _ in rows:
            r = run.store.get(rid)
            print(f"  {rid}: id={r['identity_verdict'] or '-'} action={r['action'] or '-'}"
                  f"{(' detail=' + r['note']) if r['note'] else ''}")
    # A failed decision is not a success: the caller (a cron, the intake lane) must not believe the row is watched.
    return 2 if run.errors else 0


def slack_post(text: str) -> bool:
    from lib.slack_token import _from_env_file
    tok = os.environ.get("MUSO_SLACK_BOT_TOKEN_OPERATIONS") or _from_env_file("MUSO_SLACK_BOT_TOKEN_OPERATIONS",
                                                                              "/etc/openclaw/main.env")
    if not tok:
        print("ERROR page: no Slack token")
        return False
    req = urllib.request.Request("https://slack.com/api/chat.postMessage",
                                 data=json.dumps({"channel": SLACK_CHANNEL, "text": text,
                                                  "unfurl_links": False}).encode(),
                                 headers={"Authorization": "Bearer " + tok,
                                          "Content-Type": "application/json; charset=utf-8"})
    try:
        return bool(json.load(urllib.request.urlopen(req, timeout=30)).get("ok"))
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR page: {exc}")
        return False


HIDE_DUE_HEAD = (f"<@{JAN}> :rotating_light: *GDPR erasure register: the 24-hour HIDE deadline has passed and the "
                 f"page is not hidden* - open/merge the hide batch PR")


def watchdog(run: Run, page: bool) -> None:
    now = datetime.now(timezone.utc)
    rows_ = run.watchdog_rows(now)
    # include_legal=True: a LEGAL_HIDE_FIRST page has the same 24-hour deadline (the captain owns the hide, not the
    # alert), so an overdue legal-threat request must page too instead of waiting for the 30-day warning.
    hide_rows = run.hide_due_rows(now, include_legal=True)
    for ln in [line for _, line in rows_]:
        print("  " + ln)
    print(f"watchdog: {len(rows_)} confirmation line(s), {len(hide_rows)} overdue-hide line(s)")
    for ln in [line for _, line in hide_rows]:
        print("  " + ln)
    if not page or not (rows_ or hide_rows):
        return
    state = _load_json(_state_path(run.store.path, "watchdog-last.json"))
    today = now.strftime("%Y-%m-%d")
    paged = {str(x) for x in state.get("paged", [])} if state.get("last_page_day") == today else set()
    # The two deadlines are tracked SEPARATELY ("hide:<reg>" / "confirm:<reg>"). One flat set meant the 24-hour hide
    # page, which fires first, suppressed the same row's 30-day confirmation warning arriving later that same day --
    # the row went out with its deadline announced as "hide overdue" and its actual statutory date never announced.
    # A bare register number from an older state file counts as a HIDE page (what that set was for); double-posting a
    # confirmation line is harmless, silently skipping one is not.
    fresh = [(reg, line) for reg, line in rows_ if f"confirm:{reg}" not in paged]
    fresh_hide = [(reg, line) for reg, line in hide_rows if f"hide:{reg}" not in paged]
    if not fresh and not fresh_hide:
        return          # everything due today was already paged today; no repeat
    # The 24-hour HIDE deadline is its own page (received + 24 h, the ruling's first step): it fires long before the
    # 30-day warning, so a PASS request whose batch PR never opened cannot pass in silence.
    chunks = page_chunks([ln for _, ln in fresh_hide], head=HIDE_DUE_HEAD) if fresh_hide else []
    chunks += page_chunks([ln for _, ln in fresh]) if fresh else []
    # EVERY chunk must post before any row counts as paged: a partial page must never suppress a request.
    posted = all([slack_post(c) for c in chunks])
    if posted:
        newly = {f"confirm:{reg}" for reg, _ in fresh} | {f"hide:{reg}" for reg, _ in fresh_hide}
        with open(_state_path(run.store.path, "watchdog-last.json"), "w") as f:
            json.dump({"last_page_day": today, "paged": sorted(set(paged) | newly)}, f)
    else:
        run.errors.append("watchdog page failed")


APPROVERS = ("U7RP6HKUZ", "U038BM16T7W", "U0AL36NADEY")      # Aaron / Jan / Nick


def oldest_first(items: list[dict]) -> list[dict]:
    """Statutory order: the request whose deadline is oldest goes first. The register is a legal record, so the queue
    is not allowed to depend on row id or intake order."""
    return sorted(items, key=lambda x: (x.get("due_at") or "", x.get("register_no") or 0))


def refuse_send(a, kind: str, items: list[dict]) -> None:
    """The gate in front of every send. THREE things, and all three are a human's to open:

      - the compiled-in unlock (`copy.PIPELINE_SENDS_APPROVED`, flipped only by a PR that carries the GO);
      - `--approved-by`, an allowlisted human's Slack id;
      - and the one that is not a string this process can type: a Slack message FROM that human, in the approval
        channel, carrying the digest of exactly this batch (`gdpr_pipeline.approval`). An allowlist comparison alone
        is not a human lock - any caller can pass an id - so without the message there is no send.

    Without `--send` nothing here fires and both commands are a dry run."""
    if not a.send:
        print(approval.note(kind, items))
        return
    if not copy.PIPELINE_SENDS_APPROVED:
        print("REFUSED: pipeline sends are LOCKED (copy.PIPELINE_SENDS_APPROVED = False); the copy and the adapters "
              "are in place, the unlock is one line a human signs in a PR")
        raise SystemExit(1)
    # The allowlist is the three humans OR the one approved sender seat (029/031: the seat posts through the devops
    # bot, and its user id is Slack's `auth.test`, never a name). A pre-check that only knew the humans refused the
    # seat before `verify` - which accepts it - could ever run.
    if a.approved_by not in APPROVERS:
        try:
            seat = approval.seat_id()
        except approval.Unverifiable as exc:
            print(f"REFUSED: {exc}")
            raise SystemExit(1) from exc
        if a.approved_by != seat:
            print(f"REFUSED: --approved-by must be an allowlisted human (Aaron / Jan / Nick Slack id) or the sender "
                  f"seat ({seat})")
            raise SystemExit(1)
    ok, why = approval.verify(kind, items, a.approved_by, APPROVERS)
    print(("approved: " if ok else "REFUSED: ") + why)
    if not ok:
        raise SystemExit(1)


def hold_lock(store_path: str):
    """One run at a time, or two hourly ticks stack up. Every decide pass is ~5 network reads per stale row (each
    Trino query is a `kubectl exec`), so the tick is minutes long by design; a second run starting on top of it
    only doubles the load and lets two passes page for the same rows. Returns the open lock handle (held for the
    process lifetime) or None when another run already holds it."""
    import fcntl
    path = _state_path(store_path, "run.lock")
    # The lock is taken BEFORE Store() exists (the store is opened after this on purpose: a second run must exit
    # without touching the DB at all), so on a fresh node the state directory does not exist yet and the tick died
    # with FileNotFoundError. Create it here, restricted: it holds the register's sidecars.
    os.makedirs(os.path.dirname(path) or ".", mode=0o700, exist_ok=True)
    handle = open(path, "a+")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    return handle


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--store", default=DEFAULT_PATH)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("backfill", "tick"):
        p = sub.add_parser(name)
        p.add_argument("--register", required=(name == "backfill"))
        p.add_argument("--gmail-ledger", default=GMAIL_LEDGER)
        p.add_argument("--support-ledger", default=SUPPORT_LEDGER)
        p.add_argument("--out")
        p.add_argument("--page", action="store_true")
    p = sub.add_parser("intake", help="record one request pushed by another pipeline (ids only, no bodies)")
    p.add_argument("--candidate", required=True, help="JSON file, or - for stdin (one object or a list)")
    p.add_argument("--no-decide", action="store_true", help="only record; let the hourly tick decide")
    sub.add_parser("decide")
    p = sub.add_parser("report")
    p.add_argument("--out")
    p = sub.add_parser("hide-batch")
    p.add_argument("--open-prs", action="store_true")
    p.add_argument("--include-legal", action="store_true", help="add legal hide-first pages (captain's call)")
    sub.add_parser("mark-hidden")
    for name in ("ask", "confirm"):
        p = sub.add_parser(name)
        p.add_argument("--send", action="store_true", help="actually deliver (default is a dry run)")
        p.add_argument("--approved-by", default="")
        p.add_argument("--limit", type=int, default=0,
                       help="send at most N letters, OLDEST deadline first (0 = no cap)")
        if name == "confirm":
            p.add_argument("--sitemap", action="store_true", help="walk every sitemap file for the M line")
    p = sub.add_parser("watchdog")
    p.add_argument("--page", action="store_true")
    p = sub.add_parser("dedupe", help="report (or --apply) the same customer event opened under two row keys")
    p.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    writes = a.cmd in ("backfill", "tick", "decide", "mark-hidden", "intake") or getattr(a, "open_prs", False) or \
        getattr(a, "page", False) or getattr(a, "send", False) or getattr(a, "apply", False)
    if writes and os.path.exists(KILL):
        print(f"gdpr-pipeline disabled ({KILL})")
        return 0
    lock = hold_lock(a.store) if writes else None
    if writes and lock is None:
        # Not an error: the run that holds the lock is doing this same work right now, and the next tick retries.
        print("another gdpr-pipeline run holds the lock: nothing done")
        return 0
    run = Run(Store(a.store))
    now = datetime.now(timezone.utc)

    if a.cmd == "intake":
        return cmd_intake(run, a)

    if a.cmd in ("backfill", "tick"):
        # backfill is the bootstrap: it searches the WHOLE lookback (a first run has no cursor, so a 3-hour window
        # would silently leave every older Intercom-only request unregistered).
        do_intake(run, a, intercom_hours=INTERCOM_MAX_LOOKBACK_DAYS * 24 if a.cmd == "backfill" else 3, now=now)
        run.decide_all(hidden_now(run), stale_hours=0 if a.cmd == "backfill" else 20)
        if a.cmd == "tick":
            run.mark_hidden()
            watchdog(run, a.page)
        if a.out:
            Path(a.out).write_text(backfill_table(run.store.all("open"), now) + "\n")
    elif a.cmd == "dedupe":
        pairs = run.store.duplicate_events()
        for keep, drop in pairs:
            print(f"#{drop['register_no']} (row {drop['id']}, {drop['row_key']}) is the same customer event as "
                  f"#{keep['register_no']} (row {keep['id']}, {keep['row_key']})")
            if a.apply:
                run.store.merge_duplicate(keep, drop)
        if pairs and not a.apply:
            print("dry run: nothing written (pass --apply to close the duplicates)")
        elif not pairs:
            print("no duplicate post-confirmation rows")
    elif a.cmd == "decide":
        run.decide_all(hidden_now(run))
    elif a.cmd == "report":
        t = backfill_table(run.store.all("open"), now)
        Path(a.out).write_text(t + "\n") if a.out else print(t)
    elif a.cmd == "hide-batch":
        try:
            hd, pdp = sources.hidden_lists()
        except sources.Unknown as exc:
            run.fail("hide lists", exc)
            return 2
        rows = run.store.all("open")
        cand = hide_batch.plan(rows, hd, pdp, {}, include_legal=a.include_legal)
        flight = hide_batch.in_flight_ids([c["id"] for c in cand]) if cand else {}
        batch = hide_batch.plan(rows, hd, pdp, flight, include_legal=a.include_legal)
        print(f"hide batch: {len(batch)} id(s); already in an open PR: "
              + ", ".join(f"{k} {len(v)}" for k, v in flight.items()))
        for b in batch:
            print(f"  #{b['register_no']} {b['id']} {b['basis']} due {b['due_at'][:10]} needs {'+'.join(b['need'])}")
        if batch:
            res = hide_batch.open_prs(batch, dry_run=not a.open_prs)
            deferred = res.get("deferred") or {}
            for kind, url in deferred.items():
                print(f"deferred ({kind}): the open batch PR {url} has not merged yet, so the next batch waits for it "
                      f"(both PRs of a batch insert at the same point in the same list file, so a second pair would "
                      f"only conflict). These ids stay un-hidden and the next tick retries them.")
            opened = {k for k in ("hdevops", "pdp") if str(res.get(k, "")).startswith("http")}
            if not a.open_prs:
                for k in ("hdevops", "pdp"):
                    if k in deferred:
                        print(f"----- {k} (deferred: {deferred[k]}) -----")
                    else:
                        print(f"----- {k} (dry run) -----\n{res.get(k, '(no change)')}")
            elif opened:
                for rid in {b["request_id"] for b in batch if set(b["need"]) & opened}:
                    row = run.store.get(rid)
                    prs = dict(row["hide_pr"])
                    prs.setdefault("batches", []).append({k: res[k] for k in opened} |
                                                         {"ids": [b["id"] for b in batch if b["request_id"] == rid
                                                                  and set(b["need"]) & opened]})
                    run.store.update(rid, "hide_pr", hide_pr=prs)
                print(json.dumps({k: res[k] for k in opened}, indent=1))
    elif a.cmd == "mark-hidden":
        run.mark_hidden()
    elif a.cmd == "ask":
        items = oldest_first(run.asks(now))[:a.limit or None]
        refuse_send(a, "ask", items)
        for x in items:
            print(f"#{x['register_no']} {x['channel']} -> {x['to']} [{x['kind']}]\n  {x['text']}\n")
            if a.send:
                r = send.deliver(run, x, "ask", a.approved_by)
                print(f"  -> {r['state']} {r.get('why') or r.get('ref') or ''}\n")
    elif a.cmd == "confirm":
        from gdpr_pipeline import checks
        m_result = None
        if a.sitemap:
            ids = sorted({d["id"] for r in run.store.all("open") for d in r["verdict_detail"]})
            try:
                m_result = checks.sitemap_absent(ids)
            except sources.Unknown as exc:
                run.fail("M sitemap walk", exc)
        items = oldest_first(run.confirmations(now, m_result=m_result))[:a.limit or None]
        refuse_send(a, "confirm", items)
        for x in items:
            print(f"===== #{x['register_no']} due {x['due_at'][:10]} -> {x['to']} S={x['S']} P={x['P']} M={x['M']}"
                  f" slot={x.get('slot') or 'confirm'}\n"
                  f"{x['text']}\n")
            if a.send:
                r = send.deliver(run, x, "confirm", a.approved_by, slot=x.get("slot"))
                print(f"===== #{x['register_no']} -> {r['state']} {r.get('why') or r.get('ref') or ''}\n")
    elif a.cmd == "watchdog":
        watchdog(run, a.page)

    if run.errors:
        print(f"{len(run.errors)} read(s) failed; exit 2 (nothing was recorded for those rows)")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
