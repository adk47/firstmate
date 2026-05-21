# scripts/intercom/

One-off Intercom audit / research scripts. All read-only.

## audit-credit-claim-attachments.sh

Phase 0 deliverable for the Caroline `credit-claim-with-proof` Lobster
pipeline. Queries Intercom for conversations in the last N days
matching credit-claim keywords, walks each conversation's parts, counts
user-side attachments, and emits a CSV + summary JSON.

### Run

```bash
# 1. Pull the token from the gateway config (or set INTERCOM_TOKEN directly)
export INTERCOM_TOKEN="$(jq -r '.channels.intercom.accounts.default.token' openclaw-edge.json)"

# 2. (Optional) Tune the lookback window or cap
export DAYS_BACK=90       # default
export MAX_CONVS=500      # cap on conversations to inspect

# 3. Run from the repo root
scripts/intercom/audit-credit-claim-attachments.sh
```

Output lands in `./out/intercom-audit-YYYYMMDD/`:

- `conversations.csv` — one row per conversation (TAB-separated; commas appear in body snippets)
- `summary.json` — aggregate stats: attachment rate, content-type frequency, size buckets
- `conversations/<id>.json` — raw Intercom API response per conversation (for offline re-analysis)
- `audit.log` — progress + errors

### Where to run

Two places work:

- **node-8 (hydra)** — token already lives in `/opt/hydra/openclaw-edge.json`. Cleanest.
- **Anywhere with the token + jq + curl** — laptop is fine for a one-shot. Network access to `api.intercom.io` required.

### Safety

- Read-only: only `POST /conversations/search` (search is a POST in Intercom) and `GET /conversations/{id}`. No writes.
- Rate-limited: 250 ms between requests by default. Intercom's published limit is 1000 requests/minute; we're well under.
- Resumable: per-conversation JSON is cached in `conversations/`, so re-runs skip already-fetched conversations.
- Token-safe: token is read once into an env var, never echoed to stdout/stderr or logs.

### Tuning

| Env var | Default | Purpose |
|---|---|---|
| `INTERCOM_TOKEN` | (required) | Bearer token. From `openclaw-edge.json` `channels.intercom.accounts.default.token`. |
| `DAYS_BACK` | 90 | Lookback window. |
| `MAX_CONVS` | 500 | Hard cap on conversations to inspect. Search may return more; we stop after this. |
| `API_VERSION` | 2.11 | Intercom-Version header. |
| `SLEEP_MS` | 250 | Sleep between API calls. Lower at your own risk. |
| `OUT_DIR` | `./out/intercom-audit-YYYYMMDD` | Output directory. |

### What the output answers

See `docs/credit-claim-proof-audit-2026-05-19.md` for the full
methodology + decision tree that the summary stats feed into.

Short version:

- **Volume.** `summary.json:candidate_conversations` and
  `conversations_with_user_attachments` — if the second is < 2/week
  averaged, the whole project may not be worth the engineering.
- **File mix.** `summary.json:content_type_frequency` — sets the
  Phase 2 pipeline's allowlist.
- **Size budget.** `summary.json:size_buckets` — sets the per-file
  and total-payload caps.
- **Customer framings.** Eyeball `conversations.csv:first_user_body_snippet`
  for the common phrasings; these inform Caroline's classifier prose.
