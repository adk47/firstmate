WITH recent_claims AS (
    SELECT c.profileid, c.profiletype, c.createdat AS claim_date, c.teamid
    FROM "platform-core-backend-export-prod".public_claiming c
    WHERE c.status = 'processed'
      AND c.createdat >= date_format(date_add('day', -1, current_timestamp), '%Y-%m-%d')
),
paid_teams AS (
    SELECT DISTINCT teamid, plan
    FROM "platform-core-backend-export-prod".public_subscriptions
    WHERE status = 'active'
),
enriched AS (
    SELECT rc.profileid, p.name, p.profile_type,
        COALESCE(array_join(p.roles, ', '), '') AS roles,
        p.popularity, p.credits_count, rc.claim_date,
        pt.plan,
        u.email, u.fullname AS user_name,
        CASE
            WHEN pt.plan LIKE 'muso_team_business_%' THEN 'B2B'
            WHEN pt.plan LIKE 'muso_team_pro_%' THEN 'B2P'
            WHEN pt.plan LIKE 'muso_individual_%' THEN 'B2P'
            ELSE 'Other'
        END AS plan_category
    FROM recent_claims rc
    JOIN paid_teams pt ON pt.teamid = rc.teamid
    JOIN "platform-industry-bi-prod".matvw_catalog_profile p ON p._id = rc.profileid AND NOT p.is_deleted
    LEFT JOIN "platform-core-backend-export-prod".public_users u ON u.defaultteamid = rc.teamid
)
SELECT * FROM enriched ORDER BY popularity DESC NULLS LAST LIMIT 30
