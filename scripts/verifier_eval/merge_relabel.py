"""Independent ground truth for the merges set, from today's facts (PURE; no I/O).

Input: the facts snapshot written by ``scripts/verifier-eval-merge-facts.py`` (core read replica +
catalog, profiles per item taken from m1's own ticket file, never from a verifier's output).
Output per item: what the owner-confirmed self-serve merge SHOULD answer today, in the endpoint's
vocabulary - ``eligible`` (would execute) / ``queued_review`` / ``already_merged`` /
``refused:<CODE>`` - plus, for (ticket, loser) pairs, what core's admin merge route answers
(``409`` / ``accepts``, core's findLoginOrPrimaryLosers rule with its same-user exemption).

Rules = the product contract as written down (self-merge-1026 v1 contract, Fable ruling
q1-merge-fable-1027 "never fold a populated profile into an empty shell", core's 2026-10-13
login/primary guard), computed here from raw rows. Where the contract needs evidence this module
does not read (same-person evidence from shared recordings, staff holds when the table is absent),
it says so in ``basis`` and lands on the side that does NOT act.
"""

from __future__ import annotations

from typing import Any

OPEN = {"pending", "intent_pending"}
IN_FLIGHT = {"requested", "enqueued", "callback_received", "stale"}
MIN_PROFILES, MAX_PROFILES = 2, 10
REVIEW_CREDIT_THRESHOLD = 5000


def _l(x: Any) -> str:
    return str(x or "").lower()


class Facts:
    def __init__(self, f: dict[str, Any], watchlist_users: set[str] | None = None, strict_holds: bool = True):
        self.cat = {_l(k): v for k, v in (f.get("profiles") or {}).items()}
        self.claims: dict[str, list[dict[str, Any]]] = {}
        for c in f.get("claims") or []:
            self.claims.setdefault(_l(c["profileId"]), []).append(c)
        self.login: dict[str, set[str]] = {}
        for r in f.get("login") or []:
            self.login.setdefault(_l(r["profileId"]), set()).add(str(r["userId"]))
        self.primary: dict[str, set[str]] = {}
        for r in f.get("primary") or []:
            self.primary.setdefault(_l(r["profileId"]), set()).add(str(r["userId"]))
        self.admin_teams: dict[str, set[str]] = {}
        for r in f.get("admins") or []:
            self.admin_teams.setdefault(str(r["userId"]), set()).add(_l(r["teamId"]))
        self.default_team = {str(r["userId"]): _l(r["teamId"]) for r in f.get("default_teams") or [] if r.get("teamId")}
        self.paid: dict[str, set[str]] = {}
        for r in f.get("paid_seats") or []:
            self.paid.setdefault(_l(r["profileId"]), set()).add(_l(r["teamId"]))
        self.in_flight: set[str] = set()
        for m in f.get("profile_merges") or []:
            if m.get("status") in IN_FLIGHT:
                self.in_flight |= {_l(m["survivor"]), _l(m["loser"])}
        self.holds = {_l(r["profileId"]) for r in f.get("staff_holds") or []}
        # A hold source that could not be read is not an empty hold list: `strict_holds` decides what an
        # unread gate means (see would_execute). `staff_hold_table` records WHICH source answered, so a
        # snapshot says "no holds" or "not read" and never blurs the two.
        self.holds_known = bool(f.get("staff_hold_table_present"))
        self.holds_source = f.get("staff_hold_table")
        self.strict_holds = strict_holds
        self.watch = watchlist_users or set()

    def owners(self, p: str) -> set[str]:
        """Users whose login or presented primary this profile is (core's protected set)."""
        return self.login.get(p, set()) | self.primary.get(p, set())


def core_admin_route(keep: str, losers: list[str], fx: Facts) -> str:
    """core POST /admin/profiles/merge LOGIN_OR_PRIMARY_LOSER: refuse when a loser is some user's
    login/primary unless the survivor is that same user's login/primary."""
    survivor_owners = fx.owners(keep)
    for lo in losers:
        if fx.owners(lo) - survivor_owners:
            return "409"
    return "accepts"


def _requester(keep: str, losers: list[str], fx: Facts) -> tuple[str | None, str]:
    for scope, ids in (("processed_on_keep", [keep]), ("processed_on_duplicate", losers)):
        users = {str(c["userId"]) for p in ids for c in fx.claims.get(p, [])
                 if c.get("status") == "processed" and c.get("userId") is not None}
        if len(users) == 1:
            return users.pop(), scope
        if len(users) > 1:
            return None, f"ambiguous_{scope}"
    return None, "no_processed_claim_with_user"


def label(item: dict[str, Any], fx: Facts) -> dict[str, Any]:
    keep = _l(item.get("keep"))
    losers = [_l(x) for x in item.get("losers") or [] if x and _l(x) != keep]
    out: dict[str, Any] = {"basis": []}
    if item.get("kind") == "pair" and keep and losers:
        out["core"] = core_admin_route(keep, losers, fx)
    if not keep or not losers or len(losers) + 1 > MAX_PROFILES:
        return {**out, "label": "refused:TOO_MANY", "basis": ["profiles_outside_2_to_10"]}

    # 1. catalog state: forwarded / deleted losers
    kc = fx.cat.get(keep) or {}
    if kc.get("read") != "ok":
        return {**out, "label": "refused:SELF_MERGE_UNAVAILABLE", "basis": ["catalog_unread_keep"]}
    if kc.get("forwarded") or kc.get("deleted"):
        return {**out, "label": "refused:MERGE_IN_PROGRESS", "basis": ["keep_itself_merged_or_deleted"]}
    live = []
    for lo in losers:
        lc = fx.cat.get(lo) or {}
        if lc.get("read") != "ok":
            return {**out, "label": "refused:SELF_MERGE_UNAVAILABLE", "basis": [f"catalog_unread:{lo[:8]}"]}
        if lc.get("forwarded") or lc.get("deleted"):
            if _l(lc.get("served_id")) != keep:
                return {**out, "label": "refused:MERGE_IN_PROGRESS",
                        "basis": [f"loser_merged_into_other_survivor:{lo[:8]}"]}
            continue
        live.append(lo)
    if not live:
        return {**out, "label": "already_merged", "basis": ["every_loser_forwarded_to_keep"]}
    if len(live) < len(losers):
        out["basis"].append(f"partial_merge:{len(losers) - len(live)}_already_forwarded")
    losers = live
    allp = [keep, *losers]

    # 2. requester and the workspaces they manage
    user, basis = _requester(keep, losers, fx)
    out["requester"] = user
    out["basis"].append(f"requester:{basis}")
    managed = fx.admin_teams.get(user, set()) if user else set()

    # 3. per-profile reasons, contract order OPEN_CLAIM > NOT_CLAIMED > LEGAL_HOLD > ORG > IN_FLIGHT
    def reasons(p: str) -> list[str]:
        r = []
        cl = fx.claims.get(p, [])
        foreign = [c for c in cl if (c.get("status") == "processed" and _l(c.get("teamId")) not in managed)
                   or (c.get("status") in OPEN and str(c.get("userId")) != str(user))]
        if foreign or (fx.owners(p) - ({user} if user else set())):
            r.append("OPEN_CLAIM")
        if not any(c.get("status") == "processed" and _l(c.get("teamId")) in managed for c in cl):
            r.append("NOT_CLAIMED")
        if p in fx.holds:
            r.append("LEGAL_HOLD")
        sub = _l((fx.cat.get(p) or {}).get("subType"))
        if sub == "organization" or _l((fx.cat.get(p) or {}).get("type")) == "organization":
            r.append("ORG_PROFILE")
        if p in fx.in_flight:
            r.append("MERGE_IN_PROGRESS")
        return r

    per = {p: reasons(p) for p in allp}
    for code in ("OPEN_CLAIM", "NOT_CLAIMED", "LEGAL_HOLD", "ORG_PROFILE", "MERGE_IN_PROGRESS"):
        hit = [p[:8] for p, rs in per.items() if code in rs]
        if hit:
            return {**out, "label": f"refused:{code}", "basis": out["basis"] + [f"{code}:{','.join(hit)}"]}

    def would_execute(extra: list[str]) -> dict[str, Any]:
        """`eligible` only when every safety check that gates EXECUTION was actually read.

        The staff-hold table is one of those checks and it cannot be faked: with the table absent the
        holds list is empty for the wrong reason, so a legal hold could be sitting on any of these
        profiles. Answering `eligible` there would execute a merge nobody verified - so it lands on
        the side that does not act, in a class that says why.
        """
        if not fx.holds_known:
            why = f"staff_hold_source_absent:{fx.holds_source or 'none_found'}"
            if fx.strict_holds:
                return {**out, "label": "queued_review:LEGAL_HOLD_UNKNOWN",
                        "basis": out["basis"] + extra + [why]}
            return {**out, "label": "eligible", "basis": out["basis"] + extra + [why, "holds_assumed_clean"]}
        return {**out, "label": "eligible", "basis": out["basis"] + extra}

    # 4. same person type
    kt = _l(kc.get("type"))
    if any(_l((fx.cat.get(lo) or {}).get("type")) != kt or not kt for lo in losers):
        return {**out, "label": "refused:TYPE_MISMATCH", "basis": out["basis"] + ["type_differs"]}

    # 5. never fold a populated profile into an empty login shell
    credits = {p: (fx.cat.get(p) or {}).get("creditCount") for p in allp}
    if fx.login.get(keep) and not ((credits[keep] or 0) > 0):
        if any(credits[lo] != 0 for lo in losers):
            return {**out, "label": "refused:EMPTY_SHELL_MAIN", "basis": out["basis"] + ["keep_is_empty_login_shell"]}

    # 6. a loser that is the requester's own login/primary needs the keep to be their own claim
    own_identity_losers = [lo for lo in losers if user and user in fx.owners(lo)]
    if own_identity_losers and user not in fx.owners(keep):
        own_keep_claim = any(c.get("status") == "processed" and str(c.get("userId")) == user
                             for c in fx.claims.get(keep, []))
        if not own_keep_claim:
            return {**out, "label": "refused:PRIMARY_PROFILE", "basis": out["basis"] + ["own_identity_loser"]}
        out["basis"].append("needs_primary_switch")

    # 7. review triggers -> automatic extra checks
    triggers = []
    if any(c is None for c in credits.values()) or sum(c or 0 for c in credits.values()) > REVIEW_CREDIT_THRESHOLD:
        triggers.append("big_catalog")
    paid_losers = [lo for lo in losers if fx.paid.get(lo)]
    if paid_losers:
        triggers.append("paid_not_main")
    if user and user in fx.watch:
        triggers.append("watchlisted")
    own = fx.default_team.get(user or "")
    if not own or any(not any(c.get("status") == "processed" and _l(c.get("teamId")) == own for c in fx.claims.get(p, []))
                      for p in allp):
        triggers.append("workspace_claim")
    if not triggers:
        return would_execute(["no_review_trigger"])
    out["basis"].append("triggers:" + ",".join(triggers))
    foreign_paid = [lo[:8] for lo in paid_losers if fx.paid[lo] - managed]
    if foreign_paid:
        return {**out, "label": "refused:PAID_SEAT", "basis": out["basis"] + [f"foreign_paid:{','.join(foreign_paid)}"]}
    kr = set((kc.get("raw_ids") or []))
    if all(kr & set((fx.cat.get(lo) or {}).get("raw_ids") or []) for lo in losers):
        return would_execute(["same_person:shared_raw_dsp_id"])
    # Same-person evidence beyond shared raw DSP ids (shared recordings) is not read here: the side
    # that does not act.
    return {**out, "label": "queued_review", "basis": out["basis"] + ["same_person_not_proven_by_raw_ids"]}


def relabel_all(facts: dict[str, Any], watchlist_users: set[str] | None = None,
                strict_holds: bool = True) -> dict[str, dict[str, Any]]:
    """``strict_holds`` (default): an unread legal-hold source never yields `eligible`, because the
    empty list came from a missing table, not from a clean read. ``strict_holds=False`` is the
    sensitivity variant (core itself fails open on absent pre-migration tables) - use it to measure
    how much of an answer depends on a gate nothing could read, never as the shipped labels."""
    fx = Facts(facts, watchlist_users, strict_holds)
    return {k: label(v, fx) for k, v in (facts.get("items") or {}).items()}


def acts(verdict: str) -> bool:
    return verdict == "eligible"
