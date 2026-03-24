WITH cancelled_pro AS (
  SELECT s.userid, s.teamid, s.plan,
    cast(s.updatedat as timestamp) as cancel_date,
    cast(s.createdat as timestamp) as sub_created,
    ROW_NUMBER() OVER (PARTITION BY s.userid ORDER BY cast(s.updatedat as timestamp) DESC) as rn
  FROM "platform-core-backend-export-prod".public_subscriptions s
  WHERE s.status = 'cancelled'
    AND cast(s.updatedat as timestamp) >= current_timestamp - interval '5' month
    AND s.plan LIKE '%pro%'
),
user_subs AS (
  SELECT userid, COUNT(*) as total_subscriptions
  FROM "platform-core-backend-export-prod".public_subscriptions GROUP BY 1
),
cancel_reasons AS (
  SELECT CAST(user_id AS VARCHAR) as uid,
    json_extract_scalar(event_properties, '$["cancellationDetails.feedback"]') as cancel_reason,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY event_time DESC) as rn
  FROM "platform-industry-amplitude-bi-prod".events
  WHERE import_date >= '2025-09-01' AND event_type = 'backend_user_subscription_cancelled'
),
claimed AS (
  SELECT teamid, profileid,
    ROW_NUMBER() OVER (PARTITION BY teamid ORDER BY createdat DESC) as rn
  FROM "platform-core-backend-export-prod".public_claiming
  WHERE status = 'processed' AND profileid IS NOT NULL
),
follows_given AS (
  SELECT actor_id, COUNT(*) as follow_count
  FROM "platform-feed-export-prod".public_follow GROUP BY 1
),
login_activity AS (
  SELECT CAST(user_id AS VARCHAR) as uid,
    COUNT(*) as login_count_90d,
    MAX(event_time) as last_login
  FROM "platform-industry-amplitude-bi-prod".events
  WHERE import_date >= '2025-11-01' AND event_type IN ('login', 'session_start')
  GROUP BY 1
),
feature_usage AS (
  SELECT CAST(user_id AS VARCHAR) as uid,
    COUNT_IF(event_type = 'analytics_view') as analytics_views,
    COUNT_IF(event_type LIKE 'plaque%') as plaque_interactions,
    COUNT_IF(event_type LIKE 'audit%') as audit_views,
    COUNT_IF(event_type = 'profile_view') as profile_views,
    COUNT_IF(event_type LIKE 'encore%') as encore_interactions,
    COUNT_IF(event_type = 'share_click') as share_clicks,
    COUNT_IF(event_type LIKE 'milestone%') as milestone_interactions,
    COUNT_IF(event_type = 'home_feed') as home_feed_views,
    COUNT_IF(event_type LIKE 'credits_submissions%') as credit_submissions,
    COUNT_IF(event_type LIKE 'roster%') as roster_actions
  FROM "platform-industry-amplitude-bi-prod".events
  WHERE import_date >= '2025-11-01'
    AND event_type NOT LIKE '[%'
    AND event_type NOT LIKE 'backend_%'
  GROUP BY 1
)
SELECT
  cp.cancel_date,
  u.email,
  u.firstname as first_name,
  u.lastname as last_name,
  CASE WHEN cp.plan LIKE '%proplus%' THEN 'pro_plus' ELSE 'pro' END as plan_tier,
  cp.plan as plan_raw,
  CASE WHEN cp.plan LIKE '%annual%' THEN 'annual' ELSE 'monthly' END as billing_cycle,
  cp.sub_created as subscription_start,
  COALESCE(us.total_subscriptions, 1) as total_subscriptions,
  COALESCE(cr.cancel_reason, 'not_provided') as cancel_reason,
  p.name as profile_name,
  p._id as profile_id,
  p.credits_count,
  p.popularity,
  p.profile_type,
  ARRAY_JOIN(p.roles, ', ') as roles,
  ARRAY_JOIN(p.common_credits, ', ') as common_credits,
  p.primary_genre,
  p.country,
  p.years_active,
  COALESCE(fg.follow_count, 0) as follows_count,
  COALESCE(la.login_count_90d, 0) as logins_last_90d,
  COALESCE(fu.analytics_views, 0) as used_analytics,
  COALESCE(fu.plaque_interactions, 0) as used_plaques,
  COALESCE(fu.audit_views, 0) as used_audits,
  COALESCE(fu.profile_views, 0) as viewed_profiles,
  COALESCE(fu.encore_interactions, 0) as used_encore,
  COALESCE(fu.share_clicks, 0) as used_sharing,
  COALESCE(fu.milestone_interactions, 0) as used_milestones,
  COALESCE(fu.home_feed_views, 0) as used_home_feed,
  COALESCE(fu.credit_submissions, 0) as submitted_credits,
  COALESCE(fu.roster_actions, 0) as used_roster,
  CASE WHEN c.profileid IS NOT NULL THEN 'yes' ELSE 'no' END as has_claimed_profile,
  CASE WHEN p._id IS NOT NULL THEN 'https://app.muso.ai/profile/' || p._id ELSE '' END as profile_url
FROM cancelled_pro cp
JOIN "platform-core-backend-export-prod".public_users u ON u.id = cp.userid
LEFT JOIN user_subs us ON us.userid = cp.userid
LEFT JOIN claimed c ON c.teamid = cp.teamid AND c.rn = 1
LEFT JOIN "platform-industry-bi-prod".matvw_catalog_profile p ON p._id = c.profileid AND p.is_deleted = false
LEFT JOIN follows_given fg ON fg.actor_id = c.profileid
LEFT JOIN cancel_reasons cr ON cr.uid = CAST(cp.userid AS VARCHAR) AND cr.rn = 1
LEFT JOIN login_activity la ON la.uid = CAST(cp.userid AS VARCHAR)
LEFT JOIN feature_usage fu ON fu.uid = CAST(cp.userid AS VARCHAR)
WHERE cp.rn = 1
ORDER BY cp.cancel_date DESC
