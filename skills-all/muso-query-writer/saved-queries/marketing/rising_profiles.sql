/*
id: rising_profiles
title: [marketing] Rising Profiles
athena_id: 7a5f47c0-7ad4-4d50-b4ab-ec826ebef359
primary_tag: marketing
tags: [marketing]
athena_database: platform-industry-calc-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with ig AS (
	select c._id AS profile_id,
		arbitrary(contact.value) AS instagram
	from "platform-industry-bi-prod".matvw_catalog_profile as c
		cross join unnest(raw_profile_ids) AS cr(rid)
		join "platform-industry-bi-prod".matvw_raw_profile AS r ON (r._id = rid)
		cross join unnest(r.contacts) AS rc(contact)
	where nullif(contact.value, '') is not null
		and contact.type = 'instagram'
	group by 1
),
s AS (
	select profile_id,
		min_by("overall_score", date) AS old_score,
		max_by("overall_score", date) AS cur_score,
		count(1) = 1 AS is_new
	from "platform-industry-calc-prod"."calc_credit_score_history"
	where date in (
			select date
			from "platform-industry-calc-prod"."calc_credit_score_history$partitions"
			order by 1 desc
			limit 2
		)
	group by 1
)
select s.profile_id,
	name,
	ARRAY_JOIN(p.common_credits, ', ') AS profile_common_credits,
	cur_score - old_score AS score_diff,
	cur_score,
	old_score,
	popularity,
	rank,
	instagram
from "platform-industry-bi-prod".matvw_catalog_profile AS p
	join s ON (p._id = s.profile_id)
	left join ig ON (s.profile_id = ig.profile_id)
where profile_type in ('professional', 'artist')
	and old_score > 0
order by cur_score - old_score desc
limit 1000