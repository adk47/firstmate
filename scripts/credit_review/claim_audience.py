"""p1 + r5 (10-31 11:0xZ, batch 3): the audience is decided PER USER across all of their claims. A user with ANY
proof_ask claim gets the code ask only (or a listed hold), never a status line in the same window (the /k class:
telling someone who owes the code that the wait is on us)."""


class MixedAudience(SystemExit):
    pass


def assert_one_audience(rows):
    """REFUSE the run when any user is in both audiences (a status line to a user who owes the code)."""
    owes = {r["user_id"] for r in rows if r.get("audience") == "proof_ask"}
    mixed = sorted({r["user_id"] for r in rows if r.get("audience") == "status" and r["user_id"] in owes})
    if mixed:
        raise MixedAudience(f"REFUSED: {len(mixed)} user(s) in BOTH a proof_ask and a status row: {mixed[:10]}")


def drop_messaged_7d(rows, counts, messaged):
    """The live gate defers anyone with a note from it in the last 7 days (any campaign); --check-recipients does not
    evaluate that, so the builder drops them (batch 3: 25 signed rows deferred at send). `messaged` = account ids. Pure."""
    kept = []
    for r in rows:
        if str(r["user_id"]) in messaged:
            counts["dropped_messaged_7d"] = counts.get("dropped_messaged_7d", 0) + 1
            continue
        kept.append(r)
    return kept


def one_audience_over_all_claims(rows, counts, ask_users):
    """p1 157: the per-user audience is computed over ALL of the user's open claims, not only the rows that survived the
    build/gate. `ask_users` = every user with ANY open proof_ask-audience claim (this list's rows plus every claim asked
    by code and still pending, e.g. a b3 ask the gate deferred). Their status rows are dropped. Pure."""
    owes = {str(u) for u in ask_users} | {str(r["user_id"]) for r in rows if r.get("audience") == "proof_ask"}
    here = {str(r["user_id"]) for r in rows if r.get("audience") == "proof_ask"}
    kept = []
    for r in rows:
        if r.get("audience") == "status" and str(r["user_id"]) in owes:
            if str(r["user_id"]) in here:
                counts["status_user_owes_code_ask"] = counts.get("status_user_owes_code_ask", 0) + 1
                counts.setdefault("status_user_owes_code_ask_claims", []).append(r["claim_id"])
            else:
                counts["status_user_owes_code_ask_elsewhere"] = \
                    counts.get("status_user_owes_code_ask_elsewhere", 0) + 1
            continue
        kept.append(r)
    return kept


def drop_unreachable(rows, counts, forbidden):
    """p1 157: a user Intercom refused (action_forbidden) is unreachable; never list him again (no-channel tray).
    `forbidden` = account ids with a prior action_forbidden in the ledger. Pure."""
    kept = []
    for r in rows:
        if str(r["user_id"]) in forbidden:
            counts.setdefault("no_channel_tray", []).append(r["claim_id"])
            continue
        kept.append(r)
    return kept
