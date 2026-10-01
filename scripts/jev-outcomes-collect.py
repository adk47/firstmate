#!/usr/bin/env python3
# ──────────────────────────────────────────────────────────────
# jev-outcomes-collect.py — read-only collector: derives per-turn ground
# truth (today: first_tool) from the openclaw trajectory store and writes it
# to a sidecar JSONL next to the Jev shadow log, so jev-shadow-report.sh can
# eventually compare Jev's answer to what actually happened instead of to
# Jev's own router action (scripts/jev-shadow-report.sh:250's bug).
#
# Never writes to node-8 state: the trajectory SQLite is opened read-only
# (mode=ro URI) and the shadow log is only ever read. The only write this
# script performs is its own --out sidecar file, atomically.
#
# Usage:
#   jev-outcomes-collect.py [--shadow-file PATH] [--out PATH] \
#     [--since-hours N] [--inventory PATH] [--trajectory-db PATH] \
#     [--json-summary]
#
# Turn grouping and the ground-truth sidecar format are the shared contract
# for every child of MUS-1481 -- see that card for the authoritative JSON
# shape. Summary: a turn is a run of one item_id's shadow rows whose
# timestamps are each within 5.0s of the next; a turn's window is
# [turn_start, next_turn_start), or [turn_start, turn_start+72h) for the
# last turn of a conversation.
#
# first_tool is the name of the FIRST trajectory tool.call event inside that
# window whose tool name is in caroline-inventory.json's allowlist (minus
# BUILTIN_EXCLUDE), or the literal "none" if the conversation IS present in
# the trajectory store but no such call fell in the window -- including a
# conversation with zero tool.call rows, as long as it has ANY row in the
# store. If the conversation is ABSENT FROM THE STORE ENTIRELY (no rows at
# all), first_tool is OMITTED from truth (never "none") and
# evidence.trajectory_seen is false -- conflating "we never looked" with
# "nothing happened" would manufacture agreement against Jev's single most
# common answer.
# ──────────────────────────────────────────────────────────────
import argparse
import datetime
import json
import os
import sqlite3
import sys
import tempfile

SESSIONKEY_CONV_PREFIX = "agent:support:intercom:direct:"

# Same exclusion set and reasoning as scripts/jev-backtest-caroline.sh:222 --
# support_action_router and the openclaw built-ins fire on nearly every turn
# and are not a resolution signal.
BUILTIN_EXCLUDE = {"read", "memory_search", "memory_get", "support_action_router"}

TURN_GAP_SECONDS = 5.0
LAST_TURN_WINDOW = datetime.timedelta(hours=72)

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SHADOW_FILE = "/var/lib/hydra-jev/shadow/caroline.jsonl"
DEFAULT_OUT = "/var/lib/hydra-jev/shadow/caroline.outcomes.jsonl"
DEFAULT_INVENTORY = os.path.join(_REPO_ROOT, "plugins", "intercom", "src", "caroline-inventory.json")
DEFAULT_TRAJECTORY_DB = "/root/.openclaw-edge/agents/support/agent/openclaw-agent.sqlite"

_TS_FORMATS = ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ")


def parse_ts(ts):
    """ISO8601-Z string -> aware UTC datetime, or None if unparseable."""
    if not ts:
        return None
    s = str(ts).strip()
    for fmt in _TS_FORMATS:
        try:
            return datetime.datetime.strptime(s, fmt).replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            continue
    return None


def format_ts(dt):
    dt = dt.astimezone(datetime.timezone.utc)
    if dt.microsecond:
        return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (dt.microsecond // 1000)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def sessionkey_conv(session_key):
    if session_key and session_key.startswith(SESSIONKEY_CONV_PREFIX):
        return session_key[len(SESSIONKEY_CONV_PREFIX):]
    return None


def load_allowed_tool_names(path):
    """caroline-inventory.json's .tools[].name minus BUILTIN_EXCLUDE. Raises
    OSError/ValueError on an unreadable or malformed inventory file, AND on
    an empty result -- callers must fail loud, never fall back to an
    unfiltered OR an empty set. A WARN-only empty result (e.g. a
    generator-side rename of the "tools" key) still lets the collector run
    to completion and label EVERY trajectory-seen turn "none", exit 0, and
    atomically overwrite a good sidecar with fabricated ground truth
    (GitHub Muso QA Bot, MUS-1541 round 9). Raising here means main()'s
    existing `except ValueError: return 3` stops that before write_atomic
    is ever called, so the prior sidecar survives untouched."""
    with open(path, "r", encoding="utf-8") as fh:
        inv = json.load(fh)
    names = {t.get("name") for t in (inv.get("tools") or [])
             if isinstance(t, dict) and t.get("name")}
    names -= BUILTIN_EXCLUDE
    if not names:
        raise ValueError(
            "%s yielded zero valid support-tool names after excluding built-ins" % path)
    return names


def ingest_record(rec, per_conv):
    """Mutates per_conv: conv_id -> [{"ts": epoch_seconds, "name": str}, ...].
    Returns True if rec was a countable tool.call event."""
    if not isinstance(rec, dict) or rec.get("type") != "tool.call":
        return False
    data = rec.get("data") or {}
    name = data.get("name")
    if not name:
        return False
    conv = sessionkey_conv(rec.get("sessionKey"))
    if not conv:
        return False
    dt = parse_ts(rec.get("ts"))
    ts_epoch = dt.timestamp() if dt is not None else 0.0
    per_conv.setdefault(conv, []).append({"ts": ts_epoch, "name": name})
    return True


def sweep_sqlite(db_paths):
    """Mirrors scripts/jev-backtest-caroline.sh:371-393's sweep_sqlite for the
    tool.call collection (read-only URI, tolerant of a missing/locked/
    tableless store -- skip, never fatal), but ALSO returns conversations_seen:
    the set of conv_ids with ANY event in the store, from an unfiltered full
    scan -- never derived from per_conv. A conversation that genuinely made
    no tool call still has message/model rows in the store; gating
    trajectory_seen on "has a tool.call" rather than "is present at all"
    silently drops every such turn from the labeled set instead of correctly
    labeling it first_tool="none" (QA round 6, MUS-1541 NO-GO on 9038aad)."""
    per_conv = {}
    conversations_seen = set()
    for db_path in db_paths:
        try:
            con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
        except sqlite3.Error:
            continue
        try:
            rows = con.execute(
                "select event_json from trajectory_runtime_events order by session_id, seq")
            for (event_json,) in rows:
                try:
                    rec = json.loads(event_json)
                except (ValueError, TypeError):
                    continue
                if isinstance(rec, dict):
                    conv = sessionkey_conv(rec.get("sessionKey"))
                    if conv:
                        conversations_seen.add(conv)
                ingest_record(rec, per_conv)
        except sqlite3.Error:
            continue
        finally:
            con.close()
    return per_conv, conversations_seen


def load_shadow_rows(path):
    """Validated (surface, item_id, ts) rows from the shadow JSONL. A row
    with no usable surface/item_id/ts is dropped -- it can be neither turn-
    grouped nor joined back by the report, so it is not evidence.

    Deliberately does NOT take a since-hours cutoff: filtering rows here,
    before turn grouping, can drop only one row of a turn (the shadow log
    writes a v1+v2 pair ~2s apart for the same turn) and leave the other,
    so build_turns silently starts the turn at the wrong row and a tool
    call before the survivor's ts falls out of its own window -- a turn
    that existed gets a fabricated turn_start and a wrong first_tool
    instead of being cleanly included or excluded. See filter_turns_since,
    which drops whole turns by turn_start AFTER grouping instead."""
    rows = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if not isinstance(row, dict):
                continue
            surface = row.get("surface")
            item_id = row.get("item_id")
            ts = row.get("ts")
            if not isinstance(surface, str) or not surface:
                continue
            if not isinstance(item_id, str) or not item_id:
                continue
            dt = parse_ts(ts)
            if dt is None:
                continue
            rows.append({"surface": surface, "item_id": item_id, "ts": ts, "ts_dt": dt})
    return rows


def filter_turns_since(turns, cutoff_dt):
    """Drops whole turns whose turn_start precedes cutoff_dt. Must run AFTER
    build_turns, never before -- see load_shadow_rows's docstring for why
    row-level filtering corrupts the turn it cuts through."""
    if cutoff_dt is None:
        return turns
    return [t for t in turns if t["turn_start_dt"] >= cutoff_dt]


def build_turns(rows):
    """Groups rows by (surface, item_id) then splits each conversation's
    rows into turns wherever the gap to the next row exceeds TURN_GAP_SECONDS.
    turn_end is the next turn's start, or turn_start + 72h for the last turn.
    Returns turns sorted by (surface, item_id, turn_start_dt)."""
    by_conv = {}
    for r in rows:
        by_conv.setdefault((r["surface"], r["item_id"]), []).append(r)

    turns = []
    for (surface, item_id), conv_rows in by_conv.items():
        conv_rows = sorted(conv_rows, key=lambda r: r["ts_dt"])
        clusters = [[conv_rows[0]]]
        for prev, cur in zip(conv_rows, conv_rows[1:]):
            gap = (cur["ts_dt"] - prev["ts_dt"]).total_seconds()
            if gap <= TURN_GAP_SECONDS:
                clusters[-1].append(cur)
            else:
                clusters.append([cur])

        for i, cluster in enumerate(clusters):
            turn_start_dt = cluster[0]["ts_dt"]
            if i + 1 < len(clusters):
                turn_end_dt = clusters[i + 1][0]["ts_dt"]
            else:
                turn_end_dt = turn_start_dt + LAST_TURN_WINDOW
            turns.append({
                "surface": surface,
                "item_id": item_id,
                "turn_start_dt": turn_start_dt,
                "turn_end_dt": turn_end_dt,
                "row_ts": [r["ts"] for r in cluster],
            })

    turns.sort(key=lambda t: (t["surface"], t["item_id"], t["turn_start_dt"]))
    return turns


def label_turn(turn, per_conv, conversations_seen, allowed_names):
    """Returns (truth_dict, evidence_dict) for one turn. trajectory_seen is
    whether the CONVERSATION is present in the trajectory store at all (any
    event type) -- never about the turn's own window, and never derived from
    whether it happened to make a tool call. That distinction is the one
    QA's round-6 NO-GO caught: gating on "has a tool.call ever" silently
    dropped every genuinely tool-free turn from the labeled set instead of
    correctly scoring it first_tool="none"."""
    trajectory_seen = turn["item_id"] in conversations_seen
    conv_events = per_conv.get(turn["item_id"]) or []
    truth = {}
    tools_called = []
    if trajectory_seen:
        start = turn["turn_start_dt"].timestamp()
        end = turn["turn_end_dt"].timestamp()
        in_window = sorted((e for e in conv_events if start <= e["ts"] < end),
                            key=lambda e: e["ts"])
        tools_called = [e["name"] for e in in_window]
        first_tool = "none"
        for e in in_window:
            if e["name"] in allowed_names:
                first_tool = e["name"]
                break
        truth["first_tool"] = first_tool
    return truth, {"tools_called": tools_called, "trajectory_seen": trajectory_seen}


def collect(shadow_path, inventory_path, trajectory_db_paths, since_hours=None):
    """Returns (records, summary). Raises OSError/ValueError if the
    inventory file is unreadable/malformed -- that is a config error, not a
    per-row skip."""
    rows = load_shadow_rows(shadow_path)
    turns = build_turns(rows)
    if since_hours is not None:
        cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=float(since_hours))
        turns = filter_turns_since(turns, cutoff)
    allowed_names = load_allowed_tool_names(inventory_path)
    per_conv, conversations_seen = sweep_sqlite(trajectory_db_paths)
    collected_at = format_ts(datetime.datetime.now(datetime.timezone.utc))

    records = []
    labeled = 0
    conversations = set()
    for turn in turns:
        conversations.add((turn["surface"], turn["item_id"]))
        truth, evidence = label_turn(turn, per_conv, conversations_seen, allowed_names)
        if "first_tool" in truth:
            labeled += 1
        records.append({
            "v": 1,
            "surface": turn["surface"],
            "item_id": turn["item_id"],
            "turn_start": format_ts(turn["turn_start_dt"]),
            "turn_end": format_ts(turn["turn_end_dt"]),
            "row_ts": turn["row_ts"],
            "truth": truth,
            "evidence": evidence,
            "collected_at": collected_at,
        })

    summary = {"turns": len(records), "conversations": len(conversations), "labeled": labeled}
    return records, summary


def write_atomic(records, out_path):
    """Writes one JSON object per line. Atomic + 0600 for a real target file
    (write to a uniquely-named temp file in the same directory, os.replace);
    a stream target (/dev/stdout, "-") has no filesystem identity to swap,
    so it is written directly -- that is the documented dry-run path for a
    read-only check against the live data. A raise mid-write on a real
    target leaves neither the tmp file nor the final file behind.

    Uses tempfile.mkstemp rather than a fixed "<out>.tmp" name: a fixed,
    predictable temp path opened without O_EXCL would follow a pre-existing
    symlink at that path (writing/truncating whatever it points to) and
    would also let two concurrent runs clobber each other's in-progress
    write. mkstemp's name is unpredictable and its open is O_CREAT|O_EXCL,
    closing both (GitHub Muso QA Bot, MUS-1541 round 7)."""
    if out_path in ("-", "/dev/stdout"):
        for rec in records:
            sys.stdout.write(json.dumps(rec, sort_keys=True))
            sys.stdout.write("\n")
        return

    out_dir = os.path.dirname(out_path) or "."
    fd, tmp_path = tempfile.mkstemp(prefix=os.path.basename(out_path) + ".", suffix=".tmp", dir=out_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            for rec in records:
                fh.write(json.dumps(rec, sort_keys=True))
                fh.write("\n")
    except Exception:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, out_path)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Read-only per-turn ground-truth collector for the Jev shadow report.")
    parser.add_argument("--shadow-file", default=DEFAULT_SHADOW_FILE)
    parser.add_argument("--out", default=DEFAULT_OUT)
    parser.add_argument("--since-hours", type=float, default=None)
    parser.add_argument("--inventory", default=DEFAULT_INVENTORY)
    parser.add_argument("--trajectory-db", default=DEFAULT_TRAJECTORY_DB)
    parser.add_argument("--json-summary", action="store_true")
    args = parser.parse_args(argv)

    try:
        records, summary = collect(args.shadow_file, args.inventory, [args.trajectory_db],
                                    since_hours=args.since_hours)
    except OSError as exc:
        print(f"jev-outcomes-collect.py: cannot read {exc.filename}: {exc}", file=sys.stderr)
        return 3
    except ValueError as exc:
        print(f"jev-outcomes-collect.py: malformed input: {exc}", file=sys.stderr)
        return 3

    write_atomic(records, args.out)

    if args.json_summary:
        print(json.dumps(summary))
    else:
        print(f"turns={summary['turns']} conversations={summary['conversations']} "
              f"labeled={summary['labeled']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
