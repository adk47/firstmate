"""Behavioral tests for scripts/jev-outcomes-collect.py.

This is the read-only half of MUS-1481's fix for jev-shadow-report.sh
comparing Jev to its own router action instead of a real outcome. It derives
`first_tool` ground truth per shadow-log turn from the openclaw trajectory
store and writes a sidecar JSONL. Invariants locked here: the 5.0s turn-
grouping rule (collapse vs. split), window selection of the FIRST allowlisted
tool.call (and only the allowlisted ones -- read/support_action_router must
not count), the 72h last-turn window, and -- the single most important rule
in the card -- a conversation absent from the trajectory store must leave
`first_tool` ABSENT from `truth`, never silently "none" (which would
manufacture agreement against Jev's single most common answer). Plus the
sidecar's own safety properties: 0600 mode and atomic, no-partial-file-on-
raise writes.

Stdlib pytest, no network, no real path -- every fixture is a temp shadow
JSONL and a temp SQLite trajectory store built in the test.
"""
import datetime
import importlib.util
import json
import os
import pathlib
import sqlite3
import stat

import pytest

_REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "jev-outcomes-collect.py"
_spec = importlib.util.spec_from_file_location("jev_outcomes_collect", _SCRIPT)
m = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m)


def shadow_row(item_id, ts, surface="caroline"):
    return {"ts": ts, "surface": surface, "item_id": item_id, "answers": {}, "actual": "route"}


def write_shadow(path, rows):
    with open(path, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")


def tool_call_event(name, ts, conv_id):
    return {"type": "tool.call", "ts": ts,
            "sessionKey": f"agent:support:intercom:direct:{conv_id}",
            "data": {"name": name, "toolCallId": f"{name}-{ts}"}}


def non_tool_event(event_type, ts, conv_id):
    """A real trajectory row that is NOT a tool.call -- e.g. Caroline answered
    from memory and called nothing. Presence of rows like this, with zero
    tool.call rows, is exactly the case QA's round-6 NO-GO found mislabeled."""
    return {"type": event_type, "ts": ts,
            "sessionKey": f"agent:support:intercom:direct:{conv_id}",
            "data": {}}


def write_trajectory_db(path, records):
    con = sqlite3.connect(path)
    con.execute("create table trajectory_runtime_events "
                "(session_id text, seq integer, run_id text, event_json text, created_at integer)")
    for i, r in enumerate(records):
        con.execute("insert into trajectory_runtime_events values (?,?,?,?,?)",
                    ("s1", i, "r1", json.dumps(r), 1789000000000 + i))
    con.commit()
    con.close()


def write_inventory(path, names):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"tools": [{"name": n} for n in names]}, fh)


@pytest.fixture
def inventory(tmp_path):
    path = tmp_path / "caroline-inventory.json"
    write_inventory(path, ["profile_status", "create_ticket", "credit_verification_check",
                            "read", "support_action_router"])
    return str(path)


def test_rows_2_3s_apart_collapse_into_one_turn():
    rows = [
        {"surface": "caroline", "item_id": "C1", "ts": "2026-09-23T10:00:00Z", "ts_dt":
         m.parse_ts("2026-09-23T10:00:00Z")},
        {"surface": "caroline", "item_id": "C1", "ts": "2026-09-23T10:00:02Z", "ts_dt":
         m.parse_ts("2026-09-23T10:00:02Z")},
    ]
    turns = m.build_turns(rows)
    assert len(turns) == 1
    assert turns[0]["row_ts"] == ["2026-09-23T10:00:00Z", "2026-09-23T10:00:02Z"]


def test_rows_90s_apart_are_two_turns():
    rows = [
        {"surface": "caroline", "item_id": "C1", "ts": "2026-09-23T10:00:00Z", "ts_dt":
         m.parse_ts("2026-09-23T10:00:00Z")},
        {"surface": "caroline", "item_id": "C1", "ts": "2026-09-23T10:01:30Z", "ts_dt":
         m.parse_ts("2026-09-23T10:01:30Z")},
    ]
    turns = m.build_turns(rows)
    assert len(turns) == 2
    assert turns[0]["row_ts"] == ["2026-09-23T10:00:00Z"]
    assert turns[1]["row_ts"] == ["2026-09-23T10:01:30Z"]


def test_rows_exactly_5_0s_apart_collapse():
    # QA round 3 finding 1b: the other two grouping tests use 2.3s and 90s,
    # both far from the threshold, so TURN_GAP_SECONDS's VALUE was free to
    # drift (e.g. widened to 60.0) with the suite still green. Pins the
    # boundary itself with a literal 5-second gap, not the constant.
    rows = [
        {"surface": "caroline", "item_id": "C1", "ts": "2026-09-23T10:00:00Z", "ts_dt":
         m.parse_ts("2026-09-23T10:00:00Z")},
        {"surface": "caroline", "item_id": "C1", "ts": "2026-09-23T10:00:05Z", "ts_dt":
         m.parse_ts("2026-09-23T10:00:05Z")},
    ]
    turns = m.build_turns(rows)
    assert len(turns) == 1


def test_rows_just_over_5_0s_apart_split():
    # The other half of the boundary: one second past 5.0s must already
    # split -- catches TURN_GAP_SECONDS being widened (this literal 6s gap
    # would wrongly collapse into one turn under e.g. 60.0) as well as a
    # <= -> < flip at the comparison site.
    rows = [
        {"surface": "caroline", "item_id": "C1", "ts": "2026-09-23T10:00:00Z", "ts_dt":
         m.parse_ts("2026-09-23T10:00:00Z")},
        {"surface": "caroline", "item_id": "C1", "ts": "2026-09-23T10:00:06Z", "ts_dt":
         m.parse_ts("2026-09-23T10:00:06Z")},
    ]
    turns = m.build_turns(rows)
    assert len(turns) == 2


def test_last_turn_of_a_conversation_gets_72h_window():
    # QA round 3 finding 1a: asserting against m.LAST_TURN_WINDOW pins only
    # the SHAPE (last turn uses the constant, not a next-cluster start) --
    # it is structurally incapable of catching the constant's VALUE being
    # tuned (e.g. 72 -> 24). Assert the literal instead.
    rows = [
        {"surface": "caroline", "item_id": "C1", "ts": "2026-09-23T10:00:00Z", "ts_dt":
         m.parse_ts("2026-09-23T10:00:00Z")},
    ]
    turns = m.build_turns(rows)
    assert len(turns) == 1
    assert turns[0]["turn_end_dt"] - turns[0]["turn_start_dt"] == datetime.timedelta(hours=72)


def test_tool_inside_window_is_picked(inventory, tmp_path):
    shadow = tmp_path / "caroline.jsonl"
    write_shadow(shadow, [
        shadow_row("C1", "2026-09-23T10:00:00Z"),
        shadow_row("C1", "2026-09-23T11:00:00Z"),  # starts a second turn -> bounds turn 1's end
    ])
    db = tmp_path / "traj.sqlite"
    write_trajectory_db(db, [
        tool_call_event("profile_status", "2026-09-23T10:00:05Z", "C1"),
    ])
    records, summary = m.collect(str(shadow), inventory, [str(db)])
    turn1 = next(r for r in records if r["row_ts"] == ["2026-09-23T10:00:00Z"])
    assert turn1["truth"]["first_tool"] == "profile_status"


def test_tool_after_turn_end_is_not_picked(inventory, tmp_path):
    shadow = tmp_path / "caroline.jsonl"
    write_shadow(shadow, [
        shadow_row("C1", "2026-09-23T10:00:00Z"),
        shadow_row("C1", "2026-09-23T11:00:00Z"),
    ])
    db = tmp_path / "traj.sqlite"
    write_trajectory_db(db, [
        tool_call_event("profile_status", "2026-09-23T11:00:05Z", "C1"),  # after turn1's end
    ])
    records, summary = m.collect(str(shadow), inventory, [str(db)])
    turn1 = next(r for r in records if r["row_ts"] == ["2026-09-23T10:00:00Z"])
    assert turn1["truth"]["first_tool"] == "none"
    turn2 = next(r for r in records if r["row_ts"] == ["2026-09-23T11:00:00Z"])
    assert turn2["truth"]["first_tool"] == "profile_status"


def test_first_allowlisted_tool_wins_when_several_fire(inventory, tmp_path):
    shadow = tmp_path / "caroline.jsonl"
    write_shadow(shadow, [shadow_row("C1", "2026-09-23T10:00:00Z")])
    db = tmp_path / "traj.sqlite"
    write_trajectory_db(db, [
        tool_call_event("read", "2026-09-23T10:00:01Z", "C1"),
        tool_call_event("credit_verification_check", "2026-09-23T10:00:03Z", "C1"),
        tool_call_event("profile_status", "2026-09-23T10:00:02Z", "C1"),
    ])
    records, summary = m.collect(str(shadow), inventory, [str(db)])
    turn = records[0]
    assert turn["truth"]["first_tool"] == "profile_status"


def test_builtin_only_window_is_none(inventory, tmp_path):
    shadow = tmp_path / "caroline.jsonl"
    write_shadow(shadow, [shadow_row("C1", "2026-09-23T10:00:00Z")])
    db = tmp_path / "traj.sqlite"
    write_trajectory_db(db, [
        tool_call_event("support_action_router", "2026-09-23T10:00:01Z", "C1"),
        tool_call_event("read", "2026-09-23T10:00:02Z", "C1"),
    ])
    records, summary = m.collect(str(shadow), inventory, [str(db)])
    turn = records[0]
    assert turn["truth"]["first_tool"] == "none"
    assert turn["evidence"]["trajectory_seen"] is True


def test_conversation_absent_from_trajectory_store_omits_first_tool(inventory, tmp_path):
    shadow = tmp_path / "caroline.jsonl"
    write_shadow(shadow, [shadow_row("C404", "2026-09-23T10:00:00Z")])
    db = tmp_path / "traj.sqlite"
    write_trajectory_db(db, [
        tool_call_event("profile_status", "2026-09-23T09:00:00Z", "C999"),  # different conv
    ])
    records, summary = m.collect(str(shadow), inventory, [str(db)])
    turn = records[0]
    assert "first_tool" not in turn["truth"]
    assert turn["evidence"]["trajectory_seen"] is False
    assert summary["labeled"] == 0
    assert summary["turns"] == 1
    assert summary["conversations"] == 1


def test_sweep_sqlite_conversations_seen_includes_conv_with_no_tool_call(tmp_path):
    # Pins the mechanism directly: conversations_seen must come from an
    # unfiltered scan, not from per_conv's tool.call-only collection. A
    # conv with ONLY non-tool.call rows must still land in conversations_seen.
    db = tmp_path / "traj.sqlite"
    write_trajectory_db(db, [
        non_tool_event("message.user", "2026-09-23T10:00:00Z", "C500"),
        non_tool_event("model.response", "2026-09-23T10:00:01Z", "C500"),
    ])
    per_conv, conversations_seen = m.sweep_sqlite([str(db)])
    assert "C500" in conversations_seen
    assert "C500" not in per_conv


def test_turn_with_only_nontool_trajectory_rows_is_none_not_omitted(inventory, tmp_path):
    # QA round 6 (MUS-1541 NO-GO on 9038aad), exact reproduction: a
    # conversation genuinely present in the store that made no tool call at
    # all must be labeled first_tool="none" with trajectory_seen=True --
    # NOT omitted as if the conversation were absent. Omitting it silently
    # drops every real "none" turn from the labeled set, biasing the metric
    # against exactly the answer Jev gives most often.
    shadow = tmp_path / "caroline.jsonl"
    write_shadow(shadow, [shadow_row("C500", "2026-09-23T10:00:00Z")])
    db = tmp_path / "traj.sqlite"
    write_trajectory_db(db, [
        non_tool_event("message.user", "2026-09-23T10:00:00Z", "C500"),
        non_tool_event("model.response", "2026-09-23T10:00:01Z", "C500"),
        non_tool_event("message.agent", "2026-09-23T10:00:02Z", "C500"),
    ])
    records, summary = m.collect(str(shadow), inventory, [str(db)])
    turn = records[0]
    assert turn["truth"]["first_tool"] == "none"
    assert turn["evidence"]["trajectory_seen"] is True
    assert turn["evidence"]["tools_called"] == []
    assert summary["labeled"] == 1


def test_output_file_is_0600_and_atomic(tmp_path):
    out_path = tmp_path / "caroline.outcomes.jsonl"
    m.write_atomic([{"a": 1}, {"a": 2}], str(out_path))
    mode = stat.S_IMODE(os.stat(out_path).st_mode)
    assert mode == 0o600
    lines = out_path.read_text().splitlines()
    assert len(lines) == 2
    # No leftover temp file under ANY name -- the tmp path is a randomized
    # mkstemp name, not the old fixed "<out>.tmp", so this must check the
    # whole directory rather than one guessed path.
    assert [p.name for p in tmp_path.iterdir()] == ["caroline.outcomes.jsonl"]


def test_no_partial_file_left_behind_when_collector_raises_mid_write(tmp_path):
    out_path = tmp_path / "caroline.outcomes.jsonl"

    def boom():
        yield {"a": 1}
        raise RuntimeError("simulated mid-write failure")

    with pytest.raises(RuntimeError):
        m.write_atomic(boom(), str(out_path))
    assert not os.path.exists(str(out_path))
    assert list(tmp_path.iterdir()) == []


def test_write_atomic_uses_an_unpredictable_temp_name_not_a_fixed_one(tmp_path):
    # GitHub Muso QA Bot (round 7, MUS-1541): a fixed "<out>.tmp" path
    # opened without O_EXCL follows a pre-existing symlink at that exact
    # path. Proven here by pre-creating a symlink at the OLD fixed name
    # pointing at a file outside tmp_path -- if write_atomic still opened
    # that literal path, this canary file would be clobbered.
    out_path = tmp_path / "caroline.outcomes.jsonl"
    canary = tmp_path / "canary_outside_target.txt"
    canary.write_text("untouched")
    os.symlink(str(canary), str(out_path) + ".tmp")

    m.write_atomic([{"a": 1}], str(out_path))

    assert canary.read_text() == "untouched"
    assert out_path.read_text().strip() == '{"a": 1}'


# QA round 1 (MUS-1547, NO-GO @ 755e6a23) findings 1 and 2.
# QA round 9 (MUS-1541 NO-GO @ e2951ddc) escalated finding 1: a WARN-only
# empty allowlist still let the collector run to completion, exit 0, and
# atomically overwrite a good sidecar with every turn fabricated "none".
# load_allowed_tool_names now RAISES instead of warning -- see below.

def test_empty_allowlist_after_builtin_exclude_raises(tmp_path):
    # BUILTIN_EXCLUDE strips every entry -- the same "zero valid support-tool
    # names" case scripts/jev-backtest-caroline.sh:238-239 warns on, but a
    # warning alone is not enough: main()'s existing `except ValueError:
    # return 3` only fires if this function actually raises.
    path = tmp_path / "inv.json"
    write_inventory(path, ["read", "support_action_router"])
    with pytest.raises(ValueError):
        m.load_allowed_tool_names(str(path))


def test_renamed_tools_key_also_raises(tmp_path):
    # Finding 1's exact reproduction: a generator-side rename of "tools"
    # passes check-caroline-inventory.sh's regenerate-and-diff gate but
    # zeroes this collector's allowlist.
    path = tmp_path / "inv.json"
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"supportTools": [{"name": "profile_status"}]}, fh)
    with pytest.raises(ValueError):
        m.load_allowed_tool_names(str(path))


def test_cli_empty_allowlist_exits_nonzero_and_preserves_last_good_sidecar(tmp_path, capsys):
    # QA round 9's exact ask: a CLI-level test asserting a non-zero exit AND
    # that no output replaces the last good sidecar. Drives main() itself,
    # not load_allowed_tool_names directly, so the whole pipeline -- collect()
    # raising before write_atomic is ever called -- is what is proven, not
    # just the one function.
    shadow = tmp_path / "caroline.jsonl"
    write_shadow(shadow, [shadow_row("C1", "2026-09-23T10:00:00Z")])
    inventory = tmp_path / "inv.json"
    write_inventory(inventory, ["read", "support_action_router"])  # empty after exclude
    db = tmp_path / "traj.sqlite"
    write_trajectory_db(db, [])
    out_path = tmp_path / "caroline.outcomes.jsonl"
    out_path.write_text('{"v": 1, "last": "good"}\n')
    before = out_path.read_bytes()

    rc = m.main([
        "--shadow-file", str(shadow),
        "--out", str(out_path),
        "--inventory", str(inventory),
        "--trajectory-db", str(db),
    ])

    assert rc != 0
    assert out_path.read_bytes() == before
    assert [p.name for p in tmp_path.iterdir() if p.name.startswith("caroline.outcomes")] == \
        ["caroline.outcomes.jsonl"]
    assert "malformed input" in capsys.readouterr().err


def test_since_hours_drops_whole_turns_never_truncates_one(inventory, tmp_path):
    # Finding 2's exact reproduction: a turn is two shadow rows 2s apart with
    # a qualifying tool call in between. Filtering rows before grouping (the
    # bug) would drop the first row on a cutoff that lands between the two,
    # making build_turns start the turn at the second row and pushing the
    # tool call out of its own window -- "first_tool" flips to "none". The
    # fix filters whole turns by turn_start AFTER grouping, so the turn is
    # either fully present with the right label or fully absent -- never
    # truncated into a wrong one.
    shadow = tmp_path / "caroline.jsonl"
    write_shadow(shadow, [
        shadow_row("C1", "2026-09-23T10:00:00Z"),
        shadow_row("C1", "2026-09-23T10:00:02Z"),
    ])
    db = tmp_path / "traj.sqlite"
    write_trajectory_db(db, [
        tool_call_event("profile_status", "2026-09-23T10:00:01Z", "C1"),
    ])
    rows = m.load_shadow_rows(str(shadow))
    turns = m.build_turns(rows)
    assert len(turns) == 1

    # Cutoff strictly between the two rows.
    mid_cutoff = m.parse_ts("2026-09-23T10:00:01Z")
    assert m.filter_turns_since(turns, mid_cutoff) == []

    before_cutoff = m.parse_ts("2026-09-23T09:59:00Z")
    kept = m.filter_turns_since(turns, before_cutoff)
    assert len(kept) == 1
    assert kept[0]["row_ts"] == ["2026-09-23T10:00:00Z", "2026-09-23T10:00:02Z"]


def test_filter_turns_since_boundary_is_inclusive():
    # QA round 2 finding 1's suggested boundary case: a turn whose
    # turn_start exactly equals the cutoff must be KEPT ("since" is an
    # inclusive lower bound). Catches a >= -> > flip (mutation D).
    turns = [{"turn_start_dt": m.parse_ts("2026-09-23T10:00:00Z"),
              "row_ts": ["2026-09-23T10:00:00Z"]}]
    cutoff = m.parse_ts("2026-09-23T10:00:00Z")
    assert m.filter_turns_since(turns, cutoff) == turns


def _iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (dt.microsecond // 1000)


def test_since_hours_cutoff_between_a_turns_rows_drops_it_through_collect(inventory, tmp_path):
    # QA round 2 (MUS-1576, NO-GO @ 24a2cd31) finding 1: the round-1 regression
    # test drove collect() with since_hours=100000 (~11 years), which can
    # never land between a turn's two rows, so it had zero power to fail
    # against the exact defect round 1 found. This test uses timestamps
    # relative to datetime.now() so collect()'s own now()-derived cutoff
    # actually lands strictly between the two rows, the way a real
    # --since-hours run would. Reintroducing the row-level prefilter (round-1
    # finding 2) or making --since-hours a no-op must turn this red.
    import datetime as _dt
    now = _dt.datetime.now(_dt.timezone.utc)
    row1 = now - _dt.timedelta(seconds=10)
    row2 = now - _dt.timedelta(seconds=8)
    tool_ts = now - _dt.timedelta(seconds=9)  # strictly between row1 and row2

    shadow = tmp_path / "caroline.jsonl"
    write_shadow(shadow, [shadow_row("C1", _iso(row1)), shadow_row("C1", _iso(row2))])
    db = tmp_path / "traj.sqlite"
    write_trajectory_db(db, [tool_call_event("profile_status", _iso(tool_ts), "C1")])

    # Control: no --since-hours, the turn is whole and correctly labeled.
    records_full, summary_full = m.collect(str(shadow), inventory, [str(db)])
    assert summary_full["turns"] == 1
    assert records_full[0]["truth"]["first_tool"] == "profile_status"

    # since_hours cutoff = now - 9s, landing strictly between row1 and row2.
    since_hours = 9.0 / 3600.0
    records, summary = m.collect(str(shadow), inventory, [str(db)], since_hours=since_hours)
    assert summary["turns"] == 0
    assert records == []


# ── --intercom leg (MUS-1543): resolution_path + needs_reply ground truth ──
# Every fixture stubs the HTTP layer; nothing here touches the network.
import io
import re
import urllib.error

CAROLINE = "5763097"
HUMAN = "9000001"
T0 = "2026-09-23T10:00:00Z"
T0_EPOCH = int(m.parse_ts(T0).timestamp())
SECRET_TEXT = "SECRET-CUSTOMER-TEXT jane@example.com Jane Doe"


def part(offset, author_type, author_id, part_type="comment"):
    return {"part_type": part_type, "created_at": T0_EPOCH + offset,
            "body": SECRET_TEXT,
            "author": {"type": author_type, "id": str(author_id), "name": "Jane Doe",
                       "email": "jane@example.com"}}


def conv(parts=(), state="open", last_close=None, reopens=0, assignee=None,
         first_assignment=None, rating=None):
    return {"id": "C1", "state": state, "admin_assignee_id": assignee,
            "conversation_rating": rating,
            "statistics": {"count_reopens": reopens, "last_close_at": last_close,
                           "first_assignment_at": first_assignment},
            "conversation_parts": {"conversation_parts": list(parts)}}


def run_intercom(tmp_path, inventory, convs, shadow_rows=None, tools=(), max_convs=None):
    """convs: item_id -> payload dict, or None for a failed GET. Returns
    (records, summary, calls) where calls is the list of fetched ids."""
    shadow = tmp_path / "caroline.jsonl"
    write_shadow(shadow, shadow_rows or [shadow_row("C1", T0)])
    db = tmp_path / "traj.sqlite"
    write_trajectory_db(db, [tool_call_event(n, ts, "C1") for n, ts in tools]
                        or [non_tool_event("model.completed", T0, "C1")])
    calls = []

    def fetch(cid):
        calls.append(cid)
        return convs.get(cid)

    records, summary = m.collect(str(shadow), inventory, [str(db)], intercom_fetch=fetch,
                                 intercom_max_convs=max_convs)
    return records, summary, calls


def test_human_admin_part_in_window_is_human_required_and_beats_a_tool_call(inventory, tmp_path):
    c = conv([part(30, "admin", HUMAN)])
    recs, _, _ = run_intercom(tmp_path, inventory, {"C1": c},
                              tools=[("profile_status", "2026-09-23T10:00:10Z")])
    assert recs[0]["truth"]["first_tool"] == "profile_status"
    assert recs[0]["truth"]["resolution_path"] == "human_required"
    assert recs[0]["evidence"]["human_admin_replied"] is True


def test_human_assignee_with_assignment_in_window_is_human_required(inventory, tmp_path):
    c = conv([], assignee=HUMAN, first_assignment=T0_EPOCH + 20)
    recs, _, _ = run_intercom(tmp_path, inventory, {"C1": c})
    assert recs[0]["truth"]["resolution_path"] == "human_required"


def test_caroline_assignee_is_not_a_human_takeover(inventory, tmp_path):
    c = conv([], assignee=CAROLINE, first_assignment=T0_EPOCH + 20)
    recs, _, _ = run_intercom(tmp_path, inventory, {"C1": c})
    assert "resolution_path" not in recs[0]["truth"]


def test_bot_author_and_caroline_admin_are_not_human(inventory, tmp_path):
    c = conv([part(5, "bot", "77"), part(20, "admin", CAROLINE)])
    recs, _, _ = run_intercom(tmp_path, inventory, {"C1": c},
                              tools=[("profile_status", "2026-09-23T10:00:10Z")])
    assert recs[0]["truth"]["resolution_path"] == "caroline_tool"
    assert recs[0]["evidence"]["human_admin_replied"] is False
    assert recs[0]["evidence"]["caroline_replied"] is True


def test_tool_call_and_no_human_is_caroline_tool(inventory, tmp_path):
    recs, _, _ = run_intercom(tmp_path, inventory, {"C1": conv([])},
                              tools=[("create_ticket", "2026-09-23T10:00:10Z")])
    assert recs[0]["truth"]["resolution_path"] == "caroline_tool"


def test_silence_then_close_without_reopen_is_no_reply(inventory, tmp_path):
    c = conv([], state="closed", last_close=T0_EPOCH + 600)
    recs, _, _ = run_intercom(tmp_path, inventory, {"C1": c})
    assert recs[0]["truth"]["resolution_path"] == "no_reply"
    assert recs[0]["truth"]["needs_reply"] == "false"
    assert recs[0]["evidence"]["closed_without_human"] is True


def test_same_shape_with_a_reopen_leaves_resolution_path_absent(inventory, tmp_path):
    c = conv([], state="closed", last_close=T0_EPOCH + 600, reopens=1)
    recs, _, _ = run_intercom(tmp_path, inventory, {"C1": c})
    assert "resolution_path" not in recs[0]["truth"]
    assert recs[0]["evidence"]["reopens"] == 1


def test_caroline_replied_no_tool_customer_wrote_back_is_never_labelled(inventory, tmp_path):
    # The "do not invent ask_customer / answer_from_knowledge" guard: this
    # signature is identical for a clarifying question, a knowledge answer
    # and a silently failed tool call, so the key must be ABSENT.
    c = conv([part(20, "admin", CAROLINE), part(120, "user", "u1")])
    recs, _, _ = run_intercom(tmp_path, inventory, {"C1": c})
    assert "resolution_path" not in recs[0]["truth"]
    assert recs[0]["truth"]["needs_reply"] == "true"


def test_last_turn_of_open_conversation_omits_needs_reply(inventory, tmp_path):
    recs, _, _ = run_intercom(tmp_path, inventory, {"C1": conv([])})
    assert "needs_reply" not in recs[0]["truth"]


def test_open_conversation_reopened_after_an_earlier_close_still_omits_needs_reply(inventory, tmp_path):
    # last_close_at predates this turn: the close belongs to an earlier turn.
    c = conv([], state="open", last_close=T0_EPOCH - 3600, reopens=1)
    recs, _, _ = run_intercom(tmp_path, inventory, {"C1": c})
    assert "needs_reply" not in recs[0]["truth"]


def test_non_last_turn_without_caroline_part_is_needs_reply_false(inventory, tmp_path):
    rows = [shadow_row("C1", T0), shadow_row("C1", "2026-09-23T10:10:00Z")]
    recs, _, _ = run_intercom(tmp_path, inventory, {"C1": conv([])}, shadow_rows=rows)
    assert recs[0]["truth"]["needs_reply"] == "false"
    assert "needs_reply" not in recs[1]["truth"]


def test_parts_outside_the_turn_window_do_not_count(inventory, tmp_path):
    rows = [shadow_row("C1", T0), shadow_row("C1", "2026-09-23T10:10:00Z")]
    c = conv([part(700, "admin", HUMAN)])  # in turn 2's window only
    recs, _, _ = run_intercom(tmp_path, inventory, {"C1": c}, shadow_rows=rows)
    assert "resolution_path" not in recs[0]["truth"]
    assert recs[1]["truth"]["resolution_path"] == "human_required"


def test_failed_get_keeps_first_tool_and_marks_intercom_unseen(inventory, tmp_path):
    rows = [shadow_row("C1", T0), shadow_row("C2", T0)]
    db = tmp_path / "traj.sqlite"
    shadow = tmp_path / "caroline.jsonl"
    write_shadow(shadow, rows)
    write_trajectory_db(db, [tool_call_event("profile_status", "2026-09-23T10:00:10Z", "C1"),
                             tool_call_event("create_ticket", "2026-09-23T10:00:10Z", "C2")])
    good = conv([part(30, "admin", HUMAN)])
    recs, summary = m.collect(str(shadow), inventory, [str(db)],
                              intercom_fetch=lambda cid: None if cid == "C1" else good)
    c1, c2 = recs
    assert c1["truth"] == {"first_tool": "profile_status"}
    assert c1["evidence"]["intercom_seen"] is False
    assert "csat" not in c1["evidence"]
    assert c2["truth"]["resolution_path"] == "human_required"
    assert c2["evidence"]["intercom_seen"] is True
    assert summary["intercom_failed"] == 1


def test_one_get_per_conversation_reused_across_turns(inventory, tmp_path):
    rows = [shadow_row("C1", T0), shadow_row("C1", "2026-09-23T10:10:00Z"),
            shadow_row("C1", "2026-09-23T10:20:00Z")]
    _, _, calls = run_intercom(tmp_path, inventory, {"C1": conv([])}, shadow_rows=rows)
    assert calls == ["C1"]


def test_max_convs_caps_gets_and_marks_the_rest_unseen(inventory, tmp_path):
    rows = [shadow_row("C1", T0), shadow_row("C2", T0)]
    recs, _, calls = run_intercom(tmp_path, inventory, {"C1": conv([]), "C2": conv([])},
                                  shadow_rows=rows, max_convs=1)
    assert calls == ["C1"]
    assert recs[1]["evidence"]["intercom_seen"] is False


def test_intercom_off_adds_no_intercom_keys(inventory, tmp_path):
    shadow = tmp_path / "caroline.jsonl"
    write_shadow(shadow, [shadow_row("C1", T0)])
    db = tmp_path / "traj.sqlite"
    write_trajectory_db(db, [non_tool_event("model.completed", T0, "C1")])
    recs, summary = m.collect(str(shadow), inventory, [str(db)])
    assert "intercom_seen" not in recs[0]["evidence"]
    assert set(recs[0]["truth"]) == {"first_tool"}
    assert "intercom_failed" not in summary


def test_csat_and_no_customer_text_in_the_sidecar(inventory, tmp_path):
    c = conv([part(20, "admin", CAROLINE), part(30, "user", "u1")], state="closed",
             last_close=T0_EPOCH + 90, rating={"rating": 5, "remark": SECRET_TEXT})
    recs, _, _ = run_intercom(tmp_path, inventory, {"C1": c})
    assert recs[0]["evidence"]["csat"] == 5
    out = tmp_path / "out.jsonl"
    m.write_atomic(recs, str(out))
    blob = out.read_text()
    for needle in ("SECRET-CUSTOMER-TEXT", "jane@example.com", "Jane Doe"):
        assert needle not in blob


def test_caroline_admin_id_default_matches_the_identity_gate_script():
    src = (_REPO_ROOT / "scripts" / "check-intercom-reply-identity.sh").read_text()
    pinned = re.search(r'^CAROLINE_ADMIN_ID="(\d+)"', src, re.M).group(1)
    assert m.DEFAULT_CAROLINE_ADMIN_ID == pinned


def test_caroline_admin_id_env_override(monkeypatch):
    monkeypatch.setenv("JEV_OUTCOMES_CAROLINE_ADMIN_ID", "123")
    assert m.caroline_admin_id_from_env() == "123"
    monkeypatch.delenv("JEV_OUTCOMES_CAROLINE_ADMIN_ID")
    assert m.caroline_admin_id_from_env() == m.DEFAULT_CAROLINE_ADMIN_ID


# ── the HTTP layer ──

class _Resp:
    def __init__(self, payload):
        self._b = json.dumps(payload).encode()

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _http_error(code, headers=None):
    import email.message
    h = email.message.Message()
    for k, v in (headers or {}).items():
        h[k] = v
    return urllib.error.HTTPError("https://x", code, "err", h, io.BytesIO(b"{}"))


def test_fetcher_issues_a_get_with_pinned_headers_and_no_body():
    seen = []

    def opener(req, timeout):
        seen.append(req)
        return _Resp({"id": "C1"})

    f = m.make_intercom_fetcher("tok123", opener=opener, sleep=lambda s: None)
    assert f("C1") == {"id": "C1"}
    req = seen[0]
    assert req.get_method() == "GET" and req.data is None
    assert req.full_url == "https://api.intercom.io/conversations/C1?display_as=plaintext"
    assert req.get_header("Intercom-version") == "2.11"
    assert req.get_header("Authorization") == "Bearer tok123"


def test_fetcher_retries_429_honouring_retry_after_then_succeeds():
    outcomes = [_http_error(429, {"Retry-After": "7"}), _Resp({"id": "C1"})]
    sleeps = []

    def opener(req, timeout):
        o = outcomes.pop(0)
        if isinstance(o, Exception):
            raise o
        return o

    f = m.make_intercom_fetcher("t", opener=opener, sleep=sleeps.append)
    assert f("C1") == {"id": "C1"}
    assert sleeps == [7]


@pytest.mark.parametrize("exc", [_http_error(500), _http_error(404),
                                 urllib.error.URLError("boom"), TimeoutError("slow")])
def test_fetcher_returns_none_on_failure_never_raises(exc):
    def opener(req, timeout):
        raise exc

    f = m.make_intercom_fetcher("t", opener=opener, sleep=lambda s: None)
    assert f("C1") is None


def test_fetcher_none_on_non_json_body():
    class Bad(_Resp):
        def read(self):
            return b"<html>"

    f = m.make_intercom_fetcher("t", opener=lambda r, timeout: Bad({}), sleep=lambda s: None)
    assert f("C1") is None


def test_token_file_parsing(tmp_path):
    p = tmp_path / "edge.env"
    p.write_text('OTHER=1\nexport MUSOAI_INTERCOM_TOKEN="abc def"\n')
    assert m.read_intercom_token(str(p)) == "abc def"
    p.write_text("MUSOAI_INTERCOM_TOKEN=plain\n")
    assert m.read_intercom_token(str(p)) == "plain"
    p.write_text("OTHER=1\n")
    with pytest.raises(ValueError):
        m.read_intercom_token(str(p))


def test_cli_intercom_runs_end_to_end_exit_0_with_one_bad_conversation(inventory, tmp_path, monkeypatch, capsys):
    shadow = tmp_path / "caroline.jsonl"
    write_shadow(shadow, [shadow_row("C1", T0), shadow_row("C2", T0)])
    db = tmp_path / "traj.sqlite"
    write_trajectory_db(db, [tool_call_event("profile_status", "2026-09-23T10:00:10Z", "C1")])
    envf = tmp_path / "edge.env"
    envf.write_text("MUSOAI_INTERCOM_TOKEN=tok\n")

    def fake_fetcher(token, **kw):
        assert token == "tok"
        return lambda cid: None if cid == "C1" else conv([part(30, "admin", HUMAN)])

    monkeypatch.setattr(m, "make_intercom_fetcher", fake_fetcher)
    out = tmp_path / "out.jsonl"
    rc = m.main(["--shadow-file", str(shadow), "--out", str(out), "--inventory", inventory,
                 "--trajectory-db", str(db), "--intercom", "--intercom-token-file", str(envf),
                 "--json-summary"])
    assert rc == 0
    summary = json.loads(capsys.readouterr().out)
    assert summary["intercom_failed"] == 1
    assert summary["resolution_path_hist"] == {"human_required": 1}
    assert "tok" not in out.read_text()


def test_cli_intercom_without_a_token_fails_loud_and_preserves_the_sidecar(inventory, tmp_path):
    shadow = tmp_path / "caroline.jsonl"
    write_shadow(shadow, [shadow_row("C1", T0)])
    out = tmp_path / "out.jsonl"
    out.write_text("GOOD\n")
    envf = tmp_path / "edge.env"
    envf.write_text("OTHER=1\n")
    rc = m.main(["--shadow-file", str(shadow), "--out", str(out), "--inventory", inventory,
                 "--trajectory-db", str(tmp_path / "none.sqlite"),
                 "--intercom", "--intercom-token-file", str(envf)])
    assert rc == 3
    assert out.read_text() == "GOOD\n"
