"""The single resolution point for the Intercom admin id we post under.

2026-08-31: customers saw support replies signed "Nicholas Sollazzo" because an
agent composed an Intercom call using a human's admin id. Doctrine and a CI gate
now cover the agent path (skills-all/muso-intercom/SKILL.md,
scripts/check-intercom-reply-identity.sh), but eight unattended writers still
resolved the id as `os.environ.get("INTERCOM_ADMIN_ID", "5763097")` with no
validation, in three subtly different variants.

That mattered: `/etc/openclaw/main.env` sets the var to Aaron's admin id
(5201828), and the main gateway's process env carries it too, so any of those
scripts run by an agent from that gateway posted under a human's identity. The
systemd timers were never affected — their units load shared.env/edge.env, which
do not set the var — which is precisely why this stayed invisible: the scheduled
path was right and only the agent path was wrong.

**The posting identity is a constant of the system, not a configurable.**

A value that is not Caroline's is IGNORED and reported loudly, rather than
obeyed or treated as fatal:

  - obeying it is the customer-visible bug this exists to prevent;
  - refusing outright would strand customer notifications behind a config typo,
    and would turn a currently-working agent path into a hard failure the moment
    it ran against the live (wrong) env;
  - ignoring is the only option that is both always-correct and non-disruptive.

Allowlist, not blocklist: this module names the one id that IS allowed and
refuses everything else, so an id nobody thought to forbid — a new teammate's,
a typo, an encoding that decodes at runtime — is refused without an edit here.
Enumerating forbidden ids is the design that lost an arms race twice on PR #900.
"""
from __future__ import annotations

import os
import sys
from typing import Mapping, Optional

# The ONE admin id an unattended writer may post as: Caroline
# (operations@muso.ai). Named in docs/lessons/muso-domain.md and the
# muso-intercom skill, and asserted by scripts/check-intercom-reply-identity.sh
# — all three must change together if this ever moves.
CAROLINE_ADMIN_ID = "5763097"

ENV_VAR = "INTERCOM_ADMIN_ID"

# Greppable prefix so an operator can find these in a journal, matching the
# convention the intercom plugin uses for its own lanes.
_LOG_PREFIX = "[intercom:identity]"


def resolve_admin_id(env: Optional[Mapping[str, str]] = None) -> str:
    """Return the admin id to post under. Always Caroline's.

    `env` defaults to the process environment; pass a mapping to test.

    An unset or blank ``INTERCOM_ADMIN_ID`` is simply "not configured" and
    resolves silently. Any other value that is not Caroline's id is ignored,
    with a warning on stderr naming the rejected value and the variable, so the
    misconfiguration is fixable rather than merely survivable.
    """
    if env is None:
        env = os.environ

    raw = env.get(ENV_VAR)
    if raw is None:
        return CAROLINE_ADMIN_ID

    candidate = raw.strip()
    if not candidate:
        # Exported-but-empty is "unset", not "set wrongly". One of the three
        # resolution variants in the tree got this wrong and would have used
        # the empty string as an admin id.
        return CAROLINE_ADMIN_ID

    if candidate == CAROLINE_ADMIN_ID:
        return CAROLINE_ADMIN_ID

    print(
        f"{_LOG_PREFIX} {ENV_VAR}={candidate!r} is not Caroline "
        f"({CAROLINE_ADMIN_ID}); ignoring it and posting as Caroline. "
        f"Customer-facing writes must never be attributed to a human. "
        f"Unset {ENV_VAR} or set it to {CAROLINE_ADMIN_ID} to silence this.",
        file=sys.stderr,
    )
    return CAROLINE_ADMIN_ID
