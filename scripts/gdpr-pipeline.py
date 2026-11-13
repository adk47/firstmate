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
  gdpr-pipeline.py resolve --state sent|failed --why TEXT (--row N | --rows 1,2 | --all-refused) [--apply]
      resolve a send the sender could not finish (`unknown`/`sending`), with the evidence on the record. `--why` and
      a person are required; the decision APPENDS to `erasure_events` and never overwrites the writer's own words.
      `--all-refused` covers only rows whose evidence is a writer REFUSAL (provably pre-send, so one shared reason
      is honest); anything else needs `--force` and an individual `--row`. Dry run unless `--apply`.
  gdpr-pipeline.py watchdog [--page]                    due_at - 3 d without confirmation; ASK > 7 d unanswered
  gdpr-pipeline.py dsar plan|author|send|clock|trail|states      the DSAR ladder (gdpr_pipeline/dsar.py)
      plan    the acknowledgement / status update each open statutory request is owed, with its exact body (reads only)
      author  freeze those bodies and put each up for review; sends nothing
      send    author, then send every message whose exact body carries the reviewer's approval [--limit N]
      clock   every statutory request inside 7 d of its date or past it, oldest first [--json | --line | --watch]
              --line --read-by firstmate is what the firstmate check runs (scripts/gdpr-dsar-clock-check.sh);
              --watch is the hourly unit on the host (gdpr-dsar-clock.timer): it puts the line in the journal and
              pages when requests are inside the window and firstmate has not read the clock for 26 h
      trail   --request N: everything on record for one request (received, checked, messages + hashes + verdicts)
      states  record each request's derived state (received -> identity_check -> in_progress -> responded -> closed)
      No --approved-by: what authorises a ladder message is a reviewer verdict bound to its sha256, checked in
      send.deliver. No verdict, or a gate that cannot run, is a hold. `tick --ladder` runs author + send each hour.

Never deletes: there is no DELETE /api/v3/admin/profile and no muso-cli delete in this pipeline. Store:
GDPR_STORE (default /var/lib/hydra-gdpr/erasure.sqlite). Exit 2 when any read failed (fail closed).
Kill switch: /etc/hydra/gdpr-pipeline.disabled (every step that writes or pages refuses to run).
The ladder has its own as well: /etc/hydra/gdpr-dsar-ladder.disabled (nothing is authored or sent; the clock still reads).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gdpr_pipeline import approval, copy, copy_gate, dsar, hide_batch, send, sources  # noqa: E402
from gdpr_pipeline import intake as intake_core  # noqa: E402
from gdpr_pipeline.run import JAN, Run, backfill_table, page_chunks, page_text, SLACK_CHANNEL  # noqa: E402
from gdpr_pipeline import store  # noqa: E402
from gdpr_pipeline.store import DEFAULT_PATH, Store  # noqa: E402

KILL = "/etc/hydra/gdpr-pipeline.disabled"
DSAR_KILL = "/etc/hydra/gdpr-dsar-ladder.disabled"
DSAR_TICK_LIMIT = 25        # ladder messages that may reach a writer in one tick
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


def hidden_now(run: Run) -> tuple[set[str], dict[str, str]]:
    """(ids on BOTH lists, {id: the one list that holds it}) — a hide needs both, and the halves ship in separate
    PRs, so the second half of the answer is what stops a half-applied hide being filed as somebody else's deletion."""
    try:
        hd, pdp = sources.hidden_lists()
    except sources.Unknown as exc:
        run.fail("hide lists", exc)
        raise SystemExit(2)
    return hd & pdp, sources.half_hidden(hd, pdp)


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
        # `hidden_now()` returns (ids on BOTH lists, {id: the one list that holds it}). Unpacking it straight into the
        # call put the half-hide MAP into `conv_reader`, so a pushed candidate with a conversation_id raised
        # `TypeError: 'dict' object is not callable` and one without it silently lost the map and could keep GONE
        # (QA finding on #1736). Named, so the two can never be swapped again.
        hidden, half = hidden_now(run)
        run.decide_rows([r for _, how, r in rows if how != "unchanged"], hidden, half=half)
        for rid, how, _ in rows:
            r = run.store.get(rid)
            print(f"  {rid}: id={r['identity_verdict'] or '-'} action={r['action'] or '-'}"
                  f"{(' detail=' + r['note']) if r['note'] else ''}")
    # A failed decision is not a success: the caller (a cron, the intake lane) must not believe the row is watched.
    return 2 if run.errors else 0


def cmd_resolve(run: Run, a) -> int:
    """Resolve a send the sender could not finish, with the evidence on the record.

    Why this exists: `send.deliver` records a writer that exited non-zero as `unknown`, which the ledger treats as
    "a letter may be out there, a human's to resolve" and never retries. That is the right answer for a genuinely
    ambiguous POST and the wrong one for a writer that REFUSED before it posted anything -- and the wrong answer is
    not self-correcting: on 2026-11-07 the register held 114 `unknown` rows, every one of them a `REFUSED:` from
    `intercom-ops-write.sh`, and the confirm batch was approved and delivered ZERO of 20 because each row was
    blocked by an earlier claim nobody could clear. There was no operator path at all: `finish_send` is the only
    transition and only the sender calls it.

    The guards are the point, not the convenience:
      * `--why` is required and must not be blank. A resolution with no reason is not a record.
      * the resolution APPENDS to `erasure_events` (from-state, to-state, why, who, the evidence it was decided on)
        and never overwrites the writer's own `detail`, so a later reader can tell a person's decision from the
        sender's transition.
      * `--all-refused` only ever touches rows whose evidence is a writer REFUSAL, which is provably pre-send, so
        one shared reason is honest for the whole batch. Anything else needs `--force` and an individual `--row`.
      * `--all-refused --state sent` is refused: a batch of provably-pre-send refusals cannot have been delivered.
    """
    why = (a.why or "").strip()
    if not why:
        print("resolve: --why is required and must not be blank. A resolution with no reason is not a record.")
        return 2
    by = (a.by or os.environ.get("GDPR_RESOLVER") or os.environ.get("GDPR_SENDER_SEAT")
          or os.environ.get("USER") or "").strip()
    if not by:
        print("resolve: cannot tell who is resolving. Pass --by: the record must name a person.")
        return 2
    if a.force and a.all_refused:
        print("resolve: --force cannot be combined with --all-refused. A batch shares one provable cause; anything "
              "else needs its own reason, one row at a time.")
        return 2
    if a.all_refused and a.state == "sent":
        print("resolve: --all-refused --state sent is refused. A writer refusal is provably pre-send, so nothing "
              "was delivered; the honest resolution is --state failed.")
        return 2
    ids = list(a.row)
    if a.rows:
        try:
            ids += [int(x) for x in a.rows.replace(" ", "").split(",") if x]
        except ValueError:
            print(f"resolve: --rows must be comma-separated integers, got {a.rows!r}")
            return 2
    if a.all_refused and ids:
        print("resolve: --all-refused and --row/--rows are exclusive.")
        return 2
    if not a.all_refused and not ids:
        print("resolve: name the rows (--row N, --rows 1,2,3) or --all-refused.")
        return 2

    # Build the work list: (row id, slot, the ledger record).
    work: list[tuple[int, str, dict]] = []
    if a.all_refused:
        for rec in run.store.resolvable_sends(kind=a.kind, refused_only=True):
            work.append((rec["request_id"], rec["kind"], rec))
    else:
        for rid in ids:
            slots = [a.kind] if a.kind else ["ask", "confirm", "confirm-interim"]
            for slot in slots:
                rec = run.store.send_record(rid, slot)
                if rec is None:
                    continue
                if rec["state"] not in run.store.RESOLVABLE_SEND_STATES:
                    print(f"  #{rid} {slot}: {rec['state']} - not a state a person resolves, skipped")
                    continue
                work.append((rid, slot, rec))
    if not work:
        print("resolve: nothing to resolve.")
        return 0

    # The evidence guard. A row whose writer did not REFUSE is a genuine ambiguity: a person may still resolve it,
    # but only by naming that row and saying why, never by sweeping it into a batch.
    refused = [w for w in work if store.is_writer_refusal(w[2].get("detail"))]
    other = [w for w in work if w not in refused]
    if a.force and len(work) != 1:
        # `--force` is the "a person looked at THIS letter" escape hatch. A batch of genuinely ambiguous sends under
        # one reason is exactly the thing the guard exists to stop: each one is a question about whether a customer
        # already got a statutory letter, and answering two of them with one sentence is not evidence for either.
        # Omitting --kind can also select several slots on one row, so the count is over SENDS, not rows.
        print(f"resolve: --force resolves exactly ONE send, and this selects {len(work)}. Name one --row and one "
              f"--kind, with the reason you checked that letter.")
        return 2
    if other and not a.force:
        for rid, slot, rec in other:
            print(f"  #{rid} {slot}: evidence is NOT a writer refusal ({rec['state']}: "
                  f"{(rec.get('detail') or '(no detail)')[:120]})")
        print(f"resolve: {len(other)} row(s) are not provably pre-send. Resolve each one individually with --row "
              f"and --force once you have checked the thread, or narrow to --all-refused.")
        return 2

    print(f"resolve: {len(work)} letter(s) -> {a.state}, by {by}")
    print(f"  why: {why}")
    for rid, slot, rec in work:
        print(f"  #{rid} {slot}: {rec['state']} -> {a.state}  (claimed {rec['at']}, "
              f"{(rec.get('detail') or '')[:100]})")
    if not a.apply:
        print("dry run: nothing written (pass --apply to record the resolution)")
        return 0
    done = 0
    for rid, slot, rec in work:
        try:
            # `expect` binds the write to the attempt this decision was made on. Without it a reclaim between
            # selection and resolution would be judged as if it were the attempt the operator read; without `at`
            # a full retry cycle that fails the same way would look like the same attempt again.
            run.store.resolve_send(rid, slot, a.state, why, by, evidence=rec.get("detail") or "",
                                   ref=f"resolved by {by}",
                                   expect=(rec["state"], rec.get("detail") or "", int(rec.get("attempt") or 0)))
            done += 1
        except store.SendNotResolvable as exc:
            print(f"  #{rid} {slot}: REFUSED: {exc}")
    print(f"resolve: {done} of {len(work)} recorded (each appended to erasure_events as send-resolved)")
    return 0 if done == len(work) else 2


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


CLOCK_READS = "clock-reads.json"         # sidecar: {reader: last read}, written by `dsar clock --read-by`


CLOCK_CHECK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gdpr-dsar-clock-check.sh")
READER_SHA_RE = re.compile(r"^[0-9a-f]{64}$")


def clock_check_sha() -> str:
    """sha256 of the firstmate check as it is DEPLOYED beside this file, '' when it cannot be read."""
    try:
        with open(CLOCK_CHECK, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return ""


def clock_read_stamp(store_path: str, reader: str, now, sha: str = "") -> None:
    """Record that `reader` read the clock, and with which bytes (`sha`: the check's own sha256, '' when it sent
    none). A sidecar, never the register, and no run lock: a read must not wait on a tick. Written whole and
    renamed, so a reader never sees half a file."""
    if store_path == ":memory:":
        return
    path = _state_path(store_path, CLOCK_READS)
    reads = _load_json(path)
    reads[reader] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    reads[reader + "_sha"] = sha if READER_SHA_RE.match(sha or "") else ""
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(reads, f, sort_keys=True)
    os.replace(tmp, path)


def clock_reader_watch(run: Run, now, page: bool) -> str:
    """Say so, once a day, when requests are inside the window and the firstmate check is not reading the clock, or
    the check that is reading it is not the one deployed (`dsar.clock_unread`). The check is registered in a
    firstmate home by `scripts/gdpr-dsar-clock-register.sh`, on a box no deploy of this repository reaches; this is
    the half that does deploy, and it makes a missing, dead or out-of-date check loud instead of silent."""
    reads = _load_json(_state_path(run.store.path, CLOCK_READS))
    line = dsar.clock_unread(str(reads.get("firstmate") or ""), run.dsar_clock(now), now,
                             read_sha=str(reads.get("firstmate_sha") or ""), deployed_sha=clock_check_sha())
    if not line:
        return ""
    print("  " + line)
    if not page:
        return line
    last = _state_path(run.store.path, "clock-unread-last.json")
    today = now.strftime("%Y-%m-%d")
    if _load_json(last).get("day") == today:
        return line
    if slack_post(line):
        with open(last, "w") as f:
            json.dump({"day": today}, f)
    else:
        run.errors.append("clock-unread page failed")
    return line


APPROVERS = ("U7RP6HKUZ", "U038BM16T7W", "U0AL36NADEY")      # Aaron / Jan / Nick


def oldest_first(items: list[dict]) -> list[dict]:
    """Statutory order: the request whose deadline is oldest goes first. The register is a legal record, so the queue
    is not allowed to depend on row id or intake order."""
    return sorted(items, key=lambda x: (x.get("due_at") or "", x.get("register_no") or 0))


def select_batch(a, kind: str, items: list[dict], run=None) -> list[dict]:
    """The approved batch is FROZEN, and a manifest is how it stays frozen (firstmate ruling 2026-11-04).

    `--limit N` is a moving selector: it takes the oldest N of *whatever is open now*, so the next intake re-cuts the
    batch and the digest a human approved no longer names it. `--manifest FILE` names the rows instead, so new intake
    lands in the NEXT batch and cannot touch this one. Two entry forms, and the pinned one is what a GO names:

      [329, 323, ...]                                            register numbers, cut from a dry run
      [{"request_id": "…", "register_no": 329, "body_sha": "…"}]  a pinned batch file: row + the exact body it was
                                                                  approved with, so intake additions and COPY
                                                                  changes are told apart by the run, not by memory

    It fails closed on every way the manifest can stop being the approved batch:
      - a row/register number not in the current sendable set (closed, already sent, verdict changed, or a typo):
        sending the rest would be a DIFFERENT batch under the same approval;
      - a BODY that no longer hashes to the pinned sha: copy is approved per body, so that is a FRESH GO, never a
        "re-cut" (firstmate ruling 2026-11-04: additions may carry a GO, a body change may not);
      - a manifest with no rows, or an unreadable/unparseable file;
      - `--manifest` together with `--limit`: two selectors with no defined winner.
    """
    if not a.manifest:
        return oldest_first(items)[:a.limit or None]
    if a.limit:
        print("REFUSED: --manifest and --limit are two different selectors for one batch; use one")
        raise SystemExit(1)
    try:
        raw = open(a.manifest).read()
    except OSError as exc:
        print(f"REFUSED: cannot read the manifest {a.manifest}: {exc}")
        raise SystemExit(1)
    claimed = ""
    try:
        wanted = json.loads(raw)
        if isinstance(wanted, dict) and isinstance(wanted.get("entries"), list):
            # the pinned FILE form: the batch document records which ruling and digest it was cut for, and the run
            # checks its own rendering against that claim below rather than trusting the file's name
            wanted, claimed = wanted["entries"], str(wanted.get("digest") or "")
        if not isinstance(wanted, list):
            raise ValueError("not a JSON list")
    except ValueError:
        wanted = [tok for tok in re.split(r"[\s,]+", raw.strip()) if tok]
    nums, rows, shas = [], [], {}
    for x in wanted:
        if isinstance(x, dict):
            # the pinned form: a batch file names the ROW and the BODY it was approved with, so "no body change"
            # (firstmate ruling 2026-11-04) is checked by the run instead of remembered by a person
            rid = str(x.get("request_id") or x.get("row") or "").strip()
            if not rid:
                print(f"REFUSED: manifest entry {x!r} has no request_id")
                raise SystemExit(1)
            if not x.get("body_sha"):
                # Same failure family as the mixed form: a row-shaped entry with no body_sha looks pinned but skips
                # the copy-change proof entirely, so a rewording after the GO would go out under the old approval.
                # A list of rows is a supported form; a list of HALF-pinned rows is not.
                print(f"REFUSED: manifest entry {rid!r} is in the pinned (row) form but carries no body_sha. Without "
                      f"it the run cannot prove the copy did not change after the GO, which is the whole point of "
                      f"pinning. Add body_sha, or name the requests by register number instead.")
                raise SystemExit(1)
            rows.append(str(rid))
            shas[rid] = str(x["body_sha"]).strip().lower()
            # NOTE: `register_no` is deliberately NOT added to `nums` here. It is documentation for a human reading
            # the file (the selection is by row id, because a register number can be renumbered); folding it into
            # `nums` would make every valid pinned manifest look like a MIXED one and trip the refusal below.
            continue
        if isinstance(x, bool) or not isinstance(x, (int, str)):
            print(f"REFUSED: manifest entry {x!r} is not a register number")
            raise SystemExit(1)
        s_ = str(x).strip().lstrip("#")
        if not s_.isdigit():
            print(f"REFUSED: manifest entry {x!r} is not a register number")
            raise SystemExit(1)
        nums.append(int(s_))
    if not nums and not rows:
        print(f"REFUSED: the manifest {a.manifest} names no requests")
        raise SystemExit(1)
    if nums and rows:
        # The two forms carry DIFFERENT guarantees, so a file that mixes them cannot be one approval. A bare register
        # number has no body_sha, so the row/body check below cannot speak for it; letting the pinned rows win (the
        # old behaviour) silently DROPPED the bare ones - a manifest naming #329 and row-58 selected only row-58, and
        # an operator could approve the digest of an incomplete batch. Refuse instead of guessing which form was
        # meant: dropping a named request is exactly the silent-removal failure the pin exists to prevent.
        print(f"REFUSED: the manifest {a.manifest} mixes the two entry forms - {len(nums)} bare register number(s) and "
              f"{len(rows)} pinned row(s). They guarantee different things: a bare number is not copy-checked, so it "
              f"cannot ride an approval whose other rows were pinned by body_sha. Use ONE form for the whole file "
              f"(pin every row with request_id + body_sha, or name every request by register number).")
        raise SystemExit(1)
    if rows:                                                    # row ids win: a register number can be renumbered
        by_row = {str(x["row"]): x for x in items}   # the store's row id may be an int; a JSON file says str
        missing_rows = [r for r in rows if r not in by_row]
        if missing_rows:
            # Say WHICH reason the batch no longer matches, because one of them is benign and one is not: rows that
            # already carry a ledger record for this kind mean an earlier run of the same batch got part-way (a send
            # that died at letter N), and the remainder then needs a fresh pin+approval under the "no removals" rule.
            # Rows that left for any other reason mean the register moved under an approval that no longer names it.
            sent = []
            if run is not None:
                for rid in missing_rows:
                    try:
                        rec = run.store.send_record(int(rid), kind)
                    except (TypeError, ValueError):
                        rec = None
                    if rec and rec.get("state") in ("sent", "sending", "unknown"):
                        sent.append(str(rid))
            detail = ""
            if sent:
                detail = (f" {len(sent)} of them already carry a ledger record for a {kind} letter "
                          f"({', '.join(sent[:5])}{' …' if len(sent) > 5 else ''}), so an earlier run of THIS batch "
                          f"got part-way. The remainder is a removal from the approved set: re-pin the unsent rows and "
                          f"get a fresh approval rather than resuming under the old one.")
            print(f"REFUSED: {len(missing_rows)} request(s) in the manifest are not in the {kind} set now "
                  f"({', '.join(missing_rows[:5])}{' …' if len(missing_rows) > 5 else ''}). Sending the rest would be "
                  f"a different batch than the one that was approved - re-cut and get a fresh approval.{detail}")
            raise SystemExit(1)
        changed = []
        for rid, want_sha in shas.items():
            got = hashlib.sha256((by_row[rid].get("text") or "").encode()).hexdigest()
            if got != want_sha:
                changed.append(rid)
        if changed:
            print(f"REFUSED: the letter BODY changed for {len(changed)} request(s) ({', '.join(changed[:5])}"
                  f"{' …' if len(changed) > 5 else ''}) since the batch was pinned. Copy is approved per body, so a "
                  f"changed body needs a FRESH approval - it is not a re-cut.")
            raise SystemExit(1)
        picked = oldest_first([by_row[r] for r in sorted(set(rows))])
        if claimed:
            got = approval.digest(kind, picked)
            if got != claimed:
                print(f"REFUSED: the batch file records digest {claimed} but these rows render {got} now. The pin and "
                      f"the register disagree, so the file is not describing the batch it names - re-pin and get a "
                      f"fresh approval rather than sending under the old one.")
                raise SystemExit(1)
        return picked
    want = set(nums)
    have = {x["register_no"]: x for x in items}
    missing = sorted(want - set(have))
    if missing:
        print(f"REFUSED: {len(missing)} request(s) in the manifest are not in the {kind} set now "
              f"({', '.join('#' + str(n) for n in missing[:20])}{' …' if len(missing) > 20 else ''}). "
              f"The manifest was cut against a different register state, so sending the rest would be a different "
              f"batch than the one that was approved - re-cut the manifest and get a fresh approval.")
        raise SystemExit(1)
    picked = [have[n] for n in sorted(want)]                 # oldest_first() sorts by deadline below
    return oldest_first(picked)


def approved_identity(approved_by: str) -> tuple[str, str]:
    """(identity, "") when `approved_by` is an allowlisted human or the resolved sender seat, else ("", WHY).

    Split out so the SCHEDULED path (the hourly tick, Fable 11-04 B26 Q1) can carry the SAME authenticated-identity
    rule without inheriting `refuse_send`'s SystemExit: a tick that died on a missing bot token would stop doing the
    intake and hide work it is also responsible for. The seat is Slack's `auth.test` on the devops bot, never a name,
    so an id typed into a unit file is still checked against the token we actually hold."""
    if approved_by in APPROVERS:
        return approved_by, ""
    try:
        seat = approval.seat_id()
    except approval.Unverifiable as exc:
        return "", str(exc)
    if approved_by != seat:
        return "", (f"--approved-by must be an allowlisted human (Aaron / Jan / Nick Slack id) or the sender seat "
                    f"({seat})")
    return approved_by, ""


def scheduled_send(store_or_none, a, now) -> None:
    """The UNLOCKED, UNATTENDED path: one approved letter per erratum, on its own due date, with no human in the loop.

    Decision `gdpr-owner` (B26 Q1) put this here. It is deliberately NOT a flag on the interactive path: that one still
    demands a 2-hour Slack message naming the batch digest, and nothing below can satisfy it. What authorises a send
    here is a REVIEWED LEDGER ENTRY with `standing: true` (policies/gdpr-send-rulings.json is PR-reviewed), the
    compiled unlock, and the invoking identity matching the ruling - all three, every run.

    NON-FATAL on purpose. The tick has already done intake, decide and mark_hidden by the time it gets here; a missing
    or not-yet-live ruling must skip the kind it cannot authorise and let the rest of the hour's work stand, instead of
    failing the unit and losing that work with it. Every skip says WHICH of the three things was wrong.
    """
    run = store_or_none
    who, bad = approved_identity(a.approved_by)
    if bad:
        print(f"tick send: REFUSED - {bad}")
        return
    if not copy.PIPELINE_SENDS_APPROVED:
        print("tick send: REFUSED - pipeline sends are LOCKED (copy.PIPELINE_SENDS_APPROVED = False)")
        return
    # THE CAP COUNTS LETTERS THAT REACH A WRITER, NOT ROWS EXAMINED (QA finding on #1779). `--limit` is a first-wave
    # brake on how many customers get mail in one hour. Applying it to the SELECTION instead let a permanently-refused
    # prefix starve everything behind it: `Run.asks()` keeps returning an unsent row, so 25 rows that can never send
    # (no requester_email, unapproved copy) occupied the window on every tick and row 26 was never attempted, even
    # after its statutory deadline. So the selection is unlimited and the brake is applied below, to attempts.
    # Only the two fields `select_batch` reads, named explicitly: a `vars(a)` copy would depend on how the caller built
    # its namespace, and a missing `limit` there is an AttributeError in the middle of the send pass.
    unlimited = argparse.Namespace(manifest=getattr(a, "manifest", ""), limit=None)
    for kind in ("ask", "confirm"):
        if kind == "ask":
            items = select_batch(unlimited, "ask", send.materialise(run, run.asks(now)), run)
        else:
            items = select_batch(unlimited, "confirm", send.materialise(run, run.confirmations(now)), run)
        if not items:
            print(f"tick send {kind}: nothing ready")
            continue
        # SELECT BY THE GRANT'S CLASSES BEFORE VERIFYING (QA finding on #1779). `copy.ASK` is erasure copy and a
        # dmca_takedown or legal_threat row reaches the same ASK_LINK verdict, so a mixed batch would be refused
        # WHOLE - and refusing the erasure letters because a takedown notice shares the batch would leave the
        # statutory breaches unsent, which is the opposite of fail-closed. Narrowing here keeps the erasure letters
        # moving; `verify_standing` below still checks the result, so the two have to agree.
        allowed = approval.standing_classes(kind, a.approved_by, now=now)
        if allowed:
            kept = [x for x in items if str(x.get("class") or "") in allowed]
            if len(kept) != len(items):
                print(f"tick send {kind}: {len(items) - len(kept)} row(s) left out - class not in the standing "
                      f"grant {sorted(allowed)}")
            items = kept
        if not items:
            print(f"tick send {kind}: nothing the standing grant covers")
            continue
        ok, why = approval.verify_standing(kind, items, a.approved_by, now=now)
        print(f"tick send {kind}: {len(items)} letter(s) -> " + ("approved: " if ok else "REFUSED: ") + why)
        if not ok:
            continue
        cap = a.limit or 0
        attempted = 0
        for i, x in enumerate(items):
            if cap and attempted >= cap:
                print(f"  {len(items) - i} letter(s) left for the next tick (--limit {cap})")
                break
            r = send.deliver(run, x, kind, a.approved_by, slot=x.get("slot"))
            # A refusal or a skip never reached a writer, so it does not spend the brake - and it stays in the queue,
            # so the tick retries it the moment its cause is fixed (a mailbox authed, an address recovered).
            if r["state"] in ("sent", "unknown", "failed"):
                attempted += 1
            print(f"  #{x['register_no']} -> {r['state']} {r.get('why') or r.get('ref') or ''}")


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
    who, bad = approved_identity(a.approved_by)
    if bad:
        print(f"REFUSED: {bad}")
        raise SystemExit(1)
    ok, why = approval.verify(kind, items, a.approved_by, APPROVERS)
    print(("approved: " if ok else "REFUSED: ") + why)
    if not ok:
        raise SystemExit(1)


def dsar_ladder(run: Run, now, limit: int, send_them: bool) -> None:
    """Author the ladder messages owed and (with `send_them`) send the approved ones. Prints one line per message.

    Non-fatal, like the scheduled send: a held message is the normal state while a verdict is pending, and a copy
    file that cannot be read stops the ladder for this run without losing the tick's other work."""
    if os.path.exists(DSAR_KILL):
        print(f"dsar ladder: disabled ({DSAR_KILL})")
        return
    if not copy_gate.GATE.exists():
        # No gate on this host: nothing could ever be approved, so nothing is authored. Authoring would make the
        # older ask stand down for the request (`Run.asks`) and leave it with no first message from anyone. The
        # ladder starts by itself the first tick the gate is there.
        print(f"dsar ladder: held, the copy gate is not installed ({copy_gate.GATE})")
        return
    try:
        results = run.dsar_send(now, limit=limit) if send_them else run.dsar_author(now)
    except dsar.CopyError as exc:
        run.fail("dsar ladder copy", exc)
        return
    tally: dict[str, int] = {}
    for x in results:
        state = x.get("state") or ("approved" if x.get("approved") else "held")
        tally[state] = tally.get(state, 0) + 1
        print(f"  #{x['register_no']} {x['slot']} {x['variant']} sha256={x['body_sha'][:16]} -> {state} "
              f"{x.get('why') or x.get('ref') or x.get('verdict_id') or x.get('gate_reason') or ''}")
    print(f"dsar ladder: {len(results)} message(s) owed: "
          + (", ".join(f"{n} {s}" for s, n in sorted(tally.items())) or "none"))


def cmd_dsar(run: Run, a, now) -> int:
    if a.action == "plan":
        items = run.dsar_owed(now)
        for x in items:
            print(f"===== #{x['register_no']} {x['class']} {x['slot']} variant={x['variant']} due {x['due_at'][:10]} "
                  f"need={x['need']}" + (f"  PROBLEM: {x['problem']}" if x["problem"] else
                                         f" sha256={hashlib.sha256(x['text'].encode()).hexdigest()}"))
            if a.bodies and x["text"]:
                print(x["text"] + "\n")
        print(f"dsar plan: {len(items)} message(s) owed, {sum(1 for x in items if x['problem'])} with a problem")
    elif a.action == "author":
        dsar_ladder(run, now, 0, send_them=False)
        run.dsar_states()
    elif a.action == "send":
        dsar_ladder(run, now, a.limit, send_them=True)
        run.dsar_states()
    elif a.action == "states":
        print(f"dsar states: {run.dsar_states()} request(s) changed state")
    elif a.action == "extend":
        # Records the NEED for an Art. 12(3) extension against one request. It sends nothing and moves no date: the
        # ladder selects the notice only when every other condition also holds (`dsar.owed`), the notice is gated
        # like any message, and the date moves when the notice has been sent.
        row = next((r for r in run.store.all() if r["register_no"] == a.request), None)
        why = ""
        if not row:
            why = f"no request #{a.request} in the register"
        elif row["class"] not in dsar.STATUTORY or row["status"] != "open":
            why = "not an open erasure or access request"
        elif not a.evidence.strip() or not a.ruling.strip():
            why = "--evidence (why more time is necessary for THIS request) and --ruling (who ruled so) are both needed"
        elif now >= dsar.due(row):
            why = "the date has passed: an extension never covers lateness already incurred"
        elif row.get("extended_until"):
            why = "this request's date has already been moved once"
        if why:
            print(f"dsar extend: refused, {why}")
            return 1
        run.store.update(row["id"], "extension_need", extension_need=a.evidence.strip(),
                         extension_need_ruling=a.ruling.strip())
        print(f"dsar extend: need recorded for #{a.request} under {a.ruling.strip()}; nothing sent, no date moved")
    elif a.action == "clock":
        clock = run.dsar_clock(now)
        if a.json:
            print(json.dumps(clock, sort_keys=True))
        elif a.line:
            # The firstmate page (scripts/gdpr-dsar-clock-check.sh): one line, or nothing when no request is inside
            # the window. Nothing printed is a READ that found nothing; a clock that cannot be read exits non-zero.
            line = dsar.clock_line(clock)
            if line:
                print(line)
            if a.read_by:
                clock_read_stamp(run.store.path, a.read_by, now, a.reader_sha)
        elif a.watch:
            # The hourly unit (gdpr-dsar-clock.timer, scripts/install-aux-units.sh). It is NOT a writing run: it takes
            # no run lock, so an hour-long tick cannot make the clock skip, and it is not `--page`, which would. The
            # line goes to the journal every hour, so what the clock said and when can be read back. The page is the
            # one about the reader, and the pipeline kill file silences pages as it does everywhere else; the line
            # firstmate reads is a read, and no kill file stops it.
            print(dsar.clock_line(clock) or f"GDPR clock: nothing inside {clock['alarm_days']} d of its date "
                                           f"({clock['open']} open)")
            clock_reader_watch(run, now, page=not os.path.exists(KILL))
        else:
            print(dsar.clock_line(clock) or f"GDPR clock: nothing inside {clock['alarm_days']} d "
                                                             f"of its date ({clock['open']} open)")
            for x in clock["alarm"]:
                print(f"  #{x['register_no']} {x['class']} {x['state']} received {x['received_at'][:10]} due "
                      f"{x['due_at'][:10]} ({x['days_left']:+.1f} d) need={x['need']} last message "
                      f"{x['last_message_at'][:10] or 'none'}" + (f" held: {x['held']}" if x["held"] else ""))
    elif a.action == "trail":
        trail = run.dsar_trail(a.request)
        if trail is None:
            print(f"no request #{a.request} in the register")
            return 1
        print(json.dumps(trail, indent=2, sort_keys=True))
    return 2 if run.errors else 0


def cmd_access(run: Run, a, now) -> int:
    """Prints counts, hashes and reasons only: never a value from the copy, and never an address."""
    if a.action == "build":
        out = run.access_build(a.request, record=a.record)
    else:
        if os.path.exists(DSAR_KILL):
            print(f"access deliver: disabled ({DSAR_KILL})")
            return 0
        out = run.access_deliver(a.request, now, dry_run=a.dry_run)
    print(json.dumps(out, indent=2, sort_keys=True))
    return 2 if run.errors else (0 if out["state"] in ("built", "sent", "would_send", "skipped") else 1)


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
        if name == "tick":
            # The scheduled send path (Fable 11-04 B26 Q1). Off unless asked for: the tick's default behaviour is
            # unchanged, so an install that does not pass --send can never message a customer.
            p.add_argument("--send", action="store_true",
                           help="also deliver the letters that are ready, under a standing ruling (default: no sends)")
            p.add_argument("--approved-by", default="")
            p.add_argument("--limit", type=int, default=0,
                           help="send at most N letters per kind, OLDEST deadline first (0 = no cap)")
            p.add_argument("--manifest", default="",
                           help="send EXACTLY these requests (the pinned batch file), instead of oldest-first")
            # The DSAR ladder. Off unless asked for, like --send; what authorises each message is its reviewer
            # verdict, so there is no --approved-by for it.
            p.add_argument("--ladder", action="store_true",
                           help="also author the acknowledgements / status updates owed and send the approved ones")
            p.add_argument("--ladder-limit", type=int, default=DSAR_TICK_LIMIT,
                           help=f"send at most N ladder messages this tick (default {DSAR_TICK_LIMIT})")
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
    sub.add_parser("copy-sha", help="print the copy identity a STANDING ruling must record (copy.fingerprint())")
    for name in ("ask", "confirm"):
        p = sub.add_parser(name)
        p.add_argument("--send", action="store_true", help="actually deliver (default is a dry run)")
        p.add_argument("--approved-by", default="")
        p.add_argument("--limit", type=int, default=0,
                       help="send at most N letters, OLDEST deadline first (0 = no cap)")
        p.add_argument("--manifest", default="",
                       help="send EXACTLY these requests, so later intake cannot re-cut a batch a human already "
                            "approved: a JSON list of register numbers, of {request_id, register_no, body_sha} "
                            "objects (the pinned form - a body change then needs a fresh approval), or one "
                            "register number per line")
        if name == "confirm":
            p.add_argument("--sitemap", action="store_true", help="walk every sitemap file for the M line")
    p = sub.add_parser("resolve", help="resolve a send the sender could not finish (unknown/sending), with the "
                                        "evidence it was decided on")
    p.add_argument("--row", type=int, action="append", default=[], help="register row id (repeatable)")
    p.add_argument("--rows", default="", help="comma-separated row ids")
    p.add_argument("--all-refused", action="store_true",
                   help="every unknown row whose evidence is a writer REFUSAL (provably pre-send, so one shared "
                        "--why covers the batch)")
    p.add_argument("--kind", default="", help="only this slot (ask | confirm); default: every slot on the row")
    p.add_argument("--state", required=True, choices=("sent", "failed"),
                   help="sent = the letter did go out; failed = it did not, and the slot is retryable again")
    p.add_argument("--why", required=True,
                   help="the evidence this was decided on. Required: a resolution with no reason is not a record")
    p.add_argument("--by", default="", help="who resolved it (default: $GDPR_RESOLVER, $GDPR_SENDER_SEAT, $USER)")
    p.add_argument("--force", action="store_true",
                   help="resolve a row whose evidence is NOT a writer refusal. Needs an individual --row; never "
                        "combined with --all-refused")
    p.add_argument("--apply", action="store_true", help="write (default: dry run)")
    p = sub.add_parser("watchdog")
    p.add_argument("--page", action="store_true")
    p = sub.add_parser("dsar", help="the DSAR ladder: acknowledgement, status updates, the clock and the trail")
    p.add_argument("action", choices=("plan", "author", "send", "clock", "trail", "states", "extend"))
    p.add_argument("--evidence", default="", help="extend: why more time is necessary for this request")
    p.add_argument("--ruling", default="", help="extend: the id of the ruling that found the need")
    p.add_argument("--limit", type=int, default=0, help="send: at most N messages (0 = no cap)")
    p.add_argument("--bodies", action="store_true", help="plan: print each exact body")
    p.add_argument("--json", action="store_true", help="clock: one JSON object")
    p.add_argument("--line", action="store_true", help="clock: the one-line page, or nothing when the window is empty")
    p.add_argument("--read-by", default="", choices=("", "firstmate"),
                   help="clock --line: record that this reader read the clock (the tick pages when nobody has)")
    p.add_argument("--reader-sha", default="",
                   help="clock --read-by: sha256 of the check doing the reading (the unit pages when it is not the "
                        "deployed scripts/gdpr-dsar-clock-check.sh)")
    p.add_argument("--watch", action="store_true",
                   help="clock: the hourly unit - print the line, page when firstmate has stopped reading the clock")
    p.add_argument("--request", type=int, default=0, help="trail: the register number")
    p = sub.add_parser("access", help="the Art. 15 answer: build the copy of one account's data, and deliver it")
    p.add_argument("action", choices=("build", "deliver"))
    p.add_argument("--request", type=int, required=True, help="the register number")
    p.add_argument("--record", action="store_true",
                   help="build: write the copy beside the register (0600) and put its hash on the trail")
    p.add_argument("--dry-run", action="store_true", help="deliver: say what would be sent, send nothing")
    p = sub.add_parser("dedupe", help="report (or --apply) the same customer event opened under two row keys")
    p.add_argument("--apply", action="store_true")
    p = sub.add_parser("reconcile", help="report (or --apply) the `unknown` letters the writer refused BEFORE posting")
    p.add_argument("--apply", action="store_true")
    p = sub.add_parser("recover-addresses",
                       help="report (or --apply) the requester address for open rows that have none")
    p.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    writes = a.cmd in ("backfill", "tick", "decide", "mark-hidden", "intake") or getattr(a, "open_prs", False) or \
        getattr(a, "page", False) or getattr(a, "send", False) or getattr(a, "apply", False) or \
        (a.cmd == "dsar" and a.action in ("author", "send", "states", "extend")) or \
        (a.cmd == "access" and (a.action == "deliver" or getattr(a, "record", False)))
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
    if a.cmd == "dsar":
        return cmd_dsar(run, a, now)
    if a.cmd == "access":
        return cmd_access(run, a, now)

    if a.cmd in ("backfill", "tick"):
        # backfill is the bootstrap: it searches the WHOLE lookback (a first run has no cursor, so a 3-hour window
        # would silently leave every older Intercom-only request unregistered).
        do_intake(run, a, intercom_hours=INTERCOM_MAX_LOOKBACK_DAYS * 24 if a.cmd == "backfill" else 3, now=now)
        both, half = hidden_now(run)
        if a.cmd == "tick":
            # BEFORE the decision pass, so a request reopened this tick is decided and acknowledged in it.
            reopened = run.reopen_unanswered()
            if reopened:
                print(f"tick: reopened {len(reopened)} statutory request(s) closed with no final response on "
                      f"record: {', '.join('#' + str(n) for n in reopened)}")
        run.decide_all(both, stale_hours=0 if a.cmd == "backfill" else 20, half=half)
        if a.cmd == "tick":
            run.mark_hidden()
            watchdog(run, a.page)
            clock_reader_watch(run, now, a.page)
            # BEFORE the scheduled send: a statutory request the ladder has authored a message for gets no legacy ask
            # (Run.asks), so the ladder has to have looked at the hour's new requests first.
            if getattr(a, "ladder", False):
                dsar_ladder(run, now, a.ladder_limit, send_them=True)
            run.dsar_states()
            # AFTER the read-back: `mark_hidden` is what turns a landed hide into hidden_at, so a confirmation
            # materialised before it would miss the rows this tick just landed. A send never changes that ordering.
            if getattr(a, "send", False):
                # A provable pre-flight refusal is retryable, and the tick is where it gets retried. Doing this here
                # rather than leaving it to a separate timer is the difference between a stranded letter healing on
                # the next tick and a stranded letter sitting in `unknown` until somebody remembers: the failure this
                # repairs (40 letters stuck for a day) WAS "nobody ran the repair". Only rows whose detail proves
                # nothing was posted move, and only while the request is still open.
                healed = [r for r in send.reconcile_stranded(run, apply=True) if r["provable"] and r["open"]]
                if healed:
                    print(f"tick reconcile: {len(healed)} stranded letter(s) re-queued (the writer refused before "
                          f"posting, so nothing reached the customer)")
                scheduled_send(run, a, now)
        if a.out:
            Path(a.out).write_text(backfill_table(run.store.all("open"), now) + "\n")
    elif a.cmd == "dedupe":
        pairs = run.store.duplicate_events()
        for keep, drop in pairs:
            print(f"#{drop['register_no']} (row {drop['id']}, {drop['row_key']}) is the same customer event as "
                  f"#{keep['register_no']} (row {keep['id']}, {keep['row_key']})")
            if a.apply:
                try:
                    run.store.merge_duplicate(keep, drop)
                except store.MergeRefused as exc:
                    # A pair that cannot be folded safely is REPORTED and left open, never half-merged: the keys and
                    # pages have not moved, so the next run sees the same pair and a person can reconcile it.
                    print(f"  REFUSED: {exc}")
                    run.fail(f"dedupe {drop['id']} -> {keep['id']}", exc)
        if pairs and not a.apply:
            print("dry run: nothing written (pass --apply to close the duplicates)")
        elif not pairs:
            print("no duplicate post-confirmation rows")
    elif a.cmd == "reconcile":
        # `unknown` is the never-retried state, and it is the right answer for a timeout. It is the wrong answer for a
        # pre-flight refusal, which happens above the POST: nothing was posted, so the letter is retryable and
        # leaving it `unknown` strands it forever. Only the writer's own pre-POST refusal text is provable.
        before = len(run.store.unknown_sends())
        rows = send.reconcile_stranded(run, apply=a.apply)
        moved = sum(1 for r in rows if r["provable"] and r["open"])
        for r in rows:
            if not r["provable"]:
                verdict = "stays unknown (may have posted)"
            elif not r["open"]:
                verdict = "stays unknown (register row is closed; no letter owed)"
            else:
                verdict = "RE-QUEUED (refused before posting; the next tick sends it)"
            print(f"row {r['request_id']} {r['kind']} via {r['channel']} {r['target']} at {r['at']}: {verdict}")
        after = len(run.store.unknown_sends())
        print(f"unknown letters: {before} before, {after} after; {moved} re-queued")
        if not a.apply:
            print("dry run: nothing written (pass --apply to re-queue the provable ones)")
        elif not moved:
            print("nothing to reconcile")
    elif a.cmd == "recover-addresses":
        # The data half of the 69 rows that could not be answered: the code half (a new thread from support@) is in
        # `route`. This only fills `requester_email` and NEVER touches erasure_sends - a claimed-unknown row stays
        # claimed and unknown, so a mailbox change can never become a second statutory letter (captain, item 4).
        rows = send.recover_addresses(run, apply=a.apply)
        got = [r for r in rows if r["email"]]
        for r in rows:
            if r["email"]:
                print(f"row {r['id']} {r['channel']}: {r['email']} (from {r['source']})")
            else:
                print(f"row {r['id']} {r['channel']}: NO ADDRESS - {r['why']}")
        print(f"open rows with no address: {len(rows)}; recovered {len(got)}; "
              f"genuinely unrecoverable {len(rows) - len(got)}")
        if not a.apply:
            print("dry run: nothing written (pass --apply to record the recovered addresses)")
    elif a.cmd == "decide":
        both, half = hidden_now(run)
        run.decide_all(both, half=half)
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
        # `flight` is what OTHER people's open PRs already add. The pipeline's own PR is not in it: open_prs owns
        # that PR and re-issues it with the whole set, so nothing queues behind an unmerged batch.
        flight = hide_batch.in_flight_ids([c["id"] for c in cand]) if cand else {}
        batch = hide_batch.plan(rows, hd, pdp, flight, include_legal=a.include_legal)
        carried: set[str] = set()
        if not a.include_legal:
            # A legal hide-first id enters only on the captain's --include-legal run. Once that run's PR is open the
            # GO is on record there, and this routine run must not replace that PR with one that drops the id.
            routine = {b["id"] for b in batch}
            batch = hide_batch.carry_legal(batch, hide_batch.plan(rows, hd, pdp, flight, include_legal=True),
                                           hide_batch.own_added())
            carried = {b["id"] for b in batch} - routine
        print(f"hide batch: {len(batch)} id(s); already in somebody else's open PR: "
              + ", ".join(f"{k} {len(v)}" for k, v in flight.items()))
        for b in batch:
            print(f"  #{b['register_no']} {b['entity']} {b['id']} {b['basis']} due {b['due_at'][:10]} "
                  f"needs {'+'.join(b['need'])}"
                  + ("  (kept: already in the open batch PR from an --include-legal run)" if b["id"] in carried
                     else ""))
        # Always called, an empty batch included: that is the run that closes a pipeline PR nothing still needs.
        res = hide_batch.open_prs(batch, dry_run=not a.open_prs)
        for pid in res["blocked_items"]:
            print(f"blocked (track/album {pid}): the platform-data-processing test has no {hide_batch.ITEMS_ANCHOR} "
                  f"set yet, so this page is prepared in NEITHER repository (never half a hide on purpose). The "
                  f"one-time change is in docs/support/caroline-billing-and-hide.md; the page stays un-hidden.")
        for kind, url in res["kept"].items():
            print(f"unchanged ({kind}): {url} already carries exactly this set; waiting for a person to merge it")
        for kind, urls in res["superseded"].items():
            print(f"{'superseded' if a.open_prs else 'would supersede'} ({kind}): {', '.join(urls)}")
        for line in res["close_failed"]:
            print(f"WARNING could not close a superseded batch PR (the next run retries): {line}")
        for kind, url in res["unreadable"].items():
            # Not a verdict about the PR: nothing in that repository was opened or closed, and the run exits 2.
            run.fail(f"hide batch ({kind})", sources.Unknown(
                f"could not read what the open pipeline PR {url} adds, so it was neither replaced nor closed"))
        if not a.open_prs:
            for k in ("hdevops", "pdp"):
                if k not in res["kept"]:
                    print(f"----- {k} (dry run) -----\n{res.get(k) or '(no change)'}")
        elif res["opened"]:
            opened = set(res["opened"])
            for rid in {b["request_id"] for b in batch if set(b["need"]) & opened}:
                row = run.store.get(rid)
                prs = dict(row["hide_pr"])
                prs.setdefault("batches", []).append({k: res[k] for k in opened} |
                                                     {"ids": [b["id"] for b in batch if b["request_id"] == rid
                                                              and set(b["need"]) & opened]})
                run.store.update(rid, "hide_pr", hide_pr=prs)
            print(json.dumps(res["opened"], indent=1))
    elif a.cmd == "mark-hidden":
        run.mark_hidden()
    elif a.cmd == "copy-sha":
        # The value a standing ruling's `copy_sha` must carry. Printed rather than hand-computed: a grant that names
        # the wrong words refuses every send, and a human re-typing a hash is how that happens.
        print(copy.fingerprint())
    elif a.cmd == "ask":
        # ORDER MATTERS, and it is the whole point of this pair: materialise FIRST, then narrow+validate.
        # `select_batch` checks each pinned entry's recorded `body_sha` against the text it is HANDED, so handing it
        # the pre-materialisation body validates the pin against bytes that are not what leaves - measured on the live
        # register: 9 pinned rows gained the approved lead line, their sha no longer matched the pin, and the manifest
        # still accepted them. Materialising first makes the manifest answer for the FINAL letter (lead + subject),
        # so "a changed body needs a FRESH approval" covers the copy that actually goes out.
        items = select_batch(a, "ask", send.materialise(run, run.asks(now)), run)
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
        items = select_batch(a, "confirm", send.materialise(run, run.confirmations(now, m_result=m_result)), run)
        refuse_send(a, "confirm", items)
        for x in items:
            print(f"===== #{x['register_no']} due {x['due_at'][:10]} -> {x['to']} S={x['S']} P={x['P']} M={x['M']}"
                  f" slot={x.get('slot') or 'confirm'}\n"
                  f"{x['text']}\n")
            if a.send:
                r = send.deliver(run, x, "confirm", a.approved_by, slot=x.get("slot"))
                print(f"===== #{x['register_no']} -> {r['state']} {r.get('why') or r.get('ref') or ''}\n")
    elif a.cmd == "resolve":
        return cmd_resolve(run, a)
    elif a.cmd == "watchdog":
        watchdog(run, a.page)
        clock_reader_watch(run, now, a.page)

    if run.errors:
        print(f"{len(run.errors)} read(s) failed; exit 2 (nothing was recorded for those rows)")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
