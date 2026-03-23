/*
id: user_seats
title: [Marketing] User seats
athena_id: 6802f911-fdaf-4240-9a90-d76371558f4f
primary_tag: marketing
tags: [marketing]
athena_database: platform-industry-db-industry-prod
description: Was done for marketing test candidate
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

--ID
-- Created At
-- Name (full name or first name and last name)
-- Subscription Status
-- Roster
-- Profile name
-- Rank/Popularity/Score


-- Plan Type (monthly vs annually) - 4 options
-- Payment Method - 4 options 
-- Subscription Start - first start
-- Subscription End - last end
-- Trial start
-- Trial End
-- Poster purchase (boolean? or smth)
-- Common Credit
-- Credit Count

-- select subscription_status, count(1) from "bi"."user_subscriptions" group by 1 limit 10

-- select * from "production-musomvp"."public_orders"

with usr AS (
	select id AS user_id,
		neptuneprofessionalid AS profile_id,
		email,
		fullname AS name,
		subscriptionstatus AS subscription_status,
		createdat AS created_at
	from "production-musomvp"."public_users" AS u
),
seat AS (
	select usr.*,
		s.status,
		s.seatid AS seat_profile_id
	from "production-musomvp"."public_discovery_seats" AS s
		join usr ON (user_id = userid)
)
select s.*,
	snp.name AS user_profile_name,
	coalesce(try_cast(snp.rank."$numberInt" AS INT), 5) AS user_profile_rank,
	snp.common_credits AS user_profile_common_credits,
	TRY_CAST(snp.credits_count."$numberInt" AS INT) AS user_profile_credits_count,
	sp.name AS seat_name,
	coalesce(try_cast(sp.rank."$numberInt" AS INT), 5) AS seat_profile_rank,
	sp.common_credits AS seat_profile_common_credits,
	TRY_CAST(sp.credits_count."$numberInt" AS INT) AS seat_profile_credits_count
from seat AS s
	join "platform-industry-db-industry-prod"."catalog_profile" AS sp ON (s.seat_profile_id = sp._id)
	join "platform-industry-db-industry-prod"."catalog_profile" AS snp ON (s.profile_id = snp._id)
	
	
	
	