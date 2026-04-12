#!/usr/bin/env python3
"""Analyze fetched Intercom conversations for CS knowledge base improvement.

Reads conversations.jsonl and produces:
1. Topic distribution (what customers actually ask about)
2. Resolution patterns (closed vs open, time to close, reassignment count)
3. Common opening messages (to inform greeting/triage patterns)
4. Failure signals (high reassignment, long time-to-close, reopens)

Output: data/analysis-report.md
"""

import json
import re
import sys
from collections import Counter
from pathlib import Path
from html.parser import HTMLParser

DATA_DIR = Path(__file__).parent / "data"
INPUT = DATA_DIR / "conversations.jsonl"
OUTPUT = DATA_DIR / "analysis-report.md"


class HTMLStripper(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []

    def handle_data(self, data):
        self.parts.append(data)

    def get_text(self):
        return " ".join(self.parts).strip()


def strip_html(html: str) -> str:
    s = HTMLStripper()
    s.feed(html or "")
    return s.get_text()


# Keyword-based topic classifier
TOPIC_PATTERNS = [
    ("profile_claim", r"\b(claim|claiming|verify|verification)\b.*\b(profile|account)\b"),
    ("profile_merge", r"\b(merge|duplicate|merging)\b.*\b(profile|account|name)\b"),
    ("profile_update", r"\b(update|change|edit)\b.*\b(profile|name|photo|image|picture|bio)\b"),
    ("profile_not_found", r"\b(can.?t find|not showing|missing|where.?s)\b.*\b(profile|name|me)\b"),
    ("credits_missing", r"\b(missing|not showing|where)\b.*\b(credit|song|track)\b"),
    ("credits_wrong", r"\b(wrong|incorrect|error|fix)\b.*\b(credit|role|song)\b"),
    ("credits_add", r"\b(add|submit|claim)\b.*\b(credit|song|track|album)\b"),
    ("analytics", r"\b(analytics|stats|streams|streaming|data|numbers)\b"),
    ("subscription", r"\b(subscription|subscribe|plan|upgrade|downgrade|pro|business|billing|payment|charge|refund|cancel)\b"),
    ("login_access", r"\b(log.?in|sign.?in|password|access|locked|can.?t get in)\b"),
    ("technical", r"\b(bug|error|crash|broken|not working|loading|slow|glitch)\b"),
    ("audit", r"\b(audit|royalt|mlc|isrc|iswc|mechanical)\b"),
    ("api_developer", r"\b(api|developer|endpoint|integration|webhook)\b"),
    ("delete_account", r"\b(delete|remove)\b.*\b(account|profile|data)\b"),
    ("general_inquiry", r"\b(what is|how does|tell me about|information)\b.*\b(muso)\b"),
]


def classify_topic(text: str) -> str:
    text_lower = text.lower()
    for topic, pattern in TOPIC_PATTERNS:
        if re.search(pattern, text_lower):
            return topic
    return "other"


def main():
    if not INPUT.exists():
        print(f"Run fetch-conversations.py first. Missing: {INPUT}", file=sys.stderr)
        sys.exit(1)

    conversations = []
    with open(INPUT) as f:
        for line in f:
            conversations.append(json.loads(line))

    if not conversations:
        print("No conversations found in input file", file=sys.stderr)
        sys.exit(1)

    print(f"Loaded {len(conversations)} conversations", file=sys.stderr)

    # Topic distribution
    topic_counter = Counter()
    state_counter = Counter()
    opening_messages = Counter()
    high_reassignment = []  # > 3 assignments
    long_resolution = []  # > 7 days to first close
    reopened = []

    for c in conversations:
        body = strip_html(c["source_body"])
        topic = classify_topic(body)
        topic_counter[topic] += 1
        state_counter[c["state"]] += 1

        # Track common opening patterns (first 50 chars, normalized)
        opener = body[:50].strip().lower()
        if opener:
            opening_messages[opener] += 1

        # Failure signals
        stats = c.get("stats", {})
        if stats.get("assignments", 0) > 3:
            high_reassignment.append({"id": c["id"], "body": body[:100], "assignments": stats["assignments"]})
        ttfc = stats.get("time_to_first_close")
        if ttfc and ttfc > 604800:  # 7 days in seconds
            long_resolution.append({"id": c["id"], "body": body[:100], "days": round(ttfc / 86400, 1)})
        if stats.get("reopens", 0) > 0:
            reopened.append({"id": c["id"], "body": body[:100], "reopens": stats["reopens"]})

    # Generate report
    lines = ["# CS Conversation Analysis Report\n"]
    lines.append(f"**Total conversations analyzed:** {len(conversations)}\n")
    lines.append("**Date range:** pre-March 2026\n\n")

    lines.append("## Topic Distribution\n")
    lines.append("| Topic | Count | % |")
    lines.append("|-------|-------|---|")
    for topic, count in topic_counter.most_common():
        pct = round(100 * count / len(conversations), 1)
        lines.append(f"| {topic} | {count} | {pct}% |")

    lines.append("\n## Conversation State\n")
    lines.append("| State | Count | % |")
    lines.append("|-------|-------|---|")
    for state, count in state_counter.most_common():
        pct = round(100 * count / len(conversations), 1)
        lines.append(f"| {state} | {count} | {pct}% |")

    lines.append("\n## Top 30 Opening Messages\n")
    lines.append("| Message | Count |")
    lines.append("|---------|-------|")
    for msg, count in opening_messages.most_common(30):
        lines.append(f"| {msg} | {count} |")

    lines.append("\n## Failure Signals\n")
    lines.append(f"### High Reassignment (>3 assignments): {len(high_reassignment)} conversations\n")
    for item in high_reassignment[:20]:
        lines.append(f"- [{item['id']}] {item['assignments']} assignments: {item['body']}")

    lines.append(f"\n### Long Resolution (>7 days): {len(long_resolution)} conversations\n")
    for item in long_resolution[:20]:
        lines.append(f"- [{item['id']}] {item['days']} days: {item['body']}")

    lines.append(f"\n### Reopened: {len(reopened)} conversations\n")
    for item in reopened[:20]:
        lines.append(f"- [{item['id']}] {item['reopens']} reopens: {item['body']}")

    report = "\n".join(lines)
    OUTPUT.write_text(report)
    print(f"Report saved to {OUTPUT}", file=sys.stderr)
    print(report)


if __name__ == "__main__":
    main()
