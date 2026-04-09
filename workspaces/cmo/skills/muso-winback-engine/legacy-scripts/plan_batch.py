#!/usr/bin/env python3
"""
Win-Back Batch Planner
Runs at midnight to select tomorrow's 120 contacts and mark them as "Next Up" in the sheet.
Groups by timezone and assigns send windows.
"""

import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

SHEET_ID = "1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs"
TAB = "High-Value Churns"
GMAIL_ACCOUNT = "a@muso.ai"
BATCH_SIZE = 120

EU_COUNTRIES = [
    "Germany", "France", "Italy", "Netherlands", "Sweden", "Spain",
    "Belgium", "Austria", "Switzerland", "Denmark", "Norway", "Finland",
    "Poland", "Romania", "Czech Republic", "Hungary", "Greece", "Portugal",
    "Ireland", "United Kingdom", "Turkey",
]
US_COUNTRIES = ["United States", "Canada"]
APAC_COUNTRIES = [
    "India", "Japan", "South Korea", "Australia", "New Zealand",
    "Philippines", "Singapore", "Indonesia", "Thailand",
]


def gog_cmd(args, timeout=30):
    cmd = ["gog"] + args + ["--account", GMAIL_ACCOUNT]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return result.stdout, result.stderr, result.returncode


def read_sheet():
    out, err, rc = gog_cmd([
        "sheets", "get", SHEET_ID,
        f"'{TAB}'!A1:AF1198", "-j"
    ])
    if rc != 0:
        print(f"Error: {err}")
        return [], []
    data = json.loads(out)
    values = data.get("values", [])
    if not values:
        return [], []
    headers = values[0]
    rows = []
    for i, v in enumerate(values[1:], start=2):
        row = {}
        for j, h in enumerate(headers):
            row[h] = v[j] if j < len(v) else ""
        row["_sheet_row"] = i
        rows.append(row)
    return headers, rows


def select_batch(rows, size=120):
    """Select next batch prioritized by value."""
    unsent = [r for r in rows if not r.get("email_template", "").strip()]

    def priority(r):
        pop = int(r.get("popularity", "0") or "0")
        credits = int(r.get("credits_count", "0") or "0")
        ltv_str = r.get("Total LTV", "$0").replace("$", "")
        try:
            ltv = float(ltv_str)
        except:
            ltv = 0
        reason = r.get("cancel_reason", "")

        score = 0
        if pop >= 80:
            score += 1000
        if credits > 500:
            score += 500
        if reason == "payment_failed":
            score += 300
        score += ltv
        return -score

    unsent.sort(key=priority)
    return unsent[:size]


def assign_batch_label(row):
    country = row.get("Country", "")
    if country in EU_COUNTRIES:
        return "Next Up: EU (6am PST)"
    elif country in US_COUNTRIES:
        return "Next Up: US (9am PST)"
    elif country in APAC_COUNTRIES:
        return "Next Up: APAC (5pm PST)"
    else:
        return "Next Up: Other (10am PST)"


def main():
    tomorrow = datetime.now().strftime("%Y-%m-%d")
    print(f"=== Win-Back Batch Planner ===")
    print(f"Planning batch for: {tomorrow}")

    headers, rows = read_sheet()
    if not rows:
        print("No data!")
        return

    # Clear any existing "Next Up" labels
    print("Clearing old Next Up labels...")
    for row in rows:
        if row.get("Next Up", "").startswith("Next Up"):
            gog_cmd([
                "sheets", "update", SHEET_ID,
                f"'{TAB}'!Y{row['_sheet_row']}",
                "--values-json", json.dumps([[""]]),
            ])

    # Select batch
    batch = select_batch(rows, BATCH_SIZE)
    print(f"Selected {len(batch)} contacts")

    # Group and label
    groups = {}
    for row in batch:
        label = assign_batch_label(row)
        groups.setdefault(label, []).append(row)

    for label, group in groups.items():
        print(f"  {label}: {len(group)}")
        for row in group:
            gog_cmd([
                "sheets", "update", SHEET_ID,
                f"'{TAB}'!Y{row['_sheet_row']}",
                "--values-json", json.dumps([[label]]),
            ])

    # Summary
    total_ltv = sum(
        float(r.get("Total LTV", "$0").replace("$", "") or "0")
        for r in batch
    )

    summary = {
        "date": tomorrow,
        "total": len(batch),
        "groups": {k: len(v) for k, v in groups.items()},
        "total_ltv": f"${total_ltv:,.2f}",
        "remaining_after": len([r for r in rows if not r.get("email_template", "").strip()]) - len(batch),
    }

    print(f"\nBatch value: {summary['total_ltv']}")
    print(f"Remaining after this batch: {summary['remaining_after']}")

    with open("/tmp/winback_batch_plan.json", "w") as f:
        json.dump(summary, f, indent=2)


if __name__ == "__main__":
    main()
