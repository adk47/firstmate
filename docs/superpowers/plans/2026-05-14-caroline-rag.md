# Caroline RAG + analytics-escalation gap — Implementation Plan

> **STATUS: COMPLETE + POLICY-REVISED (2026-05-14). Read this before re-using the plan.**
>
> This plan was executed end-to-end on 2026-05-14 and shipped as PR #283 (Layer 1) + PR #286 (Layer 2). However, the **policy** that Layer 1 encodes was reversed mid-PR. The original Rule 2 ("concrete pushback always tickets, target 75–100% analytics-ticket rate") was REMOVED. Final shipped doctrine: **no `create_ticket` calls for analytics, no team-review promises, no SLA promises** — honest fallback ("message back in a couple weeks") instead. See the [design spec — Final policy (v2) section](../specs/2026-05-14-caroline-rag-design.md) for the source of truth.
>
> Tasks below referring to "Rule 2", "ticket-create rate ≥75%", or "analytics-followup ticket on pushback" describe the v1 doctrine. Their FILE CHANGES landed but the policy they encoded was reversed in a follow-up commit on the same PR. Do not re-execute these tasks as written — refer to the spec's v2 policy section.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal (v1, REVERSED):** Close the 25% missed-analytics-escalation tail by (a) adding two atomic-escalation rules to Caroline's analytics doctrine and (b) enabling openclaw's built-in `memorySearch` + `autoRecall` so reference docs are auto-injected on every customer message.

**Goal (v2, SHIPPED):** Stop Caroline from promising analytics follow-up that isn't happening. Caroline (a) acknowledges analytics complaints honestly via the migration narrative + no-ticket fallback; (b) gets memorySearch/memory_search tools for general doctrine discovery; (c) still atomically tickets non-analytics escalations via Rule 1.

**Architecture:** Two sequential PRs. **PR A** is a markdown-only change to `workspaces/support/reference/common-issues.md` row #7 — ships standalone, low-risk. **PR B** flips `memorySearch.enabled: true` for the support agent in `openclaw-edge.json` with OpenAI embeddings indexing the read-only `reference/` directory, adds `reference/active-incidents.md` as Aaron's editable narrative file, and pins safety invariants (`autoCapture: false`, `dreaming.enabled: false`, `dmScope: per-channel-peer`) into the existing `scripts/validate-shared-config.sh` CI gate.

**Tech Stack:** openclaw 2026.5.5 / qmd memory backend / OpenAI `text-embedding-3-small` / bash + jq for CI invariants / markdown for doctrine.

**Spec:** [docs/superpowers/specs/2026-05-14-caroline-rag-design.md](../specs/2026-05-14-caroline-rag-design.md)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `workspaces/support/reference/common-issues.md` | extend | Append **Rule 1** (say-it=do-it) and **Rule 2** (concrete pushback) to the bottom of row #7 (Analytics not showing / streams not updating). |
| `workspaces/support/reference/active-incidents.md` | **create** | Aaron-editable narrative file listing currently-active platform issues. Indexed by qmd for autoRecall retrieval. |
| `openclaw-edge.json` | modify | Replace the `support` agent's `memorySearch: { enabled: false }` block with the full RAG config (provider, qmd paths, store path). |
| `/etc/openclaw/shared.env` (server-only) | modify | Add `OPENAI_EMBEDDING_API_KEY` if not already provisioned. Documented in plan only — env file is not in the repo. |
| `scripts/validate-shared-config.sh` | extend | Add four new invariant checks: `autoCapture`, `qmd.paths`, `memory-core.dreaming.enabled`, `dmScope`. |
| `scripts/validate-caroline-rag.sh` | **create** | Standalone post-deploy verification: `openclaw memory status` + `openclaw memory search` smoke-test. Called manually after PR B deploy, also wired into deploy.sh's post-flight section. |
| `scripts/deploy.sh` | extend | Append a post-deploy step that runs `validate-caroline-rag.sh` against the edge profile and Slacks the result. |

---

# PR A — Layer 1: analytics-escalation rules (markdown only)

## Task 1: Append Rules 1 and 2 to `common-issues.md` row #7

**Files:**
- Modify: `workspaces/support/reference/common-issues.md` (after line 161, before the `---` and section 8)

- [ ] **Step 1: Read current state of row #7 to locate insertion point.**

The existing row #7 ends with the "Forbidden phrasing" list at lines 156–161. The new rules append below that list, **before** the horizontal rule `---` that begins section 8.

Run: `sed -n "108,162p" workspaces/support/reference/common-issues.md`
Expected: shows the "Analytics not showing / streams not updating" section ending with "Once subscribed, please be patient as it takes time to populate."

- [ ] **Step 2: Append the two new rules.**

After line 161 (`- "Once subscribed, please be patient as it takes time to populate."`) and before the `---` that opens section 8, insert:

```markdown

**Rule 1 — Escalation language and the tool call are atomic.**

If your reply contains any of the following phrases (or close variants), you MUST call `create_ticket` in the same turn — not the next turn, the same turn:

- "I'll flag this"
- "I'll escalate this"
- "I'll send this to the team"
- "I'll get this in front of engineering"
- "I'll route this for review"
- "I've sent this to a person"
- "I've flagged your profile"

If the tool call did not succeed, do not say you escalated. Either retry the tool call or tell the customer the system could not file the ticket right now and ask them to try again in a few minutes. Never imply an escalation happened when it did not.

**Rule 2 — Concrete pushback always tickets.**

The following customer signals each independently mandate a `create_ticket` call with `actionType: analytics-followup`, regardless of whether you have asked any follow-up questions yet:

- Customer repeats the analytics complaint after the upgrade-in-progress narrative.
- Customer cites a specific stuck number ("259,759,141", "stuck at 90k").
- Customer cites a duration ("weeks", "months", "since April").
- Customer explicitly asks for a human ("can I speak to a person", "is there a real person").
- Customer expresses clear frustration after a non-resolving reply ("can yall fix this", "this is unacceptable", "I've contacted support multiple times").

These signals override the troubleshooting decision tree. After any of them fires, do **not** ask for a screenshot, "log out and back in", or a billing-seat re-check before ticketing.
```

- [ ] **Step 3: Verify the file still parses cleanly and the section count is unchanged.**

Run: `grep -c "^## [0-9]" workspaces/support/reference/common-issues.md`
Expected: same count as before the edit (run before + after, numbers must match — likely 10).

Run: `awk '/^## 7\./,/^## 8\./' workspaces/support/reference/common-issues.md | grep -cE "^\*\*Rule [12]"`
Expected: `2`

- [ ] **Step 4: Commit.**

```bash
git add workspaces/support/reference/common-issues.md
git commit -m "$(cat <<'EOF'
fix(support): close analytics-escalation say-it-do-it gap

Append Rule 1 (escalation language and tool call are atomic) and Rule 2
(concrete pushback signals always ticket) to common-issues.md row #7.

Plugs the 25% miss observed in 48 post-PR-270 analytics sessions where
Caroline produced escalation language without a same-turn create_ticket
call.

See docs/superpowers/specs/2026-05-14-caroline-rag-design.md
EOF
)"
```

## Task 2: Open PR A and verify Caroline picks up the new doctrine

**Files:**
- No file changes — verification only.

- [ ] **Step 1: Push branch and open PR.**

```bash
git push -u origin chore/caroline-analytics-review
gh pr create --title "fix(support): close analytics-escalation say-it-do-it gap (Layer 1)" --body "$(cat <<'EOF'
## Summary

Adds Rule 1 (say-it=do-it) and Rule 2 (concrete pushback) to Caroline's analytics doctrine (common-issues.md row #7).

Plugs the 25% missed-escalation tail observed in 48 post-PR-270 analytics sessions where Caroline said "I'll flag" / "I'll send to the team" but never called create_ticket.

This is Layer 1 of a two-layer fix. Layer 2 (RAG enablement) follows as a separate PR per docs/superpowers/specs/2026-05-14-caroline-rag-design.md.

## Test plan

- [ ] Merge + redeploy edge
- [ ] After 24h of live traffic, re-run the analytics-session audit (see spec) and confirm ticket-creation rate on pushback approaches 100%
EOF
)"
```

- [ ] **Step 2: After PR merges and deploys, wait 24h then re-run the audit.**

Run on `40.160.32.80`:
```bash
cd /root/.openclaw-edge/agents/support/sessions/
cutoff=$(date -d "24 hours ago" +%s)
total=0; ticketed=0; pushback_missed=0
for f in $(find . -name "*.jsonl*" -not -name "*.trajectory*" -newermt "@$cutoff"); do
  mt=$(stat -c %Y "$f")
  [ "$mt" -lt "$cutoff" ] && continue
  # Heuristic: contains analytics signal
  has_signal=$(jq -r 'select(.type=="message" and .message.role=="user") | .message.content // [] | .[] | select(.type=="text") | .text' "$f" 2>/dev/null | grep -ciE "analytics|streams.*(stuck|frozen|not updat)|stream.{0,10}count")
  [ "$has_signal" -eq 0 ] && continue
  total=$((total+1))
  has_ticket=$(jq -r 'select(.type=="message" and .message.role=="assistant") | .message.content // [] | .[] | select(.type=="toolCall") | .name' "$f" 2>/dev/null | grep -c create_ticket)
  if [ $has_ticket -gt 0 ]; then ticketed=$((ticketed+1)); fi
done
echo "Total: $total | Ticketed: $ticketed"
```
Expected: ticketed/total ratio above 75% (was 54% before the fix). Below that, the doctrine is not being followed → file follow-up issue, do NOT abandon Layer 2.

---

# PR B — Layer 2: RAG enablement

## Task 3: Verify embedding API key wiring

**Files:**
- No file changes — investigation only. Output: a decision to either reuse `OPENAI_API_KEY` or provision a new `OPENAI_EMBEDDING_API_KEY`.

- [ ] **Step 1: Check what's already in shared.env.**

Run on `40.160.32.80`:
```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 'grep -E "OPENAI|EMBEDDING" /etc/openclaw/shared.env /etc/openclaw/edge.env 2>/dev/null | sed "s/=.*/=<redacted>/"'
```
Expected output cases:
- `OPENAI_API_KEY=<redacted>` already present → reuse it (cheapest path). Set `apiKey.id: "OPENAI_API_KEY"` in the memorySearch config.
- Nothing related to OpenAI → provision a new key. Use the org's OpenAI billing account, create a key restricted to embedding endpoints only, name it `OPENAI_EMBEDDING_API_KEY`, add to `shared.env` via the team's secret-management process (NOT in this PR — out-of-band).
- Some other shape (e.g. `OPENROUTER_API_KEY`): openrouter does not proxy OpenAI embeddings cleanly; provision a separate key.

- [ ] **Step 2: Document the decision in the PR description.**

Add a `## Key wiring` section to PR B description noting which env var is referenced by the config. Block PR B merge until the env var exists on edge profile.

## Task 4: Verify `memorySearch` config schema on a test profile

**Files:**
- No persistent file changes — validation only.

- [ ] **Step 1: Take a backup of the test profile's openclaw.json.**

Run on `40.160.32.80`:
```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 '
cp /root/.openclaw-test/openclaw.json /root/.openclaw-test/openclaw.json.bak-pre-rag-$(date +%Y%m%dT%H%M%SZ)
ls -la /root/.openclaw-test/openclaw.json.bak-pre-rag-*
'
```
Expected: backup file exists with current timestamp.

- [ ] **Step 2: Apply the proposed memorySearch block to the test profile and validate.**

Edit `/root/.openclaw-test/openclaw.json` to replace the `support` agent's `memorySearch` block with:

```json
"memorySearch": {
  "enabled": true,
  "autoRecall": true,
  "autoCapture": false,
  "remote": {
    "provider": "openai",
    "model": "text-embedding-3-small",
    "apiKey": { "source": "env", "id": "OPENAI_API_KEY" }
  },
  "qmd": {
    "paths": ["reference"],
    "scope": "workspace",
    "update": { "onBoot": true, "interval": "5m" }
  },
  "store": {
    "path": "/root/.openclaw-test/memory/{agentId}.sqlite"
  }
}
```

Run: `ssh -i ~/.ssh/nick_ovh root@40.160.32.80 'openclaw doctor --profile test 2>&1 | tail -40'`
Expected: no warnings or errors related to `memorySearch` key names. If you see "unknown key", "deprecated field", or any memorySearch-related warning → the schema has drifted from the research-agent assumption. Stop, dig into `/root/.openclaw-test/plugin-runtime-deps/openclaw-*/dist/memory-search-*.js` for the actual schema, and update this plan with the correct keys before continuing.

- [ ] **Step 3: Restore the test profile config to baseline.**

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 '
cp /root/.openclaw-test/openclaw.json.bak-pre-rag-* /root/.openclaw-test/openclaw.json
openclaw doctor --profile test 2>&1 | tail -5
'
```
Expected: doctor clean, no remaining warnings.

## Task 5: Create `reference/active-incidents.md`

**Files:**
- Create: `workspaces/support/reference/active-incidents.md`

- [ ] **Step 1: Write the file.**

```markdown
# Active Incidents

Current platform issues that affect customer-facing answers. When an incident ends, delete its block. When a new incident starts, append a new block.

This file is indexed by Caroline's RAG (qmd / autoRecall). Editing it propagates to her context within 5 minutes. For urgent changes, hot-patch the live copy at `/opt/hydra/workspaces/support/reference/active-incidents.md` and PR the repo as catch-up (see memory: feedback_hot_patch_pattern).

---

## Analytics platform migration (active since 2026-04)

**Trigger keywords:** analytics, streams, stream count, data not updating, data frozen, stuck in [month], numbers not moving.

**Narrative:** "We're in the middle of an analytics platform migration and server move, so refresh has been lagging across many accounts right now. Your data is being tracked normally in the background." Do NOT call this a refresh delay, a sync issue, or a bug. Do NOT quote specific timing.

**Resolution path:** follow `common-issues.md` row #7. Call `profile_status` first. If customer accepts the narrative, close out — no ticket. If customer pushes back (Rule 2 in common-issues.md row #7), call `create_ticket` with `actionType: analytics-followup` in the same turn as the escalation language (Rule 1).

**Owner:** Aaron / engineering.
```

- [ ] **Step 2: Verify the file is in the workspace tree.**

Run: `ls workspaces/support/reference/active-incidents.md && wc -l workspaces/support/reference/active-incidents.md`
Expected: file exists, ~20 lines.

- [ ] **Step 3: Commit.**

```bash
git add workspaces/support/reference/active-incidents.md
git commit -m "$(cat <<'EOF'
feat(support): add active-incidents.md as transient-narrative source

Aaron-editable file for currently-active platform issues. Indexed by qmd
in PR B; auto-injected to Caroline's context via memorySearch.autoRecall
when a customer mentions a matching trigger keyword.

Initial entry captures the analytics platform migration narrative.

See docs/superpowers/specs/2026-05-14-caroline-rag-design.md
EOF
)"
```

## Task 6: Update `openclaw-edge.json` to enable memorySearch on the support agent

**Files:**
- Modify: `openclaw-edge.json` lines 92–94 (currently `"memorySearch": { "enabled": false }`).

- [ ] **Step 1: Show the current block for context.**

Run: `sed -n "90,96p" openclaw-edge.json`
Expected:
```json
      "workspace": "/opt/hydra/workspaces/support",
      "memorySearch": {
        "enabled": false
      },
      "bootstrapMaxChars": 40000,
```

- [ ] **Step 2: Replace the memorySearch block.**

Replace lines 92–94 with (use the apiKey ID determined in Task 3):

```json
      "memorySearch": {
        "enabled": true,
        "autoRecall": true,
        "autoCapture": false,
        "remote": {
          "provider": "openai",
          "model": "text-embedding-3-small",
          "apiKey": { "source": "env", "id": "OPENAI_API_KEY" }
        },
        "qmd": {
          "paths": ["reference"],
          "scope": "workspace",
          "update": { "onBoot": true, "interval": "5m" }
        },
        "store": {
          "path": "/root/.openclaw-edge/memory/{agentId}.sqlite"
        }
      },
```

- [ ] **Step 3: Validate the file parses.**

Run: `jq . openclaw-edge.json > /dev/null && echo "valid"`
Expected: `valid`. Any jq error → JSON is broken, fix before continuing.

- [ ] **Step 4: Confirm no other agent has memorySearch enabled.**

Run: `jq '.agents.list[] | {id, ms: (.memorySearch.enabled // false)}' openclaw-edge.json`
Expected: only `support` has `ms: true`. All others `false` or absent. If any other agent shows `ms: true`, halt — multi-agent RAG was not part of this design.

## Task 7: Verify memory tools surface on test profile (issue #76603 regression check)

**Files:**
- No persistent file changes — validation only.

- [ ] **Step 1: Apply the new config to the test profile and start it.**

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 '
cp /root/.openclaw-test/openclaw.json /root/.openclaw-test/openclaw.json.bak-pre-tooltest-$(date +%Y%m%dT%H%M%SZ)
# Copy the memorySearch block from the proposed openclaw-edge.json into openclaw-test
# (manual edit — paste the block from Task 6 Step 2)
openclaw doctor --profile test 2>&1 | tail -10
'
```

- [ ] **Step 2: List the tools available to the support agent on the test profile.**

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 'openclaw agent tools list --agent support --profile test 2>&1 | grep -E "memory_search|memory_get"'
```
Expected: both `memory_search` and `memory_get` appear. If neither appears → upstream issue #76603 has hit our runtime version. Stop, file an issue, and pin the runtime to a known-good version before proceeding.

- [ ] **Step 3: Restore the test profile and clean up.**

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 '
cp /root/.openclaw-test/openclaw.json.bak-pre-tooltest-* /root/.openclaw-test/openclaw.json
'
```

## Task 8: Extend `validate-shared-config.sh` with memory-safety invariants

**Files:**
- Modify: `scripts/validate-shared-config.sh`

- [ ] **Step 1: Read existing checks to match style.**

Run: `wc -l scripts/validate-shared-config.sh && head -50 scripts/validate-shared-config.sh`
Note the `fail` / `pass` / `extract` helper functions and the use of python3 for JSON path traversal.

- [ ] **Step 2: Append four new invariant checks at the bottom of the script, before any final `exit $FAILURES` line.**

Identify where the existing checks end (look for the last `if extract … fail …; fi` block) and add a new section labeled `# --- Caroline memory safety invariants (added 2026-05-14) ---`:

```bash
# --- Caroline memory safety invariants (added 2026-05-14) ---
# See docs/superpowers/specs/2026-05-14-caroline-rag-design.md

invariant_check() {
  local file="$1" path="$2" expected="$3" label="$4"
  local actual
  actual=$(python3 -c "
import json, sys
with open('$file') as f:
    c = json.load(f)
v = c
for k in '$path'.split('.'):
    if isinstance(v, list):
        # support agent lookup by id
        v = next((a for a in v if isinstance(a, dict) and a.get('id') == k), None)
    elif isinstance(v, dict):
        v = v.get(k)
    if v is None:
        break
print(json.dumps(v) if v is not None else 'null')
")
  if [ "$actual" = "$expected" ]; then
    pass "$label = $expected"
  else
    fail "$label expected $expected, got $actual"
  fi
}

# 1. Caroline must never have autoCapture enabled (would persist customer
#    transcripts into shared recall store, leaking customer A → customer B).
invariant_check "$EDGE" "agents.list.support.memorySearch.autoCapture" "false" \
  "edge.support.memorySearch.autoCapture"

# 2. Caroline's qmd corpus must be limited to the reference/ subdirectory.
#    Anything else risks indexing customer-session transcripts or auth
#    material.
invariant_check "$EDGE" "agents.list.support.memorySearch.qmd.paths" '["reference"]' \
  "edge.support.memorySearch.qmd.paths"

# 3. Dreaming must remain disabled (upstream issues #63921, #65374, #65550,
#    #66947 — see spec for full reasoning).
invariant_check "$EDGE" "plugins.entries.memory-core.config.dreaming.enabled" "false" \
  "edge.plugins.memory-core.dreaming.enabled"
# also accept missing/null as equivalent to false
if ! python3 -c "
import json
with open('$EDGE') as f:
    c = json.load(f)
try:
    v = c['plugins']['entries']['memory-core']['config']['dreaming']['enabled']
    exit(0 if v is False else 1)
except KeyError:
    exit(0)  # missing == disabled
" 2>/dev/null; then
  fail "edge memory-core.dreaming.enabled must be false or absent"
fi

# 4. Session scope must remain per-channel-peer so each Intercom conversation
#    is isolated.
invariant_check "$EDGE" "profiles.edge.session.dmScope" '"per-channel-peer"' \
  "edge.profiles.edge.session.dmScope"
```

- [ ] **Step 3: Run the validation against current (post-Task-6) repo state.**

Run: `bash scripts/validate-shared-config.sh`
Expected: all four new invariants PASS. If any FAIL, the config from Task 6 has a typo — fix before continuing.

- [ ] **Step 4: Run it against a deliberately-broken config to prove it fails loud.**

```bash
cp openclaw-edge.json /tmp/openclaw-edge.json.good
jq '.agents.list[] |= (if .id == "support" then .memorySearch.autoCapture = true else . end)' openclaw-edge.json > /tmp/openclaw-edge.json.bad
cp /tmp/openclaw-edge.json.bad openclaw-edge.json
bash scripts/validate-shared-config.sh; rc=$?
cp /tmp/openclaw-edge.json.good openclaw-edge.json
echo "rc=$rc"
```
Expected: `rc=1` (or non-zero), with a `DRIFT: edge.support.memorySearch.autoCapture expected false, got true` line in the output. If `rc=0`, the invariant is not actually enforcing — fix the script before continuing.

- [ ] **Step 5: Commit Tasks 6 + 8 together.**

```bash
git add openclaw-edge.json scripts/validate-shared-config.sh
git commit -m "$(cat <<'EOF'
feat(support): enable RAG for Caroline + lock memory-safety invariants

Flips support agent to memorySearch.enabled=true with OpenAI embeddings
indexing the read-only reference/ subdirectory. autoRecall on,
autoCapture off, dreaming off, dmScope per-channel-peer — all four
pinned via validate-shared-config.sh as CI-blocking invariants.

See docs/superpowers/specs/2026-05-14-caroline-rag-design.md
EOF
)"
```

## Task 9: Write `validate-caroline-rag.sh` post-deploy smoke test

**Files:**
- Create: `scripts/validate-caroline-rag.sh`

- [ ] **Step 1: Write the script.**

```bash
#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# validate-caroline-rag.sh
#
# Post-deploy smoke test for Caroline's RAG setup. Confirms:
#   1. memory search is enabled on the support agent
#   2. the qmd index has been built (non-empty)
#   3. retrieval returns a hit for the analytics doctrine
#   4. memory_search and memory_get tools are on Caroline's tool surface
#
# Run as part of deploy.sh post-flight, or manually after a config change.
# Exit: 0 clean, 1 invariant violated, 2 dependency error
# ──────────────────────────────────────────────────────────────
set -euo pipefail

PROFILE="${PROFILE:-edge}"
AGENT="${AGENT:-support}"
FAILURES=0
fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
pass() { echo "OK: $*"; }

# 1. memorySearch enabled?
status_json=$(openclaw memory status --agent "$AGENT" --profile "$PROFILE" --json 2>/dev/null || true)
if echo "$status_json" | grep -q '"enabled": *true'; then
  pass "memory search enabled on $AGENT/$PROFILE"
else
  fail "memory search not enabled on $AGENT/$PROFILE"
fi

# 2. Index non-empty?
chunk_count=$(echo "$status_json" | python3 -c "import sys, json; s = sys.stdin.read(); 
try:
  d = json.loads(s); print(d.get('chunks', d.get('totalChunks', 0)))
except: print(0)
")
if [ "${chunk_count:-0}" -gt 0 ]; then
  pass "qmd index has $chunk_count chunks"
else
  fail "qmd index is empty — reference/*.md may not be indexed"
fi

# 3. Retrieval smoke-test: known query should hit common-issues.md
search_out=$(openclaw memory search "analytics streams stuck" --agent "$AGENT" --profile "$PROFILE" --max-results 3 2>/dev/null || true)
if echo "$search_out" | grep -qi "analytics" && echo "$search_out" | grep -q "common-issues.md"; then
  pass "retrieval returns analytics doctrine for analytics query"
else
  fail "retrieval did NOT return analytics doctrine — index may be stale or query embedding failed"
fi

# 4. memory_search / memory_get tools visible (issue #76603 regression)
tools=$(openclaw agent tools list --agent "$AGENT" --profile "$PROFILE" 2>/dev/null || true)
if echo "$tools" | grep -q memory_search && echo "$tools" | grep -q memory_get; then
  pass "memory_search and memory_get tools on $AGENT tool surface"
else
  fail "memory_search and/or memory_get missing from tool surface (upstream issue #76603?)"
fi

exit $FAILURES
```

- [ ] **Step 2: Make executable and verify it runs locally (will FAIL until live deploy — that's expected at this stage).**

```bash
chmod +x scripts/validate-caroline-rag.sh
ls -la scripts/validate-caroline-rag.sh
```
Expected: `-rwxr-xr-x ... scripts/validate-caroline-rag.sh`

- [ ] **Step 3: Commit.**

```bash
git add scripts/validate-caroline-rag.sh
git commit -m "$(cat <<'EOF'
chore(scripts): add validate-caroline-rag.sh post-deploy smoke test

Confirms memorySearch is enabled, qmd index is built, analytics
retrieval returns the expected doctrine, and memory_search/get tools
surface on the agent (regression check for upstream #76603).

Wired into deploy.sh in a follow-up step.

See docs/superpowers/specs/2026-05-14-caroline-rag-design.md
EOF
)"
```

## Task 10: Wire `validate-caroline-rag.sh` into `deploy.sh`

**Files:**
- Modify: `scripts/deploy.sh` (post-flight section)

- [ ] **Step 1: Locate the post-flight section of deploy.sh.**

Run: `grep -n "post.flight\|post_flight\|after.deploy\|smoke" scripts/deploy.sh | head -10`
Note the existing post-flight conventions (e.g. how `validate-shared-config.sh` is called, how Slack notifications are sent).

- [ ] **Step 2: Add a post-flight call after the existing config validation.**

After the last existing post-flight check and before the success exit, add:

```bash
# Caroline RAG smoke test (post-flight)
if [ -x "$HYDRA_ROOT/scripts/validate-caroline-rag.sh" ]; then
  echo "Running Caroline RAG smoke test..."
  if PROFILE=edge AGENT=support "$HYDRA_ROOT/scripts/validate-caroline-rag.sh"; then
    echo "Caroline RAG smoke test passed."
  else
    rag_rc=$?
    echo "Caroline RAG smoke test FAILED with rc=$rag_rc"
    # Non-fatal: don't roll back the whole deploy on RAG failure
    # because the rest of Caroline still works. But surface to Slack.
    if [ -n "${HYDRA_SLACK_WEBHOOK:-}" ]; then
      curl -s -X POST -H 'Content-type: application/json' \
        --data "{\"text\":\":warning: Caroline RAG post-deploy check failed (rc=$rag_rc). Investigate: \`/var/log/hydra-deploy.log\`\"}" \
        "$HYDRA_SLACK_WEBHOOK" >/dev/null || true
    fi
  fi
fi
```

- [ ] **Step 3: Verify deploy.sh syntax.**

Run: `bash -n scripts/deploy.sh && echo "syntax ok"`
Expected: `syntax ok`. Any syntax error → fix before commit (per memory `feedback_apostrophe_in_jq_heredoc`).

- [ ] **Step 4: Commit.**

```bash
git add scripts/deploy.sh
git commit -m "$(cat <<'EOF'
chore(deploy): run validate-caroline-rag.sh post-flight

Surfaces RAG misconfiguration (empty index, missing tools, retrieval
miss) to Slack within minutes of deploy rather than waiting for a
customer-facing miss. Non-fatal — won't roll back the deploy.

See docs/superpowers/specs/2026-05-14-caroline-rag-design.md
EOF
)"
```

## Task 11: Open PR B

**Files:**
- No file changes — PR creation only.

- [ ] **Step 1: Push branch and open PR.**

```bash
git push -u origin chore/caroline-analytics-review
gh pr create --title "feat(support): enable RAG for Caroline + lock memory-safety invariants (Layer 2)" --body "$(cat <<'EOF'
## Summary

- Enables openclaw `memorySearch` + `autoRecall` for the `support` agent (Caroline) with OpenAI `text-embedding-3-small` indexing the read-only `workspaces/support/reference/` directory
- Adds `workspaces/support/reference/active-incidents.md` as the Aaron-editable source for transient platform narratives
- Pins memory-safety invariants (`autoCapture: false`, `dreaming.enabled: false/absent`, `dmScope: per-channel-peer`, `qmd.paths: ["reference"]`) in `scripts/validate-shared-config.sh` — CI gate
- Adds `scripts/validate-caroline-rag.sh` post-deploy smoke test, wired into `deploy.sh`

See `docs/superpowers/specs/2026-05-14-caroline-rag-design.md` for design rationale, including why Dreaming + autoCapture are explicitly disabled (four open upstream bugs, GDPR concerns, no customer-facing postmortems exist).

## Pre-flight done

- [x] Task 3: confirmed `OPENAI_API_KEY` is in `shared.env` (no new env var needed)
- [x] Task 4: validated config schema against `openclaw doctor` on `test` profile — clean
- [x] Task 7: confirmed `memory_search` and `memory_get` tools surface on test profile (not affected by upstream #76603 regression)
- [x] Task 8: validated `validate-shared-config.sh` PASSes on this PR and FAILs loud on deliberately-broken config

## Test plan

- [ ] Merge to main → deploy to edge
- [ ] Deploy's post-flight runs `validate-caroline-rag.sh` (Task 10) and posts to Slack
- [ ] Manually verify: `ssh hydra 'openclaw memory search "analytics streams stuck" --agent support --profile edge'` returns chunks from `common-issues.md` and `active-incidents.md`
- [ ] After 24h of live traffic, re-run the analytics-session audit. Ticket-creation rate on pushback should remain ≥75% (Layer 1 baseline). Look for additional improvements on first-touch quality (Caroline citing migration narrative consistently)

## Rollout / rollback

- Rollback: revert this PR + redeploy. Caroline returns to pre-RAG behavior. No data loss; the qmd SQLite store is regeneratable from `reference/` and can be deleted.
EOF
)"
```

## Task 12: Post-deploy verification (live)

**Files:**
- No file changes — operational verification.

- [ ] **Step 1: After PR B merges and deploys, watch the post-flight Slack message.**

Expected: ":white_check_mark: Caroline RAG post-deploy check passed" (or however deploy.sh formats success). If you see the warning posted from Task 10 Step 2, drop down to Step 2.

- [ ] **Step 2: Run the smoke test manually if Slack is unclear.**

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 'PROFILE=edge AGENT=support /opt/hydra/scripts/validate-caroline-rag.sh'
```
Expected: 4 `OK:` lines, exit 0.

- [ ] **Step 3: Spot-check retrieval with the analytics query.**

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 'openclaw memory search "analytics streams stuck" --agent support --profile edge --max-results 5'
```
Expected: top result includes content from `common-issues.md` row #7 or `active-incidents.md`. If the top result is unrelated (e.g. a faq.md chunk about pricing), retrieval quality is off — file a follow-up to tune chunk size or switch embedding model to `voyage-3`.

- [ ] **Step 4: Tail one new analytics session and confirm autoRecall fires.**

Wait for the next analytics conversation to start on Intercom, then:
```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80 '
latest=$(ls -t /root/.openclaw-edge/agents/support/sessions/*.jsonl | head -1)
echo "=== Session: $latest ==="
jq -r "select(.type==\"custom_message\") | .content // .text // \"\" | tostring | .[0:200]" "$latest" | head -20
'
```
Expected: see `[memory recall]` or similar marker in the custom_message stream showing retrieved chunks injected. If no recall marker appears on an analytics-keyword conversation, autoRecall is not firing — re-run smoke test and dig into `openclaw memory status --deep`.

## Task 13: Update memory with the new invariant

**Files:**
- Create: `~/.claude/projects/-Users-nick-Dev--CLIENTS-muso-Muso-AI-hydra/memory/project_caroline_rag_invariants.md`
- Modify: `~/.claude/projects/-Users-nick-Dev--CLIENTS-muso-Muso-AI-hydra/memory/MEMORY.md`

- [ ] **Step 1: Create the project-memory entry.**

```markdown
---
name: project_caroline_rag_invariants
description: Caroline RAG is on (memorySearch+autoRecall) but autoCapture/Dreaming are pinned OFF by CI gate. Reversing those flips bypasses customer-isolation guardrail.
metadata:
  type: project
---

PR B (2026-05-1?) enabled `memorySearch.enabled: true` + `autoRecall: true`
for the `support` agent (Caroline) on edge profile, indexing the read-only
`workspaces/support/reference/` directory via OpenAI text-embedding-3-small.

**Pinned invariants (in `scripts/validate-shared-config.sh`, CI-blocking):**
- `support.memorySearch.autoCapture: false`
- `support.memorySearch.qmd.paths: ["reference"]`
- `plugins.entries.memory-core.config.dreaming.enabled: false` (or absent)
- `profiles.edge.session.dmScope: "per-channel-peer"`

**Why:** customer-facing agent (Caroline talks to many strangers).
autoCapture would persist customer A's transcript into recall context
for customer B's session → privacy leak. Dreaming has 4 open upstream
bugs unfit for customer-facing PII (#63921, #65374, #65550, #66947) —
see spec.

**How to apply:** Before approving any PR that touches openclaw-edge.json
support agent config or memory-core config, run validate-shared-config.sh
locally. If the invariants need to change for a legitimate reason, update
this memory entry + the spec rationale together.

Spec: `docs/superpowers/specs/2026-05-14-caroline-rag-design.md`
Plan: `docs/superpowers/plans/2026-05-14-caroline-rag.md`
```

- [ ] **Step 2: Append to MEMORY.md index.**

Add a line at the end of `MEMORY.md`:

```markdown
- [project_caroline_rag_invariants.md](project_caroline_rag_invariants.md) - Caroline RAG on, autoCapture/Dreaming pinned OFF by CI gate (customer-isolation)
```

- [ ] **Step 3: Done. No commit (memory is per-user, not in repo).**

---

## Self-Review

**Spec coverage:** every section of the spec maps to one or more tasks:

- Spec §1 (memorySearch config) → Task 6
- Spec §2 (active-incidents.md) → Task 5
- Spec §3 (Rules 1+2 in common-issues.md) → Task 1
- Spec §4 (CI invariant test) → Task 8
- Spec §5 (initial index + verification) → Task 12 (live verification post-deploy)
- Spec §6 (memory tool surface regression check) → Task 7
- Spec §7 (ClickUp custom-field follow-up) → out-of-scope per spec, not in this plan
- Spec "Why no Dreaming" → enforced via Task 8 invariants + Task 13 memory

**Placeholder scan:** done. No "TBD"/"TODO"/"appropriate error handling" patterns. The one judgment call in Task 12 Step 3 ("file a follow-up to tune chunk size or switch embedding model") is concrete (specific named alternative, `voyage-3`), not a vague TODO.

**Type consistency:** the JSON path used in `validate-shared-config.sh` (Task 8) matches the actual nested key path in `openclaw-edge.json` (Task 6). The agent ID `support` is used consistently. Tool names `memory_search` / `memory_get` match the runtime symbols verified earlier in the session.

**Open uncertainty (flagged in the spec):**
- Task 3 may discover OpenAI key needs to be provisioned out-of-band (separate process). Plan handles this by blocking PR B merge until Task 3 confirms the env var exists.
- Task 7 may discover #76603 hits us. Plan handles by halting + version-pinning before proceeding.
- The exact `memorySearch` schema key names (Task 6) are derived from runtime symbols + research-agent reports; Task 4 explicitly validates against `openclaw doctor` on a non-production profile before flipping live.

These are designed-in gates, not unresolved unknowns.
