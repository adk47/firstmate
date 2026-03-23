# Platform Data Processing Formulas

Comprehensive documentation of all calculation formulas in the platform-data-processing system.

**Source**: [platform-data-processing/docs/formulas](https://github.com/Muso-AI/platform-data-processing/tree/main/docs/formulas)

## How to Update This Document

To refresh this documentation from the source, use `gh` CLI:

```bash
# List all formulas
gh api repos/Muso-AI/platform-data-processing/contents/docs/formulas/Formulas --jq '.[].name'

# Fetch a specific formula (example: Credit Score)
gh api "repos/Muso-AI/platform-data-processing/contents/docs/formulas/Formulas/Credit%20Score%20aad1b33a50b1467882ed0ee1d4558e19.md" --jq '.content' | base64 -d
```

## Formula Index

| Formula | Status | Source URL |
|---------|--------|------------|
| [Credit Score](#credit-score) | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Credit%20Score%20aad1b33a50b1467882ed0ee1d4558e19.md) |
| [Profile Popularity](#profile-popularity) | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Profile%20Popularity%2075525536778e45c7a5d59e36c2bab8d4.md) |
| [Auto Linking & Merging](#auto-linking-and-merging) | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Auto%20linking%20and%20merging%207771875f90ec4d3685e1b8f392623b94.md) |
| [Profile Aggregations](#profile-aggregations) | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Profile%20Aggregations%20a86d5bbc3cf644d5a9372fcd538f0074.md) |
| [Milestones Generation](#milestones-generation) | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Milestones%20Generation%2012e0aeed21ad800e97f9f5092b70bab5.md) |
| [Analytics Cubes](#analytics-cubes) | tuning | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Analytics%20Cubes%20709e212f53be4316a18ad52fbccda7de.md) |
| [Profile Score Charts](#profile-score-charts) | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Profile%20Score%20Charts%20ffa2c013415b4d30afb4e192c8c20156.md) |
| [Rising Entities](#rising-entities) | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Rising%20entities%2052120e6a26b741d4b43cee37ef84a95b.md) |
| [Non-Legit Profiles](#non-legit-profiles-finder) | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Non-legit%20profiles%20finder%20b2b8aa2fed1e4bbb98929a418a589fb5.md) |
| [Analytics History](#analytics-history) | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Analytics%20History%20b3ff2dbada664c4d856b7098336c0993.md) |

### Additional Formulas (not yet documented here)

| Formula | Status | Source URL |
|---------|--------|------------|
| Analytics - track daily computation | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Analytics%20-%20track%20daily%20computation%20df9d661e97094744b72ed74b90c8b979.md) |
| Analytics Links Merge | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Analytics%20Links%20Merge%20b967b75d6ab8416ab5288e176dcb89d9.md) |
| Analytics Search Matching | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Analytics%20Search%20Matching%205aac2768674a4c67b369f930ebabeacb.md) |
| Analytics Send Search for capturing | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Analytics%20Send%20Search%20for%20capturing%20d8ac24ddafd5421b895378663da9222d.md) |
| Audiomack stream stats | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Audiomack%20stream%20stats%2010b0aeed21ad8077b73fdc29d798be83.md) |
| Catalog Profile Collaboration | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Catalog%20Profile%20Collaboration%2011a0aeed21ad80eba55fe304aae7d606.md) |
| Catalog Released/Published With | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Catalog%20Released%20Published%20With%201a10aeed21ad805a8e8edcbfbfc32768.md) |
| Profile Feeds | tuning | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Profile%20Feeds%201dd0aeed21ad8022b15bf33599448096.md) |
| Profile track credits | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Profile%20track%20credits%204ecac0790671466b87348783b96888fd.md) |
| Sitemaps Generation | done | [GitHub](https://github.com/Muso-AI/platform-data-processing/blob/main/docs/formulas/Formulas/Sitemaps%20Generation%200abacca3a11b48e18a1fc5faffcbd3ca.md) |

---

## Credit Score

**Driver**: `src/tools/jobs/industry_processing/drivers/calc/credit_score.py`

Creates a Muso Score for every profile based on their track credits and popularity.

### Popularity to Score Mapping

| Track Popularity | Score Increment |
|------------------|-----------------|
| 0-19 | 1 |
| 20-39 | 2 |
| 40-59 | 4 |
| 60-79 | 16 |
| 80-100 | 32 |

### Formula

1. Get all non-deleted profiles (`artist`, `professional`, `organization`)
2. Join to `catalog_master_credit` → `catalog_track` to get track popularity
3. Calculate `track_score` based on popularity mapping above
4. **Overall Score**:
   - Window sort by popularity DESC, limit 500 tracks
   - SUM(track_score)
5. **By Category**:
   - Map credits to categories via `dict_credit_category_rule` in MongoDB
   - Artist category: limit 300 tracks, multiply score by 5/3
   - Other categories: limit 500 tracks
   - SUM per category

### Category Rules

Categories are dynamically managed in MongoDB `industry.dict_credit_category_rule`:

```json
{
  "category": "Musician - Keys",
  "parent": ["Musician"],
  "child": ["Piano", "Keyboard", "Synthesizer"],
  "profile_type": ["professional"]
}
```

### Output Tables

- `profile_score` - Current scores
- `profile_score_history` - Historical scores (partitioned by date)

---

## Profile Popularity

**Driver**: `src/tools/jobs/industry_processing/drivers/calc/profile_popularity.py`

Converts credit scores to a 0-100 popularity scale using logarithmic normalization.

### Formula

```
popularity = ROUND(LOG(profile_credit_score, 2) / LOG(max_profile_credit_score, 2) * 100, 0)
```

- If result is 0 but credit_score > 0 → set to 1
- If credit_score = 0 → set to 0

### Roster Popularity Boost

Profiles with high-popularity roster members get boosted:

1. Get top 10 roster members by popularity
2. Calculate `roster_popularity = SUM(member_popularity) / 10`
3. Final popularity = `GREATEST(popularity, roster_popularity)`

---

## Auto Linking and Merging

**Drivers**: `src/tools/jobs/industry_processing/drivers/calc/link_*.py`, `merge_*.py`, `create_from_raw_*.py`

Automated deduplication across raw sources (Spotify, Tidal, MLC, Jaxsta, Genius).

### Operations

| Operation | Description |
|-----------|-------------|
| **Merge** | Combine two catalog entities (profile→profile, track→track) |
| **Link** | Connect raw entity to catalog entity |
| **Create from Raw** | Create new catalog entity from raw (profiles only) |

### Profile Matching Rules

| Operation | Name Match | Credit Match |
|-----------|------------|--------------|
| Merge | 80% Levenshtein AND >5 chars | `ln(isrc_intersection)/ln(isrc_count) > 0.5` AND isrc_count between 2-500 |
| Link | 80% Levenshtein AND >5 chars | Same as merge |
| Create | Name doesn't exactly match any existing | Tidal/MLC: 5-500 non-artist credits |

### Track Matching Rules

| Operation | Title Match | Additional |
|-----------|-------------|------------|
| Merge | Lowercase exact match | Duration within 5 sec AND same artists (100%) |
| Link | Lowercase exact match | Duration within 5 sec AND same artists |

### Merge Priority (Who Becomes Main)

**Profiles**:
1. If both in roster → drop (manual review)
2. If only one in roster → that one is main
3. Otherwise: higher ISRC count wins, then earlier ID

**Tracks/Releases**:
1. Higher raw_recording_ids/raw_release_ids count wins
2. Earlier ID as tiebreaker

### Analytics-Assisted Track Merging

Tracks with same artists + title AND Spotify streams within 1% are merge candidates.

---

## Profile Aggregations

**Drivers**: `src/tools/jobs/industry_processing/drivers/calc/profile_*.py`

Calculates derived profile fields displayed in the UI.

### Fields Calculated

| Field | Description |
|-------|-------------|
| `common_credits` | Top 3 credit categories by weighted count |
| `credits_count` | Total credits |
| `recent_credits_count` | Credits added in last 30 days |
| `credits_count_1y` | Credits from tracks released in last 365 days |
| `credits_count_ytd` | Credits from tracks released this calendar year |
| `collaborations_count` | Number of collaborators |
| `child_roles` | All credit roles with counts |
| `top_collaborators` | Top 4 collaborators by track popularity |
| `primary_genre` | Most common genre from artist credits |
| `genres` | All genres with track counts |
| `years_active` | MAX(release_year) - MIN(release_year) |
| `popularity` | 0-100 score |
| `track_popularities` | Track counts by popularity range |

### Common Credits Weighting

```
parent_weight =
  2 if parent='Artist'
  3 if parent='Organizations' AND profile_type='organization'
  0 if parent='Organizations' AND profile_type!='organization'
  1 otherwise

Filter out if: 100 * parent_weight * credit_weight / total_weight < 5%
```

---

## Milestones Generation

**Drivers**: `src/tools/jobs/industry_processing/drivers/calc/milestone_generation*.py`

Streaming achievement tracking for profiles.

### Milestone Thresholds

| Type | Streams | Count Calculation |
|------|---------|-------------------|
| legendary | 10B+ | FLOOR(streams / 10B) |
| diamond | 1B+ | FLOOR(streams / 1B) |
| platinum | 100M+ | FLOOR(streams / 100M) |
| gold | 10M+ | FLOOR(streams / 10M) |
| silver | 1M+ | FLOOR(streams / 1M) |
| bronze | 100K+ | FLOOR(streams / 100K) |
| iron | 10K+ | FLOOR(streams / 10K) |

### Process

1. Get `calc_analytics_cube_track` where period='all'
2. For each profile_id + track_id, calculate type and count from `ce_streams`
3. Compare with previous day - upsert if changed
4. Send SQS notification to Growth for new/upgraded milestones

### SQS Notification Format

```json
{
  "name": "processMilestonesNotifications",
  "args": ["profileId", "2024-08-10"]
}
```

---

## Analytics Cubes

**Status**: tuning

Pre-aggregated analytics for fast querying by time period.

### Periods

- 1 week (1W)
- 4 weeks (4W)
- 12 weeks (12W)
- Year to date (YTD)
- All time

### Metrics Per Period

- Current values (streams, views, shazams, etc.)
- Previous period values
- Delta calculations
- Per-platform breakdowns (Spotify, YouTube, TikTok, etc.)

### Cube Types

| Cube | Granularity |
|------|-------------|
| Track Cube | profile_id + track_id + period |
| Release Cube | profile_id + release_id + period |
| Profile Cube | profile_id + period |

---

## Profile Score Charts

**Drivers**: `src/tools/jobs/industry_processing/drivers/calc/credit_score_charts*.py`

**Schedule**: Weekly, Thursdays

Weekly leaderboards by credit category.

### Tables

**CreditScoreChartsEntries**:
- `id`: hash(chart_id:profile_id)
- `chart_id`: category + date identifier
- `profile_id`, `score`, `credits_count`, `position`
- `position_change`, `score_change`, `credits_count_change`
- Encore fields: `score_stream_1y`, `position_stream_1y`

**CreditScoreCharts**:
- `id`: hash(category + date)
- `category`, `calculation_date`
- `total_entries_count`, `prev_date`

### Position Ordering

1. Score DESC
2. Track count DESC
3. Profile created timestamp ASC

---

## Rising Entities

**Driver**: `src/tools/jobs/industry_processing/drivers/calc/muso_chart_entities.py`

**Schedule**: Weekly, Thursdays (with Tuesday pre-calculation)

### Charts

| Chart | Calculation |
|-------|-------------|
| `new_release` | Top 100 releases from last 30 days by SUM(popularity) |
| `rising_profile` | Top 100 artists/professionals by credit score jump in last 7 days |
| `rising_company` | Top by score jump: 45 Record Labels, 45 Publishers, 10 Studios |

### Score Jump Calculation

Max delta of `overall_score` between calculation_date and any day in the previous 7 days.

### Compilation Filter (Excluded Names)

```regex
various|musik|music|nature|sound|relax|yoga|work|sleep|baby|orch|rain|medita|
noise|ambien|focus|water|jazz|piano|violin|lounge|study|chill|storm|ocean|
wind|stress|instrument|effect|nurs|weather|guitar|therapy|pregnan
```

---

## Non-Legit Profiles Finder

**Driver**: `src/tools/jobs/industry_processing/drivers/calc/profile_compilation_mark.py`

Detects and marks compilation/non-music profiles.

### Detection Rules

**Compilation Profiles** (ambient, relaxation, etc.):
```regex
nature|sound|relax|yoga|work|sleep|baby|rain|medita|noise|ambien|focus|
water|jazz|piano|violin|lounge|study|chill|storm|ocean|wind|stress|
effect|weather|guitar|therapy|pregnan
```
- Mark as `compilation_profile` if >50% of tracks match AND >100 tracks

**Non-Music Profiles** (audiobooks, podcasts):
```regex
kapitel|chapter|folge|episode|teil|part|absatz|paragrapgh|act
```
- Mark as `non_music_profile` if >50% of tracks match AND >100 tracks

### Protection

Profiles linked to Muso users (roster seats, claimed profiles, Neptune IDs) are excluded.

---

## Analytics History

**Driver**: `src/tools/jobs/industry_processing/drivers/calc/analytics_history.py`

Accumulates metrics history for long-term retention.

### Sources

| Source | Metrics |
|--------|---------|
| Spotify | streams |
| YouTube | streams, views, videos |
| TikTok | views |
| Shazam | shazams |
| SoundCloud | streams |
| Audiomack | streams (rolling sum) |
| Instagram | video links, videos, views (from Zyte) |
| Anghami | streams |
| Qobuz | streams |

### Output Schema

```
source, metric_name, id, metric_value, capture_date
```

---

## Implementation Notes

### Common Patterns

1. **Filters**: All calculations filter `deleted.is_deleted = FALSE`
2. **Profile Types**: Most calculations only include `artist`, `professional`, `organization`
3. **User Protection**: Calculations that modify profiles exclude user-linked profiles
4. **Idempotency**: All calculations can be safely re-run

### SQS Message Format

```json
{
  "action_type": "link|merge|create_from_raw",
  "entity": {
    "entity_type": "profile|track|release",
    "entity_id": "{main_entity_id}"
  },
  "data": {
    "merge_ids": [],
    "link_raw_ids": [],
    "raw_ids": [],
    "action_by": {
      "id": "{run_batch_id}",
      "type": "operations",
      "sub_type": "platform_link_merge"
    }
  }
}
```

### Key MongoDB Collections

| Collection | Purpose |
|------------|---------|
| `dict_credit_category_rule` | Credit → Category mapping rules |
| `muso_chart_entities` | Rising/new release charts |
| `catalog_profile` | Profile data |
| `catalog_track` | Track data |
| `catalog_master_credit` | Credit assignments |

### Key Athena Tables

| Table | Purpose |
|-------|---------|
| `profile_score` / `profile_score_history` | Credit scores |
| `calc_analytics_cube_*` | Pre-aggregated analytics |
| `calc_credit_score_charts_entries` | Chart positions |
| `analytics_history` | Historical metrics |
