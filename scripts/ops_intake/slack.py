"""Slack I/O for the router: reply in the asker's thread, and page #clio_devops.

Two operations, both narrow:

* :func:`post_message` - ``chat.postMessage`` as the ``operations`` bot, with
  ``thread_ts`` so the reply lands in the ask's thread (spec j2 item 5). Returns
  the message ts, or raises: a reply the caller believes was posted but was not
  is how a row ends up ``answered`` with an empty thread.
* :func:`page` - ``scripts/lib/slack-notify.sh``'s
  ``slack_notify_critical_status``, i.e. #clio_devops with the on-call owners
  actually mentioned. It RETURNS the delivery status instead of swallowing it
  (a page nobody received must not look like one that landed) and never raises
  at the caller: a failed page must not undo an answer.

The bot token is resolved through ``lib/slack_token.resolve_secret`` so an
unresolved openclaw SecretRef can never be sent as a Bearer token. Tokens come
from the process env first (the gateway child inherits it) and then
``/etc/openclaw/main.env``.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

_SCRIPTS = Path(__file__).resolve().parents[1]
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

from lib.slack_token import resolve_secret  # noqa: E402

API = "https://slack.com/api/chat.postMessage"
REPLIES_API = "https://slack.com/api/conversations.replies"
HISTORY_API = "https://slack.com/api/conversations.history"
TIMEOUT_S = 20
# A bound on the cursor walk, not a budget: 50 pages x 200 is far beyond any operations thread we have, and a cursor
# that loops or never empties must not hang the intake. Hitting it simply stops the walk, so the caller sees only the
# pages it did read and fails closed on the rest (an ask read refuses; the completion signal reads as unanswered).
MAX_PAGES = 50
TOKEN_ENV = {
    "operations": "MUSO_SLACK_BOT_TOKEN_OPERATIONS",
    "devops": "MUSO_SLACK_BOT_TOKEN_DEVOPS",
}
PAGE_CHANNEL = "C0ADV2W76G4"  # #clio_devops


def token_for(account: str = "operations") -> str:
    name = TOKEN_ENV.get(account, TOKEN_ENV["operations"])
    return resolve_secret({"source": "env", "provider": "hydra-env", "id": name})


def post_message(*, channel: str, thread_ts: str | None, text: str,
                 account: str = "operations") -> str:
    """Post ``text``; return the Slack ts. Raises on any non-confirmed send."""
    token = token_for(account)
    if not token:
        raise RuntimeError(f"no Slack token resolved for account {account!r}")
    body: dict[str, object] = {"channel": channel, "text": text,
                               "unfurl_links": False, "unfurl_media": False}
    if thread_ts:
        body["thread_ts"] = thread_ts
    req = urllib.request.Request(
        API, data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + token,
                 "Content-Type": "application/json; charset=utf-8"},
        method="POST")
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
        payload = json.loads(resp.read() or b"{}")
    if not payload.get("ok"):
        raise RuntimeError(f"chat.postMessage failed: {payload.get('error')}")
    return str(payload.get("ts") or "")


CONTRACT_LINE = re.compile(r"^[a-z-]+ \u00b7 (oa-[0-9A-Za-z-]+) \u00b7 ")


def thread_has_bot_reply(*, channel: str, thread_ts: str, after_ts: str,
                         ask_id: str | None = None,
                         account: str = "operations", fetch=None) -> bool:
    """Did the bot post in this thread after the ask? The agent turn's completion
    signal: a hand-off row is only closed when a reply actually exists.

    The router posts its own contract lines into the same thread, and each carries
    its ask id, so a contract line for ANOTHER ask is not this ask's answer.

    Raises on any read failure - an unreadable thread is UNKNOWN, and the caller
    escalates rather than assuming the agent answered.
    """
    token = token_for(account)
    if not token:
        raise RuntimeError(f"no Slack token resolved for account {account!r}")
    for messages in _iter_pages(fetch or urllib.request.urlopen, token, REPLIES_API, channel, {"ts": thread_ts}):
        for message in messages:
            if str(message.get("ts") or "") <= after_ts:
                continue
            if not (message.get("bot_id") or message.get("subtype") == "bot_message"):
                continue
            contract = CONTRACT_LINE.match(str(message.get("text") or ""))
            if contract is not None and ask_id is not None and contract.group(1) != ask_id:
                continue
            return True
    return False


def _find_message(opener, token: str, channel: str, ts: str) -> dict | None:
    """The message whose ``ts`` is EXACTLY ``ts``, from the thread first and the channel second.

    ``conversations.history`` returns only top-level channel messages, so an ask posted as a thread reply - the
    normal shape for this bot - is invisible to it. ``conversations.replies`` walks the thread the ts belongs to
    (Slack accepts any message ts in the thread, not just the parent). Both are asked for the whole window up to
    ``ts`` and the exact ts is required, so a neighbouring message can never stand in for the ask.
    """
    for api, extra in ((REPLIES_API, {"ts": ts}), (HISTORY_API, {})):
        message = _page_to_ts(opener, token, api, channel, ts, extra)
        if message is not None:
            return message
    return None


def _iter_pages(opener, token: str, api: str, channel: str, query_extra: dict):
    """Yield each page's messages, following ``response_metadata.next_cursor``.

    ``conversations.replies`` is CURSOR-PAGINATED and returns messages OLDEST FIRST, so a single ``limit=200`` request
    for a long thread never contains its latest replies. Reading one page was wrong twice in this module: a staff ask
    that was reply 201+ was absent, the ts was not found, and ``hide.py`` exited 6 filing nothing (QA review
    5904456478, Important); and the completion signal had the same hole, where a bot reply past reply 200 would look
    like an unanswered thread forever. Following the cursor is the documented way to read a whole thread
    (https://docs.slack.dev/reference/methods/conversations.replies/).

    The walk never short-circuits on the timestamps it has already seen: pages arrive OLDEST FIRST, so an early stop
    keyed on "we have read back past the ask" would skip every LATER page - exactly where a bot reply or a staff ask
    lives. ``MAX_PAGES`` bounds a broken or looping cursor; a walk that hits the bound simply stops yielding (the
    caller fails closed on whatever it did not see).

    Raises on a failed read: an unreadable thread is UNKNOWN, never "not there".
    """
    cursor = ""
    for _ in range(MAX_PAGES):
        query = {"channel": channel, **query_extra, "limit": 200}
        if cursor:
            query["cursor"] = cursor
        req = urllib.request.Request(
            f"{api}?{urllib.parse.urlencode(query)}",
            headers={"Authorization": "Bearer " + token}, method="GET")
        with opener(req, timeout=TIMEOUT_S) as resp:
            payload = json.loads(resp.read() or b"{}")
        if not payload.get("ok"):
            raise RuntimeError(f"{api.rsplit('/', 1)[-1]} failed: {payload.get('error')}")
        messages = [m for m in payload.get("messages") or [] if isinstance(m, dict)]
        yield messages
        cursor = str((payload.get("response_metadata") or {}).get("next_cursor") or "")
        if not cursor:
            return


def _page_to_ts(opener, token: str, api: str, channel: str, ts: str, extra: dict) -> dict | None:
    """The message whose ``ts`` is EXACTLY ``ts``, or None.

    Walks every page (see ``_iter_pages``) because the ask may be reply 201+ of a long thread, and requires an exact
    ts so a neighbour can never stand in for it. Returns None on any unreadable page rather than raising: the caller
    reads "not found" as UNKNOWN and refuses, so a broken page must not be mistaken for a found message either."""
    try:
        for messages in _iter_pages(opener, token, api, channel,
                                    {**extra, "latest": ts, "inclusive": "true"}):
            for message in messages:
                if str(message.get("ts") or "") == ts:
                    return message
    except (RuntimeError, OSError, ValueError):
        return None
    return None


def message_author(*, channel: str, ts: str, account: str = "operations", fetch=None) -> tuple[str, str]:
    """``(author, body)`` for the message at ``ts`` in ``channel``.

    The intake's identity control AND its only source of ask text. A caller-supplied
    requester id proves only that the caller typed a staff id, and caller-supplied
    ask text proves nothing at all, so an ask is bound to the message it names: the
    author must equal the requester and the body is what the parser reads. The message
    is looked for in the thread it belongs to first and in the channel's top-level
    messages second, so an ask posted as a thread reply resolves. Raises on EVERY
    unreadable case - no token, a transport error, ``ok:false``, no message with that
    exact ts in the channel or its threads, a message with no author, or a message
    with no text - because an unreadable identity or ask is UNKNOWN, and UNKNOWN is a
    refusal.
    """
    token = token_for(account)
    if not token:
        raise RuntimeError(f"no Slack token resolved for account {account!r}")
    opener = fetch or urllib.request.urlopen
    message = _find_message(opener, token, channel, ts)
    if message is None:
        raise RuntimeError(
            f"no message at ts {ts} in {channel} or in its threads "
            f"(conversations.replies and conversations.history both returned no message with that exact ts)")
    user = str(message.get("user") or "")
    if not user:
        raise RuntimeError(f"the message at ts {ts} in {channel} has no author")
    body = str(message.get("text") or "").strip()
    if not body:
        raise RuntimeError(f"the message at ts {ts} in {channel} has no text")
    return user, body


def page(text: str) -> bool:
    """Page #clio_devops with the on-call owners mentioned.

    Returns the DELIVERY status: True only when the helper exited 0. It never
    raises, but a page nobody received must never look like one that landed.
    """
    script = _SCRIPTS / "lib" / "slack-notify.sh"
    if not script.is_file():
        print(f"ops_intake.slack: paging helper missing at {script}", file=sys.stderr)
        return False
    try:
        proc = subprocess.run(
            ["bash", "-c",
             'set -euo pipefail; source "$1"; slack_notify_critical_status "$2"',
             "slack-notify", str(script), text],
            check=False, timeout=60, capture_output=True, text=True,
            env={**__import__("os").environ, "SLACK_CHANNEL": PAGE_CHANNEL})
    except Exception as exc:  # noqa: BLE001 - reported as an undelivered page
        print(f"ops_intake.slack: page failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return False
    if proc.returncode != 0:
        print(f"ops_intake.slack: page not delivered (rc={proc.returncode}): "
              f"{(proc.stderr or '').strip()[:300]}", file=sys.stderr)
        return False
    return True
