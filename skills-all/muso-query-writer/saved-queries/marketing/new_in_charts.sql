/*
id: new_in_charts
title: [marketing] New in charts
athena_id: c43a8e5f-19d4-46c7-969c-d3b1857680a0
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
	from hive."platform-industry-bi-prod".matvw_catalog_profile as c
		cross join unnest(raw_profile_ids) AS cr(rid)
		join hive."platform-industry-bi-prod".matvw_raw_profile AS r ON (r._id = rid)
		cross join unnest(r.contacts) AS rc(contact)
	where nullif(contact.value, '') is not null
		and contact.type = 'instagram'
	group by 1
)
select "category" AS chart,
	"profile_id" AS "profile_id",
	arbitrary(name) AS name,
	arbitrary(position) as position,
	arbitrary(position_change) as position_change,
	arbitrary(score) as score,
	arbitrary(score_change) as score_change,
	arbitrary(instagram) AS instagram
from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history"
	left join ig USING(profile_id)
where date in (
		select date
		from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history$partitions"
		order by 1 desc
		limit 10
	)
	and "position" <= 100
	and (position_change <= position-100 or position_change = 0)
group by 1,
	2
having count(1) = 1
	and max(date) in (
		select max(date)
		from "platform-industry-calc-prod"."calc_credit_score_charts_entries_history$partitions"
	)
order by position_change =0, name