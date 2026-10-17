---
name: muso-fraud-cases
description: |
  Read-only fraud case knowledge base: closed and open fraud investigations as one markdown
  file per case, plus a query script. Use before reasoning about a suspected fraud pattern, to
  find precedent by vector, outcome or signal.

  Triggers: "fraud precedent", "have we seen this fraud before", "fraud case", "similar fraud case"
metadata:
  version: "1.0"
---

# Muso Fraud Cases

Case files in `cases/`, one per investigation. Query them; do not edit them from an agent run.

```bash
bash scripts/fraud-cases-query.sh --vector credit_self_add
bash scripts/fraud-cases-query.sh --outcome confirmed_fraud --signal role_inflation
bash scripts/fraud-cases-query.sh --validate
```

Output is tab-separated: id, vector, outcome, one-line summary, path. `--validate` checks every case file; any query also refuses a corpus with an invalid case. The script is read-only: jq/grep only, no network, no DB, no writes.

`INDEX.md` is generated, never hand-edited: `bash scripts/fraud-cases-query.sh --index > INDEX.md`. A bats test fails when it is stale.

## Case format

`cases/<YYYY-MM-DD>-<slug>.md`. Frontmatter is one `key: <JSON value>` per line between two `---` lines (valid YAML, and one row per file for a later Postgres import):

| key | value |
|---|---|
| `id` | equals the filename stem |
| `title` | one line |
| `source` | `repo_mined` (seed mined from repo docs) or `notion` (imported from the Notion Fraud Cases DB) |
| `date_opened`, `date_closed` | `YYYY-MM-DD`; `date_closed` may be `null` |
| `vector` | one of `claim_impersonation`, `credit_self_add`, `role_inflation`, `muso_only_credits`, `dedupe_abuse`, `removal_social_engineering`, `referral_abuse`, `payment_fraud` |
| `signals` | snake_case tokens; use the detector factor names where they apply |
| `evidence_sources` | repo paths or query names, non-empty |
| `outcome` | `confirmed_fraud`, `false_positive` or `inconclusive` |
| `actions_taken` | list |
| `detector_factors_that_fired` | subset of `role_inflation`, `source_quality`, `establishment`, `velocity`, `backend_hard_reject`, `muso_only` |
| `what_would_have_caught_it_earlier` | string; for a thin case, say what evidence is missing |
| `related_profiles` | ids only |

## Rules

- **No customer PII** in any case: ids and counts, never names, emails or identity documents. Validation rejects email addresses and phone-number-shaped strings only. **It cannot detect names or document text**: a human reviewer must check every new case for those before merge.
- **Additive.** Litigation hold: never delete or rewrite a closed case. Correct it with a new dated section in the same file.
- **Do not invent outcomes.** A pattern with no recorded result is `inconclusive`. An honest thin case beats a fabricated rich one.
