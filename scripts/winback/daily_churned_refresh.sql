SELECT
  CAST(s.updatedat AS varchar)                                            AS cancel_date,
  LOWER(u.email)                                                          AS email,
  COALESCE(TRIM(u.firstname), '')                                         AS first_name,
  COALESCE(TRIM(u.lastname),  '')                                         AS last_name,
  CASE
    WHEN s.plan LIKE '%proplus%' THEN 'pro+'
    WHEN s.plan LIKE '%pro%'     THEN 'pro'
    ELSE 'other'
  END                                                                     AS plan_tier,
  s.plan                                                                  AS plan_raw,
  CASE WHEN s.plan LIKE '%annual%' THEN 'annual' ELSE 'monthly' END       AS billing_cycle,
  CAST(s.createdat AS varchar)                                            AS subscription_start,
  CAST(1 AS varchar)                                                      AS total_subscriptions,
  CAST(json_extract_scalar(s.details, '$.cancel_reason') AS varchar)      AS cancel_reason,
  COALESCE(p.name, '')                                                    AS profile_name,
  u.neptuneprofessionalid                                                 AS profile_id,
  CAST(COALESCE(p.credits_count, 0) AS varchar)                           AS credits_count,
  CAST(COALESCE(p.popularity, 0)    AS varchar)                           AS popularity,
  COALESCE(p.profile_type, '')                                            AS profile_type,
  COALESCE(array_join(p.roles, ', '), '')                                 AS roles,
  COALESCE(array_join(p.common_credits, ', '), '')                        AS common_credits,
  COALESCE(p.primary_genre, '')                                           AS primary_genre,
  COALESCE(p.country, '')                                                 AS country,
  CAST(COALESCE(p.years_active, 0) AS varchar)                            AS years_active,
  ''                                                                      AS follows_count,
  ''                                                                      AS logins_last_90d,
  ''                                                                      AS used_analytics,
  ''                                                                      AS used_plaques,
  ''                                                                      AS used_audits,
  ''                                                                      AS viewed_profiles,
  ''                                                                      AS used_encore,
  ''                                                                      AS used_sharing,
  ''                                                                      AS used_milestones,
  ''                                                                      AS used_home_feed,
  ''                                                                      AS submitted_credits,
  ''                                                                      AS used_roster,
  CAST(CASE WHEN u.neptuneprofessionalid IS NOT NULL THEN true ELSE false END AS varchar) AS has_claimed_profile,
  CASE WHEN u.neptuneprofessionalid IS NOT NULL THEN
    'https://credits.muso.ai/profile/' || u.neptuneprofessionalid
    ELSE '' END                                                           AS profile_url,
  ''                                                                      AS outreach_status,
  ''                                                                      AS email_sent_date,
  ''                                                                      AS email_variant,
  ''                                                                      AS response_status,
  ''                                                                      AS notes,
  ''                                                                      AS stage
FROM postgresql_core.public.subscriptions s
JOIN postgresql_core.public.users u
  ON u.id = s.userid
LEFT JOIN "platform-industry-bi-prod".matvw_catalog_profile p
  ON p._id = u.neptuneprofessionalid AND COALESCE(p.is_deleted,false) = false
WHERE s.status = 'cancelled'
  AND s.updatedat > TIMESTAMP '__CUTOFF__'
  AND s.plan IN (
    'muso_individual_pro_monthly',
    'muso_individual_pro_monthly_notrial',
    'muso_individual_pro_annual',
    'muso_team_pro_graduated_monthly',
    'muso_team_pro_graduated_annual',
    'muso_individual_proplus_monthly',
    'muso_individual_proplus_monthly_notrial',
    'muso_individual_proplus_annual'
  )
  AND u.email IS NOT NULL
ORDER BY s.updatedat ASC
