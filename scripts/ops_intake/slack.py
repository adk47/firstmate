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
TIMEOUT_S = 20
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
    query = urllib.parse.urlencode({"channel": channel, "ts": thread_ts, "limit": 200})
    req = urllib.request.Request(
        f"{REPLIES_API}?{query}",
        headers={"Authorization": "Bearer " + token}, method="GET")
    opener = fetch or urllib.request.urlopen
    with opener(req, timeout=TIMEOUT_S) as resp:
        payload = json.loads(resp.read() or b"{}")
    if not payload.get("ok"):
        raise RuntimeError(f"conversations.replies failed: {payload.get('error')}")
    for message in payload.get("messages") or []:
        if not isinstance(message, dict):
            continue
        if str(message.get("ts") or "") <= after_ts:
            continue
        if not (message.get("bot_id") or message.get("subtype") == "bot_message"):
            continue
        contract = CONTRACT_LINE.match(str(message.get("text") or ""))
        if contract is not None and ask_id is not None and contract.group(1) != ask_id:
            continue
        return True
    return False


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
