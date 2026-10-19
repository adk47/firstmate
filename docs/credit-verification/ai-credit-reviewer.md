# AI credit reviewer + approval auditor

> Added 2026-10-11 (captain: "we can't let bad credits into the system"; "need a monitor that closely watches credit approvals on our side to check if they should have been given ... with AI and internet searches"). The full design, labelled-set precision results and rollout live in the firstmate task record `data/ai-credit-validator-h1/design.md`. This page is the operator's view.

## What it is

`scripts/credit-review.py` with its package `scripts/credit_review/` (stdlib Python, no pip). It is **read-only on credits**: the admin client issues GETs only, through `muso-admin-api.sh`, so the service credentials stay in the gateway env.

| Cron (`cron-jobs.json`) | Command | Output |
|---|---|---|
| `credit-approval-auditor-hourly` (:45) | `credit-review.py audit` (approvals of the last 90 min, or since the previous successful run minus 15 min if earlier, so failed runs leave no gap; at most 24 h back, and an older gap raises a `N minutes not audited` alert; the scan reads every list page back to the window start, never a page cap that would drop the oldest approvals; rows are processed oldest first in chunks of 100 and recorded per chunk; no chunk starts unless the longest chunk so far still fits before the 1800 s deadline and no model call starts after it, so the run returns and prints its alerts (sampled approvals left unjudged for time are recorded and reported in a `CREDIT-AUDIT NOTE`; a big track whose model check the deadline cut is NOT recorded, its chunk does not advance `audit_last_run`, and the next run model-checks it), and an early stop alerts and advances `audit_last_run` only to the last finished chunk; big tracks get the model budget first across the whole run, sampled non-big rows are judged after the last chunk with what is left) | one `CREDIT-AUDIT ALERT:` line per CONTRADICTED big-track approval, per approver-identity problem, and per profile burst (below), else `NO_REPLY` → #credit-verification |
| `credit-approval-audit-digest-daily` (08:15) | `credit-review.py digest` | all SUSPECT / CONTRADICTED of the last 24 h |
| `credit-approval-audit-metrics-weekly` (Mon 08:20) | `credit-review.py metrics` | verdict counts, $/1k, lower-bound precision |
| `credit-review-shadow-4h` (:15 every 4h) | `credit-review.py review --phase shadow` | nothing (ledger only) |

**Cost controls** (Fable credit-AI report, 2026-10-14):
- **Big track = the IDP's rule** (`_is_big_track`; definition under *How a verdict is made*). Before, an unlinked artist made a pop-0 track big; that was 35 of 89 model calls on 10-14.
- **Profile batching**: non-big claims of one profile go to the model together, up to 6 per call, each answered by a local alias (`c1`..`c6`) that `judge_many` maps back to the request, so internal request ids never reach the provider (a claim the answer leaves out is a model error for that claim, never a pass). **Big tracks are always one call per claim**: in a same-day A/B on the labelled set, batching big tracks lost 11 contradictions on big tracks, the rows that raise alerts.
- **Audit/shadow dedupe**: the shadow reviewer's approved sample skips approvals the hourly audit model-checked in the last 24 h.
- **Search-junk filter**: the web search excludes `muso.ai`, `soundbetter.com`, `pandora.com`, `imdb.com`, `mobygames.com`, the five most-cited domains in the live ledger that never supplied a usable finding (xAI native search takes at most 5). Override: `CREDIT_REVIEW_WEB_EXCLUDE` (comma-separated, empty = none). SoundBetter never counts as independent evidence even if the override lets it back in (see *How a verdict is made*).
- `credit-review.py eval --batch` evaluates the production batching path.

**Profile burst alert.** One profile with **≥ 10 SUSPECT/CONTRADICTED approvals, or ≥ 20 approvals of any verdict, within any 2 h window** gets one `CREDIT-AUDIT ALERT: burst of approvals on one profile - <name> (<profile id>) ...` line. Every 2 h window ending since the previous check (state key `burst_last_check`, at most 24 h back) and up to the audit's own watermark `audit_last_run` (so approvals not yet recorded, after an early stop or made during the run, are judged next run) is judged, so approvals that a catch-up run records late, or a burst split across two hourly runs, still alert. Each request counts once, by its latest audit verdict. Approvals parked because their trusted raw credits could not be read count toward the ≥ 20 threshold (never as SUSPECT) and show as `N not yet auditable` in the alert, and the check is held back to the earliest of them (a row parked for more than 24 h no longer holds it) so their windows are judged again once they are recorded. A profile is alerted again only for a window holding an approval newer than every approval already alerted (state key `burst_alerted_through:<profile id>`), so an alert never repeats for approvals already alerted while a continuing burst with new approvals alerts again. Why: on 2026-10-14 one profile filed 421 requests in under 2 h, the validator approved 35, and the audit marked 25 SUSPECT in one hour without a single alert, because row alerts only fire for a CONTRADICTED big track.

**Cron output is Slack output.** openclaw posts a command cron's stdout **and** stderr (`stdout: … / stderr: …`), so the CLI writes nothing to stderr: progress lines and Python warnings go to `/var/lib/hydra/credit-review/run.log` (`$CREDIT_REVIEW_LOG`; rotated to `.1` at 5 MB; stderr is used only on an interactive terminal). A quiet run prints exactly `NO_REPLY` (silent); a run with something to act on prints only its alert lines; an admin-API outage or an unexpected crash prints one plain line (no exception text) and leaves the details in the log.

Ledger: `/var/lib/hydra/credit-review/ledger.sqlite3`. Tables:
- `reviews`: every verdict, with the PII-free evidence the model saw, the model's answer, and (ledger only, never sent to the model) the claimant names and domains used to exclude claimant-controlled web pages, so `rescore` replays the same exclusion.
- `rereview_queue`: CONTRADICTED approvals waiting for a human.
- `evidence_retry`: approvals whose trusted raw credits could not be read. They are **not** recorded as reviewed; every run retries them from the stored snapshot (also after they leave the 90-min window). The first failure raises a `CREDIT-AUDIT ALERT`, and the daily digest shows the parked count until it drains.
- `state`

## How a verdict is made

1. **Catalog evidence (always, free).** For each claimed role:
   - Inputs: the track's raw credits from Spotify / Tidal / MLC / Jaxsta (`muso` rows never count), the catalog track (`GET /admin/track/<id>`: popularity and artists, each artist's catalog popularity from `GET /admin/profile/<id>`), plus the profile's identity anchors, velocity, and the approver record (`metadata.approval`, core-backend #10307).
   - Approver identity: an agent approval alerts unless it comes from a registered automation's own account (`KNOWN_AGENT_APPROVERS` in `policy.py`: `agent-credit-decider@muso.ai` = credit-trust-decide, `agent-uvn-cron@muso.ai` = uvn-under30) while that automation is `approved: true` in `policies/credit-approval-automation.json`. Even then it alerts (`registered automation approval broke a rule`, naming the automation and the rule) when the row carries a validator `reject_*` rule or a validator conflict, is a big track without trusted-source confirmation, claims an editorial role without a trusted credit for the claimant, or was marked documentation-required by the decider (apply mode) and approved without the proof id the decider recorded on its own `decisions` row (uvn-under30 has no proof source, so its approval of such a row always alerts). The `reject_*` check is `policy.validator_rejected_rules`, the same predicate the decider uses to hold those rows. Past 10 rule-break lines the audit adds one `... and N more` line with the total.
   - A failed velocity, catalog-track or claimant-profile read is an evidence error (`evidence_errors` flag), never zero requests, a small track or "no claimant links". While the claimant profile is unreadable no web evidence can confirm.
   - Velocity's big-track share reads the catalog for at most 50 of the profile's distinct tracks of the week: past that, an evenly spaced sample from oldest to newest (submission order cannot steer it), with `velocity_counts_are_a_floor_or_sample` set and `velocity_big_share_sample_tracks` / `velocity_distinct_tracks_7d` recorded.
   - A one-person role (mixing/mastering/immersive/remaster) that a trusted source credits to someone else → **CONTRADICTED**.
   - Every role trusted-confirmed → **CONFIRMED**.
2. **Model + web search (behind a flag).** For undecided approvals: every big track plus a stable 10% sample of the rest.
   - Big comes from catalog data only, never the request's client-sourced `spotifyPopularity`: catalog track popularity ≥ 60 (`BIG_TRACK_POPULARITY`), or a *linked* track artist (one that links a catalog profile) with catalog popularity ≥ 90 (`BIG_ARTIST_POPULARITY`), the IDP's `_is_big_track` rule. Unknown track popularity, or an unreadable linked artist, counts as big; a track with no linked artist is decided by its own popularity. Velocity's big-track share uses the same rule.
   - Tool-less OpenRouter calls (`x-ai/grok-4.3`, `web` plugin): one call per big-track request; non-big requests of one profile share a call (profile batching, under *Cost controls*).
   - `--provider codex` ($0, credit-trust T01): the server fetches free sources itself (MusicBrainz by ISRC, Wikipedia) and tool-less Codex on the ChatGPT subscription judges them; a finding counts only if its quoted passage is verbatim in the fetched snapshot. The OpenRouter judge above, with all its switches, is the fallback when nothing can be fetched or Codex is unavailable. See [credit-trust-llm.md](credit-trust-llm.md).
   - Only real search citations count, and only on independent domains, counted once per registrable domain (two subdomains of one site = 1). Never independent: `muso.ai`; any domain in the claimant profile's `links` / `socials` / `rawProfiles[].url` (so a claimant with a Discogs raw profile gets no Discogs confirmation); any host with a label that is the claimant's name ("Real Engineer" → `realengineer.com`, `realengineer.wixsite.com`); user-generated hosting and social platforms (Wix, Blogspot, WordPress.com, Linktree, Instagram, X/Twitter, Facebook, TikTok, YouTube, SoundCloud, Bandcamp, SoundBetter, where a claimant's own page only repeats the claim).
3. **Policy clamps** (`credit_review/policy.py`).
   - A model error holds.
   - "No evidence on an obscure track" is not a flag.
   - The reviewer never recommends approving a big track without trusted corroboration, on a stillfloo-pattern profile, or with any red flag.

## Switches

| Switch | Effect |
|---|---|
| `/etc/hydra/credit-review.disabled` | everything prints `NO_REPLY`, nothing is read |
| `/etc/hydra/credit-review-model.enabled` | **absent = catalog-only (the default).** Present = model + web search on. |
| shared OpenRouter balance < $10 | model skipped (auto top-up keeps the account funded; $10 only stops a runaway at zero), one `CREDIT-AUDIT NOTE` per day |
| `--provider codex` | Codex judges server-fetched sources at $0 and needs no enable file; OpenRouter becomes its fallback. Kill switch for the Codex rung: `/etc/hydra/credit-trust-codex.disabled` |
| `--budget-usd` / `--daily-budget-usd` | per-run / per-UTC-day model spend caps (audit: $2 / $8; review: $1 per run). Model calls run one at a time, each launched only if `spent + (dearest call in the last 7 days, min $0.05)` stays inside the cap, so a run overshoots by at most one call. |

`run_review` stays advisory (it refuses any phase but `shadow` / `advise`). Trust-yet-verify approvals live in a separate, registered automation: `credit-review.py decide` ([credit-trust-decide.md](credit-trust-decide.md)). Nothing here rejects or removes a credit.

## Running it by hand

```bash
python3 /opt/hydra/scripts/credit-review.py audit --window-min 90 --no-model     # catalog-only audit
python3 /opt/hydra/scripts/credit-review.py digest --hours 24
sqlite3 /var/lib/hydra/credit-review/ledger.sqlite3 \
  "select reviewed_at, verdict, track_title, claimed_roles from reviews where mode='audit' and verdict!='CONFIRMED' order by id desc limit 20"
# Labelled-set precision (spends model credit; refuses below the balance floor):
python3 /opt/hydra/scripts/credit-review.py eval --mode audit --models x-ai/grok-4.3 --out /tmp/cr-eval
# Same eval at $0: server-fetched sources judged by tool-less Codex (run as root on node-8):
python3 /opt/hydra/scripts/credit-review.py eval --mode audit --provider codex --models gpt-6.1-sol --out /tmp/cr-eval-codex
# Re-apply the current policy to stored eval ledgers (no API or model calls):
python3 /opt/hydra/scripts/credit-review.py rescore /tmp/cr-eval-ledger.sqlite3
```

Tests: `python3 scripts/tests/test_credit_review.py` (CI: py-tests job).
