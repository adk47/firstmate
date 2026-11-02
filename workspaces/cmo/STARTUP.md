# CMO Startup / Wire Up Checklist

**Purpose**: When CMO is first booted on a new HYDRA server (or after a major
config reset), this document walks the agent through a full wire up process.
The agent reads this, asks Nick each question in order, verifies every piece,
and only marks the system as "ready" once every item is green.

**Delete this file** when the checklist is complete and the system is live.

---

## How to Use

1. Read this file top to bottom.
2. For each checklist item, run the verification command or ask Nick the question.
3. Post results to Nick in `#marketing` as you go.
4. Do NOT skip items. Do NOT assume. Do NOT silently fail.
5. If a check fails, stop and ask Nick how to fix it. Never move on with broken wiring.
6. When every item is green, notify Nick in `#marketing`:
   "CMO wire up complete. All systems green. Ready for production work."
7. After Nick confirms, delete this file.

---

## Phase 1, Identity

- [ ] Confirm agent identity: CMO, Muso.AI
- [ ] Read `SOUL.md` and summarize identity to Nick in one paragraph
- [ ] Read `USER.md` and list all 4 authorized users with IDs
- [ ] Confirm owner: Nick (U0AL36NADEY)
- [ ] Confirm CEO: Aaron Kaufman (U7RP6HKUZ, a@muso.ai)
- [ ] Confirm who the current CTO is (Serhii, U03TYGJF1N3, left 2026-08-26 — seat may be vacant)
- [ ] Confirm Head of Ops: Jan Delmo (U038BM16T7W)

## Phase 2, Environment Variables

Credentials come from the **gateway environment** – loaded as a systemd
`EnvironmentFile` by your gateway unit (`/etc/openclaw/main.env` for
`openclaw-gateway-main`, `/etc/openclaw/edge.env` for `openclaw-gateway-edge`)
and inherited by every codex child of that unit (a shell you started yourself
over SSH is not one: it sources your profile instead). They are **NOT** in `~/.zshrc`: the gateway
runs as a daemon and does not source an interactive shell, so sourcing your
shell profile does nothing for you. If a variable is unset or the API returns
401/403, tell DevOps which variable and which unit, and do not wait for a
reply. Carry on with the work that does not need it, and stop only the
actions that do. A check you could not run never counts as passed.
`openclaw__secrets request` is not a shortcut around that: a requested value
goes straight to the team store and is never given to your shell or your
chat, so it cannot satisfy a `$VAR` your command reads. Never request a name
that is, or should be, in the gateway env; DevOps sets those in the unit env
file.

Verify each env var is set in the gateway environment.

```bash
echo "klaviyo: ${MUSOAI_KLAVIYO_TOKEN:+set}"
echo "amplitude token: ${MUSOAI_AMPLITUDE_TOKEN:+set}"
echo "amplitude secret: ${MUSOAI_AMPLITUDE_SECRET_KEY:+set}"
echo "profitwell: ${MUSOAI_PROFITWELL_TOKEN:+set}"
echo "rewardful: ${REWARDFUL_API_SECRET:+set}"
echo "stripe: ${MUSOAI_STRIPE_API_KEY:+set}"
echo "clickup: ${CLICKUP_API_KEY:+set}"
echo "ghl (b2b ads): ${GHL_API_KEY:+set}"
echo "ghl (winback): ${GHL_WINBACK_API_KEY:+set}"
echo "n8n api: ${N8N_API_KEY:+set}"
echo "n8n mcp: ${N8N_MCP_KEY:+set}"
echo "n8n base url: ${N8N_BASE_URL:+set}"
echo "docusign integration: ${DOCUSIGN_INTEGRATION_KEY:+set}"
echo "docusign user: ${DOCUSIGN_USER_ID:+set}"
echo "docusign account: ${DOCUSIGN_ACCOUNT_ID:+set}"
```

- [ ] All tokens show "set"
- [ ] If any are missing, ask Nick for the value and have him add them
- [ ] Report which ones are missing, do NOT guess or fabricate

## Phase 3, Gmail (4 accounts via gog CLI)

- [ ] `gog auth list` shows all 4 accounts:
    - a@muso.ai
    - f@muso.ai (McLaren Amberti, Sales Operations)
    - ak@muso.ai
    - aaron.k@muso.ai
- [ ] For each account, run `gog gmail messages search "in:inbox" --account <email> --max 1` and confirm a result comes back
- [ ] If any account is missing, ask Nick to run `gog auth login <email>` manually
- [ ] Confirm Gmail label `B2B - Ads` exists in a@muso.ai (the primary)
- [ ] Confirm Gmail label `Win-Back` exists in a@muso.ai (for the separate win back engine)

## Phase 4, Google Sheets Access

Test read access to each critical sheet:

### Outreach Engine Data Stores

- [ ] Contact + Company Intelligence — NocoDB (CANONICAL; see `skills/muso-outreach-engine/references/config.md`)
    - `bash scripts/nocodb-api.sh records.count m9vsbijhrr9ddeu` (Contacts Intelligence reachable)
    - `bash scripts/nocodb-api.sh records.count mvr6nmzcv7albxt` (Company Intelligence reachable)
- [ ] Master Leads Sheet (`1OWzfmxtgX-xq-aGxgmsjAdzQoyKbb94hnU_j-jm5q6I`) — templates + KB only
- [ ] Outreach Log Sheet (`1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0`)
    - `gog sheets get 1o1aUpAhQ8tNuZtzWqUm9bOUFvyPaGrCHbImbB4mtmW0 --range "muso-b2b-outreach-reports!A1:M1" --account a@muso.ai`
    - Confirm columns match: `# | Date | Muso Email | Domain | Contact | Company | Title | Email | Action | Status | Email Subject | Template | Hook / Notes`
- [ ] Test WRITE access: append a test row to the logbook, then delete it

### Win Back Engine Sheets

- [ ] Win Back Master Sheet (`1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs`)
    - `gog sheets get 1_gltz-8ZbRbYnXeOoYcK_Y5PyFJ8npogFbw-eT4JKPs --range "high_value_churn!A1:AE2" --account a@muso.ai`
    - Confirm tab `pro_churned_all` exists
    - Confirm tab `high_value_churn` exists with ~1080 rows
- [ ] Confirm Gmail label `Win-Back` exists in `a@muso.ai`

## Phase 5, GHL Wire Up

- [ ] Confirm GHL API key works:
    ```bash
    curl -s -G "https://services.leadconnectorhq.com/opportunities/pipelines" \
      -H "Authorization: Bearer $GHL_API_KEY" -H "Version: 2021-07-28" \
      -d "locationId=S5w31kRRgsBjjiVATWlP" | python3 -m json.tool
    ```
- [ ] Confirm pipeline `B2B-Ads-Clio` (`GeSt85TueSvJ0SNFZXfQ`) exists
- [ ] Fetch all 11 stage IDs and write them into `skills/muso-outreach-engine/references/pipeline-stages.md`
    - Cold
    - Emailed
    - Follow-up
    - Replied
    - Meeting Booked
    - No-Show
    - Awaiting for Application
    - Proposal Draft
    - Proposal Sent
    - Closed Won
    - Closed Lost
- [ ] Confirm custom field `sheet_row_id` exists on the Contact object. If not, ask Nick to create it.
- [ ] Test WRITE: create a dummy contact, create a dummy opportunity at Cold stage, delete both

### GHL Win Back Location (separate from B2B Ads)

- [ ] Confirm `$GHL_WINBACK_API_KEY` env var is set in `/etc/openclaw/main.env` and is DIFFERENT from `$GHL_API_KEY`
- [ ] Confirm GHL win back API key works:
    ```bash
    curl -s -G "https://services.leadconnectorhq.com/opportunities/pipelines" \
      -H "Authorization: Bearer $GHL_WINBACK_API_KEY" -H "Version: 2021-07-28" \
      -d "locationId=fmK5Vl9sJv49WTYA0QyP" | python3 -m json.tool
    ```
- [ ] Confirm pipeline `Churn -> Win-back` (`AZa8jK5S7UyQ0fqfxzyB`) exists
- [ ] Fetch all 7 stage IDs and write them into `skills/muso-winback-engine/references/pipeline-stages.md`
    - Churned
    - Next Up
    - Emailed
    - Replied
    - Follow-up
    - Re-subscribed
    - Lost / No Answer
- [ ] Confirm ~1080 high value pro users exist as opportunities at `Churned` stage
- [ ] Confirm custom field `sheet_row_id` exists on the Contact object in this location
- [ ] Test WRITE: create a dummy contact, create a dummy opportunity at Churned stage, delete both

## Phase 6, Slack Channels

Verify the agent can post to each channel:

- [ ] `#marketing` (general marketing)
- [ ] `#muso-ads` (advertising campaigns)
- [ ] `#campaigns` (campaign planning)
- [ ] `#sales-alerts` (C0ARQ021M40) (outreach notifications)
- [ ] `#company-finder` (C0ARS7XMY93) (daily company batches)
- [ ] `#win-back-alerts` (C0ARTH6U0S2) (churn win back, separate engine)
- [ ] `#hydra-heartbeat` (heartbeat posts)

For each, post a test message "CMO wire up test, please ignore" then delete.

## Phase 7, Skills Inventory

- [ ] List every skill directory under `skills/` and read its SKILL.md
- [ ] For each outreach subskill, confirm it references `muso-outreach-engine/references/config.md`
- [ ] For each winback subskill, confirm it references `muso-winback-engine/references/config.md`
- [ ] For each directly available analytics skill (ProfitWell, Amplitude, Rewardful), run one test query
- [ ] Send Finance one read-only current-subscription test request and confirm its live Stripe response follows `muso-stripe-subscription-analytics` reporting rules
- [ ] Confirm `muso-slack-formatter` is loaded (mandatory output filter)
- [ ] Confirm `muso-outreach-engine` + `muso-outreach-writer` load together
- [ ] Confirm `muso-winback-engine` + `muso-winback-writer` load together
- [ ] Confirm both engines have their `qa` subskill (`muso-outreach-qa`, `muso-winback-qa`)

## Phase 8, Cron Jobs

- [ ] List all active crons
- [ ] Confirm these exist and are active (or pending, if not yet wired):
    - `b2b-reply-scanner-15m` (every 15 min, all 4 accounts)
    - `cmo-eod-briefing` (daily, 22:00 CET, Nick's DM `D0AKT90NQJX`)
    - `amp-daily-report` (daily, 11:00 AM CST)
    - `company-finder-daily` (1 PM CEST, #company-finder) NEW, may not exist yet
    - `muso-winback-engine` (3x daily 9am, 1pm, 5pm CST) separate engine
- [ ] For any cron marked "pending", ask Nick if it should be wired now or later

## Phase 9, Memory & Reference State

- [ ] Read `MEMORY.md` and confirm no Clay references remain
- [ ] Read `HEARTBEAT.md` and confirm all channels point to new destinations (not the deprecated legacy Clio channel `C0AHN078CSH` for sales)
- [ ] Read `AGENTS.md` and confirm the 11 agent roster
- [ ] Read `TOOLS.md` and confirm access levels match the current wiring

## Phase 10, Smoke Test

Run a dry run of the full outreach workflow on ONE contact without actually sending:

- [ ] Pick 1 untouched contact from NocoDB Contacts Intelligence (`m9vsbijhrr9ddeu`)
- [ ] Run the 4 source exclusion check (sheet logbook, NocoDB Contacts Intelligence Status, GHL, Gmail label)
- [ ] Generate a draft email via `muso-outreach-writer` with Aaron voice
- [ ] Confirm the email has: no em dash, under 120 words, HTML, correct signature
- [ ] Show the draft to Nick in `#marketing`
- [ ] Do NOT actually send. This is a smoke test.

## Phase 11, Final Sign Off

- [ ] All phases complete
- [ ] Post to `#marketing`:
    "CMO wire up complete. All 11 phases passed. System is live. Delete STARTUP.md when ready."
- [ ] Wait for Nick to confirm
- [ ] Delete this file

## Troubleshooting

- **If a token is missing**: ask Nick, do not guess, do not try to read other config files
- **If a sheet read fails**: check `gog auth list`, confirm a@muso.ai is authenticated
- **If GHL returns 401**: the API key may have expired, ask Nick for a new one
- **If a Slack post fails**: confirm the channel ID is correct and the bot is in the channel
- **If any check fails twice**: stop, escalate to Nick, do not retry blindly

## Never

- Never send real emails during wire up
- Never write to GHL production opportunities during smoke test (use dummies only)
- Never assume missing config is intentional, always confirm with Nick
- Never mark a phase complete if any checklist item is red
