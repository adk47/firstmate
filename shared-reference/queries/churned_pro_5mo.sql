-- STACK SWAP (Oct 2026): "platform-industry-amplitude-bi-prod".events is the Amplitude export lake.
-- At Amplitude's cutover the event router's lake sink takes over the same files (analytics lane A11), so
-- this query is meant to stay valid; check the latest partition if a result looks short. For a current or per-user read prefer ClickHouse product_events.events (skill muso-analytics).
WITH cancelled_subs AS (
    SELECT
        s.id AS sub_id,
        s.userid,
        s.teamid,
        s.service AS payment_platform,
        s.plan AS plan_tier,
        s.profileseatslimit,
        s.createdat AS sub_createdat,
        s.updatedat AS cancel_date
    FROM "platform-core-backend-export-prod".public_subscriptions s
    WHERE s.status = 'cancelled'
      AND CAST(SUBSTR(s.updatedat, 1, 10) AS date) >= date_add('month', -5, current_date)
),
first_sub AS (
    SELECT userid, MIN(createdat) AS first_sub_start, COUNT(*) AS total_subscriptions
    FROM "platform-core-backend-export-prod".public_subscriptions
    GROUP BY userid
),
users AS (
    SELECT id, email, fullname, createdat AS account_created, lastactivetime
    FROM "platform-core-backend-export-prod".public_users
),
roster AS (
    SELECT teamid, seatid AS profile_id, type AS seat_type
    FROM "platform-core-backend-export-prod".public_roster_seats
),
profiles AS (
    SELECT
        _id,
        name AS profile_name,
        credits_count,
        popularity,
        profile_type,
        roles,
        common_credits,
        primary_genre,
        country
    FROM "platform-industry-bi-prod".matvw_catalog_profile
    WHERE NOT is_deleted
),
claiming AS (
    SELECT profileid AS profile_id, userid
    FROM "platform-core-backend-export-prod".public_claiming
    WHERE status = 'processed'
),
cancel_reasons AS (
    SELECT
        CAST(user_id AS bigint) AS userid,
        json_extract_scalar(event_properties, '$["cancellationDetails.feedback"]') AS cancel_reason,
        event_time,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY event_time DESC) AS rn
    FROM "platform-industry-amplitude-bi-prod".events
    WHERE event_type = 'backend_user_subscription_cancelled'
      AND import_date >= date_format(date_add('month', -6, current_date), '%Y-%m-%d')
)
SELECT
    u.email,
    u.fullname AS name,
    cs.plan_tier,
    cs.payment_platform,
    u.account_created,
    u.lastactivetime AS last_active,
    CASE
        WHEN CAST(SUBSTR(u.lastactivetime, 1, 10) AS date) >= date_add('day', -30, current_date) THEN 'active_30d'
        WHEN CAST(SUBSTR(u.lastactivetime, 1, 10) AS date) >= date_add('day', -90, current_date) THEN 'active_90d'
        ELSE 'inactive'
    END AS activity_level,
    cs.cancel_date,
    fs.first_sub_start,
    fs.total_subscriptions,
    p.profile_name,
    r.profile_id,
    p.credits_count,
    p.popularity,
    p.profile_type,
    ARRAY_JOIN(p.roles, ', ') AS roles,
    ARRAY_JOIN(p.common_credits, ', ') AS common_credits,
    p.primary_genre,
    p.country,
    cs.profileseatslimit AS roster_size,
    cl.profile_id IS NOT NULL AS has_claimed_profile,
    CASE WHEN r.profile_id IS NOT NULL THEN 'https://app.muso.ai/profile/' || r.profile_id ELSE NULL END AS profile_url,
    cr.cancel_reason
FROM cancelled_subs cs
JOIN users u ON u.id = cs.userid
LEFT JOIN first_sub fs ON fs.userid = cs.userid
LEFT JOIN roster r ON r.teamid = cs.teamid
LEFT JOIN profiles p ON p._id = r.profile_id
LEFT JOIN claiming cl ON cl.profile_id = r.profile_id
LEFT JOIN cancel_reasons cr ON cr.userid = cs.userid AND cr.rn = 1
