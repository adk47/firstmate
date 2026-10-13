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
