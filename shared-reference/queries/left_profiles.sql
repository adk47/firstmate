WITH recently_canceled AS (
    SELECT s.teamid, s.userid, s.plan, s.updatedat AS cancel_date
    FROM "platform-core-backend-export-prod".public_subscriptions s
    WHERE s.status = 'cancelled'
      AND s.updatedat >= date_format(date_add('day', -1, current_timestamp), '%Y-%m-%d')
),
canceled_profiles AS (
    SELECT rc.teamid, rc.userid, rc.plan, rc.cancel_date, c.profileid
    FROM recently_canceled rc
    JOIN "platform-core-backend-export-prod".public_claiming c ON c.teamid = rc.teamid AND c.status = 'processed'
),
enriched AS (
    SELECT cp.profileid, p.name, p.profile_type,
        COALESCE(array_join(p.roles, ', '), '') AS roles,
        p.popularity, p.credits_count, cp.plan, cp.cancel_date,
        u.email, u.fullname AS user_name,
        CASE
            WHEN cp.plan LIKE 'muso_team_business_%' THEN 'B2B'
            WHEN cp.plan LIKE 'muso_team_pro_%' THEN 'B2P'
            WHEN cp.plan LIKE 'muso_individual_%' THEN 'B2P'
            ELSE 'Other'
        END AS plan_category
    FROM canceled_profiles cp
    JOIN "platform-industry-bi-prod".matvw_catalog_profile p ON p._id = cp.profileid AND NOT p.is_deleted
    LEFT JOIN "platform-core-backend-export-prod".public_users u ON u.id = cp.userid
)
SELECT * FROM enriched ORDER BY popularity DESC NULLS LAST LIMIT 50
