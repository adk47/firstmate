#!/usr/bin/env python3
"""Fetch pre-March-2026 Intercom conversations for CS analysis.

Uses the search endpoint (source.body + metadata). Does NOT fetch
full conversation parts -- that would be 20k individual API calls.

Output: data/conversations.jsonl (one JSON object per conversation)
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

API_BASE = "https://api.intercom.io"
TOKEN = os.environ.get("INTERCOM_TOKEN")
# Before March 1 2026 00:00 UTC (pre-Caroline era)
CREATED_BEFORE = 1772323200
PER_PAGE = 150  # Intercom max
TARGET = 20_000
OUTPUT = Path(__file__).parent / "data" / "conversations.jsonl"


def fetch_page(starting_after: str | None = None) -> dict:
    # Use search endpoint -- the list endpoint ignores created_at_before
    payload: dict = {
        "query": {"field": "created_at", "operator": "<", "value": CREATED_BEFORE},
        "pagination": {"per_page": PER_PAGE},
    }
    if starting_after:
        payload["pagination"]["starting_after"] = starting_after

    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{API_BASE}/conversations/search",
        data=body,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Intercom-Version": "2.11",
        },
        method="POST",
    )

    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            if e.code == 429:
                retry_after = int(e.headers.get("Retry-After", 10))
                print(f"  Rate limited, waiting {retry_after}s...", file=sys.stderr)
                time.sleep(retry_after)
                continue
            raise
        except urllib.error.URLError:
            if attempt < 2:
                time.sleep(2 ** attempt)
                continue
            raise
    raise RuntimeError("Max retries exceeded")


def main():
    if not TOKEN:
        print("Set INTERCOM_TOKEN env var", file=sys.stderr)
        sys.exit(1)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    total = 0
    starting_after = None

    with open(OUTPUT, "w") as f:
        while total < TARGET:
            data = fetch_page(starting_after)
            convos = data.get("conversations", [])
            if not convos:
                break

            for c in convos:
                src = c.get("source") or {}
                record = {
                    "id": c["id"],
                    "created_at": c["created_at"],
                    "state": c["state"],
                    "source_body": src.get("body", ""),
                    "source_subject": src.get("subject", ""),
                    "source_author_type": (src.get("author") or {}).get("type", ""),
                    "admin_assignee_id": c.get("admin_assignee_id"),
                    "ai_title": (c.get("custom_attributes") or {}).get("AI Title", ""),
                    "tags": [t["name"] for t in (c.get("tags") or {}).get("tags", [])],
                    "stats": {
                        "parts": (c.get("statistics") or {}).get("count_conversation_parts", 0),
                        "assignments": (c.get("statistics") or {}).get("count_assignments", 0),
                        "reopens": (c.get("statistics") or {}).get("count_reopens", 0),
                        "time_to_first_close": (c.get("statistics") or {}).get("time_to_first_close"),
                        "time_to_admin_reply": (c.get("statistics") or {}).get("time_to_admin_reply"),
                    },
                }
                f.write(json.dumps(record) + "\n")
                total += 1

            next_page = data.get("pages", {}).get("next", {})
            starting_after = next_page.get("starting_after") if next_page else None
            if not starting_after:
                break

            print(f"  Fetched {total} conversations...", file=sys.stderr)
            time.sleep(0.5)  # Be nice to the API

    print(f"Done. {total} conversations saved to {OUTPUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
