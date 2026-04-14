"""Gog-CLI adapter for Slack."""
from __future__ import annotations

from ._gog import run_gog
from .config import DEVOPS_CHANNEL, SALES_ALERTS_CHANNEL


def _run_gog(*args: str) -> None:
    run_gog(*args, timeout=15)


def post_sales_alert(text: str) -> None:
    _run_gog("slack", "chat", "postMessage",
             "--channel", SALES_ALERTS_CHANNEL,
             "--text", text)


def post_devops_alert(text: str) -> None:
    _run_gog("slack", "chat", "postMessage",
             "--channel", DEVOPS_CHANNEL,
             "--text", text)
