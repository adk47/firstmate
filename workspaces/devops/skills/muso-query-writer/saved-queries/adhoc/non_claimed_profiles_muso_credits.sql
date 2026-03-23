/*
id: non_claimed_profiles_muso_credits
title: [AdHoc] Non claimed profiles muso credits
athena_id: 10fbca53-6f96-4a66-b30a-ff71af04a33f
primary_tag: adhoc
tags: [adhoc]
athena_database: platform-industry-bi-prod
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
	from "platform-core-backend-export-prod".public_roster_seats
	group by 1
),
cl as (
	select profileid as _id,
		TRUE as is_claiming_attempted,
		BOOL_OR(status = 'processed') as is_claimed
	from "platform-core-backend-export-prod".public_claiming
	group by 1
)
select p._id as profile_id,
	t._id as track_id,
	arbitrary(t.popularity) as track_popularity,
	arbitrary(t.title) as track_title,
	arbitrary(array_join(transform(artists, a->a.name), ',')) as track_artists,
	arbitrary(p.popularity) as profile_popularity,
	arbitrary(p.name) as profile_name,
	arbitrary(p.profile_type) as profile_type,
	arbitrary(p.common_credits) as profile_common_credits
from "platform-industry-calc-common-prod".calc_profile_track_credits as c
	join "platform-industry-bi-prod".matvw_catalog_track as t ON (t._id=c.master_track_id)
	join "platform-industry-bi-prod".matvw_catalog_profile as p ON (c.profile_id = p._id)
	left join s ON(s._id = p._id)
	left join cl ON(cl._id = p._id)
	cross join unnest(raw_recording_credit_ids) AS cr(rcid)
	join "platform-industry-bi-prod".matvw_raw_recording_credit AS r ON(rcid = r._id)
where not p.is_deleted
	and not t.is_deleted
-- 	and t.popularity > 0 -- and p.profile_type in ('artist', 'professional')
	and not COALESCE(is_claimed, FALSE)
group by 1,
	2
having count_if(r.profile_id not like 'muso:%') = 0
order by 3 desc