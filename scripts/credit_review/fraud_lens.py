"""The fraud lens on credit-status messaging (captain 2026-10-26 ~00:40Z "we must be monitoring
and validating requests with a fraud lens"; Fable ruling-intercom-external-id-1026 Ruling B).

Who must not be told anything about their credit requests, and who may be told only through the
document ask. One implementation, used by:
  - ``credit-review.py uvn-status`` (uvn_status.run): every user is passed through ``Lens`` right
    before their note is built, for every campaign;
  - ``credit-review.py fraud-lens``: builds the paid never-contacted population and splits it
    (held / ask-only / clean) BEFORE the census lists are made, as paid-wave-runner-p1 did by hand.

Verdict per user:
  held (never messaged, never closed: re-checked every run), when ANY of
    1. watchlist: the user id, the account email, or a profile on any of their open requests is in
       policies/fraud-watchlist.json (both tiers; credit_review/watchlist.py, missing = fatal), or the
       user id is in policies/fraud-lens-holds.json (named a1 / s1 / brief accounts, messaging only);
    2. velocity above the band (s1 levels, 90 days, one profile, one UTC day): more than VEL_ROWS
       rows (level B'), or more than VEL_BIG big-track rows, popularity >= VEL_BIG_POP (level C);
    3. big-track claim on a single signal on SINGLE_SIGNAL_HOLD_MIN (10) or more OPEN rows
       (Fable Ruling B.1; today 85599, 126307, 134346, 281827).
  ask_only: 1 to 9 such single-signal rows and not held (Fable Ruling B.2). They are released, but
    only to the uvn-status document ask: never Copy A (status-doc-received) or Copy B0
    (status-team-review), so nothing we send implies approval.

A single-signal row: an OPEN request (not approved / rejected, not deleted) with
spotifyPopularity >= BIG_POP whose verificationData carries a hold code in SINGLE_SIGNAL_CODES (no
trusted source: the claim is the only signal) or whose support is one shortcut_source.

Read-only: it queries the core replica (Trino) and the verify ledger, and writes only the files
named on the command line.
"""
from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable

from . import verify_notify, watchlist as watchlist_mod

Query = verify_notify.Query

BIG_POP = 60
SINGLE_SIGNAL_CODES = ("review_big_track_without_trusted_credit", "review_big_track_weak_footprint")
SINGLE_SIGNAL_HOLD_MIN = 10   # Fable Ruling B.1: >= 10 open single-signal rows stay fraud-held
VEL_DAYS = 90
VEL_ROWS = 300                # s1 level B': rows per profile per UTC day
VEL_BIG = 10                  # s1 level C: big-track rows per profile per UTC day
VEL_BIG_POP = 70
HOLDS_DEFAULT = Path(__file__).resolve().parents[2] / "policies" / "fraud-lens-holds.json"
OPEN = "deletedat IS NULL AND status NOT IN ('approved','rejected')"


@dataclass
class Verdict:
    held: list[str] = field(default_factory=list)
    single_signal_rows: int = 0

    @property
    def ask_only(self) -> bool:
        return not self.held and self.single_signal_rows > 0


def load_holds(path: Path | str | None = None) -> dict[int, str]:
    """{user id: reason} from policies/fraud-lens-holds.json. Missing or malformed = ValueError:
    a broken hold list must never read as "nobody is held"."""
    p = Path(path) if path else HOLDS_DEFAULT
    if not p.exists():
        raise ValueError(f"fraud-lens holds missing: {p}")
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ValueError(f"fraud-lens holds unreadable: {p}: {exc}") from exc
    entries = doc.get("entries") if isinstance(doc, dict) else None
    if not isinstance(entries, list) or not entries:
        raise ValueError(f"fraud-lens holds {p}: no entries list")
    out: dict[int, str] = {}
    for i, e in enumerate(entries):
        if not isinstance(e, dict) or not str(e.get("reason") or "").strip() or not str(e.get("evidence") or "").strip():
            raise ValueError(f"fraud-lens holds {p}: entry {i} lacks reason or evidence")
        users = e.get("user_ids")
        if not isinstance(users, list) or not users or not all(isinstance(u, int) and not isinstance(u, bool) for u in users):
            raise ValueError(f"fraud-lens holds {p}: entry {i} needs a non-empty list of integer user_ids")
        for u in users:
            out.setdefault(u, str(e["reason"]))
    return out


def _vd(raw: Any) -> Any:
    v: Any = raw
    for _ in range(2):
        if not isinstance(v, str):
            break
        try:
            v = json.loads(v)
        except ValueError:
            return None
    return v


def single_signal(pop: Any, verification_data: Any) -> bool:
    """A big-track (popularity >= BIG_POP) row whose only support is the claim: a single-signal
    hold code, or a lone shortcut_source. An unparseable verificationData is not single-signal
    here (the lens is a messaging hold; the approval bar is enforced elsewhere)."""
    p = str(pop if pop is not None else "").strip()
    if not p.lstrip("-").isdigit() or int(p) < BIG_POP:
        return False
    vd = _vd(verification_data)
    if not isinstance(vd, dict):
        return False
    codes = vd.get("hold_reason_codes")
    if isinstance(codes, list) and any(c in SINGLE_SIGNAL_CODES for c in codes):
        return True
    return vd.get("shortcut_source") not in (None, "")


def verdict(*, watch: Iterable[str] = (), max_rows_day: int = 0, max_big_day: int = 0,
            single_signal_rows: int = 0) -> Verdict:
    """The pure rule (tested): see the module docstring."""
    held = list(watch)
    if max_rows_day > VEL_ROWS:
        held.append(f"velocity above band: {max_rows_day} rows on one profile in one UTC day (> {VEL_ROWS}, s1 level B')")
    if max_big_day > VEL_BIG:
        held.append(f"velocity above band: {max_big_day} big-track (pop>={VEL_BIG_POP}) rows on one profile in one "
                    f"UTC day (> {VEL_BIG}, s1 level C)")
    if single_signal_rows >= SINGLE_SIGNAL_HOLD_MIN:
        held.append(f"big-track claim on a single signal: {single_signal_rows} open row(s) pop>={BIG_POP} "
                    f"(>= {SINGLE_SIGNAL_HOLD_MIN})")
    return Verdict(held=sorted(set(held)), single_signal_rows=single_signal_rows)


def _ids(xs: Iterable[int]) -> str:
    return ",".join(str(int(x)) for x in xs)


class Lens:
    """Replica-backed lens: ``lens(user_ids) -> {user_id: Verdict}`` (every id gets a verdict).
    A replica error propagates: the caller sends nothing."""

    def __init__(self, query: Query, wl: watchlist_mod.Watchlist, holds: dict[int, str]):
        self.query, self.wl, self.holds = query, wl, holds

    def __call__(self, user_ids: list[int]) -> dict[int, Verdict]:
        ids = sorted({int(u) for u in user_ids})
        watch: dict[int, list[str]] = {u: [] for u in ids}
        rows_day: dict[int, int] = {}
        big_day: dict[int, int] = {}
        single: dict[int, int] = {}
        for u in ids:
            if u in self.wl.user_ids:
                watch[u].append("watchlist " + ("fraud" if u in self.wl.fraud_user_ids else "review") + " user")
            if u in self.holds:
                watch[u].append(f"fraud-lens hold: {self.holds[u]}")
        for i in range(0, len(ids), 400):
            chunk = _ids(ids[i:i + 400])
            if self.wl.email_sha256 or self.wl.email_domains:
                for uid, email in self.query(f"SELECT CAST(id AS varchar), lower(email) FROM postgresql_core.public.users "
                                             f"WHERE id IN ({chunk})"):
                    if self.wl.email_hit(email or ""):
                        watch[int(uid)].append("watchlist email")
            for uid, pid, pop, vd in self.query(
                    "SELECT CAST(userid AS varchar), CAST(profileid AS varchar), CAST(spotifypopularity AS varchar), "
                    "json_format(CAST(verificationdata AS json)) FROM postgresql_core.public.credit_requests "
                    f"WHERE {OPEN} AND userid IN ({chunk})"):
                u = int(uid)
                if pid and pid.strip().lower() in self.wl.profile_ids:
                    tier = "fraud" if pid.strip().lower() in self.wl.fraud_profile_ids else "review"
                    watch[u].append(f"watchlist {tier} profile on an open request")
                if single_signal(pop, vd):
                    single[u] = single.get(u, 0) + 1
            for uid, mx, mxbig in self.query(
                    "SELECT CAST(userid AS varchar), CAST(max(n) AS varchar), CAST(max(nbig) AS varchar) FROM ("
                    "SELECT userid, profileid, date(createdat AT TIME ZONE 'UTC') d, count(*) n, "
                    f"sum(CASE WHEN spotifypopularity >= {VEL_BIG_POP} THEN 1 ELSE 0 END) nbig "
                    "FROM postgresql_core.public.credit_requests "
                    f"WHERE createdat > current_timestamp - INTERVAL '{VEL_DAYS}' DAY AND userid IN ({chunk}) "
                    "GROUP BY 1, 2, 3) GROUP BY 1"):
                rows_day[int(uid)] = int(mx or 0)
                big_day[int(uid)] = int(mxbig or 0)
        return {u: verdict(watch=watch[u], max_rows_day=rows_day.get(u, 0), max_big_day=big_day.get(u, 0),
                           single_signal_rows=single.get(u, 0)) for u in ids}


def null_lens(user_ids: list[int]) -> dict[int, Verdict]:
    """Holds nobody (tests of unrelated runner behaviour only)."""
    return {int(u): Verdict() for u in user_ids}


LensFn = Callable[[list[int]], dict[int, Verdict]]


def default_lens(query: Query, *, watchlist_path: str | None = None, holds_path: str | None = None) -> LensFn:
    """The deployed lens: the watchlist (credit_review/watchlist.py, REQUIRED: missing or malformed
    = ValueError) plus the messaging holds (missing or malformed = ValueError)."""
    wl = watchlist_mod.load(watchlist_path, required=True)
    return Lens(query, wl, load_holds(holds_path))


# -- population (paid-wave-runner-p1's G9 definition, credit-trust-llm-t01) -------------------

PAID_TEAMS = ("(SELECT DISTINCT s.teamid FROM postgresql_core.public.subscriptions s "
              "WHERE s.status IN ('active','trialing'))")


def paid_never_contacted(query: Query, ledger_path: str, *, since: str) -> tuple[list[int], dict[str, int]]:
    """Paid-workspace users with an open credit request, no core ask (proofRequest.noticeSentAt /
    responseAt, infoRequest.responseAt) and no `sent` verify_messages row since `since`."""
    rows = query(
        "SELECT CAST(cr.userid AS varchar), CAST(max(CASE WHEN coalesce("
        "json_extract_scalar(cr.metadata,'$.proofRequest.noticeSentAt'), "
        "json_extract_scalar(cr.metadata,'$.proofRequest.responseAt'), "
        "json_extract_scalar(cr.metadata,'$.infoRequest.responseAt')) IS NOT NULL THEN 1 ELSE 0 END) AS varchar) "
        f"FROM postgresql_core.public.credit_requests cr WHERE cr.deletedat IS NULL "
        f"AND cr.status NOT IN ('approved','rejected') AND cr.workspaceid IN {PAID_TEAMS} GROUP BY 1")
    users = {int(r[0]): r[1] == "1" for r in rows if str(r[0]).isdigit()}
    db = sqlite3.connect(f"file:{ledger_path}?mode=ro", uri=True)
    try:
        sent = {int(a) for (a,) in db.execute(
            "SELECT account_id FROM verify_messages WHERE status='sent' AND created_at >= ?", (since,))
            if a is not None and str(a).strip().isdigit()}
    finally:
        db.close()
    never = sorted(u for u, asked in users.items() if not asked and u not in sent)
    return never, {"paid_pending_users": len(users), "ledger_contacted": len(sent & set(users)),
                   "paid_never_contacted": len(never)}


def split(user_ids: list[int], lens: LensFn) -> dict[str, Any]:
    """{held: [{user_id, reasons}], ask_only: [ids], clean: [ids], counts}."""
    verdicts = lens(user_ids)
    held = [{"user_id": u, "reasons": verdicts[u].held} for u in sorted(verdicts) if verdicts[u].held]
    ask = sorted(u for u, v in verdicts.items() if v.ask_only)
    clean = sorted(u for u, v in verdicts.items() if not v.held and not v.ask_only)
    by: dict[str, int] = {}
    for h in held:
        for r in {r.split(":")[0] for r in h["reasons"]}:
            by[r] = by.get(r, 0) + 1
    return {"held": held, "ask_only": ask, "clean": clean,
            "counts": {"users": len(verdicts), "fraud_held": len(held), "ask_only": len(ask), "clean": len(clean),
                       "held_by_reason": by}}
