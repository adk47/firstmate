/*
id: milestones_last_week
title: [marketing] Milestones last week
athena_id: 748891b9-91c3-4efb-bd33-6c280f186a3e
primary_tag: marketing
tags: [marketing]
athena_database: production-musomvp
description: No description provided
status: one_off
pii: unknown
last_exported: 2025-01-31
*/

select case
		when type = 'legendary' then 10000000000
		when type = 'diamond' then 1000000000
		when type = 'platinum' then 100000000
		when type = 'gold' then 10000000
		when type = 'silver' then 1000000
		when type = 'bronze' then 100000
		when type = 'iron' then 10000 else 0
	end * increment as streams,
	type,
	increment,
	trackid,
	t.title AS track_title,
	array_join(array_distinct(transform(artists, a->a.name)), ', ') AS track_artists,
	profileid,
	p.name AS profile_name,
	ARRAY_JOIN(p.common_credits, ', ') AS profile_common_credits,
	updatedat AS updated_time
from "production-musomvp".public_track_milestones AS m
join hive.default.matvw_catalog_track AS t ON (t._id=m.trackid)
join hive.default.matvw_catalog_profile AS p ON (p._id=m.profileid)
where date_diff(
		'day',
		TRY(DATE(substr("updatedat", 1, 10))),
		current_date
	) < 7
	and type not in ('iron', 'bronze', 'silver')
order by 1 desc, updatedat desc