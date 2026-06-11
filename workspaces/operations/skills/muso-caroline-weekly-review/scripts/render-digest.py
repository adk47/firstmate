#!/usr/bin/env python3
"""Deterministic renderer for the validated+redacted structured digest.

Reads digest JSON on stdin, writes to stdout either:
  --text    the plain-text digest (the announce-delivery fallback; pipe it
            through redact-output.sh | linkify-convs.sh |
            assert-digest-contract.sh exactly like the legacy path), or
  --blocks  the full Slack chat.postMessage payload (channel + notification
            text + Block Kit blocks) for post-digest.sh.

WHY a script, not the LLM: same doctrine as assert-digest-contract.sh — the
header semantics (status emoji, P0 ping, severity triplet, scores line, the
always-present guard section) are COMPUTED here from the validated counts, so
no model on the fallback chain can drop or mangle them. The LLM never authors
Block Kit JSON and never hand-writes Intercom URLs.

Both modes share every line-building helper, so the Block Kit post and the
plain-text fallback can never drift apart. This file is the single in-skill
source of the P0 ping Slack id.

Env (blocks mode): CAROLINE_DIGEST_CHANNEL — override the target channel
(default #cs_chats C0ANM0PN9L5); used by the shadow-channel rollout.
"""

import json
import os
import re
import sys
from datetime import datetime

PING_USER = "U0AL36NADEY"           # pinged on line 1 ONLY when P0 > 0
DEFAULT_CHANNEL = "C0ANM0PN9L5"     # cs_chats
CONV_URL = "https://app.intercom.com/a/inboxes/all/conversations/"
# Mirrors linkify-convs.sh: lookbehind excludes 0-9 (longer digit runs),
# / (already-inside-a-URL) and | (already a link label) so the pass is
# idempotent; the only 15-16 digit tokens in the digest are conversation ids.
LINK_RE = re.compile(r"(?<![0-9/|])([0-9]{15,16})(?![0-9])")
SECTION_CHAR_CAP = 2800             # Slack section text hard limit is 3000
MAX_BULLETS = 10                    # per section; overflow is counted, never silent

DIMENSIONS = [  # render order; good_catch last so wins close each digest
    ("voice", "\U0001f399️", "Voice"),
    ("tools", "\U0001f6e0️", "Tools"),
    ("sentiment", "\U0001f61f", "Sentiment"),
    ("good_catch", "✅", "Good catch"),
]
THEME_CATEGORY = {
    "issue": "\U0001f41b issue",
    "question": "❓ question",
    "feature_request": "\U0001f4a1 feature ask",
    "escalation_pattern": "\U0001f6a8 escalation",
}
WEEKLY_THEME_GROUPS = [
    ("issue", "\U0001f41b Recurring issues"),
    ("question", "❓ Recurring questions"),
    ("feature_request", "\U0001f4a1 Feature asks"),
    ("escalation_pattern", "\U0001f6a8 Escalation patterns"),
]


def linkify(text):
    return LINK_RE.sub(lambda m: f"<{CONV_URL}{m.group(1)}|{m.group(1)}>", text)


def date_display(iso):
    try:
        d = datetime.strptime(iso, "%Y-%m-%d")
    except ValueError:
        return iso
    return f"{d.strftime('%a %b')} {d.day}"


def window_phrase(hours):
    hours = int(hours)
    if hours > 48 and hours % 24 == 0:
        return f"last {hours // 24}d"
    return f"last {hours}h"


def status_emoji(sev):
    if sev["p0"] > 0:
        return "\U0001f534"  # red circle
    if sev["p1"] > 0:
        return "\U0001f7e1"  # yellow circle
    return "\U0001f7e2"      # green circle


def title(d):
    return "Caroline daily" if d["kind"] == "daily" else "Caroline weekly roll-up"


def headline(d):
    sev = d["severity"]
    line = (
        f"{status_emoji(sev)} {title(d)} · {date_display(d['date'])} · "
        f"{window_phrase(d['window_hours'])} · {d['conv_count']} convs · "
        f"{sev['p0']} P0 / {sev['p1']} P1 / {sev['p2']} P2"
    )
    if sev["p0"] > 0:
        line = f"<@{PING_USER}> {line}"
    return line


def scores_line(d):
    s = d["scores"]
    return (
        f"\U0001f399️ Voice {s['voice']} | \U0001f6e0️ Tools {s['tools']} | "
        f"\U0001f61f Sentiment {s['sentiment']}"
    )


def conv_refs(ids):
    return " ".join(f"conv {i}" for i in ids)


def finding_bullet(f):
    parts = [f["text"]]
    if f.get("conversation_ids"):
        parts.append(conv_refs(f["conversation_ids"]))
    bullet = " · ".join(parts)
    if f["severity"] != "info":
        bullet += f" ({f['severity']})"
    return bullet


def dimension_lines(d):
    """One block of lines per dimension that has findings (collapse-clean)."""
    out = []
    for dim, emoji, label in DIMENSIONS:
        findings = [f for f in d.get("findings", []) if f["dimension"] == dim]
        if not findings:
            continue
        score = d["scores"].get(dim)
        suffix = f" ({score})" if isinstance(score, int) else ""
        lines = [f"{emoji} *{label}*{suffix}: {finding_bullet(findings[0])}"]
        lines += [f"  • {finding_bullet(f)}" for f in findings[1:MAX_BULLETS]]
        if len(findings) > MAX_BULLETS:
            lines.append(f"  • …+{len(findings) - MAX_BULLETS} more")
        out.append(lines)
    return out


def guard_lines(d):
    g = d["guard"]
    caught = g["caught_stripped"] + g["caught_escalated"]
    items = g.get("items", [])
    if caught == 0 and g["missed_shipped"] == 0 and not items:
        line = "\U0001f6e1️ *Guard* - healthy: 0 caught, 0 missed in shipped replies."
    else:
        shapes = f" [shapes: {', '.join(g['shapes'])}]" if g.get("shapes") else ""
        line = (
            f"\U0001f6e1️ *Guard*: {g['caught_stripped']} stripped (silent), "
            f"{g['caught_escalated']} escalated -> human, "
            f"{g['missed_shipped']} missed in shipped replies.{shapes}"
        )
    if g["source"] != "journalctl":
        line += f" (guard-log source degraded: {g['source']})"
    lines = [line]
    for it in items:
        note = f" {it['note']}" if it.get("note") else ""
        if it["type"] == "unanswered_escalation":
            lines.append(
                f"  • Escalated & still unanswered: conv {it['conversation_id']}"
                f"{note} <- action item (P1)"
            )
        else:
            lines.append(
                f"  • SHIPPED leak the guard missed: conv {it['conversation_id']}"
                f"{note} <- guard gap (P0)"
            )
    return lines


def theme_bullet(t):
    return (
        f"[{THEME_CATEGORY[t['category']]}] {t['label']} - {t['summary']} "
        f"· {t['unique_customers']} customers · {conv_refs(t['conversation_ids'])}"
    )


def kb_bullet(c):
    return (
        f"{c['label']} · {c['unique_customers']} customers "
        f"· {conv_refs(c['conversation_ids'])}"
    )


def context_line(d):
    # The live cron job names, so the footer greps back to cron-jobs.json.
    bits = [
        "caroline-daily-review" if d["kind"] == "daily" else "caroline-weekly-rollup",
        window_phrase(d["window_hours"]),
        f"guard source {d['guard']['source']}",
    ]
    bits += d.get("degraded", [])
    return " · ".join(bits)


# --------------------------------------------------------------------------
# text mode
# --------------------------------------------------------------------------

def render_text(d):
    lines = [headline(d), scores_line(d)]
    for block in dimension_lines(d):
        lines += block
    themes = sorted(d.get("themes", []), key=lambda t: -t["unique_customers"])
    if themes:
        lines.append("\U0001f9f5 *Themes* (multiple customers, informational):")
        lines += [f"  • {theme_bullet(t)}" for t in themes]
    kb = sorted(d.get("kb_gap_candidates", []), key=lambda c: -c["unique_customers"])
    if kb:
        lines.append("\U0001f4d6 *KB-gap candidates* (>=3 unique customers):")
        lines += [f"  • {kb_bullet(c)}" for c in kb]
    lines += guard_lines(d)
    return "\n".join(lines)


# --------------------------------------------------------------------------
# blocks mode
# --------------------------------------------------------------------------

def cap_section(text):
    if len(text) <= SECTION_CHAR_CAP:
        return text
    kept = text[:SECTION_CHAR_CAP]
    cut = kept.rfind("\n")
    if cut > 0:
        kept = kept[:cut]
    dropped = text.count("\n") - kept.count("\n")
    return f"{kept}\n_…+{dropped} more line(s) truncated_"


def section(text):
    return {"type": "section", "text": {"type": "mrkdwn", "text": cap_section(linkify(text))}}


def render_blocks(d):
    sev = d["severity"]
    blocks = []
    if sev["p0"] > 0:
        # Mentions do not render inside header blocks (plain_text), so the
        # ping leads as its own section; the notification text pings too.
        blocks.append(section(f"<@{PING_USER}> \U0001f534 *{sev['p0']} P0 - action needed*"))
    blocks.append({
        "type": "header",
        "text": {
            "type": "plain_text",
            "text": f"{status_emoji(sev)} {title(d)} · {date_display(d['date'])} "
                    f"· {window_phrase(d['window_hours'])}",
            "emoji": True,
        },
    })
    s = d["scores"]
    fields = [
        f"*Convs:* {d['conv_count']}",
        f"*Severity:* {sev['p0']} P0 / {sev['p1']} P1 / {sev['p2']} P2",
        f"\U0001f399️ *Voice* {s['voice']}",
        f"\U0001f6e0️ *Tools* {s['tools']}",
        f"\U0001f61f *Sentiment* {s['sentiment']}",
        f"\U0001f6e1️ *Guard* {d['guard']['caught_stripped'] + d['guard']['caught_escalated']}"
        f" caught / {d['guard']['missed_shipped']} missed",
    ]
    blocks.append({"type": "section",
                   "fields": [{"type": "mrkdwn", "text": x} for x in fields]})
    blocks.append({"type": "divider"})

    for lines in dimension_lines(d):
        blocks.append(section("\n".join(lines)))

    g = d["guard"]
    if g.get("items") or g["caught_stripped"] + g["caught_escalated"] + g["missed_shipped"] > 0 \
            or g["source"] != "journalctl":
        blocks.append(section("\n".join(guard_lines(d))))

    themes = sorted(d.get("themes", []), key=lambda t: -t["unique_customers"])
    if d["kind"] == "weekly":
        for cat, heading in WEEKLY_THEME_GROUPS:
            group = [t for t in themes if t["category"] == cat]
            if not group:
                continue
            lines = [f"*{heading}*"]
            lines += [f"• {theme_bullet(t)}" for t in group]
            blocks.append(section("\n".join(lines)))
        kb = sorted(d.get("kb_gap_candidates", []), key=lambda c: -c["unique_customers"])
        if kb:
            lines = ["*\U0001f4d6 KB-gap candidates* (>=3 unique customers)"]
            lines += [f"• {kb_bullet(c)}" for c in kb]
            lines.append("_Auto-PR disabled in v1 - open manually via open-kb-pr.sh_")
            blocks.append(section("\n".join(lines)))
    elif themes:
        lines = ["*\U0001f9f5 Themes* _(multiple customers, informational)_"]
        lines += [f"• {theme_bullet(t)}" for t in themes]
        blocks.append(section("\n".join(lines)))

    blocks.append({"type": "context",
                   "elements": [{"type": "mrkdwn", "text": context_line(d)}]})

    return {
        "channel": os.environ.get("CAROLINE_DIGEST_CHANNEL", DEFAULT_CHANNEL),
        # Notification/fallback text: the same computed headline (carries the
        # ping when P0 > 0 so the push notification pings too).
        "text": headline(d),
        "unfurl_links": False,
        "unfurl_media": False,
        "blocks": blocks,
    }


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("--text", "--blocks"):
        print("usage: render-digest.py --text|--blocks < digest.json", file=sys.stderr)
        return 2
    try:
        digest = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"render-digest: stdin is not valid JSON: {e}", file=sys.stderr)
        return 1
    try:
        if sys.argv[1] == "--text":
            print(render_text(digest))
        else:
            print(json.dumps(render_blocks(digest), ensure_ascii=False))
    except (KeyError, TypeError) as e:
        # validate-digest.sh runs first, so this is a pipeline-order bug.
        print(f"render-digest: digest missing required field ({e}) - "
              f"was validate-digest.sh run first?", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
