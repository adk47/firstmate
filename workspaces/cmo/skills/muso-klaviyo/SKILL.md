---
name: muso-klaviyo
description: |
  Klaviyo email/SMS marketing analytics, flow authoring, and template editing. Query metrics, profiles, campaigns, flows, lists, segments. Create new flows from scratch or by cloning existing ones. Edit standalone library email templates.
  WRITE ACCESS: Aaron (U7RP6HKUZ) and Fede (U07NF5A77E2) only. All other users are READ-ONLY.

  Use when: checking email/SMS campaign performance, subscriber profiles, list/segment sizes,
  flow performance, event history, marketing analytics, OR creating/cloning a flow, OR editing email template HTML, OR a user asks to "duplicate / clone / build / draft a flow" with new copy.

  Triggers: "klaviyo", "email marketing", "email campaigns", "sms campaigns", "email metrics",
  "subscriber", "flow", "campaign performance", "open rate", "click rate", "clone flow",
  "duplicate flow", "create flow", "build dunning flow", "edit template", "swap email copy"
allowed-tools:
  - Bash
compatibility: |
  Requires MUSOAI_KLAVIYO_TOKEN env var.
metadata:
  version: "1.1"
  source-repo: "Muso-AI/muso-skills"
---

# Klaviyo Skill

Query and manage Muso.AI email/SMS marketing data from Klaviyo.

## Access Control

- **Aaron (U7RP6HKUZ):** Full read/write access
- **Fede (U07NF5A77E2):** Full read/write access
- **All other users:** READ-ONLY. Only GET requests (and POST for search/aggregate endpoints). Never create, update, or delete data.

Always check `sender_id` before executing any write operation.

## Authentication

The private API key is available as `$MUSOAI_KLAVIYO_TOKEN` in the environment.

Klaviyo uses a custom Authorization header and requires a `revision` header for API versioning:

```bash
curl -s \
  -H "Authorization: Klaviyo-API-Key $MUSOAI_KLAVIYO_TOKEN" \
  -H "revision: 2025-01-15" \
  "https://a.klaviyo.com/api/metrics/"
```

All subsequent curl commands use the same auth headers.

> **Important:** Always include the `revision` header. Use `2025-01-15` (latest stable) for read endpoints and templates.
>
> Beta endpoints use a different revision. **Flow create/clone (`POST /api/flows/`) requires `revision: 2024-10-15.pre`.** Mixing revisions on the same call is fine — pick the one the endpoint requires.

## Truthfulness rule (READ THIS BEFORE CLAIMING SOMETHING IS IMPOSSIBLE)

If you are about to tell a user "the Klaviyo API doesn't support X" — STOP. Verify with a curl first. Asserting limits without testing has blown up live conversations (see 2026-04-28 dunning V2 incident).

Concretely, **these things ARE possible via API even though they may feel like UI-only**:
- Creating a brand-new flow from scratch (`POST /api/flows/`, beta).
- Cloning an existing flow with modified message bodies/templates (GET definition → mutate `template_id`s → POST).
- Editing email HTML in standalone library templates (`PATCH /api/templates/{id}/`).

If you're unsure, run a `curl -i` and read the actual status code instead of guessing. A 405 or 404 is information; a hallucinated "not possible" is a lie.

## Base URL

`https://a.klaviyo.com/api/`

## Allowed Operations (Read-Only)

### Metrics (Event Types)
```bash
# List all metrics (event types like "Placed Order", "Opened Email", etc.)
curl -s \
  "https://a.klaviyo.com/api/metrics/" | jq '.data[] | {id, name: .attributes.name}'
```

### Metric Aggregates (Analytics — POST but read-only)
```bash
# Query aggregated metric data (e.g., total revenue from "Placed Order" events)
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "type": "metric-aggregate",
      "attributes": {
        "metric_id": "METRIC_ID",
        "measurements": ["count", "sum_value"],
        "interval": "day",
        "filter": ["greater-or-equal(datetime,2026-01-01T00:00:00)","less-than(datetime,2026-02-01T00:00:00)"]
      }
    }
  }' \
  "https://a.klaviyo.com/api/metric-aggregates/" | jq
```

> **Measurements:** `count`, `sum_value`, `unique` (count of unique profiles)
> **Intervals:** `day`, `week`, `month`
> **Filters:** Use Klaviyo filter syntax: `greater-or-equal(datetime,...)`, `less-than(datetime,...)`

### Events (Individual Event Records)
```bash
# List recent events
curl -s \
  "https://a.klaviyo.com/api/events/?sort=-datetime" | jq '.data[:5] | .[] | {type: .attributes.metric_id, email: .attributes.profile_id, time: .attributes.datetime}'

# Filter events by metric
curl -s \
  "https://a.klaviyo.com/api/events/?filter=equals(metric_id,\"METRIC_ID\")&sort=-datetime" | jq
```

### Profiles (Subscribers)
```bash
# List profiles
curl -s \
  "https://a.klaviyo.com/api/profiles/" | jq '.data[:5] | .[] | {id, email: .attributes.email, name: "\(.attributes.first_name) \(.attributes.last_name)"}'

# Get a specific profile
curl -s \
  "https://a.klaviyo.com/api/profiles/PROFILE_ID/" | jq '.data.attributes'

# Filter profiles by email
curl -s \
  "https://a.klaviyo.com/api/profiles/?filter=equals(email,\"user@example.com\")" | jq
```

### Lists
```bash
# List all lists
curl -s \
  "https://a.klaviyo.com/api/lists/" | jq '.data[] | {id, name: .attributes.name}'

# Get profiles in a list
curl -s \
  "https://a.klaviyo.com/api/lists/LIST_ID/profiles/" | jq '.data[] | {id, email: .attributes.email}'
```

### Segments
```bash
# List all segments
curl -s \
  "https://a.klaviyo.com/api/segments/" | jq '.data[] | {id, name: .attributes.name}'

# Get profiles in a segment
curl -s \
  "https://a.klaviyo.com/api/segments/SEGMENT_ID/profiles/" | jq '.data[] | {id, email: .attributes.email}'
```

### Campaigns
```bash
# List all campaigns
curl -s \
  "https://a.klaviyo.com/api/campaigns/?filter=equals(messages.channel,\"email\")" | \
  jq '.data[] | {id, name: .attributes.name, status: .attributes.status}'

# Get campaign details
curl -s \
  "https://a.klaviyo.com/api/campaigns/CAMPAIGN_ID/" | jq '.data.attributes'
```

### Flows
```bash
# List all flows
curl -s \
  "https://a.klaviyo.com/api/flows/" | jq '.data[] | {id, name: .attributes.name, status: .attributes.status}'

# Get flow details
curl -s \
  "https://a.klaviyo.com/api/flows/FLOW_ID/" | jq '.data.attributes'
```

### Tags
```bash
# List all tags
curl -s \
  "https://a.klaviyo.com/api/tags/" | jq '.data[] | {id, name: .attributes.name}'
```

## Pagination

Klaviyo uses cursor-based pagination. Check `links.next` in the response:

```bash
# First page
RESPONSE=$(curl -s \
  "https://a.klaviyo.com/api/profiles/?page[size]=20")

echo "$RESPONSE" | jq '.data | length'  # items on this page

# Get next page URL
NEXT=$(echo "$RESPONSE" | jq -r '.links.next // empty')
if [ -n "$NEXT" ]; then
  curl -s \
    "$NEXT" | jq '.data | length'
fi
```

## Sparse Fieldsets

Reduce payload size by requesting only specific fields:

```bash
# Get only email and name from profiles
curl -s \
  "https://a.klaviyo.com/api/profiles/?fields[profile]=email,first_name,last_name" | jq
```

## Common Workflows

### Email Campaign Performance Summary
```bash
# 1. List recent email campaigns
curl -s \
  "https://a.klaviyo.com/api/campaigns/?filter=equals(messages.channel,\"email\")&sort=-send_time" | \
  jq '.data[:5] | .[] | {name: .attributes.name, status: .attributes.status, send_time: .attributes.send_strategy.datetime}'
```

### Find a Subscriber by Email
```bash
curl -s \
  "https://a.klaviyo.com/api/profiles/?filter=equals(email,\"user@example.com\")" | \
  jq '.data[] | .attributes'
```

### Count Events in a Date Range
```bash
# First get the metric_id for the event you want (e.g., "Placed Order")
METRIC_ID=$(curl -s \
  "https://a.klaviyo.com/api/metrics/" | \
  jq -r '.data[] | select(.attributes.name == "Placed Order") | .id')

# Then query aggregates
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "{
    \"data\": {
      \"type\": \"metric-aggregate\",
      \"attributes\": {
        \"metric_id\": \"$METRIC_ID\",
        \"measurements\": [\"count\", \"sum_value\", \"unique\"],
        \"interval\": \"month\",
        \"filter\": [\"greater-or-equal(datetime,2025-01-01T00:00:00)\",\"less-than(datetime,2026-02-01T00:00:00)\"]
      }
    }
  }" \
  "https://a.klaviyo.com/api/metric-aggregates/" | jq
```

## Tips

- **Write access:** Aaron (U7RP6HKUZ) and Fede (U07NF5A77E2) only. All others read-only.
- Always include the `revision: 2025-01-15` header (API versioning is mandatory)
- Response format follows JSON:API spec: `{"data": [...], "links": {...}}`
- Use `| jq` to parse and filter JSON responses
- Always use `-s` (silent) flag with curl to suppress progress output
- Rate limits: Burst 10/s, Steady 150/m per endpoint — check response headers
- Use sparse fieldsets (`?fields[type]=field1,field2`) to reduce response size
- Pagination: max 200 items per page, use `page[size]` param and `links.next` for next page
- Filter syntax: `equals(field,"value")`, `greater-or-equal(field,value)`, `less-than(field,value)`
- POST to `/api/metric-aggregates/` is read-only (queries data, does not create anything)

## Write Operations (gated to Aaron / Fede only)

Before any of the following, verify `sender_id` is `U7RP6HKUZ` (Aaron) or `U07NF5A77E2` (Fede). If not, refuse and ask the requester to ping one of them.

### Editing an email template (library templates only)

Library templates are standalone, reusable email templates. Their IDs come from `GET /api/templates/`. They are EDITABLE via API.

```bash
# List library templates (find the IDs you care about by name)
curl -s -H "Authorization: Klaviyo-API-Key $MUSOAI_KLAVIYO_TOKEN" \
  -H "revision: 2025-01-15" \
  "https://a.klaviyo.com/api/templates/" | jq '.data[] | {id, name: .attributes.name, updated: .attributes.updated}'

# Update HTML and/or text content
curl -s -X PATCH \
  -H "Authorization: Klaviyo-API-Key $MUSOAI_KLAVIYO_TOKEN" \
  -H "revision: 2025-01-15" \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "type": "template",
      "id": "TEMPLATE_ID",
      "attributes": {
        "name": "Dunning Email #1",
        "html": "<p>Hey {{ first_name|default:\"there\" }}, ...</p>",
        "text": "Hey {{ first_name|default:\"there\" }}, ..."
      }
    }
  }' \
  "https://a.klaviyo.com/api/templates/TEMPLATE_ID/" | jq
```

> **Drag-and-drop templates**: `PATCH /templates/{id}/` does NOT update drag-and-drop templates' visual definition — only `name`, `html`, `text`. If the source-of-truth is the drag-and-drop editor, edit there.
>
> **Creating new templates programmatically:** `POST /api/templates/` creates standard HTML templates fine. For drag-and-drop templates, Klaviyo's create-from-scratch path requires app-partner template IDs and the dedicated **Clone Template API** — you cannot author the visual blocks via the basic templates endpoint. If a flow action needs a drag-and-drop template you don't already have a clone source for, build it in the UI first, then reference its ID in the flow definition.

### Library template vs flow-internal template (the gotcha that bit us 2026-04-28)

Klaviyo has TWO distinct template ID spaces:

| Type | Where it lives | Editable via API? | How to identify |
|---|---|---|---|
| **Library template** | Top-level "Templates" library | YES — `PATCH /api/templates/{id}/` | Returned by `GET /api/templates/` |
| **Flow-internal template** | Snapshot inside a published flow message | NO — read-only via API | `GET /flow-messages/{id}/template/` returns it but PATCH 404s |

**Implication:** Editing a library template does NOT auto-update a live flow that already references it — flows hold their own snapshot at publish time. To get new copy into an existing live flow, either:
1. Build a new draft flow via `POST /api/flows/` (preferred — see next section), OR
2. Have a human re-attach the updated library template inside the Klaviyo flow editor UI.

### Cloning a flow with new copy (THE workflow for "duplicate this flow but change the messages")

This is what would have answered Fede's 2026-04-28 ask in 5 minutes. Beta endpoint, `revision: 2024-10-15.pre`.

> ⚠️ **Beta endpoint — production safety rules.** `POST /api/flows/` is a beta API. Klaviyo's own guide tells you not to point production traffic at it without a UI review. Concretely, when CMO uses this:
>
> 1. **Always create as Draft** (the endpoint's default — never override `status` to `live`/`manual` in the request body).
> 2. **Never activate the new flow from the API.** Activation is a Klaviyo UI action by Aaron or Fede after they review the draft. CMO posts the new flow ID into Slack, says "draft created — review and activate in UI", and stops.
> 3. **Don't deactivate the old flow programmatically as part of the same session.** Two operations on production marketing flows = two human reviews.
>
> If a requester pushes for "just activate it directly", refuse and ask them to review in the UI first — same gate that exists for any production write.

**Step 1 — Update or create the library templates with the new copy:**

```bash
# (use the PATCH /templates/ pattern above to put Serhii's new HTML into the relevant library template IDs)
```

**Step 2 — Pull the full definition of the existing live flow:**

```bash
SRC_FLOW_ID="UgzmYJ"  # e.g. Failed Payment Dunning (Aaron)

curl -s \
  -H "Authorization: Klaviyo-API-Key $MUSOAI_KLAVIYO_TOKEN" \
  -H "revision: 2024-10-15.pre" \
  "https://a.klaviyo.com/api/flows/$SRC_FLOW_ID/?additional-fields[flow]=definition" \
  > /tmp/src-flow.json

jq '.data.attributes.definition' /tmp/src-flow.json | head -80
```

**Step 3 — Mutate the response into a valid create-request body:**

In `data.attributes`, the response includes runtime-only fields. The create endpoint rejects them. Strip and rewrite:

- Set a new `attributes.name` (e.g. `"Failed Payment Clio V2"`).
- Delete `attributes.created`, `attributes.updated`, `attributes.status`, `attributes.trigger_type`.
- Delete `data.relationships` and `data.links`.
- For each entry in `attributes.definition.actions[]`: copy the existing `id` value into `temporary_id` and DELETE the `id` field. Klaviyo will mint real IDs on POST.
- For email actions, set `data.message.template_id` to the **library template ID** containing the new copy (from Step 1). This is the lever that swaps in new copy without touching the original flow.
- Subject lines live in `data.message.subject_line` — update if needed.
- Update `attributes.definition.entry_action_id` if it referenced an `id` you just rewrote (use the new `temporary_id`).

**Step 4 — POST the new flow (creates as Draft by default):**

```bash
curl -s -X POST \
  -H "Authorization: Klaviyo-API-Key $MUSOAI_KLAVIYO_TOKEN" \
  -H "revision: 2024-10-15.pre" \
  -H "Content-Type: application/json" \
  -d @/tmp/new-flow.json \
  "https://a.klaviyo.com/api/flows/" | jq '.data | {id, status: .attributes.status, name: .attributes.name}'
```

The response gives you the new flow's permanent `id`. Drop it in Slack so the requester can review/activate in the UI.

> **Rate limits on `POST /api/flows/`:** Burst 1/s, Steady 15/m, Daily 100/d. Required scope: `flows:write`.

### Minimal example payload skeleton

```json
{
  "data": {
    "type": "flow",
    "attributes": {
      "name": "Failed Payment Dunning V2",
      "definition": {
        "triggers": [
          { "type": "metric", "id": "$metric_id_for_payment_failed", "trigger_filter": null }
        ],
        "profile_filter": null,
        "entry_action_id": "act-1",
        "actions": [
          {
            "temporary_id": "act-1",
            "type": "send-email",
            "links": { "next": "act-2" },
            "data": {
              "message": {
                "subject_line": "Quick heads up — your subscription payment didn't go through",
                "template_id": "UECpTy",
                "from_email": "aaron@muso.ai",
                "from_label": "Aaron Kaufman"
              }
            }
          },
          {
            "temporary_id": "act-2",
            "type": "time-delay",
            "links": { "next": "act-3" },
            "data": { "delay_seconds": 259200 }
          }
        ]
      }
    }
  }
}
```

## Hard Limits — what is NOT possible via the Klaviyo API

Use this list when the right answer truly is "you have to do it in the UI". Don't add to this list without verifying with a real curl.

| Want to do | API supports? | Workaround |
|---|---|---|
| Update the *definition / structure / message bodies* of an already-created flow | NO | Create a new draft via `POST /api/flows/`, deactivate the old one (status PATCH or UI) |
| Update *only the status* of an existing flow (live / manual / draft) | YES — `PATCH /api/flows/{id}` (scope `flows:write`, revision `2025-01-15`) | n/a |
| Clone a flow with a single dedicated `/clone` endpoint | NO (no `/clone` route exists) | Use the GET-definition → mutate → POST pattern above — functionally equivalent |
| Edit HTML inside a flow-internal template (`flow-message/{id}/template/`) | NO (read-only — `PATCH` returns 404) | Edit a library template, then re-attach in the flow editor UI |
| Add A/B test / split actions to a flow being created via API | NOT in the beta `POST /api/flows/` schema | Build the A/B variant in the UI |
| Delete a flow | NOT verified — no documented `DELETE /api/flows/{id}`. If you need this, run `curl -i -X DELETE` against a throwaway draft and read the actual status code before asserting | UI archive is always available |

## Documentation

- Klaviyo API Overview: https://developers.klaviyo.com/en/reference/api_overview
- Metrics API: https://developers.klaviyo.com/en/reference/metrics_api_overview
- Profiles API: https://developers.klaviyo.com/en/reference/profiles_api_overview
- Segments API: https://developers.klaviyo.com/en/reference/segments_api_overview
- Events API: https://developers.klaviyo.com/en/reference/events_api_overview
- **Flows API (beta create)**: https://developers.klaviyo.com/en/reference/create_flow
- **Flows API guide (workflow)**: https://developers.klaviyo.com/en/v2024-10-15/reference/create_and_retrieve_flows
- **Templates API (PATCH HTML)**: https://developers.klaviyo.com/en/reference/update_template
