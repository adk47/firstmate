---
name: muso-nocodb
description: |
  NocoDB Cloud REST API (v2) — full schema + data control plane for the
  marketing workspace's B2B-ADS-intelligence base, through the gated, audited
  `muso nocodb` provider commands.

  Use when: doing any operation against the B2B-ADS-intelligence base —
  record CRUD (create/read/update/delete/link), schema (tables, columns,
  views, filters, sorts), hooks, attachments, comments, shared views.
  This skill is cmo's single layer to NocoDB; there is no MCP fallback.

  Triggers: "nocodb", "create table", "add column", "single select",
  "kanban view", "nocodb webhook", "upload attachment", "shared view",
  "duplicate base", "B2B ADS intelligence", "marketing CRM base"
compatibility: |
  Main gateway on node-8 only. Driven by the `muso` host binary —
  `muso nocodb …` (see muso-cli SKILL.md for the output/exit-code contract and
  the policy gates). Requires the muso binary that ships the `nocodb` command
  (v0.3.0+); until that release is pinned by deploy.sh, use the legacy wrapper
  fallback (`bash scripts/nocodb-api.sh <same-subcommand>`) — see the soak
  banner. The xc-token PAT (`nc_pat_…`) rides `NOCODB_API_TOKEN` (the same var
  the wrapper uses); NOCODB_BASE_ID/NOCODB_API_URL default to the
  B2B-ADS-intelligence base, loaded from /etc/openclaw/main.env.
depends-on:
  - muso-cli
metadata:
  version: "1.1"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# muso-nocodb — NocoDB via the gated `muso nocodb` provider

This skill is cmo's single layer to NocoDB. Drive record CRUD, schema, and the
long tail through **`muso nocodb …`** — one authenticated, policy-gated, audited
path that routes the full-scope `nc_pat_` token through the same gate as the
admin API: reads are ungated, writes carry requester attribution, and
destructive schema ops require approval.

## ⚠️ Soak banner — read before your first call

`muso nocodb` is **merged on muso-cli `main` but only callable once the binary
that ships it (v0.3.0+) is pinned by `deploy.sh` and deployed on node-8.** Until
then:

- **Fallback:** every `muso nocodb <verb>` below has the exact legacy wrapper
  equivalent `bash scripts/nocodb-api.sh <verb>` (the command map shows both).
  If `muso nocodb …` errors with `unknown command "nocodb"`, the released binary
  predates the command — use the wrapper for now.
- **company-finder** already routes NocoDB through `muso` behind
  `USE_MUSO_CLI=1` (dark, default off) — same cutover, code side.
- **`attachments.upload` has no `muso` path** (it is multipart to
  `/storage/upload`; `muso nocodb raw` sends JSON bodies only). That one op
  **stays on the wrapper** indefinitely — see Attachments below.

## Defaults

Preconfigured for the **B2B-ADS-intelligence** base. Env (from `/etc/openclaw/main.env`):

```
NOCODB_API_URL=https://app.nocodb.com/api/v2   # wrapper only; muso uses host + full /api/v2 paths
NOCODB_BASE_ID=p11hvpwapu4hv0x                 # B2B-ADS-intelligence (muso: --base default)
NOCODB_WORKSPACE_ID=w8fofvl1                   # marketing
NOCODB_API_TOKEN=nc_pat_***                    # full-scope PAT, marketing@muso.ai (xc-token)
```

Retarget any command with `--base <baseId>`. Preview any write with `--dry-run`
(prints the resolved, redacted request without sending; reads still execute).

## Policy gates (what writes require)

`muso nocodb` puts the previously-ungated `nc_pat_` token behind the gate:

| Tier | Operation | What you must pass |
|---|---|---|
| read | list / get / count / tables list-get / whoami | nothing |
| write | record create/update, table/column create | `--requester <email>` (agents: auto-injected as `MUSO_REQUESTER` per conversation — do **not** hardcode it) |
| dangerous | bulk record **delete** | `+ --yes` |
| approval | delete a **table / column / base** (`tables delete`, `raw DELETE /api/v2/meta/...`) | `+ --confirmed-by <approver> --approval-ref <slack-ts>` |

## Command map (muso ⇄ wrapper)

| Operation | `muso nocodb …` | wrapper fallback |
|---|---|---|
| identity | `whoami` | `auth.me` |
| list tables | `tables list [--base <p…>]` | `tables.ls` |
| get table + columns | `tables get --table <m…>` | `tables.get <m…>` |
| create table | `tables create --base <p…> --data <json>` | `tables.create <p…> <json>` |
| delete table | `tables delete --table <m…> --confirmed-by … --approval-ref …` | `tables.delete <m…>` |
| list records | `records list --table <m…> [--where --fields --sort --limit --offset]` | `records.ls <m…> …` |
| get record | `records get --table <m…> --id <rid>` | `records.get <m…> <rid>` |
| count | `records count --table <m…> [--where '(…)']` | `records.count <m…> …` |
| create record(s) | `records create --table <m…> --data <obj-or-array>` | `records.create <m…> <json>` |
| update record(s) | `records update --table <m…> --data <array>` | `records.update <m…> <json>` |
| delete record(s) | `records delete --table <m…> --data <array> --yes` | `records.delete <m…> <json>` |
| anything else | `raw <METHOD> /api/v2/… [--data <json>]` | `raw <METHOD> <pathAfterApiV2>` |

## Quick start

```bash
# Identity + scope sanity
muso nocodb whoami

# Tables and their schemas
muso nocodb tables list
muso nocodb tables get --table m9vsbijhrr9ddeu        # Contacts Intelligence

# Create a new table (two columns)
muso nocodb tables create --base p11hvpwapu4hv0x --data '{
  "table_name":"campaigns","title":"Campaigns",
  "columns":[
    {"column_name":"title","title":"Title","uidt":"SingleLineText","pv":true},
    {"column_name":"sent_at","title":"Sent At","uidt":"DateTime"}
  ]}'

# Read / write records
muso nocodb records get   --table m9vsbijhrr9ddeu --id 42
muso nocodb records create --table m9vsbijhrr9ddeu --data '{"Name":"Acme","Email":"hi@acme.com"}'
muso nocodb records update --table m9vsbijhrr9ddeu --data '[{"Id":12,"Status":"open"}]'
```

## Long tail via `muso nocodb raw`

Columns, views, filters, sorts, hooks, shared views, duplicate-base, CSV export
— the ops without a typed command — go through `raw <METHOD> <path>` with the
**full wire path** (`/api/v2/meta/...`); the same policy tiers apply (e.g.
`DELETE /api/v2/meta/columns/*` is approval-tier).

```bash
# Add a SingleSelect column (BOTH dtxp AND colOptions.options required — see gotchas)
muso nocodb raw POST /api/v2/meta/tables/<m…>/columns --data '{
  "column_name":"status","title":"Status","uidt":"SingleSelect",
  "dtxp":"'\''new'\'','\''open'\'','\''closed'\''",
  "colOptions":{"options":[
    {"title":"new","color":"#cfdffe","order":1},
    {"title":"open","color":"#d1f7c4","order":2},
    {"title":"closed","color":"#ffdce5","order":3}]}}'

# Create a Kanban view grouped by status
muso nocodb raw POST /api/v2/meta/tables/<m…>/kanbans --data '{"title":"Pipeline","fk_grp_col_id":"<statusColumnId>"}'

# Per-base OpenAPI dump (self-discovery) + base detail
muso nocodb raw GET /api/v2/meta/bases/p11hvpwapu4hv0x/swagger.json
muso nocodb raw GET /api/v2/meta/bases/p11hvpwapu4hv0x
```

The wrapper's no-arg help (`bash scripts/nocodb-api.sh`) and
[`references/api-reference.md`](references/api-reference.md) list every wire path
for the long tail.

## Attachments (wrapper-only)

`muso nocodb` cannot upload attachments — it is a multipart POST to
`/storage/upload`, which `raw` (JSON only) can't express. **Upload via the
wrapper, assign via muso:**

```bash
ATT=$(bash scripts/nocodb-api.sh --raw attachments.upload ./logo.png)
muso nocodb records update --table <m…> --data "[{\"Id\":12,\"Logo\":$ATT}]"
```

## Aggregations (client-side)

NocoDB Cloud exposes no public REST aggregation beyond `count`. For
sums/averages/group-by, fetch the rows and aggregate in `jq`.

> ⚠️ **NocoDB Cloud silently clamps a single list to 100 rows** regardless of
> `--limit`. A lone `records list` aggregated in `jq` computes over ≤100 rows
> **silently** the moment the (filtered) set exceeds 100. To aggregate a whole
> table you MUST paginate until `pageInfo.isLastPage`.

```bash
# Filtered count (server-side — exact, no pagination)
muso nocodb records count --table m9vsbijhrr9ddeu --where "(Status,eq,Follow Up 2)"

# Fetch ALL rows for the given --fields as one JSON array. Loops until
# pageInfo.isLastPage (or an empty page), advancing --offset by the rows
# actually returned, so the 100-row clamp is harmless (same logic as
# company-finder's fetch_table, the merged #510 fix). The `jq .data` peels
# muso's one-object {data:…} envelope back to the raw {list,pageInfo} body.
# Trailing flags (e.g. --where '(…)') forward to every page.
nocodb_fetch_all() {  # usage: nocodb_fetch_all <tableId> <fields> [extra records list flags…]
  local tid="$1" fields="$2"; shift 2
  local offset=0 resp chunk n pages=()
  while :; do
    resp=$(muso nocodb records list --table "$tid" \
             --fields "$fields" --limit 100 --offset "$offset" "$@" --json) || return 1
    resp=$(jq -c '.data' <<<"$resp")
    chunk=$(jq -c '.list' <<<"$resp"); n=$(jq 'length' <<<"$chunk")
    pages+=("$chunk")
    [[ "$(jq -r '.pageInfo.isLastPage == true' <<<"$resp")" == true || "$n" -eq 0 ]] && break
    offset=$((offset + n))
  done
  printf '%s\n' "${pages[@]}" | jq -cs 'add // []'
}

# Group-by distribution over the FULL table
nocodb_fetch_all m9vsbijhrr9ddeu "Status" \
  | jq '[.[].Status] | group_by(.) | map({status: .[0], n: length}) | sort_by(.n) | reverse'
```

For very large tables prefer a narrow `--where` (paginate fewer rows) or a Grid
view's shared CSV export via `muso nocodb raw POST /api/v2/export/<viewId>/csv`.

## Discovery pattern

`NOCODB_BASE_ID` is baked into the env. Start there:

```bash
muso nocodb raw GET /api/v2/meta/bases/p11hvpwapu4hv0x     # base detail incl. sources
muso nocodb tables list                                    # tables in the default base
muso nocodb tables get --table <m…>                        # full column list
muso nocodb raw GET /api/v2/meta/bases/p11hvpwapu4hv0x/swagger.json   # per-base OpenAPI dump
```

If the base ever changes, update `NOCODB_BASE_ID` in `/etc/openclaw/main.env`
and restart the gateway. Note: the string after `/mcp/<id>` in any NocoDB MCP
URL is a SEPARATE identifier from the admin base id — don't confuse the two;
only the admin id (`p…`) works against `/api/v2/meta/bases/`.

## Gotchas (have caught me before)

- **Token collision 401s**: `xc-mcp-token` and `xc-token` are different headers.
  The MCP-token is rejected by `/api/v2/*` with `ERR_AUTHENTICATION_REQUIRED`;
  the PAT (xc-token) is rejected by `/mcp/*`. The provider sends `xc-token`.
- **MCP base id ≠ admin base id**: see Discovery. Confirmed empirically; the
  published docs are wrong on this.
- **SingleSelect requires BOTH `dtxp` AND `colOptions.options`** — supplying one
  returns a vague 400. See the raw column example.
- **LTAR / "Links" columns require parent/child IDs, not table titles**. 400
  "ref column not found" almost always means you passed a title.
- **Attachments**: you cannot assign a URL string to an Attachment column
  directly. Upload first (wrapper — see Attachments), take the returned array,
  and assign that array into the record field.
- **Where-clause syntax** is v2 by default: `(field,operator,value)` with
  `~and`/`~or`/`~not` connectives. Prefix the whole clause with `@` for v3.
- **records create accepts a single object OR an array** for bulk; bulk
  update/delete always take an array of `{Id, …}`.
- **Bulk update/delete return an ID array, not the {list,pageInfo} envelope.**
  Don't expect `.list[0]`. (Under `muso`, the whole body is wrapped once more as
  `{data: …}` — peel `.data` first, as `nocodb_fetch_all` does.)
- **The single-list 100-row clamp** is silent: to read or aggregate a whole
  table, paginate until `pageInfo.isLastPage` (or an empty page), advancing
  `--offset` by the rows actually returned — never treat a short page as "all
  rows." (This silent truncation broke company-finder dedupe on 2026-06-12;
  fixed in #510.)

## Authoritative full reference

[`references/api-reference.md`](references/api-reference.md) has the complete
endpoint catalog, every gotcha, the ID-prefix legend (`w…`/`p…`/`m…`/`v…`/`c…`),
and the per-base swagger discovery path. The wrapper (`scripts/nocodb-api.sh`)
is the source of truth for exact long-tail wire paths to feed `muso nocodb raw`.

## Scope and authorization

The REST PAT (`NOCODB_API_TOKEN`) is workspace-level-owner of the **marketing**
workspace only — it cannot touch other Muso bases. Routing it through
`muso nocodb` adds requester attribution + a fail-closed audit trail + the
approval gate on destructive schema ops.

If the PAT is ever compromised: revoke at NocoDB → Account Settings → API
Tokens, regenerate, update `/etc/openclaw/main.env`, and restart
`openclaw-gateway-main`.
