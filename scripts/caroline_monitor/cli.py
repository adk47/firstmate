#!/usr/bin/env python3
"""The Caroline monitor's commands. `scripts/caroline-monitor.py` is the entry point.

  tick       read Intercom (or --corpus), measure, PAGE on a regression, record the reading
  report     print the current reading from the recorded thread facts (no network)
  shapes     the fix loop's table: one row per shape, with its fix type and where the fix stands
  remeasure  did a shipped fix move its own number
  baseline   write data/caroline-monitor/baseline.json from a corpus
  drill      send one labelled test page down the real path, to prove the monitor can fire

Exit codes for `tick`: 0 measured, or blind with the health line and the page it owed
delivered; 1 a page or health line could not be delivered; 2 a register that will not load
(not a transient read failure).
"""
import argparse
import gzip
import importlib.util
import json
import os
import sqlite3
import sys
import time

from . import alerts, backlog, calibrate, collect, commitments, fixloop, metrics, rules
from .store import DEFAULT_STATE_DIR, Store

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASELINE_PATH = os.path.join(REPO_ROOT, "data", "caroline-monitor", "baseline.json")
SLACK_HELPERS = os.path.join(REPO_ROOT, "scripts", "intercom-data-complaint-watchdog.py")
DAY, HOUR = metrics.DAY, metrics.HOUR


def log(message):
    print(f"[caroline-monitor] {message}", file=sys.stderr)


def utc(ts):
    return time.strftime("%Y-%m-%d %H:%MZ", time.gmtime(ts))


def day(ts):
    return time.strftime("%m-%d", time.gmtime(ts))


# --- inputs -----------------------------------------------------------------------------------
def load_baseline(path=None):
    try:
        with open(path or BASELINE_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def load_calibration(path=None):
    """The hand-label record, or None. Only a record for the CURRENT rules counts: precision
    measured on older rules says nothing about these."""
    try:
        with open(path or CALIBRATION_PATH) as f:
            record = json.load(f)
    except (OSError, ValueError):
        return None
    return record if record.get("rules_version") == rules.RULES_VERSION else None


def read_corpus(path):
    """A collector dump: a `_meta` line, then one reduced thread per line. Plain or gzip."""
    opener = gzip.open if path.endswith(".gz") else open
    meta, threads = {}, []
    with opener(path, "rt") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if "_meta" in row:
                meta = row["_meta"]
            else:
                threads.append(row)
    return meta, threads


def who(cfg):
    return (tuple(cfg.get("non_human_admin_ids") or rules.DEFAULT_NON_HUMAN_ADMINS),
            tuple(cfg.get("staffed_team_ids") or ()))


def facts_of(threads, cfg):
    non_human, staffed = who(cfg)
    return [rules.thread_facts(t, non_human, staffed) for t in threads]


class Blind(Exception):
    """The monitor could not measure. Never the same thing as 'nothing is wrong'."""


def check_coverage(listed, total_count, errors, cfg):
    """Raise Blind unless the read covered the window: every listed thread, within tolerance."""
    if not listed:
        raise Blind("Intercom listed no conversations for the window")
    if total_count is not None and abs(listed - total_count) > max(5, 0.01 * total_count):
        raise Blind(f"listed {listed} conversations but Intercom counts {total_count}")
    share = errors / listed
    if share > cfg.get("max_read_error_share", 0.02):
        raise Blind(f"{errors} of {listed} conversations could not be read ({share:.1%})")


def keep(store, threads, register, now):
    """Store what was read about these threads: the facts, and the promises made in them."""
    non_human, staffed = who(register.get("monitor") or {})
    store.keep(((rules.thread_facts(t, non_human, staffed), t.get("contact_id") or "") for t in threads),
               register, now)


def refresh(store, register, now, token, collector=collect.collect):
    """Bring the fact store up to date: the trailing window, every open conversation of any age,
    and everything touched since the last good tick. Only threads whose `updated_at` moved (or
    that were read under another rule set) are fetched again."""
    cfg = register.get("monitor") or {}
    non_human, staffed = who(cfg)
    version = rules.reader_version(non_human, staffed)
    start = now - int(cfg.get("window_days", 37)) * DAY
    since = now - int(cfg.get("backlog_since_hours", 26)) * HOUR
    last_good = store.get("last_good_tick")
    if last_good:
        since = min(since, int(last_good) - HOUR)   # a gap in ticks must not hide what closed in it
    held = store.held(version)
    try:
        got = collector(token, start, now, skip=held, since_ts=since)
    except collect.CollectError as e:
        raise Blind(f"Intercom read failed: {e}") from e
    errors = len(got["errors"])
    check_coverage(len(got["listed"]), got.get("total_count"), errors, cfg)
    keep(store, got["threads"], register, now)
    if got["gone"]:
        store.delete_facts(got["gone"])
    store.close_unlisted(r["id"] for r in got["listed"])
    store.enqueue_due(register, now, skip=got["errors"])   # after the re-reads: a moved thread is current
    store.set("inbox", {"whole_inbox": not errors, "as_of": now, "created_since": start, "touched_since": since,
                        "listed": len(got["listed"]), "intercom_total_count": got.get("total_count"),
                        "read_errors": errors})
    covered = store.get("covered") or {}
    if covered.get("version") != version:
        covered = {"version": version, "from": start}
    covered["from"] = min(covered["from"], start)
    store.set("covered", covered)
    return {"listed": len(got["listed"]), "total_count": got.get("total_count"),
            "fetched": len(got["threads"]), "skipped": len(got.get("skipped") or ()),
            "gone": len(got["gone"]), "errors": len(got["errors"]), "window_start": start}


# --- the reading ------------------------------------------------------------------------------
def take_reading(facts, register, now, covered_from):
    cfg = register.get("monitor") or {}
    maturity = cfg.get("maturity_hours", 48)
    weeks = metrics.matured_weeks(facts, now, maturity, weeks=4,
                                  unanswered_hours=cfg.get("unanswered_hours", 24))
    covered = [covered_from is not None and covered_from <= w["window"]["start"] for w in weeks]
    last30 = metrics.measure(facts, now - 30 * DAY, now, now, None, cfg.get("unanswered_hours", 24))
    verdicts = fixloop.remeasure_all(facts, register, now, covered_from, load_calibration())
    findings = alerts.evaluate(weeks, register, verdicts, covered=covered[0] and covered[1])
    if not covered[0]:
        findings = [alerts.Finding(
            "unmeasured:window", alerts.PAGE, 0,
            "the thread facts on hand do not cover the last matured week. Nothing was compared.")]
    return {"taken_at": now, "reader_version": rules.reader_version(*who(cfg)), "weeks": weeks,
            "weeks_covered": covered, "last30": last30, "verdicts": verdicts, "findings": findings}


def compact(reading):
    """What is kept per tick: the numbers, without re-storing 30 shape rows four times over."""
    def slim(m, shapes=False):
        out = {k: m[k] for k in ("window", "threads", "outcomes", "headline", "handoff", "extra", "rates")}
        if shapes:
            out["shapes"] = {sid: {"threads": r["threads"], metrics.HEADLINE: r[metrics.HEADLINE],
                                   "answered": r["answered"]} for sid, r in m["shapes"].items()}
        return out
    return {"reader_version": reading["reader_version"],
            "weeks": [slim(w, shapes=(i == 0)) for i, w in enumerate(reading["weeks"][:2])],
            "last30": slim(reading["last30"]),
            "verdicts": reading["verdicts"],
            "findings": [f._asdict() for f in reading["findings"]]}


def _pct(part, whole):
    return f"{100.0 * part / whole:.1f}%" if whole else "n/a"


def render_report(reading, register, baseline=None):
    weeks, last30 = reading["weeks"], reading["last30"]
    cur = weeks[0]
    lines = [f"Caroline monitor: reading as of {utc(reading['taken_at'])} (reader {reading['reader_version']})", ""]
    base = (baseline or {}).get("matured_weeks") or []
    base_text = f"; baseline {base[0]['headline']}" if base else ""
    lines.append("HEADLINE  hand-offs with nobody assigned, per matured week "
                 f"(each thread read {cur['window']['maturity_hours']}h after it opened){base_text}")
    for w, ok in zip(weeks, reading["weeks_covered"]):
        span = f"{day(w['window']['start'])}..{day(w['window']['end'])}"
        if not ok:
            lines.append(f"  {span}   not measured (the thread facts do not reach this week)")
            continue
        lines.append(f"  {span}   {w['headline']:>5}  of {w['threads']:>5} threads  ({_pct(w['headline'], w['threads'])})")
    lines += ["", f"SUPPORTING, last matured week ({cur['threads']} threads) and the week before"]
    prev = weeks[1] if reading["weeks_covered"][1] else None

    def row(label, get, rate=True):
        a = get(cur)
        text = f"  {label:<46} {a:>5}"
        if rate:
            text += f"  {_pct(a, cur['threads']):>6}"
        if prev:
            b = get(prev)
            text += f"   was {b:>5}" + (f"  {_pct(b, prev['threads']):>6}" if rate else "")
        lines.append(text)
    row("hand-off (she said a person is coming)", lambda m: m["handoff"])
    row("  with nobody assigned  [headline]", lambda m: m["headline"])
    row("  and assigned to a person", lambda m: m["outcomes"]["handoff_assigned"])
    row("  assigned, no human reply yet", lambda m: m["extra"]["handoff_assigned_no_human_reply"])
    row("assigned to a person (any)", lambda m: m["extra"]["assigned"])
    row("  of those, after the output guard fired", lambda m: m["extra"]["guard_assigned"])
    row("output guard fired, nobody assigned", lambda m: m["extra"]["guard_blocked"] - m["extra"]["guard_assigned"])
    row("a human replied", lambda m: m["extra"]["human_reply"])
    row("queue line, no person and no state", lambda m: m["outcomes"]["queue_line"])
    row("resolved without a hand-off", lambda m: m["outcomes"]["answered"])
    row("answered, customer's last message open", lambda m: m["outcomes"]["answered_awaiting"])
    row("refused with a reason and a way back", lambda m: m["outcomes"]["refused"])
    row("no reply at all (any age)", lambda m: m["outcomes"]["never_answered"])
    row(f"no reply at all after {cur['window']['unanswered_hours']}h (robots excluded)",
        lambda m: m["extra"]["never_answered_over_n_hours"])
    row("date or day-count promise", lambda m: m["extra"]["date_promise"])
    row("we opened it, customer has not written", lambda m: m["outcomes"]["no_customer_message"])
    lines += ["", f"LAST 30 DAYS AS OF NOW ({last30['threads']} threads; comparable with the intent-mining report)",
              f"  hand-off with nobody assigned {last30['headline']} ({_pct(last30['headline'], last30['threads'])}); "
              f"counting queue lines as hand-offs too: {last30['extra']['handoff_no_assignment_broad']}",
              f"  assigned to a person {last30['extra']['assigned']} ({_pct(last30['extra']['assigned'], last30['threads'])}); "
              f"a human replied {last30['extra']['human_reply']} ({_pct(last30['extra']['human_reply'], last30['threads'])}); "
              f"resolved without a hand-off {last30['outcomes']['answered']} "
              f"({_pct(last30['outcomes']['answered'], last30['threads'])})",
              f"  customer chased a day or more after the promise: {last30['extra']['chased_after_promise']}"]
    lines += ["", "FINDINGS"]
    if not reading["findings"]:
        lines.append("  none")
    for f in reading["findings"]:
        lines.append(f"  [{f.severity}] {f.key}: {f.text}")
    return "\n".join(lines)


def render_shapes(reading, register):
    weeks = reading["weeks"]
    prev = weeks[1] if reading["weeks_covered"][1] else None
    table = fixloop.shape_table(register, weeks[0], prev, load_calibration())
    cur = weeks[0]
    lines = [f"Fix loop: shapes, last matured week {day(cur['window']['start'])}..{day(cur['window']['end'])} "
             f"({cur['threads']} threads, {cur['headline']} handed off with nobody assigned)", "",
             f"  {'shape':<26}{'threads':>8}{'no-assign':>10}{'was':>6}{'rate':>7}{'resolved':>9}{'rule ok':>9}"
             "  fix      status       owner"]
    for r in table:
        if not r["threads"] and not r["headline_prev"]:
            continue
        was = "" if r["headline_prev"] is None else str(r["headline_prev"])
        rate = "" if r["headline_rate"] is None else f"{r['headline_rate']:.0%}"
        ok = "?" if r["precision"] is None else f"{r['precision']:.0%}"
        lines.append(f"  {r['shape']:<26}{r['threads']:>8}{r['headline']:>10}{was:>6}{rate:>7}{r['resolved']:>9}{ok:>9}"
                     f"  {r['fix_type'] or '?':<8} {r['status'] or '?':<12} {r['owner'] or '-'}")
    lines += ["", "  rule ok = how often the rules picked that shape correctly, by hand labels "
                  "(data/caroline-monitor/calibration.json). ? = not labelled for these rules."]
    share = fixloop.residual_share(cur)
    if share is not None:
        lines += ["", f"  fits no named shape: {share:.0%} of threads (pages above "
                      f"{alerts.thresholds(register)['residual_share_max']:.0%})"]
    lines += ["", "Shipped fixes, re-measured"]
    if not reading["verdicts"]:
        lines.append("  none shipped yet")
    for v in reading["verdicts"]:
        lines.append("  " + render_verdict(v))
    return "\n".join(lines)


def render_verdict(v):
    name = fixloop.verdict_name(v)
    text = f"{name} [{v['metric']}], shipped {v['shipped_at']}: {v['verdict'].upper()}"
    if "before" in v:
        b, a = v["before"], v["after"]
        text += (f". Before {b['count']} of {b['threads']} threads ({_rate(b['rate'])}), "
                 f"after {a['count']} of {a['threads']} ({_rate(a['rate'])})")
    if "control_before" in v:
        text += (f"; every other shape {_rate(v['control_before']['rate'])} to "
                 f"{_rate(v['control_after']['rate'])}")
    if v.get("reason"):
        text += f" ({v['reason']})"
    if v.get("ready_at"):
        text += f" (measurable from {utc(v['ready_at'])})"
    if v.get("note"):
        text += f" ({v['note']})"
    return text


def _rate(value):
    return "n/a" if value is None else f"{100 * value:.1f}%"


# --- Slack ------------------------------------------------------------------------------------
def slack_helpers():
    """The fleet's one Slack poster (token resolution, escaping, ok-or-raise)."""
    spec = importlib.util.spec_from_file_location("intercom_data_complaint_watchdog", SLACK_HELPERS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def slack_target(cfg):
    slack = cfg.get("slack") or {}
    channel = os.environ.get("CAROLINE_MONITOR_SLACK_CHANNEL") or slack.get("channel")
    raw = os.environ.get("CAROLINE_MONITOR_MENTION_IDS")
    mentions = [m.strip() for m in raw.split(",")] if raw is not None else list(slack.get("mention_ids") or [])
    return channel, [m for m in mentions if m]


def post(cfg, text, poster=None, channel=None):
    """Send or raise. A caller stamps a page as sent only after this returns."""
    channel = channel or slack_target(cfg)[0]
    if not channel:
        raise RuntimeError("no Slack channel configured")
    if poster is not None:
        return poster(channel, text)
    helpers = slack_helpers()
    return helpers.slack_post(helpers.resolve_slack_token(), channel, text)


def health_channel(cfg):
    """Where the one line per run goes, or '' when it is switched off. Defaults to the page channel."""
    slack = cfg.get("slack") or {}
    if not slack.get("health_line", True):
        return ""
    return (os.environ.get("CAROLINE_MONITOR_HEALTH_CHANNEL") or slack.get("health_channel")
            or slack_target(cfg)[0] or "")


def post_health(cfg, text, args, poster):
    """Print the line always; post it unless this is a dry run. Returns False when the post failed:
    a run nobody heard about is a failed run."""
    print("\n" + text)
    channel = health_channel(cfg)
    if args.dry_run or not channel:
        return True
    try:
        post(cfg, text, poster, channel=channel)
    except Exception as e:  # noqa: BLE001
        log(f"health line not delivered: {e}")
        return False
    return True


def weekly_due(store, cfg, now):
    slack = cfg.get("slack") or {}
    t = time.gmtime(now)
    week = time.strftime("%G-W%V", t)
    if store.get("weekly_posted") == week:
        return None
    if (t.tm_wday, t.tm_hour) < (slack.get("weekly_post_weekday_utc", 0), slack.get("weekly_post_hour_utc", 8)):
        return None
    return week


# --- commands ---------------------------------------------------------------------------------
def _open_store(args, in_memory_ok=False):
    if in_memory_ok and (getattr(args, "dry_run", False)
                         or (getattr(args, "corpus", None) and not args.state_dir)):
        return Store(":memory:")
    return Store.open_default(args.state_dir)


def _load(args):
    register = fixloop.load_register(args.register)
    errors = fixloop.validate(register)
    if errors:
        raise fixloop.RegisterError("the shape register is invalid: " + "; ".join(errors[:5]))
    return register


def _facts_and_cover(args, store, register, now, token=None, collector=collect.collect):
    """(facts under the current reader version, covered_from, how they were obtained)."""
    cfg = register.get("monitor") or {}
    version = rules.reader_version(*who(cfg))
    if getattr(args, "corpus", None):
        meta, threads = read_corpus(args.corpus)
        errors = meta.get("errors", 0)
        check_coverage(meta.get("listed", len(threads)), meta.get("total_count"), errors, cfg)
        keep(store, threads, register, now)
        store.set("covered", {"version": version, "from": int(meta.get("start") or 0)})
        store.set("inbox", {"whole_inbox": bool(meta.get("backlog")) and not errors, "as_of": now,
                            "created_since": int(meta.get("start") or 0), "listed": meta.get("listed"),
                            "intercom_total_count": meta.get("total_count"), "read_errors": errors})
        how = {"corpus": os.path.basename(args.corpus), "threads": len(threads)}
    elif getattr(args, "offline", False):
        how = {"offline": True}
    else:
        how = refresh(store, register, now, token or collect.resolve_token(), collector)
    covered = store.get("covered") or {}
    covered_from = covered.get("from") if covered.get("version") == version else None
    return store.facts(rules_version=version), covered_from, how


def inbox_reading(store, facts, register, now, reading):
    """The support instrument's content for this reading (backlog.py)."""
    scope = store.get("inbox") or {"whole_inbox": False}
    week = reading["weeks"][0] if reading["weeks_covered"][0] else None
    outbox = commitments.outbox_counts(store.db) if scope.get("whole_inbox") else None
    return backlog.build(facts, register, now, scope, week, outbox)


def day_before(store, now):
    """The inbox reading from about a day ago, to compare with. None when there is none."""
    for taken_at, doc in store.readings("backlog", limit=40):
        if 20 * HOUR <= now - taken_at <= 48 * HOUR and (doc.get("scope") or {}).get("whole_inbox"):
            return doc
    return None


def _now(args):
    if getattr(args, "now", None):
        return int(args.now)
    if getattr(args, "corpus", None):
        meta, _ = read_corpus(args.corpus)
        if meta.get("end"):
            return int(meta["end"])
    return int(time.time())


def cmd_tick(args, poster=None, collector=collect.collect, token=None):
    now = _now(args)
    store = _open_store(args, in_memory_ok=True)
    cfg = {}
    try:
        register = _load(args)
        cfg = register.get("monitor") or {}
        facts, covered_from, how = _facts_and_cover(args, store, register, now, token, collector)
    except fixloop.RegisterError as e:
        return _blind(store, cfg, now, str(e), args, poster, fatal=True)
    except (Blind, collect.CollectError) as e:
        return _blind(store, cfg, now, str(e), args, poster)
    store.set("blind_ticks", 0)
    reading = take_reading(facts, register, now, covered_from)
    t = alerts.thresholds(register)
    inbox = inbox_reading(store, facts, register, now, reading)
    reading["findings"] = reading["findings"] + alerts.evaluate_inbox(inbox, day_before(store, now), t)
    paging = [f for f in reading["findings"] if f.severity == alerts.PAGE]
    send = alerts.due(paging, store.last_page, now, t)
    log(f"read: {json.dumps(how, sort_keys=True)}")
    print(render_report(reading, register, load_baseline(args.baseline)))
    print("\n" + backlog.render(inbox))
    rc = 0
    if args.dry_run:
        if send:
            print("\nWOULD PAGE:\n" + alerts.render_page(send, reading["weeks"], slack_target(cfg)[1]))
        post_health(cfg, alerts.render_health(utc(now), how, reading, inbox, len(paging), len(send)), args, poster)
        return rc
    store.add_reading(now, "tick", compact(reading))
    store.add_reading(now, "backlog", inbox)
    # The instrument file is written by a real read of the inbox, or to a path asked for by name.
    # A corpus replay never overwrites the live file.
    out = getattr(args, "backlog_out", None) or (None if getattr(args, "corpus", None) else backlog.DEFAULT_PATH)
    if out:
        try:
            backlog.write(inbox, out)
        except OSError as e:
            log(f"SUPPORT BACKLOG FILE NOT WRITTEN ({out}): {e}")
            rc = 1
    if not getattr(args, "corpus", None):
        store.set("last_good_tick", now)
    store.clear_pages_except([f.key for f in paging])
    page_failed = False
    if send:
        try:
            post(cfg, alerts.render_page(send, reading["weeks"], slack_target(cfg)[1]), poster)
        except Exception as e:  # noqa: BLE001 - any delivery failure is the same outcome
            log(f"PAGE NOT DELIVERED ({len(send)} findings): {e}")
            rc = 1
            page_failed = True
        else:
            for f in send:
                store.stamp_page(f.key, f.value, now)
            log(f"paged {len(send)} finding(s): " + ", ".join(f.key for f in send))
    week = weekly_due(store, cfg, now)
    if week and reading["weeks_covered"][0]:
        base = load_baseline(args.baseline)
        base_week = ((base or {}).get("matured_weeks") or [{}])[0].get("headline")
        weeks = reading["weeks"] if reading["weeks_covered"][1] else reading["weeks"][:1]
        try:
            post(cfg, alerts.render_weekly(weeks, base_week), poster)
        except Exception as e:  # noqa: BLE001
            log(f"weekly line not delivered: {e}")
            rc = rc or 1
        else:
            store.set("weekly_posted", week)
    health = alerts.render_health(utc(now), how, reading, inbox, len(paging), len(send), page_failed)
    if not post_health(cfg, health, args, poster):
        rc = rc or 1
    retention = int(cfg.get("retention_days", 180))
    pruned = store.prune_facts(now - retention * DAY)
    if pruned:
        log(f"pruned {pruned} thread facts older than {retention} days")
    return rc


def _blind(store, cfg, now, reason, args, poster, fatal=False):
    """Could not measure. Recorded every time, and paged once it has happened
    `blind_ticks_to_page` times in a row: one failed read is a blip, two is a monitor nobody is
    being told is down. Below the threshold the run is a success (exit 0) unless the health line
    itself could not be delivered; `fatal` is a register that will not load, which fails loud at
    once. `--dry-run` prints NOT MEASURED and records nothing."""
    log(f"BLIND: {reason}")
    print(f"NOT MEASURED: {reason}")
    count = int(store.get("blind_ticks") or 0) + 1
    # A register that will not load is one of the ways to be blind, so neither the page nor the
    # health line can depend on it for its own address.
    target = cfg if (cfg.get("slack") or {}).get("channel") else alerts.FALLBACK_TARGET
    delivered = post_health(target, alerts.render_health_blind(utc(now), reason, count), args, poster)
    if args.dry_run:
        return 0
    store.set("blind_ticks", count)
    store.add_reading(now, "blind", {"reason": reason, "consecutive": count})
    rc = 0 if delivered else 1
    if fatal:
        return rc or 2
    if count >= int(cfg.get("blind_ticks_to_page", 2)):
        finding = alerts.Finding(
            "unmeasured:blind", alerts.PAGE, count,
            f"the monitor could not measure for {count} ticks in a row: {reason}. "
            "No number below is current; nothing is known to be fine.")
        t = dict(alerts.DEFAULT_PAGE)
        t.update(cfg.get("page") or {})
        if alerts.due([finding], store.last_page, now, t):
            mentions = " ".join(f"<@{m}>" for m in slack_target(target)[1])
            try:
                post(target, f":rotating_light: *Caroline monitor is BLIND* {mentions}\n• {finding.text}", poster)
            except Exception as e:  # noqa: BLE001
                log(f"blind page not delivered: {e}")
                rc = 1
            else:
                store.stamp_page(finding.key, count, now)
    return rc


def _offline_reading(args):
    now = _now(args)
    store = _open_store(args, in_memory_ok=True)
    register = _load(args)
    if not getattr(args, "corpus", None):
        args.offline = True
    facts, covered_from, _ = _facts_and_cover(args, store, register, now)
    reading = take_reading(facts, register, now, covered_from)
    reading["inbox"] = inbox_reading(store, facts, register, now, reading)
    return reading, register


def cmd_report(args):
    reading, register = _offline_reading(args)
    if args.json:
        out = compact(reading)
        out["taken_at"] = reading["taken_at"]
        out["inbox"] = reading["inbox"]
        print(json.dumps(out, indent=1, sort_keys=True))
    else:
        print(render_report(reading, register, load_baseline(args.baseline)))
        print("\n" + backlog.render(reading["inbox"]))
    return 0


def cmd_shapes(args):
    reading, register = _offline_reading(args)
    if args.json:
        prev = reading["weeks"][1] if reading["weeks_covered"][1] else None
        print(json.dumps({"taken_at": reading["taken_at"],
                          "shapes": fixloop.shape_table(register, reading["weeks"][0], prev, load_calibration()),
                          "verdicts": reading["verdicts"]}, indent=1))
    else:
        print(render_shapes(reading, register))
    return 0


def cmd_remeasure(args):
    reading, register = _offline_reading(args)
    verdicts = [v for v in reading["verdicts"] if not args.name or fixloop.verdict_name(v) == args.name]
    if args.name and not verdicts:
        print(f"{args.name}: not shipped (no `shipped_at` on its register row), so there is nothing to re-measure")
        return 0
    if args.json:
        print(json.dumps(verdicts, indent=1))
    else:
        for v in verdicts:
            print(render_verdict(v))
        if not verdicts:
            print("none shipped yet")
    return 0


def _source(meta, read):
    return {"window_start": meta.get("start"), "window_end": meta.get("end"),
            "listed": meta.get("listed"), "intercom_total_count": meta.get("total_count"),
            "read": read, "gone": meta.get("gone"), "errors": meta.get("errors")}


def _inbox_block(threads, meta, register, now):
    """The support-backlog.json content for ONE read: every field of the block is as of `now`."""
    cfg = register.get("monitor") or {}
    facts = facts_of(threads, cfg)
    reading = take_reading(facts, register, now, int(meta.get("start") or 0))
    scope = {"whole_inbox": bool(meta.get("backlog")) and not meta.get("errors"), "as_of": now,
             "created_since": int(meta.get("start") or 0), "listed": meta.get("listed"),
             "intercom_total_count": meta.get("total_count"), "read_errors": meta.get("errors")}
    week = reading["weeks"][0] if reading["weeks_covered"][0] else None
    return backlog.build(facts, register, now, scope, week)


def build_baseline(threads, meta, register, now, inbox_read=None):
    """`inbox_read` is an optional (meta, threads) pair from a SEPARATE read of the inbox. The open
    and waiting counts of the inbox block describe the moment the inbox was read, which cannot be
    replayed: when the headline is rebuilt for an earlier `now`, the block is built whole from that
    one read, as of that read's own cut-off (`_meta.end`), and the moment is recorded in
    `inbox_read_at`. Without it the block is built from the same corpus at `now`."""
    cfg = register.get("monitor") or {}
    facts = facts_of(threads, cfg)
    reading = take_reading(facts, register, now, int(meta.get("start") or 0))
    last30 = reading["last30"]
    matured = [w for w, ok in zip(reading["weeks"], reading["weeks_covered"]) if ok]
    if inbox_read is None:
        inbox_meta, inbox_threads, inbox_now = meta, threads, now
    else:
        inbox_meta, inbox_threads = inbox_read
        inbox_now = int(inbox_meta["end"])
    return {
        "_doc": "The monitor's recorded starting point. Written by `caroline-monitor.py baseline` from a full "
                "read of the window; never edited by hand. Counts only: no thread text and no thread ids. "
                "`inbox` is the support-backlog.json content of ONE read of the inbox, every field as of "
                "`inbox_read_at` (null fields when the read did not cover every open conversation); "
                "`inbox_source` is that read. Everything else is as of `taken_at`, from `source`.",
        "inbox": _inbox_block(inbox_threads, inbox_meta, register, inbox_now),
        "inbox_read_at": inbox_now,
        "inbox_read_at_utc": utc(inbox_now),
        "inbox_source": _source(inbox_meta, len(inbox_threads)),
        "taken_at": now,
        "taken_at_utc": utc(now),
        "rules_version": rules.RULES_VERSION,
        "reader_version": reading["reader_version"],
        "covered_from": int(meta.get("start") or 0),
        "source": _source(meta, len(threads)),
        "matured_weeks": matured,
        "last30_as_of_now": last30,
        "shape_threads": {sid: row["threads"] for sid, row in last30["shapes"].items()},
        "verdicts": reading["verdicts"],
    }


def cmd_baseline(args):
    register = _load(args)
    meta, threads = read_corpus(args.corpus)
    cfg = register.get("monitor") or {}
    check_coverage(meta.get("listed", len(threads)), meta.get("total_count"), meta.get("errors", 0), cfg)
    now = _now(args)
    reading = take_reading(facts_of(threads, cfg), register, now, int(meta.get("start") or 0))
    matured = [w for w, ok in zip(reading["weeks"], reading["weeks_covered"]) if ok]
    if not matured:
        start = int(meta.get("start") or 0)
        need = int(cfg.get("maturity_hours", 48))
        print(f"refusing to write {args.out}: the corpus covers {utc(start)}..{utc(now) if start else 'nothing'} "
              f"and no matured week; a matured week is the 7 days ending {need}h before the reading "
              f"({utc(now - need * HOUR)}), and the corpus must start before that. No file was written.",
              file=sys.stderr)
        return 2
    inbox_read = None
    if getattr(args, "inbox_corpus", None):
        inbox_meta, inbox_threads = read_corpus(args.inbox_corpus)
        check_coverage(inbox_meta.get("listed", len(inbox_threads)), inbox_meta.get("total_count"),
                       inbox_meta.get("errors", 0), cfg)
        if not inbox_meta.get("end") or not inbox_meta.get("backlog"):
            print(f"refusing to write {args.out}: {args.inbox_corpus} is not a whole-inbox read with a recorded "
                  "cut-off (collect with --backlog), so the inbox block would have no single read time. "
                  "No file was written.", file=sys.stderr)
            return 2
        inbox_read = (inbox_meta, inbox_threads)
    baseline = build_baseline(threads, meta, register, now, inbox_read)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(baseline, f, indent=1, sort_keys=True)
        f.write("\n")
    week = baseline["matured_weeks"][0]
    print(f"baseline written to {args.out}: {week['headline']} hand-offs with nobody assigned in the last "
          f"matured week ({week['threads']} threads); {baseline['last30_as_of_now']['headline']} in 30 days")
    print("\n" + backlog.render(baseline["inbox"]))
    return 0


def cmd_drill(args, poster=None):
    """One labelled page down the real path. It proves token, channel, mention and rendering;
    it stamps nothing, so it can never suppress a real page."""
    reading, register = _offline_reading(args)
    cfg = register.get("monitor") or {}
    finding = alerts.Finding(
        "drill", alerts.PAGE, 0,
        "This is a test of the page path, sent on purpose. The numbers above are the real current reading.")
    text = alerts.render_page([finding], reading["weeks"], slack_target(cfg)[1], drill=True)
    if args.dry_run:
        print(text)
        return 0
    try:
        post(cfg, text, poster)
    except Exception as e:  # noqa: BLE001
        log(f"DRILL FAILED, the monitor cannot page: {e}")
        return 1
    log("drill delivered")
    return 0


CALIBRATION_PATH = os.path.join(REPO_ROOT, "data", "caroline-monitor", "calibration.json")


def cmd_calibrate(args):
    """sample: write the blind labelling sheets (scratch, masked text). score: turn the labels
    into data/caroline-monitor/calibration.json (counts only)."""
    def path(name):
        return os.path.join(args.dir, name)
    if args.action == "sample":
        register = _load(args)
        cfg = register.get("monitor") or {}
        meta, threads = read_corpus(args.corpus)
        now = _now(args)
        start = now - 30 * DAY
        cohort = [t for t in threads if start <= int(t.get("created_at") or 0) < now]
        os.makedirs(args.dir, exist_ok=True)
        sheet, key, populations = calibrate.sample_shapes(cohort, args.seed)
        calibrate.write_jsonl(path("shapes.sheet.jsonl"), sheet)
        with open(path("shapes.key.json"), "w") as f:
            json.dump({"key": key, "populations": populations}, f)
        o_seed = args.outcome_seed if args.outcome_seed is not None else args.seed
        o_sheet, o_key, o_pop = calibrate.sample_outcomes(cohort, facts_of(cohort, cfg), o_seed, now)
        calibrate.write_jsonl(path("outcomes.sheet.jsonl"), o_sheet)
        with open(path("outcomes.key.json"), "w") as f:
            json.dump({"key": o_key, "populations": o_pop, "seed": args.seed, "outcome_seed": o_seed,
                       "window": {"start": start, "end": now, "threads": len(cohort)}}, f)
        print(f"{len(sheet)} asks to label in {path('shapes.sheet.jsonl')} -> shapes.labels.txt; "
              f"{len(o_sheet)} outcomes in {path('outcomes.sheet.jsonl')} -> outcomes.labels.txt")
        return 0
    with open(path("shapes.key.json")) as f:
        shapes = json.load(f)
    with open(path("outcomes.key.json")) as f:
        outcomes = json.load(f)
    record = calibrate.calibration_record(
        calibrate.score_shapes(shapes["key"], calibrate.read_labels(path("shapes.labels.txt")), shapes["populations"]),
        calibrate.score_outcomes(outcomes["key"], calibrate.read_labels(path("outcomes.labels.txt")),
                                 outcomes["populations"]),
        {"shapes": outcomes["seed"], "outcomes": outcomes.get("outcome_seed", outcomes["seed"])},
        outcomes["window"], args.rater)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(record, f, indent=1, sort_keys=True)
        f.write("\n")
    c, o = record["classifier"], record["outcome_reader"]
    print(f"calibration written to {args.out}: {c['labelled']} asks labelled, weighted accuracy "
          f"{c['weighted_accuracy']}; headline precision {o['headline']['precision']} "
          f"({o['headline']['labelled']} labelled), missed promises {o['no_handoff']['missed_promises']} "
          f"of {o['no_handoff']['labelled']}")
    return 0


def build_parser():
    p = argparse.ArgumentParser(prog="caroline-monitor.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--register", default=None, help="shape register (default policies/caroline-shapes.json)")
    p.add_argument("--state-dir", default=None, help=f"state directory (default {DEFAULT_STATE_DIR})")
    p.add_argument("--baseline", default=None, help="baseline file (default data/caroline-monitor/baseline.json)")
    sub = p.add_subparsers(dest="command", required=True)

    def common(sp, corpus=True):
        if corpus:
            sp.add_argument("--corpus", help="measure a collector dump instead of the live store or Intercom")
        sp.add_argument("--now", type=int, help="epoch seconds to read as of (default: now, or the corpus end)")
        return sp
    t = common(sub.add_parser("tick", help="read, measure, page, record"))
    t.add_argument("--dry-run", action="store_true", help="measure and print; post and record nothing")
    t.add_argument("--backlog-out", default=None,
                   help=f"where to write the support instrument file (default {backlog.DEFAULT_PATH}; "
                        "a --corpus run writes it only when this is given)")
    r = common(sub.add_parser("report", help="print the current reading (no network)"))
    r.add_argument("--json", action="store_true")
    s = common(sub.add_parser("shapes", help="the fix loop's table, one row per shape"))
    s.add_argument("--json", action="store_true")
    m = common(sub.add_parser("remeasure", help="did a shipped fix move its own number"))
    m.add_argument("name", nargs="?", help="a shape id, a global fix or an exemption (default: all shipped)")
    m.add_argument("--json", action="store_true")
    b = sub.add_parser("baseline", help="write the baseline from a corpus")
    b.add_argument("--corpus", required=True)
    b.add_argument("--now", type=int)
    b.add_argument("--inbox-corpus", default=None,
                   help="a separate whole-inbox read (collect --backlog): the inbox block is built from it alone, "
                        "as of its own cut-off, and that moment is recorded as inbox_read_at")
    b.add_argument("--out", default=BASELINE_PATH)
    d = common(sub.add_parser("drill", help="send one labelled test page"))
    d.add_argument("--dry-run", action="store_true")
    c = sub.add_parser("calibrate", help="hand-label calibration: sample sheets, then score the labels")
    c.add_argument("action", choices=("sample", "score"))
    c.add_argument("--corpus")
    c.add_argument("--now", type=int)
    c.add_argument("--dir", required=True, help="scratch directory for sheets, keys and labels (never committed)")
    c.add_argument("--seed", type=int, default=20261111)
    c.add_argument("--outcome-seed", type=int, default=None,
                   help="a separate seed for the outcome sample (a fresh draw after a pattern change)")
    c.add_argument("--out", default=CALIBRATION_PATH)
    c.add_argument("--rater", default="one rater, blind to the predicted shape")
    return p


COMMANDS = {"tick": cmd_tick, "report": cmd_report, "shapes": cmd_shapes, "remeasure": cmd_remeasure,
            "baseline": cmd_baseline, "drill": cmd_drill, "calibrate": cmd_calibrate}


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return COMMANDS[args.command](args)
    except (Blind, fixloop.RegisterError, collect.CollectError, OSError, sqlite3.Error) as e:
        print(f"NOT MEASURED: {e}", file=sys.stderr)
        return 2
