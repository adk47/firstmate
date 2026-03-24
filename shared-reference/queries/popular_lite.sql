WITH claimed_teams AS (
    SELECT c.profileid, c.teamid
    FROM "platform-core-backend-export-prod".public_claiming c
    WHERE c.status = 'processed'
),
paid_teams AS (
    SELECT DISTINCT teamid
    FROM "platform-core-backend-export-prod".public_subscriptions
    WHERE status = 'active'
),
lite_claimed AS (
    SELECT ct.profileid, ct.teamid
    FROM claimed_teams ct
    LEFT JOIN paid_teams pt ON pt.teamid = ct.teamid
    WHERE pt.teamid IS NULL
)
SELECT p._id, p.name, p.profile_type,
    COALESCE(array_join(p.roles, ', '), '') AS roles,
    p.popularity, p.credits_count, p.credits_count_1y,
    u.email, u.fullname AS user_name, u.lastactivetime
FROM lite_claimed lc
JOIN "platform-industry-bi-prod".matvw_catalog_profile p ON p._id = lc.profileid AND NOT p.is_deleted
LEFT JOIN "platform-core-backend-export-prod".public_users u ON u.defaultteamid = lc.teamid
WHERE p.popularity >= 80
ORDER BY p.popularity DESC
LIMIT 50
