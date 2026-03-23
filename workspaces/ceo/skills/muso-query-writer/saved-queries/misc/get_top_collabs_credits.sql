/*
id: get_top_collabs_credits
title: [AI] Get top collabs credits
athena_id: c33f2169-555f-45cd-ad2e-ce504f8bbf5c
primary_tag: ai
tags: [ai]
athena_database: platform-industry-db-industry-prod
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with s AS (
	select overall_score,
		profile_id AS _id,
		child_credit_score,
		TRY(transform(
        filter(
            map_entries(TRY_CAST(JSON_EXTRACT(child_credit_score, '$') AS MAP<varchar, bigint>)),
            e -> e[2] = array_max(map_values(TRY_CAST(JSON_EXTRACT(child_credit_score, '$') AS MAP<varchar, bigint>)))),
        e -> e[1])[1] = 'Artist') AS is_artist
		
	from "platform-industry-calc-prod"."calc_credit_score"
),
top_profiles AS (
select max_by(_id, overall_score) AS profile_id,
	name,
	MAX_BY(is_artist, overall_score) AS is_artist,
	MAX(overall_score) AS overall_score,
	MAX_BY(child_credit_score, overall_score) AS child_score
from "platform-industry-db-industry-prod"."catalog_profile" AS p
	join s USING(_id)
where lower(name) not like '%rain%'
	and lower(name) not like '%chill%'
	and lower(name) not like '%lounge%'
	and lower(name) not like '%meditation%'
group by name
order by overall_score desc
limit 10000
)
select 
    profile_id,
    count(distinct album_id) AS num_credits
from top_profiles 
join "platform-industry-db-industry-prod"."catalog_master_credit" USING(profile_id)
cross join unnest(master_release_ids) AS mr(release_id)
join "platform-industry-db-industry-prod"."catalog_release" AS r ON (r._id=release_id)
group by 1