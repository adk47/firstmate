/*
id: top_claimed_profiles
title: [marketing] Top claimed profiles
athena_id: 212fcd10-78e1-4b4f-aa95-13fb5e01f597
primary_tag: marketing
tags: [marketing]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with o as (
	select distinct teamid,
		json_extract_scalar(item, '$.details.profile.id') AS profile_id
	from postgresql_core.public.public_orders
		CROSS JOIN UNNEST(
			cast(json_extract(details, '$.items') AS ARRAY(JSON))
		) AS i(item)
	where json_extract_scalar(details, '$.orderType') = 'black-card'
),
s AS (
	select t.email AS email,
		s.seatid AS profile_id,
		BOOL_OR(coalesce(s.status = 'active', FALSE)) AS is_pro,
		ARBITRARY(o.profile_id) IS NOT NULL AS ordered_black_card,
		BOOL_OR(coalesce(c.status = 'processed', FALSE)) AS is_claimed
	from postgresql_core.public.public_teams AS t
		join postgresql_core.public.public_roster_seats as s ON (t.id = s.teamid)
		left join postgresql_core.public.public_claiming as c ON (
			t.id = c.teamid
			and s.seatid = profileid
		)
		left join o ON (
			t.id = c.teamid
			and s.seatid = profile_id
		)
	group by 1,
		2
),
c AS (
	select profile_id,
	   -- min(position) AS min_position,
		min(if(category = 'Artist', position)) AS artist_position,
		min(if(category = 'Songwriter', position)) AS songwriter_position,
		min(if(category = 'Producer', position)) AS producer_position,
		min(if(category = 'Mixing', position)) AS mixing_position,
		min(if(category = 'Mastering', position)) AS mastering_position
	from "platform-industry-calc-prod".calc_credit_score_charts_entries_history
	where date = '2024-02-15' 
-- 	and category in (
-- 	    'Artist',
-- 	    'Songwriter',
-- 	    'Producer',
-- 	    'Mixing',
-- 	    'Mastering'
-- 	)
	group by 1
)
select s.*,
	profile_id,
	name as profile_name,
	popularity,
	c.*
from hive.default.matvw_catalog_profile AS p
	join s ON (profile_id = _id)
	left join c USING(profile_id)
	where is_claimed and is_pro and not ordered_black_card
order by is_claimed desc,
	popularity desc
limit 1000