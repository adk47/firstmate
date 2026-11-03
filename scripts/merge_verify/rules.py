"""THE profile-merge verdict, PURE (no I/O): facts in, verdict + evidence + the exact command out.

One open merge request (a ClickUp `action:profile-merge` ticket: a keep profile and the duplicates
the requester named) is judged from already-read facts (collect.py live, snapshot.py frozen). The
order is profile-merge-ops-m1's 235-ticket re-read (data/profile-merge-ops-m1/merge-states-1028.md),
with core-backend's merge guards where core is stricter, then the per-duplicate checks a merge
needs before anybody may run it:

  ticket stage (first that applies)                       verdict                    eval
  0  a section the stage needs was not read               unknown                    UNKNOWN
  1  no keep / no duplicate / an id not in the catalog    needs_ids                  WAIT
  2  every duplicate already ends on the keep (ledger)    already_merged             WAIT (no-op)
  3  a profile or the requester on the fraud watchlist    held_watchlist             WAIT
  4  an organisation profile                              refused:ORG_PROFILE        DECLINE
  5  a profile without a processed claim                  needs_claim                WAIT
  6  claims in two workspaces / by two accounts, or       refused:OPEN_CLAIM         DECLINE
     another account's open claim
  7  a duplicate that is another account's login or       refused:LOGIN_OR_PRIMARY_  DECLINE
     confirmed presented primary (core's 409; exempt        LOSER
     when the keep is that same account's own)
  per duplicate (every one must pass for `eligible`)
  8  a merge already in flight / the keep merged away     wait:merge_in_flight       WAIT
  9  person type differs                                  refused:TYPE_MISMATCH      DECLINE
 10  populated duplicate into an empty login shell        refused:EMPTY_SHELL_MAIN   DECLINE
 11  paid by a workspace that is not the requester's      refused:PAID_SEAT          DECLINE
 12  owner confirmation: a thread of the requester's OWN  wait:owner_thread          WAIT
     (one contact, the account's email) names the keep
     AND this duplicate in the requester's own words
 13  big / common / flagged guard: popularity >= 60,      needs_human:<why>          WAIT
     keep has fewer credits (direction), a claim with
     screening risk flags (when the source carries them),
     another same-name profile claimed or with credits
     (census not read = UNKNOWN). Watchlist and the
     fraud-lens holds already held the ticket at stage 3
 14  same person on the DSPs: one Spotify or Tidal        needs_evidence:same_person WAIT
     artist identity on BOTH profiles
 15  everything above holds                               eligible                   APPROVE

UNKNOWN never approves: a fact that was not read is never "no problem". `fresh_read` says whether
every read was made in this run (the same-run anchor); a frozen snapshot is never fresh, so a
replay can measure `eligible` but marks it measurement-only. `eligible` is evidence for a human or
the self-serve path: nothing here runs the command, and core's POST /admin/profiles/merge (and the
self-serve route) re-check their own guards at execution.
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import asdict, dataclass, field
from typing import Any

RULE_VERSION = "mv-1"

APPROVE, DECLINE, WAIT, UNKNOWN = "APPROVE", "DECLINE", "WAIT", "UNKNOWN"
BIG_POPULARITY = 60
PERSON_DSP = ("spotify", "tidal")  # the captain's anchor: a Spotify or Tidal artist identity
IN_FLIGHT = ("requested", "enqueued", "callback_received", "unverified", "pending", "processing")
TOLD_TAGS = ("merge-outcome-notified", "customer-outcome:complete")
RELATION_ORDER = ("identical", "fold_equal", "near", "token_subset", "shared_token", "different")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
DEFAULT_EXECUTOR = "caroline@muso.ai"

# m1's state names, for the regression against merge-states-1028.md.
M1_STATE = {
    "needs_ids": "no-ids", "held_watchlist": "held-watchlist", "refused:ORG_PROFILE": "org-profile",
    "needs_claim": "needs-claim-first", "refused:OPEN_CLAIM": "contested",
    "refused:LOGIN_OR_PRIMARY_LOSER": "D2-login-loser", "unknown": "unknown",
}

NEXT = {
    "needs_ids": "ask the requester for the main and duplicate profile links (captain 1-4 wording)",
    "already_merged": "nothing to merge; tell the user only on ledger `verified`, via the approved merge-outcome copy",
    "held_watchlist": "held for review by policy (fraud watchlist); never merged automatically",
    "refused:ORG_PROFILE": "organisation/label profiles go through the organisations path, never this merge path",
    "needs_claim": "the requester claims each named profile first; re-judged when the claims process",
    "refused:OPEN_CLAIM": "two workspaces or claimants: the rule forbids the merge",
    "refused:LOGIN_OR_PRIMARY_LOSER": ("core 409: a duplicate is an account's login/primary; the self-serve "
                                       "presented-primary switch clears the requester's own"),
    "unknown": "a read failed or a fact was not read; re-run, never merge on it",
    "eligible": "a named human runs each command (one loser per call), or the requester uses self-serve once it is on",
    "partial": "some duplicates are eligible; the rest name their own blocker",
}


# ── names (a port of core identityEvidence.foldName / nameRelation) ──────────────────────────

def fold_name(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    s = "".join(ch for ch in unicodedata.normalize("NFKD", value) if not unicodedata.combining(ch)).lower()
    return " ".join("".join(ch if ch.isalnum() else " " for ch in s).split())


def _lev(a: str, b: str, cap: int) -> int:
    if abs(len(a) - len(b)) > cap:
        return cap + 1
    prev = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        cur = [i]
        for j in range(1, len(b) + 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] != b[j - 1])))
        if min(cur) > cap:
            return cap + 1
        prev = cur
    return prev[-1]


def name_relation(a: Any, b: Any) -> str:
    if isinstance(a, str) and isinstance(b, str) and a.strip() and a.strip() == b.strip():
        return "identical"
    fa, fb = fold_name(a), fold_name(b)
    if not fa or not fb:
        return "different"
    ca, cb = fa.replace(" ", ""), fb.replace(" ", "")
    if fa == fb or ca == cb:
        return "fold_equal"
    if len(ca) >= 5 and len(cb) >= 5 and _lev(ca, cb, 2) <= 2:
        return "near"
    ta, tb = set(fa.split()), set(fb.split())
    small, big = (ta, tb) if len(ta) <= len(tb) else (tb, ta)
    if small and small <= big:
        return "token_subset"
    if ta & tb:
        return "shared_token"
    return "different"


def best_name_relation(names_a: list[str], names_b: list[str]) -> str:
    best = "different"
    for x in names_a or []:
        for y in names_b or []:
            r = name_relation(x, y)
            if RELATION_ORDER.index(r) < RELATION_ORDER.index(best):
                best = r
    return best


# ── verdict shapes ────────────────────────────────────────────────────────────────────────────

@dataclass
class LoserVerdict:
    loser: str
    verdict: str                       # eligible | refused:<SLUG> | wait:<why> | needs_human:<why> | needs_evidence:<why> | unknown
    eval: str                          # APPROVE | DECLINE | WAIT | UNKNOWN
    reasons: list[str] = field(default_factory=list)
    basis: str | None = None           # the same-person basis (eligible only)
    command: str | None = None         # the exact merge command a named human would run (eligible only)
    self_serve: dict | None = None     # the call the requester's own session would make (eligible only)


@dataclass
class TicketVerdict:
    ticket: str
    verdict: str
    eval: str
    stage: str
    m1_state: str
    keep: str | None
    losers: list[LoserVerdict] = field(default_factory=list)
    reasons: list[str] = field(default_factory=list)
    fresh_read: bool = False
    rule_version: str = RULE_VERSION
    next_step: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def eval_of(verdict: str) -> str:
    if verdict == "eligible":
        return APPROVE
    if verdict.startswith("refused:"):
        return DECLINE
    if verdict == "unknown":
        return UNKNOWN
    return WAIT


def _low(x: Any) -> str:
    return str(x or "").strip().lower()


def _chain_end(pid: str, edges: dict[str, str]) -> str:
    seen = 0
    while pid in edges and seen < 20:
        pid, seen = edges[pid], seen + 1
    return pid


def _is_org(p: dict) -> bool:
    return _low(p.get("sub_type")) == "organization" or _low(p.get("type")) == "organization"


def _ids(p: dict, source: str) -> set[str]:
    return {str(x).strip() for x in (p.get(source) or []) if str(x or "").strip()}


def command_for(keep: str, loser: str, conv: Any, executor: str = DEFAULT_EXECUTOR) -> str:
    """The exact core-path line a named human runs on node-8 (edge env), one loser per call.
    `<captain handle>` stays a placeholder on purpose: no agent confirmer exists and the verifier
    never picks one."""
    if not (UUID.match(keep) and UUID.match(loser)):
        raise ValueError("command_for needs two full profile UUIDs")
    ref = f"{conv}|{RULE_VERSION}" if conv and str(conv).isdigit() else f"<conversation id>|{RULE_VERSION}"
    return (f"muso --env prod profiles merge --into {keep} --from {loser} --requester {executor} --yes "
            f"--confirmed-by <captain handle> --approval-ref '{ref}'")


def self_serve_for(keep: str, loser: str, user_id: Any) -> dict:
    """What the requester's own session would send on the self-serve path (FEATURE_SELF_MERGE is
    off: core answers 409 SELF_MERGE_SWITCHED_OFF until the captain turns it on), plus core's dry
    check for the same request."""
    return {"as_user": user_id, "method": "POST", "path": "/api/v4/user/profiles/merge",
            "body": {"mainProfileId": keep, "mergeProfileIds": [loser]},
            "dry_check": {"method": "POST", "path": "/admin/self-merge-requests/verify",
                          "body": {"userId": user_id, "mainProfileId": keep, "mergeProfileIds": [loser]}}}


# ── the rule ──────────────────────────────────────────────────────────────────────────────────

def decide(ticket: dict, *, fresh: bool = False, executor: str = DEFAULT_EXECUTOR) -> TicketVerdict:
    """The verdict for ONE open merge ticket. `fresh` = every read in `ticket` was made in this run.

    Fact sections (None = not read, which is never "nothing there"): profiles, merges, watchlist,
    claims, identity, paid, threads, pairs (see docs/credit-verification/merge-verify.md)."""
    keep = _low(ticket.get("keep")) or None
    dups = [d for d in dict.fromkeys(_low(x) for x in (ticket.get("dups") or [])) if d and d != keep]
    profiles: dict | None = ticket.get("profiles")
    claims: dict | None = ticket.get("claims")
    identity: list | None = ticket.get("identity")
    merges: list | None = ticket.get("merges")
    watch: dict | None = ticket.get("watchlist")
    tags = {_low(t) for t in (ticket.get("tags") or [])}

    def done(verdict: str, stage: str, reasons: list[str], m1_state: str | None = None,
             losers: list[LoserVerdict] | None = None) -> TicketVerdict:
        return TicketVerdict(ticket=str(ticket.get("ticket")), verdict=verdict, eval=eval_of(verdict), stage=stage,
                             m1_state=m1_state or M1_STATE.get(verdict, verdict), keep=keep, losers=losers or [],
                             reasons=reasons, fresh_read=bool(fresh), next_step=NEXT.get(verdict, ""))

    if not keep or not dups:
        return done("needs_ids", "1_ids", ["no keep/duplicate profile ids"])
    if profiles is None:
        return done("unknown", "0_read", ["unread:catalog"])
    sides = [keep] + dups
    unread = [u for u in sides if (profiles.get(u) or {}).get("found") is None]
    if unread:
        return done("unknown", "0_read", ["unread:catalog " + ",".join(u[:8] for u in unread)])
    missing = [u for u in sides if not profiles[u]["found"]]
    if missing:
        return done("needs_ids", "1_ids", ["id not in catalog: " + ",".join(u[:8] for u in missing)])

    if merges is None:
        return done("unknown", "0_read", ["unread:profile_merges"])
    edges = {_low(m["loser"]): _low(m["survivor"]) for m in merges if m.get("status") == "verified"}
    home = _chain_end(keep, edges)
    live = [d for d in dups if _chain_end(d, edges) != home]
    if not live:
        told = bool(tags & set(TOLD_TAGS))
        return done("already_merged", "2_ledger", ["every duplicate verifiably ends on the keep"],
                    m1_state="merged-told" if told else "merged-not-told")
    sides = [keep] + live

    if watch is None:
        return done("unknown", "0_read", ["unread:watchlist"])
    hits = sorted({_low(x) for x in (watch.get("profile_ids") or [])} & set(sides))
    if hits or watch.get("requester_hit"):
        return done("held_watchlist", "3_watchlist", (["watchlist " + ",".join(u[:8] for u in hits)] if hits else [])
                    + (["requester on the watchlist"] if watch.get("requester_hit") else []))

    org = [u for u in sides if _is_org(profiles[u])]
    if org:
        return done("refused:ORG_PROFILE", "4_org", ["organization " + ",".join(u[:8] for u in org)])

    if claims is None:
        return done("unknown", "0_read", ["unread:claims"])
    proc = {u: [c for c in claims.get(u) or [] if c.get("status") == "processed"] for u in sides}
    unclaimed = [u for u in sides if not proc[u]]
    if unclaimed:
        pending = [u for u in unclaimed if any(c.get("status") in ("pending", "intent_pending") for c in claims.get(u) or [])]
        why = "unclaimed " + ",".join(u[:8] for u in unclaimed if u not in pending)
        return done("needs_claim", "5_claim", [why + (" pending " + ",".join(u[:8] for u in pending) if pending else "")])
    teams = {_low(c.get("team_id")) for u in sides for c in proc[u]}
    users = {str(c.get("user_id")) for u in sides for c in proc[u] if c.get("user_id") not in (None, "")}
    if len(teams) > 1 or len(users) > 1:
        return done("refused:OPEN_CLAIM", "6_contested", [f"{len(teams)} workspaces / {len(users)} claimant users"])
    requester = next(iter(users), None)
    foreign_open = sorted({u[:8] for u in sides for c in claims.get(u) or []
                           if c.get("status") in ("pending", "intent_pending")
                           and str(c.get("user_id")) != str(requester) and _low(c.get("team_id")) not in teams})
    if foreign_open:
        return done("refused:OPEN_CLAIM", "6_contested", ["another account's open claim on " + ",".join(foreign_open)])

    if identity is None:
        return done("unknown", "0_read", ["unread:login_primary"])
    ident = [(_low(r.get("profile_id")), str(r.get("user_id")), r.get("kind")) for r in identity]
    keep_owners = {uid for pid, uid, _ in ident if pid == keep}
    login_losers = sorted({pid for pid, uid, _ in ident if pid in live and uid not in keep_owners})
    if login_losers:
        return done("refused:LOGIN_OR_PRIMARY_LOSER", "7_login_primary",
                    ["login/primary loser " + ",".join(u[:8] for u in login_losers)])

    # ── per duplicate ─────────────────────────────────────────────────────────────────────────
    in_flight = {_low(m["loser"]) for m in merges if m.get("status") in IN_FLIGHT} | \
                {_low(m["survivor"]) for m in merges if m.get("status") in IN_FLIGHT}
    paid: dict | None = ticket.get("paid")
    threads: list | None = ticket.get("threads")
    pairs: dict = ticket.get("pairs") or {}
    kp = profiles[keep]
    keep_is_login = any(pid == keep and kind == "login" and uid == str(requester) for pid, uid, kind in ident)
    flags = [c.get("flagged") for u in sides for c in proc[u]]
    flagged_claim = any(flags)
    flags_unread = any(f is None for f in flags)
    out: list[LoserVerdict] = []
    for loser in live:
        lp = profiles[loser]
        pair = pairs.get(loser) or {}

        def lv(verdict: str, why: list[str], **kw: Any) -> LoserVerdict:
            return LoserVerdict(loser=loser, verdict=verdict, eval=eval_of(verdict), reasons=why, **kw)

        if home != keep:
            out.append(lv("wait:merge_in_flight", [f"the keep {keep[:8]} itself was merged into {home[:8]}"]))
            continue
        if loser in in_flight or keep in in_flight:
            out.append(lv("wait:merge_in_flight", ["a profile_merges row on this pair is still in flight"]))
            continue
        tk, tl = _low(kp.get("type")), _low(lp.get("type"))
        if not tk or not tl or tk != tl:
            out.append(lv("refused:TYPE_MISMATCH", [f"type {tk or '?'} vs {tl or '?'}"]))
            continue
        kc, lc = kp.get("credits"), lp.get("credits")
        if not isinstance(kc, int) or not isinstance(lc, int):
            out.append(lv("unknown", ["unread:credit_count"]))
            continue
        if keep_is_login and kc == 0 and lc != 0:
            out.append(lv("refused:EMPTY_SHELL_MAIN", ["the keep is the requester's empty login shell"]))
            continue
        if paid is None or loser not in paid:
            out.append(lv("unknown", ["unread:paid_seats"]))
            continue
        if [t for t in paid[loser] if _low(t) not in teams]:
            out.append(lv("refused:PAID_SEAT", ["paid by a workspace the requester does not hold"]))
            continue
        if threads is None:
            out.append(lv("unknown", ["unread:requester_threads"]))
            continue
        own = [t for t in threads if t.get("bound") is True
               and {keep, loser} <= {_low(x) for x in t.get("named_ids") or []}]
        if not own:
            out.append(lv("wait:owner_thread",
                          ["no thread of the requester's own (one contact, the account email) names the keep and this duplicate"]))
            continue
        pops = [profiles[u].get("popularity") for u in (keep, loser)]
        if any(not isinstance(p, (int, float)) for p in pops):
            out.append(lv("unknown", ["unread:popularity"]))
            continue
        guard = []
        if max(pops) >= BIG_POPULARITY:
            guard.append(("big_profile", f"popularity>={BIG_POPULARITY} ({max(pops)})"))
        if lc > kc:
            guard.append(("direction", f"the keep has fewer credits ({kc} < {lc})"))
        if flagged_claim:
            guard.append(("flagged_claim", "a claim carries screening risk flags"))
        same_name = pair.get("same_name_others")
        if same_name is None:
            out.append(lv("unknown", ["unread:same_name_census"]))
            continue
        if same_name:
            guard.append(("common_name", "another same-name profile is claimed or holds credits"))
        if guard:
            out.append(lv("needs_human:" + guard[0][0], [g[1] for g in guard]))
            continue
        shared = sorted({f"{s}:{x}" for s in PERSON_DSP for x in (_ids(kp, s) & _ids(lp, s))})
        if not shared:
            rel = pair.get("name_relation") or best_name_relation(kp.get("names") or [], lp.get("names") or [])
            out.append(lv("needs_evidence:same_person", [f"no Spotify or Tidal identity on both profiles (names {rel})"]))
            continue
        why = [f"owner thread {own[0].get('conv')}"]
        if flags_unread:
            why.append("claim screening flags are not on the replica; core re-checks them at execution")
        if not fresh:
            why.append("snapshot read: measurement only, never a live approve")
        out.append(lv("eligible", why, basis="shared_dsp_identity " + ",".join(shared),
                      command=command_for(keep, loser, own[0].get("conv"), executor),
                      self_serve=self_serve_for(keep, loser, requester)))

    verdicts = [x.verdict for x in out]
    if all(v == "eligible" for v in verdicts):
        tv = "eligible"
    elif "eligible" in verdicts:
        tv = "partial"
    else:  # the most protective duplicate verdict names the ticket
        tv = min(verdicts, key=lambda v: (0 if v.startswith("refused:") else 1 if v == "unknown"
                                          else 2 if v.startswith("needs_") else 3))
    why = sorted({f"{x.loser[:8]}: {x.verdict}" for x in out if x.verdict != "eligible"})
    return done(tv, "8_per_duplicate", why, m1_state="executable-L7", losers=out)
