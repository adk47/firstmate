/*
id: muso_only_credits_for_non_claimed_profiles
title: [AdHoc] Muso-only credits for non-claimed profiles
athena_id: 947b3aa2-fe2b-4deb-beb0-f1eed5d09643
primary_tag: adhoc
tags: [adhoc]
trino_catalog: hive
trino_schema: default
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

with s as (
	select seatid as _id,
		TRUE as is_in_seats,
		BOOL_OR(status = 'active') as is_pro,
		BOOL_OR(type = 'organization') as is_org
	from postgresql_core.public.roster_seats
	group by 1
),
cl as (
	select profileid as _id,
		TRUE as is_claiming_attempted,
		BOOL_OR(status = 'processed') as is_claimed
	from postgresql_core.public.claiming
	group by 1
),
rt as (
	select rrid as recording_id,
		track_id as muso_track_id
	from (
			select _id as track_id,
				array_union(raw_recording_ids, ARRAY [ 'muso:' || _id ]) as rids
			from hive."platform-industry-bi-prod".matvw_catalog_track
			where not is_deleted
		)
		cross join unnest(rids) as r(rrid)
),
rp as (
	select rpid as profile_id,
		profile_id as muso_profile_id
	from (
			select _id as profile_id,
				array_union(raw_profile_ids, ARRAY [ 'muso:' || _id ]) as rids
			from hive."platform-industry-bi-prod".matvw_catalog_profile
			where not is_deleted
		)
		cross join unnest(rids) as r(rpid)
),
c as (
	select muso_profile_id,
		muso_track_id,
		array_agg(distinct credit) as raw_credits,
		array_agg(
			distinct coalesce(action_by.type, 'system') || ':' || coalesce(action_by.sub_type, '') || ':' || coalesce(action_by.id, '')
		) as raw_added_by,
		array_agg(distinct created_by) as raw_created_by,
		from_unixtime(min(created_timestamp) / 1000) as raw_min_added_time,
		from_unixtime(max(created_timestamp) / 1000) as raw_max_added_time
	from hive."platform-industry-bi-prod".matvw_raw_recording_credit as c
		join rp USING(profile_id)
		join rt USING(recording_id)
	group by 1,
		2
	having count_if(profile_id not like 'muso:%') = 0
		and count_if(
			profile_id like 'muso:%'
			and not is_deleted
		) > 0
)
select p._id as profile_id,
	t._id as track_id,
	array_join(raw_credits, ',') as muso_credits,
	t.popularity as track_popularity,
	t.title as track_title,
	array_join(transform(artists, a->a.name), ',') as track_artists,
	p.popularity as profile_popularity,
	p.name as profile_name,
	p.profile_type as profile_type,
	p.common_credits as profile_common_credits,
	raw_added_by,
	raw_created_by,
	raw_min_added_time,
	raw_max_added_time
from hive."platform-industry-bi-prod".matvw_catalog_track as t
	join c ON(t._id = muso_track_id)
	left join cl ON(cl._id = muso_profile_id)
	join hive."platform-industry-bi-prod".matvw_catalog_profile as p ON(p._id = muso_profile_id)
where not t.is_deleted
	and t.popularity > 30
	and not COALESCE(is_claimed, FALSE)
order by 4 desc