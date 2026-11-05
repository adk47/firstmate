#!/usr/bin/env python3
"""Watch one Intercom conversation for customer parts after a proof request."""

import json
import os
import subprocess
import sys
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


CONVERSATION_ID = "215476219633630"
SENT_PART_ID = "57690102978"
DEADLINE = datetime(2026, 11, 11, 14, 15, tzinfo=timezone.utc)
STATE_PATH = Path("/opt/hydra/workspaces/coordinator/tmp/zak-proof-monitor-state.json")


def fetch():
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    if not token:
        raise RuntimeError("MUSOAI_INTERCOM_TOKEN is unavailable in the gateway environment")
    request = urllib.request.Request(
        f"https://api.intercom.io/conversations/{CONVERSATION_ID}",
        headers={
            "Authorization": f"Bearer {token}",
            "Intercom-Version": "2.11",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=25) as response:
        return json.load(response)


def save_state(state):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=STATE_PATH.parent, delete=False) as output:
        json.dump(state, output)
        temporary = output.name
    os.replace(temporary, STATE_PATH)


def disable(job_id):
    if not job_id:
        raise RuntimeError("Watch job id is missing")
    subprocess.run(
        ["openclaw", "--profile", "main", "cron", "disable", job_id],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=30,
    )


def main():
    state = json.loads(STATE_PATH.read_text()) if STATE_PATH.exists() else {}
    data = fetch()
    parts = data.get("conversation_parts", {}).get("conversation_parts", [])
    if not parts:
        parts = data.get("conversation_parts", {}).get("parts", [])
    anchor = next((part for part in parts if str(part.get("id")) == SENT_PART_ID), None)
    if not anchor:
        raise RuntimeError("Sent proof request part is absent from Intercom response")

    if "--probe" in sys.argv:
        print(json.dumps({
            "conversation": str(data.get("id")),
            "state": data.get("state"),
            "part_count": len(parts),
            "anchor_created_at": anchor.get("created_at"),
            "proof_request_parts": [
                {
                    "id": str(part.get("id")),
                    "body_present": bool(part.get("body")),
                    "deleted": part.get("deleted"),
                    "redacted": part.get("redacted"),
                    "part_type": part.get("part_type"),
                }
                for part in parts
                if str(part.get("id")) in ("57689661898", SENT_PART_ID)
            ],
            "last_parts": [
                {
                    "id": str(part.get("id")),
                    "created_at": part.get("created_at"),
                    "part_type": part.get("part_type"),
                    "author_type": (part.get("author") or {}).get("type"),
                    "attachment_count": len(part.get("attachments") or []),
                }
                for part in parts[-5:]
            ],
        }))
        return

    anchor_at = int(anchor.get("created_at") or 0)
    seen = set(state.get("seen_part_ids", []))
    new_parts = [
        part for part in parts
        if int(part.get("created_at") or 0) > anchor_at
        and str(part.get("id")) not in seen
        and (part.get("author") or {}).get("type") != "admin"
        and part.get("part_type") in ("comment", "reply")
    ]
    if new_parts:
        seen.update(str(part.get("id")) for part in new_parts)
        state["seen_part_ids"] = sorted(seen)
        save_state(state)
        ids = ", ".join(str(part.get("id")) for part in new_parts)
        attachments = sum(len(part.get("attachments") or []) for part in new_parts)
        print(
            f"Zak replied in the existing Intercom conversation "
            f"(https://app.intercom.com/a/inbox/_/inbox/search?query={CONVERSATION_ID}). "
            f"New customer part(s): {ids}; attachment count: {attachments}. "
            "Proof needs review before any credit decision. No further customer message was sent."
        )
    elif datetime.now(timezone.utc) < DEADLINE:
        print("NO_REPLY")

    if datetime.now(timezone.utc) >= DEADLINE:
        disable(state.get("job_id"))
        if not new_parts:
            print("Zak has not replied to the proof request after seven days; the watch has ended.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Zak proof monitor failed: {error}", file=sys.stderr)
        raise SystemExit(1)
