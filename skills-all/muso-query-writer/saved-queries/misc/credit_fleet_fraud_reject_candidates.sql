/*
id: credit_fleet_fraud_reject_candidates
title: [Fraud] Credit fleet fraud - reversal-candidate credit_request IDs (DRY-RUN list)
primary_tag: fraud
tags: [fraud]
trino_catalog: postgresql_core
trino_schema: public
description: >
  Given a list of CONFIRMED-fraud submitter userids, list the still-APPROVED creative high-pop
  credit_request IDs that are CANDIDATES for reversal — with track/artist/role/popularity context
  for analyst review. READ-ONLY. This produces a reviewable reject list; it does NOT execute any
  reject. Execution is a separate, human-gated step (see muso-ops-admin bulk-destructive gate).
status: experimental
pii: contains the fraudulent submission detail — internal review only
notes: >
  Edit the userids IN-list to the confirmed set. Scope is intentionally NARROW (status='approved',
  creative role, pop>=70) to mirror Aaron's "revoke the famous-artist approvals first; leave the
  small legit baseline until Jan cross-checks". Widen pop / role filters only with analyst sign-off.
  The cr `id` column is what feeds the gated execution: PUT /admin/credit-requests
  {"requestIds":[...],"status":"rejected"} — run ONLY after human confirmation.
*/

WITH cr AS (
    SELECT
        id, userid, profileid, status,
        coalesce(spotifypopularity, 0) AS pop,
        spotifytracktitle AS track,
        element_at(CAST(json_extract(spotifytrackartists, '$') AS array(row(id varchar, name varchar))), 1).name AS primary_artist,
        array_join(split(substr(credits, 2, length(credits) - 2), ','), ', ') AS roles,
        any_match(split(substr(credits, 2, length(credits) - 2), ','),
            r -> regexp_like(lower(trim(r)), 'producer|writer|composer|lyric|songwrit|arrang|manager|^co-')
                 AND NOT regexp_like(lower(trim(r)), 'mastering|mixing|engineer')) AS is_creative,
        coalesce(CAST(json_extract(verificationdata, '$') AS row(is_approved boolean, total_risk_percent double)).is_approved, false) AS verifier_approved,
        coalesce(CAST(json_extract(verificationdata, '$') AS row(is_approved boolean, total_risk_percent double)).total_risk_percent, 0.0) AS total_risk
    FROM postgresql_core.public.credit_requests
    WHERE userid IN (162720, 184149, 179969, 301754)   -- <-- confirmed-fraud submitter set; edit me
)
SELECT
    CAST(id AS varchar)       AS credit_request_id,
    userid,
    CAST(profileid AS varchar) AS profileid,
    pop,
    primary_artist,
    track,
    roles,
    verifier_approved,
    round(total_risk, 1)      AS total_risk
FROM cr
WHERE status = 'approved'
  AND is_creative
  AND pop >= 70
ORDER BY userid, pop DESC
