/*
id: top_profiles
title: [ukraine] top profiles
athena_id: 249791d7-dc52-4325-b709-46ab8d88ac89
primary_tag: ukraine
tags: [ukraine]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with s as (
	select profile_id,
		overall_score
	from "platform-industry-calc-prod".calc_credit_score
),
up AS (
	select _id as profile_id,
		common_credits,
		name
	from hive."platform-industry-bi-prod".matvw_catalog_profile
	where lower(country) = 'ukraine'
		and not is_deleted
),
ut AS (
	select master_track_id,
		profile_id
	from hive."platform-industry-bi-prod".matvw_catalog_master_credit
		join up using(profile_id)
	where not is_deleted
),
uc AS (
	select distinct profile_id
	from (
			select ut.profile_id AS user_profile_id,
				c.profile_id,
				row_number() over (
					partition by ut.profile_id
					order by count(1) desc
				) AS rn
			from ut
				join hive."platform-industry-bi-prod".matvw_catalog_master_credit AS c USING(master_track_id)
			where not is_deleted
				and ut.profile_id <> c.profile_id
			group by 1,
				2
		)
	where rn <= 10
),
p AS (
	select profile_id
	from up
	union
	select profile_id
	from uc
)
select profile_id,
	name,
	common_credits,
	overall_score,
	country
from p
	join hive."platform-industry-bi-prod".matvw_catalog_profile AS cp ON(profile_id = _id)
	join s USING(profile_id)
where coalesce(nullif(lower(country), ''), 'ukraine') = 'ukraine'
order by overall_score desc
limit 1000