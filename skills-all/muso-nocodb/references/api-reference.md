# NocoDB Cloud v2 REST API — Full Reference

Host: `https://app.nocodb.com`
Prefix: `/api/v2/` (except `auth.me` which lives on `/api/v1/auth/user/me`)
Auth header: `xc-token: <nc_pat_...>` (Personal Access Token)

For the wrapper that drives all of this, see [`../scripts/nocodb-api.sh`](../scripts/nocodb-api.sh).

## ID prefix legend

| Prefix | Resource | Example |
|---|---|---|
| `w…` | Workspace | `w8fofvl1` (marketing) |
| `p…` | Base (project) | `p11hvpwapu4hv0x` (B2B-ADS-intelligence) |
| `m…` | Table (model) | `m9vsbijhrr9ddeu` (Contacts Intelligence) |
| `v…` | View | `vw33qq1bqhforq5h` |
| `c…` | Column | `cc8t4kjpsn0w595` |
| `u…` | User | `us8wdwnrce56c4hq` |
| `b…` | Source (per-base datasource) | `b4nbs56exoqxkvp` |

The string after `/mcp/` in the MCP URL (e.g. `nc0hvbud53e8fmrx`) is a **separate** identifier that NocoDB Cloud generates when MCP is enabled on a base. It is not interchangeable with the `p…` base id.

## Per-resource endpoint catalog

### Auth / Workspaces / Bases

| Method | Path | Note |
|---|---|---|
| GET | `/api/v1/auth/user/me` | Sanity check; returns `is_api_token`, `roles`, `api_token_meta.scope` |
| GET | `/meta/workspaces` | Lists the workspaces this PAT can see |
| GET | `/meta/bases/` | Org-admin only; PATs with workspace-only scope get 403 |
| GET | `/meta/bases/{baseId}` | Full base detail incl. sources |
| GET | `/meta/bases/{baseId}/info` | Server build/runtime info |
| GET | `/meta/bases/{baseId}/swagger.json` | **Per-base OpenAPI** — use for self-discovery when you don't know a field name |
| PATCH | `/meta/bases/{baseId}` | Body keys: `title`, `color`, `order`, `meta`. `name` is silently ignored. |
| DELETE | `/meta/bases/{baseId}` | Tombstones the base |
| POST | `/meta/duplicate/{baseId}` | Duplicate base |

### Tables

| Method | Path |
|---|---|
| GET | `/meta/bases/{baseId}/tables` |
| GET | `/meta/tables/{tableId}` (includes `columns` + `columnsById` map) |
| POST | `/meta/bases/{baseId}/tables` — body `{table_name, title, columns: [...]}` |
| PATCH | `/meta/tables/{tableId}` |
| DELETE | `/meta/tables/{tableId}` (returns `true`) |
| POST | `/meta/tables/{tableId}/reorder` — body `{order: N}` |
| POST | `/meta/duplicate/{baseId}/table/{tableId}` |

### Columns / Fields

Columns are always added at the **table** level. View column endpoints only show/hide existing columns.

| Method | Path | Note |
|---|---|---|
| POST | `/meta/tables/{tableId}/columns` | Single create |
| POST | `/meta/tables/{tableId}/columns/bulk` | Bulk create/update/delete (use `{op, columns:[...]}`) |
| PATCH | `/meta/columns/{columnId}` | Edit title/uidt/options |
| DELETE | `/meta/columns/{columnId}` | |
| POST | `/meta/columns/{columnId}/primary` | Set as primary value field |

**Critical `uidt` values and what they need in `colOptions`:**

| `uidt` | Required body extras |
|---|---|
| `SingleLineText`, `LongText`, `Email`, `URL`, `PhoneNumber`, `Number`, `Decimal`, `Percent`, `Currency`, `Rating`, `Checkbox`, `Date`, `DateTime`, `Time`, `Year`, `Duration`, `Barcode`, `QRCode`, `JSON` | Nothing special; `column_name` + `title` + `uidt` is enough |
| `SingleSelect`, `MultiSelect` | **Both** `dtxp` (comma-quoted options string) **and** `colOptions.options[]` |
| `Formula` | `colOptions: {formula_raw: "<expr>"}` — passing `formula:` plain text 400s |
| `Lookup`, `Rollup` | `colOptions: {fk_relation_column_id, fk_lookup_column_id|fk_rollup_column_id, rollup_function}` — IDs, not names |
| `Links` / `LinkToAnotherRecord` | `colOptions: {type:"mm"|"hm"|"bt", parentId, childId}` — IDs, not titles |
| `Attachment` | nothing; assign values via `/storage/upload` returned array |
| `User`, `CreatedBy`, `LastModifiedBy` | system or extra `colOptions.is_multi` |

### Views

Per-type create endpoints — `<type>` is one of `grids`, `forms`, `galleries`, `kanbans`, `maps`, `calendars`:

| Method | Path |
|---|---|
| GET | `/meta/tables/{tableId}/views` |
| POST | `/meta/tables/{tableId}/{type}` (create) |
| GET / PATCH | `/meta/{type}/{viewId}` |
| PATCH | `/meta/views/{viewId}` (cross-type update of view meta) |
| DELETE | `/meta/views/{viewId}` |
| POST | `/meta/views/{viewId}/show-all` |
| POST | `/meta/views/{viewId}/hide-all` |
| GET / POST | `/meta/views/{viewId}/columns` (visibility) |
| PATCH | `/meta/views/{viewId}/columns/{columnId}` |

### Filters / Sorts

| Method | Path |
|---|---|
| GET / POST | `/meta/views/{viewId}/filters` |
| PATCH / DELETE | `/meta/filters/{filterId}` |
| POST | `/meta/filters/{filterGroupId}/children` (nested groups) |
| GET / POST | `/meta/views/{viewId}/sorts` |
| PATCH / DELETE | `/meta/sorts/{sortId}` |

### Records (data API)

| Method | Path | Notes |
|---|---|---|
| GET | `/tables/{tableId}/records` | Params: `viewId`, `fields`, `sort`, `where`, `offset`, `limit`, `nested[...]` |
| GET | `/tables/{tableId}/records/{recordId}` | |
| GET | `/tables/{tableId}/records/count` | `where=` supported |
| POST | `/tables/{tableId}/records` | Object or array (bulk) |
| PATCH | `/tables/{tableId}/records` | **Always an array** of `{Id, …fields}` |
| DELETE | `/tables/{tableId}/records` | Array of `{Id}` |
| GET / POST / DELETE | `/tables/{tableId}/links/{linkFieldId}/records/{recordId}` | Link/unlink LTAR — body is array of target record IDs |

#### Where-clause syntax (v2)

```
Basic:        (field,op,value)
No-value:     (field,op)
Date subop:   (field,op,sub_op[,value])
Multi-value:  (field,op,v1,v2,v3)
Connectives:  ~and  ~or  ~not   (with tilde)
Group:        ((a)~or(b))~and(c)
```

Operators: `eq, neq, like, nlike, in, gt, lt, gte, lte, btw, nbtw, blank, notblank, null, notnull, empty, notempty, checked, notchecked, allof, anyof, nallof, nanyof`. Date sub-operators: `today, tomorrow, yesterday, oneWeekAgo, oneWeekFromNow, oneMonthAgo, oneMonthFromNow, pastWeek, pastMonth, pastYear, nextWeek, nextMonth, nextYear, daysAgo, daysFromNow, exactDate, pastNumberOfDays, nextNumberOfDays, isWithin`.

Prefix the whole `where` with `@` for v3-style inside v2: `where=@("Title",not,blank)`.

### Attachments

| Method | Path | Body |
|---|---|---|
| POST | `/storage/upload?path=<folder>` | multipart `file=@…` |
| POST | `/storage/upload-by-url` | JSON array `[{url, fileName}]` |

The response is an array of attachment objects (with `url`, `title`, `mimetype`, `size`, optionally `signedUrl`, `path`, `signedPath`). **Assign that array directly into an Attachment column** when calling `records.create`/`records.update`.

### Webhooks / Hooks

| Method | Path |
|---|---|
| GET / POST | `/meta/tables/{tableId}/hooks` |
| PATCH / DELETE | `/meta/hooks/{hookId}` |
| POST | `/meta/tables/{tableId}/hooks/test` |
| GET | `/meta/tables/{tableId}/hooks/samplePayload/{event}/{operation}/v2` |
| GET | `/meta/hooks/{hookId}/logs` |
| GET / POST | `/meta/hooks/{hookId}/filters` |

There is **no** `GET /meta/hooks/{hookId}` — fetch via the list endpoint and filter client-side. Same shape for filters and sorts.

### Comments

| Method | Path |
|---|---|
| GET | `/meta/comments?row_id=<rowId>&fk_model_id=<tableId>` |
| POST | `/meta/comments` |
| PATCH | `/meta/comment/{commentId}` |
| DELETE | `/meta/comment/{commentId}` |
| GET | `/meta/comments/count` |

### Shared views

| Method | Path |
|---|---|
| POST / GET / PATCH / DELETE | `/meta/views/{viewId}/share` |

Public consumer endpoints (no auth): `/api/v2/public/shared-view/{uuid}/rows`, `…/aggregate`, `…/groupby`, `…/nested`, `…/meta`.

### Per-base API tokens (PAT manager — base-scoped only)

| Method | Path |
|---|---|
| GET / POST | `/meta/bases/{baseId}/api-tokens` |
| DELETE | `/meta/bases/{baseId}/api-tokens/{tokenId}` |

Workspace/account-level PAT creation is UI-only on Cloud.

### Export / misc

| Method | Path |
|---|---|
| POST | `/export/{viewId}/csv` |
| POST | `/export/{viewId}/xlsx` |

## Gotchas (verified, not theoretical)

1. **`xc-mcp-token` rejected by `/api/v2/*`** with 401 `ERR_AUTHENTICATION_REQUIRED`. The MCP and admin APIs use different tokens with different headers. Tested 2026-05-25.
2. **MCP id ≠ admin base id**: the part after `/mcp/` is a separate NocoDB Cloud identifier. To discover the admin base id, call the MCP's `getBaseInfo` tool, or list workspaces and bases via the admin REST.
3. **PAT scope is enforced per-token, not per-user**: a workspace-owner can create a narrow-scope PAT that fails `tableCreate` even though the user role allows it. Always confirm at PAT-creation time with all scopes set to Read+Write if you want full surface.
4. **PATCH bulk records always takes an array** of `{Id, fields…}`. Single-object body returns a confusing 400 about missing IDs.
5. **`column_name` is sanitized** (spaces/underscores stripped on some versions — see [#9438](https://github.com/nocodb/nocodb/issues/9438)); always set `title` explicitly for the display name.
6. **`PATCH /meta/bases/{baseId}` ignores `name`** (Airtable-ism) and silently returns the unchanged object with 200. Use `title`.
7. **Workspace detail / workspace bases endpoints often 401** even for workspace-owners on NocoDB Cloud — undocumented limitation. Use `/meta/bases/{baseId}` once you have the base id.
8. **`auth.me` is `/api/v1/…`, not `/api/v2/…`** — there is no `/api/v2/auth/user/me`.
9. **Apostrophe / quote escaping in `dtxp`** matters: pass `"'option1','option2'"` (single-quoted options inside the JSON string).
10. **Empty bulk response shape**: bulk POST returns `[{Id: N}, …]`, not the `{list, pageInfo}` envelope of GET. Don't try to read `.list[0]`.

## Self-discovery

If you don't know a field name or the exact shape of a request body, fetch the per-base swagger:

```bash
bash scripts/nocodb-api.sh bases.swagger p11hvpwapu4hv0x | jq '.paths | keys[]' | head -40
bash scripts/nocodb-api.sh bases.swagger p11hvpwapu4hv0x | jq '.paths["/api/v2/meta/tables/{tableId}/hooks"].post'
```

The swagger is authoritative for the current base state and includes the exact `uidt` enum the server is willing to accept.
