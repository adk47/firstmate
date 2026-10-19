"""Slack adapter for the outreach sender worker.

Hydra posts to Slack via the Web API directly (not via gog — gog is
Google-only). Bot tokens live in `/root/.openclaw-main/openclaw.json`
under `channels.slack.accounts.<bot>.botToken`. Same pattern as
`scripts/outage-notify.py` and `scripts/hydra-daily-audit.py`.

Sales alerts post as the CMO bot (the CMO workspace owns outreach);
devops red alerts post as the devops bot so they land in `#clio_devops`
from an appropriate author.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

from ..slack_token import resolve_secret
from .config import DEVOPS_CHANNEL, SALES_ALERTS_CHANNEL

_OPENCLAW_CONFIG = "/root/.openclaw-main/openclaw.json"

# Cache bot tokens per-process.
_TOKENS: dict[str, str] = {}


def _load_token(bot: str) -> str:
    """Read the named bot's token from openclaw.json. Raises if missing."""
    if bot in _TOKENS:
        return _TOKENS[bot]
    path = os.environ.get("MUSO_OUTREACH_OPENCLAW_CONFIG", _OPENCLAW_CONFIG)
    with open(path) as f:
        c = json.load(f)
    accts = c.get("channels", {}).get("slack", {}).get("accounts", {})
    token = resolve_secret(accts.get(bot, {}).get("botToken", ""))
    if not token:
        raise RuntimeError(
            f"No Slack bot token for '{bot}' in {path}. "
            "Check channels.slack.accounts.<bot>.botToken."
        )
    _TOKENS[bot] = token
    return token


def _post(token: str, channel: str, text: str) -> None:
    """POST to Slack Web API. Raises on non-OK response."""
    data = json.dumps(
        {"channel": channel, "text": text, "unfurl_links": False}
    ).encode()
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=data,
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json; charset=utf-8",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        body = json.loads(resp.read())
    if not body.get("ok"):
        raise RuntimeError(f"Slack postMessage failed: {body!r}")


def post_sales_alert(text: str) -> None:
    _post(_load_token("cmo"), SALES_ALERTS_CHANNEL, text)


def post_devops_alert(text: str) -> None:
    _post(_load_token("devops"), DEVOPS_CHANNEL, text)
