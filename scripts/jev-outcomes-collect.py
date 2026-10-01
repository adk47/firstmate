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
#     [--json-summary] [--intercom [--intercom-token-file PATH]
#     [--intercom-max-convs N]]
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
#
# --intercom (off by default) adds the half only Intercom can answer, from ONE
# read-only GET per conversation (never a POST/PUT/tag/note/assignment):
# resolution_path in {human_required, caroline_tool, no_reply} and needs_reply.
# ask_customer / answer_from_knowledge / acknowledge are deliberately NEVER
# emitted -- "Caroline replied without a tool and the customer wrote back" is
# the same observable signature for all three plus a silently failed tool, and
# a wrong label is worse than none. A turn we cannot label has the key ABSENT.
# A failed GET marks that conversation's turns evidence.intercom_seen=false
# and never aborts the run. No customer text/email/name is ever copied out of
# a response: only ids, timestamps and label vocabulary reach the sidecar.
# ──────────────────────────────────────────────────────────────
import argparse
import datetime
import http.client
import json
import os
import sqlite3
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

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
DEFAULT_INTERCOM_TOKEN_FILE = "/etc/openclaw/edge.env"

# Pinned by scripts/check-intercom-reply-identity.sh (CAROLINE_ADMIN_ID); a
# test parses that file and asserts this equals it, so the copies cannot drift.
DEFAULT_CAROLINE_ADMIN_ID = "5763097"

INTERCOM_API_BASE = "https://api.intercom.io"
INTERCOM_VERSION = "2.11"
INTERCOM_TIMEOUT_SECONDS = 30
INTERCOM_MAX_ATTEMPTS = 3
INTERCOM_MAX_RETRY_AFTER = 60

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
                "is_last": i + 1 == len(clusters),
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


def caroline_admin_id_from_env():
    return os.environ.get("JEV_OUTCOMES_CAROLINE_ADMIN_ID") or DEFAULT_CAROLINE_ADMIN_ID


def read_intercom_token(path):
    """MUSOAI_INTERCOM_TOKEN from an env file (optional `export`, optional
    quotes). Raises OSError if unreadable, ValueError if absent/empty --
    --intercom without a token is a config error, never a silent no-op."""
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("export "):
                line = line[len("export "):].lstrip()
            key, sep, val = line.partition("=")
            if sep and key.strip() == "MUSOAI_INTERCOM_TOKEN":
                val = val.strip().strip("\"'")
                if val:
                    return val
    raise ValueError("no MUSOAI_INTERCOM_TOKEN in %s" % path)


def make_intercom_fetcher(token, opener=urllib.request.urlopen, sleep=time.sleep):
    """Returns fetch(conv_id) -> conversation dict, or None on ANY failure.
    GET only. Same 429 + Retry-After + exponential-backoff shape as
    scripts/cs-analysis/fetch-conversations.py:48-64, but every failure ends
    in None (fail-soft per conversation) instead of raising. Only the
    conversation id and HTTP status are ever written to stderr."""
    def fetch(conv_id):
        url = "%s/conversations/%s?display_as=plaintext" % (
            INTERCOM_API_BASE, urllib.parse.quote(str(conv_id), safe=""))
        req = urllib.request.Request(url, method="GET", headers={
            "Authorization": "Bearer %s" % token,
            "Accept": "application/json",
            "Intercom-Version": INTERCOM_VERSION,
        })
        for attempt in range(INTERCOM_MAX_ATTEMPTS):
            try:
                with opener(req, timeout=INTERCOM_TIMEOUT_SECONDS) as resp:
                    body = json.loads(resp.read())
                return body if isinstance(body, dict) else None
            except urllib.error.HTTPError as exc:
                if exc.code == 429 and attempt + 1 < INTERCOM_MAX_ATTEMPTS:
                    try:
                        wait = int(exc.headers.get("Retry-After", 10))
                    except (TypeError, ValueError):
                        wait = 10
                    sleep(max(0, min(wait, INTERCOM_MAX_RETRY_AFTER)))
                    continue
                print("jev-outcomes-collect.py: intercom GET %s -> http %s" % (conv_id, exc.code),
                      file=sys.stderr)
                return None
            except ValueError:
                print("jev-outcomes-collect.py: intercom GET %s -> non-JSON body" % conv_id,
                      file=sys.stderr)
                return None
            except (urllib.error.URLError, http.client.HTTPException, OSError):
                if attempt + 1 < INTERCOM_MAX_ATTEMPTS:
                    sleep(2 ** attempt)
                    continue
                print("jev-outcomes-collect.py: intercom GET %s -> network failure" % conv_id,
                      file=sys.stderr)
                return None
        return None
    return fetch


def _epoch(v):
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def is_human_admin(author_type, author_id, caroline_id):
    """Mirrors plugins/intercom/src/handoff.ts isHumanAdmin: an admin who is
    not Caroline. A bot author is never a human takeover."""
    return author_type == "admin" and author_id is not None and str(author_id) != str(caroline_id)


def summarize_intercom(conv, caroline_id):
    """Reduces one Intercom conversation payload to ids/timestamps only --
    nothing from a message body, name or email survives this function."""
    stats = conv.get("statistics") or {}
    parts = []
    raw_parts = (conv.get("conversation_parts") or {}).get("conversation_parts") or []
    for p in raw_parts:
        if not isinstance(p, dict):
            continue
        at = _epoch(p.get("created_at"))
        author = p.get("author") or {}
        if at is None:
            continue
        a_type, a_id = author.get("type"), author.get("id")
        parts.append({
            "at": at,
            "human": is_human_admin(a_type, a_id, caroline_id),
            "caroline_comment": (a_type == "admin" and a_id is not None
                                 and str(a_id) == str(caroline_id)
                                 and p.get("part_type") == "comment"),
        })
    assignee = conv.get("admin_assignee_id")
    rating = conv.get("conversation_rating")
    return {
        "parts": parts,
        "human_assignee": assignee is not None and str(assignee) != str(caroline_id),
        "first_assignment_at": _epoch(stats.get("first_assignment_at")),
        "last_close_at": _epoch(stats.get("last_close_at")),
        "reopens": stats.get("count_reopens") if isinstance(stats.get("count_reopens"), int) else 0,
        "csat": rating.get("rating") if isinstance(rating, dict) else None,
    }


def label_intercom(turn, truth, ic):
    """Returns (truth_additions, evidence_additions) for one turn.
    resolution_path precedence, first match wins inside the window:
    human_required > caroline_tool > no_reply > absent."""
    start = turn["turn_start_dt"].timestamp()
    end = turn["turn_end_dt"].timestamp()
    in_win = [p for p in ic["parts"] if start <= p["at"] < end]
    human_in_win = any(p["human"] for p in in_win) or (
        ic["human_assignee"] and ic["first_assignment_at"] is not None
        and start <= ic["first_assignment_at"] < end)
    caroline_in_win = any(p["caroline_comment"] for p in in_win)
    last_close = ic["last_close_at"]
    closed_after_start = last_close is not None and last_close >= start
    closed_in_win = last_close is not None and start <= last_close < end

    add = {}
    if human_in_win:
        add["resolution_path"] = "human_required"
    elif truth.get("first_tool") not in (None, "none"):
        add["resolution_path"] = "caroline_tool"
    elif not caroline_in_win and closed_in_win and ic["reopens"] == 0:
        add["resolution_path"] = "no_reply"

    if caroline_in_win:
        add["needs_reply"] = "true"
    elif not turn["is_last"] or closed_after_start:
        add["needs_reply"] = "false"

    human_any = any(p["human"] for p in ic["parts"])
    evidence = {
        "intercom_seen": True,
        "caroline_replied": any(p["caroline_comment"] for p in ic["parts"]),
        "human_admin_replied": human_any,
        "closed_without_human": last_close is not None and not human_any,
        "reopens": ic["reopens"],
        "csat": ic["csat"],
    }
    return add, evidence


def collect(shadow_path, inventory_path, trajectory_db_paths, since_hours=None,
            intercom_fetch=None, intercom_max_convs=None, caroline_id=None):
    """Returns (records, summary). Raises OSError/ValueError if the
    inventory file is unreadable/malformed -- that is a config error, not a
    per-row skip. intercom_fetch (conv_id -> dict|None) switches on the
    Intercom leg; None keeps the original trajectory-only behaviour."""
    rows = load_shadow_rows(shadow_path)
    turns = build_turns(rows)
    if since_hours is not None:
        cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=float(since_hours))
        turns = filter_turns_since(turns, cutoff)
    allowed_names = load_allowed_tool_names(inventory_path)
    per_conv, conversations_seen = sweep_sqlite(trajectory_db_paths)
    collected_at = format_ts(datetime.datetime.now(datetime.timezone.utc))

    caroline_id = caroline_id or caroline_admin_id_from_env()
    capped = set()  # conversations skipped by --intercom-max-convs, not failures
    intercom = {}  # item_id -> summarized payload, or None for a failed/skipped GET
    records = []
    labeled = 0
    conversations = set()
    for turn in turns:
        conversations.add((turn["surface"], turn["item_id"]))
        truth, evidence = label_turn(turn, per_conv, conversations_seen, allowed_names)
        if intercom_fetch is not None:
            cid = turn["item_id"]
            if cid not in intercom:
                if intercom_max_convs is not None and len(intercom) >= intercom_max_convs:
                    intercom[cid] = None
                    capped.add(cid)
                else:
                    # One bad conversation (transport fault OR malformed payload)
                    # must never abort the run.
                    try:
                        payload = intercom_fetch(cid)
                        intercom[cid] = summarize_intercom(payload, caroline_id) if payload else None
                    except Exception as exc:
                        print("jev-outcomes-collect.py: intercom %s skipped (%s)"
                              % (cid, type(exc).__name__), file=sys.stderr)
                        intercom[cid] = None
            if intercom[cid] is None:
                evidence["intercom_seen"] = False
            else:
                add_truth, add_evidence = label_intercom(turn, truth, intercom[cid])
                truth.update(add_truth)
                evidence.update(add_evidence)
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
    if intercom_fetch is not None:
        hist = {}
        for r in records:
            rp = r["truth"].get("resolution_path")
            if rp:
                hist[rp] = hist.get(rp, 0) + 1
        attempted = len(intercom) - len(capped)
        failed = sum(1 for c, v in intercom.items() if v is None and c not in capped)
        summary["intercom_failed"] = failed
        summary["intercom_capped"] = len(capped)
        if attempted and failed == attempted:
            print("jev-outcomes-collect.py: WARNING every intercom GET failed (%d/%d); "
                  "token revoked or API down?" % (failed, attempted), file=sys.stderr)
        summary["resolution_path_labeled"] = sum(hist.values())
        summary["resolution_path_hist"] = hist
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
    parser.add_argument("--intercom", action="store_true",
                        help="add resolution_path/needs_reply from read-only Intercom GETs")
    parser.add_argument("--intercom-token-file", default=DEFAULT_INTERCOM_TOKEN_FILE)
    parser.add_argument("--intercom-max-convs", type=int, default=None)
    args = parser.parse_args(argv)

    try:
        fetch = None
        if args.intercom:
            fetch = make_intercom_fetcher(read_intercom_token(args.intercom_token_file))
        records, summary = collect(args.shadow_file, args.inventory, [args.trajectory_db],
                                    since_hours=args.since_hours, intercom_fetch=fetch,
                                    intercom_max_convs=args.intercom_max_convs)
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
        if args.intercom:
            print(f"intercom_failed={summary['intercom_failed']} "
                  f"resolution_path_labeled={summary['resolution_path_labeled']} "
                  f"hist={json.dumps(summary['resolution_path_hist'], sort_keys=True)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
