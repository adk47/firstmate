"""User-level decision, row-level effect (captain 2026-11-12: "the verification decision unit is wrong").

The held queue is counted in rows and worked in rows, and it is made of people: 11,552 rows on us are
1,617 users, and the R8-volume cohort is 2,061 rows that belong to 65 of them. This module changes the
UNIT the stored-fact rules of the decider are evaluated in, and nothing else:

* one verdict per PERSON: a user's open rows are grouped by the stored facts the rules read, the ladder
  is walked ONCE per group, and the answer is applied to every row in it;
* the EFFECT stays per row: every row gets its own answer (rule, decision, reason), worded by the same
  functions the per-row path uses, so the ledger row and the audit trail are what they were;
* no threshold, refusal rule or hold reason is defined here. The rule functions are
  ``policy.validator_rejected_rules`` and ``policy.validator_conflict`` and the deny lists are the
  decider's own ``Policy``; this file only decides how many times they are called.

What is, and is not, decided here. ``RULES`` is the inventory. The rules a row's STORED facts decide
(a validator ``reject_*`` rule, the user / profile deny lists, a missing trackId, a validator conflict)
are user-level. Everything that reads the row's own track, role or catalog evidence stays per-row and
is answered ``per_row``: this module never approves, and it never guesses a row it cannot read.

A row whose stored facts are not in the shape the rules were written for is AMBIGUOUS: it is not put in
any group, it is walked on its own exactly as today (``row_answer``), and it is counted
(``UserVerdict.fallback``). A batched verdict never covers a row it could not read.

The stored-fact answer of a row is its answer once the row's live read succeeds; ``Answer.live`` names
the read that can still defer it this run. Only the reject rule sits ahead of every live read, which is
why it is the one the decider takes from here (``decide.run``); see docs/credit-verification/
user-level-decisions.md.
"""
from __future__ import annotations

import math
import time
from collections import Counter
from dataclasses import dataclass, field
from typing import Any, Iterable, Sequence

from .policy import (HOLD_ON_ERROR_KEY, HOLD_RULE_PREFIX, REJECT_RULE_PREFIX, validator_conflict,
                     validator_rejected_rules)

# --- the rules, in the decider's order -------------------------------------------------------------
REJECT_RULE = "reject_rule"
DENY_USER = "deny_user"
DENY_PROFILE = "deny_profile"
NO_TRACK = "no_track"
CONFLICT = "validator_conflict"
PER_ROW = "per_row"

# The wording of each stored-fact rule, written ONCE: the per-row path (decide.pre_model, decide.run)
# and the user-level pass print the same text, so a row cannot be worded one way by one unit and
# another way by the other.
DENY_USER_REASON = "user on the fraud / PULL / HOLD / RE-VERIFY list"
DENY_PROFILE_REASON = "profile on the fleet-scan / stillfloo deny list"
NO_TRACK_REASON = "track not ingested yet (no trackId): decided once the catalog has it"
PER_ROW_REASON = "no stored-fact rule decides this row: its own track, role and catalog evidence do (per-row path)"

# Which live read can still DEFER a row before its stored-fact answer lands (decide.run order).
LIVE_NONE = ""
LIVE_EVIDENCE = "evidence build"
LIVE_TRACK = "evidence build, catalog track read"


def reject_hold_reason(rejected: Sequence[str]) -> str:
    return (f"validator reject rule fired ({', '.join(rejected)}): "
            "never approved or asked by automation; human review")


def conflict_reason(conflict: dict[str, Any]) -> str:
    return ("validator conflict (the server refuses agent approvals of these): "
            + ",".join(conflict["hold_rules"] + (["class_c"] if conflict["class_c"] else [])
                       + (["hold_on_error"] if conflict["hold_on_error"] else [])))


@dataclass(frozen=True)
class Rule:
    name: str
    unit: str          # "user" | "row" | "user (already)"
    why: str


#: Every rule of the decider's path and the unit it is evaluated in after this change. "user" rows are
#: the ones this module batches; "row" rows are untouched and say why; "user (already)" were per person
#: before this change and are listed so the inventory is complete.
RULES: tuple[Rule, ...] = (
    Rule(REJECT_RULE, "user", "reads only the row's stored validator rules; rows of one person that carry the "
         "same rules get one walk. Decided before any live read."),
    Rule(DENY_USER, "user", "a fact about the person: read once per user, never per row."),
    Rule(DENY_PROFILE, "user", "reads only the row's profile id against the deny list; one walk per group."),
    Rule(NO_TRACK, "user", "reads only whether the row has a trackId; one walk per group."),
    Rule(CONFLICT, "user", "reads only the row's stored validator rules and rule errors; one walk per group."),
    Rule("evidence_unavailable", "row", "a live read of THIS row's track and profile failed this run; a "
         "transient failure of one read says nothing about the person's other rows."),
    Rule("catalog_track_unreadable", "row", "the row's own catalog track could not be read this run."),
    Rule("artist_unreadable", "row", "a linked artist of the row's own track could not be read this run."),
    Rule("big_track", "row", "the popularity of the row's own track; a person holds big and small tracks."),
    Rule("trusted_source_contradiction", "row", "what trusted sources credit on the row's own track and role."),
    Rule("red_flags", "row", "computed from the row's own evidence."),
    Rule("editorial_role", "row", "the row's own roles against the row's own track popularity."),
    Rule("trusted_confirmation", "row", "an APPROVAL: every claimed role credited on this track by a trusted "
         "source. Never inferred from another row (never approve on absence of evidence)."),
    Rule("footprint", "row", "an APPROVAL: counted per role family of the row's own claim."),
    Rule("web_check", "row", "an APPROVAL or a support request from sources about this track and role."),
    Rule("document_contradiction", "row", "a document verdict is keyed by claim (request and role)."),
    Rule("paid_provisional", "row", "needs a positive anchor on the row itself."),
    Rule("per_role_split", "row", "decides role by role inside one request."),
    Rule("never_re_ask", "user (already)", "decide.filter_support: one ask per user, proof on file holds the user."),
    Rule("approval_caps", "user (already)", "per-user and fleet daily caps are counters, applied in order."),
    Rule("account_gate", "user (already)", "account_gate.Cached: one gate call per account per run."),
)


@dataclass(frozen=True)
class Answer:
    """What the stored-fact rules say about ONE row. ``decision`` is '' for ``per_row`` (not decided here)."""
    rule: str
    decision: str
    reason: str
    live: str = LIVE_NONE

    @property
    def decided(self) -> bool:
        return self.rule != PER_ROW


_PER_ROW = Answer(PER_ROW, "", PER_ROW_REASON)


def _walk(vd: Any, user_denied: bool, profile_denied: bool, has_track: bool) -> Answer:
    """The stored-fact ladder, in decide.run's order. The ONE place that order is written for both units."""
    rejected = validator_rejected_rules(vd)
    if rejected:
        return Answer(REJECT_RULE, "hold", reject_hold_reason(rejected), LIVE_NONE)
    if user_denied:
        return Answer(DENY_USER, "support", DENY_USER_REASON, LIVE_EVIDENCE)
    if profile_denied:
        return Answer(DENY_PROFILE, "support", DENY_PROFILE_REASON, LIVE_EVIDENCE)
    if not has_track:
        return Answer(NO_TRACK, "defer", NO_TRACK_REASON, LIVE_EVIDENCE)
    conflict = validator_conflict(vd)
    if conflict:
        return Answer(CONFLICT, "support", conflict_reason(conflict), LIVE_TRACK)
    return _PER_ROW


def _user_id(row: dict[str, Any]) -> int | None:
    uid = row.get("userId")
    return uid if isinstance(uid, int) and not isinstance(uid, bool) else None


def row_answer(row: dict[str, Any], policy: Any) -> Answer:
    """TODAY'S UNIT: one walk for one row, on the full row, reading it the way the per-row path does
    (decide.base_decision / request_decision for the user id, EvidenceBuilder.build for profile and track)."""
    uid = row.get("userId")
    uid = uid if isinstance(uid, int) else None
    return _walk(row.get("verificationData"),
                 uid is not None and uid in policy.deny_user_ids,
                 str(row.get("profileId") or "").lower() in policy.deny_profile_ids,
                 bool(str(row.get("trackId") or "")))


# --- the view: the stored facts the ladder reads, and nothing else ----------------------------------
_SCORE_KEYS = ("track_credit", "collaborations")


def _plain_number(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def row_view(row: dict[str, Any], policy: Any) -> tuple[Any, ...] | None:
    """The hashable signature of the stored facts the ladder reads from this row, or None when the row
    is AMBIGUOUS (walked on its own, and counted).

    Two rows of one person with the same view get the same answer by construction: the walk is given
    the view and never the row. The view keeps each fact VERBATIM (a rule score is its number, or the
    JSON null the validator writes for a rule with no score); what a value means is left to the rule
    functions. A fact that is not in that shape is never normalised into a group - a rule score that is
    a string or a boolean, a verificationData that is not an object, an id of the wrong type each send
    the row to the per-row path, which reads it exactly as it does today.
    """
    vd = row.get("verificationData")
    if not isinstance(vd, dict) or _user_id(row) is None:
        return None
    rules = vd.get("rule_risk_percent", {})
    errors = vd.get("rule_errors", {})
    if rules is None:
        rules = {}
    if errors is None:
        errors = {}
    if not isinstance(rules, dict) or not isinstance(errors, dict):
        return None
    pid, tid = row.get("profileId"), row.get("trackId")
    if not (pid is None or isinstance(pid, str)) or not (tid is None or isinstance(tid, str)):
        return None
    read = []
    for k, v in rules.items():
        if not isinstance(k, str):
            return None
        if k in _SCORE_KEYS or k.startswith(HOLD_RULE_PREFIX) or k.startswith(REJECT_RULE_PREFIX):
            if v is not None and not _plain_number(v):     # null = "no score": canonical, kept verbatim
                return None
            read.append((k, v))
    if any(not isinstance(k, str) for k in errors):
        return None
    read.sort()
    return (tuple(read), HOLD_ON_ERROR_KEY in errors, (pid or "").lower() in policy.deny_profile_ids, bool(tid))


def view_answer(view: tuple[Any, ...], user_denied: bool) -> Answer:
    """One walk for a whole group. It is handed the VIEW, so it cannot read a field the view left out."""
    rules, hold_on_error, profile_denied, has_track = view
    vd = {"rule_risk_percent": dict(rules), "rule_errors": {HOLD_ON_ERROR_KEY: True} if hold_on_error else {}}
    return _walk(vd, user_denied, profile_denied, has_track)


# --- cohorts (the census labels; a label, never an input to a decision) -----------------------------
R8_VOLUME, R8_HARD, SCORE_ONLY, NAMED_REVIEW, NO_CODES = "r8_volume", "r8_hard", "score_only", "named_review", "other"
COHORTS = (R8_VOLUME, R8_HARD, SCORE_ONLY, NAMED_REVIEW, NO_CODES)
VOLUME_CODE = "review_hourly_velocity_profile"
SCORE_CODE = "risk_score_at_or_above_threshold"


def cohort(row: dict[str, Any]) -> str:
    """The held-by-reason cohort of a row, from the validator's own ``hold_reason_codes``.

    This reproduces the paid-queue census labels (firstmate paid-sla-closer tick) from the row; the
    census script is not in this repository, so the mapping is pinned by the numbers it reproduces
    (docs/credit-verification/user-level-decisions.md), not by shared code.
    """
    vd = row.get("verificationData")
    codes = vd.get("hold_reason_codes") if isinstance(vd, dict) else None
    codes = [str(c) for c in codes] if isinstance(codes, list) else []
    if not codes:
        return NO_CODES
    if VOLUME_CODE in codes:
        return R8_VOLUME
    if any(c.startswith(REJECT_RULE_PREFIX) for c in codes):
        return R8_HARD
    if SCORE_CODE in codes:
        return SCORE_ONLY
    return NAMED_REVIEW


# --- one person --------------------------------------------------------------------------------------
@dataclass
class UserVerdict:
    """One person's verdict: every open row they hold, answered. ``answers`` is row for row (the effect);
    ``groups`` is what a reader works from (one line per distinct answer, with the rows it covers)."""
    user_id: int | None
    answers: list[tuple[str, Answer]] = field(default_factory=list)      # (request id, answer), input order
    fallback: list[str] = field(default_factory=list)                    # request ids walked per row (ambiguous)
    walks: int = 0                                                       # ladder walks spent on this person
    cohorts: Counter = field(default_factory=Counter)

    @property
    def rows(self) -> int:
        return len(self.answers)

    @property
    def groups(self) -> list[tuple[Answer, list[str]]]:
        out: dict[Answer, list[str]] = {}
        for rid, a in self.answers:
            out.setdefault(a, []).append(rid)
        return sorted(out.items(), key=lambda kv: (-len(kv[1]), kv[0].rule, kv[0].reason))

    @property
    def per_row(self) -> int:
        return sum(1 for _, a in self.answers if not a.decided)

    @property
    def uniform(self) -> bool:
        """One answer covers every row this person holds."""
        return len({a for _, a in self.answers}) == 1


def decide_user(user_id: int | None, rows: Sequence[dict[str, Any]], policy: Any) -> UserVerdict:
    """One person, all their rows. The user-scope fact is read once; each group of rows that share the
    stored facts the ladder reads is walked once; an ambiguous row is walked on its own and counted."""
    v = UserVerdict(user_id=user_id)
    user_denied = user_id is not None and user_id in policy.deny_user_ids
    seen: dict[tuple[Any, ...], Answer] = {}
    for row in rows:
        rid = str(row.get("id"))
        v.cohorts[cohort(row)] += 1
        view = row_view(row, policy) if user_id is not None else None
        if view is None:
            v.fallback.append(rid)
            v.walks += 1
            v.answers.append((rid, row_answer(row, policy)))
            continue
        a = seen.get(view)
        if a is None:
            a = seen[view] = view_answer(view, user_denied)
            v.walks += 1
        v.answers.append((rid, a))
    return v


# --- a queue -----------------------------------------------------------------------------------------
@dataclass
class Plan:
    verdicts: list[UserVerdict]
    answers: list[Answer]            # aligned with the input rows: the row-level effect

    @property
    def rows(self) -> int:
        return len(self.answers)

    @property
    def users(self) -> int:
        return sum(1 for v in self.verdicts if v.user_id is not None)

    @property
    def walks(self) -> int:
        return sum(v.walks for v in self.verdicts)

    @property
    def fallback(self) -> int:
        return sum(len(v.fallback) for v in self.verdicts)


def decide_users(rows: Sequence[dict[str, Any]], policy: Any) -> Plan:
    """THE NEW UNIT. Rows are grouped by person (first-seen order), each person is decided once, and
    the answers come back aligned with ``rows`` so the caller writes the effect per row as before.
    Rows with no readable user id cannot be attributed to a person: each is its own fallback."""
    by_user: dict[int | None, list[int]] = {}
    for i, row in enumerate(rows):
        by_user.setdefault(_user_id(row), []).append(i)
    answers: list[Answer | None] = [None] * len(rows)
    verdicts = []
    for uid, idx in by_user.items():
        v = decide_user(uid, [rows[i] for i in idx], policy)
        for i, (_, a) in zip(idx, v.answers):
            answers[i] = a
        verdicts.append(v)
    return Plan(verdicts=verdicts, answers=answers)  # type: ignore[arg-type]


def decide_rows(rows: Sequence[dict[str, Any]], policy: Any) -> list[Answer]:
    """Today's unit over a queue: one walk per row."""
    return [row_answer(row, policy) for row in rows]


# --- equivalence, then speed -------------------------------------------------------------------------
@dataclass
class Equivalence:
    rows: int
    users: int
    agree: int
    disagreements: list[dict[str, Any]]
    walks_per_row: int
    walks_per_user: int
    fallback: int
    seconds_per_row: float
    seconds_per_user: float
    answers: dict[str, int]
    uniform_users: int
    per_row_rows: int

    @property
    def equivalent(self) -> bool:
        return not self.disagreements and self.agree == self.rows

    def as_dict(self) -> dict[str, Any]:
        d = dict(self.__dict__)
        d["equivalent"] = self.equivalent
        d["disagreements"] = self.disagreements[:50]
        d["disagreement_count"] = len(self.disagreements)
        return d


def _best(fn, repeat: int) -> tuple[Any, float]:
    out, best = None, math.inf
    for _ in range(max(1, repeat)):
        t = time.perf_counter()
        out = fn()
        best = min(best, time.perf_counter() - t)
    return out, best


def equivalence(rows: Sequence[dict[str, Any]], policy: Any, repeat: int = 5) -> Equivalence:
    """Per-row answers against the per-user answers, ROW FOR ROW, on the same rows in the same process.

    Agreement is on the whole answer (rule, decision, reason, live read). A disagreement is a defect in
    the user-level pass and is returned, never averaged away. The two clocks are the best of ``repeat``
    passes of each unit over the same list, so they compare the units and not a cold cache.
    """
    before, t_row = _best(lambda: decide_rows(rows, policy), repeat)
    plan, t_user = _best(lambda: decide_users(rows, policy), repeat)
    bad = [{"request_id": str(r.get("id")), "user_id": r.get("userId"), "cohort": cohort(r),
            "per_row": [b.rule, b.decision, b.reason, b.live], "per_user": [a.rule, a.decision, a.reason, a.live]}
           for r, b, a in zip(rows, before, plan.answers) if a != b]
    return Equivalence(
        rows=len(rows), users=plan.users, agree=len(rows) - len(bad), disagreements=bad,
        walks_per_row=len(rows), walks_per_user=plan.walks, fallback=plan.fallback,
        seconds_per_row=t_row, seconds_per_user=t_user,
        answers=dict(Counter(a.rule for a in plan.answers)),
        uniform_users=sum(1 for v in plan.verdicts if v.user_id is not None and v.uniform),
        per_row_rows=sum(1 for a in plan.answers if not a.decided))


def by_cohort(rows: Iterable[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    out: dict[str, list[dict[str, Any]]] = {c: [] for c in COHORTS}
    for r in rows:
        out[cohort(r)].append(r)
    return out


def sample_users(rows: Sequence[dict[str, Any]], per_cohort: int) -> list[dict[str, Any]]:
    """Every row of the ``per_cohort`` users holding the most rows in each cohort, plus the same number
    holding the fewest. Deterministic (ties by user id), and whole people: a sampled user brings all
    their rows, in every cohort, because the unit under test is the person."""
    chosen: set[int] = set()
    for members in by_cohort(rows).values():
        n = Counter(u for u in (_user_id(r) for r in members) if u is not None)
        ranked = sorted(n, key=lambda u: (-n[u], u))
        chosen.update(ranked[:per_cohort])
        chosen.update(ranked[-per_cohort:] if per_cohort else [])
    return [r for r in rows if _user_id(r) in chosen]


# --- what the unit does to a queue (the report) ------------------------------------------------------
def summary(rows: Sequence[dict[str, Any]], policy: Any) -> dict[str, Any]:
    """What one verdict per person does to ``rows``: how many people, how many ladder walks, how many
    lines a reader works from (one per distinct answer a person holds), and how much stays per-row."""
    plan = decide_users(rows, policy)
    people = [v for v in plan.verdicts if v.user_id is not None]
    return {
        "rows": plan.rows, "users": plan.users, "walks_per_row": plan.rows, "walks_per_user": plan.walks,
        "fallback": plan.fallback,
        "worklist_lines": sum(len(v.groups) for v in plan.verdicts),
        "users_one_answer": sum(1 for v in people if v.uniform),
        "users_fully_decided": sum(1 for v in people if v.per_row == 0),
        "users_all_per_row": sum(1 for v in people if v.per_row == v.rows),
        "rows_decided": sum(1 for a in plan.answers if a.decided),
        "rows_per_row": sum(1 for a in plan.answers if not a.decided),
        "answers": dict(sorted(Counter(f"{a.decision or 'per_row'}:{a.rule}" for a in plan.answers).items())),
    }


# --- the replica snapshot (read-only) ----------------------------------------------------------------
COURT_UNVERIFIED, COURT_PAID_HELD = "unverified", "paid-held"
_SNAPSHOT_KEYS = ("rule_risk_percent", "rule_errors", "hold_reason_codes")


def snapshot_sql(court: str = COURT_UNVERIFIED) -> str:
    """Every open ``unverified`` row with a validator verdict (the decider's population), or with
    ``paid-held`` the paid-queue census's held court (paid workspace, no proof submitted). It carries
    the fields this module reads and nothing else; each JSON value travels base64 so no quoting of
    the transport can change it, and a key that is absent stays absent (an empty cell)."""
    if court not in (COURT_UNVERIFIED, COURT_PAID_HELD):
        raise ValueError(f"unknown court {court!r}")
    cells = ", ".join("to_base64(to_utf8(coalesce(json_format(json_extract(cr.verificationdata, "
                      f"'$.{k}')), '')))" for k in _SNAPSHOT_KEYS)
    sql = ("SELECT CAST(cr.id AS varchar), CAST(cr.userid AS varchar), CAST(cr.profileid AS varchar), "
           "CAST(cr.trackid AS varchar), substr(json_format(cr.verificationdata), 1, 1), " + cells + " "
           "FROM postgresql_core.public.credit_requests cr "
           "WHERE cr.status = 'unverified' AND cr.deletedat IS NULL AND cr.verificationdata IS NOT NULL")
    if court == COURT_PAID_HELD:
        sql += (" AND coalesce(json_extract_scalar(cr.metadata, '$.proofRequest.proofUploadedAt'), "
                "json_extract_scalar(cr.metadata, '$.proofRequest.responseAt'), "
                "json_extract_scalar(cr.metadata, '$.infoRequest.responseAt')) IS NULL "
                "AND cr.workspaceid IN (SELECT teamid FROM postgresql_core.public.subscriptions "
                "WHERE status IN ('active', 'trialing'))")
    return sql


def parse_snapshot(stdout: str) -> list[dict[str, Any]]:
    """Rows in the admin shape the decider reads (id, userId, profileId, trackId, verificationData).
    A line that cannot be read RAISES: a dropped row would be a row nobody compared, and "we could not
    read it" must never look like "it agreed".

    The replica's stdout is CSV and nothing else - the jline banner the wrapper emits goes to stderr
    (measured: `trino-query.sh "SELECT 1 AS a, 'x' AS b"` prints `"1","x"` on stdout and the banner on
    stderr), so every line here must begin with a quoted id. A line that does not is an unexpected
    transport error, and skipping it would let `snapshot` write a PARTIAL file that `equivalence` then
    proves 0 disagreements over. So it raises and names the line."""
    import base64
    import csv
    import io
    import json
    out = []
    lines = stdout.splitlines()
    for index, line in enumerate(lines, start=1):
        if not line.startswith('"'):
            raise ValueError(f"snapshot line {index} is not a CSV row, refusing to drop it: {line[:80]!r}")
    for cells in csv.reader(io.StringIO("\n".join(lines))):
        if len(cells) != 5 + len(_SNAPSHOT_KEYS) or not cells[0]:
            raise ValueError(f"snapshot row has {len(cells)} cells, expected {5 + len(_SNAPSHOT_KEYS)}: {cells[:1]}")
        rid, uid, pid, tid, shape = cells[:5]
        vd: Any = None                                   # not an object: the per-row path reads it (fallback)
        if shape == "{":
            vd = {}
            for key, cell in zip(_SNAPSHOT_KEYS, cells[5:]):
                text = base64.b64decode(cell, validate=True).decode("utf-8")
                if text:
                    vd[key] = json.loads(text)
        out.append({"id": rid, "userId": int(uid) if uid.isdigit() else None, "profileId": pid or None,
                    "trackId": tid or None, "status": "unverified", "verificationData": vd})
    return out


def snapshot(trino_cmd: str, court: str = COURT_UNVERIFIED, timeout_s: int = 600) -> list[dict[str, Any]]:
    import subprocess
    p = subprocess.run([trino_cmd], input=snapshot_sql(court), capture_output=True, text=True,
                       timeout=timeout_s, check=False)
    if p.returncode != 0:
        raise RuntimeError(f"replica snapshot failed rc={p.returncode}: {p.stderr.strip()[-300:]}")
    rows = parse_snapshot(p.stdout)
    if not rows:
        raise RuntimeError("replica snapshot returned no rows: unmeasured, not an empty queue")
    return rows
