#!/usr/bin/env python3
"""
Win-Back Sanity Check
Cross-checks sheet, GHL, and Gmail to catch drift.
Run daily as part of the heartbeat.
"""

import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

SHEET_ID = "1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs"
TAB = "High-Value Churns"
GHL_KEY = os.environ.get("GHL_WINBACK_API_KEY", "")  # was hardcoded; env var since MUS-20329
GHL_LOCATION = "fmK5Vl9sJv49WTYA0QyP"
GHL_PIPELINE = "AZa8jK5S7UyQ0fqfxzyB"
GMAIL_ACCOUNT = "a@muso.ai"


def gog_cmd(args, timeout=15):
    cmd = ["gog"] + args + ["--account", GMAIL_ACCOUNT]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return result.stdout, result.stderr, result.returncode


def ghl_api(method, endpoint):
    import urllib.request
    url = f"https://services.leadconnectorhq.com{endpoint}"
    if "?" in url:
        url += f"&locationId={GHL_LOCATION}"
    else:
        url += f"?locationId={GHL_LOCATION}"

    headers = {
        "Authorization": f"Bearer {GHL_KEY}",
        "Version": "2021-07-28",
        "User-Agent": "muso-hydra-ghl/1.0 (+ops@muso.ai)",  # urllib's default UA gets Cloudflare 403 1010 (MUS-20329)
        "Accept": "application/json",
    }
    req = urllib.request.Request(url, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except Exception as e:
        return None


def require_ghl_key():
    """Fail closed before any side effect when the GHL key is not in the environment (MUS-20382)."""
    if not GHL_KEY:
        sys.exit("GHL_WINBACK_API_KEY is not set; refusing to run (no email, sheet or GHL call made).")


def run_sanity_check():
    require_ghl_key()
    issues = []
    stats = {}

    print("=== Win-Back Sanity Check ===")
    print(f"Date: {datetime.now().strftime('%Y-%m-%d %H:%M')}\n")

    # 1. Sheet status
    print("1. Sheet check...")
    out, err, rc = gog_cmd([
        "sheets", "get", SHEET_ID,
        f"'{TAB}'!S2:S1198", "-j"
    ], timeout=30)

    if rc == 0:
        data = json.loads(out)
        values = data.get("values", [])
        emailed = sum(1 for v in values if v and "Emailed" in v[0])
        total = len(values)
        remaining = total - emailed
        stats["sheet_total"] = total
        stats["sheet_emailed"] = emailed
        stats["sheet_remaining"] = remaining
        print(f"  Total: {total} | Emailed: {emailed} | Remaining: {remaining}")
    else:
        issues.append("Could not read sheet")

    # 2. GHL pipeline check
    print("\n2. GHL pipeline check...")
    result = ghl_api("GET", f"/opportunities/search?pipeline_id={GHL_PIPELINE}&limit=1")
    if result:
        total_opps = result.get("meta", {}).get("total", 0)
        stats["ghl_total_opps"] = total_opps
        print(f"  Total opportunities: {total_opps}")

        # Check for stage distribution
        for stage_name, stage_id in [
            ("Churned", "819bd77b-9b34-4773-bdb3-4f532f925a9a"),
            ("Emailed", "c01f6866-106a-4663-b177-93af8603a920"),
            ("Replied", "73b66a22-98cb-47a5-b4fd-3b558394cc7b"),
            ("Re-subscribed", "e51bd206-edec-4bb5-b344-39b2d96cd39e"),
        ]:
            r = ghl_api("GET", f"/opportunities/search?pipeline_id={GHL_PIPELINE}&stageId={stage_id}&limit=1")
            if r:
                count = r.get("meta", {}).get("total", 0)
                stats[f"ghl_{stage_name.lower()}"] = count
                print(f"  {stage_name}: {count}")
    else:
        issues.append("Could not query GHL pipeline")

    # 3. Cross-check: sheet emailed vs GHL emailed
    if "sheet_emailed" in stats and "ghl_emailed" in stats:
        diff = abs(stats["sheet_emailed"] - stats["ghl_emailed"])
        if diff > 5:
            issues.append(f"Sheet/GHL drift: sheet says {stats['sheet_emailed']} emailed, GHL says {stats['ghl_emailed']}")
            print(f"\n  WARNING: Sheet/GHL drift detected ({diff} difference)")

    # 4. Gmail send count check
    print("\n3. Gmail check...")
    today = datetime.now().strftime("%Y-%m-%d")
    log_file = Path.home() / f".openclaw/workspace/api-logs/gmail/{today}.jsonl"
    if log_file.exists():
        with open(log_file) as f:
            sends = [json.loads(l) for l in f if "winback_send" in l]
        stats["gmail_sends_today"] = len(sends)
        print(f"  Sends logged today: {len(sends)}")
    else:
        stats["gmail_sends_today"] = 0
        print("  No sends logged today")

    # 5. Rate limit check
    print("\n4. Rate limit check...")
    if stats.get("gmail_sends_today", 0) > 450:
        issues.append(f"Approaching Gmail daily limit: {stats['gmail_sends_today']}/500")

    # Summary
    print("\n=== SUMMARY ===")
    if issues:
        print(f"ISSUES FOUND ({len(issues)}):")
        for issue in issues:
            print(f"  - {issue}")
    else:
        print("All checks passed.")

    stats["issues"] = issues
    stats["timestamp"] = datetime.now().isoformat()

    with open("/tmp/winback_sanity.json", "w") as f:
        json.dump(stats, f, indent=2)

    return stats


if __name__ == "__main__":
    run_sanity_check()
