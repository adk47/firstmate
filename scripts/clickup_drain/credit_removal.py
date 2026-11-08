"""Hourly drainer for ClickUp `action:credit-removal` tickets ("remove my credit" / "that isn't me").

The customer made ONE choice, in the app's modal or in Caroline's chat (Fable
`credit-removal-flow-fable-r2` §4, §6):

    "This is me, but hide it from my profile"   -> details.intent = "hide_mine"
    "This isn't me / I'm not on this track"     -> details.intent = "not_me"

This drainer turns each ticket into rows for `credit_review.removal_executor`, which owns the two
intents and the core writes (docs/credit-verification/credit-removal.md). The drainer owns the ClickUp
side and the IDENTITY LINK:

  identity   The ticket's own text is DATA, never identity (a ticket body is customer text, and a
             customer - or anyone who can send Caroline a message - controls every byte of it). The
             account comes from the Intercom conversation's contact (`external_id`), through
             `credit_review.identity_resolver` (r5: professional id / Auth0 subject / a processed
             claim's profile / the representation profile, and nothing else). The ticket's own profile
             link is used ONLY as a candidate id, and only after `identity_resolver.owns` confirms the
             account actually owns it (its own professional id, a processed claim, or its
             representation profile). A profile the ticket names but the account does not own is
             `identity_unlinked`: nothing is hidden and a human reads the ticket. A ticket with no
             resolvable account is the same.

  intents    `details.intent` is required and must be exactly one of the two. `details.track_urls[]`
             (or `details.track_ids[]`) names up to TICKET_ROWS_MAX tracks; `details.proof_urls[]`
             carries a follow-up proof LINK. A ticket with no structured intent is NEVER parsed out of
             free text: it is `needs-customer` and its digest line carries the customer's own words.

  roles      the row carries every role the profile holds on the track (read back from core by the
             executor's readback path). `not_me` covers them all - there is no half-removal, and no
             guess about which role the customer meant.

  tags       exactly one `customer-outcome:` tag per ticket, from the executor's own disposition
             (`removal_executor.TAG_FOR`):
               complete               the credit is hidden, or the gate removed it - read back
               verification-required  the gate says the public sources still list them: we ask for a
                                      proof on the ticket and leave it in the queue (no tag: the
                                      ticket must stay workable, so the proof lands on it)
               needs-customer         ambiguous / unlinked identity / kept after 30 days: a human
               blocked                the core route is absent or refused this automation
               partial                a write went through and the read-back disagreed: NEVER closed
             A transient credit-write lock (`lock_busy`) tags nothing: nothing was written, so the
             ticket stays in the queue for the next run. A proof that arrived after the claim was
             filed (`proof_awaiting_gate`) tags nothing either: the proof is graded and POSTed to the
             gate's proof route, and the internal ask is NOT repeated while it waits. Once the gate
             answers `listed` again, only a proof graded `different` suppresses the ask; `same` and
             `unreadable` ask again, and `unreadable` is worded as a retry.
             A ticket that already carries ANY `customer-outcome:` tag is skipped: a human (or another
             automation) owns it. Tags are replaced, then read back; a read-back that does not agree
             raises rather than reporting a close that did not happen.

  close      `customer-outcome:complete` plus status `resolved` (lib/customer_outcome.customer_complete).
             `resolve-notify.py` allowlists `credit-removal`, so the customer gets the approved note and
             `close-resolved-conversations.py` closes the conversation. Nothing else is closed.

  safety     dry run by DEFAULT (`--apply` to write); both kill files
             (/etc/hydra/clickup-drain-credit-removal.disabled here, /etc/hydra/credit-removal-executor
             .disabled in the executor); the executor refuses every write unless
             policies/credit-approval-automation.json's `credit-removal-executor` entry is approved AND
             /etc/hydra/credit-removal-executor.live exists; ovh-node-8 host guard; every decision and
             every write is a line in /var/lib/hydra/credit-removal/ledger.jsonl with an inverse.

CLI:
  clickup_drain/credit_removal.py                     dry run: decide + report, write nothing
  clickup_drain/credit_removal.py --apply             tag/close + the executor's own gates
  clickup_drain/credit_removal.py --revert <run_id>   replay a run's inverses, untag its tickets
  clickup_drain/credit_removal.py --rows-out F        also write the assembled rows file

stdout: ONE JSON summary. stderr: the human digest (one line per ticket that was not written).
"""
from __future__ import annotations

import argparse
import contextlib
import csv
import io
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from credit_review import removal_executor as rx  # noqa: E402
from lib import clickup_client, customer_outcome, intercom_link  # noqa: E402

LIST_ID = os.environ.get("CLICKUP_CREDIT_REMOVAL_LIST", "901000600160")
ACTION_TAG = "action:credit-removal"
HOST_GUARD = "ovh-node-8"
KILL_FILE = os.environ.get("CLICKUP_CREDIT_REMOVAL_KILL_FILE",
                           "/etc/hydra/clickup-drain-credit-removal.disabled")
STATE_DIR = os.environ.get("CLICKUP_CREDIT_REMOVAL_STATE", "/var/lib/hydra/clickup-drain-credit-removal")
BATCH_MAX = int(os.environ.get("CLICKUP_CREDIT_REMOVAL_BATCH_MAX", "20"))
TICKETS_MAX = int(os.environ.get("CLICKUP_CREDIT_REMOVAL_TICKETS_MAX", "20"))
TICKET_ROWS_MAX = 3
MAX_PAGES = 20
PAGE = 100
COMMENT_MAX_PER_RUN = 10
READBACK_TRIES = 3
READBACK_POLL_S = 2.0
INTERCOM_API = os.environ.get("INTERCOM_API", "https://api.intercom.io")
TRINO = os.environ.get("CREDIT_REMOVAL_TRINO", "/opt/hydra/scripts/trino-query.sh")
PROFILE_URL_RE = re.compile(r"/profile/([0-9a-fA-F-]{8,})")
TRACK_URL_RE = re.compile(r"/track/([0-9a-fA-F-]{8,})")
PROFILE_FIELD_HINTS = ("profile", "muso profile", "customer profile")

#: `/admin/profile/:id/credits` is PAGE-based (it ignores `offset` and echoes page 1 back), so a
#: complete read is a page walk. One page is not the list: a requested track on page 2+ would be
#: reported absent, and `track_unresolved` is a durable `needs-customer` tag.
CREDITS_PAGE_LIMIT = 500
CREDITS_MAX_PAGES = 400
# A follow-up on an existing ticket is a ClickUp COMMENT, not a description edit
# (`create_ticket` dedupes same-conversation/same-kind onto the open ticket and posts
# `buildFollowupComment`). That comment carries its own structured block, which is the only
# place a proof link the customer sends AFTER the ticket is filed ever appears.
UPDATE_START = "---ACTION-REQUEST-UPDATE---"
UPDATE_END = "---END-ACTION-REQUEST-UPDATE---"
UPDATE_BLOCK_RE = re.compile(re.escape(UPDATE_START) + r"\s*(\{[\s\S]*?\})\s*" + re.escape(UPDATE_END))


class RunError(RuntimeError):
    """The run cannot continue safely (unreadable board, a write that did not read back)."""


# ── board ───────────────────────────────────────────────────────────────────
def clickup_key() -> str:
    """The ClickUp token. A cron does NOT inherit the gateway's env, so when the variable is absent the
    key comes from the gateway env file (exactly that one line, the way scripts/stale-ticket-watchdog.sh
    does it) or from /etc/clickup/api-key."""
    key = os.environ.get("CLICKUP_API_KEY") or os.environ.get("MUSOAI_CLICKUP_API_KEY") or ""
    if not key:
        env_file = Path(os.environ.get("CLICKUP_ENV_FILE", "/etc/openclaw/main.env"))
        if env_file.exists():
            for line in env_file.read_text(errors="replace").splitlines():
                if line.startswith("CLICKUP_API_KEY="):
                    key = line.split("=", 1)[1].strip().strip("'\"").strip()
                    break
    if not key:
        path = Path("/etc/clickup/api-key")
        if path.exists():
            key = path.read_text().strip()
    if not key:
        raise RunError("no ClickUp API key (CLICKUP_API_KEY / MUSOAI_CLICKUP_API_KEY, CLICKUP_ENV_FILE, "
                       "or /etc/clickup/api-key)")
    return key


def client() -> clickup_client.ClickUp:
    return clickup_client.shared(clickup_key())


def tags_of(task: dict) -> set[str]:
    return {str(t.get("name", "")).strip().lower() for t in task.get("tags") or [] if isinstance(t, dict)}


def is_open(task: dict) -> bool:
    return not customer_outcome.workflow_terminal(task)


def why_excluded(task: dict[str, Any], list_id: str | None = None) -> str:
    """Why this ticket is NOT the drainer's to work, or "" when it is. The ONE definition: the bulk scan
    and the `--ticket` re-run both route through it, so they cannot drift apart."""
    if list_id and str((task.get("list") or {}).get("id") or "") not in ("", str(list_id)):
        return f"it is in list {(task.get('list') or {}).get('id')}, not {list_id}"
    if ACTION_TAG not in tags_of(task):
        return f"it does not carry {ACTION_TAG}"
    tags = customer_outcome.outcome_tags_of(task)
    if tags:
        return f"it already carries {', '.join(sorted(tags))} (someone owns its outcome)"
    if not is_open(task):
        return f"its status {str((task.get('status') or {}).get('status'))!r} is terminal"
    return ""


def select_tickets(api: clickup_client.ClickUp, list_id: str, *, only: str | None = None,
                   max_pages: int = MAX_PAGES) -> list[dict[str, Any]]:
    """OPEN tickets carrying `action:credit-removal`, oldest first."""
    if only:
        _, task = api.request("GET", f"/task/{only}")
        if not isinstance(task, dict) or not task.get("id"):
            raise RunError(f"ticket {only} not found")
        why = why_excluded(task, list_id)
        if why:
            raise RunError(f"ticket {only} is not actionable: {why}")
        return [task]
    params = [("tags[]", ACTION_TAG), ("include_closed", "false"), ("order_by", "created"),
              ("reverse", "false"), ("subtasks", "false")]
    tasks = api.list_tasks(list_id, params, max_pages)
    out = []
    for task in tasks:
        if not isinstance(task, dict) or not task.get("id"):
            continue
        if why_excluded(task, list_id):
            continue
        out.append(task)
    out.sort(key=lambda t: (str(t.get("date_created") or ""), str(t.get("id"))))
    return out


# ── ticket -> rows ──────────────────────────────────────────────────────────
def action_json(task: dict) -> dict[str, Any]:
    """The support skill's structured block (`---ACTION-REQUEST---` … `---END-ACTION-REQUEST---`),
    parsed from the ticket body. Absent/unparseable -> {} (a malformed block is one ticket's problem,
    not the run's)."""
    body = str(task.get("description") or task.get("text_content") or "")
    start, end = "---ACTION-REQUEST---", "---END-ACTION-REQUEST---"
    i = body.find(start)
    if i < 0:
        return {}
    j = body.find(end, i)
    if j < 0:
        return {}
    raw = body[i + len(start):j].strip()
    if raw.startswith("```"):
        raw = raw.split("\n", 1)[-1].rsplit("```", 1)[0]
    try:
        doc = json.loads(raw)
    except ValueError:
        return {}
    return doc if isinstance(doc, dict) else {}


def details_of(task: dict) -> dict[str, Any]:
    block = action_json(task)
    details = block.get("details")
    return details if isinstance(details, dict) else {}


def followup_details(api: Any, task: dict) -> dict[str, Any]:
    """The `details` of every `---ACTION-REQUEST-UPDATE---` block on the ticket's COMMENTS, oldest
    first, merged into one dict.

    A proof the customer sends after the ticket is filed never reaches the description: `create_ticket`
    dedupes onto the open ticket and posts `buildFollowupComment`, which carries the structured block
    in a comment. Reading only the description is why a `not_me` claim could ask for a proof forever
    while the proof sat on the ticket. Comments are read as DATA and only `proof_urls` is taken from
    them (see `intents`): the intent is the customer's ONE choice, made when the ticket was filed, and
    a later comment must never be able to change it. `proof_urls` from every block ACCUMULATE (newest
    last, deduped, capped at `PROOF_URLS_MAX`) instead of the newest replacing the rest, because a
    customer may send several links before the next drain and each one is evidence.

    Fail-open on purpose: a ClickUp error or a malformed block yields {} so one unreadable comment
    cannot stop the run, and the ticket still works from its own description."""
    tid = str(task.get("id") or "")
    if not tid:
        return {}
    try:
        resp = api.request("GET", f"/task/{tid}/comment")
    except Exception:  # noqa: BLE001 - a comment read is best-effort, never a run-stopper
        return {}
    # `clickup_client.request` answers (status, body); a Response-shaped stub answers .ok/.json().
    if isinstance(resp, tuple):
        status, payload = (resp + (None,))[:2] if len(resp) < 2 else resp[:2]
        if status != 200:
            return {}
    else:
        if not getattr(resp, "ok", False):
            return {}
        try:
            payload = resp.json()
        except Exception:  # noqa: BLE001
            return {}
    comments = payload.get("comments") if isinstance(payload, dict) else None
    if not isinstance(comments, list):
        return {}
    merged: dict[str, Any] = {}
    proofs: list[str] = []
    for comment in comments:
        if not isinstance(comment, dict):
            continue
        text = str(comment.get("comment_text") or comment.get("text_content") or "")
        for raw in UPDATE_BLOCK_RE.findall(text):
            try:
                doc = json.loads(raw)
            except ValueError:
                continue
            details = doc.get("details") if isinstance(doc, dict) else None
            if not isinstance(details, dict):
                continue
            # `proof_urls` ACCUMULATE across updates, newest last, deduped and capped. A customer who
            # sends link A and then link B before the next drain has sent TWO proofs, and keeping only
            # the newest would silently drop A: if B is unreadable and A shows the right person, A is
            # the one that settles the claim.
            for value in _str_list(details.get("proof_urls"), PROOF_URLS_MAX):
                if value not in proofs:
                    proofs.append(value)
            merged.update({k: v for k, v in details.items() if k != "proof_urls"})
    if proofs:
        merged["proof_urls"] = proofs[:PROOF_URLS_MAX]
    return merged


def verbatim_of(task: dict) -> str:
    """The customer's own words (their quote, unmodified), for the digest. Never summarised, never
    rephrased: it is the only place a free-text request stays readable by a human."""
    block = action_json(task)
    for holder in (details_of(task), block):
        text = str(holder.get("customer_verbatim_request") or "")
        if text:
            return " ".join(text.split())[:300]
    return ""


def profile_id_of(task: dict) -> str:
    """The ticket's profile id: the custom field the support tools file it in, else the `**Profile:**`
    deeplink, else the structured block. Empty when the ticket names none.

    This is a CANDIDATE, never an identity: `link_identity` decides whether the ticket's own verified
    account actually presents this profile."""
    for cf in task.get("custom_fields") or []:
        if not isinstance(cf, dict):
            continue
        if cf.get("id") == os.environ.get("CLICKUP_PROFILE_FIELD_ID"):
            value = cf.get("value")
            if value and (m := PROFILE_URL_RE.search(str(value))):
                return m.group(1)
            if value and str(value).strip():
                return str(value).strip()
        name = str(cf.get("name") or "").strip().lower()
        if name and any(h in name for h in PROFILE_FIELD_HINTS) and cf.get("value"):
            m = PROFILE_URL_RE.search(str(cf["value"]))
            if m:
                return m.group(1)
    body = str(task.get("description") or task.get("text_content") or "")
    if m := PROFILE_URL_RE.search(body):
        return m.group(1)
    block = action_json(task)
    for key in ("customer_profile_id", "profile_id", "customerProfileId"):
        if block.get(key):
            return str(block[key]).strip()
    return ""


# How many proof links one ticket may present: its own `details.proof_urls` plus every follow-up
# comment's, deduped oldest-first, then capped. A person rarely has more than two, so five is slack.
PROOF_URLS_MAX = 5


def _str_list(value: Any, limit: int) -> list[str]:
    if isinstance(value, str):
        return [value.strip()] if value.strip() else []
    if isinstance(value, (list, tuple)):
        return [str(v).strip() for v in value if str(v or "").strip()][:limit]
    return []


def intents(task: dict, followup: dict[str, Any] | None = None) -> tuple[dict[str, Any], str]:
    """({"intent", "tracks", "proof_urls"}, why it cannot be used).

    `details.intent` must be exactly one of the two names: a customer who did not answer the question
    has not made the choice, and picking one for them would either hide a credit they wanted removed or
    file a claim about a credit that IS them.

    `followup` is the merged `details` of the ticket's follow-up COMMENTS (`followup_details`). Only
    `proof_urls` is read from it: a proof the customer sends after the ticket is filed lands there and
    nowhere else, while the intent and the tracks stay the ones the ticket was filed with."""
    d = details_of(task)
    intent = str(d.get("intent") or "").strip().lower()
    if not intent:
        return {}, "no structured intent (no details.intent on the ticket)"
    if intent not in rx.INTENTS:
        return {}, f"details.intent {intent!r} is not one of {rx.INTENTS}"
    # read one PAST the cap so an over-long ticket is refused instead of silently truncated
    tracks = _str_list(d.get("track_ids"), TICKET_ROWS_MAX + 1)
    if not tracks:
        for value in _str_list(d.get("track_urls"), TICKET_ROWS_MAX + 1):
            m = TRACK_URL_RE.search(value)
            tracks.append(m.group(1) if m else value)
    if not tracks:
        tracks = _str_list(d.get("track_titles"), TICKET_ROWS_MAX + 1)
    if not tracks:
        return {}, "ticket names no track"
    if len(tracks) > TICKET_ROWS_MAX:
        return {}, (f"ticket names {len(tracks)} tracks, more than the {TICKET_ROWS_MAX} this drainer "
                    "will do in one pass")
    proofs = _str_list(d.get("proof_urls"), PROOF_URLS_MAX)
    for value in _str_list((followup or {}).get("proof_urls"), PROOF_URLS_MAX):
        if value not in proofs:
            proofs.append(value)
    return {"intent": intent, "tracks": tracks, "proof_urls": proofs[:PROOF_URLS_MAX]}, ""


# ── identity LINK ───────────────────────────────────────────────────────────
def trino(sql: str) -> list[list[str]]:
    """Rows from the core replica, CSV. Never cached: identity is re-derived every run."""
    try:
        proc = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=900, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RunError(f"replica query failed: {type(exc).__name__}") from exc
    if proc.returncode != 0:
        raise RunError(f"replica query failed: {(proc.stderr or '').strip()[-300:]}")
    rows = csv.reader(io.StringIO(proc.stdout or ""))
    return [r for r in rows if r and not (len(r) == 1 and r[0].strip().lower() in ("", "rows"))]


def intercom_token() -> str:
    """The Intercom token. A cron does NOT inherit the gateway's env, so when the variable is absent the
    token comes from the gateway env file (the same fallback `clickup_key` uses). Absent everywhere is
    a RunError: without it the identity gate would silently degrade to `identity_unlinked` for every
    ticket and the run would report success."""
    token = (os.environ.get("MUSOAI_INTERCOM_TOKEN") or os.environ.get("INTERCOM_TOKEN") or "").strip()
    if not token:
        env_file = Path(os.environ.get("INTERCOM_ENV_FILE", "/etc/openclaw/main.env"))
        if env_file.exists():
            for line in env_file.read_text(errors="replace").splitlines():
                for name in ("MUSOAI_INTERCOM_TOKEN=", "INTERCOM_TOKEN="):
                    if line.startswith(name):
                        token = line.split("=", 1)[1].strip().strip("'\"").strip()
                        break
                if token:
                    break
    if not token:
        raise RunError("no Intercom token (MUSOAI_INTERCOM_TOKEN / INTERCOM_TOKEN, INTERCOM_ENV_FILE, "
                       "or /etc/openclaw/main.env)")
    return token


def contact_external_ids(conv_id: str, *, get: Callable[..., Any] | None = None) -> list[str]:
    """The `external_id`s of the conversation's contacts. Empty only when the conversation genuinely has
    no contact: an unreadable Intercom raises `RunError` (a stopped run, retried next hour) instead of
    degrading into a durable `identity_unlinked` tag that parks the ticket forever."""
    if not conv_id:
        return []
    token = intercom_token()
    getter = get or _intercom_get
    conv = getter(f"/conversations/{urllib.parse.quote(conv_id)}", token)
    refs = ((conv.get("contacts") or {}).get("contacts") or []) if isinstance(conv, dict) else []
    out: list[str] = []
    for ref in refs[:5]:
        cid = ref.get("id") if isinstance(ref, dict) else None
        if not cid:
            continue
        detail = getter(f"/contacts/{urllib.parse.quote(str(cid))}", token)
        ext = str((detail or {}).get("external_id") or "").strip()
        if ext:
            out.append(ext)
    return sorted(set(out))


def _intercom_get(path: str, token: str, *, timeout: int = 30) -> dict:
    req = urllib.request.Request(f"{INTERCOM_API}{path}", method="GET",
                                 headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                                          "Intercom-Version": "2.11"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as exc:
        raise RunError(f"Intercom GET {path} -> HTTP {exc.code}") from exc
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise RunError(f"Intercom GET {path} failed: {type(exc).__name__}") from exc


def link_identity(ext_ids: Iterable[str], candidate_profile_id: str, *,
                  query: Callable[[str], list[list[str]]] | None = None
                  ) -> tuple[str, bool, str]:
    """(account id, linked, why) for one ticket.

    The account comes from the VERIFIED Intercom contact's `external_id` through
    `identity_resolver` (r5). `linked` is true only when exactly one account owns that id AND that
    account OWNS `candidate_profile_id` (`identity_resolver.owns`: its own professional id, a processed
    claim's profile, or its representation profile). The customer's message text is never an input to
    this function."""
    exts = [str(x).strip() for x in ext_ids if str(x or "").strip()]
    if not exts:
        return "", False, "no verified contact id on the conversation"
    query = query or trino

    from credit_review import identity_resolver  # noqa: PLC0415 - read-only sibling module

    try:
        resolved = identity_resolver.resolve(exts, query)
    except RunError:
        raise
    except Exception as exc:  # noqa: BLE001
        # A read that did not COMPLETE is not a negative identity result. `identity_unlinked` is a
        # DURABLE `needs-customer` tag, so answering it from a broken read would park a valid ticket
        # forever, even after the replica recovers. Only a completed read may say "not linked".
        raise RunError(f"identity lookup failed: {type(exc).__name__}: {exc}") from exc
    accounts = {r.account_id for r in resolved.values() if r.account_id is not None}
    why = "; ".join(sorted({r.why for r in resolved.values() if r.why}))[:200]
    if not accounts:
        return "", False, f"no account owns this contact ({why or 'unresolved'})"
    if len(accounts) > 1:
        return "", False, f"{len(accounts)} accounts own this contact ({why or 'ambiguous'})"
    account = str(next(iter(accounts)))
    if not candidate_profile_id:
        return account, False, "ticket names no profile"
    try:
        owned = identity_resolver.owns(account, candidate_profile_id, query)
    except RunError:
        raise
    except Exception as exc:  # noqa: BLE001
        # Same rule as the lookup above: an unreadable ownership answer is not "not owned".
        raise RunError(f"profile ownership unreadable: {type(exc).__name__}: {exc}") from exc
    if owned:
        return account, True, ""
    return account, False, ("the ticket's profile is not one this account owns (its own professional "
                            "id, a processed claim, or its representation profile)")


# ── track resolution ────────────────────────────────────────────────────────
def _credit_title(item: dict) -> str:
    for key in ("title", "trackTitle", "track_title", "name"):
        if item.get(key):
            return str(item[key])
    track = item.get("track")
    if isinstance(track, dict) and track.get("title"):
        return str(track["title"])
    return ""


def _norm(text: Any) -> str:
    return " ".join(str(text or "").lower().split())


def profile_credits(api: Any, profile_id: str, **params: Any) -> list[dict[str, Any]]:
    """The profile's credits, PAGED. An unreadable profile raises `RunError` (a stopped run) rather
    than becoming a durable `track_unresolved` tag on a ticket nobody will look at again.

    Page-based on purpose: `/admin/profile/:id/credits` IGNORES `offset` and echoes page 1 back, so
    an offset walk would silently truncate. Reading only page 1 is worse than truncation here: a
    requested track on page 2+ would be reported absent, and `track_unresolved` is a DURABLE
    `needs-customer` tag, so a credit the customer really holds would never be hidden or removed.
    A short list is never returned: a surprise shape or a walk that cannot finish raises."""
    out: list[dict[str, Any]] = []
    for page in range(1, CREDITS_MAX_PAGES + 1):
        try:
            data = api.get(f"/admin/profile/{profile_id}/credits",
                           {"limit": CREDITS_PAGE_LIMIT, "page": page, **params})
        except RunError:
            raise
        except Exception as exc:  # noqa: BLE001 - any read failure is "cannot read", never "no such track"
            raise RunError(f"profile {profile_id} credits unreadable: {type(exc).__name__}") from exc
        items = data.get("items") if isinstance(data, dict) else None
        if not isinstance(items, list):
            raise RunError(f"profile {profile_id} credits unreadable")
        out.extend(i for i in items if isinstance(i, dict))
        total = data.get("total")
        if isinstance(total, int):
            if len(out) >= total:
                return out
            if not items:
                raise RunError(f"profile {profile_id}: credits list truncated at {len(out)}/{total} "
                               "with an empty page")
            continue
        # No total: a page shorter than the limit is the last page.
        if len(items) < CREDITS_PAGE_LIMIT:
            return out
    raise RunError(f"profile {profile_id}: credits list did not finish in {CREDITS_MAX_PAGES} pages")


def resolve_track(api: Any, profile_id: str, *, track_id: str = "", title: str = "") -> tuple[dict[str, Any], str]:
    """(the profile's credit row for that track, why not). An explicit id is trusted only when the
    profile's own credits confirm it; a title must match EXACTLY ONE of them. The drainer never guesses
    which track a customer meant."""
    if track_id:
        items = profile_credits(api, profile_id)
        match = [it for it in items if str(it.get("trackId") or it.get("track_id") or "") == track_id]
        if not match:
            return {}, "track_id is not among the profile's credits"
        return match[0], ""
    if not title:
        return {}, "intent names no track"
    items = profile_credits(api, profile_id, keyword=title)
    hits = [it for it in items if _norm(_credit_title(it)) == _norm(title)]
    ids = {str(it.get("trackId") or it.get("track_id") or "") for it in hits}
    ids.discard("")
    if len(ids) != 1:
        return {}, f"track {title!r} matched {len(ids)} of the profile's credits"
    return hits[0], ""


def roles_of(item: dict[str, Any]) -> tuple[str, ...]:
    """Every role the profile holds on that credit. `not_me` covers them all."""
    roles = item.get("roles") or item.get("credits") or []
    out: list[str] = []
    for role in roles if isinstance(roles, (list, tuple)) else [roles]:
        name = role.get("role") or role.get("name") if isinstance(role, dict) else role
        if str(name or "").strip():
            out.append(str(name).strip())
    return tuple(dict.fromkeys(out))


def claimant_name_of(api: Any, profile_id: str) -> str:
    """The name Muso credits (the profile's own display name), for the proof prompt. Empty on failure:
    a name we could not read is not evidence either way."""
    try:
        data = api.get(f"/admin/profile/{profile_id}")
    except Exception:  # noqa: BLE001
        return ""
    if isinstance(data, dict):
        for key in ("name", "displayName", "title"):
            if data.get(key):
                return str(data[key])[:120]
    return ""


def _note(task: dict[str, Any], disposition: str, why: str, **extra: Any) -> dict[str, Any]:
    note: dict[str, Any] = {"disposition": disposition, "why": why,
                            "conversation_id": intercom_link.conv_id_of(task),
                            "verbatim": verbatim_of(task)}
    note.update(extra)
    return note


def assemble(api: Any, tasks: Iterable[dict[str, Any]], *,
             ext_ids_for: Callable[[str], list[str]] | None = None,
             identity_query: Callable[[str], list[list[str]]] | None = None,
             comments_api: Any = None
             ) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    """(rows, per-ticket notes). A ticket that cannot be executed becomes a note with an honest
    disposition name; a ticket whose every track resolved becomes rows.

    `api` is the READ admin (credits, claimant name). `comments_api` is the ClickUp client, which is
    the only thing that can read a ticket's follow-up comments; it defaults to `api` so a caller that
    has one client for both keeps working."""
    rows: list[dict[str, Any]] = []
    notes: dict[str, dict[str, Any]] = {}
    ext_ids_for = ext_ids_for or contact_external_ids
    for task in tasks:
        tid = str(task.get("id"))
        profile_id = profile_id_of(task)
        wanted, why_intent = intents(task, followup_details(comments_api or api, task))
        if why_intent:
            notes[tid] = _note(task, "needs_customer", why_intent, profile_id=profile_id)
            continue
        if not profile_id:
            notes[tid] = _note(task, "needs_customer", "ticket names no profile")
            continue
        conv_id = intercom_link.conv_id_of(task) or ""
        account, linked, why_link = link_identity(ext_ids_for(conv_id), profile_id, query=identity_query)
        if not linked:
            notes[tid] = _note(task, "identity_unlinked", why_link or "identity not linked",
                               profile_id=profile_id, account=account)
            continue
        built: list[dict[str, Any]] = []
        claimant = claimant_name_of(api, profile_id)
        for track in wanted["tracks"]:
            item, why = resolve_track(api, profile_id,
                                      track_id=track if _is_id(track) else "", title=track)
            if why:
                notes[tid] = _note(task, "track_unresolved", why, profile_id=profile_id)
                built = []
                break
            track_id = str(item.get("trackId") or item.get("track_id") or "")
            built.append({
                "ticket_id": tid, "profile_id": profile_id, "intent": wanted["intent"],
                "track_id": track_id, "track_name": _credit_title(item), "conversation_id": conv_id,
                "account_id": account, "identity_linked": True, "roles": list(roles_of(item)),
                "claimant_name": claimant, "proof_urls": wanted["proof_urls"],
                "verbatim": verbatim_of(task)})
        if not built:
            continue
        keys = [(r["ticket_id"], r["track_id"], r["intent"]) for r in built]
        if len(keys) != len(set(keys)):
            notes[tid] = _note(task, "needs_customer",
                               "ticket asks for two rows on the same track", profile_id=profile_id)
            continue
        rows.extend(built)
    return rows, notes


def _is_id(text: str) -> bool:
    return bool(re.fullmatch(r"[0-9a-fA-F-]{8,}", str(text or "")))


# ── ClickUp writes ──────────────────────────────────────────────────────────
def apply_outcome(api: clickup_client.ClickUp, task: dict[str, Any], outcome: str, *,
                  close: bool = True, sleep: Callable[[float], None] = time.sleep
                  ) -> tuple[str, str]:
    """Replace the ticket's `customer-outcome:` tags with exactly `outcome`, then READ IT BACK. When
    `outcome` is `complete` and `close` is set, also move the ticket to `resolved` — the tag alone is not
    a close (`lib/customer_outcome.customer_complete` needs a terminal status too, and
    resolve-notify.py refuses to message a customer about anything else).

    Returns `(established, problem)`."""
    tid = str(task["id"])
    desired = customer_outcome.outcome_tag(outcome)
    existing = customer_outcome.outcome_tags_of(task)
    for tag in sorted(existing - {desired}):
        api.request("DELETE", f"/task/{tid}/tag/{urllib.parse.quote(tag, safe='')}")
    if desired not in existing:
        api.request("POST", f"/task/{tid}/tag/{urllib.parse.quote(desired, safe='')}", body={})
    if outcome != customer_outcome.OUTCOME_COMPLETE or not close:
        _, fresh = api.request("GET", f"/task/{tid}")
        fresh = fresh if isinstance(fresh, dict) else {}
        got = customer_outcome.customer_outcome_of(fresh)
        if got != outcome:
            raise RunError(f"customer outcome read-back failed for {tid}: wrote {outcome}, read {got}")
        return outcome, ""
    fresh: dict[str, Any] = {}
    problem = ""
    try:
        api.request("PUT", f"/task/{tid}", body={"status": "resolved"})
        for attempt in range(READBACK_TRIES):
            _, fresh = api.request("GET", f"/task/{tid}")
            fresh = fresh if isinstance(fresh, dict) else {}
            if customer_outcome.customer_complete(fresh):
                return outcome, ""
            if attempt + 1 < READBACK_TRIES:
                sleep(READBACK_POLL_S)
        problem = ("outcome written but ClickUp left the task "
                   f"{str((fresh.get('status') or {}).get('status') or 'non-terminal')!r}")
    except (RuntimeError, OSError) as exc:
        problem = f"outcome written but the ClickUp close failed: {str(exc)[:200]}"
    downgraded = _downgrade_to_partial(api, tid, desired)
    return "partial", (
        problem + "; tag downgraded from complete to partial" if downgraded
        else problem + f"; WARNING could not replace {desired} with partial — a human must untag {tid}")


def _downgrade_to_partial(api: clickup_client.ClickUp, tid: str, desired: str) -> bool:
    """Replace `complete` with `partial` so the ticket stays workable. Best effort by design: a ticket
    that is still open must not keep a `complete` tag nothing will ever look at again."""
    partial = customer_outcome.outcome_tag("partial")
    try:
        api.request("DELETE", f"/task/{tid}/tag/{urllib.parse.quote(desired, safe='')}")
        api.request("POST", f"/task/{tid}/tag/{urllib.parse.quote(partial, safe='')}", body={})
    except (RuntimeError, OSError):
        return False
    return True


def ask_line(note: dict[str, Any], rows: list[dict[str, Any]], *, retry: bool = False) -> str:
    """The internal note that turns "the public sources still list you" into an action. It is NOT
    customer copy (a ticket comment, notify_all off): the only approved customer note goes through
    intercom-verify-request.sh and says nothing about this check. `retry` is the UNREADABLE case: the
    link on file could not be read, so the next ask is visibly one more, never a first ask."""
    asks = []
    for row in rows:
        track = row.get("track_name") or row.get("track_id") or "the track"
        roles = ", ".join(f"'{r}'" for r in (row.get("roles") or [])) or "the role on the credit"
        asks.append(f"{track} ({roles})")
    if retry:
        head = ("[hydra credit-removal] the link on file could not be read, so nothing is removed and "
                "the check is not settled.")
    else:
        head = ("[hydra credit-removal] the public credits still list this person on that track, so "
                "nothing is removed.")
    body = "; ".join(asks) if asks else str(note.get("why") or "")
    return (f"{head} Ask the customer for one LINK that shows the right person credited on it (the "
            f"track's credit page on a public credit source) and reply here with it. Track: {body}")


def comment_ask(api: clickup_client.ClickUp, task: dict[str, Any], line: str, *,
                state_dir: str, today: str) -> bool:
    """Post the proof ask ONCE per ticket per day, and return whether it went out."""
    tid = str(task["id"])
    path = Path(state_dir) / "asked.json"
    try:
        asked = json.loads(path.read_text())
        if not isinstance(asked, dict):
            asked = {}
    except (OSError, ValueError):
        asked = {}
    if asked.get(tid) == today:
        return False
    _, sent = api.request("POST", f"/task/{tid}/comment",
                          body={"comment_text": line, "notify_all": False})
    if not isinstance(sent, dict) or sent.get("id") is None:
        raise RunError(f"comment on {tid} was not accepted by ClickUp")
    asked[tid] = today
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(asked, indent=0, sort_keys=True) + "\n")
    return True


def untag(api: clickup_client.ClickUp, task: dict[str, Any]) -> None:
    """Remove every `customer-outcome:` tag from a reverted ticket and put it back on the board (a
    reverted ticket is a human's again)."""
    tid = str(task["id"])
    for tag in sorted(customer_outcome.outcome_tags_of(task)):
        api.request("DELETE", f"/task/{tid}/tag/{urllib.parse.quote(tag, safe='')}")
    if customer_outcome.workflow_terminal(task):
        api.request("PUT", f"/task/{tid}", body={"status": "to do"})
    _, fresh = api.request("GET", f"/task/{tid}")
    if customer_outcome.outcome_tags_of(fresh if isinstance(fresh, dict) else {}):
        raise RunError(f"outcome tags still present on {tid} after a revert")


# ── the run ─────────────────────────────────────────────────────────────────
def digest_lines(notes: dict[str, dict[str, Any]],
                 executed: dict[str, list[dict[str, Any]]]) -> list[str]:
    """One line per ticket (and per row) that was not written, naming the ticket and the reason."""
    out = []
    for tid, note in sorted(notes.items()):
        words = f' | "{note["verbatim"]}"' if note.get("verbatim") else ""
        conv = f" [{note['conversation_id']}]" if note.get("conversation_id") else ""
        out.append(f"{tid}: {note.get('disposition')}: {note.get('why')}{conv}{words}")
    for tid, rows in sorted(executed.items()):
        for r in rows:
            if r.get("disposition") in ("hide", "removed", "gate_filed"):
                continue
            out.append(f"{tid}: {r.get('disposition')}: {r.get('track_id') or ''}: {r.get('why')}")
    return out


def _atomic_batch(rows: list[dict[str, Any]], cap: int) -> tuple[list[dict[str, Any]], list[str]]:
    """(the rows of the tickets that fit under `cap`, the ticket ids that did not). A ticket is taken
    whole or not at all: a half-executed ticket would be tagged from the rows that ran while the rest of
    its request was silently lost."""
    order: list[str] = []
    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        tid = str(row.get("ticket_id"))
        if tid not in grouped:
            grouped[tid] = []
            order.append(tid)
        grouped[tid].append(row)
    batch: list[dict[str, Any]] = []
    deferred: list[str] = []
    for tid in order:
        if len(batch) + len(grouped[tid]) <= cap:
            batch.extend(grouped[tid])
        else:
            deferred.append(tid)
    return batch, deferred


def _apply_outcomes(api: clickup_client.ClickUp, tasks: list[dict[str, Any]],
                    executed: dict[str, list[dict[str, Any]]], notes: dict[str, dict[str, Any]], *,
                    state_dir: str, now: Callable[[], datetime],
                    log: Callable[[str], None],
                    sleep: Callable[[float], None]) -> tuple[dict[str, str], dict[str, str],
                                                             dict[str, str]]:
    """Tag, ask, or close each ticket. Runs INSIDE the drainer's credit-write lock: the credit state
    the executor just wrote and the ticket transition this makes are one step, so a concurrent
    `--revert` cannot interleave between them."""
    tags_applied: dict[str, str] = {}
    problems: dict[str, str] = {}
    comments: dict[str, str] = {}
    for tid in sorted(set(executed) | set(notes)):
        task = next((t for t in tasks if str(t.get("id")) == tid), None)
        if task is None:
            continue
        if tid in executed:
            outcome = rx.ticket_outcome([r.get("disposition") for r in executed[tid]])
        else:
            outcome = rx.TAG_FOR.get(str(notes[tid].get("disposition") or ""))
        if outcome is None:
            # the answer has not landed (a gate still checking, a proof we still need): no tag, so
            # the ticket stays in the queue and the next run sees it again
            continue
        if outcome == "verification-required":
            rows = executed.get(tid, [])
            asking = [r for r in rows if r.get("disposition") == "proof_required"]
            verdicts = [str(r.get("proof_verdict") or "") for r in asking]
            if verdicts and all(v == "different" for v in verdicts):
                log(f"{tid}: a proof names a different person; the gate has what it needs")
                continue
            line = ask_line(notes.get(tid) or {}, rows,
                            retry=any(v == "unreadable" for v in verdicts))
            if len(comments) < COMMENT_MAX_PER_RUN and comment_ask(
                    api, task, line, state_dir=state_dir, today=now().strftime("%Y-%m-%d")):
                comments[tid] = line
                log(f"{tid}: asked for a proof that shows the right person (left on the board)")
            continue
        established, problem = apply_outcome(
            api, task, outcome, close=(outcome == customer_outcome.OUTCOME_COMPLETE), sleep=sleep)
        tags_applied[tid] = established
        if problem:
            problems[tid] = problem
        log(f"{tid}: tagged customer-outcome:{established}"
            + (" and resolved" if established == customer_outcome.OUTCOME_COMPLETE else "")
            + (f" — {problem}" if problem else ""))
    return tags_applied, problems, comments


def run(*, list_id: str = LIST_ID, apply: bool = False, only: str | None = None,
        limit: int | None = None, rows_out: str | None = None,
        api: clickup_client.ClickUp | None = None, read_api: Any = None,
        executor_run: Callable[..., rx.Result] = rx.run,
        ext_ids_for: Callable[[str], list[str]] | None = None,
        identity_query: Callable[[str], list[list[str]]] | None = None,
        kill_file: str = KILL_FILE, state_dir: str = STATE_DIR,
        log: Callable[[str], None] | None = None,
        lock: Callable[[], Any] = rx.locked,
        sleep: Callable[[float], None] = time.sleep,
        now: Callable[[], datetime] = lambda: datetime.now(timezone.utc)) -> dict[str, Any]:
    """One drainer run. Dry run by default: the executor decides and reports, and NOTHING (no ClickUp
    tag, no core row) is written."""
    log = log or (lambda msg: print(msg, file=sys.stderr))
    if os.path.exists(kill_file):
        return {"mode": "apply" if apply else "dry-run", "stopped": f"kill file {kill_file} present",
                "tickets": 0, "rows": 0}
    api = api or client()
    if read_api is None:
        from credit_retro.api import WrapperReadApi  # noqa: PLC0415
        read_api = WrapperReadApi()
    try:
        tasks = select_tickets(api, list_id, only=only)
    except RunError as exc:
        # `--ticket` on a ticket the filters exclude is an operator error, not a run to make noise about
        return {"mode": "apply" if apply else "dry-run", "stopped": str(exc), "tickets": 0, "rows": 0}
    log(f"credit-removal: {len(tasks)} open ticket(s) to consider")
    tasks = tasks[:TICKETS_MAX] if not only else tasks
    try:
        rows, notes = assemble(read_api, tasks, ext_ids_for=ext_ids_for, identity_query=identity_query,
                               comments_api=api)
    except RunError as exc:
        return {"mode": "apply" if apply else "dry-run", "stopped": str(exc), "tickets": 0, "rows": 0}
    batch, deferred = _atomic_batch(rows, limit if limit else BATCH_MAX)
    # A second-resolution name is NOT unique: a manual `--ticket` run beside the hourly cron in the
    # same second would write the SAME rows file, and the second writer would replace the first's
    # batch before the executor opened it. The suffix makes the name unique, and the same name is
    # handed to the executor as its run_id, so `--revert <run_id>` can never undo two runs' writes.
    run_name = f"{now().strftime('%Y%m%dT%H%M%SZ')}-{os.urandom(3).hex()}"
    path = Path(rows_out) if rows_out else Path(state_dir) / f"rows-{run_name}.json"
    @contextlib.contextmanager
    def _inner_lock():
        # The drainer holds the shared credit-write lock across the WHOLE batch (see below), so the
        # executor must not take it again: flock on a second descriptor in one process blocks, and
        # that would deadlock the run against itself.
        yield

    def _execute() -> dict[str, Any]:
        if not batch:
            return {"dispositions": {}, "stopped": "", "writes": 0}
        Path(state_dir).mkdir(parents=True, exist_ok=True)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"rows": batch}, indent=1, sort_keys=True) + "\n")
        return executor_run(str(path), apply=apply, log=log, run_id=run_name,
                            lock=_inner_lock).as_dict()

    def _grouped(summary: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
        # the executor keys its rows by row_key (ticket:profile:track:intent); ClickUp works by ticket
        out: dict[str, list[dict[str, Any]]] = {}
        for rows_out in (summary.get("dispositions") or {}).values():
            for item in rows_out:
                tid = str(item.get("ticket_id") or "")
                if tid:
                    out.setdefault(tid, []).append(item)
        return out

    summary: dict[str, Any] = {"dispositions": {}, "stopped": "", "writes": 0}
    executed: dict[str, list[dict[str, Any]]] = {}
    tags_applied: dict[str, str] = {}
    problems: dict[str, str] = {}
    comments: dict[str, str] = {}
    if apply:
        # The credit write and the ticket close are ONE transition. Holding the shared lock across
        # both means a `--revert` cannot land between the executor finishing a hide and this loop
        # closing the ticket: it would unhide the credit and untag, and this loop would then re-tag
        # it `complete` with the credit visible again. `revert()` takes the same lock, so the two
        # are serialized; whichever arrives second sees the other's result.
        try:
            with lock():
                summary = _execute()
                executed = _grouped(summary)
                if not summary.get("stopped"):
                    tags_applied, problems, comments = _apply_outcomes(
                        api, tasks, executed, notes, state_dir=state_dir, now=now, log=log,
                        sleep=sleep)
        except TimeoutError as exc:
            summary["stopped"] = f"the credit write lock was busy: {exc}"
    else:
        summary = _execute()
        executed = _grouped(summary)
    digest = digest_lines(notes, executed)
    if summary.get("stopped"):
        digest.insert(0, f"executor stopped: {summary['stopped']} (nothing was attempted, nothing tagged)")
        log(f"executor stopped ({summary['stopped']}): nothing was attempted, so nothing is tagged")
    for line in digest:
        log(f"  {line}")
    return {"mode": "apply" if apply else "dry-run", "list_id": list_id, "rows_file": str(path),
            "tickets_considered": len(tasks), "tickets_with_rows": len({r['ticket_id'] for r in rows}),
            "rows": len(batch), "deferred_tickets": deferred, "executor": summary, "notes": notes,
            "tags_applied": tags_applied, "problems": problems, "comments": comments,
            "digest": digest, "stopped": summary.get("stopped", "")}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="write (default: dry run, nothing written)")
    ap.add_argument("--list-id", default=LIST_ID)
    ap.add_argument("--ticket", help="one ClickUp ticket id (a re-run after a human looked)")
    ap.add_argument("--limit", type=int, help="at most N rows this run")
    ap.add_argument("--rows-out", help="also write the assembled rows file here")
    ap.add_argument("--state-dir", default=STATE_DIR, help="where the per-run rows files are kept")
    ap.add_argument("--revert", metavar="RUN_ID", help="replay a run's inverses and untag its tickets")
    ap.add_argument("--skip-host-guard", action="store_true",
                    help="run off ovh-node-8 anyway (tests only; never on a workstation with the key)")
    args = ap.parse_args(argv)

    hostname = os.environ.get("CLICKUP_CREDIT_REMOVAL_HOSTNAME") or socket.gethostname()
    if not args.skip_host_guard and hostname != HOST_GUARD:
        print(f"clickup-credit-removal: refusing to run on {hostname!r}; it writes ClickUp tickets and "
              f"core credit rows on {HOST_GUARD} only (--skip-host-guard overrides)", file=sys.stderr)
        return 2
    if args.revert:
        api = client()
        untagged: list[str] = []

        def _untag(rows: list[dict[str, Any]]) -> None:
            # Runs INSIDE the executor's credit-write lock, so a concurrent apply run cannot re-tag
            # the ticket between the undo landing and the tag coming off.
            for tid in sorted({str(r.get("ticket_id")) for r in rows}):
                _, task = api.request("GET", f"/task/{tid}")
                if isinstance(task, dict):
                    untag(api, task)
                    untagged.append(tid)

        res = rx.revert(args.revert, log=lambda m: print(m, file=sys.stderr), untag=_untag)
        res["untagged"] = sorted(untagged)
        print(json.dumps(res, sort_keys=True))
        return 0 if not res.get("stopped") else 1
    summary = run(list_id=args.list_id, apply=args.apply, only=args.ticket, limit=args.limit,
                  rows_out=args.rows_out, state_dir=args.state_dir)
    print(json.dumps(summary, sort_keys=True))
    return 0 if not summary.get("stopped") else 1


if __name__ == "__main__":
    sys.exit(main())
