---
name: muso-nocodb
description: |
  NocoDB Cloud REST API (v2) — full schema + data control plane for the
  marketing workspace's B2B-ADS-intelligence base.

  Use when: doing any operation against the B2B-ADS-intelligence base —
  record CRUD (create/read/update/delete/link), schema (tables, columns,
  views, filters, sorts), hooks, attachments, comments, shared views.
  This skill is cmo's single layer to NocoDB; there is no MCP fallback.

  Triggers: "nocodb", "create table", "add column", "single select",
  "kanban view", "nocodb webhook", "upload attachment", "shared view",
  "duplicate base", "B2B ADS intelligence", "marketing CRM base"
compatibility: |
  Requires `curl` + `jq` and `NOCODB_API_TOKEN` (a Personal Access Token,
  `nc_pat_…`) in the env. Reads NOCODB_API_URL, NOCODB_BASE_ID,
  NOCODB_WORKSPACE_ID — defaults baked in for the B2B-ADS-intelligence base.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - Bash
---

# muso-nocodb — NocoDB REST API

This skill is cmo's single layer to NocoDB. Drive everything — record CRUD, schema (tables/columns/views), hooks, attachments, comments, shared views — through `bash scripts/nocodb-api.sh <subcommand> [args]`.

## Defaults

The skill is preconfigured for the **B2B-ADS-intelligence** base. Env vars are loaded from `/etc/openclaw/main.env`:

```
NOCODB_API_URL=https://app.nocodb.com/api/v2
NOCODB_BASE_ID=p11hvpwapu4hv0x         # B2B-ADS-intelligence
NOCODB_WORKSPACE_ID=w8fofvl1           # marketing
NOCODB_API_TOKEN=nc_pat_***            # full-scope PAT, marketing@muso.ai
```

Use `--base <baseId>` on any subcommand to retarget. Use `--dry-run` to preview the curl call without executing.

## Quick start

```bash
# Identity + scope sanity
bash scripts/nocodb-api.sh auth.me

# What bases can this token see?
bash scripts/nocodb-api.sh workspaces.ls
bash scripts/nocodb-api.sh bases.get p11hvpwapu4hv0x

# Tables and their schemas
bash scripts/nocodb-api.sh tables.ls
bash scripts/nocodb-api.sh tables.get m9vsbijhrr9ddeu        # Contacts Intelligence

# Create a new table (two columns: name, email)
bash scripts/nocodb-api.sh tables.create p11hvpwapu4hv0x '{
  "table_name":"campaigns",
  "title":"Campaigns",
  "columns":[
    {"column_name":"title","title":"Title","uidt":"SingleLineText","pv":true},
    {"column_name":"sent_at","title":"Sent At","uidt":"DateTime"}
  ]
}'

# Add a SingleSelect column to an existing table (BOTH dtxp AND colOptions.options required)
bash scripts/nocodb-api.sh columns.add <tableId> '{
  "column_name":"status","title":"Status","uidt":"SingleSelect",
  "dtxp":"'\''new'\'','\''open'\'','\''closed'\''",
  "colOptions":{"options":[
    {"title":"new","color":"#cfdffe","order":1},
    {"title":"open","color":"#d1f7c4","order":2},
    {"title":"closed","color":"#ffdce5","order":3}
  ]}
}'

# Create a Kanban view grouped by status
bash scripts/nocodb-api.sh views.create <tableId> kanban '{"title":"Pipeline","fk_grp_col_id":"<statusColumnId>"}'

# Upload an attachment, then assign it to a record's Attachment column
ATT=$(bash scripts/nocodb-api.sh --raw attachments.upload ./logo.png)
bash scripts/nocodb-api.sh records.update <tableId> "[{\"Id\":12,\"Logo\":$ATT}]"

# Add a webhook that fires after row insert
bash scripts/nocodb-api.sh hooks.create <tableId> '{
  "title":"Slack on new contact","event":"after","operation":"insert",
  "notification":{"type":"URL","payload":{"method":"POST","url":"https://hooks.slack.com/…"}}
}'
```

## Aggregations (client-side)

NocoDB Cloud doesn't expose a public REST aggregation endpoint — `count` is the only server-side aggregate the PAT can reach. For sums/averages/group-by, fetch the rows and aggregate in `jq`.

> ⚠️ **NocoDB Cloud silently clamps `records.ls --limit` to 100.** A single
> `records.ls` returns at most 100 rows no matter what `--limit` you pass, so
> piping one call into a `jq` aggregate computes over ≤100 rows **silently** the
> moment the (filtered) set exceeds 100. `--limit 1000` does **not** work — to
> aggregate a whole table you MUST paginate until `pageInfo.isLastPage`.

```bash
# Filtered count (server-side — exact, no pagination needed)
bash scripts/nocodb-api.sh records.count m9vsbijhrr9ddeu --where "(Status,eq,Follow Up 2)"

# Fetch ALL rows of a table for the given --fields, as one JSON array. Loops until
# pageInfo.isLastPage (or an empty page) and advances --offset by the rows actually
# returned, so the 100-row clamp is harmless. (Same logic as company-finder's
# fetch_table — the merged #510 fix.) Pass extra `records.ls` flags (e.g.
# `--where '(…)'`) as trailing args to aggregate a filtered subset — they are
# forwarded to every page request.
nocodb_fetch_all() {  # usage: nocodb_fetch_all <tableId> <fields> [extra records.ls flags…]
  local tid="$1" fields="$2"; shift 2
  local offset=0 resp chunk n pages=()
  while :; do
    resp=$(bash scripts/nocodb-api.sh --raw records.ls "$tid" \
             --fields "$fields" --limit 100 --offset "$offset" "$@") || return 1
    chunk=$(jq -c '.list' <<<"$resp"); n=$(jq 'length' <<<"$chunk")
    pages+=("$chunk")
    [[ "$(jq -r '.pageInfo.isLastPage == true' <<<"$resp")" == true || "$n" -eq 0 ]] && break
    offset=$((offset + n))
  done
  printf '%s\n' "${pages[@]}" | jq -cs 'add // []'
}

# Group-by count: distribution of statuses (over the FULL table)
nocodb_fetch_all m9vsbijhrr9ddeu "Status" \
  | jq '[.[].Status] | group_by(.) | map({status: .[0], n: length}) | sort_by(.n) | reverse'

# Sum a numeric column (over the FULL table)
nocodb_fetch_all <tid> "Amount" \
  | jq '[.[].Amount // 0] | add'

# Sum over a FILTERED subset — trailing flags are forwarded to records.ls
nocodb_fetch_all <tid> "Amount" --where "(Status,eq,Follow Up 2)" \
  | jq '[.[].Amount // 0] | add'
```

For very large tables, prefer a narrow `--where` filter (so you paginate fewer rows) or a Grid view's URL-shared CSV export (`bash scripts/nocodb-api.sh raw POST /export/<viewId>/csv`).

For the **full subcommand list**, run `bash scripts/nocodb-api.sh` with no args (the header comment block is the help text), or read [`references/api-reference.md`](references/api-reference.md).

## Discovery pattern

`NOCODB_BASE_ID` is baked into the env. Start from there:

```bash
bash scripts/nocodb-api.sh bases.get $NOCODB_BASE_ID            # base detail incl. sources
bash scripts/nocodb-api.sh tables.ls                            # tables in default base
bash scripts/nocodb-api.sh tables.get <tableId>                 # full column list
bash scripts/nocodb-api.sh bases.swagger $NOCODB_BASE_ID        # per-base OpenAPI dump
```

If the base ever changes, update `NOCODB_BASE_ID` in `/etc/openclaw/main.env` and restart the gateway. Note: the string after `/mcp/<id>` in any NocoDB MCP URL is a SEPARATE identifier from the admin base id — don't confuse the two; only the admin id (`p…`) works against `/api/v2/meta/bases/`.

## Gotchas (have caught me before)

- **Token collision 401s**: `xc-mcp-token` and `xc-token` are different headers. The MCP-token is rejected by `/api/v2/*` with `ERR_AUTHENTICATION_REQUIRED`; the PAT (xc-token) is rejected by `/mcp/*`. Use the right one — this script always sends `xc-token` for the REST API.
- **MCP base id ≠ admin base id**: see above. Confirmed empirically; the published docs are wrong on this.
- **SingleSelect requires BOTH `dtxp` AND `colOptions.options`** — supplying only one returns a vague 400. See quick-start example.
- **LTAR / "Links" columns require parent/child IDs, not table titles**. 400 "ref column not found" almost always means you passed a title.
- **Attachments**: you cannot assign a URL string to an Attachment column directly. Upload first via `attachments.upload[-by-url]`, take the returned array, and assign that array into the record field.
- **Where-clause syntax** is v2 by default: `(field,operator,value)` with `~and`/`~or`/`~not` connectives. Prefix the whole clause with `@` for v3 syntax inside v2.
- **records.create accepts a single object OR an array** for bulk; bulk PATCH/DELETE always take an array of `{id, …}`.
- **Bulk PATCH/DELETE return an ID array, not the {list,pageInfo} envelope.** Don't expect `.list[0]`.
- **`records.ls --limit` is silently clamped to 100 by NocoDB Cloud.** A single page is ≤100 rows regardless of the `--limit` you pass. To read or aggregate a whole table, paginate until `pageInfo.isLastPage` (or an empty page), advancing `--offset` by the rows actually returned — never treat a short page as "all rows." See the Aggregations section for the loop. (This silent truncation broke company-finder dedupe on 2026-06-12; fixed in #510.)

## Authoritative full reference

[`references/api-reference.md`](references/api-reference.md) has the complete endpoint catalog, every gotcha, the ID-prefix legend (`w…`/`p…`/`m…`/`v…`/`c…`), and the per-base swagger discovery path.

## Scope and authorization

This skill lives under `workspaces/cmo/skills/muso-nocodb/`, so only cmo's agent runtime resolves it via the `muso-nocodb` trigger. The REST PAT (`NOCODB_API_TOKEN`) is workspace-level-owner of the **marketing** workspace only — it cannot touch other Muso bases.

If the PAT is ever compromised: revoke at NocoDB → Account Settings → API Tokens, then regenerate, update `/etc/openclaw/main.env`, and restart `openclaw-gateway-main`.
