#!/usr/bin/env python3
"""Deterministic renderer for the validated+redacted structured digest.

Reads digest JSON on stdin, writes to stdout one of:
  --text          the plain-text digest (the announce-delivery fallback; pipe
                  it through redact-output.sh | linkify-convs.sh |
                  assert-digest-contract.sh exactly like the legacy path)
  --blocks-main   the LEAN Slack chat.postMessage payload — ping + action
                  items, header, compact summary, theme one-liners. This is
                  the glance.
  --blocks-thread the detail payload posted as a THREAD REPLY under the main
                  message (post-digest.sh injects thread_ts) — P2 details,
                  good catches, full uncapped evidence lists, guard detail.

WHY a script, not the LLM: same doctrine as assert-digest-contract.sh — the
header semantics (status emoji, P0 ping, severity triplet, scores line, the
always-present guard report) are COMPUTED here from the validated counts, so
no model on the fallback chain can drop or mangle them. The LLM never authors
Block Kit JSON and never hand-writes Intercom URLs.

Glanceability rules (2026-06-11 v2, per Nick's feedback on the first live
post): conversation ids are STRIPPED from prose mechanically (the grader
duplicating ids in text was the main noise source) and evidence renders as
tiny numbered links capped at 3 per main-message bullet (`1 2 3 +6`); the
full lists live in the thread payload.

All modes share every line-building helper, so the posts and the plain-text
fallback can never drift apart. This file is the single in-skill source of
the P0 ping Slack id.

Env (blocks modes): CAROLINE_DIGEST_CHANNEL — override the target channel
(default #cs_chats C0ANM0PN9L5); used by the shadow-channel rollout.
"""

import json
import os
import re
import sys
from datetime import datetime

PING_USER = "U0AL36NADEY"           # pinged on the action block ONLY when P0 > 0
DEFAULT_CHANNEL = "C0ANM0PN9L5"     # cs_chats
CONV_URL = "https://app.intercom.com/a/inboxes/all/conversations/"
# Mirrors linkify-convs.sh: lookbehind excludes 0-9 (longer digit runs),
# / (already-inside-a-URL) and | (already a link label) so the pass is
# idempotent; the only 15-16 digit tokens in the digest are conversation ids.
LINK_RE = re.compile(r"(?<![0-9/|])([0-9]{15,16})(?![0-9])")
# Prose scrub: the grader keeps writing ids inside text/summary even though
# conversation_ids carries the evidence — strip them mechanically so links
# render exactly once, as numbered evidence.
ID_IN_PROSE_RE = re.compile(r"(?:\bconv\s*)?(?<![0-9/|])[0-9]{15,16}(?![0-9])")
SECTION_CHAR_CAP = 2800             # Slack section text hard limit is 3000
MAX_BULLETS = 10                    # per detail section; overflow counted, never silent
MAIN_LINK_CAP = 3                   # evidence links per main-message bullet
SUMMARY_CHAR_CAP = 100              # theme summary length in the main message

DIMENSIONS = [  # render order; good_catch last so wins close the details
    ("voice", "\U0001f399️", "Voice"),
    ("tools", "\U0001f6e0️", "Tools"),
    ("sentiment", "\U0001f61f", "Sentiment"),
    ("good_catch", "✅", "Good catch"),
]
DIM_LABEL = {k: l for k, _, l in DIMENSIONS}
THEME_EMOJI = {
    "issue": "\U0001f41b",
    "question": "❓",
    "feature_request": "\U0001f4a1",
    "escalation_pattern": "\U0001f6a8",
}
WEEKLY_THEME_GROUPS = [
    ("issue", "\U0001f41b Recurring issues"),
    ("question", "❓ Recurring questions"),
    ("feature_request", "\U0001f4a1 Feature asks"),
    ("escalation_pattern", "\U0001f6a8 Escalation patterns"),
]


def linkify(text):
    return LINK_RE.sub(lambda m: f"<{CONV_URL}{m.group(1)}|{m.group(1)}>", text)


def strip_ids(text):
    """Remove conversation ids (and a leading 'conv') from prose; evidence is
    rendered separately as numbered links from conversation_ids."""
    out = ID_IN_PROSE_RE.sub("", text or "")
    out = re.sub(r"\(\s*\)", "", out)              # parens left empty
    out = re.sub(r"\s+([.,;:)\]])", r"\1", out)    # space before punctuation
    out = re.sub(r"\s{2,}", " ", out)
    out = out.strip()
    out = re.sub(r"^[·\-,;:\s]+", "", out)         # dangling leading separators
    out = re.sub(r"[·\-,;:\s]+$", "", out)         # dangling trailing separators
    # a removed trailing id often leaves its preposition hanging
    # ("audit lines in", "asked for a human in")
    out = re.sub(r"\b(?:in|at|on|from|of|to|for)$", "", out)
    return re.sub(r"[·\-,;:\s]+$", "", out).strip()


def evidence_links(ids, cap=MAIN_LINK_CAP):
    """Tiny numbered evidence links: `<url|1> <url|2> <url|3> +6`.
    cap=None renders every id (thread payload)."""
    ids = list(ids or [])
    shown = ids if cap is None else ids[:cap]
    parts = [f"<{CONV_URL}{cid}|{i}>" for i, cid in enumerate(shown, 1)]
    if cap is not None and len(ids) > cap:
        parts.append(f"+{len(ids) - cap}")
    return " ".join(parts)


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
    g = d["guard"]
    caught = g["caught_stripped"] + g["caught_escalated"]
    return (
        f"\U0001f399️ Voice {s['voice']} | \U0001f6e0️ Tools {s['tools']} | "
        f"\U0001f61f Sentiment {s['sentiment']} | \U0001f6e1️ Guard {caught}/{g['missed_shipped']}"
    )


def truncate(text, cap):
    return text if len(text) <= cap else text[: cap - 1].rstrip() + "…"


# --------------------------------------------------------------------------
# shared content builders
# --------------------------------------------------------------------------

def action_items(d, cap=MAIN_LINK_CAP):
    """One-line P0/P1 bullets: findings first (P0 before P1), then guard items.
    These ARE the 'what do I do' — they lead the main message."""
    items = []
    for f in d.get("findings", []):
        if f["severity"] in ("P0", "P1"):
            links = evidence_links(f.get("conversation_ids", []), cap)
            line = f"{strip_ids(f['text'])} ({DIM_LABEL[f['dimension']]})"
            if links:
                line += f" · {links}"
            items.append((f["severity"], line))
    for it in d["guard"].get("items", []):
        sev = "P0" if it["type"] == "shipped_leak" else "P1"
        what = ("SHIPPED leak the guard missed" if sev == "P0"
                else "Escalated, still unanswered by a human")
        note = strip_ids(it.get("note", ""))
        line = what + (f" - {note}" if note else "")
        line += f" (Guard) · {evidence_links([it['conversation_id']], cap)}"
        items.append((sev, line))
    items.sort(key=lambda x: x[0])  # P0 < P1 lexically
    return [line for _, line in items]


def theme_line(t, cap=MAIN_LINK_CAP):
    summary = truncate(strip_ids(t["summary"]), SUMMARY_CHAR_CAP)
    line = f"{THEME_EMOJI[t['category']]} *{strip_ids(t['label'])}*"
    if summary:
        line += f" — {summary}"
    line += f" · *{t['unique_customers']} customers*"
    links = evidence_links(t["conversation_ids"], cap)
    if links:
        line += f" · {links}"
    return line


def sorted_themes(d):
    return sorted(d.get("themes", []), key=lambda t: -t["unique_customers"])


def sorted_kb(d):
    return sorted(d.get("kb_gap_candidates", []), key=lambda c: -c["unique_customers"])


def detail_lines(d, cap=MAIN_LINK_CAP):
    """P2/info findings grouped per dimension (the P0/P1 ones live in the
    action block). Collapse-clean: a dimension with nothing renders nothing."""
    out = []
    for dim, emoji, label in DIMENSIONS:
        findings = [f for f in d.get("findings", [])
                    if f["dimension"] == dim and f["severity"] not in ("P0", "P1")]
        if not findings:
            continue
        def bullet(f):
            line = strip_ids(f["text"])
            links = evidence_links(f.get("conversation_ids", []), cap)
            if links:
                line += f" · {links}"
            if f["severity"] != "info":
                line += f" ({f['severity']})"
            return line
        lines = [f"{emoji} *{label}*: {bullet(findings[0])}"]
        lines += [f"  • {bullet(f)}" for f in findings[1:MAX_BULLETS]]
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
        note = strip_ids(it.get("note", ""))
        note = f" {note}" if note else ""
        link = evidence_links([it["conversation_id"]], None)
        if it["type"] == "unanswered_escalation":
            lines.append(f"  • Escalated & still unanswered: {link}{note} <- action item (P1)")
        else:
            lines.append(f"  • SHIPPED leak the guard missed: {link}{note} <- guard gap (P0)")
    return lines


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
# text mode (announce fallback — single message, contract-gated downstream)
# --------------------------------------------------------------------------

def render_text(d):
    lines = [headline(d), scores_line(d)]
    acts = action_items(d)
    if acts:
        lines.append("\U0001f6a8 *Action needed*:")
        lines += [f"  • {a}" for a in acts]
    themes = sorted_themes(d)
    if themes:
        lines.append("\U0001f9f5 *Themes* (multiple customers, informational):")
        lines += [f"  • {theme_line(t)}" for t in themes]
    kb = sorted_kb(d)
    if kb:
        lines.append("\U0001f4d6 *KB-gap candidates* (>=3 unique customers):")
        lines += [f"  • {theme_line(c)}" for c in kb]
    for block in detail_lines(d):
        lines += block
    lines += guard_lines(d)
    return "\n".join(lines)


# --------------------------------------------------------------------------
# blocks modes
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


def payload(d, blocks, notify_text):
    return {
        "channel": os.environ.get("CAROLINE_DIGEST_CHANNEL", DEFAULT_CHANNEL),
        "text": notify_text,
        "unfurl_links": False,
        "unfurl_media": False,
        "blocks": blocks,
    }


def render_blocks_main(d):
    sev = d["severity"]
    s = d["scores"]
    g = d["guard"]
    caught = g["caught_stripped"] + g["caught_escalated"]
    blocks = []

    acts = action_items(d)
    if acts:
        # Mentions do not render inside header blocks (plain_text), so the
        # action block leads as a section; the notification text pings too.
        head = f"{status_emoji(sev)} *{sev['p0']} P0 / {sev['p1']} P1 - action needed*"
        if sev["p0"] > 0:
            head = f"<@{PING_USER}> {head}"
        blocks.append(section(head + "\n" + "\n".join(f"• {a}" for a in acts)))

    blocks.append({
        "type": "header",
        "text": {
            "type": "plain_text",
            "text": f"{status_emoji(sev)} {title(d)} · {date_display(d['date'])} "
                    f"· {window_phrase(d['window_hours'])}",
            "emoji": True,
        },
    })
    blocks.append(section(
        f"*Convs* {d['conv_count']} · {sev['p0']} P0 / {sev['p1']} P1 / {sev['p2']} P2\n"
        f"\U0001f399️ Voice {s['voice']} · \U0001f6e0️ Tools {s['tools']} · "
        f"\U0001f61f Sentiment {s['sentiment']} · \U0001f6e1️ Guard {caught}/{g['missed_shipped']}"
    ))

    themes = sorted_themes(d)
    if d["kind"] == "weekly":
        for cat, heading in WEEKLY_THEME_GROUPS:
            group = [t for t in themes if t["category"] == cat]
            if not group:
                continue
            blocks.append({"type": "divider"})
            blocks.append(section(f"*{heading}*\n" + "\n".join(theme_line(t) for t in group)))
    elif themes:
        blocks.append({"type": "divider"})
        blocks.append(section(
            "*\U0001f9f5 Themes* _(multiple customers, informational)_\n"
            + "\n".join(theme_line(t) for t in themes)
        ))

    blocks.append({"type": "context",
                   "elements": [{"type": "mrkdwn", "text": context_line(d)}]})
    return payload(d, blocks, headline(d))


def render_blocks_thread(d):
    """Detail reply. publish-digest.sh skips the post when nothing but the
    lead + healthy guard line would render (a truly quiet day)."""
    blocks = [{"type": "context",
               "elements": [{"type": "mrkdwn",
                             "text": f"Details for the {title(d)} digest above"}]}]

    for lines in detail_lines(d, cap=None):
        blocks.append(section("\n".join(lines)))

    themes = sorted_themes(d)
    if themes:
        blocks.append(section(
            "*\U0001f9f5 Theme evidence* _(every conversation)_\n"
            + "\n".join(
                f"{THEME_EMOJI[t['category']]} *{strip_ids(t['label'])}* · "
                f"{evidence_links(t['conversation_ids'], None)}"
                for t in themes
            )
        ))

    kb = sorted_kb(d)
    if kb:
        lines = ["*\U0001f4d6 KB-gap candidates* (>=3 unique customers)"]
        for c in kb:
            lines.append(f"• {theme_line(c, cap=None)}")
            note = strip_ids(c.get("proposed_kb_note", ""))
            if note:
                lines.append(f"    _proposed note:_ {note}")
        lines.append("_Auto-PR disabled in v1 - open manually via open-kb-pr.sh_")
        blocks.append(section("\n".join(lines)))

    g = d["guard"]
    if (g["caught_stripped"] + g["caught_escalated"] + g["missed_shipped"] > 0
            or g.get("items") or g["source"] != "journalctl"):
        blocks.append(section("\n".join(guard_lines(d))))

    return payload(d, blocks, f"{title(d)} - details")


def main():
    modes = {"--text": render_text,
             "--blocks-main": render_blocks_main,
             "--blocks-thread": render_blocks_thread}
    if len(sys.argv) != 2 or sys.argv[1] not in modes:
        print("usage: render-digest.py --text|--blocks-main|--blocks-thread < digest.json",
              file=sys.stderr)
        return 2
    try:
        digest = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"render-digest: stdin is not valid JSON: {e}", file=sys.stderr)
        return 1
    try:
        out = modes[sys.argv[1]](digest)
        if sys.argv[1] == "--text":
            print(out)
        else:
            print(json.dumps(out, ensure_ascii=False))
    except (KeyError, TypeError) as e:
        # validate-digest.sh runs first, so this is a pipeline-order bug.
        print(f"render-digest: digest missing required field ({e}) - "
              f"was validate-digest.sh run first?", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
