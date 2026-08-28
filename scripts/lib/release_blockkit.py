#!/usr/bin/env python3
"""Render a release into the #releases Block Kit payload.

Reads its inputs from the RA_* environment variables documented in
release-announce.sh and writes the Slack chat.postMessage payload to
argv[1].

Two rendering modes, chosen by whether highlights were supplied:

  rich      RA_HIGHLIGHTS_FILE has content -> a plain-language
            "What's new" section for a company-wide audience, with the
            per-type counts reduced to a single context line.
  fallback  no highlights (the agent turn failed, timed out, or was
            skipped) -> the deterministic conventional-commit sections,
            plus an explicit note that highlights are missing.

The fallback exists so a release is never silently unannounced because
the LLM step broke. It degrades what the message SAYS, never whether it
is sent.
"""

import json
import os
import re
import sys

# Slack limits: header plain_text 150, section text 3000. The section cap
# is held well under the hard limit so an overflow footer always fits.
HEADER_MAX = 150
SECTION_MAX = 2800

SECTION_EMOJI = {
    "Features": "✨",       # sparkles
    "Fixes": "\U0001F527",      # wrench
    "Performance": "⚡",    # zap
    "Refactors": "♻️",  # recycle
    "Reverts": "⏪",        # rewind
    "Chores": "\U0001F9F9",     # broom
    "Docs": "\U0001F4DA",       # books
    "Other": "\U0001F4E6",      # package
}

# Singular/plural for the counts line. Keys must match SECTION_EMOJI.
SECTION_NOUN = {
    "Features": ("feature", "features"),
    "Fixes": ("fix", "fixes"),
    "Performance": ("perf change", "perf changes"),
    "Refactors": ("refactor", "refactors"),
    "Reverts": ("revert", "reverts"),
    "Chores": ("chore", "chores"),
    "Docs": ("doc change", "doc changes"),
    "Other": ("change", "changes"),
}


# Slack reserves exactly three characters in mrkdwn text objects. Leaving
# them raw is not a rendering nit: a commit subject containing <!channel>
# or <!everyone> renders as a real broadcast and pings the whole company
# from #releases. Commit subjects are author-controlled and highlights are
# LLM-written, so both are untrusted for this purpose.
# https://docs.slack.dev/messaging/formatting-message-text (escaping)
def mrkdwn_escape(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def parse_notes(md):
    """Parse release.sh's markdown back into [(title, [bullets])].

    Mirrors emit_section()'s output shape:
        ### Features
        <blank>
        - bullet
    """
    sections = []
    title = None
    bullets = []
    for raw in md.splitlines():
        line = raw.rstrip()
        if line.startswith("### "):
            if title and bullets:
                sections.append((title, bullets))
            title = line[4:].strip()
            bullets = []
        elif line.startswith("- "):
            bullets.append(line[2:].strip())
    if title and bullets:
        sections.append((title, bullets))
    return sections


def linkify_prs(text, repo):
    """Turn (#123) into an explicit Slack link.

    Explicit links keep the message readable for anyone whose Slack does
    not have the GitHub app installed, which is most of the company.
    """
    if not repo:
        return text
    return re.sub(
        r"\(#(\d+)\)",
        lambda m: "(<https://github.com/%s/pull/%s|#%s>)" % (repo, m.group(1), m.group(1)),
        text,
    )


# A single absurdly long subject used to consume the whole section budget
# and push every later bullet into the "+N more" note -- an honest count
# attached to a dishonest magnitude. Cap each bullet first so the overflow
# note only fires on genuine aggregate overflow.
BULLET_MAX = 300


def clamp_bullets(bullets, prefix=""):
    """Join bullets under the section cap, with an honest overflow note.

    Never silently truncates: if items are dropped the reader is told how
    many and where to find them.
    """
    out = []
    used = len(prefix)
    for i, b in enumerate(bullets):
        if len(b) > BULLET_MAX:
            b = b[: BULLET_MAX - 1] + "…"
        line = "• %s" % b
        if used + len(line) + 1 > SECTION_MAX:
            remaining = len(bullets) - i
            out.append("_…+%d more (see the release page)_" % remaining)
            break
        out.append(line)
        used += len(line) + 1
    return prefix + "\n".join(out)


def read_lines(path):
    if not path or not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8") as fh:
        # Filter AFTER stripping the bullet glyph: a line of "- " is
        # truthy before cleaning and empty after, and an empty-but-present
        # highlights list would suppress the deterministic fallback.
        return [c for c in (l.strip().lstrip("-• ").strip() for l in fh) if c]


def main():
    out_path = sys.argv[1]

    channel = os.environ.get("RA_CHANNEL", "")
    emoji = os.environ.get("RA_EMOJI", "\U0001F680")
    display = os.environ.get("RA_DISPLAY", "release")
    version = os.environ.get("RA_VERSION", "")
    repo = os.environ.get("RA_REPO", "")
    release_url = os.environ.get("RA_RELEASE_URL", "")
    compare_url = os.environ.get("RA_COMPARE_URL", "")
    rollback_url = os.environ.get("RA_ROLLBACK_URL", "")
    stats = os.environ.get("RA_STATS", "")
    footer = os.environ.get("RA_FOOTER", "")

    with open(os.environ["RA_NOTES_FILE"], encoding="utf-8") as fh:
        sections = parse_notes(fh.read())

    highlights = read_lines(os.environ.get("RA_HIGHLIGHTS_FILE", ""))

    header = "%s  %s · %s" % (emoji, display, version)
    if len(header) > HEADER_MAX:
        header = header[: HEADER_MAX - 1] + "…"

    blocks = [
        {"type": "header", "text": {"type": "plain_text", "text": header, "emoji": True}}
    ]

    if highlights:
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": clamp_bullets(
                    [mrkdwn_escape(h) for h in highlights], "*What's new*\n"
                ),
            },
        })
    else:
        # No highlights: fall back to the deterministic sections so the
        # message still carries real content, and say plainly that the
        # plain-language layer is missing rather than pretending.
        for title, bullets in sections:
            icon = SECTION_EMOJI.get(title, "\U0001F4E6")
            blocks.append({
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": clamp_bullets(
                        [linkify_prs(mrkdwn_escape(b), repo) for b in bullets],
                        "*%s %s*\n" % (icon, title),
                    ),
                },
            })

    # Counts line, always present: it is the one place the technical
    # shape of the release survives into the rich rendering.
    counts = []
    for title, bullets in sections:
        noun = SECTION_NOUN.get(title, ("change", "changes"))
        counts.append("%s %d %s" % (
            SECTION_EMOJI.get(title, "\U0001F4E6"),
            len(bullets),
            noun[0] if len(bullets) == 1 else noun[1],
        ))

    if not sections and not highlights:
        # release.sh's emit_section format drifted, or the notes were empty.
        # Without this the message is header + warning only: valid Slack,
        # zero content, and no error anywhere.
        sys.stderr.write(
            "release_blockkit: could not parse any section from the release notes\n"
        )
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "_release notes could not be parsed — see the release page_",
            },
        })

    context_lines = []
    if counts:
        context_lines.append(" · ".join(counts))
    if stats:
        context_lines.append(mrkdwn_escape(stats))
    if not highlights:
        context_lines.append(":warning: plain-language highlights unavailable for this release")
    if context_lines:
        blocks.append({
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": "\n".join(context_lines)}],
        })

    actions = []
    if release_url:
        actions.append({
            "type": "button",
            "text": {"type": "plain_text", "text": "View release", "emoji": True},
            "url": release_url,
        })
    if compare_url:
        actions.append({
            "type": "button",
            "text": {"type": "plain_text", "text": "Diff", "emoji": True},
            "url": compare_url,
        })
    if rollback_url:
        actions.append({
            "type": "button",
            "text": {"type": "plain_text", "text": "Rollback", "emoji": True},
            "url": rollback_url,
        })
    if actions:
        blocks.append({"type": "actions", "elements": actions})

    if footer:
        blocks.append({
            "type": "context",
            "elements": [{"type": "mrkdwn", "text": footer}],
        })

    payload = {
        "text": "%s %s %s — %s" % (emoji, display, version, release_url),
        # The notification text above is what lands in the sidebar and in
        # push notifications; without it Slack shows "This content can't
        # be displayed" for a blocks-only message.
        "unfurl_links": False,
        "unfurl_media": False,
        "blocks": blocks,
    }
    if channel:
        payload["channel"] = channel

    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)


if __name__ == "__main__":
    main()
