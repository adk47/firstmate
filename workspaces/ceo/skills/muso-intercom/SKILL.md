---
name: muso-intercom
description: |
  Intercom customer messaging and support. Query conversations, contacts, companies.
  WRITE ACCESS: Aaron (U7RP6HKUZ) ONLY. All other users are READ-ONLY.

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

## Write Access Control (MANDATORY — check FIRST)

**Write operations (send messages, update contacts, tag, close conversations, etc.):**
- `U7RP6HKUZ` (Aaron) → full write access
- Everyone else → READ ONLY. Politely decline write requests: "Intercom writes are Aaron-only. Ask him directly."

**Read operations (search, list, view):** available to all authorized users.

Always verify `sender_id` from inbound metadata before any write operation.

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

> **Token fix applied (2026-02-16):** The `$MUSOAI_INTERCOM_TOKEN` in `~/.zshrc`
> had a trailing space corrupting the value. This has been fixed. Run `source ~/.zshrc`
> to reload.

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

- **READ-ONLY ONLY** - Never modify data
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
