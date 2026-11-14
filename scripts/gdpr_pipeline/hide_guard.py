"""The hide guard: the last check before a page is put into the reversible-hide PRs.

Why it exists (audit `data/gdpr-takedown-ownership-f3/report.md`, 2026-11-13): of 253 profiles removed in 90 days,
60 had the owner's claim on record. 61 passed on a name match, 45 on a legal or takedown request nobody is recorded
as approving, and one was removed while a different account held its claim. The identity step decides and stores a
verdict; nothing read the proof again when the hide was prepared, and nothing bounded how many went at once.

`hide-batch` calls `guard()` on the planned batch and prepares only what it admits. Three rules, all code:

  1. OWNERSHIP, read again from its source. A page is admitted only on path A (the requesting account holds a
     processed claim on the profile) or path D (a verified sender writing from the profile's own website). For D
     the profile's website is read from core now and must still be the sender's host, and `hide-batch` has the
     identity step decide every path-D row again first, because only that step reads whether the sender is
     verified. For A the claim is read from core now, not taken from the stored verdict, and it has to be one of:
       - a reviewed claim: filed against an existing profile (empty `reason`) with verification links; or
       - the account's own profile: a claim made with no review counts only while the profile holds exactly one
         source, a muso one, created within SELF_CREATED_WINDOW_S of the claim. Measured: 4,429 of 4,432 instant
         claims are that. Two reached an artist's catalog page through a later merge; those are held.
     The profile's sources are read from the live admin profile, never the catalog view (four days behind when
     this was written). A name match (PASS_B / PASS_C) is held. A legal or takedown request (LEGAL_HIDE_FIRST) is
     held too, on the `--include-legal` run as well: the account that holds the claim on the page is decided by the
     identity step as path A and enters the batch as any owner's request, so the guard sees it as A, never as a
     legal page it could admit on a stored verdict.
  2. CAPS. A requester gets REQUESTER_PROFILES_PER_DAY new profiles in 24 hours and the register
     GLOBAL_PROFILES_PER_DAY. The rest are held, paged once, and offered again on the next run, most overdue first.
     A track or an album counts as its one artist's profile.
  3. AN AUDIT ROW. Every admit and every hold is a `hide_guard` event on the request, written when it changes,
     with the basis, the claim and the requester key. The hide stays the reversible list entry; this adds nothing
     that deletes.

It has no outcome that waits for a person: a page is admitted, or held with a reason code whose `NEXT` line is what
has to change. It sends nothing itself. The identity step weighs the requester's claim with the same rule
(`prove`, called from `Run.decide_row`), so a requester whose claim does not show ownership is decided ASK_IDENTITY
there and asked by the letter that verdict already has; the guard is what stops a hide if that step is skipped,
stale, or wrong.

"Could not read" is not "not the owner": a failed claim or catalog read raises `sources.Unknown`, and the caller
stops before it touches the open PR. Holding instead would re-issue the PR without ids that may be rightful.
"""
from __future__ import annotations

import hashlib
from dataclasses import replace
from datetime import datetime, timedelta, timezone

from gdpr_pipeline import identity, sources
from gdpr_pipeline.store import parse_iso

EVENT = "hide_guard"
PAGED = "hide_guard_paged"

REQUESTER_PROFILES_PER_DAY = 3      # the audit's burst line: one requester, more than 3 profiles in a day
GLOBAL_PROFILES_PER_DAY = 20        # owner-verified hides ran at 47 in 30 days; the largest real day was 7
SELF_CREATED_WINDOW_S = 60
WINDOW = timedelta(hours=24)

ADMITTED, HELD = "admitted", "held"

NAME_ONLY = "name_match_is_not_ownership"
LEGAL = "legal_request_without_ownership"
NOT_RECORDED = "proof_not_recorded"
NOT_HOLDER = "requester_holds_no_claim_now"
UNVERIFIED = "claim_not_verified"
NOT_FOUND = "profile_not_found"
SITE_MOVED = "sender_is_not_at_the_profiles_site_now"
REQUESTER_CAP = "requester_over_daily_cap"
GLOBAL_CAP = "over_global_daily_cap"
CAP_REASONS = (REQUESTER_CAP, GLOBAL_CAP)

# What each hold needs. The first four are asks of the requester; none is a queue for a person.
NEXT = {
    NAME_ONLY: "a matching name does not show the profile is theirs: the requester claims the profile in the app",
    LEGAL: "a legal or takedown request with no ownership on record does not show the profile is the requester's: "
           "the ask is the requester's claim on the profile, or the owner's written authorisation (a link or a "
           "label/management document)",
    NOT_HOLDER: "the requesting account holds no processed claim on the profile now: the requester claims it",
    UNVERIFIED: "the claim was made without verification and the profile holds sources that account did not create: "
                "the next identity decision asks the requester for evidence of authority",
    NOT_RECORDED: "the decision on file does not say which account and profile it rests on: decided again next run",
    NOT_FOUND: "core did not return the profile: read again next run",
    SITE_MOVED: "the profile's website is not the sender's host now: the next identity decision asks the requester "
                "to claim the profile or send evidence of authority",
    REQUESTER_CAP: f"more than {REQUESTER_PROFILES_PER_DAY} profiles for one requester in 24 hours: offered again "
                   f"next run",
    GLOBAL_CAP: f"more than {GLOBAL_PROFILES_PER_DAY} profiles in 24 hours: offered again next run",
}

OWNERSHIP = (identity.PASS_A, identity.PASS_D)
# LEGAL_HIDE_FIRST is deliberately absent: the guard admits no legal page (a legal threat from the account that
# holds the claim is decided by the identity step as PASS_A and enters as path A).


def requester_key(row: dict, entry: dict) -> str:
    """Who is asking, as one stable key that carries no address: the account when the decision names one, else a
    hash of the address, else the request itself."""
    if entry.get("account") is not None:
        return f"account:{entry['account']}"
    email = (row.get("requester_email") or "").strip().lower()
    if email:
        return "mail:" + hashlib.sha256(email.encode()).hexdigest()[:10]
    return f"request:{row['id']}"


def _has_link(value) -> bool:
    if isinstance(value, str):
        return len(value.strip()) >= 4
    if isinstance(value, dict):
        return any(_has_link(v) for v in value.values())
    if isinstance(value, list):
        return any(_has_link(v) for v in value)
    return False


def reviewed(claim: dict) -> bool:
    """A claim filed against an existing profile and processed with the claimant's links on it. Any other `reason`
    ('created by user', 'company claim on add', one not seen yet) is a claim nobody reviewed."""
    return not (claim.get("reason") or "").strip() and _has_link(claim.get("links"))


def own_profile(claim: dict, src: dict | None) -> bool:
    """The profile is the one this claim's account created: one source, a muso one, made with the claim."""
    return bool(src and len(src["raws"]) == 1 and src["raws"][0].startswith("muso:")
                and abs(src["created"] - claim["created"]) <= SELF_CREATED_WINDOW_S)


def own_site(sender_host: str, website: str) -> bool:
    """Path D now: the host the pass rested on is the host of the website the profile carries at this moment. The
    exact host, as in the identity step (`identity.host_of`), and never a free-mail host."""
    wd = identity.host_of(website)
    return bool(sender_host and wd and sender_host not in identity.FREEMAIL and sender_host == wd)


def weigh(account: int, claims: list[dict], src: dict | None, src_read: bool) -> tuple[str, str, str]:
    """(proof, claim id, hold reason) for path A on one profile; exactly one of proof / reason is set."""
    mine = [c for c in claims if c["account"] == account]
    if not mine:
        return "", "", NOT_HOLDER
    for c in mine:
        if reviewed(c):
            return "reviewed_claim", c["claim_id"], ""
    if not src_read:
        raise sources.Unknown("the profile was not read for a claim that needs it")
    if src is None:
        return "", "", NOT_FOUND
    for c in mine:
        if own_profile(c, src):
            return "own_profile", c["claim_id"], ""
    return "", "", UNVERIFIED


def prove(facts: list, account: int | None, claim_reader=None, source_reader=None) -> list:
    """The identity step's page facts, with `account` taken off every profile where its processed claim does not
    show the profile is the account's (and named in `claim_unproven`, so the decision can say why it asks). A track
    or an album is weighed on its artists. Other accounts' claims stay: "claimed by somebody else" still asks.

    Reads only where the requester holds a claim on a named page. Raises sources.Unknown when the proof could not
    be read, or the profile could not be: the row is decided on a later run, never asked on a read that failed."""
    def held(p) -> bool:
        return (p.entity == "profile" and p.found and not p.gone and not p.hidden and not p.half_hidden
                and account in p.claim_user_ids)

    if account is None:
        return facts
    mine = sorted({q.entity_id for p in facts for q in (p, *p.artists) if held(q)})
    if not mine:
        return facts
    claims = (claim_reader or sources.claim_proofs)(mine)
    for pid in mine:
        if pid not in claims:
            raise sources.Unknown(f"claims on {pid} were not read")
    unreviewed = [pid for pid in mine if not any(c["account"] == account and reviewed(c) for c in claims[pid])]
    srcs = (source_reader or sources.profile_sources)(unreviewed) if unreviewed else {}
    unproven = set()
    for pid in mine:
        _, _, reason = weigh(account, claims[pid], srcs.get(pid), pid in unreviewed)
        if reason == NOT_FOUND:
            raise sources.Unknown(f"profile {pid} was not returned for a claim that needs it")
        if reason:
            unproven.add(pid)

    def strip(p):
        if held(p) and p.entity_id in unproven:
            p = replace(p, claim_user_ids=p.claim_user_ids - {account},
                        claim_unproven=p.claim_unproven | {account})
        if p.artists:
            p = replace(p, artists=tuple(strip(a) for a in p.artists))
        return p

    return [strip(p) for p in facts] if unproven else facts


def needs_redecide(rows: list[dict], batch: list[dict], now: datetime | None = None, claim_reader=None,
                   source_reader=None, site_reader=None) -> list[dict]:
    """Rows in the batch the identity step decides again before the guard runs.

    One kind is a recorded pass the guard no longer admits on ownership: the claim was deleted, the profile gained
    sources after an unreviewed claim, its website moved, or the decision never recorded what it rests on. Deciding
    it again is what turns a hold into the ask the identity step already owns (`Run.asks` selects ASK rows), instead
    of the page waiting behind a hold nobody told the requester about.

    The other is every path-D row, admitted or not: whether the sender is verified is read from the conversation,
    and only the identity step reads it. Raises sources.Unknown on a proof it cannot read, exactly as `judge`."""
    if not batch:
        return []
    now = now or datetime.now(timezone.utc)
    by_id = {r["id"]: r for r in rows}
    out, seen = [], set()
    for d in judge(batch, rows, [], now, claim_reader, source_reader, site_reader):
        if d["basis"] != identity.PASS_D and (d["outcome"] != HELD or d["reason"] in CAP_REASONS):
            continue                 # a cap hold releases itself on a later run: nothing is wrong with the pass
        row = by_id.get(d["request_id"])
        if row is None or row["id"] in seen:
            continue
        entry = next((x for x in row["verdict_detail"] if x["id"] == d["page"]), {})
        if entry.get("verdict") not in identity.IDENTITY_PASS:
            continue                 # a legal hide-first page is held here; the identity step lifts it as path A
        seen.add(row["id"])
        out.append(row)
    return out


def latest(history: list[dict]) -> dict[tuple[int, str], dict]:
    """{(request, page): the guard's LAST decision} - what a reader that pages or acts on a page must start from."""
    out: dict[tuple[int, str], dict] = {}
    for ev in history:
        d = ev["detail"]
        out[(ev["request_id"], d.get("page") or "")] = d
    return out


def _first_admits(history: list[dict]) -> dict[str, tuple[datetime, str]]:
    """{owner profile: (when it was first admitted, for which requester)}."""
    first: dict[str, tuple[datetime, str]] = {}
    for ev in history:
        d = ev["detail"]
        if d.get("outcome") == ADMITTED and d.get("owner_page") and d["owner_page"] not in first:
            first[d["owner_page"]] = (parse_iso(ev["at"]), d.get("requester") or "")
    return first


def judge(batch: list[dict], rows: list[dict], history: list[dict], now: datetime,
          claim_reader=None, source_reader=None, site_reader=None) -> list[dict]:
    """One decision per batch entry, in batch order (most overdue first). Reads, writes nothing."""
    claim_reader = claim_reader or sources.claim_proofs
    source_reader = source_reader or sources.profile_sources
    site_reader = site_reader or sources.profile_sites
    by_id = {r["id"]: r for r in rows}
    out = []
    for b in batch:
        row = by_id.get(b["request_id"]) or {"id": b["request_id"], "verdict_detail": []}
        entry = next((d for d in row["verdict_detail"] if d["id"] == b["id"]), {})
        dec = {"page": b["id"], "entity": b.get("entity") or "profile", "request_id": b["request_id"],
               "register_no": b.get("register_no"), "basis": b["basis"], "owner_page": entry.get("owner_page") or "",
               "account": entry.get("account"), "requester": requester_key(row, entry), "outcome": HELD,
               "reason": "", "proof": "", "claim_id": "", "sender_host": entry.get("sender_host") or ""}
        legal = b["basis"] == identity.LEGAL_HIDE_FIRST
        if legal:
            dec["reason"] = LEGAL
        elif b["basis"] not in OWNERSHIP:
            dec["reason"] = NAME_ONLY
        elif not dec["owner_page"] or not (dec["sender_host"] if b["basis"] == identity.PASS_D
                                          else dec["account"] is not None):
            dec["reason"] = NOT_RECORDED
        out.append(dec)

    path_a = [d for d in out if not d["reason"] and d["basis"] == identity.PASS_A]
    claims = claim_reader(sorted({d["owner_page"] for d in path_a})) if path_a else {}
    for d in path_a:
        if d["owner_page"] not in claims:
            raise sources.Unknown(f"claims on {d['owner_page']} were not read")
    unreviewed = sorted({d["owner_page"] for d in path_a
                         if any(c["account"] == d["account"] for c in claims[d["owner_page"]])
                         and not any(c["account"] == d["account"] and reviewed(c) for c in claims[d["owner_page"]])})
    srcs = source_reader(unreviewed) if unreviewed else {}
    for d in path_a:
        owner = d["owner_page"]
        d["proof"], d["claim_id"], d["reason"] = weigh(d["account"], claims[owner], srcs.get(owner),
                                                       owner in unreviewed)
    # Path D: the stored verdict says the sender's host WAS the profile's website. The website is read again here;
    # a profile whose site was changed or corrected since the decision is held, never admitted on the old answer.
    path_d = [d for d in out if not d["reason"] and d["basis"] == identity.PASS_D]
    sites = site_reader(sorted({d["owner_page"] for d in path_d})) if path_d else {}
    for d in path_d:
        if d["owner_page"] not in sites:
            d["reason"] = NOT_FOUND
        elif not own_site(d["sender_host"], sites[d["owner_page"]]):
            d["reason"] = SITE_MOVED
        else:
            d["proof"] = "own_site"
    for d in out:
        del d["sender_host"]         # compared above, never recorded on the event or shown

    first = _first_admits(history)
    per_requester: dict[str, int] = {}
    total = 0
    for at, who in first.values():
        if now - at < WINDOW:
            per_requester[who] = per_requester.get(who, 0) + 1
            total += 1
    for d in out:
        if d["reason"]:
            continue
        if d["owner_page"] not in first:
            if per_requester.get(d["requester"], 0) >= REQUESTER_PROFILES_PER_DAY:
                d["reason"], d["proof"], d["claim_id"] = REQUESTER_CAP, "", ""
                continue
            if total >= GLOBAL_PROFILES_PER_DAY:
                d["reason"], d["proof"], d["claim_id"] = GLOBAL_CAP, "", ""
                continue
            first[d["owner_page"]] = (now, d["requester"])
            per_requester[d["requester"]] = per_requester.get(d["requester"], 0) + 1
            total += 1
        d["outcome"] = ADMITTED
    return out


def record(store, decisions: list[dict], history: list[dict]) -> int:
    """Write an event for each decision that differs from the last one on file for that request and page."""
    last: dict[tuple[int, str], tuple[str, str]] = {}
    for ev in history:
        d = ev["detail"]
        last[(ev["request_id"], d.get("page") or "")] = (d.get("outcome") or "", d.get("reason") or "")
    wrote = 0
    for d in decisions:
        if last.get((d["request_id"], d["page"])) == (d["outcome"], d["reason"]):
            continue
        store.event(d["request_id"], EVENT, **{k: d[k] for k in (
            "page", "entity", "owner_page", "basis", "account", "requester", "outcome", "reason", "proof",
            "claim_id")})
        wrote += 1
    store.db.commit()
    return wrote


def to_page(decisions: list[dict], paged: list[dict], now: datetime) -> list[dict]:
    """Cap holds nobody has been paged about in the last 24 hours."""
    told = {ev["detail"].get("page") for ev in paged if now - parse_iso(ev["at"]) < WINDOW}
    return [d for d in decisions if d["reason"] in CAP_REASONS and d["page"] not in told]


def page_text(held: list[dict]) -> str:
    """The alert. Ids, counts and requester keys only: no name and no address."""
    by_req: dict[str, list[dict]] = {}
    for d in held:
        by_req.setdefault(d["requester"], []).append(d)
    lines = [f"GDPR hide guard: {len(held)} page(s) held over the daily cap. Nothing was hidden for them; they are "
             f"offered again on the next run."]
    for who, ds in sorted(by_req.items(), key=lambda kv: -len(kv[1])):
        regs = ", ".join(dict.fromkeys(f"#{d['register_no']}" for d in ds))
        why = ", ".join(sorted({d["reason"] for d in ds}))
        lines.append(f"- {who}: {len(ds)} held ({why}), register {regs}")
    lines.append(f"Caps: {REQUESTER_PROFILES_PER_DAY} profiles per requester and {GLOBAL_PROFILES_PER_DAY} in all, "
                 f"per 24 hours. Rows: erasure_events kind={EVENT}.")
    return "\n".join(lines)


def mark_paged(store, held: list[dict]) -> None:
    for d in held:
        store.event(d["request_id"], PAGED, page=d["page"], reason=d["reason"], requester=d["requester"])
    store.db.commit()


def guard(batch: list[dict], rows: list[dict], store, write: bool, now: datetime | None = None,
          claim_reader=None, source_reader=None, site_reader=None) -> tuple[list[dict], list[dict]]:
    """(the batch entries admitted, every decision). `write=False` is the dry run: nothing is recorded, so it spends
    no cap. Raises sources.Unknown when a proof could not be read."""
    now = now or datetime.now(timezone.utc)
    history = store.events_of_kind(EVENT)
    decisions = judge(batch, rows, history, now, claim_reader, source_reader, site_reader)
    if write:
        record(store, decisions, history)
    ok = {(d["request_id"], d["page"]) for d in decisions if d["outcome"] == ADMITTED}
    return [b for b in batch if (b["request_id"], b["id"]) in ok], decisions
