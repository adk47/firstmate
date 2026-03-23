/*
id: industry_sla
title: [OKR] Industry SLA
athena_id: c318b753-58b8-4f41-bd16-8914dc7ce72d
primary_tag: okr
tags: [okr]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: experimental
pii: unknown
last_exported: 2025-01-31
*/

with p AS (
	select _id as profile_id,
		rank,
		cast(
			from_unixtime(updated_timestamp / 1000) as date
		) AS upd,
		cast(
			from_unixtime(created_timestamp / 1000) as date
		) AS created
	from "platform-industry-bi-prod"."matvw_catalog_profile"
	where profile_type in ('professional', 'artist')
		and not COALESCE(is_deleted, false)
),
c AS (
	select profile_id,
		MIN(rank) AS rank,
		max(
			cast(
				from_unixtime(updated_timestamp / 1000) as date
			)
		) AS crd_upd
	from "platform-industry-bi-prod"."matvw_catalog_master_credit"
		right join p USING(profile_id)
	group by 1
)
select CASE
		when rank = 1
		and date_diff('day', crd_upd, current_date) <= 3 then true
		when rank = 2
		and date_diff('day', crd_upd, current_date) <= 10 then true
		when rank = 3
		and date_diff('day', crd_upd, current_date) <= 30 then true
		when rank = 4
		and date_diff('day', crd_upd, current_date) <= 90 then true
		when rank = 5
		and date_diff('day', crd_upd, current_date) <= 180 then false -- change to true
		else false
	end AS is_within_sla,
	count(1)
from c
where rank < 3
group by 1