"""Shared subprocess wrapper for the gog CLI.

All adapter modules (gmail_client, sheets_client, slack_client) call
run_gog() instead of duplicating subprocess.run boilerplate.
"""
from __future__ import annotations

import subprocess


def run_gog(*args: str, timeout: int = 30) -> str:
    """Run a gog CLI command and return stdout as a string.

    Raises subprocess.CalledProcessError on non-zero exit.
    Callers that don't need the output can discard the return value.
    """
    res = subprocess.run(
        ("gog", *args),
        check=True,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return res.stdout
