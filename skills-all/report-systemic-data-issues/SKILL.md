---
name: report-systemic-data-issues
description: |
  Every 6h, read recent Intercom conversations, find where MULTIPLE distinct
  users independently report the SAME or a very similar data problem, and post
  one verbose, Aaron-ready report to the priority channel. The semantic
  clustering is yours (the agent's); a deterministic script gathers the
  conversations and renders + posts the report. Follows Aaron's report-to-aaron
  doctrine: state the SYMPTOM (not a diagnosis or fix), use precise nouns, put
  all context up front.

  Use when: invoked by the `systemic-data-issue-report-6h` cron, or asked to
  "check for systemic data issues", "cluster the recent data complaints", or
  "report systemic data issues to Aaron".

  Triggers: "systemic data issue", "cluster data complaints", "same issue across
  users", "report data issues to Aaron"
allowed-tools:
  - exec
metadata:
  version: "1.0"
  source-repo: "Muso-AI/hydra"
---

# Report systemic data issues

Turn the last window of Intercom support traffic into **one** report Aaron can
act on: the issues where the *same* data problem is hitting *multiple* distinct
users. Individual one-off complaints are NOT systemic — they go to the normal
support flow, not to Aaron.

The deterministic edges are a script
(`/opt/hydra/scripts/intercom-data-complaint-watchdog.py`); the **clustering
judgement in the middle is yours**. You never hand-format Slack — `--report`
renders and posts.

## Hard rules

- **You only produce `clusters.json`.** You do NOT post to Slack, do not use the
  message tool, do not curl Slack. The `--report` step posts (with the Aaron
  mention and injection-escaping) and prints the final line — emit that VERBATIM.
- **A cluster needs ≥2 DISTINCT users** (distinct emails; an anonymous
  conversation is its own user). One loud user reporting three times is not
  systemic. If you are unsure two complaints are the *same* issue, keep them
  apart — a false "systemic" page costs Aaron more than a missed near-cluster.
- **Symptom, not diagnosis or fix** (Aaron's rule). For each cluster write what
  the app/data is *doing* from the customer's side. Do NOT guess the code cause,
  do NOT propose a fix, do NOT invoke V3/V4 internals.
- **Precise nouns** — *track / album / credit / master / profile / Spotify /
  Muso*. Never blur "track" vs "album" vs "credit".
- **Cite what the customer points at** — track IDs, `credits.muso.ai/...` or
  other URLs, profile names, and any numbers the customer themselves states.
  These are the closest thing to Aaron's "source-vs-Muso" comparison; surface
  them in each user's `cites`.
- **Carry `conv_id` for every user** (from the gather output). The report
  rebuilds the Intercom deeplink from it — an agent-supplied URL is ignored.
- **Honesty over completeness.** If the window was truncated (gather prints a
  `WARN: ... DROPPED N`), say so in your final note. Conversations you judged
  NON-systemic (a one-off, or not a data error at all — e.g. an onboarding /
  profile-creation request) go in `excluded[]` with a one-line reason, so Aaron
  sees what you set aside. Never silently drop.
- **A recovered hiccup must not abort the run.** If a one-off command errors,
  recover and continue — a single trailing tool error makes the runtime mark the
  whole run failed. Always end with a visible final message.

## Workflow (one shell session is fine for steps 1 and 3; step 2 is your reasoning)

### Step 1 — Gather (deterministic, read-only)

```bash
WD=/tmp/systemic-data-issue
mkdir -p "$WD"
python3 /opt/hydra/scripts/intercom-data-complaint-watchdog.py --gather --window-hours 24 > "$WD/candidates.json"
```

Read `"$WD/candidates.json"`. Each entry in `.candidates[]` is a conversation
the AI should read: `conv_id`, `who` (email or "anonymous"), `age_hours`,
`state`, `tags` (a conversation carrying `ai:data-complaint` was already flagged
by Caroline — weight it), `deeplink`, and `opening_message` (the customer's
opening text, HTML-stripped, capped). Note `.truncated` and any `WARN` on stderr.

### Step 2 — Cluster (your judgement) → write `clusters.json`

Read every candidate. First decide which are genuine **data** complaints (the
customer says Muso's data about their music is wrong / missing / misattributed /
out of date). Drop calm how-do-I questions and non-data requests — but record
the borderline ones you drop in `excluded[]` so the set is auditable.

Then group the genuine complaints by the **same underlying issue** — not a coarse
category. "credits showing under the wrong producer name" and "I'm credited on a
track that isn't mine" may or may not be the same issue; decide by what's
actually wrong, and write a symptom that fits the members. Only groups with **≥2
distinct users** are clusters.

Write the result with a heredoc to `"$WD/clusters.json"`, matching this schema
exactly:

```json
{
  "window_hours": 24,
  "clusters": [
    {
      "issue_slug": "credits-false-attribution",
      "title": "Credits misattribution — artists credited on tracks that aren't theirs",
      "symptom": "On muso.ai an artist's name appears in the credits for a track they say they had no part in; they're asking to be removed.",
      "noun": "credits",
      "users": [
        {
          "who": "anonymous (Ayal Nistor)",
          "conv_id": "215474812001295",
          "email": "",
          "detail": "credited on a track he says he has nothing to do with; asks to be removed",
          "cites": ["track 78d7dcd3-3b1c", "https://credits.muso.ai/track/78d7dcd3-3b1c"],
          "age_hours": 3,
          "state": "open"
        }
      ]
    }
  ],
  "excluded": [
    { "who": "elies.off.officiel@gmail.com", "reason": "profile-creation request (profile not indexed yet), not a data error" }
  ]
}
```

Field rules:
- `issue_slug` — a STABLE kebab-case key for the issue (the cooldown is keyed on
  it; reuse the same slug for the same issue across runs so a known cluster isn't
  re-paged every 6h).
- `title` — short headline. `symptom` — one line, symptom only. `noun` — the
  precise noun. `users[]` — one entry per member conversation; `who`, `conv_id`
  required; `detail`, `cites`, `age_hours`, `state` carry the per-user context.
- `email` — **copy the candidate's `email` verbatim** (empty string `""` for an
  anonymous conversation). This is the distinct-user KEY, not the display `who`:
  the same customer's email across several conversations counts as ONE user, and
  two DIFFERENT anonymous conversations count as TWO. Get it wrong and the ≥2
  threshold mis-fires (a missed page, or a false one).
- If there are NO ≥2-user clusters, write `{"clusters": [], "excluded": [...]}`
  — the report step will simply report nothing to page (no Slack noise).

### Step 3 — Report (deterministic; renders + posts)

```bash
python3 /opt/hydra/scripts/intercom-data-complaint-watchdog.py --report --clusters "$WD/clusters.json"
rm -rf "$WD"   # scrub the customer transcripts from disk
```

- The script drops sub-threshold clusters, applies the per-`issue_slug` 24h
  cooldown, renders the Aaron report, and posts it to the priority channel
  (`C0BBTAVP44X`, mentioning Aaron) via the Ops bot. On a quiet window it posts
  nothing and prints `nothing fresh to page`.
- If it exits non-zero with `malformed clusters.json: ...`, your `clusters.json`
  broke the schema — fix it per the stderr message and re-run `--report`.
- Emit the script's final stdout line VERBATIM as your final assistant message,
  then nothing else.

## Environment

- `MUSOAI_INTERCOM_TOKEN` — required for `--gather` (Intercom read).
- `MUSO_SLACK_BOT_TOKEN_OPERATIONS` — the Ops bot token `--report` posts with
  (falls back to the openclaw config devops token). The Ops bot must be a member
  of `C0BBTAVP44X`.
- Tunables (env, all defaulted): `WATCHDOG_WINDOW_HOURS` (24), `WATCHDOG_MAX_CANDIDATES`
  (300), `WATCHDOG_SYSTEMIC_THRESHOLD` (2), `WATCHDOG_COOLDOWN_HOURS` (24).
