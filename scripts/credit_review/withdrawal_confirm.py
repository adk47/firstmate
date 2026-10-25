"""withdrawal-confirm (firstmate 061): tell a requester that the credit request they asked us
to withdraw is withdrawn. Fixed copy in Caroline's gate; role + title from the request row on
the core replica (Trino), never from what anyone typed. Sent only for a request that is
`rejected` with metadata.withdrawal.by = "requester" (the credit-system lane's withdrawal
record), once per request (gate ledger).

Delivery (firstmate 063): a request given as `id:conversation` is answered IN that Intercom
conversation (the gate checks it is the requester's own, unassigned to a human and not
tagged do-not-message); a bare `id` goes by email.

Recipient (firstmate 090): every payload carries user.professional_id (users.neptuneprofessionalid,
Intercom's external_id) and user.auth_id when the account has an Auth0 subject; an account
without a professional id (which should not happen) is held, never handed to the gate.

In-thread legacy-id match (firstmate 089, in-thread replies only, a backstop): before the send the
driver asks the gate (read only, --thread-contact) for that conversation's contact external_id
and, when it is not this account's, checks on the replica whether it is another Muso account;
the gate then accepts the reply only when the contact has the account email, the email is not a
shared or role inbox, and that check said no."""

from __future__ import annotations

import json
import os
import re
import tempfile
from typing import Any

from . import verify_ledger, verify_notify
from .uvn_status import Query, trino

CAMPAIGN = "withdrawal-confirm"
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
CONV_RE = re.compile(r"^[0-9]{1,24}$")
EXT_RE = re.compile(r"^[A-Za-z0-9._|-]{1,128}$")


def parse_specs(specs: list[str]) -> tuple[dict[str, str], list[str]]:
    """({request id: conversation id or ''}, refusals) from `id[:conversation]` items."""
    out: dict[str, str] = {}
    bad: list[str] = []
    for spec in (s.strip() for s in specs):
        if not spec:
            continue
        rid, _, conv = spec.partition(":")
        rid, conv = rid.strip().lower(), conv.strip()
        if not UUID_RE.fullmatch(rid):
            bad.append(f"{spec}: not a credit request id")
        elif conv and not CONV_RE.fullmatch(conv):
            bad.append(f"{spec}: the conversation must be a numeric Intercom conversation id")
        else:
            out[rid] = conv
    return out, bad


def payloads(request_ids: list[str], query: Query = trino) -> tuple[list[dict[str, Any]], list[str], list[str]]:
    """(one payload per verified withdrawal, refusals, held: ids whose account has no
    professional id) for these `id[:conversation]` items."""
    threads, bad = parse_specs(request_ids)
    if bad:
        return [], bad, []
    ids = list(threads)
    if not ids:
        return [], [], []
    quoted = ",".join(f"'{r}'" for r in ids)
    rows = query(
        "SELECT CAST(cr.id AS varchar), cr.status, json_extract_scalar(cr.metadata, '$.withdrawal.by'), "
        "spotifytracktitle, json_format(CAST(spotifytrackartists AS json)), "
        "credits, CAST(u.id AS varchar), lower(u.email), u.firstname, "
        "u.neptuneprofessionalid, u.auth0userid "
        "FROM postgresql_core.public.credit_requests cr JOIN postgresql_core.public.users u ON u.id = cr.userid "
        f"WHERE CAST(cr.id AS varchar) IN ({quoted})")
    found, out, refused, held = set(), [], [], []
    for rid, status, by, title, artists, raw_roles, uid, email, first, pro, auth in rows:
        found.add(rid)
        roles = verify_notify.pg_text_array(raw_roles)  # a Postgres text[] literal on the replica
        if status != "rejected" or by != "requester":
            refused.append(f"{rid}: not a requester withdrawal (status {status}, withdrawal.by {by or '-'})")
            continue
        try:
            artist = next((a.get("name") for a in json.loads(artists or "[]") if isinstance(a, dict) and a.get("name")), "")
        except ValueError:
            artist = ""
        if not (title and roles and email):
            refused.append(f"{rid}: no title, role or account email")
            continue
        pro_id = verify_notify.professional_id(pro)
        if not pro_id:
            held.append(rid)
            continue
        p: dict[str, Any] = {"user": {"email": email, "id": uid, "professional_id": pro_id,
                                      "auth_id": verify_notify.auth_subject(auth), "first_name": first or ""},
                             "credits": [{"request_id": rid, "role": roles, "track_title": title,
                                          "artist_name": artist or "-"}]}
        if threads.get(rid):
            p["extra"] = ["--conversation", threads[rid]]
        out.append(p)
    refused += [f"{r}: not found" for r in ids if r not in found]
    return out, refused, held


def ext_owner_ids(ext: str, query: Query = trino) -> set[str]:
    """Muso user ids whose numeric id, professional id or Auth0 subject is this Intercom
    external_id (replica)."""
    if not EXT_RE.fullmatch(ext):
        raise ValueError(f"unexpected external_id {ext!r}")
    return {str(r[0]) for r in query(
        "SELECT CAST(id AS varchar) FROM postgresql_core.public.users "
        f"WHERE CAST(id AS varchar) = '{ext}' OR neptuneprofessionalid = '{ext}' OR auth0userid = '{ext}' "
        f"OR auth0userid = 'auth0|{ext}'")}


def check_thread_identity(p: dict[str, Any], campaign: str, report: verify_notify.Report, *, query: Query,
                          wrapper: str, runner: verify_notify.Runner) -> bool:
    """Adds user.thread_external_id / user.ext_other_account (the gate's legacy-id match input)
    to an in-thread payload. False when nothing may be sent: a gate refusal (rc 1, counted as
    refused with the gate's reason) or an unreadable thread (counted as failed). An external_id
    that cannot be checked on the replica gets no ext_other_account, so the gate refuses it."""
    fd, path = tempfile.mkstemp(prefix="verify-thread-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"user": p["user"], "credits": p["credits"]}, fh, ensure_ascii=False)
        res = runner([wrapper, "send", "--credits-file", path, "--approved-by", verify_notify.CAPTAIN_UID,
                      "--campaign", campaign, *(p.get("extra") or []), "--thread-contact"])
    finally:
        os.unlink(path)
    line = next((ln for ln in (res.stdout or "").splitlines() if ln.startswith("THREAD_CONTACT ")), "")
    rid = p["credits"][0]["request_id"]
    try:
        info = json.loads(line.split(" ", 1)[1]) if res.returncode == 0 and line else None
    except ValueError:
        info = None
    err = next((ln.strip() for ln in (res.stderr or "").splitlines() if ln.strip()), "")
    if res.returncode == 1:
        report.refused_users += 1
        report.refusals.append(f"{rid}: {err.removeprefix('REFUSED: ')}"[:200])
        return False
    if not isinstance(info, dict):
        report.failed_users += 1
        report.failures.append(f"{rid}: the conversation could not be read (rc={res.returncode}): {err}"[:200])
        return False
    ext = str(info.get("external_id") or "")
    uid, pro, auth = str(p["user"]["id"]), str(p["user"].get("professional_id") or ""), str(p["user"].get("auth_id") or "")
    mine = {x for x in (pro, auth, f"auth0|{auth}" if auth else "") if x}
    p["user"]["thread_external_id"] = ext
    if not ext or ext in mine:
        p["user"]["ext_other_account"] = False
    elif EXT_RE.fullmatch(ext):
        p["user"]["ext_other_account"] = bool(ext_owner_ids(ext, query) - {uid})
    return True


def _threaded(ps: list[dict[str, Any]], campaign: str, report: verify_notify.Report, *, mode: str, query: Query,
              wrapper: str, runner: verify_notify.Runner) -> list[dict[str, Any]]:
    if mode != "apply":
        return ps
    return [p for p in ps if "--conversation" not in (p.get("extra") or [])
            or check_thread_identity(p, campaign, report, query=query, wrapper=wrapper, runner=runner)]


def _recording_deferrals(runner: verify_notify.Runner, deferred: list[str]) -> verify_notify.Runner:
    def run_one(argv: list[str]) -> Any:
        res = runner(argv)
        if res.returncode == 3 and "--credits-file" in argv:
            with open(argv[argv.index("--credits-file") + 1], encoding="utf-8") as fh:
                deferred.extend(str(c["request_id"]) for c in json.load(fh)["credits"])
        return res
    return run_one


def run(request_ids: list[str], *, mode: str = "dry-run", query: Query = trino,
        wrapper: str = verify_notify.WRAPPER, runner: verify_notify.Runner = verify_notify._run
        ) -> tuple[verify_notify.Report, list[str], list[str], list[str]]:
    """(report, refusals, held: request ids whose account has no professional id,
    deferred: request ids the gate deferred (daily cap)); held and deferred ones were not sent."""
    report = verify_notify.Report()
    ps, refused, held = payloads(request_ids, query)
    report.no_professional_id = len(held)
    ps = _threaded(ps, CAMPAIGN, report, mode=mode, query=query, wrapper=wrapper, runner=runner)
    report.users = len(ps)
    deferred: list[str] = []
    verify_notify.send_all(ps, report, mode=mode, wrapper=wrapper, runner=_recording_deferrals(runner, deferred),
                           extra=["--campaign", CAMPAIGN])
    return report, refused, held, deferred


# -- email-changed (firstmate 073) ---------------------------------------------
# "Done - your sign-in email has been updated ..." as a threaded reply into the requester's
# own conversation, once per ticket. The account comes from the replica; its email only keys the
# ledger. The gate takes the recipient from the ticket conversation itself: exactly one contact,
# an Intercom user whose external_id is this account's professional id or Auth0 subject
# (firstmate 076, 090), or the in-thread legacy-id match (firstmate 089). There is no email search.
TICKET_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")


def email_changed(*, user_id: int, conversation: str, ticket: str, dup: bool = False, mode: str = "dry-run",
                  query: Query = trino, wrapper: str = verify_notify.WRAPPER,
                  runner: verify_notify.Runner = verify_notify._run, ledger_path: str | None = None,
                  post: verify_notify.Poster = verify_notify.post_cs_priority) -> tuple[verify_notify.Report, list[str]]:
    report = verify_notify.Report()
    if not TICKET_RE.fullmatch(ticket or "") or not str(conversation).isdigit():
        return report, ["--ticket must be letters/digits/dashes and --conversation the numeric conversation id"]
    rows = query(f"SELECT CAST(id AS varchar), lower(email), neptuneprofessionalid, auth0userid "
                 f"FROM postgresql_core.public.users WHERE id = {int(user_id)}")
    if not rows or not rows[0][1]:
        return report, [f"user {user_id}: no account email on the replica"]
    pro_id = verify_notify.professional_id(rows[0][2])
    if not pro_id:
        return report, [f"user {user_id}: no professional id on the replica (the Intercom recipient cannot be matched)"]
    campaign = "email-changed-dup" if dup else "email-changed"
    payload = {"user": {"email": rows[0][1], "id": str(int(user_id)), "professional_id": pro_id,
                        "auth_id": verify_notify.auth_subject(rows[0][3]), "first_name": ""},
               "credits": [{"request_id": f"email-change-{ticket}"}],
               "extra": ["--conversation", str(conversation)]}
    ps = _threaded([payload], campaign, report, mode=mode, query=query, wrapper=wrapper, runner=runner)
    verify_notify.send_all(ps, report, mode=mode, wrapper=wrapper, runner=runner, extra=["--campaign", campaign])
    report.users = len(ps)
    if mode == "apply":
        verify_notify.flag_refusals(report, ledger_path=ledger_path or verify_ledger.DEFAULT_PATH,
                                    campaigns=["email-changed", "email-changed-dup"], post=post)
    return report, []
