"""Shared Intercom conversation-link resolution for ClickUp support tickets.

The "Intercom Link" custom field (#417) carries the conversation deeplink
https://app.intercom.com/a/inbox/<ws>/inbox/conversation/<convId>, from which we
recover the conversation id for precise (non-email) ticket<->conversation
matching. Tickets filed before #417, and some filed from the description path,
carry the deeplink only in the body — hence the fallback.

This module is the canonical definition. `resolve-notify.py`,
`close-resolved-conversations.py`, `overdue-verification-notifier.py` and
`resolution-matcher.py` each still carry their own byte-identical copy with a
"MUST mirror" comment; any change here MUST be made there too until those
callers are migrated. The ids must stay byte-identical across all of them —
a conv id extracted one way but not another silently breaks cross-script
matching (a notifier defer set keyed on a different id fails to defer).
"""
import os
import re

# "Intercom Link" custom field added in #417 (default mirrors support-tools'
# plugins/support-tools/src/index.ts).
INTERCOM_LINK_FIELD = os.environ.get(
    "CLICKUP_INTERCOM_LINK_FIELD_ID", "c32dbf6e-f680-4ff1-a532-192bb96245c3")
# Excludes quotes too. Must stay byte-identical to resolve-notify.py's
# _CONV_ID_RE and close-resolved-conversations.py's _CONV_ID_RE.
CONV_ID_RE = re.compile(r"/conversation/([^/?#\s\"']+)")


def conv_id_from_link(value):
    """Recover the Intercom conversation id from an "Intercom Link" value."""
    m = CONV_ID_RE.search(str(value))
    return m.group(1) if m else None


def conv_id_of(task):
    """Recover the Intercom conversation id, #417 field first (structured),
    description deeplink second. None when neither is present/parseable."""
    for cf in task.get("custom_fields") or []:
        if cf.get("id") == INTERCOM_LINK_FIELD and cf.get("value"):
            cid = conv_id_from_link(cf["value"])
            if cid:
                return cid
    desc = task.get("description") or task.get("text_content") or ""
    for line in desc.splitlines():
        if "**Conversation:**" in line or "/inbox/conversation/" in line:
            cid = conv_id_from_link(line)
            if cid:
                return cid
    return None
