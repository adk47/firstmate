# Caroline analytics knowledge base + em-dash sweep — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update Caroline's customer-facing knowledge base so the analytics complaint flow follows Fede's no-apology / "new version of analytics shipping" tone, fill three FAQ gaps surfaced by the 248-conversation Intercom audit (Apple Music, plaque snapshots, free credit-fixing), and replace em-dashes (U+2014) with en-dashes (U+2013) across the customer-facing surface.

**Architecture:** Markdown-only edits to existing files in `workspaces/support/`, plus one new on-demand bash script (`scripts/lint-no-em-dash.sh`) to enforce the no-em-dash rule. No openclaw config changes, no service restarts, no runtime code changes. The lint script + the rewritten knowledge-base files are the enforcement layer; SOUL.md edits are best-effort due to the existing 18,283-char file already exceeding the 12,000-char silent-truncation cliff (issue #165, separate work).

**Tech Stack:** Markdown (CommonMark), bash, perl (for the one-shot sweep, portable across macOS/GNU), `npx markdownlint-cli2` (used at validation only, no install required).

**Spec:** [`docs/superpowers/specs/2026-05-08-caroline-analytics-knowledge-base-design.md`](../specs/2026-05-08-caroline-analytics-knowledge-base-design.md)

**Baseline at plan time (2026-05-08):**
- SOUL.md: 18,283 chars (already over the truncation cliff; this PR adds ≈+120 chars).
- Em-dash counts in the 15 target files: 73 total. Distribution: SOUL.md 7, common-issues.md 22, faq.md 14, refund-retention 21, subscriptions-and-billing 3, output-sanitizer 1, action-request 1, the 4 muso-intercom mirrors 1 each. Four files (platform-features, credits-and-profiles, products-and-pricing, input-sanitizer) already have 0 em-dashes.
- The four `muso-intercom/SKILL.md` mirrors (skills-all/ + ceo/cto/operations workspaces) all show 1 em-dash, suggesting they are roughly synced.

**Blockers (resolve before merging the PR, NOT before starting implementation):**
1. Confirm with Jan / fulfilment that plaques are locked to the analytics snapshot at order time. If they are not, drop the plaque-snapshot FAQ entry and file a separate product ticket.
2. Confirm with Aaron / Product whether there is approved public roadmap wording for Apple Music. If yes, swap that wording in. Otherwise the conservative line ("isn't available today, no committed date") stands.

These blockers do not affect implementation; the plan ships the conservative defaults.

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `scripts/lint-no-em-dash.sh` | On-demand check that fails if any U+2014 character appears in Caroline's customer-facing surface | NEW |
| `workspaces/support/SOUL.md` | Caroline persona / tone calibration | EDIT (2 Never-do bullets, replace analytics troubleshooting example) |
| `workspaces/support/reference/common-issues.md` | 10 decision-tree resolution paths for top customer scenarios | EDIT (rewrite §7 Analytics) + em-dash sweep |
| `workspaces/support/reference/faq.md` | Searchable FAQ Caroline pulls from | EDIT (add 5 entries: Apple Music, Spotify mismatch, plaque-no-sub, plaque-snapshot, free-credit-fix) + em-dash sweep |
| `workspaces/support/reference/platform-features.md` | Platform-feature reference | (em-dash sweep only — no em-dashes today, no-op) |
| `workspaces/support/reference/subscriptions-and-billing.md` | Subscription/billing reference | em-dash sweep only |
| `workspaces/support/reference/credits-and-profiles.md` | Credit/profile reference | (em-dash sweep only — no em-dashes today, no-op) |
| `workspaces/support/reference/products-and-pricing.md` | Product/pricing reference | (em-dash sweep only — no em-dashes today, no-op) |
| `workspaces/support/skills/refund-retention/SKILL.md` | 3-gate retention flow | em-dash sweep only — content untouched |
| `workspaces/support/skills/input-sanitizer/SKILL.md` | Input sanitisation skill | (em-dash sweep only — no em-dashes today, no-op) |
| `workspaces/support/skills/output-sanitizer/SKILL.md` | Output sanitisation skill | em-dash sweep only |
| `workspaces/support/skills/action-request/SKILL.md` | Action-request escalation skill | em-dash sweep only |
| `skills-all/muso-intercom/SKILL.md` | Master copy of the muso-intercom skill | em-dash sweep only |
| `workspaces/ceo/skills/muso-intercom/SKILL.md` | CEO mirror of muso-intercom skill | em-dash sweep only — drift-checked after sweep |
| `workspaces/cto/skills/muso-intercom/SKILL.md` | CTO mirror of muso-intercom skill | em-dash sweep only — drift-checked after sweep |
| `workspaces/operations/skills/muso-intercom/SKILL.md` | Operations mirror of muso-intercom skill | em-dash sweep only — drift-checked after sweep |

---

## Order of operations

1. Add the lint script first (it's the test for steps 2–6).
2. Run the em-dash sweep on existing files. This strips em-dashes from the *old* §7 text, the *old* FAQ, the refund-retention skill, the mirrors, etc.
3. Verify the lint passes (exit 0). Commit the sweep.
4. Rewrite `common-issues.md §7` with the new analytics content (must contain no em-dashes — the lint script catches accidental drift).
5. Append the 5 new FAQ entries to `faq.md`.
6. Make the two surgical SOUL.md edits.
7. Run lint, markdownlint, and mirror-diff verifications. Open the PR.

This order ensures the new content I author cannot reintroduce em-dashes — the lint script is in place before any of the new content is written.

---

### Task 1: Add the em-dash lint script

**Files:**
- Create: `scripts/lint-no-em-dash.sh`

- [ ] **Step 1: Verify the script doesn't already exist**

```bash
ls scripts/lint-no-em-dash.sh 2>&1
```
Expected: `ls: cannot access 'scripts/lint-no-em-dash.sh': No such file or directory`

- [ ] **Step 2: Write the script**

```bash
cat > scripts/lint-no-em-dash.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Fail if em-dashes (U+2014) appear anywhere in Caroline's customer-facing
# surface. There are no legitimate exceptions: the Forbidden-phrasing block
# in common-issues.md uses en-dashes only, and any new instance is a bug.

# Guard: must be run from repo root, otherwise paths silently miss and the
# script returns 0 falsely.
[ -d workspaces/support ] || {
  echo "Run from repo root; workspaces/support not found." >&2
  exit 2
}

BAD=$(grep -rn $'\xe2\x80\x94' \
  workspaces/support/ \
  skills-all/muso-intercom/ \
  workspaces/{ceo,cto,operations}/skills/muso-intercom/ \
  2>/dev/null || true)

if [ -n "$BAD" ]; then
  echo "Em-dashes found in customer-facing knowledge base:"
  echo "$BAD"
  exit 1
fi
echo "OK: no stray em-dashes in customer-facing surface."
EOF
chmod +x scripts/lint-no-em-dash.sh
```

- [ ] **Step 3: Confirm the script catches the existing em-dashes (this is the failing test)**

Run: `bash scripts/lint-no-em-dash.sh`
Expected: exit code 1, output begins with `Em-dashes found in customer-facing knowledge base:` followed by ~73 lines of `path:line:content` (one per em-dash). This is the script's "before" state and confirms it actually scans.

- [ ] **Step 4: Confirm the repo-root guard works**

Run: `(cd /tmp && bash /Users/nick/.superconductor/worktrees/hydra/sc-tunneled-niobium-ff6b/scripts/lint-no-em-dash.sh)`
Expected: exit code 2, stderr contains `Run from repo root; workspaces/support not found.`

- [ ] **Step 5: Run shellcheck (matches the repo's pre-commit gate for *.sh files)**

Run: `shellcheck scripts/lint-no-em-dash.sh`
Expected: no output, exit code 0. If shellcheck flags style issues, fix them inline before continuing.

- [ ] **Step 6: Commit**

```bash
git add scripts/lint-no-em-dash.sh
git commit -m "chore(support): add lint-no-em-dash.sh on-demand check

Guards Caroline's customer-facing knowledge base against em-dash
(U+2014) drift; en-dashes (U+2013) are the house style going forward.
"
```

---

### Task 2: Run the em-dash sweep across the customer-facing surface

**Files modified:**
- `workspaces/support/SOUL.md` (7 em-dashes → 0)
- `workspaces/support/reference/common-issues.md` (22 → 0)
- `workspaces/support/reference/faq.md` (14 → 0)
- `workspaces/support/reference/subscriptions-and-billing.md` (3 → 0)
- `workspaces/support/skills/refund-retention/SKILL.md` (21 → 0)
- `workspaces/support/skills/output-sanitizer/SKILL.md` (1 → 0)
- `workspaces/support/skills/action-request/SKILL.md` (1 → 0)
- `skills-all/muso-intercom/SKILL.md` (1 → 0)
- `workspaces/ceo/skills/muso-intercom/SKILL.md` (1 → 0)
- `workspaces/cto/skills/muso-intercom/SKILL.md` (1 → 0)
- `workspaces/operations/skills/muso-intercom/SKILL.md` (1 → 0)
- `workspaces/support/reference/platform-features.md` (0 — no-op)
- `workspaces/support/reference/credits-and-profiles.md` (0 — no-op)
- `workspaces/support/reference/products-and-pricing.md` (0 — no-op)
- `workspaces/support/skills/input-sanitizer/SKILL.md` (0 — no-op)

- [ ] **Step 1: Confirm baseline em-dash count**

Run:
```bash
grep -rc $'\xe2\x80\x94' \
  workspaces/support/ \
  skills-all/muso-intercom/ \
  workspaces/{ceo,cto,operations}/skills/muso-intercom/ \
  | awk -F: '{s+=$2} END {print s}'
```
Expected: `73` (matches the spec baseline). If the number is different, stop and reconcile — files may have changed since the spec was written.

- [ ] **Step 2: Run the sweep**

```bash
files=(
  workspaces/support/SOUL.md
  workspaces/support/reference/common-issues.md
  workspaces/support/reference/faq.md
  workspaces/support/reference/platform-features.md
  workspaces/support/reference/subscriptions-and-billing.md
  workspaces/support/reference/credits-and-profiles.md
  workspaces/support/reference/products-and-pricing.md
  workspaces/support/skills/refund-retention/SKILL.md
  workspaces/support/skills/input-sanitizer/SKILL.md
  workspaces/support/skills/output-sanitizer/SKILL.md
  workspaces/support/skills/action-request/SKILL.md
  skills-all/muso-intercom/SKILL.md
  workspaces/ceo/skills/muso-intercom/SKILL.md
  workspaces/cto/skills/muso-intercom/SKILL.md
  workspaces/operations/skills/muso-intercom/SKILL.md
)
for f in "${files[@]}"; do
  [ -f "$f" ] && perl -i -pe 's/\x{2014}/\x{2013}/g' "$f"
done
```

- [ ] **Step 3: Run the lint script — this should now pass**

Run: `bash scripts/lint-no-em-dash.sh`
Expected: exit 0, output: `OK: no stray em-dashes in customer-facing surface.`

If it fails, the failure output will list every remaining em-dash. The most common cause is a file outside the `files=()` array — add it and re-sweep.

- [ ] **Step 4: Spot-check the changes look reasonable**

Run: `git diff --stat`
Expected: 11 files changed (the four 0-em-dash files won't appear). Insertions roughly equal deletions (a 3-byte em-dash → 3-byte en-dash; both are 3 UTF-8 bytes, so line lengths are unchanged and no diff line count surprise).

- [ ] **Step 5: Commit**

```bash
git add workspaces/support/ skills-all/muso-intercom/ workspaces/{ceo,cto,operations}/skills/muso-intercom/
git commit -m "chore(support): em-dash → en-dash sweep across Caroline's KB

Replaces 73 U+2014 em-dashes with U+2013 en-dashes across the
customer-facing surface (workspaces/support/ + skills-all/muso-intercom
+ 3 muso-intercom workspace mirrors). House style going forward; the
new lint script (scripts/lint-no-em-dash.sh) enforces.

No content changes; only punctuation.
"
```

---

### Task 3: Verify the muso-intercom mirrors didn't develop new drift

**Files:**
- (Read-only) `skills-all/muso-intercom/SKILL.md`
- (Read-only) `workspaces/{ceo,cto,operations}/skills/muso-intercom/SKILL.md`

Per memory `feedback_skill_dual_tree`: when fixing any skill, always check skills-all/ AND every workspaces/<agent>/skills/ copy, because some are hardlinked, most are independent drift. Confirm the sweep didn't introduce new drift relative to whatever drift exists today.

- [ ] **Step 1: Stash the current state, fetch pre-sweep state, compute drift, restore**

```bash
# Save current (post-sweep) drift fingerprint
post_drift=$(
  diff skills-all/muso-intercom/SKILL.md workspaces/ceo/skills/muso-intercom/SKILL.md | wc -l;
  diff skills-all/muso-intercom/SKILL.md workspaces/cto/skills/muso-intercom/SKILL.md | wc -l;
  diff skills-all/muso-intercom/SKILL.md workspaces/operations/skills/muso-intercom/SKILL.md | wc -l;
)
echo "Post-sweep drift line counts (ceo / cto / operations): $post_drift"
```

- [ ] **Step 2: Compare against pre-sweep drift using `git stash`**

```bash
# Stash the sweep, measure pre-sweep drift, then unstash
git stash push -- skills-all/muso-intercom/SKILL.md \
                workspaces/ceo/skills/muso-intercom/SKILL.md \
                workspaces/cto/skills/muso-intercom/SKILL.md \
                workspaces/operations/skills/muso-intercom/SKILL.md

pre_drift_ceo=$(diff skills-all/muso-intercom/SKILL.md workspaces/ceo/skills/muso-intercom/SKILL.md | wc -l)
pre_drift_cto=$(diff skills-all/muso-intercom/SKILL.md workspaces/cto/skills/muso-intercom/SKILL.md | wc -l)
pre_drift_ops=$(diff skills-all/muso-intercom/SKILL.md workspaces/operations/skills/muso-intercom/SKILL.md | wc -l)
echo "Pre-sweep drift (ceo / cto / operations): $pre_drift_ceo / $pre_drift_cto / $pre_drift_ops"

git stash pop
```

- [ ] **Step 3: Confirm post-sweep drift equals pre-sweep drift**

Compute the same numbers post-sweep and compare manually. If they match, the sweep applied identically to all four mirrors and we did not introduce new drift. If they diverge, investigate — most likely a mirror had a different em-dash position than the others, or a unicode-encoded variant we missed.

Expected: pre-drift line counts == post-drift line counts for all three (ceo, cto, operations) vs skills-all.

- [ ] **Step 4: No commit (verification only)**

If drift state is unchanged, proceed to Task 4. If new drift was introduced, fix it before continuing.

---

### Task 4: Rewrite `common-issues.md §7` with the new analytics content

**Files:**
- Modify: `workspaces/support/reference/common-issues.md` (replace the entire section starting `## 7. Analytics not showing`, ending before `## 8. Can't log in`)

The new content must contain no em-dashes (the lint script will catch any). Use only en-dashes (U+2013) where dashes are needed.

- [ ] **Step 1: Identify the exact byte-range of §7 in the current file**

Run: `grep -n '^## ' workspaces/support/reference/common-issues.md`
Expected: a list of section headers with line numbers. Note the line numbers of `## 7.` and `## 8.` — §7 spans from `## 7.` line up to (but not including) the `## 8.` line.

- [ ] **Step 2: Replace §7 in place**

Use a text editor or programmatic replacement. The full replacement text is below. Open the file, delete from the line `## 7. Analytics not showing` through the blank line immediately before `## 8. Can't log in`, and paste the following:

```markdown
## 7. Analytics not showing / streams not updating

**Customer says:** "My analytics aren't updating," "I just upgraded but no
streams," "My Spotify shows X streams but Muso shows Y," "I'm on Pro but I
see nothing."

The analytics pipeline is being upgraded. We are shipping a new version of
analytics with better data and additional features. Caroline does NOT know
the current refresh cadence and MUST NOT quote specific timing (no "24
hours," "48–96 hours," "Friday 4PM EST," etc.). Aaron and engineering own
this; Caroline's job is to keep the customer warm and file a ticket if they
push back.

**Tone (read this before responding):**

- Do NOT apologise. No "sorry for the delay," no "I understand your
  frustration."
- Position the gap as us actively improving, not as a problem we're hiding.
- Be direct and confident, not defensive.
- Never promise rewards, credits, free months, or specific timing.

**Resolution path:**

1. Confirm the basics – these are real prerequisites, not stalls:
   - Active Pro or Business subscription (not Lite). If they're on Lite,
     that's the answer.
   - Their profile has a seat assigned (Settings > Subscription).
   - If they're asking specifically about Apple Music data, see faq.md →
     "Apple Music streams."

2. If subscription + seat are good and they're seeing missing or stale data,
   deflect with confidence. Use phrasing along the lines of:

   > "We're upgrading the analytics infrastructure and rolling out a new
   > version of analytics with better data and new features. Things are
   > landing in stages, so you'll see your numbers improve as it ships. If
   > you want me to flag your account so the team can check on yours
   > specifically, I can open a ticket."

3. Expect pushback ("I want it working now"). Do NOT repeat the same line,
   do NOT get defensive. Acknowledge directly and offer the ticket:

   > "Totally fair. I can't speed it up from here, but I can make sure the
   > team has eyes on your account – want me to open a ticket?"

4. **Escalate** when any of these are true:
   - Customer accepts the ticket offer.
   - High-catalog customer asking specific data questions Caroline can't
     answer.
   - Customer is clearly frustrated after one deflection cycle.

   Ticket category: "Analytics – Data Question." Include account email,
   profile URL, subscription plan, what they're seeing vs what they
   expected. SLA: 1 business day.

5. **Never promise:**
   - Specific timing for fixes, refreshes, or data backfills.
   - Rewards, credits, free months, or compensation of any kind.
   - Apple Music data (we don't have it yet – see FAQ).
   - Feature parity with Spotify-for-Artists or any other platform.

**Forbidden phrasing (verbatim from human-agent scripts; do NOT use):**

- "Please allow 48–96 hours…"
- "Please allow 72–120 hours…"
- "Milestones refresh every Friday at 4 PM EST."
- "Sorry for the inconvenience."
- "Once subscribed, please be patient as it takes time to populate."

```

- [ ] **Step 3: Run the lint script — must still pass after the rewrite**

Run: `bash scripts/lint-no-em-dash.sh`
Expected: exit 0, `OK: no stray em-dashes in customer-facing surface.`

If it fails, the new content I just pasted contains an em-dash I missed. Fix and re-lint.

- [ ] **Step 4: Run markdownlint on the file**

Run: `npx --yes markdownlint-cli2 workspaces/support/reference/common-issues.md 2>&1 | tail -20`

Expected: errors exist (the file already has many MD013 line-length and MD032 blanks-around-lists pre-existing errors, ~30 of them). Confirm no NEW error categories appeared — particularly NO `MD007/ul-indent` errors, since the §7 replacement uses 3-space indent matching the rest of the file.

If new error categories appear, fix them inline.

- [ ] **Step 5: Diff for sanity**

Run: `git diff workspaces/support/reference/common-issues.md`
Expected: §7 fully replaced. Other sections untouched. The diff should not show changes outside §7.

- [ ] **Step 6: Commit**

```bash
git add workspaces/support/reference/common-issues.md
git commit -m "feat(support): rewrite common-issues §7 analytics tone

Strips the contradictory '24h / 4PM EST' timing claim that disagreed
with what human agents actually tell customers (48-96h / weekly
Friday 4PM). Replaces with no-apology / 'new version of analytics
shipping' posture per Fede's brief. Caroline no longer quotes any
specific timing; she deflects with confidence and offers a ticket if
the customer pushes back.

Forbidden-phrasing block at the end captures the bad scripts we
explicitly do NOT want Caroline to use, so future drift is easy to
spot in review.
"
```

---

### Task 5: Append five new FAQ entries to `faq.md`

**Files:**
- Modify: `workspaces/support/reference/faq.md` (append three new sections at the end of the file: Analytics, Plaque orders, Profile management)

- [ ] **Step 1: Read the current file's tail to know where to append**

Run: `tail -20 workspaces/support/reference/faq.md`
Expected: shows the last existing entry. Note its trailing structure (blank lines, separators) so the new content matches.

- [ ] **Step 2: Append the new entries**

Open `workspaces/support/reference/faq.md` and append at the end:

```markdown

---

## Analytics

### Why don't I see Apple Music streams?
Apple Music isn't available in Muso analytics today. It's a known request,
but there's no committed date.

### My Spotify numbers don't match Muso's numbers – why?
Streaming numbers come from each platform on its own schedule, and we're
upgrading how analytics get pulled and refreshed. Some difference between
Muso and what you see on Spotify can persist because each platform's
attribution and reporting works differently, but this should improve as the
analytics upgrade rolls out. If a specific track looks badly off and you'd
like the team to check it, share the track URL and I can open a ticket.

---

## Plaque orders

### Do I need a paid subscription to order a plaque?
No. Subscriptions unlock analytics and performance insights – they aren't
required for managing your profile or ordering a plaque. You can add,
remove, and correct credits on a free Lite account, and you can order a
plaque from the Promotions tab regardless of your plan.

### My plaque shows old stream numbers – can it be updated?
Plaques are locked to the analytics snapshot from the day the order was
placed. That's intentional – the plaque is meant to commemorate where you
were at that moment, not track new streams forever. If your plaque captured
the wrong number (e.g. a sync hadn't completed yet on the order date), open
a ticket with the order ID and the team will sort it out.

---

## Profile management

### I don't have a paid plan – can I still fix wrong credits on my profile?
Yes. Adding, removing, and correcting credits is free. Subscriptions are
only needed for analytics and insights, not for basic profile work. If
you're hitting a UI issue while editing, let me know and I'll open a ticket
so the team can look.
```

- [ ] **Step 3: Run the lint script**

Run: `bash scripts/lint-no-em-dash.sh`
Expected: exit 0. If it fails, the new content contains an em-dash. Fix and re-lint.

- [ ] **Step 4: Run markdownlint on the file**

Run: `npx --yes markdownlint-cli2 workspaces/support/reference/faq.md 2>&1 | tail -15`

Expected: errors may exist (pre-existing baseline). Confirm no NEW error categories appeared because of the appended content. Pay attention to MD032 — every bulleted list under the new entries should have a blank line before its first bullet (the new entries don't actually use bullets, but headings need the standard blank-line spacing).

- [ ] **Step 5: Diff sanity check**

Run: `git diff workspaces/support/reference/faq.md`
Expected: the diff is purely additive at the end of the file. Existing entries untouched.

- [ ] **Step 6: Commit**

```bash
git add workspaces/support/reference/faq.md
git commit -m "feat(support): add 5 FAQ entries from Intercom audit gaps

From the 2026-01..05 Intercom audit (248 conversations):

- Apple Music absence (avoids 'we're working on a partnership' which
  has been used unchanged for 4+ months and reads as a soft promise).
- Spotify-vs-Muso number mismatch (acknowledges platform attribution
  differences without overpromising resolution).
- Free users CAN manage credits without a paid plan (the #2 confusion
  in the audit, after analytics latency).
- Plaque orders don't require a subscription.
- Plaques are snapshots locked at order time (subject to operations
  confirmation per blocker #1 — drop the entry if plaques don't work
  this way).
"
```

---

### Task 6: Two surgical SOUL.md edits (Never-do list + analytics example)

**Files:**
- Modify: `workspaces/support/SOUL.md` (add 2 bullets to Tone Calibration "Never do" list, replace the Troubleshooting example for analytics)

Reality check: SOUL.md is 18,283 chars at baseline, already past the 12,000 silent-truncation cliff. This task adds ≈+120 chars; the file remains over-cliff. The lint script + KB edits are the real enforcement, SOUL.md is best-effort. See spec "Where the real enforcement lives."

- [ ] **Step 1: Locate the "Never do" list**

Run: `grep -n '^- ' workspaces/support/SOUL.md | head -20`
Expected: a list of bulleted lines. Identify the bullets in the "Never do" section (look for the line `**Never do**:` first, then the bullets immediately following).

- [ ] **Step 2: Add 2 bullets to the "Never do" list**

After the existing last bullet (`- Repeat the customer's question back to them`), add:

```markdown
- Use the U+2014 em-dash. Use the U+2013 en-dash (`–`) instead.
- Apologise about analytics latency, missing data, or refresh delays. The
  pipeline is being upgraded; reframe as improvement, not failure.
```

The first bullet uses the literal text `U+2014` rather than the character itself, so the rule line does not trip the lint script it is announcing. The second bullet wraps to the next line to stay under 80 cols.

- [ ] **Step 3: Replace the analytics troubleshooting example**

Find the example block under `*Troubleshooting:*`. Currently it reads:

```markdown
*Troubleshooting:*
> Customer: "My analytics aren't showing"
> Caroline: "Analytics need a Pro or Business subscription with a seat assigned to your profile. Check Settings > Billing to make sure your plan is active. If it is, let me know and I'll create a ticket for our team to look into it."
```

Replace with:

```markdown
*Troubleshooting:*
> Customer: "My analytics aren't showing"
> Caroline: "First, double-check you're on Pro/Business with a seat
> assigned (Settings > Subscription). If that's good, we're rolling out a
> new version of analytics right now – things land in stages. Want me to
> open a ticket?"
```

- [ ] **Step 4: Run the lint script**

Run: `bash scripts/lint-no-em-dash.sh`
Expected: exit 0. If the new content reintroduced any em-dash, fix.

- [ ] **Step 5: Confirm SOUL.md char count is in the expected range**

Run: `wc -c workspaces/support/SOUL.md`
Expected: ≈ 18,283 + 120 ≈ 18,400 chars (acceptable; the file is over-cliff, this PR doesn't materially change that). If the count is dramatically different (>+500 chars), the edits were over-applied — review the diff.

- [ ] **Step 6: Diff sanity check**

Run: `git diff workspaces/support/SOUL.md`
Expected: 2 added bullets in "Never do," and the analytics example block replaced. No other changes.

- [ ] **Step 7: Commit**

```bash
git add workspaces/support/SOUL.md
git commit -m "feat(support): SOUL.md analytics tone + em-dash rules

- Adds two 'Never do' bullets: no em-dashes (use en-dashes), and no
  apology about analytics latency.
- Replaces the troubleshooting example for analytics with the new
  'rolling out a new version' deflection.

SOUL.md remains over the 12000-char truncation cliff (issue #165);
this PR does not attempt to fix that. Mechanical enforcement of these
rules lives in scripts/lint-no-em-dash.sh and the rewritten
common-issues.md §7, both of which are stable.
"
```

---

### Task 7: Final pre-PR verification

- [ ] **Step 1: Lint passes**

Run: `bash scripts/lint-no-em-dash.sh`
Expected: exit 0, `OK: no stray em-dashes in customer-facing surface.`

- [ ] **Step 2: All commits present, working tree clean**

Run: `git log --oneline -10`
Expected: 5 new commits on top of the existing branch (in addition to the spec commit `e772bcf`):
1. `chore(support): add lint-no-em-dash.sh on-demand check`
2. `chore(support): em-dash → en-dash sweep across Caroline's KB`
3. `feat(support): rewrite common-issues §7 analytics tone`
4. `feat(support): add 5 FAQ entries from Intercom audit gaps`
5. `feat(support): SOUL.md analytics tone + em-dash rules`

Run `git status` and confirm `nothing to commit, working tree clean`.

- [ ] **Step 3: SOUL.md char count regression check**

Run: `wc -c workspaces/support/SOUL.md`
Expected: between 18,300 and 18,500 (baseline 18,283 + ~120). Flag if outside this range.

- [ ] **Step 4: muso-intercom mirror drift unchanged**

Run:
```bash
diff skills-all/muso-intercom/SKILL.md workspaces/ceo/skills/muso-intercom/SKILL.md | wc -l
diff skills-all/muso-intercom/SKILL.md workspaces/cto/skills/muso-intercom/SKILL.md | wc -l
diff skills-all/muso-intercom/SKILL.md workspaces/operations/skills/muso-intercom/SKILL.md | wc -l
```
Expected: same line counts as Task 3's pre-sweep measurement. No new drift.

- [ ] **Step 5: No new markdownlint error categories vs baseline**

Run:
```bash
npx --yes markdownlint-cli2 \
  workspaces/support/reference/common-issues.md \
  workspaces/support/reference/faq.md \
  workspaces/support/SOUL.md \
  2>&1 | grep -oE 'MD[0-9]+/[a-zA-Z-]+' | sort -u
```
Expected: only `MD013` (line-length), `MD032` (blanks-around-lists), and possibly `MD041` (first-line-h1) — all pre-existing categories. NO new categories like `MD007` (ul-indent), `MD025` (single-h1), etc. If a new category appears, fix it inline.

---

### Task 8: Manual behavioural smoke test (DO LAST, requires human)

**Files:** none — this is a runtime check on Caroline via the dev gateway.

This is qualitative validation: send Caroline these prompts via the dev Intercom inbox / `openclaw-dev` profile and confirm her replies match the new tone. Pass criteria are "feels right," not deterministic — Caroline is stochastic.

- [ ] **Step 1: Confirm the dev gateway is up and Caroline is reachable**

Run: per the existing dev workflow (this varies; if unclear, ping Aaron or check `openclaw-dev.json`).

- [ ] **Step 2: Run the smoke prompts and verify**

Send these messages to Caroline via the dev inbox and verify her replies match the criteria:

| Prompt | Pass criteria |
|---|---|
| "My analytics aren't showing" | Confirms Pro/Business + seat first. Then mentions "new version of analytics" / "upgrading." Offers a ticket. **No "sorry," no "48-96 hours," no "Friday 4PM."** |
| "I want it working now" (after the deflection above) | Acknowledges, doesn't repeat itself, offers a ticket. |
| "Why don't you have Apple Music?" | Says it isn't available today, no committed date. **No "we're working on a partnership."** |
| "My plaque shows old numbers" | Explains the order-time snapshot. Offers a ticket if order-time number looked wrong. |
| "Do I need to pay to fix my credits?" | Answers "no, that's free." |
| "I want a refund" | refund-retention skill activates and runs its 3-gate flow (regression check; this PR didn't touch it). |

- [ ] **Step 3: If any prompt fails, decide:** is the failure due to (a) the SOUL.md edits being truncated by issue #165, or (b) actually-broken content? If (a), accept and ship — the lint + KB edits are the real enforcement and they don't depend on SOUL.md. If (b), fix the relevant common-issues / faq entry.

- [ ] **Step 4: No commit (verification only)**

---

### Task 9: Open the PR

- [ ] **Step 1: Push the branch**

Run: `git push -u origin chore/intercom-refund-analysis`

- [ ] **Step 2: Open the PR via gh**

```bash
gh pr create \
  --title "feat(support): caroline analytics KB rewrite + em-dash sweep" \
  --body "$(cat <<'EOF'
## Summary

- Rewrites Caroline's analytics complaint flow to follow Fede's tone direction: no apology, reframe as "new version of analytics shipping," never quote specific timing, never promise rewards.
- Adds 5 new FAQ entries surfaced by the 2026-01..05-04 Intercom audit (248 conversations): Apple Music absence, Spotify-vs-Muso number mismatch, free users can fix credits, plaque-no-subscription-needed, plaque-snapshot-at-order-time.
- Replaces 73 em-dashes (U+2014) with en-dashes (U+2013) across the customer-facing surface (workspaces/support/, skills-all/muso-intercom/, and the 3 muso-intercom workspace mirrors).
- Adds `scripts/lint-no-em-dash.sh` as on-demand enforcement.

Spec: `docs/superpowers/specs/2026-05-08-caroline-analytics-knowledge-base-design.md`

## Blockers (resolve before merge)

- [ ] Confirm with Jan / fulfilment that plaques are locked to the order-time analytics snapshot. If not, drop the plaque-snapshot FAQ entry.
- [ ] Confirm with Aaron / Product whether there's approved public roadmap wording for Apple Music. If yes, swap that wording in. Otherwise the conservative line stands.

## Out of scope (separate Linear tickets)

- Engineering: leaked `cluster.local` password-reset URL.
- Operations: human-agent script alignment (so they stop saying "sorry," "48-96 hours," etc.).
- Operations: silent-close behaviour audit (46/65 customer-initiated tickets closed without admin reply).
- Refund-retention rewrite (blocked on payment-link infra).
- SOUL.md truncation overhang fix (issue #165).

## Test plan

- [x] `bash scripts/lint-no-em-dash.sh` exits 0
- [x] `wc -c workspaces/support/SOUL.md` between 18,300 and 18,500
- [x] muso-intercom mirror drift unchanged from pre-PR baseline
- [x] No new markdownlint error categories vs baseline
- [ ] Manual smoke test in dev: 6 prompts above all pass criteria

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Confirm PR opened**

Run: `gh pr view --json url,number -q '.url'`
Expected: a URL to the new PR. Paste the URL into the conversation when done.

---

## Self-review notes

This plan was written with the spec open. Coverage check:

- ✅ Spec File Footprint table → Plan File Structure section (15 files, identical).
- ✅ Spec common-issues.md §7 replacement → Task 4 (full text included).
- ✅ Spec faq.md additions → Task 5 (5 entries: Apple Music, Spotify, plaque-sub, plaque-snapshot, free-fix).
- ✅ Spec SOUL.md changes → Task 6 (2 Never-do bullets + analytics example replacement).
- ✅ Spec em-dash sweep mechanic → Task 2.
- ✅ Spec lint script → Task 1.
- ✅ Spec drift check → Task 3.
- ✅ Spec validation criteria (lint, char count, mirror diff, markdownlint) → Task 7.
- ✅ Spec smoke-test prompts → Task 8.
- ✅ Spec rollout (PR + deploy.sh picks up next run) → Task 9.
- ✅ Spec blockers (plaque, Apple Music) → flagged in Task 9 PR body.
- ✅ Spec copy guardrails (no future timing drift, no analytics-support implication for free users, plaque language) → embedded in Tasks 4–6 inline.
