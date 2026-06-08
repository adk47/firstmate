/*
id: credit_fleet_fraud_user_scan
title: [Fraud] Credit fleet fraud - user-level submission scan
primary_tag: fraud
tags: [fraud]
trino_catalog: postgresql_core
trino_schema: public
description: >
  User/workspace-level behavioral scan for "credit fleet fraud" — one submitter spraying
  high-volume credit claims across unrelated high-popularity catalogs to manufacture chart rank.
  Scores the SUBMITTER as a running transaction (not each credit in isolation). READ-ONLY.
  Produces a ranked candidate list for ANALYST REVIEW — it is high-recall, not a confirmed-fraud
  list; combine with source-confirmation % and name-match before any action.
status: experimental
pii: contains user ids / names / emails — redact before posting to non-private channels
validated_on_node8: 2026-06-04 — surfaces the fraud ring at the top: userids 162720/184149/179969
  (all "hannah baker"/Darnel aliases) + 301754 (dagobertbuss@icloud.com = Aaron's offical.BVC.music),
  while legit mastering/mixing engineers drop out.
notes: >
  VALIDATION FINDINGS (live postgresql_core via trino-query.sh, 2026-06-04):
  - Gate on STATUS-INDEPENDENT behavior, not on approvals. The flagship fraudster userid 162720 was
    fully remediated (1253 requests, 104 distinct primary artists, 225 pop>=70 high-risk
    submissions, but n_approved=0 now). Gating on approved counts would MISS it. n_approved /
    appr_verif_false are REPORTED as damage indicators, not gates.
  - The "$0-LTV / free account" filter is the key precision lever (Aaron's "free/unclaimed" =
    airtight). It cut the suspect set ~60 -> ~40 by removing paying labels. Computed NULL-safe
    (team-only subs have NULL userid — a plain NOT IN nulls the whole predicate).
  - Live type gotchas vs the old Athena export: createdat is timestamp(6) w/ tz (NOT a string —
    do not substr it); credits is varchar (the {a,b} split IS correct); spotifytrackartists &
    verificationdata are json (json_extract + CAST); profileid is uuid (cast for literal compares).
  ENRICHMENT (v2, to raise precision before any auto-action):
  - source-confirmation %: join potential_fraud_accounts_muso_only_credits.sql logic (muso-only
    credits) — legit engineers/labels are on-source; injected credits are muso-only.
  - name-match: profile name vs spotifytrackArtists[].name fuzzy match (KSJ Beats != Olivia Rodrigo).
  - Creative-vs-technical role split is THE precision lever: is_high_risk_role excludes
    mastering/mixing/engineer, so legit engineers (high-volume cross-artist free accounts) drop out.
    Remaining edge cases (a free indie/regional producer with a coherent catalog) still need
    analyst review + source-confirm — keep this ADVISORY (no auto-action).

  Tunable thresholds (a row must clear all three to surface):
    min_requests=100, min_distinct_primary_artists=8, min_highpop_highrisk=5
*/

WITH cr AS (
    SELECT
        id, userid, workspaceid, profileid, status,
        coalesce(spotifypopularity, 0) AS pop,
        -- credits is a postgres text[] rendered as varchar like {Producer,Co-Producer}.
        -- CREATIVE / chart-weighted roles only. Technical roles (mastering/mixing/engineer) are
        -- EXCLUDED: legit mastering/mixing engineers are high-volume, cross-artist, free accounts
        -- and flood the list otherwise (validated 2026-06-04 — incl. Georgetown/Oasis Mastering).
        -- This is the single biggest precision lever (matches Aaron's "cleared: real engineers").
        any_match(
            split(substr(credits, 2, length(credits) - 2), ','),
            r -> regexp_like(lower(trim(r)), 'producer|writer|composer|lyric|songwrit|arrang|manager|^co-')
                 AND NOT regexp_like(lower(trim(r)), 'mastering|mixing|engineer')
        ) AS is_high_risk_role,
        CAST(json_extract(spotifytrackartists, '$') AS array(row(id varchar, name varchar))) AS artists,
        coalesce(CAST(json_extract(verificationdata, '$') AS row(is_approved boolean)).is_approved, false) AS verifier_approved
    FROM postgresql_core.public.credit_requests
    -- For an ongoing detector, scope to recent activity, e.g.:
    -- WHERE createdat >= date_add('day', -90, current_date)
),
-- "paying" = has an ACTIVE subscription, by user OR by a workspace/team they submit under.
-- (trial = free; cancelled = not currently paying. NULL-safe: IS NOT NULL guards the NOT IN trap.)
active_sub_user AS (
    SELECT DISTINCT userid FROM postgresql_core.public.subscriptions
    WHERE status = 'active' AND userid IS NOT NULL
),
active_sub_team AS (
    SELECT DISTINCT teamid FROM postgresql_core.public.subscriptions
    WHERE status = 'active' AND teamid IS NOT NULL
),
user_paid_via_team AS (
    SELECT DISTINCT c.userid
    FROM cr c JOIN active_sub_team t ON c.workspaceid = t.teamid
),
spread AS (
    SELECT userid, count(DISTINCT element_at(artists, 1).name) AS n_distinct_primary_artists
    FROM cr WHERE artists IS NOT NULL
    GROUP BY userid
),
agg AS (
    SELECT
        userid,
        count(DISTINCT id)                                                      AS n_requests,
        count(DISTINCT profileid)                                              AS n_profiles,
        count(DISTINCT IF(pop >= 70 AND is_high_risk_role, id))                AS highpop_highrisk_submitted,
        count(DISTINCT IF(status = 'approved', id))                            AS n_approved,
        count(DISTINCT IF(status = 'approved' AND pop >= 70 AND is_high_risk_role, id)) AS approved_highpop_highrisk,
        count(DISTINCT IF(status = 'approved' AND NOT verifier_approved, id))  AS approved_verifier_false,
        max(pop)                                                               AS max_pop
    FROM cr GROUP BY userid
)
SELECT
    a.userid,
    u.fullname                                  AS user_name,
    u.email                                     AS user_email,
    a.n_requests,
    a.n_profiles,
    s.n_distinct_primary_artists,
    a.highpop_highrisk_submitted,
    a.n_approved,
    a.approved_highpop_highrisk,
    a.approved_verifier_false,
    a.max_pop,
    -- composite fraud signature (higher = more suspicious); v1 starting weights
    round(
        least(a.n_requests / 100.0, 3.0)
      + least(s.n_distinct_primary_artists / 8.0, 3.0)
      + least(a.highpop_highrisk_submitted / 5.0, 4.0)
      + least(a.approved_verifier_false / 20.0, 3.0)
    , 2)                                        AS fleet_fraud_score
FROM agg a
JOIN spread s                ON s.userid  = a.userid
LEFT JOIN active_sub_user su ON su.userid = a.userid
LEFT JOIN user_paid_via_team pt ON pt.userid = a.userid
LEFT JOIN postgresql_core.public.users u ON u.id = a.userid
WHERE a.n_requests >= 100
  AND s.n_distinct_primary_artists >= 8
  AND a.highpop_highrisk_submitted >= 5
  -- free / $0-LTV only (the precision lever); drop this line to see all volume submitters
  AND su.userid IS NULL
  AND pt.userid IS NULL
-- Lead with the behavioral signature (robust to remediation — a scrubbed fraudster like 162720
-- still ranks high on submissions even at 0 approvals). Re-sort by approved_verifier_false for
-- "still-live damage to clean up first".
ORDER BY a.highpop_highrisk_submitted DESC, fleet_fraud_score DESC
LIMIT 200
