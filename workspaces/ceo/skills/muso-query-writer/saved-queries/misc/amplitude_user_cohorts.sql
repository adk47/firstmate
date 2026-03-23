/*
id: amplitude_user_cohorts
title: Amplitude User Cohorts
athena_id: 5945e76a-6471-4a22-aa47-3dd233e94b8b
primary_tag: misc
tags: [misc]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

-- Users who joined and never started the trial (no subscription status) +
-- Stripe/PayPal users who had a trial but didn't upgrade (expired)  +
-- Stripe/PayPal who canceled (canceled) +
-- Stripe/Paypal Pro Subscribers (monthly + discovery seats) +
-- iOS/Android subscribers who canceled (canceled)
-- iOS/Android Pro Subscribers (Trialing)
-- iOS/Android Pro Subscribers (Monthly)
-- iOS/Android Pro Plus Subscribers (Trialing)
-- iOS/Android Pro Plus Subscribers (Monthly)
with usr AS (
	select id,
		email,
		subscriptionstatus,
		CASE
			WHEN snstargetarns LIKE '%platform": "ios%' THEN 'ios'
			WHEN snstargetarns LIKE '%platform": "android%' THEN 'android'
			WHEN snstargetarns LIKE '%platform%' THEN 'unknown'
		end AS platform,
		createdat AS created_at
	from "production-musomvp"."public_users"
)
select 
    id,
    email,
    platform,
    cohort,
    created_at
from (
		select id,
			'Stripe/PayPal users who had a trial but didnt upgrade (expired)' AS cohort
		from "production-musomvp"."public_users"
		where subscriptionstatus = 'EXPIRED'
			and appledata IS NULL
			and googledata IS NULL
		union all
		select id,
			'Users who joined and never started the trial (no subscription status)' AS cohort
		from "production-musomvp"."public_users"
		where NULLIF(subscriptionstatus, '') IS NULL
		union all
		select id,
			'Stripe/PayPal who canceled (canceled)' AS cohort
		from "production-musomvp"."public_users"
		where UPPER(subscriptionstatus) LIKE '%CANCEL%'
			and appledata IS NULL
			and googledata IS NULL
		union all
		select id,
			'Stripe/Paypal Pro Subscribers' AS cohort
		from "production-musomvp"."public_users"
		where UPPER(subscriptionstatus) = 'PRO'
			and appledata IS NULL
			and googledata IS NULL
		union all
		select id,
			'iOS/Android subscribers who canceled' AS cohort
		from "production-musomvp"."public_users"
		where (
				UPPER(subscriptionstatus) LIKE '%CANCEL%'
				OR UPPER(subscriptionstatus) LIKE '%EXPIRE%'
			)
			and (
				appledata IS NOT NULL
				OR googledata IS NOT NULL
			)
		union all
		select u.id,
			'iOS/Android Pro Subscribers (monthly)' AS cohort
		from "production-musomvp"."public_users" as u
			JOIN "production-musomvp"."public_discovery_seats" AS s ON(u.id = s.userid)
		where UPPER(u.subscriptionstatus) = 'PRO'
			and (
				u.appledata IS NOT NULL
				OR u.googledata IS NOT NULL
			)
			and s.deletedat IS NULL
			and s.status = 'active'
		group by 1
		having COUNT(1) = 1
		union all
		select u.id,
			'iOS/Android Pro Plus Subscribers (monthly)' AS cohort
		from "production-musomvp"."public_users" as u
			JOIN "production-musomvp"."public_discovery_seats" AS s ON(u.id = s.userid)
		where UPPER(u.subscriptionstatus) = 'PRO'
			and (
				u.appledata IS NOT NULL
				OR u.googledata IS NOT NULL
			)
			and s.deletedat IS NULL
			and s.status = 'active'
		group by 1
		having COUNT(1) > 1
		union all
		select u.id,
			'iOS/Android Pro Subscribers (trialing)' AS cohort
		from "production-musomvp"."public_users" as u
			JOIN "production-musomvp"."public_discovery_seats" AS s ON(u.id = s.userid)
		where UPPER(u.subscriptionstatus) = 'TRIAL'
			and (
				u.appledata IS NOT NULL
				OR u.googledata IS NOT NULL
			)
			and s.deletedat IS NULL
			and s.status = 'active'
		group by 1
		having COUNT(1) = 1
		union all
		select u.id,
			'iOS/Android Pro Plus Subscribers (trialing)' AS cohort
		from "production-musomvp"."public_users" as u
			JOIN "production-musomvp"."public_discovery_seats" AS s ON(u.id = s.userid)
		where UPPER(u.subscriptionstatus) = 'TRIAL'
			and (
				u.appledata IS NOT NULL
				OR u.googledata IS NOT NULL
			)
			and s.deletedat IS NULL
			and s.status = 'active'
		group by 1
		having COUNT(1) > 1
	) AS c
	JOIN usr USING(id)