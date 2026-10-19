"""Resolve a Slack token read from the raw openclaw config.

openclaw-main.json stores `channels.slack.accounts.*.botToken` as a SecretRef
(`{"source": "env", "provider": "hydra-env", "id": "MUSO_SLACK_BOT_TOKEN_X"}`).
The gateway resolves refs itself; scripts that json.load() the file do not, and
an unresolved ref dict is truthy, so it would be sent as a Bearer token. Every
script that reads a Slack token from that config goes through resolve_secret().

Always returns a str; "" means unresolved, which every caller already treats
as "no token".
"""

from __future__ import annotations

import os
import re
import sys

GATEWAY_ENV_FILE = "/etc/openclaw/main.env"  # the gateway's EnvironmentFile


def _from_env_file(name: str, path: str) -> str:
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
                if m and m.group(1) == name:
                    return m.group(2).strip().strip("'\"")
    except OSError:
        pass
    return ""


def resolve_secret(value, env=None, env_file: str = GATEWAY_ENV_FILE) -> str:
    if isinstance(value, str):
        return value
    if not isinstance(value, dict) or value.get("source") != "env":
        return ""
    name = value.get("id")
    if not isinstance(name, str) or not name:
        return ""
    env = os.environ if env is None else env
    token = env.get(name) or _from_env_file(name, env_file)
    if not token:
        print(f"slack_token: {name} not set in env or {env_file}", file=sys.stderr)
    return token
