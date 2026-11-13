---
name: muso-intercom
description: |
  Intercom customer messaging and support. Query conversations, contacts, companies.
  WRITE ACCESS: Aaron (U7RP6HKUZ), Jan (U038BM16T7W), Nick (U0AL36NADEY) co-equal;
  everyone else is READ-ONLY. Every conversation write goes through
  /opt/hydra/scripts/intercom-ops-write.sh (internal note by default).

  Use when: viewing conversations, searching contacts/users, looking up companies,
  checking tags, viewing segments, browsing help articles, or querying support data.

  Triggers: "intercom", "conversation", "contact", "support ticket", "help article",
  "customer support", "chat", "inbox", "segment", "company"
allowed-tools:
  - Bash
compatibility: |
  Requires MUSOAI_INTERCOM_TOKEN env var.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Intercom Skill

Query and manage Muso.AI customer messaging and support data from Intercom.

## Write Access Control (MANDATORY – check FIRST)

**Write operations (send messages, update contacts, tag, close conversations, etc.):**
- `U7RP6HKUZ` (Aaron), `U038BM16T7W` (Jan), `U0AL36NADEY` (Nick) → full write
  access, co-equal. Their request IS the authorization: execute it and report
  the result. **Never route one of them to another for sign-off**, and never
  answer a Tier-1 "do it" with "I'm waiting on Aaron": that is inventing an
  approval requirement that does not exist.
- Everyone else → READ ONLY. Politely decline write requests: "Intercom writes
  need Jan, Nick or Aaron. Want me to ask Jan?"

**The one machine class, and it is not yours to use.** `intercom-ops-write.sh reply
--purpose gdpr-erasure` posts a statutory erasure letter as `system:gdpr-pipeline`
with no human id. The writer refuses any conversation the erasure register does not
own **and any body the pipeline has not already claimed** (a `sending` ledger row
carrying that conversation and the sha256 of those exact bytes), so it can only post
copy the pipeline composed under its own gates. It exists because a GDPR letter is an
obligation with its own clock, not a request. It is called by
`scripts/gdpr-pipeline.py` and by nothing else: an agent reaching for `--purpose` to
skip the allowlist is exactly the 2026-08-31 failure with a new flag. If you are not
the GDPR pipeline, you need a human.

Authorization is not a path. A note or reply goes through the wrapper in "Writing to
a conversation" below; a bulk stale close through `cs-stale-drain`; an abuse tag or
close through `muso-abuse-block`. A write with no wrapper today (a single
conversation's close, an assignment, a tag, a snooze, a contact update) is done by
the human in the inbox: say so plainly and do the supported part, never a hand-typed
curl.

**A request that falls outside a safe wrapper is not an approval problem.** If
Jan or Nick asks for a variation the tooling can't express (a different
staleness window, a narrower scope), the missing piece is a *capability*, not a
signature. Say plainly what the tool can and cannot do, do the part that is
supported, and never convert "my script doesn't have that flag" into "Aaron
must approve this". Escalating a capability gap to a human as an approval
request is the 2026-08-26 failure (Jan asked twice to close her 14-day-old
inbox; the agent posted a write-approval page to Aaron, then refused Nick's
explicit "do it" on the grounds that Aaron had not answered).

**Read operations (search, list, view):** available to all authorized users.

Always verify `sender_id` from inbound metadata before any write operation.

## Writing to a conversation (MANDATORY path)

Reads are raw curl. A WRITE into a conversation is **never a raw curl**: it goes through
the wrapper, which pins Caroline's identity, logs the write to `api-logs/` before it
happens, and verifies what Intercom actually created.

```bash
# Internal note (the default). Not visible to the customer. --audience is required and
# becomes the first line: "Note to Jan (internal Ops note, not visible to the customer)."
/opt/hydra/scripts/intercom-ops-write.sh note \
  --conversation CONVERSATION_ID --requested-by SLACK_USER_ID \
  --audience Jan --body-file /path/to/note.txt

# Customer-facing reply. ONLY when the human explicitly said to answer the CUSTOMER.
/opt/hydra/scripts/intercom-ops-write.sh reply \
  --conversation CONVERSATION_ID --requested-by SLACK_USER_ID \
  --customer-facing --approved-by SLACK_USER_ID --body-file /path/to/reply.txt
```

- **A resolution, summary or status asked for in Slack is a NOTE.** "Do resolution",
  "summarize this", "what's the status" all mean: tell the team, in the inbox, as an
  internal note addressed to whoever asked (`--audience Jan`) or to `team`. The customer
  is answered only when the human says so in words ("reply to the customer", "tell
  them ...").
- `--requested-by` is the Slack user id from message metadata of the human who asked.
  The wrapper refuses anyone outside the write allowlist above; that refusal is the
  answer, not a reason to post another way.
- `--approved-by` is a HUMAN's Slack user id. Self-approval, god-mode and agent
  identities never authorize a customer-facing reply (2026-08-31: a self-approved reply
  reached customers under a human's name).
- The customer never sees internal surfaces. The wrapper refuses a customer-facing body
  that carries an issue link, "Ops resolution", "ticket", an admin id, a Slack mention,
  or any pattern Caroline's outbound sanitizer redacts
  (`plugins/intercom/src/sanitize-tool-leak.ts`: tool tokens, "tool failed", ClickUp,
  openclaw, HYDRA). Paraphrase the bridge's `customer_safe_summary` in Caroline's
  voice; quote the normal SLA, never an engineering ETA.
- `--dry-run` renders the exact payload and posts nothing; `--validate` checks only.
- Closing, assigning, tagging and snoozing are outside this wrapper. Bulk stale closes
  go through the `cs-stale-drain` skill and abuse tagging/closing through
  `muso-abuse-block`; any other close, assignment, tag or snooze is a human's action in
  the inbox, not a hand-typed curl.
- The trust-yet-verify note ("We added your credit ... Please help us verify it") and its
  `credit-proof` tag are a separate, cron-driven path:
  `/opt/hydra/scripts/intercom-verify-request.sh`, run by `credit-review.py verify-notify`
  (fixed copy, captain-approved, one note per user per day). Never send that note or tag
  a proof reply by hand; see `docs/credit-verification/verify-request-notes.md`.

## Reply Identity (MANDATORY for customer-facing writes)

Agent-authored, customer-facing conversation replies MUST post as **Caroline,
`admin_id: "5763097"`**, so the customer sees one consistent support identity for
the whole thread. A human's Slack authorization authorizes the *write*; it never
changes the *posting identity*. Never post a reply, note-to-customer, or closing
message under a human admin id (Nick `10206197`, Aaron `5201828`, Jan `5465657`):
on 2026-08-31 escalation follow-ups posted with Nick's id showed customers
"Nicholas Sollazzo" mid-thread instead of Caroline. (Same rationale as
muso-ops-dedup, which pins `INTERCOM_ADMIN_ID=5763097` "so the reply matches the
rest of the thread".) Internal notes carry `5763097` too. On an assignment call
`5763097` is the ACTOR (`admin_id`). **Caroline is also the default ASSIGNEE: the AI
queue is "assigned to `5763097`", and no conversation is assigned to a person by
default** (captain 2026-11-11; `plugins/intercom/src/assignment-policy.ts`). Only an
explicit escalation that carries a reason leaves her, and it goes to the escalation
TEAM queue (`escalationTeamId`, sent with `type: "team"`), never to an individual's
admin id. `defaultInboxId` is retired: `scripts/check-intercom-no-personal-assignee.sh`
fails CI if a config sets it. Assigning an escalated conversation back to Caroline is
the hand-back: when the customer spoke last she answers at that moment, not on their
next message (`plugins/intercom/src/handler.ts`, the `assigned` branch). The only exception to any of this is a human
posting as themselves from the Intercom UI.

## Authentication

The API token is available as `$MUSOAI_INTERCOM_TOKEN` in the environment.

Intercom uses Bearer token authentication:

```bash
curl -s \
  -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" \
  -H "Accept: application/json" \
  "https://api.intercom.io/..."
```

All subsequent curl commands use the same auth headers.

> **Token fix applied (2026-02-16):** The `$MUSOAI_INTERCOM_TOKEN` had a trailing space
> corrupting the value. This has been fixed. It lives in your gateway profile's env file
> (`/etc/openclaw/main.env`, or `edge.env` for the CS/Intercom profile).

## Base URL

`https://api.intercom.io`

## API Versioning

Include the API version header for consistent responses:

```bash
-H "Intercom-Version: 2.11"
```

## Allowed Operations (Read-Only)

### Conversations
```bash
# List conversations
curl -s \
  "https://api.intercom.io/conversations?per_page=20" | jq

# Get a specific conversation
curl -s \
  "https://api.intercom.io/conversations/CONVERSATION_ID" | jq

# Get conversation with full message parts
curl -s \
  "https://api.intercom.io/conversations/CONVERSATION_ID?display_as=plaintext" | jq
```

### Attachments (screenshots, PDFs)

Attachment URLs in conversation payloads are **signed CDN links with a ~30
minute TTL** -- URLs copied from an earlier fetch (or handed to a delegated
subagent) expire and then return 403. To inspect attachments, always use the
bundled helper, which re-fetches the conversation fresh (fresh signed URLs),
downloads every attachment locally, and detects the file type itself (no
dependency on the `file` binary -- node-8 does not have it):

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-intercom/scripts/fetch-conversation-attachments.sh \
  CONVERSATION_ID [--out-dir DIR]
```

Prints one JSON line per downloaded attachment:
`{"path":"...","source_url":"...","detected_type":"png|jpeg|gif|webp|heic|pdf|unknown","bytes":N}`.
Read the downloaded files with vision to inspect them.

Two extra keys can appear, and both change what you may conclude:

- `"converted_from":"heic"` + `"original_path":"..."` -- the attachment was an
  iPhone HEIC and has been transcoded to JPEG for you (`heif-convert`, from
  the `libheif-examples` package). Inspect `path`; `original_path` is the
  untouched original.
- `"unreadable":true` + `"unreadable_reason":"heic_decode_failed"`,
  `"corrupt_or_unrecognized"`, `"oversize"` or `"pipeline_failed"` -- the bytes
  arrived and did not become usable evidence. This marker is the ONLY basis for
  reporting unreadable or corrupt evidence, and it claims something about the
  lines it appears on and nothing else. A manifest carrying no `unreadable` line
  is NOT proof that every attachment was fetched: if the conversation references
  a file the manifest does not list, report what you did and did not receive and
  ASK -- never call it corrupt, and never call the set complete. The reasons are
  NOT interchangeable:
  - `pipeline_failed` -- we never examined the file at all: `heif-convert` is
    not installed (`apt-get install -y libheif-examples`) or the transcode blew
    its 12s bound. A node-8 provisioning problem. Say NOTHING about the file
    itself; you have no evidence about it.
  - `heic_decode_failed` -- libheif looked at the payload and refused it. That
    is EITHER a damaged/truncated upload OR a variant we cannot decode, and the
    helper cannot tell which. A valid HEIC header proves the container, never
    the payload. Report that it could not be decoded; do NOT assert it is
    corrupt, and do NOT assert the customer's file is fine.
  - `corrupt_or_unrecognized` -- the bytes matched no container we know. That
    is EITHER a damaged/truncated upload OR a valid file in a format we cannot
    read (TIFF, MP4, ZIP, DOCX...), and the helper CANNOT tell which. Never
    report it as damaged. Each line carries `declared_type`, the content-type
    the uploading client claimed: a hint, NOT something we verified -- clients
    mislabel constantly, which is why the bytes are sniffed at all. Ask for a
    JPEG/PNG screenshot rather than the same file again.
  - `oversize` -- the opposite of a failure: the HEIC decoded FINE and the
    resulting JPEG was over the 10MB cap, so it was refused. Never report an
    `oversize` file as corrupt or undecodable -- ask for a smaller version or a
    screenshot.

Read the MANIFEST, never the directory. The default out-dir is reused per
conversation and the index restarts at 1 on every run, so the directory can
hold files from earlier runs. Only the JSON lines this invocation printed
describe this invocation's attachments; the helper removes the outputs it owns
before re-converting, but a stale `1.png` from a differently-shaped earlier run
can still sit there. Never glob the directory and inspect what you find.

Rules:

- **Inspect attachments centrally** (the agent handling the request). Do NOT
  hand attachment URLs to delegated subagents for inspection -- by the time
  they run, the signed URLs are typically expired and subagents cannot read
  the parent's local files. Subagents should return the conversation ID and
  let the parent download + inspect.
- Do NOT improvise `curl` + `file` pipelines; the helper handles auth, URL
  freshness, the CDN host allowlist, size caps, and type detection.
- Downloading is a read operation and needs no write approval.

### Search Conversations (POST - Read-Only)
```bash
# Search conversations by keyword
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "query": {
      "operator": "AND",
      "value": [
        {
          "field": "source.body",
          "operator": "~",
          "value": "search term"
        }
      ]
    }
  }' \
  "https://api.intercom.io/conversations/search" | jq

# Search conversations by contact email
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "query": {
      "field": "contact_ids",
      "operator": "=",
      "value": "CONTACT_ID"
    }
  }' \
  "https://api.intercom.io/conversations/search" | jq
```

### Contacts / Users
```bash
# List contacts
curl -s \
  "https://api.intercom.io/contacts?per_page=50" | jq

# Get a specific contact
curl -s \
  "https://api.intercom.io/contacts/CONTACT_ID" | jq
```

### Search Contacts (POST - Read-Only)
```bash
# Search contacts by email
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "query": {
      "field": "email",
      "operator": "=",
      "value": "user@example.com"
    }
  }' \
  "https://api.intercom.io/contacts/search" | jq

# Search contacts by name
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "query": {
      "field": "name",
      "operator": "~",
      "value": "John"
    }
  }' \
  "https://api.intercom.io/contacts/search" | jq
```

### Companies
```bash
# List companies
curl -s \
  "https://api.intercom.io/companies?per_page=50" | jq

# Get a specific company
curl -s \
  "https://api.intercom.io/companies/COMPANY_ID" | jq

# List company users
curl -s \
  "https://api.intercom.io/companies/COMPANY_ID/contacts" | jq
```

### Tags
```bash
# List all tags
curl -s \
  "https://api.intercom.io/tags" | jq
```

### Segments
```bash
# List all segments
curl -s \
  "https://api.intercom.io/segments" | jq

# Get a specific segment
curl -s \
  "https://api.intercom.io/segments/SEGMENT_ID" | jq
```

### Help Center Articles
```bash
# List articles
curl -s \
  "https://api.intercom.io/articles?per_page=50" | jq

# Get a specific article
curl -s \
  "https://api.intercom.io/articles/ARTICLE_ID" | jq
```

### Admins / Teammates
```bash
# List all admins/teammates
curl -s \
  "https://api.intercom.io/admins" | jq

# Get current admin (me)
curl -s \
  "https://api.intercom.io/me" | jq
```

### Counts
```bash
# Get app-wide counts
curl -s \
  "https://api.intercom.io/counts" | jq

# Get counts by type
curl -s \
  "https://api.intercom.io/counts?type=conversation" | jq
```

## Common Workflows

### Find a User's Support Conversations
```bash
# 1. Search for the contact
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"query":{"field":"email","operator":"=","value":"user@example.com"}}' \
  "https://api.intercom.io/contacts/search" | \
  jq '.data[] | {id, name, email, role}'

# 2. Get their conversations (use contact id from step 1)
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"query":{"field":"contact_ids","operator":"=","value":"CONTACT_ID"}}' \
  "https://api.intercom.io/conversations/search" | \
  jq '.conversations[] | {id, title: .source.subject, state, created_at}'
```

### Get Open Conversation Summary
```bash
curl -s \
  "https://api.intercom.io/conversations?open=true&per_page=50" | \
  jq '.conversations[] | {
    id,
    title: .source.subject,
    contact: .contacts.contacts[0].id,
    assignee: .assignee.name,
    created_at,
    waiting_since
  }'
```

## Tips

- Reads are raw curl. Writes go through `/opt/hydra/scripts/intercom-ops-write.sh`, never a raw curl (see "Writing to a conversation")
- Search endpoints use POST but are read-only (query, not mutation)
- Search operators: `=`, `!=`, `~` (contains), `!~`, `>`, `<`, `IN`, `NIN`
- Use `| jq` to parse and filter JSON responses
- Always use `-s` (silent) flag with curl to suppress progress output
- Pagination: use `per_page` and `starting_after` cursor from response `pages.next`
- Rate limit: varies by plan, check `X-RateLimit-Limit` response header
- Timestamps are Unix timestamps in seconds
- Include `-H "Intercom-Version: 2.11"` for consistent API behavior

## Documentation

- Intercom API Docs: https://developers.intercom.com/docs/references/rest-api/api.intercom.io/
- Search API: https://developers.intercom.com/docs/references/rest-api/api.intercom.io/Conversations/searchConversations/
- Pagination: https://developers.intercom.com/docs/build-an-integration/learn-more/rest-apis/pagination/
