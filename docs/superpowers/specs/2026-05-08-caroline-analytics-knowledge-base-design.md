# Caroline analytics knowledge base + em-dash sweep

**Date:** 2026-05-08
**Owner:** Nick
**Stakeholders:** Fede (tone direction), Jan (operations), Aaron (analytics infra truth)
**Status:** spec, awaiting review

## Background

A 124-day audit of Intercom (2026-01-01 to 2026-05-04, 248 unique
conversations after de-noising the credit-verification queue and the bulk
co-founder outreach) surfaced three things worth acting on:

1. **Analytics is the #1 product complaint** by volume (55 conversations).
   Human agents respond with a canned timing line ("48–96 hours," "72–120
   hours," "every Friday at 4 PM EST") that contradicts what's currently in
   Caroline's `common-issues.md#7`, and Aaron is the only person with
   visibility into whether either number is true today. Fede's direction:
   stop apologising, reframe as "we're upgrading the infrastructure / new
   version of analytics is coming," ask for patience, never promise rewards
   or specific timing. Internally we call it "V2" but the public phrasing is
   "a new version of analytics."

2. **Three recurring FAQ gaps** with no Caroline coverage today: Apple Music
   data (we don't have it; agents have used "we're working on a partnership"
   unchanged for 4+ months), plaque vs. analytics confusion (customers think
   they need a paid plan to manage credits; they don't), and plaque-locked-
   at-order-time (customers don't realise the snapshot is intentional).

3. **Em-dashes have crept across Caroline's customer-facing surface.** Nick
   wants en-dashes (`–`) used in their place going forward, and the existing
   files cleaned up.

Out of scope, but found in the same audit and filed separately: the
refund-retention skill could match the live human-agent retention script
better (parked, blocked on payment-link infra); 71% of customer-initiated
"app broken" tickets get silent-closed without an admin reply (operations
training problem, not Caroline's); the password-reset email leaks an
internal `credits.muso-prod.svc.cluster.local:3000` URL (engineering bug).

## Goals

- Caroline answers analytics complaints with the new tone: no apology,
  reframe as improvement landing, never quote specific timing, never promise
  rewards.
- Three new FAQ entries cover Apple Music absence, plaque-as-snapshot, and
  the "do I need a paid plan to fix credits" question.
- Em-dashes (`—`) replaced with en-dashes (`–`) across Caroline's
  customer-facing surface, with a SOUL.md rule preventing future drift and
  an on-demand lint script.
- No service restart, no openclaw config change, no runtime code/config
  change. The only non-markdown addition is `scripts/lint-no-em-dash.sh`,
  an on-demand check that does not run at runtime.

## Non-goals

- Re-writing refund-retention. (Blocked on payment-link infra.)
- Fixing the silent-close human-agent behaviour. (Operations / Jan.)
- Fixing the leaked `cluster.local` reset URL. (Engineering ticket.)
- Encoding specific analytics timings ("24h," "48–96h," "weekly Friday 4PM").
  We deliberately do not know these and refuse to invent them.
- Repo-wide em-dash sweep. Customer-facing surface only.
- Promising Apple Music data, V2 ship date, or any compensation menu to
  customers.

## Design

### Architecture

Edit-in-place across Caroline's existing knowledge base — no new Caroline
files, no new skills. The factual content is small enough and the tone shift
specific enough that a dedicated `analytics-deflection` skill would be
over-engineering; promote later if Fede wants gates or variants. One new
infrastructure file (`scripts/lint-no-em-dash.sh`) is added outside Caroline's
KB to keep the em-dash rule enforceable on demand.

### File footprint

```
workspaces/support/
├── SOUL.md                                  EDIT  (2 tone rules + replace 1 example)
├── reference/
│   ├── common-issues.md                     EDIT  (rewrite §7 Analytics)
│   ├── faq.md                               EDIT  (add 3 entries + em-dash sweep)
│   ├── platform-features.md                 EDIT  (em-dash sweep only)
│   ├── subscriptions-and-billing.md         EDIT  (em-dash sweep only)
│   ├── credits-and-profiles.md              EDIT  (em-dash sweep only)
│   └── products-and-pricing.md              EDIT  (em-dash sweep only)
└── skills/
    ├── refund-retention/SKILL.md            EDIT  (em-dash sweep only)
    ├── input-sanitizer/SKILL.md             EDIT  (em-dash sweep only)
    ├── output-sanitizer/SKILL.md            EDIT  (em-dash sweep only)
    └── action-request/SKILL.md              EDIT  (em-dash sweep only)

skills-all/muso-intercom/SKILL.md            EDIT  (em-dash sweep)
workspaces/{ceo,cto,operations}/skills/muso-intercom/SKILL.md   EDIT  (em-dash sweep, drift-checked)

scripts/lint-no-em-dash.sh                   NEW   (on-demand check, no pre-commit hook)
```

### common-issues.md §7 — replacement text

The existing §7 contradicts what human agents say (24h vs. 48–96h) and
embeds a specific timing claim no one currently in scope (Nick / Jan / Fede)
can verify. Strip the timing entirely. Replace with the no-apology /
reframe-as-improvement posture, plus an explicit forbidden-phrasing list to
make future drift easy to spot.

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

The Forbidden phrasing block contains only en-dashes (in `48–96` and
`72–120`), no em-dashes. The lint script therefore needs no allowlist —
preserve the bad wording, not the bad punctuation.

### faq.md — three new entries

Append to existing `faq.md`. Tone matches the rest of the file. En-dashes
only.

```markdown
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

The plaque-locked-at-order-time entry is encoded from the human-agent
support tickets in the audit. The implementation step "verify with
operations / Jan that this matches actual plaque behaviour" is a
prerequisite before merge — see Open Questions.

### SOUL.md — two surgical changes

Two surgical edits, kept tight to add as little to the file as possible
(net ≈ +120 chars). Truncation context follows.

**Reality check.** Today `SOUL.md` is 18,283 chars — already 6,283 chars
past the 12,000 silent-truncation cliff documented in
`project_soul_memory_truncation` (hydra issue #165). The file is being
truncated at injection now, today, regardless of this PR.

**Where the real enforcement lives.** Mechanical enforcement of this PR's
rules comes from (a) `scripts/lint-no-em-dash.sh` and (b) the edits to
`common-issues.md` and `faq.md` — those are stable. The SOUL.md edits are
best-effort additions to a file that's already truncating; they may or may
not survive injection on any given turn. We accept that and rely on the
hard mechanical layer below the persona for correctness. The +120 chars
this PR adds are a rounding error against that overage and do not materially
change the situation, but they also do not put the file under the cliff.
This PR explicitly does NOT try to fix the truncation problem; that's
issue #165's job. We accept that the new tone bullets and the new analytics
example may or may not survive truncation, on the same terms as everything
else in this file.

**Change A — extend "Never do" list:**

```diff
 - Repeat the customer's question back to them
+- Use the U+2014 em-dash. Use the U+2013 en-dash (`–`) instead.
+- Apologise about analytics latency, missing data, or refresh delays. The
+  pipeline is being upgraded; reframe as improvement, not failure.
```

**Change B — replace the analytics troubleshooting example.** The current
example has Caroline give a clean diagnostic answer but doesn't carry the
new tone:

```diff
 *Troubleshooting:*
 > Customer: "My analytics aren't showing"
-> Caroline: "Analytics need a Pro or Business subscription with a seat
-> assigned to your profile. Check Settings > Billing to make sure your plan
-> is active. If it is, let me know and I'll create a ticket for our team to
-> look into it."
+> Caroline: "First, double-check you're on Pro/Business with a seat
+> assigned (Settings > Subscription). If that's good, we're rolling out a
+> new version of analytics right now – things land in stages. Want me to
+> open a ticket?"
```

### Em-dash sweep mechanic

One-shot script run locally during implementation:

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

`perl -i -pe` is portable across macOS/GNU; UTF-8 safe.

The Forbidden-phrasing block contains no U+2014 characters, so it needs no
lint exception.

### scripts/lint-no-em-dash.sh

New, on-demand check. Not wired to a pre-commit hook (too invasive for the
surface). Suggested addition to CI later if drift recurs.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Fail if em-dashes (U+2014) appear anywhere in Caroline's customer-facing
# surface. There are no legitimate exceptions: the Forbidden-phrasing block
# in common-issues.md §7 uses en-dashes only, and any new instance is a bug.

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
```

No allowlist, no fenced markers, no exceptions. If a future change ever
genuinely needs an em-dash inside a quoted block, that change is responsible
for adding a `noqa-em-dash` mechanism at the time — we don't pay that
complexity cost up front.

### Skill mirror sync

Per `feedback_skill_dual_tree`, `muso-intercom/SKILL.md` exists in 4
places: `skills-all/` plus three workspace mirrors (ceo, cto, operations).
The em-dash sweep covers all four. After the sweep:

```bash
diff skills-all/muso-intercom/SKILL.md workspaces/ceo/skills/muso-intercom/SKILL.md
diff skills-all/muso-intercom/SKILL.md workspaces/cto/skills/muso-intercom/SKILL.md
diff skills-all/muso-intercom/SKILL.md workspaces/operations/skills/muso-intercom/SKILL.md
```

If the diffs reveal pre-existing drift unrelated to em-dashes, that goes
into a separate ticket and does NOT block this PR.

## Validation

### Mechanical (must pass before merge)

- `bash scripts/lint-no-em-dash.sh` exits 0.
- `wc -c workspaces/support/SOUL.md` does not regress significantly. (Pre-PR
  baseline: 18,283 chars — already past the 12,000 truncation cliff per
  issue #165. This PR adds ≈120 chars; +1% and acceptable. Do NOT attempt to
  bring the file under 12,000 in this PR; that is issue #165's job.)
- The 4 muso-intercom mirror diffs match pre-PR drift state (no new drift).
- `npx markdownlint-cli2 workspaces/support/reference/common-issues.md`
  shows no NEW errors vs the pre-PR baseline. The existing file already has
  pre-existing MD013 (line-length) and MD032 (blanks-around-lists) errors;
  the proposed §7 replacement does not add to them and includes blank lines
  before the "Tone" and "Forbidden phrasing" bullet lists. (Indent is not a
  problem — both the existing file and the replacement use 3-space indent
  consistently and pass MD007.)

### Behavioural smoke test (manual, ~10 min)

Send these prompts to Caroline via the dev gateway / `openclaw-dev` profile.
Pass criteria are qualitative — "response feels right" — because the goal
of this change is tone, not deterministic output.

| Prompt | Pass criteria |
|---|---|
| *"My analytics aren't showing"* | Confirms Pro/Business + seat first. Then mentions "new version of analytics" / "upgrading," offers a ticket. **No "sorry," no "48–96 hours," no "Friday 4PM."** |
| *"I want it working now"* (after the deflection) | Acknowledges, doesn't repeat itself, offers a ticket. |
| *"Why don't you have Apple Music?"* | Says we don't have it yet, no committed date. No "we're working on a partnership." |
| *"My plaque shows old numbers"* | Explains the order-time snapshot. Offers ticket if order-time number looked wrong. |
| *"Do I need to pay to fix my credits?"* | "No, that's free." |
| *"I want a refund"* | refund-retention skill activates (regression check; this PR didn't touch it). |

### Out of scope for this PR's testing

- Whether Caroline's underlying factual claims about the analytics pipeline
  match reality. Aaron owns that; we deliberately removed all specific
  timing claims.
- Whether human agents stop using the banned phrases. Operations training
  problem.
- Refund-retention behaviour beyond "still triggers."

## Rollout

Markdown-only, no service restart. Standard PR → review → merge → next
`deploy.sh` run. Defensive validation added in
`project_main_gateway_outage_2026-05-05` will catch any malformed
markdown/YAML at deploy time before the gateway picks up the change.

## Copy guardrails for the implementer

While implementing, hold these lines:

- **Plaques:** phrase as "data available at order/snapshot time," not as
  future corrections. Don't imply we'll update plaques after the fact.
- **Credits / free users:** "free users can fix credits" is fine; do NOT
  imply free users get analytics support.
- **Analytics:** keep avoiding timing guarantees entirely. No "4PM EST," no
  "48–96 hours," no "Friday refresh." Not in the §7 text, not in the FAQ
  examples, not in any retry phrasing.

## Blockers (must resolve before merge)

1. **Plaque-locked-at-order-time accuracy.** The FAQ entry is encoded from
   support-ticket folklore. Verify with Jan (or whoever owns plaque
   fulfilment) that this matches actual plaque behaviour before merge. If
   wrong, the entry is dropped and a separate ticket goes to product.

2. **Apple Music phrasing.** Default wording is the conservative
   "Apple Music isn't available in Muso analytics today. It's a known
   request, but there's no committed date." If Aaron / product has approved
   public roadmap wording, swap to that. Otherwise the conservative line
   stands.

## Open questions

1. **SOUL.md char count.** SOUL.md is already 18,283 chars (over the 12,000
   truncation cliff). This PR's ≈120 chars don't materially change that.
   Open question is whether to defer the SOUL.md edits entirely until issue
   #165 is fixed, OR ship them now knowing they may or may not survive
   truncation on the same terms as the rest of the file. Default: ship now,
   because mechanical enforcement (lint + KB edits) does not depend on
   SOUL.md surviving injection.

## Follow-up tickets (filed alongside this PR, not in it)

| Ticket | Owner | Why |
|---|---|---|
| Engineering: leaked `cluster.local` password-reset URL in customer emails | engineering | Real bug surfaced in audit |
| Operations: human-agent script alignment (stop saying "sorry," "48–96 hours," etc.) | Jan / ops | Same retraining we're giving Caroline |
| Operations: silent-close behaviour audit (46/65 customer-initiated tickets closed without reply) | Jan / ops | Biggest service gap in audit |
| Ops: refund-retention rewrite (blocked on payment-link infra) | Nick / ops | Parked until payment links exist |
| Product: Apple Music partnership status — what's the actual roadmap? | Aaron / product | So Caroline's "no committed date" can become real when there is one |
| Metrics: re-run 248-convo Intercom audit 30 days post-ship | Nick | Closes the loop on whether the rewrite worked |
