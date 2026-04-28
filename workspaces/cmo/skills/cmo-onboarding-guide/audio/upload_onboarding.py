#!/usr/bin/env python3
"""Upload the 12-part Muso onboarding audio guide to a Slack channel/thread.

Usage:
    python3 upload_onboarding.py <CHANNEL_ID> [THREAD_TS]

Reads the CMO bot token from openclaw-main.json.
"""

import requests
import os
import sys
import json
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(SCRIPT_DIR)

# Load token
with open("/opt/hydra/openclaw-main.json") as f:
    cfg = json.load(f)
SLACK_TOKEN = cfg["channels"]["slack"]["accounts"]["cmo"]["botToken"]

# Load transcripts for titles/descriptions
with open(os.path.join(SKILL_DIR, "transcripts.json")) as f:
    PARTS = json.load(f)

headers = {"Authorization": f"Bearer {SLACK_TOKEN}"}


def upload_part(channel_id, thread_ts, part_num):
    """Upload one part with text intro + audio file."""
    key = str(part_num)
    part = PARTS[key]
    title = part["title"]
    desc = part["description"]

    filepath = os.path.join(SCRIPT_DIR, f"part_{part_num:02d}.mp3")
    filesize = os.path.getsize(filepath)
    filename = f"Part_{part_num:02d}_{title.replace(' ', '_').replace(',', '').replace('?', '').replace('—', '-')}.mp3"

    intro = f":headphones: *Part {part_num} — {title}*\n_{desc}_"

    print(f"  [{part_num}/12] {title}...", flush=True)

    # Step 1: Get upload URL
    resp = requests.post(
        "https://slack.com/api/files.getUploadURLExternal",
        headers=headers,
        data={"filename": filename, "length": filesize},
    )
    data = resp.json()
    if not data.get("ok"):
        print(f"    ❌ getUploadURL: {data.get('error')}", flush=True)
        return False

    upload_url = data["upload_url"]
    file_id = data["file_id"]

    # Step 2: Upload file bytes
    with open(filepath, "rb") as f:
        resp2 = requests.post(upload_url, files={"file": (filename, f, "audio/mpeg")})
    if resp2.status_code != 200:
        print(f"    ❌ upload: HTTP {resp2.status_code}", flush=True)
        return False

    # Step 3: Complete upload
    complete_payload = {
        "files": [{"id": file_id, "title": f"Part {part_num} — {title}"}],
        "channel_id": channel_id,
        "initial_comment": intro,
    }
    if thread_ts:
        complete_payload["thread_ts"] = thread_ts

    resp3 = requests.post(
        "https://slack.com/api/files.completeUploadExternal",
        headers={**headers, "Content-Type": "application/json"},
        json=complete_payload,
    )
    data3 = resp3.json()
    if not data3.get("ok"):
        print(f"    ❌ complete: {data3.get('error')}", flush=True)
        return False

    print(f"    ✅ uploaded", flush=True)
    return True


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 upload_onboarding.py <CHANNEL_ID> [THREAD_TS]")
        sys.exit(1)

    channel_id = sys.argv[1]
    thread_ts = sys.argv[2] if len(sys.argv) > 2 else None

    print(f"=== Uploading Muso Onboarding Guide (12 parts) ===")
    print(f"  Channel: {channel_id}")
    print(f"  Thread:  {thread_ts or '(top-level)'}\n")

    success = 0
    for i in range(1, 13):
        if upload_part(channel_id, thread_ts, i):
            success += 1
        time.sleep(2)

    print(f"\n=== Done: {success}/12 uploaded ===")


if __name__ == "__main__":
    main()
